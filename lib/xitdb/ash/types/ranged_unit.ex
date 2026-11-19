if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Types.RangedUnit do
    @moduledoc """
    Domain struct and `Ash.Type` representing a numeric point or interval with unit/currency
    metadata (modeled after Bragi's `Ranged_Unit`), plus index decomposition and interval
    overlap predicates.

    Supported `bound_kind` values:
    `:exact | :closed_range | :greater_than | :at_least | :less_than | :at_most | :unparsed_dirty`.

    Stored in `Xitdb` as a compact string-keyed map (`"b"`, `"d"`, optional `"c"`, `"min"`,
    `"max"`), and implements `Xitdb.Encoder` so `%RangedUnit{}` structs can also be written
    directly via `Xitdb.transact/3`, `put_in/3`, and `Xitdb.DSL.tx/3`.
    """

    use Ash.Type

    alias Xitdb.Ash.Types.FixedDecimal64

    @min_i64 -9_223_372_036_854_775_808
    @max_i64 9_223_372_036_854_775_807
    @max_u64 18_446_744_073_709_551_615

    @bound_kinds [
      :exact,
      :closed_range,
      :greater_than,
      :at_least,
      :less_than,
      :at_most,
      :unparsed_dirty
    ]

    @bound_kind_map Map.new(@bound_kinds, &{Atom.to_string(&1), &1})

    @known_dimensions [
      :dimensionless,
      :currency,
      :ratio,
      :percent,
      :count,
      :time,
      :mass,
      :length
    ]

    @dimension_map Map.new(@known_dimensions, &{Atom.to_string(&1), &1})

    @known_currencies [
      :usd,
      :eur,
      :gbp,
      :cad,
      :chf,
      :jpy,
      :aud,
      :sgd,
      :hkd,
      :cny,
      :inr,
      :sek,
      :nok,
      :dkk,
      :nzd
    ]

    @currency_map Map.new(@known_currencies, &{Atom.to_string(&1), &1})

    defstruct [
      :min_val,
      :max_val,
      bound_kind: :closed_range,
      dimension: :dimensionless,
      currency: nil
    ]

    @type bound_kind ::
            :exact
            | :closed_range
            | :greater_than
            | :at_least
            | :less_than
            | :at_most
            | :unparsed_dirty

    @type t :: %__MODULE__{
            min_val: Decimal.t() | integer() | nil,
            max_val: Decimal.t() | integer() | nil,
            bound_kind: bound_kind(),
            dimension: atom() | String.t(),
            currency: atom() | String.t() | nil
          }

    @impl true
    def storage_type(_constraints), do: :map

    @impl true
    def matches_type?(%__MODULE__{}, _constraints), do: true
    def matches_type?(_val, _constraints), do: false

    @impl true
    def simple_equality?, do: false

    @impl true
    def equal?(nil, nil), do: true
    def equal?(nil, _), do: false
    def equal?(_, nil), do: false

    def equal?(%__MODULE__{} = a, %__MODULE__{} = b) do
      a.bound_kind == b.bound_kind and
        a.dimension == b.dimension and
        a.currency == b.currency and
        decimal_equal?(a.min_val, b.min_val) and
        decimal_equal?(a.max_val, b.max_val)
    end

    def equal?(a, b), do: a == b

    @impl true
    def cast_input(nil, _constraints), do: {:ok, nil}

    def cast_input(%__MODULE__{} = ru, _constraints) do
      normalize_struct(ru)
    end

    def cast_input(map, _constraints) when is_map(map) and not is_struct(map) do
      from_map(map)
    end

    def cast_input(_other, _constraints), do: :error

    @impl true
    def cast_stored(nil, _constraints), do: {:ok, nil}

    def cast_stored(%__MODULE__{} = ru, _constraints) do
      normalize_struct(ru)
    end

    def cast_stored(map, _constraints) when is_map(map) and not is_struct(map) do
      from_map(map)
    end

    def cast_stored(_other, _constraints), do: :error

    @impl true
    def dump_to_native(nil, _constraints), do: {:ok, nil}

    def dump_to_native(%__MODULE__{} = ru, _constraints) do
      case normalize_struct(ru) do
        {:ok, norm} -> {:ok, to_compact_map(norm)}
        :error -> :error
      end
    end

    def dump_to_native(map, _constraints) when is_map(map) and not is_struct(map) do
      case from_map(map) do
        {:ok, norm} -> {:ok, to_compact_map(norm)}
        :error -> :error
      end
    end

    def dump_to_native(_other, _constraints), do: :error

    @doc """
    Converts a `%RangedUnit{}` struct into its compact string-keyed Xitdb storage map.
    """
    @spec to_compact_map(t()) :: %{String.t() => String.t()}
    def to_compact_map(%__MODULE__{} = ru) do
      base = %{
        "b" => Atom.to_string(ru.bound_kind),
        "d" => to_string(ru.dimension)
      }

      base =
        if ru.currency != nil do
          Map.put(base, "c", to_string(ru.currency))
        else
          base
        end

      base =
        if ru.min_val != nil do
          Map.put(base, "min", decimal_to_str(ru.min_val))
        else
          base
        end

      if ru.max_val != nil do
        Map.put(base, "max", decimal_to_str(ru.max_val))
      else
        base
      end
    end

    @doc """
    Decomposes a `%RangedUnit{}` (or `nil`) into flat indexed attributes suitable for
    co-located `FixedDecimal64` B+Tree secondary index range queries:
    `%{min_d64: ..., max_d64: ..., bound: ..., unit: ...}` (or `<prefix>_min_d64`, etc.).

    Accepts either an atom/string prefix or an options list (e.g.
    `to_indexed_fields(ru, :ticket, unbounded: :sentinel)`).

    ## Options
    - `:prefix` — attribute key prefix atom/binary when calling the 2-arity form
    - `:unbounded` — `:nil` *(default)* or `:sentinel` (fills open interval sides with
      extreme `FixedDecimal64` bounds matching `:scale` and `:signed?`)
    - `:scale` — `FixedDecimal64` scale for `:sentinel` calculation (default: `10_000`)
    - `:signed?` — signedness for `:sentinel` calculation (default: `true`)
    """
    @spec to_indexed_fields(t() | nil, atom() | String.t() | keyword()) :: map()
    def to_indexed_fields(ranged_unit, prefix_or_opts \\ [])

    def to_indexed_fields(ranged_unit, opts) when is_list(opts) do
      do_to_indexed_fields(ranged_unit, Keyword.get(opts, :prefix), opts)
    end

    def to_indexed_fields(ranged_unit, prefix) when is_atom(prefix) or is_binary(prefix) do
      do_to_indexed_fields(ranged_unit, prefix, [])
    end

    @doc """
    Same as `to_indexed_fields/2`, accepting an explicit `prefix` alongside `opts`.
    """
    @spec to_indexed_fields(t() | nil, atom() | String.t() | nil, keyword()) :: map()
    def to_indexed_fields(ranged_unit, prefix, opts) when is_list(opts) do
      do_to_indexed_fields(ranged_unit, prefix, opts)
    end

    defp do_to_indexed_fields(nil, prefix, _opts) do
      build_indexed_map(prefix, nil, nil, nil, nil)
    end

    defp do_to_indexed_fields(%__MODULE__{} = ru, prefix, opts) do
      unbounded = Keyword.get(opts, :unbounded, nil)
      scale = Keyword.get(opts, :scale, 10_000)
      signed? = Keyword.get(opts, :signed?, true)

      min_d = to_decimal_or_nil(ru.min_val)
      max_d = to_decimal_or_nil(ru.max_val)

      {eff_min, eff_max} =
        case ru.bound_kind do
          :unparsed_dirty ->
            {nil, nil}

          :exact ->
            v = min_d || max_d
            {v, v}

          :closed_range ->
            {min_d, max_d}

          kind when kind in [:at_least, :greater_than] ->
            {min_d, open_upper_bound(unbounded, scale, signed?)}

          kind when kind in [:at_most, :less_than] ->
            {open_lower_bound(unbounded, scale, signed?), max_d}
        end

      unit =
        if ru.currency != nil do
          to_string(ru.currency)
        else
          to_string(ru.dimension)
        end

      build_indexed_map(prefix, eff_min, eff_max, Atom.to_string(ru.bound_kind), unit)
    end

    @doc """
    Returns `true` if intervals `a` and `b` are comparable (matching `dimension` and
    compatible `currency`, and neither is `:unparsed_dirty`) and intersect at least at one point.
    """
    @spec overlaps?(t(), t()) :: boolean()
    def overlaps?(%__MODULE__{bound_kind: :unparsed_dirty}, %__MODULE__{}), do: false
    def overlaps?(%__MODULE__{}, %__MODULE__{bound_kind: :unparsed_dirty}), do: false

    def overlaps?(%__MODULE__{} = a, %__MODULE__{} = b) do
      cond do
        a.dimension != b.dimension ->
          false

        a.currency != nil and b.currency != nil and a.currency != b.currency ->
          false

        true ->
          with {:ok, a_low, a_high} <- interval_bounds(a),
               {:ok, b_low, b_high} <- interval_bounds(b),
               false <- empty_interval?(a_low, a_high),
               false <- empty_interval?(b_low, b_high) do
            not bound_before?(a_high, b_low) and not bound_before?(b_high, a_low)
          else
            _ -> false
          end
      end
    end

    defp interval_bounds(%__MODULE__{bound_kind: :exact, min_val: min_v, max_val: max_v}) do
      with {:ok, v} <- require_decimal(min_v || max_v) do
        {:ok, {:inc, v}, {:inc, v}}
      end
    end

    defp interval_bounds(%__MODULE__{bound_kind: :closed_range, min_val: min_v, max_val: max_v}) do
      with {:ok, l} <- require_decimal(min_v),
           {:ok, u} <- require_decimal(max_v) do
        {:ok, {:inc, l}, {:inc, u}}
      end
    end

    defp interval_bounds(%__MODULE__{bound_kind: :at_least, min_val: min_v}) do
      with {:ok, l} <- require_decimal(min_v) do
        {:ok, {:inc, l}, :pos_inf}
      end
    end

    defp interval_bounds(%__MODULE__{bound_kind: :greater_than, min_val: min_v}) do
      with {:ok, l} <- require_decimal(min_v) do
        {:ok, {:exc, l}, :pos_inf}
      end
    end

    defp interval_bounds(%__MODULE__{bound_kind: :at_most, max_val: max_v}) do
      with {:ok, u} <- require_decimal(max_v) do
        {:ok, :neg_inf, {:inc, u}}
      end
    end

    defp interval_bounds(%__MODULE__{bound_kind: :less_than, max_val: max_v}) do
      with {:ok, u} <- require_decimal(max_v) do
        {:ok, :neg_inf, {:exc, u}}
      end
    end

    defp interval_bounds(_other), do: :error

    defp empty_interval?(:neg_inf, _high), do: false
    defp empty_interval?(_low, :pos_inf), do: false

    defp empty_interval?({low_kind, low_val}, {high_kind, high_val}) do
      case Decimal.compare(low_val, high_val) do
        :gt -> true
        :eq -> low_kind == :exc or high_kind == :exc
        :lt -> false
      end
    end

    defp bound_before?(:pos_inf, _low), do: false
    defp bound_before?(_high, :neg_inf), do: false

    defp bound_before?({high_kind, u}, {low_kind, l}) do
      case Decimal.compare(u, l) do
        :lt -> true
        :gt -> false
        :eq -> high_kind == :exc or low_kind == :exc
      end
    end

    defp normalize_struct(%__MODULE__{} = ru) do
      with {:ok, bk} <- normalize_bound_kind(ru.bound_kind),
           {:ok, dim} <- normalize_atom_or_str(ru.dimension, @dimension_map, :dimensionless),
           {:ok, cur} <- normalize_currency(ru.currency),
           {:ok, min_d} <- normalize_decimal(ru.min_val),
           {:ok, max_d} <- normalize_decimal(ru.max_val) do
        exact_consistent? =
          bk != :exact or min_d == nil or max_d == nil or Decimal.equal?(min_d, max_d)

        {norm_min, norm_max} =
          if bk == :exact do
            v = min_d || max_d
            {v, v}
          else
            {min_d, max_d}
          end

        valid_range? =
          cond do
            bk == :exact ->
              exact_consistent?

            norm_min != nil and norm_max != nil ->
              Decimal.compare(norm_min, norm_max) != :gt

            true ->
              true
          end

        if valid_range? do
          {:ok,
           %__MODULE__{
             bound_kind: bk,
             dimension: dim,
             currency: cur,
             min_val: norm_min,
             max_val: norm_max
           }}
        else
          :error
        end
      end
    end

    defp from_map(map) do
      bk_raw = fetch_any(map, ["b", :b, "bound_kind", :bound_kind], :closed_range)
      dim_raw = fetch_any(map, ["d", :d, "dimension", :dimension], :dimensionless)
      cur_raw = fetch_any(map, ["c", :c, "currency", :currency], nil)
      min_raw = fetch_any(map, ["min", :min, "min_val", :min_val], nil)
      max_raw = fetch_any(map, ["max", :max, "max_val", :max_val], nil)

      with {:ok, bk} <- normalize_bound_kind(bk_raw),
           {:ok, dim} <- normalize_atom_or_str(dim_raw, @dimension_map, :dimensionless),
           {:ok, cur} <- normalize_currency(cur_raw),
           {:ok, min_d} <- normalize_decimal(min_raw),
           {:ok, max_d} <- normalize_decimal(max_raw) do
        normalize_struct(%__MODULE__{
          bound_kind: bk,
          dimension: dim,
          currency: cur,
          min_val: min_d,
          max_val: max_d
        })
      end
    end

    defp fetch_any(map, keys, default) do
      Enum.find_value(keys, default, fn k ->
        case Map.fetch(map, k) do
          {:ok, val} -> val
          :error -> nil
        end
      end)
    end

    defp normalize_bound_kind(bk) when bk in @bound_kinds, do: {:ok, bk}

    defp normalize_bound_kind(str) when is_binary(str) do
      case Map.fetch(@bound_kind_map, str) do
        {:ok, bk} -> {:ok, bk}
        :error -> :error
      end
    end

    defp normalize_bound_kind(_), do: :error

    defp normalize_atom_or_str(nil, _known, default), do: {:ok, default}
    defp normalize_atom_or_str(a, _known, _default) when is_atom(a), do: {:ok, a}

    defp normalize_atom_or_str(str, known, _default) when is_binary(str) do
      down = String.downcase(str)

      case Map.fetch(known, down) do
        {:ok, a} ->
          {:ok, a}

        :error ->
          try do
            {:ok, String.to_existing_atom(down)}
          rescue
            ArgumentError -> {:ok, str}
          end
      end
    end

    defp normalize_atom_or_str(_, _, _), do: :error

    defp normalize_currency(nil), do: {:ok, nil}
    defp normalize_currency(cur), do: normalize_atom_or_str(cur, @currency_map, nil)

    defp normalize_decimal(nil), do: {:ok, nil}
    defp normalize_decimal(%Decimal{coef: coef}) when coef in [:NaN, :inf], do: :error
    defp normalize_decimal(%Decimal{} = d), do: {:ok, d}
    defp normalize_decimal(i) when is_integer(i), do: {:ok, Decimal.new(i)}
    defp normalize_decimal(f) when is_float(f), do: {:ok, Decimal.from_float(f)}

    defp normalize_decimal(bin) when is_binary(bin) do
      case Decimal.parse(bin) do
        {d, ""} -> {:ok, d}
        _ -> :error
      end
    end

    defp normalize_decimal(_), do: :error

    defp require_decimal(nil), do: :error

    defp require_decimal(val) do
      case normalize_decimal(val) do
        {:ok, %Decimal{} = d} -> {:ok, d}
        _ -> :error
      end
    end

    defp to_decimal_or_nil(nil), do: nil

    defp to_decimal_or_nil(val) do
      case normalize_decimal(val) do
        {:ok, d} -> d
        :error -> raise ArgumentError, "invalid numeric bound in RangedUnit: #{inspect(val)}"
      end
    end

    defp decimal_to_str(%Decimal{} = d), do: Decimal.to_string(d, :normal)
    defp decimal_to_str(i) when is_integer(i), do: Integer.to_string(i)

    defp decimal_to_str(f) when is_float(f),
      do: f |> Decimal.from_float() |> Decimal.to_string(:normal)

    defp decimal_equal?(nil, nil), do: true
    defp decimal_equal?(nil, _), do: false
    defp decimal_equal?(_, nil), do: false

    defp decimal_equal?(a, b) do
      with {:ok, da} <- normalize_decimal(a),
           {:ok, db} <- normalize_decimal(b) do
        Decimal.equal?(da, db)
      else
        _ -> a == b
      end
    end

    defp open_upper_bound(nil, _scale, _signed?), do: nil

    defp open_upper_bound(:sentinel, scale, true),
      do: FixedDecimal64.from_scaled(@max_i64, scale)

    defp open_upper_bound(:sentinel, scale, false),
      do: FixedDecimal64.from_scaled(@max_u64, scale)

    defp open_lower_bound(nil, _scale, _signed?), do: nil

    defp open_lower_bound(:sentinel, scale, true),
      do: FixedDecimal64.from_scaled(@min_i64, scale)

    defp open_lower_bound(:sentinel, scale, false),
      do: FixedDecimal64.from_scaled(0, scale)

    defp build_indexed_map(nil, min_v, max_v, bound, unit) do
      %{min_d64: min_v, max_d64: max_v, bound: bound, unit: unit}
    end

    defp build_indexed_map(prefix, min_v, max_v, bound, unit) do
      p = to_string(prefix)

      %{
        String.to_existing_atom("#{p}_min_d64") => min_v,
        String.to_existing_atom("#{p}_max_d64") => max_v,
        String.to_existing_atom("#{p}_bound") => bound,
        String.to_existing_atom("#{p}_unit") => unit
      }
    end
  end

  defimpl Xitdb.Encoder, for: Xitdb.Ash.Types.RangedUnit do
    def encode(%Xitdb.Ash.Types.RangedUnit{} = ru) do
      Xitdb.Ash.Types.RangedUnit.to_compact_map(ru)
    end
  end
end
