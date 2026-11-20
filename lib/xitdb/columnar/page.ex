defmodule Xitdb.Columnar.Page do
  @moduledoc """
  Parquet-inspired immutable row-group column page encoder and decoder (`"XCP1"`).

  Supports three intra-page column encodings:
  - `:plain_block` — presence bitmask + LEB128 varint byte-length table + concatenated values,
    compressed together across row boundaries.
  - `:dict_rle` — presence bitmask + deduplicated symbol dictionary + run-length encoded symbol IDs
    for low/medium-cardinality columns (such as MIME headers and message previews).
  - `:dict_block` — presence bitmask + varint byte-length table compressed using a shared `__dicts`
    dictionary (ideal for `Body` / `HtmlEditBody` HTML corpora).

  Every header length, varint, symbol index, RLE run sum, and presence bitmask is bounds-checked
  prior to decompression or slicing, returning `{:error, %Xitdb.Error{reason: :corrupt_column_page}}`
  or `:decompressed_size_exceeded` cleanly on malformed input.
  """

  import Bitwise

  alias Xitdb.{Compression, Error}

  @magic "XCP1"
  @flags_v1 0x01
  @max_rows 65_536
  @max_decompressed_bytes 64 * 1024 * 1024

  @enc_plain_block 1
  @enc_dict_rle 2
  @enc_dict_block 3

  @codec_none 0
  @codec_zlib 1
  @codec_zstd 2

  defstruct [
    :encoding,
    :codec,
    :row_count,
    :dict_name,
    :presence,
    :offsets,
    :sym_table,
    :row_sym_ids,
    :data
  ]

  @type encoding :: :plain_block | :dict_rle | :dict_block
  @type codec :: :none | :zlib | :zstd

  @type t :: %__MODULE__{
          encoding: encoding(),
          codec: codec(),
          row_count: non_neg_integer(),
          dict_name: String.t() | nil,
          presence: binary(),
          offsets: tuple() | nil,
          sym_table: tuple() | nil,
          row_sym_ids: tuple() | nil,
          data: binary()
        }

  @doc """
  Encodes a list of column values (`binary() | nil`) into a single binary `"XCP1"` column page.

  ## Options
  - `:encoding` (`:auto | :plain_block | :dict_rle | :dict_block`) — default `:auto`.
  - `:codec` (`:zstd | :zlib | :none`) — default `Xitdb.Compression.default_codec/0`.
  - `:level` (`integer()`) — codec compression level.
  - `:dictionary` (`atom() | String.t()`) — shared dictionary name (when using `:dict_block`).
  - `:dictionary_bytes` (`binary()`) — raw shared dictionary bytes.
  """
  @spec encode_page([binary() | nil], keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def encode_page(values, opts \\ []) when is_list(values) and is_list(opts) do
    row_count = length(values)

    cond do
      row_count > @max_rows ->
        {:error,
         %Error{reason: :invalid_column_page, details: %{row_count: row_count, max: @max_rows}}}

      not Enum.all?(values, &(is_nil(&1) or is_binary(&1))) ->
        {:error,
         %Error{reason: :invalid_column_page, details: %{reason: :expected_binary_or_nil}}}

      true ->
        do_encode_page(values, row_count, opts)
    end
  end

  @doc "Same as `encode_page/2`, but raises `Xitdb.Error` on failure."
  @spec encode_page!([binary() | nil], keyword()) :: binary()
  def encode_page!(values, opts \\ []), do: values |> encode_page(opts) |> Error.unwrap!()

  @doc """
  Decodes a binary `"XCP1"` column page into a `%Xitdb.Columnar.Page{}` index structure
  supporting `O(1)` random row extraction via `decode_row/2`.

  ## Options
  - `:dictionary_bytes` (`binary()`) — preloaded shared dictionary bytes.
  - `:db_ref` (`reference()`) & `:moment` (`integer()`) — used to look up `.__dicts.<name>` for `:dict_block` pages.
  - `:max_decompressed_bytes` (`pos_integer()`) — upper bound on decompressed page size (default `64 MB`).
  """
  @spec decode_page(binary(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def decode_page(page_bin, opts \\ [])

  def decode_page(
        <<@magic, enc_byte::8, codec_byte::8, flags_byte::8, row_count::unsigned-little-32,
          raw_block_len::unsigned-little-32, dict_name_len::8, rest::binary>>,
        opts
      )
      when enc_byte in [@enc_plain_block, @enc_dict_rle, @enc_dict_block] and
             codec_byte in [@codec_none, @codec_zlib, @codec_zstd] and
             (flags_byte &&& 0xFE) == 0 and row_count <= @max_rows and
             byte_size(rest) >= dict_name_len and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_decompressed_bytes, @max_decompressed_bytes)

    if raw_block_len > max_bytes do
      {:error,
       %Error{
         reason: :decompressed_size_exceeded,
         details: %{raw_len: raw_block_len, max_decompressed_bytes: max_bytes}
       }}
    else
      <<dict_name_bin::binary-size(^dict_name_len), block_payload::binary>> = rest
      encoding = encoding_from_byte(enc_byte)
      codec = codec_from_byte(codec_byte)
      dict_name = if dict_name_len > 0, do: :binary.copy(dict_name_bin), else: nil

      with {:ok, raw_body} <-
             decompress_page_payload(
               encoding,
               codec,
               raw_block_len,
               dict_name,
               block_payload,
               max_bytes,
               opts
             ) do
        parse_decoded_body(encoding, codec, row_count, dict_name, raw_body)
      end
    end
  end

  def decode_page(_other, _opts) do
    {:error, %Error{reason: :corrupt_column_page}}
  end

  @doc "Same as `decode_page/2`, but raises `Xitdb.Error` on failure."
  @spec decode_page!(binary(), keyword()) :: t()
  def decode_page!(page_bin, opts \\ []), do: page_bin |> decode_page(opts) |> Error.unwrap!()

  @doc """
  Extracts the value at `row_idx` (`0..row_count - 1`) in `O(1)` time.
  """
  @spec decode_row(t(), integer()) :: {:ok, binary() | nil} | {:error, Error.t()}
  def decode_row(%__MODULE__{row_count: row_count}, row_idx)
      when not is_integer(row_idx) or row_idx < 0 or row_idx >= row_count do
    {:error,
     %Error{reason: :corrupt_column_page, details: %{row_idx: row_idx, row_count: row_count}}}
  end

  def decode_row(%__MODULE__{encoding: :dict_rle, row_sym_ids: row_ids, sym_table: syms}, row_idx) do
    case elem(row_ids, row_idx) do
      nil -> {:ok, nil}
      sym_id -> {:ok, :binary.copy(elem(syms, sym_id))}
    end
  end

  def decode_row(%__MODULE__{offsets: offsets, data: data}, row_idx) do
    case elem(offsets, row_idx) do
      nil -> {:ok, nil}
      {off, len} -> {:ok, :binary.copy(:binary.part(data, off, len))}
    end
  end

  @doc """
  Materializes every row value in `page` as an ordered list `[binary() | nil]`.
  """
  @spec decode_all(t()) :: [binary() | nil]
  def decode_all(%__MODULE__{row_count: 0}), do: []

  def decode_all(%__MODULE__{row_count: row_count} = page) do
    for idx <- 0..(row_count - 1) do
      {:ok, val} = decode_row(page, idx)
      val
    end
  end

  # ============================================================================
  # Encode Helpers
  # ============================================================================

  defp do_encode_page(values, row_count, opts) do
    dict_name_opt = opts[:dictionary]
    dict_name_str = if is_nil(dict_name_opt), do: nil, else: to_string(dict_name_opt)

    if not is_nil(dict_name_str) and byte_size(dict_name_str) not in 1..255 do
      {:error, %Error{reason: :invalid_column_page, details: %{dictionary: dict_name_str}}}
    else
      dict_bytes = opts[:dictionary_bytes]

      has_dict? =
        not is_nil(dict_name_str) and is_binary(dict_bytes) and byte_size(dict_bytes) > 0

      req_encoding = Keyword.get(opts, :encoding, :auto)
      encoding = choose_encoding(req_encoding, values, has_dict?)
      codec = normalize_page_codec(Keyword.get(opts, :codec, Compression.default_codec()))
      level = Keyword.get(opts, :level)

      dict_name_bin =
        if encoding == :dict_block and has_dict? do
          dict_name_str
        else
          ""
        end

      presence = build_presence_mask(values, row_count)
      raw_body = encode_body(encoding, values, presence)
      raw_block_len = byte_size(raw_body)

      {eff_codec_byte, payload} =
        compress_page_body(raw_body, raw_block_len, codec, encoding, dict_bytes, level)

      enc_byte = encoding_to_byte(encoding)
      dict_len = byte_size(dict_name_bin)

      page_bin =
        <<@magic, enc_byte::8, eff_codec_byte::8, @flags_v1::8, row_count::unsigned-little-32,
          raw_block_len::unsigned-little-32, dict_len::8, dict_name_bin::binary, payload::binary>>

      {:ok, page_bin}
    end
  end

  defp choose_encoding(:plain_block, _values, _has_dict?), do: :plain_block
  defp choose_encoding(:dict_rle, _values, _has_dict?), do: :dict_rle

  defp choose_encoding(:dict_block, _values, true), do: :dict_block
  defp choose_encoding(:dict_block, _values, false), do: :plain_block

  defp choose_encoding(:auto, values, has_dict?) do
    {non_nil_count, uniq_set} =
      Enum.reduce(values, {0, MapSet.new()}, fn
        nil, acc -> acc
        bin, {cnt, set} -> {cnt + 1, MapSet.put(set, bin)}
      end)

    cond do
      non_nil_count >= 4 and MapSet.size(uniq_set) * 2 <= non_nil_count ->
        :dict_rle

      has_dict? ->
        :dict_block

      true ->
        :plain_block
    end
  end

  defp compress_page_body(raw_body, _raw_len, :none, _encoding, _dict_bytes, _level) do
    {@codec_none, raw_body}
  end

  defp compress_page_body(raw_body, raw_len, _codec, _encoding, _dict_bytes, _level)
       when raw_len < 32 do
    {@codec_none, raw_body}
  end

  defp compress_page_body(raw_body, raw_len, codec, encoding, dict_bytes, level) do
    eff_dict = if encoding == :dict_block, do: dict_bytes, else: nil

    case Compression.compress_block(raw_body, codec, eff_dict, level) do
      {:ok, comp} when byte_size(comp) < raw_len ->
        {codec_to_byte(codec), comp}

      _ ->
        {@codec_none, raw_body}
    end
  end

  defp build_presence_mask(_values, 0), do: <<>>

  defp build_presence_mask(values, _row_count) do
    values
    |> Enum.chunk_every(8)
    |> Enum.map(fn group ->
      group
      |> Enum.with_index()
      |> Enum.reduce(0, fn
        {nil, _bit_idx}, byte -> byte
        {_bin, bit_idx}, byte -> bor(byte, 1 <<< bit_idx)
      end)
    end)
    |> :erlang.list_to_binary()
  end

  defp encode_body(encoding, values, presence) when encoding in [:plain_block, :dict_block] do
    {lengths_io, blobs_io} =
      Enum.reduce(values, {[], []}, fn
        nil, acc ->
          acc

        bin, {lens, blobs} ->
          {[encode_varint(byte_size(bin)) | lens], [bin | blobs]}
      end)

    IO.iodata_to_binary([presence, :lists.reverse(lengths_io), :lists.reverse(blobs_io)])
  end

  defp encode_body(:dict_rle, values, presence) do
    {sym_map, sym_list_rev, sym_count, sym_ids_rev} =
      Enum.reduce(values, {%{}, [], 0, []}, fn
        nil, acc ->
          acc

        bin, {map, syms, cnt, ids} ->
          case Map.fetch(map, bin) do
            {:ok, id} ->
              {map, syms, cnt, [id | ids]}

            :error ->
              next_map = Map.put(map, bin, cnt)
              {next_map, [bin | syms], cnt + 1, [cnt | ids]}
          end
      end)

    _ = sym_map
    syms = :lists.reverse(sym_list_rev)
    sym_ids = :lists.reverse(sym_ids_rev)
    runs = encode_rle_runs(sym_ids)

    sym_entries_io =
      Enum.map(syms, fn s ->
        [encode_varint(byte_size(s)), s]
      end)

    runs_io =
      Enum.map(runs, fn {sym_id, run_len} ->
        [encode_varint(sym_id), encode_varint(run_len)]
      end)

    IO.iodata_to_binary([
      presence,
      encode_varint(sym_count),
      sym_entries_io,
      encode_varint(length(runs)),
      runs_io
    ])
  end

  defp encode_rle_runs([]), do: []

  defp encode_rle_runs([first | rest]) do
    {last_id, last_len, acc} =
      Enum.reduce(rest, {first, 1, []}, fn
        id, {id, len, acc} -> {id, len + 1, acc}
        id, {prev_id, prev_len, acc} -> {id, 1, [{prev_id, prev_len} | acc]}
      end)

    :lists.reverse([{last_id, last_len} | acc])
  end

  # ============================================================================
  # Decode Helpers
  # ============================================================================

  defp decompress_page_payload(
         _encoding,
         :none,
         raw_block_len,
         _dict_name,
         block_payload,
         _max_bytes,
         _opts
       ) do
    if byte_size(block_payload) == raw_block_len do
      {:ok, block_payload}
    else
      {:error, %Error{reason: :corrupt_column_page}}
    end
  end

  defp decompress_page_payload(
         :dict_block,
         codec,
         raw_block_len,
         dict_name,
         block_payload,
         max_bytes,
         opts
       ) do
    if is_nil(dict_name) do
      {:error, %Error{reason: :corrupt_column_page}}
    else
      with {:ok, dict_bytes} <-
             resolve_dict_bytes(
               opts[:dictionary_bytes],
               opts[:db_ref],
               opts[:moment] || -1,
               dict_name
             ) do
        Compression.decompress_block(
          codec,
          raw_block_len,
          block_payload,
          dict_bytes,
          max_bytes,
          :corrupt_column_page
        )
      end
    end
  end

  defp decompress_page_payload(
         _encoding,
         codec,
         raw_block_len,
         _dict_name,
         block_payload,
         max_bytes,
         _opts
       ) do
    Compression.decompress_block(
      codec,
      raw_block_len,
      block_payload,
      nil,
      max_bytes,
      :corrupt_column_page
    )
  end

  defp resolve_dict_bytes(bin, _db_ref, _moment, _name)
       when is_binary(bin) and byte_size(bin) > 0,
       do: {:ok, bin}

  defp resolve_dict_bytes(_nil, db_ref, moment, name) do
    Compression.fetch_dictionary_bytes(db_ref, moment, name)
  end

  defp parse_decoded_body(encoding, codec, row_count, dict_name, raw_body) do
    mask_bytes = div(row_count + 7, 8)

    if byte_size(raw_body) < mask_bytes do
      {:error, %Error{reason: :corrupt_column_page}}
    else
      <<presence_slice::binary-size(^mask_bytes), body_rest::binary>> = raw_body
      presence = :binary.copy(presence_slice)
      present_flags = unpack_presence_flags(presence, row_count)
      non_nil_count = Enum.count(present_flags, & &1)

      case encoding do
        enc when enc in [:plain_block, :dict_block] ->
          parse_block_body(
            enc,
            codec,
            row_count,
            dict_name,
            presence,
            present_flags,
            non_nil_count,
            body_rest
          )

        :dict_rle ->
          parse_dict_rle_body(
            codec,
            row_count,
            dict_name,
            presence,
            present_flags,
            non_nil_count,
            body_rest
          )
      end
    end
  end

  defp parse_block_body(
         encoding,
         codec,
         row_count,
         dict_name,
         presence,
         present_flags,
         non_nil_count,
         body_rest
       ) do
    with {:ok, lengths, data_bin} <- decode_varint_n(body_rest, non_nil_count, []),
         {:ok, offsets} <- build_offsets_tuple(present_flags, lengths, byte_size(data_bin)) do
      {:ok,
       %__MODULE__{
         encoding: encoding,
         codec: codec,
         row_count: row_count,
         dict_name: dict_name,
         presence: presence,
         offsets: offsets,
         data: :binary.copy(data_bin)
       }}
    else
      _ -> {:error, %Error{reason: :corrupt_column_page}}
    end
  end

  defp build_offsets_tuple(present_flags, lengths, data_size) do
    {rev_slots, rest_lens, total_off} =
      Enum.reduce_while(present_flags, {[], lengths, 0}, fn
        false, {acc, lens, off} ->
          {:cont, {[nil | acc], lens, off}}

        true, {acc, [len | rest], off} ->
          if off + len <= data_size do
            {:cont, {[{off, len} | acc], rest, off + len}}
          else
            {:halt, :error}
          end

        true, {_, [], _} ->
          {:halt, :error}
      end)
      |> case do
        :error -> {:error, :error, -1}
        res -> res
      end

    if rest_lens == [] and total_off == data_size do
      {:ok, rev_slots |> :lists.reverse() |> List.to_tuple()}
    else
      :error
    end
  end

  defp parse_dict_rle_body(
         codec,
         row_count,
         dict_name,
         presence,
         present_flags,
         non_nil_count,
         body_rest
       ) do
    with {:ok, sym_count, after_sym_cnt}
         when sym_count <= non_nil_count and sym_count <= @max_rows <-
           decode_varint(body_rest),
         {:ok, syms, after_syms} <- decode_symbols(after_sym_cnt, sym_count, []),
         {:ok, run_count, after_run_cnt} when run_count <= non_nil_count <-
           decode_varint(after_syms),
         {:ok, expanded_ids} <-
           decode_rle_runs(after_run_cnt, run_count, sym_count, non_nil_count),
         {:ok, row_sym_ids} <- align_rle_with_presence(present_flags, expanded_ids) do
      {:ok,
       %__MODULE__{
         encoding: :dict_rle,
         codec: codec,
         row_count: row_count,
         dict_name: dict_name,
         presence: presence,
         sym_table: List.to_tuple(syms),
         row_sym_ids: row_sym_ids,
         data: <<>>
       }}
    else
      _ -> {:error, %Error{reason: :corrupt_column_page}}
    end
  end

  defp decode_symbols(bin, 0, acc), do: {:ok, :lists.reverse(acc), bin}

  defp decode_symbols(bin, remaining, acc) do
    with {:ok, slen, rest} when byte_size(rest) >= slen <- decode_varint(bin) do
      <<s::binary-size(^slen), tail::binary>> = rest
      decode_symbols(tail, remaining - 1, [:binary.copy(s) | acc])
    else
      _ -> :error
    end
  end

  defp decode_rle_runs(<<>>, 0, _sym_count, 0), do: {:ok, []}
  defp decode_rle_runs(_bin, 0, _sym_count, _non_nil), do: :error

  defp decode_rle_runs(bin, run_count, sym_count, expected_total) do
    do_decode_rle_runs(bin, run_count, sym_count, expected_total, [])
  end

  defp do_decode_rle_runs(<<>>, 0, _sym_count, 0, acc) do
    {:ok, :lists.reverse(acc)}
  end

  defp do_decode_rle_runs(_bin, 0, _sym_count, _rem, _acc), do: :error

  defp do_decode_rle_runs(bin, runs_left, sym_count, rem_vals, acc) do
    with {:ok, sym_id, rest1} when sym_id < sym_count <- decode_varint(bin),
         {:ok, run_len, rest2} when run_len >= 1 and run_len <= rem_vals <- decode_varint(rest1) do
      next_acc = prepend_repeated(acc, sym_id, run_len)
      do_decode_rle_runs(rest2, runs_left - 1, sym_count, rem_vals - run_len, next_acc)
    else
      _ -> :error
    end
  end

  defp prepend_repeated(acc, _sym_id, 0), do: acc
  defp prepend_repeated(acc, sym_id, n), do: prepend_repeated([sym_id | acc], sym_id, n - 1)

  defp align_rle_with_presence(present_flags, expanded_ids) do
    {rev, rem_ids} =
      Enum.reduce(present_flags, {[], expanded_ids}, fn
        false, {acc, ids} -> {[nil | acc], ids}
        true, {acc, [id | rest]} -> {[id | acc], rest}
        true, {acc, []} -> {[nil | acc], :underflow}
      end)

    if rem_ids == [] do
      {:ok, rev |> :lists.reverse() |> List.to_tuple()}
    else
      :error
    end
  end

  defp unpack_presence_flags(_presence, 0), do: []

  defp unpack_presence_flags(presence, row_count) do
    0..(row_count - 1)
    |> Enum.map(fn idx ->
      byte = :binary.at(presence, div(idx, 8))
      band(byte, 1 <<< rem(idx, 8)) != 0
    end)
  end

  # ============================================================================
  # Unsigned LEB128 Varint & Mapping Primitives
  # ============================================================================

  defp encode_varint(n) when is_integer(n) and n >= 0 and n < 128, do: <<n>>

  defp encode_varint(n) when is_integer(n) and n >= 128 do
    [bor(band(n, 0x7F), 0x80) | encode_varint(bsr(n, 7))]
  end

  defp decode_varint_n(bin, 0, acc), do: {:ok, :lists.reverse(acc), bin}

  defp decode_varint_n(bin, n, acc) when n > 0 do
    case decode_varint(bin) do
      {:ok, v, rest} -> decode_varint_n(rest, n - 1, [v | acc])
      :error -> :error
    end
  end

  defp decode_varint(bin), do: do_decode_varint(bin, 0, 0)

  defp do_decode_varint(<<byte::8, rest::binary>>, shift, acc) when shift <= 28 do
    next_acc = bor(acc, bsl(band(byte, 0x7F), shift))

    if band(byte, 0x80) == 0 do
      {:ok, next_acc, rest}
    else
      do_decode_varint(rest, shift + 7, next_acc)
    end
  end

  defp do_decode_varint(_, _, _), do: :error

  defp normalize_page_codec(:none), do: :none
  defp normalize_page_codec(:zlib), do: :zlib

  defp normalize_page_codec(:zstd),
    do: if(Compression.zstd_available?(), do: :zstd, else: :zlib)

  defp normalize_page_codec(other) do
    raise ArgumentError, "unsupported columnar codec: #{inspect(other)}"
  end

  defp encoding_to_byte(:plain_block), do: @enc_plain_block
  defp encoding_to_byte(:dict_rle), do: @enc_dict_rle
  defp encoding_to_byte(:dict_block), do: @enc_dict_block

  defp encoding_from_byte(@enc_plain_block), do: :plain_block
  defp encoding_from_byte(@enc_dict_rle), do: :dict_rle
  defp encoding_from_byte(@enc_dict_block), do: :dict_block

  defp codec_to_byte(:zlib), do: @codec_zlib
  defp codec_to_byte(:zstd), do: @codec_zstd

  defp codec_from_byte(@codec_none), do: :none
  defp codec_from_byte(@codec_zlib), do: :zlib
  defp codec_from_byte(@codec_zstd), do: :zstd
end
