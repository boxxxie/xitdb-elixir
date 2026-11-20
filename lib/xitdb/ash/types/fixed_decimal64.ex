if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Types.FixedDecimal64 do
    @moduledoc """
    Ash type for fixed-scale 64-bit decimals (such as Bragi's `Decimal_64` with default
    `scale: 10_000`).

    Values expose `%Decimal{}` at runtime in Elixir while storing compact 64-bit scaled
    integers inside `Xitdb`:
    - `representation: :integer` *(default)*: stores native `Xitdb` integer slots when the
      scaled value fits in `i64`, or `{:tagged, "u8", <<val::unsigned-big-64>>}` when
      `signed?: false` and the scaled value exceeds `max(i64)`.
    - `representation: :tagged`: stores `{:tagged, "d6", <<val::signed-big-64>>}` (or
      `<<val::unsigned-big-64>>` when `signed?: false`) to preserve domain type tagging on disk.

    Secondary indexes use `Xitdb.Key.encode_fixed_decimal64_be/2` (fixed 8-byte keys) so
    `<, <=, ==, >=, >` Ash queries execute via exact B+Tree range seeks regardless of
    `representation` or `signed?`.
    """

    use Ash.Type

    alias Xitdb.Key

    @min_i64 -9_223_372_036_854_775_808
    @max_i64 9_223_372_036_854_775_807
    @max_u64 18_446_744_073_709_551_615

    @constraints [
      scale: [
        type: {:custom, __MODULE__, :validate_scale, []},
        default: 10_000,
        doc: "Positive integer power-of-10 scale factor (default: `10_000`)."
      ],
      signed?: [
        type: :boolean,
        default: true,
        doc:
          "Whether scaled storage uses signed 64-bit (`true`) or full unsigned `u64` (`false`)."
      ],
      representation: [
        type: {:one_of, [:integer, :tagged]},
        default: :integer,
        doc: "Storage slot encoding: `:integer` (native slot/`\"u8\"`) or `:tagged` (`\"d6\"`)."
      ]
    ]

    @doc false
    @spec validate_scale(term()) :: {:ok, pos_integer()} | {:error, String.t()}
    def validate_scale(scale) do
      {valid_scale, _exp} = Key.validate_scale!(scale)
      {:ok, valid_scale}
    rescue
      e in ArgumentError -> {:error, e.message}
    end

    @impl true
    def constraints, do: @constraints

    @impl true
    def init(constraints) do
      scale = Keyword.get(constraints, :scale, 10_000)
      signed? = Keyword.get(constraints, :signed?, true)
      representation = Keyword.get(constraints, :representation, :integer)

      with {:ok, valid_scale} <- validate_scale(scale),
           true <- is_boolean(signed?),
           true <- representation in [:integer, :tagged] do
        {:ok, [scale: valid_scale, signed?: signed?, representation: representation]}
      else
        {:error, msg} -> {:error, msg}
        false -> {:error, "invalid FixedDecimal64 constraints: #{inspect(constraints)}"}
      end
    end

    @impl true
    def storage_type(_constraints), do: :decimal

    @impl true
    def matches_type?(%Decimal{}, _constraints), do: true
    def matches_type?(_val, _constraints), do: false

    @impl true
    def simple_equality?, do: false

    @impl true
    def equal?(nil, nil), do: true
    def equal?(nil, _), do: false
    def equal?(_, nil), do: false
    def equal?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
    def equal?(a, b), do: a == b

    @impl true
    def cast_atomic(expr, _constraints), do: {:atomic, expr}

    @doc """
    Converts a `%Decimal{}`, unscaled integer, or `{:scaled, int}` to a scaled 64-bit integer
    according to `:scale` (default `10_000`) and `:signed?` (default `true`).
    """
    @spec to_scaled(Decimal.t() | integer() | {:scaled, integer()}, keyword()) :: integer()
    def to_scaled(value, opts \\ []) when is_list(opts) do
      {scale, _exp} = Key.validate_scale!(Keyword.get(opts, :scale, 10_000))
      signed? = Keyword.get(opts, :signed?, true)

      case do_to_scaled(value, scale, signed?) do
        {:ok, scaled} ->
          scaled

        {:error, reason} ->
          raise ArgumentError,
                "invalid FixedDecimal64 value #{inspect(value)}: #{inspect(reason)}"
      end
    end

    @doc """
    Converts a scaled 64-bit integer back into a `%Decimal{}` using `scale` (default `10_000`).
    """
    @spec from_scaled(integer(), pos_integer()) :: Decimal.t()
    def from_scaled(scaled_int, scale \\ 10_000) when is_integer(scaled_int) do
      {_scale, exp} = Key.validate_scale!(scale)

      if scaled_int < 0 do
        Decimal.new(-1, -scaled_int, -exp)
      else
        Decimal.new(1, scaled_int, -exp)
      end
    end

    @impl true
    def cast_input(nil, _constraints), do: {:ok, nil}

    def cast_input(value, constraints) do
      {scale, signed?, _rep} = extract_opts(constraints)

      with {:ok, dec} <- coerce_to_decimal(value, scale),
           {:ok, _scaled} <- do_to_scaled(dec, scale, signed?) do
        {:ok, dec}
      else
        _ -> :error
      end
    end

    @impl true
    def cast_stored(nil, _constraints), do: {:ok, nil}

    def cast_stored(raw, constraints) do
      {scale, signed?, _rep} = extract_opts(constraints)

      case raw do
        int when is_integer(int) ->
          if in_bounds?(int, signed?), do: {:ok, from_scaled(int, scale)}, else: :error

        {:tagged, "u8", <<u::unsigned-big-64>>} ->
          if not signed? or u <= @max_i64, do: {:ok, from_scaled(u, scale)}, else: :error

        {:tagged, "d6", <<i::signed-big-64>>} when signed? ->
          {:ok, from_scaled(i, scale)}

        {:tagged, "d6", <<u::unsigned-big-64>>} when not signed? ->
          {:ok, from_scaled(u, scale)}

        %Decimal{} = dec ->
          with {:ok, _} <- do_to_scaled(dec, scale, signed?), do: {:ok, dec}, else: (_ -> :error)

        bin when is_binary(bin) ->
          with {:ok, dec} <- parse_decimal_string(bin),
               {:ok, _} <- do_to_scaled(dec, scale, signed?) do
            {:ok, dec}
          else
            _ -> :error
          end

        _other ->
          :error
      end
    end

    @impl true
    def dump_to_native(nil, _constraints), do: {:ok, nil}

    def dump_to_native(value, constraints) do
      {scale, signed?, representation} = extract_opts(constraints)

      with {:ok, scaled} <- do_to_scaled(value, scale, signed?) do
        case representation do
          :integer when scaled >= @min_i64 and scaled <= @max_i64 ->
            {:ok, scaled}

          :integer when not signed? and scaled > @max_i64 and scaled <= @max_u64 ->
            {:ok, {:tagged, "u8", <<scaled::unsigned-big-64>>}}

          :tagged when signed? ->
            {:ok, {:tagged, "d6", <<scaled::signed-big-64>>}}

          :tagged when not signed? ->
            {:ok, {:tagged, "d6", <<scaled::unsigned-big-64>>}}

          _ ->
            :error
        end
      else
        _ -> :error
      end
    end

    @doc """
    Encodes a `FixedDecimal64` value (or its stored `{:tagged, ...}` tuple) into an 8-byte
    order-preserving B+Tree index key.
    """
    @spec xitdb_index_key(term(), keyword()) :: <<_::64>>
    def xitdb_index_key(value, constraints) do
      {scale, signed?, _rep} = extract_opts(constraints)

      unwrapped =
        case value do
          {:tagged, "u8", <<u::unsigned-big-64>>} -> {:scaled, u}
          {:tagged, "d6", <<i::signed-big-64>>} when signed? -> {:scaled, i}
          {:tagged, "d6", <<u::unsigned-big-64>>} when not signed? -> {:scaled, u}
          other -> other
        end

      Key.encode_fixed_decimal64_be(unwrapped, scale: scale, signed?: signed?)
    end

    @doc "Marks `FixedDecimal64` index keys as fixed 8-byte width for composite indexes."
    @spec xitdb_fixed_width?(keyword()) :: true
    def xitdb_fixed_width?(_constraints), do: true

    defp extract_opts(constraints) do
      c = constraints || []
      scale = Keyword.get(c, :scale, 10_000)
      signed? = Keyword.get(c, :signed?, true)
      rep = Keyword.get(c, :representation, :integer)
      {scale, signed?, rep}
    end

    defp coerce_to_decimal(%Decimal{} = dec, _scale), do: {:ok, dec}

    defp coerce_to_decimal({:scaled, raw}, scale) when is_integer(raw),
      do: {:ok, from_scaled(raw, scale)}

    defp coerce_to_decimal(int, _scale) when is_integer(int), do: {:ok, Decimal.new(int)}
    defp coerce_to_decimal(f, _scale) when is_float(f), do: {:ok, Decimal.from_float(f)}
    defp coerce_to_decimal(bin, _scale) when is_binary(bin), do: parse_decimal_string(bin)
    defp coerce_to_decimal(_other, _scale), do: :error

    defp parse_decimal_string(bin) do
      case Decimal.parse(bin) do
        {dec, ""} -> {:ok, dec}
        _ -> :error
      end
    end

    defp do_to_scaled({:scaled, raw}, _scale, signed?) when is_integer(raw) do
      if in_bounds?(raw, signed?), do: {:ok, raw}, else: {:error, :out_of_bounds}
    end

    defp do_to_scaled(int, scale, signed?) when is_integer(int) do
      scaled = int * scale
      if in_bounds?(scaled, signed?), do: {:ok, scaled}, else: {:error, :out_of_bounds}
    end

    defp do_to_scaled(%Decimal{coef: coef}, _scale, _signed?) when coef in [:NaN, :inf] do
      {:error, :non_finite}
    end

    defp do_to_scaled(%Decimal{} = dec, scale, signed?) do
      scaled = Decimal.mult(dec, scale)
      rounded = Decimal.round(scaled, 0)

      if Decimal.equal?(scaled, rounded) do
        int = Decimal.to_integer(rounded)
        if in_bounds?(int, signed?), do: {:ok, int}, else: {:error, :out_of_bounds}
      else
        {:error, :precision_loss}
      end
    end

    defp do_to_scaled(_other, _scale, _signed?), do: {:error, :invalid}

    defp in_bounds?(int, true), do: int >= @min_i64 and int <= @max_i64
    defp in_bounds?(int, false), do: int >= 0 and int <= @max_u64
  end
end
