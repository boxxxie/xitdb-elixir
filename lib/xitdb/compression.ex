defmodule Xitdb.Compression do
  @moduledoc """
  Transparent value-level compression, shared dictionary codecs, and content-addressed
  blob interning built on top of `xitdb`'s 2-byte `format_tag` wire primitive.

  ## Format Tags

  | Tag | Codec / Mechanism | Wire Payload Layout |
  | :--- | :--- | :--- |
  | `"cz"` | `:zlib` deflate | `<<0x10, raw_len::little-32, zlib_stream::binary>>` |
  | `"zs"` | `:zstd` (OTP 28+) | `<<0x10, raw_len::little-32, zstd_frame::binary>>` |
  | `"zd"` | Shared dictionary (`0x10` zstd / `0x12` zlib) | `<<ver_codec, raw_len::little-32, name_len, name::binary, data::binary>>` |
  | `"bp"` | Content-addressed `__blobs/<sha256>` pointer | `<<0x10, sha256_raw::binary-size(32)>>` |
  | `"pg"` | Parquet-style row-group page pointer | Refer to `Xitdb.Columnar` |

  Payloads smaller than `:min_bytes` (default `128`) or incompressible inputs that save fewer
  than `:min_savings` (default `16`) bytes stay uncompressed as native `Tag.Bytes` / `Tag.Short_Bytes`.
  """

  import Bitwise

  alias Xitdb.{CacheOwner, Error, NIF, Selector}

  @default_min_bytes 128
  @default_min_savings 16
  @default_max_decompressed_bytes 64 * 1024 * 1024
  @max_dereference_depth 2

  @tag_zlib "cz"
  @tag_zstd "zs"
  @tag_dict "zd"
  @tag_blob "bp"
  @tag_page "pg"

  @compression_tags [@tag_zlib, @tag_zstd, @tag_dict, @tag_blob, @tag_page]

  @version_zlib 0x10
  @version_zstd 0x10
  @version_dict_zstd 0x10
  @version_dict_zlib 0x12
  @version_blob 0x10

  @dict_cache_table :xitdb_dict_cache
  @dict_cache_limit 64
  @internal_roots MapSet.new(["__tx", "__blobs", "__dicts", "__col_pages", "idx"])

  @doc """
  Returns `true` if built-in Erlang `:zstd` compression is available on this OTP runtime.
  """
  @spec zstd_available?() :: boolean()
  def zstd_available?, do: Code.ensure_loaded?(:zstd)

  @doc """
  Returns the default maximum allowed decompressed payload size in bytes (`64 MB`).
  """
  @spec default_max_decompressed_bytes() :: pos_integer()
  def default_max_decompressed_bytes, do: @default_max_decompressed_bytes

  @doc """
  Returns the default value compression codec (`:zstd` when available, otherwise `:zlib`).
  """
  @spec default_codec() :: :zstd | :zlib
  def default_codec, do: if(zstd_available?(), do: :zstd, else: :zlib)

  @doc """
  Returns `true` if `tag` is an internal compression or columnar format tag.
  """
  @spec compression_tag?(term()) :: boolean()
  def compression_tag?(tag) when tag in @compression_tags, do: true
  def compression_tag?(_), do: false

  @doc """
  Compresses `raw` binary if it meets `:min_bytes` and `:min_savings` thresholds,
  returning either `{:tagged, tag, payload}` or the original uncompressed `raw` binary.

  ## Options
  - `:codec` (`:zstd | :zlib`) — compression codec (defaults to `default_codec/0`).
  - `:min_bytes` (`non_neg_integer()`) — minimum input byte size before compressing (default `128`).
  - `:min_savings` (`non_neg_integer()`) — minimum net byte reduction required (default `16`).
  - `:level` (`integer()`) — codec compression level (`3` for `:zstd`, `6` for `:zlib`).
  - `:dictionary` (`atom() | String.t()`) — shared dictionary identifier stored in `__dicts/<name>`.
  - `:dictionary_bytes` (`binary()`) — raw dictionary buffer matching `:dictionary`.
  """
  @spec compress(binary(), keyword()) :: binary() | {:tagged, String.t(), binary()}
  def compress(raw, opts \\ []) when is_binary(raw) and is_list(opts) do
    min_bytes = Keyword.get(opts, :min_bytes, @default_min_bytes)
    min_savings = Keyword.get(opts, :min_savings, @default_min_savings)
    raw_len = byte_size(raw)

    if raw_len == 0 or raw_len < min_bytes do
      raw
    else
      codec = normalize_codec(Keyword.get(opts, :codec, default_codec()))
      level = Keyword.get(opts, :level)
      dict_name = opts[:dictionary]
      dict_bytes = opts[:dictionary_bytes]

      candidate =
        cond do
          not is_nil(dict_name) and is_binary(dict_bytes) and byte_size(dict_bytes) > 0 ->
            encode_dict_tagged(raw, raw_len, codec, level, dict_name, dict_bytes)

          codec == :zstd ->
            compressed = compress_zstd_raw(raw, level)
            {@tag_zstd, <<@version_zstd::8, raw_len::unsigned-little-32, compressed::binary>>}

          codec == :zlib ->
            compressed = :zlib.compress(raw)
            {@tag_zlib, <<@version_zlib::8, raw_len::unsigned-little-32, compressed::binary>>}
        end

      case candidate do
        {tag, framed_payload}
        when byte_size(framed_payload) + min_savings <= raw_len and
               byte_size(framed_payload) < raw_len ->
          {:tagged, tag, framed_payload}

        _ ->
          raw
      end
    end
  end

  @doc """
  Decompresses a plain binary or compressed `{:tagged, tag, payload}` term into plaintext bytes.

  Enforces `max_decompressed_bytes` (default `64 MB`) before allocating buffers or streaming inflate
  output, returning `{:error, %Xitdb.Error{}}` on corrupt, truncated, or oversized payloads.
  """
  @spec decompress(term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def decompress(term, opts \\ []) when is_list(opts) do
    case term do
      bin when is_binary(bin) ->
        {:ok, bin}

      {:tagged, tag, payload}
      when tag in [@tag_zlib, @tag_zstd, @tag_dict, @tag_blob, @tag_page] ->
        resolve_tagged(tag, payload, opts[:db_ref], Keyword.get(opts, :moment, -1), opts)

      other ->
        {:ok, other}
    end
  end

  @doc "Same as `decompress/2`, but raises `Xitdb.Error` on failure."
  @spec decompress!(term(), keyword()) :: term()
  def decompress!(term, opts \\ []), do: term |> decompress(opts) |> Error.unwrap!()

  @doc """
  Encodes a raw block using `:zstd`, `:zlib`, or optional dictionary bytes without `"cz"`/`"zs"` framing.
  Used internally by `Xitdb.Columnar.Page`.
  """
  @spec compress_block(binary(), :zstd | :zlib, binary() | nil, integer() | nil) ::
          {:ok, binary()} | {:error, term()}
  def compress_block(raw, :zstd, dict_bytes, level) when is_binary(raw) do
    if zstd_available?() do
      if is_binary(dict_bytes) and byte_size(dict_bytes) > 0 do
        {:ok, cdict, _ddict} = get_or_build_zstd_dicts(dict_bytes)
        {:ok, compress_zstd_with_dict(raw, cdict, level)}
      else
        {:ok, compress_zstd_raw(raw, level)}
      end
    else
      {:error, :zstd_unavailable}
    end
  end

  def compress_block(raw, :zlib, dict_bytes, level) when is_binary(raw) do
    if is_binary(dict_bytes) and byte_size(dict_bytes) > 0 do
      {:ok, compress_zlib_with_dict(raw, dict_bytes, level || 6)}
    else
      {:ok, :zlib.compress(raw)}
    end
  end

  @doc """
  Decompresses a raw `:zstd` or `:zlib` block with strict `expected_len` and `max_bytes` checks.
  Used internally by `Xitdb.Columnar.Page`.
  """
  @spec decompress_block(
          :zstd | :zlib,
          non_neg_integer(),
          binary(),
          binary() | nil,
          non_neg_integer(),
          atom()
        ) :: {:ok, binary()} | {:error, Error.t()}
  def decompress_block(
        codec,
        expected_len,
        compressed,
        dict_bytes,
        max_bytes,
        corrupt_reason \\ :corrupt_compressed_payload
      )

  def decompress_block(_codec, expected_len, _compressed, _dict_bytes, max_bytes, _corrupt_reason)
      when expected_len > max_bytes do
    {:error,
     %Error{
       reason: :decompressed_size_exceeded,
       details: %{raw_len: expected_len, max_decompressed_bytes: max_bytes}
     }}
  end

  def decompress_block(:zlib, expected_len, compressed, dict_bytes, max_bytes, corrupt_reason) do
    safe_zlib_inflate(compressed, expected_len, max_bytes, dict_bytes, corrupt_reason)
  end

  def decompress_block(:zstd, expected_len, compressed, dict_bytes, max_bytes, corrupt_reason) do
    if zstd_available?() do
      ddict =
        if is_binary(dict_bytes) and byte_size(dict_bytes) > 0 do
          {:ok, _cdict, d} = get_or_build_zstd_dicts(dict_bytes)
          d
        else
          nil
        end

      safe_zstd_decompress(compressed, expected_len, max_bytes, ddict, corrupt_reason)
    else
      {:error, %Error{reason: :zstd_unavailable}}
    end
  end

  @doc """
  Resolves a compression or columnar tagged tuple `{:tagged, tag, payload}` against `(db_ref, moment)`.
  """
  @spec resolve_tagged(String.t(), binary(), reference() | nil, integer(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def resolve_tagged(tag, payload, db_ref, moment, opts \\ []) do
    depth = Keyword.get(opts, :_depth, 0)
    max_bytes = Keyword.get(opts, :max_decompressed_bytes, @default_max_decompressed_bytes)

    if depth > @max_dereference_depth do
      {:error, %Error{reason: :corrupt_compressed_payload, details: %{reason: :cycle_detected}}}
    else
      do_resolve_tagged(tag, payload, db_ref, moment, max_bytes, opts, depth)
    end
  end

  @doc "Same as `resolve_tagged/5`, but raises `Xitdb.Error` on failure."
  @spec resolve_tagged!(String.t(), binary(), reference() | nil, integer(), keyword()) :: term()
  def resolve_tagged!(tag, payload, db_ref, moment, opts \\ []) do
    resolve_tagged(tag, payload, db_ref, moment, opts) |> Error.unwrap!()
  end

  @doc """
  Recursively resolves any compressed or columnar tags inside a materialized term returned by the NIF.
  Fast-paths without allocation when no compression tags are present.
  """
  @spec resolve_term(term(), reference() | nil, integer(), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def resolve_term(term, db_ref, moment, opts \\ [])

  def resolve_term(term, _db_ref, _moment, _opts)
      when is_binary(term) or is_number(term) or is_boolean(term) or is_nil(term) do
    {:ok, term}
  end

  def resolve_term({:tagged, tag, _payload} = tagged, db_ref, moment, opts)
      when tag in @compression_tags do
    case tagged do
      {:tagged, tag, payload} when is_binary(payload) ->
        resolve_tagged(tag, payload, db_ref, moment, opts)

      _ ->
        {:error, %Error{reason: :corrupt_compressed_payload}}
    end
  end

  def resolve_term(term, db_ref, moment, opts) do
    if has_compressed_tag?(term) do
      do_resolve_term(term, db_ref, moment, opts)
    else
      {:ok, term}
    end
  end

  @doc "Same as `resolve_term/4`, but raises `Xitdb.Error` on failure."
  @spec resolve_term!(term(), reference() | nil, integer(), keyword()) :: term()
  def resolve_term!(term, db_ref, moment, opts \\ []) do
    resolve_term(term, db_ref, moment, opts) |> Error.unwrap!()
  end

  @doc """
  Resolves a named dictionary stored at `.__dicts.<name>` for the given database handle and moment.
  """
  @spec fetch_dictionary_bytes(reference() | nil, integer(), String.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  def fetch_dictionary_bytes(nil, _moment, dict_name) do
    {:error, %Error{reason: :missing_compression_dictionary, details: %{dictionary: dict_name}}}
  end

  def fetch_dictionary_bytes(db_ref, moment, dict_name) when is_binary(dict_name) do
    case NIF.nif_select(db_ref, moment, ["__dicts", dict_name], true) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 ->
        {:ok, bytes}

      {:ok, _other} ->
        {:error,
         %Error{reason: :missing_compression_dictionary, details: %{dictionary: dict_name}}}

      {:error, :unexpected_tag} ->
        {:error,
         %Error{reason: :missing_compression_dictionary, details: %{dictionary: dict_name}}}

      {:error, reason} ->
        {:error, %Error{reason: reason, details: %{dictionary: dict_name}}}
    end
  end

  @doc """
  Extracts a single field value compressed according to an option keyword list, returning
  `{encoded_value, blob_ops, next_state}` without duplicating `__blobs` puts in the same batch.
  """
  @spec compress_for_write(term(), binary(), keyword(), map()) ::
          {binary() | {:tagged, String.t(), binary()}, [tuple()], map()}
  def compress_for_write(
        db_or_nil,
        raw,
        opts,
        state \\ %{dicts: %{}, seen_blobs: %{}, existing_blobs: :unloaded}
      )

  def compress_for_write(db_or_nil, raw, opts, state) when is_binary(raw) and is_list(opts) do
    intern_above = Keyword.get(opts, :intern_above)
    min_bytes = Keyword.get(opts, :min_bytes, @default_min_bytes)
    min_savings = Keyword.get(opts, :min_savings, @default_min_savings)

    should_intern? =
      cond do
        is_integer(intern_above) and intern_above >= 0 ->
          byte_size(raw) >= intern_above and byte_size(raw) >= 35 + min_savings

        Keyword.get(opts, :intern, false) ->
          byte_size(raw) >= min_bytes and byte_size(raw) >= 35 + min_savings

        true ->
          false
      end

    {dict_bytes, state} =
      resolve_dict_for_write(db_or_nil, opts[:dictionary], opts[:dictionary_bytes], state)

    comp_opts =
      if is_binary(dict_bytes) do
        Keyword.put(opts, :dictionary_bytes, dict_bytes)
      else
        opts
      end

    if should_intern? do
      sha_raw = :crypto.hash(:sha256, raw)
      sha_hex = Base.encode16(sha_raw, case: :lower)
      pointer = {:tagged, @tag_blob, <<@version_blob::8, sha_raw::binary-size(32)>>}

      {blob_ops, next_state} = maybe_stage_blob_put(db_or_nil, sha_hex, raw, comp_opts, state)
      {pointer, blob_ops, next_state}
    else
      {compress(raw, comp_opts), [], state}
    end
  end

  @doc """
  Fast pre-flight scan returning `true` when `prepare_write/3` needs to rewrite compression
  directives or auto-compress values.
  """
  @spec needs_prepare?(term(), boolean() | keyword() | nil) :: boolean()
  def needs_prepare?(_term_or_ops, compress_opt)
      when is_list(compress_opt) or compress_opt == true,
      do: true

  def needs_prepare?(term_or_ops, _compress_opt), do: has_compressed_directive?(term_or_ops)

  @doc """
  Transforms `{:compressed, bin}` / `{:compressed, bin, opts}` directives and (when `:compress`
  is enabled) eligible plaintext binary values into compressed `format_tag` tuples and
  deduplicated `.__blobs.<sha>` put operations.
  """
  @spec prepare_write(
          Xitdb.t() | Xitdb.Cursor.t() | {Xitdb.t(), integer()} | nil,
          term(),
          boolean() | keyword()
        ) ::
          {:ok, term(), [tuple()]} | {:error, Error.t()}
  def prepare_write(db_or_cursor, term_or_ops, compress_opt \\ false) do
    if not needs_prepare?(term_or_ops, compress_opt) do
      {:ok, term_or_ops, []}
    else
      default_opts = normalize_compress_opts(compress_opt)
      auto? = compress_opt == true or is_list(compress_opt)

      state = %{
        dicts: %{},
        seen_blobs: %{},
        existing_blobs: :unloaded,
        blob_ops_rev: []
      }

      {transformed, final_state} =
        prepare_node(term_or_ops, db_or_cursor, default_opts, auto?, false, state)

      {:ok, transformed, :lists.reverse(final_state.blob_ops_rev)}
    end
  end

  # ============================================================================
  # Shared Dictionary Training & Persistence (Xitdb.Compression.Dictionary)
  # ============================================================================

  defmodule Dictionary do
    @moduledoc """
    Shared compression dictionary builder (`train_dictionary/2`) and immutable database
    persistence helpers (`put/4`, `get/2`, `train_and_put/4`) stored at `.__dicts.<name>`.
    """

    @doc """
    Trains a compact shared compression dictionary (`target_size` default `32_768` bytes)
    from `samples` by extracting high-frequency recurring substrings (e.g. HTML headers,
    CSS rules, signatures, and legal disclaimers) and placing top-scoring segments at the end
    of the dictionary buffer for optimal `:zstd` and `:zlib` window proximity.

    ## Options
    - `:target_size` (`pos_integer()`) — maximum dictionary size in bytes (default `32_768`, clamped to `512..131_072`).
    - `:chunk_size` (`pos_integer()`) — k-mer sample window length (default `64`).
    - `:step` (`pos_integer()`) — stride between candidate windows (default `16`).
    - `:max_samples` (`pos_integer()`) — maximum samples scanned during training (default `2_000`).
    """
    @spec train_dictionary(Enumerable.t(), keyword()) :: binary()
    def train_dictionary(samples, opts \\ []) when is_list(opts) do
      target_size = opts |> Keyword.get(:target_size, 32_768) |> max(512) |> min(131_072)
      chunk_size = opts |> Keyword.get(:chunk_size, 64) |> max(16) |> min(512)
      step = opts |> Keyword.get(:step, 16) |> max(4)
      max_samples = Keyword.get(opts, :max_samples, 2_000)

      sample_list =
        samples
        |> Stream.filter(&is_binary/1)
        |> Stream.filter(&(byte_size(&1) > 0))
        |> Enum.take(max_samples)

      if sample_list == [] do
        <<>>
      else
        counts = count_kmer_frequencies(sample_list, chunk_size, step)

        ranked_segments =
          counts
          |> Enum.filter(fn {_chunk, freq} -> freq >= 2 end)
          |> Enum.sort_by(fn {chunk, freq} -> {freq * byte_size(chunk), freq} end, :desc)

        selected = select_dictionary_segments(ranked_segments, target_size)

        if selected == <<>> do
          build_fallback_dictionary(sample_list, target_size)
        else
          selected
        end
      end
    end

    @doc """
    Stores `dict_bytes` immutably under `__dicts/<name>` inside `db` or an `Xitdb.Ash.Store`.
    """
    @spec put(Xitdb.t() | module(), atom() | String.t(), binary(), keyword()) ::
            {:ok, Xitdb.t()} | {:error, term()}
    def put(db_or_store, name, dict_bytes, tx_opts \\ [])

    def put(%Xitdb{} = db, name, dict_bytes, tx_opts)
        when (is_atom(name) or is_binary(name)) and is_binary(dict_bytes) do
      dict_name = to_string(name)
      Xitdb.transact_ops(db, [{:put, ["__dicts", dict_name], dict_bytes}], tx_opts)
    end

    def put(store, name, dict_bytes, tx_opts)
        when is_atom(store) and (is_atom(name) or is_binary(name)) and is_binary(dict_bytes) do
      if Code.ensure_loaded?(Xitdb.Ash.Store) do
        dict_name = to_string(name)

        Xitdb.Ash.Store.mutate(store, fn {db, moment} ->
          opts = Keyword.put(tx_opts, :base_moment, moment)

          case Xitdb.transact_ops_with_moment(
                 db,
                 [{:put, ["__dicts", dict_name], dict_bytes}],
                 opts
               ) do
            {:ok, next_db, next_moment} -> {:ok, {next_db, next_moment}, next_db}
            {:error, _} = err -> err
          end
        end)
      else
        {:error, %Xitdb.Error{reason: :invalid_options, details: %{store: store}}}
      end
    end

    @doc "Same as `put/4`, but raises `Xitdb.Error` on failure."
    @spec put!(Xitdb.t() | module(), atom() | String.t(), binary(), keyword()) :: Xitdb.t()
    def put!(db_or_store, name, dict_bytes, tx_opts \\ []) do
      put(db_or_store, name, dict_bytes, tx_opts) |> Xitdb.Error.unwrap!()
    end

    @doc """
    Fetches dictionary `name` from `.__dicts.<name>` in `db`, `%Xitdb.Cursor{}`, or `Xitdb.Ash.Store`.
    """
    @spec get(Xitdb.t() | Xitdb.Cursor.t() | module(), atom() | String.t()) :: binary() | nil
    def get(%Xitdb{} = db, name) when is_atom(name) or is_binary(name) do
      case Xitdb.select(db, ["__dicts", to_string(name)], raw_tagged: true) do
        {:ok, bin} when is_binary(bin) -> bin
        _ -> nil
      end
    end

    def get(%Xitdb.Cursor{} = cur, name) when is_atom(name) or is_binary(name) do
      case Xitdb.NIF.nif_select(cur.db_ref, cur.moment, ["__dicts", to_string(name)], true) do
        {:ok, bin} when is_binary(bin) -> bin
        _ -> nil
      end
    end

    def get(store, name) when is_atom(store) and (is_atom(name) or is_binary(name)) do
      if Code.ensure_loaded?(Xitdb.Ash.Store) do
        store |> Xitdb.Ash.Store.root() |> get(name)
      else
        nil
      end
    end

    @doc """
    Trains a shared dictionary from `samples` and persists it at `.__dicts.<name>` in `db`
    or an `Xitdb.Ash.Store`.
    """
    @spec train_and_put(Xitdb.t() | module(), atom() | String.t(), Enumerable.t(), keyword()) ::
            {:ok, Xitdb.t(), binary()} | {:error, term()}
    def train_and_put(db_or_store, name, samples, opts \\ []) do
      {tx_opts, train_opts} = Keyword.split(opts, [:doc, :instant, :meta, :base_moment])
      dict_bytes = train_dictionary(samples, train_opts)

      with {:ok, next_db} <- put(db_or_store, name, dict_bytes, tx_opts) do
        {:ok, next_db, dict_bytes}
      end
    end

    defp count_kmer_frequencies(samples, chunk_size, step) do
      Enum.reduce(samples, %{}, fn bin, acc ->
        len = byte_size(bin)

        eff_step =
          if len > 8_192 do
            max(step, div(len, 256))
          else
            step
          end

        count_windows_in_sample(bin, len, chunk_size, eff_step, acc)
      end)
    end

    defp count_windows_in_sample(_bin, len, chunk_size, _step, acc) when len < chunk_size do
      acc
    end

    defp count_windows_in_sample(bin, len, chunk_size, step, acc) do
      max_off = len - chunk_size
      do_count_windows(bin, 0, max_off, chunk_size, step, acc)
    end

    defp do_count_windows(_bin, off, max_off, _chunk_size, _step, acc) when off > max_off, do: acc

    defp do_count_windows(bin, off, max_off, chunk_size, step, acc) do
      chunk = :binary.part(bin, off, chunk_size)
      next_acc = Map.update(acc, chunk, 1, &(&1 + 1))
      do_count_windows(bin, off + step, max_off, chunk_size, step, next_acc)
    end

    defp select_dictionary_segments(ranked_segments, target_size) do
      {chosen_desc, _used, _seen} =
        Enum.reduce_while(ranked_segments, {[], 0, []}, fn {chunk, _freq}, {acc, used, seen} ->
          cond do
            used >= target_size ->
              {:halt, {acc, used, seen}}

            overlaps_existing?(chunk, seen) ->
              {:cont, {acc, used, seen}}

            used + byte_size(chunk) > target_size ->
              remaining = target_size - used

              if remaining >= 16 do
                trimmed = :binary.part(chunk, 0, remaining)
                {:halt, {[trimmed | acc], target_size, seen}}
              else
                {:halt, {acc, used, seen}}
              end

            true ->
              {:cont, {[chunk | acc], used + byte_size(chunk), [chunk | seen]}}
          end
        end)

      # Put lower-frequency selected chunks first and highest-frequency chunks last so
      # `:zstd` / `:zlib` sliding windows place hottest prefixes at distance ~0.
      IO.iodata_to_binary(chosen_desc)
    end

    defp overlaps_existing?(chunk, seen) do
      half = max(16, div(byte_size(chunk), 2))
      head_probe = :binary.part(chunk, 0, half)
      tail_probe = :binary.part(chunk, byte_size(chunk) - half, half)

      Enum.any?(Enum.take(seen, 64), fn existing ->
        :binary.match(existing, head_probe) != :nomatch and
          :binary.match(existing, tail_probe) != :nomatch
      end)
    end

    defp build_fallback_dictionary(samples, target_size) do
      {parts, _used} =
        Enum.reduce_while(samples, {[], 0}, fn sample, {acc, used} ->
          remaining = target_size - used

          if remaining <= 0 do
            {:halt, {acc, used}}
          else
            take = min(byte_size(sample), min(512, remaining))
            part = :binary.part(sample, 0, take)
            {:cont, {[part | acc], used + take}}
          end
        end)

      parts |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defdelegate train_dictionary(samples, opts \\ []), to: Dictionary
  defdelegate put_dictionary(db, name, dict_bytes, tx_opts \\ []), to: Dictionary, as: :put
  defdelegate put_dictionary!(db, name, dict_bytes, tx_opts \\ []), to: Dictionary, as: :put!
  defdelegate get_dictionary(target, name), to: Dictionary, as: :get

  defdelegate train_and_put_dictionary(db, name, samples, opts \\ []),
    to: Dictionary,
    as: :train_and_put

  # ============================================================================
  # Decode / Decompress Internals
  # ============================================================================

  defp do_resolve_tagged(@tag_zlib, payload, _db_ref, _moment, max_bytes, _opts, _depth) do
    with {:ok, raw_len, compressed} <- parse_simple_compressed_header(payload, @version_zlib) do
      decompress_block(:zlib, raw_len, compressed, nil, max_bytes, :corrupt_compressed_payload)
    end
  end

  defp do_resolve_tagged(@tag_zstd, payload, _db_ref, _moment, max_bytes, _opts, _depth) do
    with {:ok, raw_len, compressed} <- parse_simple_compressed_header(payload, @version_zstd) do
      decompress_block(:zstd, raw_len, compressed, nil, max_bytes, :corrupt_compressed_payload)
    end
  end

  defp do_resolve_tagged(@tag_dict, payload, db_ref, moment, max_bytes, opts, _depth) do
    case payload do
      <<ver_codec::8, raw_len::unsigned-little-32, dict_name_len::8,
        dict_name::binary-size(dict_name_len), compressed::binary>>
      when dict_name_len > 0 and ver_codec in [@version_dict_zstd, @version_dict_zlib] ->
        codec = if ver_codec == @version_dict_zstd, do: :zstd, else: :zlib

        with {:ok, dict_bytes} <-
               resolve_dict_for_read(opts[:dictionary_bytes], db_ref, moment, dict_name) do
          decompress_block(
            codec,
            raw_len,
            compressed,
            dict_bytes,
            max_bytes,
            :corrupt_compressed_payload
          )
        end

      _ ->
        {:error, %Error{reason: :corrupt_compressed_payload}}
    end
  end

  defp do_resolve_tagged(@tag_blob, payload, db_ref, moment, _max_bytes, opts, depth) do
    case payload do
      <<@version_blob::8, sha_raw::binary-size(32)>> ->
        if is_nil(db_ref) do
          {:error, %Error{reason: :missing_database_handle}}
        else
          sha_hex = Base.encode16(sha_raw, case: :lower)

          case NIF.nif_select(db_ref, moment, ["__blobs", sha_hex], true) do
            {:ok, bin} when is_binary(bin) ->
              {:ok, bin}

            {:ok, {:tagged, inner_tag, inner_payload}}
            when inner_tag in [@tag_zlib, @tag_zstd, @tag_dict] ->
              resolve_tagged(
                inner_tag,
                inner_payload,
                db_ref,
                moment,
                Keyword.put(opts, :_depth, depth + 1)
              )

            {:ok, nil} ->
              {:error, %Error{reason: :missing_interned_blob, details: %{sha256: sha_hex}}}

            {:error, reason} ->
              {:error, %Error{reason: reason}}

            _ ->
              {:error, %Error{reason: :corrupt_compressed_payload}}
          end
        end

      _ ->
        {:error, %Error{reason: :corrupt_compressed_payload}}
    end
  end

  defp do_resolve_tagged(@tag_page, payload, db_ref, moment, max_bytes, opts, _depth) do
    if is_nil(db_ref) do
      {:error, %Error{reason: :missing_database_handle}}
    else
      Xitdb.Columnar.read_pointer(
        payload,
        db_ref,
        moment,
        Keyword.put(opts, :max_decompressed_bytes, max_bytes)
      )
    end
  end

  defp parse_simple_compressed_header(
         <<hdr::8, raw_len::unsigned-little-32, rest::binary>>,
         expected_base
       )
       when (hdr &&& 0xFE) == expected_base and byte_size(rest) > 0 do
    {:ok, raw_len, rest}
  end

  defp parse_simple_compressed_header(_other, _expected_base) do
    {:error, %Error{reason: :corrupt_compressed_payload}}
  end

  defp resolve_dict_for_read(bin, _db_ref, _moment, _dict_name)
       when is_binary(bin) and byte_size(bin) > 0 do
    {:ok, bin}
  end

  defp resolve_dict_for_read(_nil, db_ref, moment, dict_name) do
    fetch_dictionary_bytes(db_ref, moment, dict_name)
  end

  defp encode_dict_tagged(raw, raw_len, :zstd, level, dict_name, dict_bytes) do
    if zstd_available?() do
      name_bin = to_string(dict_name)
      name_len = byte_size(name_bin)

      if name_len > 0 and name_len <= 255 do
        {:ok, cdict, _ddict} = get_or_build_zstd_dicts(dict_bytes)
        comp = compress_zstd_with_dict(raw, cdict, level)

        {@tag_dict,
         <<@version_dict_zstd::8, raw_len::unsigned-little-32, name_len::8, name_bin::binary,
           comp::binary>>}
      else
        nil
      end
    else
      encode_dict_tagged(raw, raw_len, :zlib, level, dict_name, dict_bytes)
    end
  end

  defp encode_dict_tagged(raw, raw_len, :zlib, level, dict_name, dict_bytes) do
    name_bin = to_string(dict_name)
    name_len = byte_size(name_bin)

    if name_len > 0 and name_len <= 255 do
      comp = compress_zlib_with_dict(raw, dict_bytes, level || 6)

      {@tag_dict,
       <<@version_dict_zlib::8, raw_len::unsigned-little-32, name_len::8, name_bin::binary,
         comp::binary>>}
    else
      nil
    end
  end

  defp normalize_codec(:zlib), do: :zlib
  defp normalize_codec(:zstd), do: if(zstd_available?(), do: :zstd, else: :zlib)

  defp normalize_codec(other) do
    raise ArgumentError,
          "unsupported compression codec: #{inspect(other)} (expected :zstd or :zlib)"
  end

  defp compress_zstd_raw(raw, nil), do: IO.iodata_to_binary(:zstd.compress(raw))

  defp compress_zstd_raw(raw, level) when is_integer(level) do
    IO.iodata_to_binary(:zstd.compress(raw, %{compressionLevel: level}))
  end

  defp compress_zstd_with_dict(raw, cdict, nil) do
    IO.iodata_to_binary(:zstd.compress(raw, %{dictionary: cdict}))
  end

  defp compress_zstd_with_dict(raw, cdict, level) when is_integer(level) do
    IO.iodata_to_binary(:zstd.compress(raw, %{dictionary: cdict, compressionLevel: level}))
  end

  defp compress_zlib_with_dict(raw, dict_bytes, level) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, level)
      _adler = :zlib.deflateSetDictionary(z, dict_bytes)
      IO.iodata_to_binary(:zlib.deflate(z, raw, :finish))
    after
      try do
        :zlib.deflateEnd(z)
      catch
        _, _ -> :ok
      end

      :zlib.close(z)
    end
  end

  defp safe_zlib_inflate(compressed, expected_len, max_bytes, dict_bytes, corrupt_reason) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      zlib_inflate_loop(z, compressed, dict_bytes, expected_len, max_bytes, corrupt_reason, [], 0)
    catch
      _, _ -> {:error, %Error{reason: corrupt_reason}}
    after
      try do
        :zlib.inflateEnd(z)
      catch
        _, _ -> :ok
      end

      try do
        :zlib.close(z)
      catch
        _, _ -> :ok
      end
    end
  end

  defp zlib_inflate_loop(
         z,
         input,
         dict_bytes,
         expected_len,
         max_bytes,
         corrupt_reason,
         acc,
         acc_len
       ) do
    case :zlib.safeInflate(z, input) do
      {:need_dictionary, _adler, out} ->
        out_len = IO.iodata_length(out)
        next_len = acc_len + out_len

        cond do
          next_len > max_bytes ->
            {:error, %Error{reason: :decompressed_size_exceeded}}

          next_len > expected_len ->
            {:error, %Error{reason: corrupt_reason}}

          is_binary(dict_bytes) and byte_size(dict_bytes) > 0 ->
            :ok = :zlib.inflateSetDictionary(z, dict_bytes)

            zlib_inflate_loop(
              z,
              [],
              nil,
              expected_len,
              max_bytes,
              corrupt_reason,
              [out | acc],
              next_len
            )

          true ->
            {:error, %Error{reason: :missing_compression_dictionary}}
        end

      {:continue, out} ->
        out_len = IO.iodata_length(out)
        next_len = acc_len + out_len

        cond do
          next_len > max_bytes ->
            {:error, %Error{reason: :decompressed_size_exceeded}}

          next_len > expected_len ->
            {:error, %Error{reason: corrupt_reason}}

          true ->
            zlib_inflate_loop(
              z,
              [],
              dict_bytes,
              expected_len,
              max_bytes,
              corrupt_reason,
              [out | acc],
              next_len
            )
        end

      {:finished, out} ->
        out_len = IO.iodata_length(out)
        final_len = acc_len + out_len

        cond do
          final_len > max_bytes ->
            {:error, %Error{reason: :decompressed_size_exceeded}}

          final_len != expected_len ->
            {:error, %Error{reason: corrupt_reason}}

          true ->
            bin = acc |> Enum.reverse([out]) |> IO.iodata_to_binary()
            {:ok, bin}
        end
    end
  end

  defp safe_zstd_decompress(compressed, expected_len, max_bytes, ddict, corrupt_reason) do
    case :zstd.get_frame_header(compressed) do
      {:ok, %{frameContentSize: fcs} = hdr}
      when is_integer(fcs) and fcs >= 0 ->
        win = Map.get(hdr, :windowSize)

        cond do
          fcs > max_bytes or (is_integer(win) and win > max_bytes) ->
            {:error, %Error{reason: :decompressed_size_exceeded}}

          fcs != expected_len ->
            {:error, %Error{reason: corrupt_reason}}

          true ->
            try do
              io =
                if is_nil(ddict) do
                  :zstd.decompress(compressed)
                else
                  :zstd.decompress(compressed, %{dictionary: ddict})
                end

              out = IO.iodata_to_binary(io)

              if byte_size(out) == expected_len do
                {:ok, out}
              else
                {:error, %Error{reason: corrupt_reason}}
              end
            rescue
              _ -> {:error, %Error{reason: corrupt_reason}}
            catch
              _, _ -> {:error, %Error{reason: corrupt_reason}}
            end
        end

      _ ->
        {:error, %Error{reason: corrupt_reason}}
    end
  end

  defp get_or_build_zstd_dicts(dict_bytes) do
    CacheOwner.ensure_started()
    key = :crypto.hash(:sha256, dict_bytes)

    case :ets.lookup(@dict_cache_table, key) do
      [{^key, cdict, ddict}] ->
        {:ok, cdict, ddict}

      [] ->
        {:ok, cdict} = :zstd.dict(:compress, dict_bytes)
        {:ok, ddict} = :zstd.dict(:decompress, dict_bytes)
        :ok = CacheOwner.put_dict(key, cdict, ddict, @dict_cache_limit)
        {:ok, cdict, ddict}
    end
  end

  # ============================================================================
  # Recursive Term Resolution Helpers
  # ============================================================================

  defp has_compressed_tag?({:tagged, tag, _bin}) when tag in @compression_tags, do: true

  defp has_compressed_tag?(list) when is_list(list) do
    Enum.any?(list, &has_compressed_tag?/1)
  end

  defp has_compressed_tag?(map) when is_map(map) and not is_struct(map) do
    has_compressed_tag_map?(:maps.iterator(map))
  end

  defp has_compressed_tag?({a, b}), do: has_compressed_tag?(a) or has_compressed_tag?(b)
  defp has_compressed_tag?(_), do: false

  defp has_compressed_tag_map?(iter) do
    case :maps.next(iter) do
      :none -> false
      {_k, v, next} -> has_compressed_tag?(v) or has_compressed_tag_map?(next)
    end
  end

  defp do_resolve_term({:tagged, tag, payload}, db_ref, moment, opts)
       when tag in @compression_tags and is_binary(payload) do
    resolve_tagged(tag, payload, db_ref, moment, opts)
  end

  defp do_resolve_term(list, db_ref, moment, opts) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn elem, {:ok, acc} ->
      case resolve_term(elem, db_ref, moment, opts) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, :lists.reverse(rev)}
      err -> err
    end
  end

  defp do_resolve_term(map, db_ref, moment, opts) when is_map(map) and not is_struct(map) do
    map
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      with {:ok, rk} <- resolve_term(k, db_ref, moment, opts),
           {:ok, rv} <- resolve_term(v, db_ref, moment, opts) do
        {:cont, {:ok, [{rk, rv} | acc]}}
      else
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, kvs} -> {:ok, Map.new(kvs)}
      err -> err
    end
  end

  defp do_resolve_term({a, b}, db_ref, moment, opts) do
    with {:ok, ra} <- resolve_term(a, db_ref, moment, opts),
         {:ok, rb} <- resolve_term(b, db_ref, moment, opts) do
      {:ok, {ra, rb}}
    end
  end

  defp do_resolve_term(other, _db_ref, _moment, _opts), do: {:ok, other}

  # ============================================================================
  # Pre-Write Compression & __blobs Interning Rewriter
  # ============================================================================

  defp has_compressed_directive?({:compressed, b}) when is_binary(b), do: true

  defp has_compressed_directive?({:compressed, b, o}) when is_binary(b) and is_list(o), do: true

  defp has_compressed_directive?({:put, _path, val}), do: has_compressed_directive?(val)
  defp has_compressed_directive?({:append, _path, val}), do: has_compressed_directive?(val)
  defp has_compressed_directive?({:insert, _path, _idx, val}), do: has_compressed_directive?(val)
  defp has_compressed_directive?({:merge_map, map}), do: has_compressed_directive?(map)

  defp has_compressed_directive?(list) when is_list(list) do
    Enum.any?(list, &has_compressed_directive?/1)
  end

  defp has_compressed_directive?(map) when is_map(map) and not is_struct(map) do
    has_compressed_directive_map?(:maps.iterator(map))
  end

  defp has_compressed_directive?(%Xitdb.Collection{kind: kind, data: data})
       when kind in [:hash_map, :counted_hash_map, :sorted_map, :array_list, :linked_array_list],
       do: has_compressed_directive?(data)

  defp has_compressed_directive?({k, v}),
    do: has_compressed_directive?(k) or has_compressed_directive?(v)

  defp has_compressed_directive?(_), do: false

  defp has_compressed_directive_map?(iter) do
    case :maps.next(iter) do
      :none -> false
      {_k, v, next} -> has_compressed_directive?(v) or has_compressed_directive_map?(next)
    end
  end

  defp normalize_compress_opts(true), do: []
  defp normalize_compress_opts(opts) when is_list(opts), do: opts
  defp normalize_compress_opts(_), do: []

  defp prepare_node({:compressed, bin}, db_or_cursor, default_opts, _auto?, _skip_auto?, state)
       when is_binary(bin) do
    {val, ops, next_state} = compress_for_write(db_or_cursor, bin, default_opts, state)
    {val, prepend_blob_ops(next_state, ops)}
  end

  defp prepare_node(
         {:compressed, bin, item_opts},
         db_or_cursor,
         default_opts,
         _auto?,
         _skip_auto?,
         state
       )
       when is_binary(bin) and is_list(item_opts) do
    merged = Keyword.merge(default_opts, item_opts)
    {val, ops, next_state} = compress_for_write(db_or_cursor, bin, merged, state)
    {val, prepend_blob_ops(next_state, ops)}
  end

  defp prepare_node({:merge_map, map}, db_or_cursor, default_opts, auto?, skip_auto?, state)
       when is_map(map) do
    {next_map, next_state} =
      prepare_map(map, db_or_cursor, default_opts, auto?, skip_auto?, state)

    {{:merge_map, next_map}, next_state}
  end

  defp prepare_node({:put, path, val}, db_or_cursor, default_opts, auto?, _skip_auto?, state) do
    skip_path? = skip_auto_for_path?(path)

    {next_val, next_state} =
      prepare_node(val, db_or_cursor, default_opts, auto?, skip_path?, state)

    {{:put, path, next_val}, next_state}
  end

  defp prepare_node({:append, path, val}, db_or_cursor, default_opts, auto?, _skip_auto?, state) do
    skip_path? = skip_auto_for_path?(path)

    {next_val, next_state} =
      prepare_node(val, db_or_cursor, default_opts, auto?, skip_path?, state)

    {{:append, path, next_val}, next_state}
  end

  defp prepare_node(
         {:insert, path, idx, val},
         db_or_cursor,
         default_opts,
         auto?,
         _skip_auto?,
         state
       ) do
    skip_path? = skip_auto_for_path?(path)

    {next_val, next_state} =
      prepare_node(val, db_or_cursor, default_opts, auto?, skip_path?, state)

    {{:insert, path, idx, next_val}, next_state}
  end

  defp prepare_node(
         %Xitdb.Collection{kind: kind, data: data} = col,
         db_or_cursor,
         default_opts,
         auto?,
         skip_auto?,
         state
       )
       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    {next_data, next_state} =
      if is_map(data) and not is_struct(data) do
        prepare_map(data, db_or_cursor, default_opts, auto?, skip_auto?, state)
      else
        prepare_kv_list(Enum.to_list(data), db_or_cursor, default_opts, auto?, skip_auto?, state)
      end

    {%Xitdb.Collection{col | data: next_data}, next_state}
  end

  defp prepare_node(
         %Xitdb.Collection{kind: kind, data: data} = col,
         db_or_cursor,
         default_opts,
         auto?,
         skip_auto?,
         state
       )
       when kind in [:array_list, :linked_array_list] and is_list(data) do
    {next_data, next_state} =
      prepare_list(data, db_or_cursor, default_opts, auto?, skip_auto?, state)

    {%Xitdb.Collection{col | data: next_data}, next_state}
  end

  defp prepare_node(bin, db_or_cursor, default_opts, true, false, state) when is_binary(bin) do
    {val, ops, next_state} = compress_for_write(db_or_cursor, bin, default_opts, state)
    {val, prepend_blob_ops(next_state, ops)}
  end

  defp prepare_node(map, db_or_cursor, default_opts, auto?, skip_auto?, state)
       when is_map(map) and not is_struct(map) do
    prepare_map(map, db_or_cursor, default_opts, auto?, skip_auto?, state)
  end

  defp prepare_node(list, db_or_cursor, default_opts, auto?, skip_auto?, state)
       when is_list(list) do
    prepare_list(list, db_or_cursor, default_opts, auto?, skip_auto?, state)
  end

  defp prepare_node(other, _db_or_cursor, _default_opts, _auto?, _skip_auto?, state),
    do: {other, state}

  defp prepare_map(map, db_or_cursor, default_opts, auto?, skip_auto?, state) do
    {pairs_rev, next_state} =
      Enum.reduce(map, {[], state}, fn {k, v}, {acc, st} ->
        child_skip? = skip_auto? or internal_root_key?(k)
        {nv, nst} = prepare_node(v, db_or_cursor, default_opts, auto?, child_skip?, st)
        {[{k, nv} | acc], nst}
      end)

    {Map.new(pairs_rev), next_state}
  end

  defp prepare_list(list, db_or_cursor, default_opts, auto?, skip_auto?, state) do
    {items_rev, next_state} =
      Enum.reduce(list, {[], state}, fn item, {acc, st} ->
        {ni, nst} = prepare_node(item, db_or_cursor, default_opts, auto?, skip_auto?, st)
        {[ni | acc], nst}
      end)

    {:lists.reverse(items_rev), next_state}
  end

  defp prepare_kv_list(list, db_or_cursor, default_opts, auto?, skip_auto?, state) do
    {items_rev, next_state} =
      Enum.reduce(list, {[], state}, fn
        {k, v}, {acc, st} ->
          child_skip? = skip_auto? or internal_root_key?(k)
          {nv, nst} = prepare_node(v, db_or_cursor, default_opts, auto?, child_skip?, st)
          {[{k, nv} | acc], nst}

        other, {acc, st} ->
          {ni, nst} = prepare_node(other, db_or_cursor, default_opts, auto?, skip_auto?, st)
          {[ni | acc], nst}
      end)

    {:lists.reverse(items_rev), next_state}
  end

  defp skip_auto_for_path?(sel) when is_binary(sel) do
    case Selector.parse_selector_steps(sel, false) do
      [{_, first} | _] -> internal_root_key?(first)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp skip_auto_for_path?([{:at_moment, _}, step | _]), do: step_is_internal?(step)
  defp skip_auto_for_path?([step | _]), do: step_is_internal?(step)
  defp skip_auto_for_path?(_), do: false

  defp step_is_internal?({_kind, k}), do: internal_root_key?(k)
  defp step_is_internal?(k), do: internal_root_key?(k)

  defp internal_root_key?(k) when is_binary(k), do: MapSet.member?(@internal_roots, k)

  defp internal_root_key?(k) when is_atom(k),
    do: MapSet.member?(@internal_roots, Atom.to_string(k))

  defp internal_root_key?(_), do: false

  defp resolve_dict_for_write(_db, _dict_name, dict_bytes, state)
       when is_binary(dict_bytes) and byte_size(dict_bytes) > 0 do
    {dict_bytes, state}
  end

  defp resolve_dict_for_write(_db, nil, _dict_bytes, state), do: {nil, state}

  defp resolve_dict_for_write(nil, _dict_name, _dict_bytes, state), do: {nil, state}

  defp resolve_dict_for_write(db_or_cursor, dict_name, _dict_bytes, state) do
    name_str = to_string(dict_name)

    case Map.fetch(state.dicts, name_str) do
      {:ok, cached} ->
        {cached, state}

      :error ->
        fetched = fetch_dict_from_target(db_or_cursor, name_str)
        {fetched, %{state | dicts: Map.put(state.dicts, name_str, fetched)}}
    end
  end

  defp fetch_dict_from_target(%Xitdb{} = db, name_str), do: Dictionary.get(db, name_str)
  defp fetch_dict_from_target(%Xitdb.Cursor{} = cur, name_str), do: Dictionary.get(cur, name_str)

  defp fetch_dict_from_target({%Xitdb{} = db, moment}, name_str) do
    case NIF.nif_select(db.db_ref, moment, ["__dicts", name_str], true) do
      {:ok, bin} when is_binary(bin) -> bin
      _ -> nil
    end
  end

  defp maybe_stage_blob_put(db_or_cursor, sha_hex, raw, comp_opts, state) do
    if Map.has_key?(state.seen_blobs, sha_hex) do
      {[], state}
    else
      {blobs_cur, state} = ensure_blobs_cursor(db_or_cursor, state)
      exists? = blobs_cur != nil and blobs_cur[sha_hex] != nil

      next_state = %{state | seen_blobs: Map.put(state.seen_blobs, sha_hex, true)}

      if exists? do
        {[], next_state}
      else
        stored_val = compress(raw, comp_opts)
        {[{:put, ["__blobs", sha_hex], stored_val}], next_state}
      end
    end
  end

  defp ensure_blobs_cursor(nil, state), do: {nil, state}

  defp ensure_blobs_cursor(_db, %{existing_blobs: cur} = state) when cur != :unloaded do
    {cur, state}
  end

  defp ensure_blobs_cursor(target, state) do
    cur =
      case target do
        %Xitdb{} = db -> Xitdb.db(db)["__blobs"]
        %Xitdb.Cursor{} = c -> c["__blobs"]
        {%Xitdb{} = db, moment} -> Xitdb.as_of(db, moment)["__blobs"]
      end

    {cur, %{state | existing_blobs: cur}}
  rescue
    _ -> {nil, %{state | existing_blobs: nil}}
  end

  defp prepend_blob_ops(state, []), do: state

  defp prepend_blob_ops(%{blob_ops_rev: rev} = state, ops) do
    %{state | blob_ops_rev: :lists.reverse(ops, rev)}
  end
end
