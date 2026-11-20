if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Types.UnsignedInteger do
    @moduledoc """
    Ash type for unsigned 64-bit integers (`0..18_446_744_073_709_551_615`).

    Values in `0..9_223_372_036_854_775_807` are stored directly as native Xitdb integer
    slots (`Tag.Uint`), while values exceeding signed `max(i64)` are stored compactly as
    `{:tagged, "u8", <<value::unsigned-big-64>>}` so exact 64-bit unsigned precision is
    preserved across Xitdb's signed-64-bit slot boundary.

    Secondary indexes on `UnsignedInteger` attributes use 8-byte `Xitdb.Key.encode_u64_be/1`
    keys for exact B+Tree range queries (`<, <=, ==, >=, >`).
    """

    use Ash.Type

    @max_i64 9_223_372_036_854_775_807
    @max_u64 18_446_744_073_709_551_615

    @constraints [
      min: [
        type: :non_neg_integer,
        doc: "Enforces an inclusive minimum value (>= 0)."
      ],
      max: [
        type: :non_neg_integer,
        doc: "Enforces an inclusive maximum value (<= 2^64 - 1)."
      ]
    ]

    @impl true
    def constraints, do: @constraints

    @impl true
    def storage_type(_constraints), do: :unsigned_integer

    @impl true
    def matches_type?(val, _constraints) when is_integer(val),
      do: val >= 0 and val <= @max_u64

    def matches_type?(_val, _constraints), do: false

    @impl true
    def cast_atomic(expr, _constraints), do: {:atomic, expr}

    @impl true
    def simple_equality?, do: true

    @impl true
    def cast_input(nil, _constraints), do: {:ok, nil}

    def cast_input(val, _constraints) when is_integer(val) and val >= 0 and val <= @max_u64 do
      {:ok, val}
    end

    def cast_input({:tagged, "u8", <<val::unsigned-big-64>>}, _constraints) do
      {:ok, val}
    end

    def cast_input(val, _constraints) when is_binary(val) do
      case Integer.parse(val) do
        {int, ""} when int >= 0 and int <= @max_u64 -> {:ok, int}
        _ -> :error
      end
    end

    def cast_input(_val, _constraints), do: :error

    @impl true
    def apply_constraints(nil, _constraints), do: {:ok, nil}

    def apply_constraints(val, constraints) when is_integer(val) do
      min = Keyword.get(constraints, :min)
      max = Keyword.get(constraints, :max)

      cond do
        val < 0 or val > @max_u64 ->
          {:error, message: "must fit within an unsigned 64-bit integer (0..2^64-1)"}

        min != nil and val < min ->
          {:error, message: "must be greater than or equal to %{min}", min: min}

        max != nil and val > max ->
          {:error, message: "must be less than or equal to %{max}", max: max}

        true ->
          {:ok, val}
      end
    end

    @impl true
    def cast_stored(nil, _constraints), do: {:ok, nil}

    def cast_stored(val, _constraints) when is_integer(val) and val >= 0 and val <= @max_u64 do
      {:ok, val}
    end

    def cast_stored({:tagged, "u8", <<val::unsigned-big-64>>}, _constraints) do
      {:ok, val}
    end

    def cast_stored(val, _constraints) when is_binary(val) do
      case Integer.parse(val) do
        {int, ""} when int >= 0 and int <= @max_u64 -> {:ok, int}
        _ -> :error
      end
    end

    def cast_stored(_val, _constraints), do: :error

    @impl true
    def dump_to_native(nil, _constraints), do: {:ok, nil}

    def dump_to_native(val, _constraints)
        when is_integer(val) and val >= 0 and val <= @max_i64 do
      {:ok, val}
    end

    def dump_to_native(val, _constraints)
        when is_integer(val) and val > @max_i64 and val <= @max_u64 do
      {:ok, {:tagged, "u8", <<val::unsigned-big-64>>}}
    end

    def dump_to_native(_val, _constraints), do: :error

    @doc """
    Encodes an unsigned 64-bit integer (or stored `"u8"` tagged value) as an 8-byte
    order-preserving B+Tree index key.
    """
    @spec xitdb_index_key(non_neg_integer() | {:tagged, binary(), binary()}, keyword()) ::
            <<_::64>>
    def xitdb_index_key({:tagged, "u8", <<val::unsigned-big-64>>}, _constraints) do
      Xitdb.Key.encode_u64_be(val)
    end

    def xitdb_index_key(val, _constraints)
        when is_integer(val) and val >= 0 and val <= @max_u64 do
      Xitdb.Key.encode_u64_be(val)
    end

    @doc "Marks `UnsignedInteger` index keys as fixed 8-byte width for composite indexes."
    @spec xitdb_fixed_width?(keyword()) :: true
    def xitdb_fixed_width?(_constraints), do: true
  end
end
