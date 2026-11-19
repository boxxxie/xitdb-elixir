defmodule Xitdb.Key do
  @moduledoc """
  Public order-preserving binary key encoders and `:sorted_map` B+Tree range scanner.

  Because `Xitdb` `:sorted_map` B+Trees sort string/binary keys in unsigned byte
  (lexicographical) order, signed integers, full unsigned 64-bit integers (`u64`),
  IEEE-754 floats, arbitrary-precision `Decimal` values, and 64-bit fixed-point decimals
  must be encoded into canonical byte strings that preserve `<, <=, ==, >=, >`.
  """

  alias Xitdb.{Cursor, Error, NIF}

  @min_i64 -9_223_372_036_854_775_808
  @max_i64 9_223_372_036_854_775_807
  @max_u64 18_446_744_073_709_551_615

  @doc """
  Encodes a signed 64-bit integer into an 8-byte sign-flipped big-endian binary
  preserving `<, <=, ==, >=, >` under unsigned byte comparison.
  """
  @spec encode_i64_be(integer()) :: <<_::64>>
  def encode_i64_be(val)
      when is_integer(val) and val >= @min_i64 and val <= @max_i64 do
    <<msb::unsigned-8, rest::binary-size(7)>> = <<val::signed-big-64>>
    <<Bitwise.bxor(msb, 0x80)::unsigned-8, rest::binary>>
  end

  @doc """
  Decodes an 8-byte sign-flipped big-endian binary back into a signed 64-bit integer.
  """
  @spec decode_i64_be(<<_::64>>) :: integer()
  def decode_i64_be(<<msb::unsigned-8, rest::binary-size(7)>>) do
    <<val::signed-big-64>> = <<Bitwise.bxor(msb, 0x80)::unsigned-8, rest::binary>>
    val
  end

  @doc """
  Encodes a full unsigned 64-bit integer (`0..18_446_744_073_709_551_615`, including
  values exceeding `max(i64)`) into an 8-byte big-endian binary preserving `<, <=, ==, >=, >`.
  """
  @spec encode_u64_be(non_neg_integer()) :: <<_::64>>
  def encode_u64_be(val) when is_integer(val) and val >= 0 and val <= @max_u64 do
    <<val::unsigned-big-64>>
  end

  @doc """
  Decodes an 8-byte unsigned big-endian binary back into an unsigned 64-bit integer.
  """
  @spec decode_u64_be(<<_::64>>) :: non_neg_integer()
  def decode_u64_be(<<val::unsigned-big-64>>), do: val

  @doc """
  Encodes an IEEE-754 float into an 8-byte order-preserving binary (`-0.0` normalized to `+0.0`).
  """
  @spec encode_f64_be(float()) :: <<_::64>>
  def encode_f64_be(val) when is_float(val) do
    normalized = if val == 0.0, do: +0.0, else: val
    <<b0::8, b1::8, b2::8, b3::8, b4::8, b5::8, b6::8, b7::8>> = <<normalized::float-big-64>>

    if Bitwise.band(b0, 0x80) == 0 do
      <<Bitwise.bxor(b0, 0x80)::8, b1::8, b2::8, b3::8, b4::8, b5::8, b6::8, b7::8>>
    else
      <<
        Bitwise.bxor(b0, 0xFF)::8,
        Bitwise.bxor(b1, 0xFF)::8,
        Bitwise.bxor(b2, 0xFF)::8,
        Bitwise.bxor(b3, 0xFF)::8,
        Bitwise.bxor(b4, 0xFF)::8,
        Bitwise.bxor(b5, 0xFF)::8,
        Bitwise.bxor(b6, 0xFF)::8,
        Bitwise.bxor(b7, 0xFF)::8
      >>
    end
  end

  if Code.ensure_loaded?(Decimal) do
    @doc """
    Encodes a `Decimal` into a canonical, scale-normalized (`60 == 60.0 == 60.000`)
    order-preserving binary. Computes `exp10 = length(raw_digits) + dec.exp` *before*
    stripping trailing zeros so integer multiples of 10 retain their true magnitude.
    """
    @spec encode_decimal_key(Decimal.t()) :: binary()
    def encode_decimal_key(%Decimal{coef: coef}) when coef in [:NaN, :inf] do
      raise ArgumentError, "cannot index non-finite Decimal #{inspect(coef)} in Xitdb B+Tree"
    end

    def encode_decimal_key(%Decimal{coef: 0}), do: <<0x80>>

    def encode_decimal_key(%Decimal{} = dec) do
      if Decimal.eq?(dec, 0) do
        <<0x80>>
      else
        raw_digits = Integer.digits(dec.coef)
        exp10 = length(raw_digits) + dec.exp
        digits = strip_trailing_zeros(raw_digits)

        case dec.sign do
          1 ->
            exp_bin = encode_i64_be(exp10)
            mantissa = for d <- digits, into: <<>>, do: <<d + 1::unsigned-8>>
            <<0xC0, exp_bin::binary, mantissa::binary, 0x00>>

          -1 ->
            exp_bin = invert_bytes(encode_i64_be(exp10))
            mantissa = for d <- digits, into: <<>>, do: <<10 - d::unsigned-8>>
            <<0x40, exp_bin::binary, mantissa::binary, 0xFF>>
        end
      end
    end

    defp strip_trailing_zeros([0]), do: [0]

    defp strip_trailing_zeros(digits) do
      digits
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == 0))
      |> Enum.reverse()
    end

    defp invert_bytes(bin) do
      for <<b::unsigned-8 <- bin>>, into: <<>>, do: <<Bitwise.bxor(b, 0xFF)::unsigned-8>>
    end
  end

  @doc """
  Encodes a 64-bit fixed-point decimal (such as Bragi `Decimal_64`) into an 8-byte
  order-preserving key.

  Accepts:
  - unscaled `integer()` (`val * scale`, aligning `12` with `Decimal.new("12.0000")`)
  - `{:scaled, raw_int}` (already scaled 64-bit integer)
  - `%Decimal{}` (scaled by `scale`, raising if fractional precision would be lost)

  ## Options
  - `:scale` — positive integer power of 10 (default: `10_000`)
  - `:signed?` — signed `i64` vs unsigned `u64` storage (default: `true`)
  """
  @spec encode_fixed_decimal64_be(integer() | {:scaled, integer()} | struct(), keyword()) ::
          <<_::64>>
  def encode_fixed_decimal64_be(value, opts \\ []) when is_list(opts) do
    {scale, _exp} = validate_scale!(Keyword.get(opts, :scale, 10_000))
    signed? = validate_signed!(Keyword.get(opts, :signed?, true))
    scaled_int = to_scaled_fixed_int!(value, scale)

    if signed? do
      if scaled_int < @min_i64 or scaled_int > @max_i64 do
        raise ArgumentError,
              "FixedDecimal64 value #{inspect(value)} (scaled #{scaled_int}) exceeds signed 64-bit bounds"
      end

      encode_i64_be(scaled_int)
    else
      if scaled_int < 0 or scaled_int > @max_u64 do
        raise ArgumentError,
              "FixedDecimal64 value #{inspect(value)} (scaled #{scaled_int}) exceeds unsigned 64-bit bounds"
      end

      encode_u64_be(scaled_int)
    end
  end

  @doc """
  Decodes an 8-byte `encode_fixed_decimal64_be/2` binary back into a `%Decimal{}`
  (or `{:scaled, int}` when `as: :scaled` is passed or `Decimal` is unavailable).
  """
  @spec decode_fixed_decimal64_be(<<_::64>>, keyword()) :: struct() | {:scaled, integer()}
  def decode_fixed_decimal64_be(<<_::64>> = bin, opts \\ []) when is_list(opts) do
    {scale, exp} = validate_scale!(Keyword.get(opts, :scale, 10_000))
    signed? = validate_signed!(Keyword.get(opts, :signed?, true))
    scaled_int = if signed?, do: decode_i64_be(bin), else: decode_u64_be(bin)
    _ = scale

    if Keyword.get(opts, :as) == :scaled or not Code.ensure_loaded?(Decimal) do
      {:scaled, scaled_int}
    else
      if scaled_int < 0 do
        apply(Decimal, :new, [-1, -scaled_int, -exp])
      else
        apply(Decimal, :new, [1, scaled_int, -exp])
      end
    end
  end

  @doc """
  Lazily streams `{key, value}` entries from a `:sorted_map` `%Xitdb.Cursor{}` across
  a bounded lexicographical range using `Xitdb.NIF.nif_sorted_map_seek/7` in `O(log N + K)`.

  Child containers are returned as lazy `%Xitdb.Cursor{}` structs.

  ## Options
  - `:prefix` — binary key prefix that all emitted keys must start with
  - `:min` — minimum binary key bound
  - `:min_inclusive?` — whether `:min` is inclusive (default: `true`)
  - `:max` — maximum binary key bound
  - `:max_inclusive?` — whether `:max` is inclusive (default: `true`)
  - `:page_size` — B+Tree seek batch size per NIF crossing (default: `64`)
  """
  @spec stream_range(Cursor.t(), keyword()) :: Enumerable.t()
  def stream_range(%Cursor{} = cursor, opts \\ []) when is_list(opts) do
    resolved = Cursor.ensure_resolved(cursor)

    if resolved.tag != :sorted_map do
      raise ArgumentError,
            "Xitdb.Key.stream_range/2 requires a :sorted_map cursor, got #{inspect(resolved.tag)}"
    end

    prefix = Keyword.get(opts, :prefix)
    min_key = Keyword.get(opts, :min)
    min_inc? = Keyword.get(opts, :min_inclusive?, true)
    max_key = Keyword.get(opts, :max)
    max_inc? = Keyword.get(opts, :max_inclusive?, true)
    page_size = Keyword.get(opts, :page_size, 64)

    if not (is_nil(prefix) or is_binary(prefix)) do
      raise ArgumentError, "expected :prefix to be a binary or nil, got: #{inspect(prefix)}"
    end

    if not (is_nil(min_key) or is_binary(min_key)) do
      raise ArgumentError, "expected :min to be a binary or nil, got: #{inspect(min_key)}"
    end

    if not (is_nil(max_key) or is_binary(max_key)) do
      raise ArgumentError, "expected :max to be a binary or nil, got: #{inspect(max_key)}"
    end

    if not (is_integer(page_size) and page_size > 0) do
      raise ArgumentError,
            "expected :page_size to be a positive integer, got: #{inspect(page_size)}"
    end

    start_key =
      cond do
        is_binary(min_key) and is_binary(prefix) -> max(min_key, prefix)
        is_binary(min_key) -> min_key
        is_binary(prefix) -> prefix
        true -> <<>>
      end

    Stream.unfold(start_key, fn
      nil ->
        nil

      cur_key ->
        case NIF.nif_sorted_map_seek(
               resolved.db_ref,
               resolved.tag_id,
               resolved.value,
               cur_key,
               page_size,
               false,
               false
             ) do
          {:ok, [], _next} ->
            nil

          {:ok, chunk, next_cursor} ->
            next_state =
              if next_cursor != nil and
                   within_upper_bound?(next_cursor, prefix, max_key, max_inc?) do
                next_cursor
              else
                nil
              end

            {chunk, next_state}

          {:error, reason} ->
            raise Error, reason: reason
        end
    end)
    |> Stream.flat_map(& &1)
    |> Stream.take_while(fn entry ->
      within_upper_bound?(elem(entry, 0), prefix, max_key, max_inc?)
    end)
    |> Stream.filter(fn entry ->
      min_satisfied?(elem(entry, 0), min_key, min_inc?)
    end)
    |> Stream.map(&unwrap_seek_entry(&1, resolved))
  end

  defp unwrap_seek_entry({key, tag_id, val}, resolved)
       when is_integer(tag_id) and is_integer(val) do
    {key, Cursor.from_compact_slot(resolved.db_ref, tag_id, val, resolved.moment)}
  end

  defp unwrap_seek_entry({key, raw_val}, resolved) do
    {key, Cursor.unwrap_nif_value(resolved.db_ref, raw_val, resolved.moment, [])}
  end

  defp min_satisfied?(_key, nil, _inc?), do: true
  defp min_satisfied?(key, min_key, true), do: key >= min_key
  defp min_satisfied?(key, min_key, false), do: key > min_key

  defp within_upper_bound?(key, prefix, max_key, max_inc?) do
    prefix_ok? =
      case prefix do
        nil -> true
        <<>> -> is_binary(key)
        p -> binary_starts_with?(key, p)
      end

    max_ok? =
      case {max_key, max_inc?} do
        {nil, _} -> true
        {m, true} -> key <= m
        {m, false} -> key < m
      end

    prefix_ok? and max_ok?
  end

  defp binary_starts_with?(bin, prefix) when is_binary(bin) and is_binary(prefix) do
    plen = byte_size(prefix)

    case bin do
      <<^prefix::binary-size(^plen), _rest::binary>> -> true
      _ -> false
    end
  end

  @doc false
  @spec validate_scale!(term()) :: {pos_integer(), non_neg_integer()}
  def validate_scale!(scale) when is_integer(scale) and scale > 0 do
    case power_of_ten_exp(scale, 0) do
      {:ok, exp} ->
        {scale, exp}

      :error ->
        raise ArgumentError,
              "FixedDecimal64 :scale must be a positive integer power of 10, got: #{inspect(scale)}"
    end
  end

  def validate_scale!(scale) do
    raise ArgumentError,
          "FixedDecimal64 :scale must be a positive integer power of 10, got: #{inspect(scale)}"
  end

  defp power_of_ten_exp(1, exp), do: {:ok, exp}

  defp power_of_ten_exp(n, exp) when n > 1 and rem(n, 10) == 0 do
    power_of_ten_exp(div(n, 10), exp + 1)
  end

  defp power_of_ten_exp(_n, _exp), do: :error

  defp validate_signed!(signed?) when is_boolean(signed?), do: signed?

  defp validate_signed!(other) do
    raise ArgumentError, "expected :signed? to be a boolean, got: #{inspect(other)}"
  end

  defp to_scaled_fixed_int!({:scaled, raw}, _scale) when is_integer(raw), do: raw
  defp to_scaled_fixed_int!(val, scale) when is_integer(val), do: val * scale

  if Code.ensure_loaded?(Decimal) do
    defp to_scaled_fixed_int!(%Decimal{coef: coef}, _scale) when coef in [:NaN, :inf] do
      raise ArgumentError, "cannot encode non-finite Decimal #{inspect(coef)} as FixedDecimal64"
    end

    defp to_scaled_fixed_int!(%Decimal{} = dec, scale) do
      scaled = Decimal.mult(dec, scale)
      rounded = Decimal.round(scaled, 0)

      if Decimal.equal?(scaled, rounded) do
        Decimal.to_integer(rounded)
      else
        raise ArgumentError,
              "Decimal #{Decimal.to_string(dec)} exceeds FixedDecimal64 scale #{scale}"
      end
    end
  end

  defp to_scaled_fixed_int!(other, _scale) do
    raise ArgumentError,
          "expected integer, {:scaled, integer}, or %Decimal{} for FixedDecimal64, got: #{inspect(other)}"
  end
end
