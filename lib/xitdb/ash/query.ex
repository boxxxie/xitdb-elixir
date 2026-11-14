if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Query do
    @moduledoc """
    Data-layer query struct, query-shaping helpers, and 6-stage planner/executor for
    `Xitdb.Ash.DataLayer`.

    Executes Stage 1 index/subtree narrowing -> Stage 2 cursor hydration ->
    Stage 3 pure-attribute pre-filtering -> Stage 4 derived enrichment &
    `Ash.Filter.Runtime` evaluation -> Stage 5 `distinct` / `runtime_sort` / slice ->
    Stage 6 `select` field masking.
    """

    alias Ash.Actions.Sort
    alias Ash.Query.{Aggregate, BooleanExpression, Calculation, Not, Parent, Ref}

    alias Ash.Query.Operator.{
      Eq,
      GreaterThan,
      GreaterThanOrEqual,
      In,
      LessThan,
      LessThanOrEqual
    }

    alias Ash.Resource.Attribute
    alias Xitdb.Ash.{Codec, Indexer, Info, Store}

    defstruct [
      :resource,
      :domain,
      :filter,
      :sort,
      :distinct,
      :distinct_sort,
      :limit,
      :offset,
      :select,
      :tenant,
      aggregates: [],
      calculations: [],
      context: %{}
    ]

    @type t :: %__MODULE__{
            resource: module(),
            domain: module() | nil,
            filter: Ash.Filter.t() | nil,
            sort: Keyword.t() | list() | nil,
            distinct: [atom()] | nil,
            distinct_sort: Keyword.t() | list() | nil,
            limit: non_neg_integer() | nil,
            offset: non_neg_integer() | nil,
            select: [atom()] | nil,
            tenant: term(),
            aggregates: [Aggregate.t()],
            calculations: [{Calculation.t(), term()} | Calculation.t()],
            context: map()
          }

    # -- Query Shaping Helpers (Delegated by `Xitdb.Ash.DataLayer`) --

    @spec new(module(), module() | nil) :: t()
    def new(resource, domain \\ nil) when is_atom(resource) do
      %__MODULE__{resource: resource, domain: domain}
    end

    @spec filter(t(), Ash.Filter.t() | nil, module()) :: {:ok, t()} | {:error, term()}
    def filter(%__MODULE__{} = query, nil, _resource), do: {:ok, query}

    def filter(%__MODULE__{filter: nil} = query, filter, _resource) do
      {:ok, %__MODULE__{query | filter: filter}}
    end

    def filter(%__MODULE__{filter: existing} = query, filter, _resource) do
      case Ash.Filter.add_to_filter(existing, filter) do
        {:ok, merged} -> {:ok, %__MODULE__{query | filter: merged}}
        {:error, _} = err -> err
      end
    end

    @spec sort(t(), term(), module()) :: {:ok, t()}
    def sort(%__MODULE__{} = query, sort, _resource), do: {:ok, %__MODULE__{query | sort: sort}}

    @spec distinct(t(), [atom()], module()) :: {:ok, t()}
    def distinct(%__MODULE__{} = query, distinct, _resource) do
      {:ok, %__MODULE__{query | distinct: distinct}}
    end

    @spec distinct_sort(t(), term(), module()) :: {:ok, t()}
    def distinct_sort(%__MODULE__{} = query, distinct_sort, _resource) do
      {:ok, %__MODULE__{query | distinct_sort: distinct_sort}}
    end

    @spec limit(t(), non_neg_integer() | nil, module()) :: {:ok, t()}
    def limit(%__MODULE__{} = query, limit, _resource) do
      {:ok, %__MODULE__{query | limit: limit}}
    end

    @spec offset(t(), non_neg_integer() | nil, module()) :: {:ok, t()}
    def offset(%__MODULE__{} = query, offset, _resource) do
      {:ok, %__MODULE__{query | offset: offset}}
    end

    @spec select(t(), [atom()] | nil, module()) :: {:ok, t()}
    def select(%__MODULE__{} = query, select, _resource) do
      {:ok, %__MODULE__{query | select: select}}
    end

    @spec set_context(term(), term(), term()) :: {:ok, t()}
    def set_context(resource, %__MODULE__{} = query, context) when is_atom(resource) do
      set_context(query, context, resource)
    end

    def set_context(%__MODULE__{} = query, nil, _resource), do: {:ok, query}

    def set_context(%__MODULE__{context: existing} = query, context, _resource)
        when is_map(context) do
      {:ok, %__MODULE__{query | context: Map.merge(existing || %{}, context)}}
    end

    @spec set_tenant(term(), term(), term()) :: {:ok, t()}
    def set_tenant(resource, %__MODULE__{} = query, tenant) when is_atom(resource) do
      set_tenant(query, tenant, resource)
    end

    def set_tenant(%__MODULE__{} = query, tenant, _resource) do
      {:ok, %__MODULE__{query | tenant: tenant}}
    end

    @spec add_aggregate(t(), Aggregate.t(), module()) :: {:ok, t()}
    def add_aggregate(%__MODULE__{aggregates: existing} = query, aggregate, _resource) do
      {:ok, %__MODULE__{query | aggregates: existing ++ [aggregate]}}
    end

    @spec add_aggregates(t(), [Aggregate.t()], module()) :: {:ok, t()}
    def add_aggregates(%__MODULE__{aggregates: existing} = query, aggregates, _resource) do
      {:ok, %__MODULE__{query | aggregates: existing ++ List.wrap(aggregates)}}
    end

    @spec add_calculation(t(), Calculation.t(), term(), module()) :: {:ok, t()}
    def add_calculation(%__MODULE__{calculations: existing} = query, calculation, expr, _resource) do
      {:ok, %__MODULE__{query | calculations: existing ++ [{calculation, expr}]}}
    end

    @spec add_calculations(t(), [{Calculation.t(), term()} | Calculation.t()], module()) ::
            {:ok, t()}
    def add_calculations(%__MODULE__{calculations: existing} = query, calculations, _resource) do
      normalized =
        Enum.map(List.wrap(calculations), fn
          {_calc, _expr} = pair -> pair
          calc -> {calc, nil}
        end)

      {:ok, %__MODULE__{query | calculations: existing ++ normalized}}
    end

    # -- 6-Stage Execution Entrypoint --

    @doc """
    Executes `query` against `db_or_cursor` (either `%Xitdb{}`, `{db, moment}`, or `%Xitdb.Cursor{}`)
    for `resource` using the 6-stage pipeline.
    """
    @spec execute(term(), t(), module()) :: {:ok, [struct()]} | {:error, term()}
    def execute(_db_or_cursor, %__MODULE__{context: %{__stub_empty__: true}}, _resource) do
      {:ok, []}
    end

    def execute(db_or_cursor, %__MODULE__{} = query, resource) when is_atom(resource) do
      %__MODULE__{} = query = normalize_domain(query, resource)

      with {:ok, raw_cursors} <- stage1_narrow(db_or_cursor, query, resource),
           {:ok, hydrated} <- stage2_hydrate(raw_cursors, query, resource),
           {:ok, prefiltered, already_filtered?} <- stage3_prefilter(hydrated, query, resource),
           {:ok, enriched_and_filtered} <-
             stage4_enrich_and_filter(
               db_or_cursor,
               prefiltered,
               already_filtered?,
               query,
               resource
             ),
           ordered = stage5_order_and_slice(enriched_and_filtered, query, resource) do
        {:ok, stage6_project(ordered, query, resource)}
      end
    end

    @doc """
    Executes query-level aggregates against records produced by `query`.
    """
    @spec execute_aggregates(term(), t(), [Aggregate.t()], module()) ::
            {:ok, map()} | {:error, term()}
    def execute_aggregates(
          _db_or_cursor,
          %__MODULE__{context: %{__stub_empty__: true}},
          _aggregates,
          _resource
        ) do
      {:ok, %{}}
    end

    def execute_aggregates(_db_or_cursor, %__MODULE__{}, [], _resource), do: {:ok, %{}}

    def execute_aggregates(db_or_cursor, %__MODULE__{} = query, aggregates, resource)
        when is_list(aggregates) and is_atom(resource) do
      %__MODULE__{} = query = normalize_domain(query, resource)
      base_query = %{query | aggregates: [], calculations: []}

      case execute(db_or_cursor, base_query, resource) do
        {:ok, records} ->
          evaluate_query_aggregates(records, aggregates, query, resource)

        {:error, _} = err ->
          err
      end
    end

    # ==========================================================================
    # Stage 1: Index / Primary-Key / Unique-Identity Narrowing
    # ==========================================================================

    defp stage1_narrow(_db_or_cursor, %__MODULE__{filter: %Ash.Filter{expression: false}}, _res) do
      {:ok, []}
    end

    defp stage1_narrow(db_or_cursor, %__MODULE__{filter: filter, tenant: tenant}, resource) do
      conjuncts = extract_top_level_conjuncts(filter)

      if Enum.any?(conjuncts, &(&1 == false)) do
        {:ok, []}
      else
        case plan_narrowing(db_or_cursor, resource, conjuncts, tenant) do
          {:empty} ->
            {:ok, []}

          {:cursors, cursors} ->
            {:ok, cursors}

          {:doc_ids, doc_ids} ->
            {:ok, doc_ids_to_cursors(db_or_cursor, resource, doc_ids, tenant)}

          :full_scan ->
            {:ok, Indexer.all_cursors(db_or_cursor, resource, tenant)}
        end
      end
    end

    defp plan_narrowing(_db_or_cursor, _resource, [], _tenant), do: :full_scan

    defp plan_narrowing(db_or_cursor, resource, conjuncts, tenant) do
      case collect_predicates(conjuncts, resource) do
        :contradiction ->
          {:empty}

        {eq_map, range_map} ->
          [pk_name | _] = Ash.Resource.Info.primary_key(resource)
          nested_fk = nested_foreign_key(resource)

          cond do
            # 1. Primary-key equality / `in` -> O(1) cursor fetch
            Map.has_key?(eq_map, pk_name) ->
              resolve_pk_candidates(db_or_cursor, resource, Map.fetch!(eq_map, pk_name), tenant)

            # 2. Unconditional unique identity equality -> O(log N) B+Tree lookup
            (identity_hit = try_unique_identity_lookup(db_or_cursor, resource, eq_map, tenant)) !=
                :no_match ->
              identity_hit

            # 3. `nested_in` parent FK equality -> O(1) subtree jump
            nested_fk != nil and Map.has_key?(eq_map, nested_fk) ->
              parent_vals = Map.fetch!(eq_map, nested_fk)

              nested_cursors =
                fetch_nested_parent_cursors(db_or_cursor, resource, parent_vals, tenant)

              intersect_cursors_with_secondary(
                db_or_cursor,
                resource,
                nested_cursors,
                eq_map,
                range_map,
                nested_fk,
                tenant
              )

            # 4. Secondary B+Tree equality, `in`, or composite prefix + range intersection
            true ->
              intersect_secondary_indexes(db_or_cursor, resource, eq_map, range_map, nil, tenant)
          end
      end
    end

    defp nested_foreign_key(resource) do
      case fallback_nested_fk(resource) do
        nil ->
          if function_exported?(Info, :nested_mappings, 1) do
            case Info.nested_mappings(resource) do
              [%{parent_key: fk} | _] when not is_nil(fk) -> fk
              [%{foreign_key: fk} | _] when not is_nil(fk) -> fk
              _ -> nil
            end
          end

        fk ->
          fk
      end
    end

    defp fallback_nested_fk(resource) do
      if function_exported?(Info, :nested_in, 1) do
        case apply(Info, :nested_in, [resource]) do
          %{foreign_key: fk} -> fk
          %{parent_key: fk} -> fk
          _ -> nil
        end
      else
        nil
      end
    end

    defp fetch_nested_parent_cursors(_db_or_cursor, _resource, [], _tenant), do: []

    defp fetch_nested_parent_cursors(db_or_cursor, resource, parent_vals, tenant) do
      parent_vals
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&Codec.encode_doc_id/1)
      |> Enum.flat_map(&Indexer.nested_cursors_for_parent(db_or_cursor, resource, &1, tenant))
    end

    defp intersect_cursors_with_secondary(
           _db_or_cursor,
           _resource,
           [],
           _eq_map,
           _range_map,
           _skip_field,
           _tenant
         ) do
      {:empty}
    end

    defp intersect_cursors_with_secondary(
           db_or_cursor,
           resource,
           cursors,
           eq_map,
           range_map,
           skip_field,
           tenant
         ) do
      case intersect_secondary_indexes(
             db_or_cursor,
             resource,
             Map.delete(eq_map, skip_field),
             range_map,
             skip_field,
             tenant
           ) do
        :full_scan ->
          {:cursors, cursors}

        {:empty} ->
          {:empty}

        {:doc_ids, allowed_ids} ->
          narrowed =
            Enum.filter(cursors, fn {doc_id, _} -> MapSet.member?(allowed_ids, doc_id) end)

          if narrowed == [], do: {:empty}, else: {:cursors, narrowed}
      end
    end

    defp resolve_pk_candidates(_db_or_cursor, _resource, [], _tenant), do: {:empty}

    defp resolve_pk_candidates(db_or_cursor, resource, pk_values, tenant) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_attr = Ash.Resource.Info.attribute(resource, pk_name)

      cursors =
        pk_values
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&Codec.encode_pk_doc_id(pk_attr, &1))
        |> Enum.flat_map(fn pk_val ->
          case Indexer.fetch_cursor(db_or_cursor, resource, pk_val, tenant) do
            {:ok, cursor} -> [{Codec.encode_pk_doc_id(pk_attr, pk_val), cursor}]
            :none -> []
          end
        end)

      if cursors == [], do: {:empty}, else: {:cursors, cursors}
    end

    defp try_unique_identity_lookup(db_or_cursor, resource, eq_map, tenant) do
      effective_tenant = resolve_effective_identity_tenant(resource, eq_map, tenant)
      strategy = Ash.Resource.Info.multitenancy_strategy(resource)

      unconditional_identities =
        resource
        |> Ash.Resource.Info.identities()
        |> Enum.filter(fn id ->
          tenant_ready? =
            Map.get(id, :all_tenants?, false) or
              strategy != :attribute or
              not is_nil(effective_tenant)

          tenant_ready? and is_nil(Map.get(id, :where)) and
            Enum.all?(id.keys, fn k ->
              case Map.get(eq_map, k) do
                [single_non_nil] when not is_nil(single_non_nil) -> true
                _ -> false
              end
            end)
        end)

      case unconditional_identities do
        [] ->
          :no_match

        [identity | _] ->
          key_map = Map.new(identity.keys, fn k -> {k, hd(Map.fetch!(eq_map, k))} end)
          lookup_tenant = if strategy == :context, do: tenant, else: effective_tenant

          case Indexer.lookup_by_identity(
                 db_or_cursor,
                 resource,
                 identity,
                 key_map,
                 lookup_tenant
               ) do
            {:ok, doc_id} -> {:doc_ids, MapSet.new([doc_id])}
            :none -> {:empty}
          end
      end
    end

    defp resolve_effective_identity_tenant(resource, eq_map, nil) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
        tenant_attr = Ash.Resource.Info.multitenancy_attribute(resource)

        case Map.get(eq_map, tenant_attr) do
          [single_non_nil] when not is_nil(single_non_nil) -> single_non_nil
          _ -> nil
        end
      else
        nil
      end
    end

    defp resolve_effective_identity_tenant(_resource, _eq_map, tenant), do: tenant

    defp intersect_secondary_indexes(
           db_or_cursor,
           resource,
           eq_map,
           range_map,
           skip_field,
           tenant
         ) do
      resource
      |> Info.indexes()
      |> Enum.reject(fn %{fields: [first | _]} -> first == skip_field end)
      |> Enum.reduce_while(:full_scan, fn index_spec, acc ->
        case evaluate_index_spec(db_or_cursor, resource, index_spec, eq_map, range_map, tenant) do
          :not_applicable ->
            {:cont, acc}

          ids when is_struct(ids, MapSet) ->
            merged =
              case acc do
                :full_scan -> ids
                {:doc_ids, prev} -> MapSet.intersection(prev, ids)
              end

            if MapSet.size(merged) == 0 do
              {:halt, {:empty}}
            else
              {:cont, {:doc_ids, merged}}
            end
        end
      end)
    end

    defp evaluate_index_spec(
           db_or_cursor,
           resource,
           %{fields: [single_field]} = index_spec,
           eq_map,
           range_map,
           tenant
         ) do
      cond do
        Map.has_key?(eq_map, single_field) ->
          eq_map
          |> Map.fetch!(single_field)
          |> Enum.reduce(MapSet.new(), fn val, acc ->
            MapSet.union(
              acc,
              Indexer.lookup_secondary_eq(db_or_cursor, resource, index_spec, [val], tenant)
            )
          end)

        Map.has_key?(range_map, single_field) ->
          bounds = Map.fetch!(range_map, single_field)
          Indexer.scan_secondary_range(db_or_cursor, resource, index_spec, bounds, tenant)

        true ->
          :not_applicable
      end
    end

    defp evaluate_index_spec(
           db_or_cursor,
           resource,
           %{fields: fields} = index_spec,
           eq_map,
           range_map,
           tenant
         ) do
      {prefix_fields, remaining} =
        Enum.split_while(fields, fn f ->
          match?([_single], Map.get(eq_map, f))
        end)

      prefix_vals = Enum.map(prefix_fields, fn f -> hd(Map.fetch!(eq_map, f)) end)

      cond do
        remaining == [] ->
          Indexer.lookup_secondary_eq(db_or_cursor, resource, index_spec, prefix_vals, tenant)

        true ->
          next_field = hd(remaining)
          base_spec = if prefix_vals == [], do: %{}, else: %{prefix: prefix_vals}

          cond do
            Map.has_key?(eq_map, next_field) and length(remaining) == 1 ->
              eq_map
              |> Map.fetch!(next_field)
              |> Enum.reduce(MapSet.new(), fn val, acc ->
                MapSet.union(
                  acc,
                  Indexer.lookup_secondary_eq(
                    db_or_cursor,
                    resource,
                    index_spec,
                    prefix_vals ++ [val],
                    tenant
                  )
                )
              end)

            Map.has_key?(eq_map, next_field) ->
              eq_map
              |> Map.fetch!(next_field)
              |> Enum.reduce(MapSet.new(), fn val, acc ->
                range_spec = %{prefix: prefix_vals ++ [val], min: :unbounded, max: :unbounded}

                MapSet.union(
                  acc,
                  Indexer.scan_secondary_range(
                    db_or_cursor,
                    resource,
                    index_spec,
                    range_spec,
                    tenant
                  )
                )
              end)

            Map.has_key?(range_map, next_field) ->
              range_spec =
                base_spec
                |> Map.merge(Map.fetch!(range_map, next_field))

              Indexer.scan_secondary_range(db_or_cursor, resource, index_spec, range_spec, tenant)

            prefix_vals != [] ->
              range_spec = %{prefix: prefix_vals, min: :unbounded, max: :unbounded}
              Indexer.scan_secondary_range(db_or_cursor, resource, index_spec, range_spec, tenant)

            true ->
              :not_applicable
          end
      end
    end

    defp doc_ids_to_cursors(db_or_cursor, resource, doc_ids, tenant) do
      Enum.flat_map(doc_ids, fn doc_id ->
        with {:ok, pk_val} <- Codec.decode_doc_id(resource, doc_id),
             {:ok, cursor} <- Indexer.fetch_cursor(db_or_cursor, resource, pk_val, tenant) do
          [{doc_id, cursor}]
        else
          _ -> []
        end
      end)
    end

    # -- Filter Conjunct & Bound Extraction Helpers --

    defp extract_top_level_conjuncts(nil), do: []
    defp extract_top_level_conjuncts(%Ash.Filter{expression: expr}), do: split_and(expr)
    defp extract_top_level_conjuncts(expr), do: split_and(expr)

    defp split_and(nil), do: []
    defp split_and(true), do: []

    defp split_and(%BooleanExpression{op: :and, left: l, right: r}),
      do: split_and(l) ++ split_and(r)

    defp split_and(other), do: [other]

    defp collect_predicates(conjuncts, resource) do
      Enum.reduce_while(conjuncts, {%{}, %{}}, fn node, {eq_acc, range_acc} ->
        case extract_predicate(node) do
          {:eq, col, val} ->
            case merge_eq(eq_acc, col, [val], Ash.Resource.Info.attribute(resource, col)) do
              :contradiction -> {:halt, :contradiction}
              next_eq -> {:cont, {next_eq, range_acc}}
            end

          {:in, col, vals} ->
            case merge_eq(eq_acc, col, vals, Ash.Resource.Info.attribute(resource, col)) do
              :contradiction -> {:halt, :contradiction}
              next_eq -> {:cont, {next_eq, range_acc}}
            end

          {:range, col, bound_side, bound} ->
            case merge_range(
                   range_acc,
                   col,
                   bound_side,
                   bound,
                   Ash.Resource.Info.attribute(resource, col)
                 ) do
              :contradiction -> {:halt, :contradiction}
              next_range -> {:cont, {eq_acc, next_range}}
            end

          :skip ->
            {:cont, {eq_acc, range_acc}}
        end
      end)
    end

    defp extract_predicate(%Eq{left: left, right: right}) do
      cond do
        local_attr_ref?(left) and literal_value?(right) ->
          {:eq, attr_ref_name(left), right}

        local_attr_ref?(right) and literal_value?(left) ->
          {:eq, attr_ref_name(right), left}

        true ->
          :skip
      end
    end

    defp extract_predicate(%In{left: left, right: right}) do
      if local_attr_ref?(left) and is_enum_of_literals?(right) do
        {:in, attr_ref_name(left), Enum.to_list(right)}
      else
        :skip
      end
    end

    defp extract_predicate(%GreaterThan{left: left, right: right}) do
      cond do
        local_attr_ref?(left) and literal_value?(right) and not is_nil(right) ->
          {:range, attr_ref_name(left), :min, {:exclusive, right}}

        local_attr_ref?(right) and literal_value?(left) and not is_nil(left) ->
          {:range, attr_ref_name(right), :max, {:exclusive, left}}

        true ->
          :skip
      end
    end

    defp extract_predicate(%GreaterThanOrEqual{left: left, right: right}) do
      cond do
        local_attr_ref?(left) and literal_value?(right) and not is_nil(right) ->
          {:range, attr_ref_name(left), :min, {:inclusive, right}}

        local_attr_ref?(right) and literal_value?(left) and not is_nil(left) ->
          {:range, attr_ref_name(right), :max, {:inclusive, left}}

        true ->
          :skip
      end
    end

    defp extract_predicate(%LessThan{left: left, right: right}) do
      cond do
        local_attr_ref?(left) and literal_value?(right) and not is_nil(right) ->
          {:range, attr_ref_name(left), :max, {:exclusive, right}}

        local_attr_ref?(right) and literal_value?(left) and not is_nil(left) ->
          {:range, attr_ref_name(right), :min, {:exclusive, left}}

        true ->
          :skip
      end
    end

    defp extract_predicate(%LessThanOrEqual{left: left, right: right}) do
      cond do
        local_attr_ref?(left) and literal_value?(right) and not is_nil(right) ->
          {:range, attr_ref_name(left), :max, {:inclusive, right}}

        local_attr_ref?(right) and literal_value?(left) and not is_nil(left) ->
          {:range, attr_ref_name(right), :min, {:inclusive, left}}

        true ->
          :skip
      end
    end

    defp extract_predicate(_other), do: :skip

    defp local_attr_ref?(%Ref{relationship_path: [], attribute: %Attribute{}}), do: true

    defp local_attr_ref?(%Ref{relationship_path: [], attribute: attr}) when is_atom(attr),
      do: true

    defp local_attr_ref?(_), do: false

    defp attr_ref_name(%Ref{attribute: %Attribute{name: name}}), do: name
    defp attr_ref_name(%Ref{attribute: name}) when is_atom(name), do: name

    defp literal_value?(%Ref{}), do: false
    defp literal_value?(%Parent{}), do: false
    defp literal_value?(%Ash.Query.Call{}), do: false
    defp literal_value?(%BooleanExpression{}), do: false
    defp literal_value?(%Not{}), do: false
    defp literal_value?(%Ash.Query.Exists{}), do: false

    defp literal_value?(val) when is_struct(val) do
      not Ash.Expr.expr?(val)
    end

    defp literal_value?(_val), do: true

    defp is_enum_of_literals?(%MapSet{} = set), do: Enum.all?(set, &literal_value?/1)
    defp is_enum_of_literals?(list) when is_list(list), do: Enum.all?(list, &literal_value?/1)
    defp is_enum_of_literals?(%Range{}), do: true
    defp is_enum_of_literals?(_), do: false

    defp merge_eq(eq_acc, _col, _vals, nil), do: eq_acc

    defp merge_eq(eq_acc, col, vals, %Attribute{} = attr) do
      unique_vals =
        vals
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(&Codec.encode_scalar_key(attr, &1))

      case Map.fetch(eq_acc, col) do
        :error ->
          if unique_vals == [], do: :contradiction, else: Map.put(eq_acc, col, unique_vals)

        {:ok, existing} ->
          existing_keys = MapSet.new(existing, &Codec.encode_scalar_key(attr, &1))

          intersected =
            Enum.filter(unique_vals, fn v ->
              MapSet.member?(existing_keys, Codec.encode_scalar_key(attr, v))
            end)

          if intersected == [], do: :contradiction, else: Map.put(eq_acc, col, intersected)
      end
    end

    defp merge_range(range_acc, _col, _side, _bound, nil), do: range_acc

    defp merge_range(range_acc, col, bound_side, bound, %Attribute{} = attr) do
      current = Map.get(range_acc, col, %{min: :unbounded, max: :unbounded})

      tightened =
        case bound_side do
          :min -> %{current | min: tighter_min(current.min, bound, attr)}
          :max -> %{current | max: tighter_max(current.max, bound, attr)}
        end

      if range_contradiction?(tightened.min, tightened.max, attr) do
        :contradiction
      else
        Map.put(range_acc, col, tightened)
      end
    end

    defp tighter_min(:unbounded, new, _attr), do: new

    defp tighter_min({k1, v1} = b1, {k2, v2} = b2, attr) do
      key1 = Codec.encode_scalar_key(attr, v1)
      key2 = Codec.encode_scalar_key(attr, v2)

      cond do
        key1 > key2 -> b1
        key2 > key1 -> b2
        k1 == :exclusive -> b1
        k2 == :exclusive -> b2
        true -> b1
      end
    end

    defp tighter_max(:unbounded, new, _attr), do: new

    defp tighter_max({k1, v1} = b1, {k2, v2} = b2, attr) do
      key1 = Codec.encode_scalar_key(attr, v1)
      key2 = Codec.encode_scalar_key(attr, v2)

      cond do
        key1 < key2 -> b1
        key2 < key1 -> b2
        k1 == :exclusive -> b1
        k2 == :exclusive -> b2
        true -> b1
      end
    end

    defp range_contradiction?(:unbounded, _max, _attr), do: false
    defp range_contradiction?(_min, :unbounded, _attr), do: false

    defp range_contradiction?({k1, v1}, {k2, v2}, attr) do
      key1 = Codec.encode_scalar_key(attr, v1)
      key2 = Codec.encode_scalar_key(attr, v2)
      key1 > key2 or (key1 == key2 and (k1 == :exclusive or k2 == :exclusive))
    end

    # ==========================================================================
    # Stage 2: Cursor Hydration & Attribute Multitenancy Enforcement
    # ==========================================================================

    defp stage2_hydrate(raw_cursors, %__MODULE__{tenant: tenant}, resource) do
      strategy = Ash.Resource.Info.multitenancy_strategy(resource)
      global? = Ash.Resource.Info.multitenancy_global?(resource)
      tenant_attr = Ash.Resource.Info.multitenancy_attribute(resource)

      raw_cursors
      |> Enum.reduce_while({:ok, []}, fn {_doc_id, cursor}, {:ok, acc} ->
        case Codec.from_cursor(resource, cursor, tenant) do
          {:ok, record} ->
            if matches_attribute_tenant?(record, strategy, tenant_attr, global?, tenant) do
              {:cont, {:ok, [record | acc]}}
            else
              {:cont, {:ok, acc}}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> reverse_ok()
    end

    defp matches_attribute_tenant?(_record, :attribute, _attr, false, nil), do: false
    defp matches_attribute_tenant?(_record, :attribute, _attr, true, nil), do: true

    defp matches_attribute_tenant?(record, :attribute, tenant_attr, _global?, tenant) do
      record_tenant = Map.get(record, tenant_attr)
      Comp.equal?(record_tenant, tenant) or record_tenant == tenant
    end

    defp matches_attribute_tenant?(_record, _strategy, _attr, _global?, _tenant), do: true

    # ==========================================================================
    # Stage 3: Pure-Attribute Pre-Filtering
    # ==========================================================================

    defp stage3_prefilter(records, %__MODULE__{filter: nil}, _resource), do: {:ok, records, true}
    defp stage3_prefilter([], _query, _resource), do: {:ok, [], true}

    defp stage3_prefilter(records, %__MODULE__{filter: filter} = query, resource) do
      if filter_uses_derived_or_related?(filter, resource) do
        {:ok, records, false}
      else
        with {:ok, filtered} <- run_runtime_filter(records, query, resource) do
          {:ok, filtered, true}
        end
      end
    end

    defp filter_uses_derived_or_related?(nil, _resource), do: false

    defp filter_uses_derived_or_related?(%Ash.Filter{expression: expr}, resource) do
      expr_uses_derived_or_related?(expr, resource)
    end

    defp filter_uses_derived_or_related?(expr, resource) do
      expr_uses_derived_or_related?(expr, resource)
    end

    defp expr_uses_derived_or_related?(expr, resource) do
      found? =
        Ash.Filter.find(expr, fn
          %Ref{relationship_path: [_ | _]} ->
            true

          %Ref{attribute: %Calculation{}} ->
            true

          %Ref{attribute: %Aggregate{}} ->
            true

          %Ref{attribute: name} when is_atom(name) ->
            is_nil(Ash.Resource.Info.attribute(resource, name))

          %Ash.Query.Exists{} ->
            true

          %Parent{} ->
            true

          _other ->
            false
        end)

      not is_nil(found?)
    end

    defp run_runtime_filter([], _query, _resource), do: {:ok, []}
    defp run_runtime_filter(records, %__MODULE__{filter: nil}, _resource), do: {:ok, records}

    defp run_runtime_filter(records, %__MODULE__{} = query, _resource) do
      actor = get_in_query_context(query, :actor)

      Ash.Filter.Runtime.filter_matches(
        query.domain,
        records,
        query.filter,
        tenant: query.tenant,
        actor: actor
      )
    end

    # ==========================================================================
    # Stage 4: Derived Enrichment (Aggregates + Calculations) & Residual Filter
    # ==========================================================================

    defp stage4_enrich_and_filter(_db, [], _already_filtered?, _query, _resource), do: {:ok, []}

    defp stage4_enrich_and_filter(db_or_cursor, records, already_filtered?, query, resource) do
      with {:ok, with_aggs} <- attach_aggregates(db_or_cursor, records, query, resource),
           {:ok, with_calcs} <- attach_calculations(with_aggs, query, resource) do
        if already_filtered? do
          {:ok, with_calcs}
        else
          run_runtime_filter(with_calcs, query, resource)
        end
      end
    end

    # -- Aggregate Execution (Batched, Per-Record parent/join_filters, Unrelated) --

    defp attach_aggregates(_db, records, %__MODULE__{aggregates: []}, _resource),
      do: {:ok, records}

    defp attach_aggregates(
           db_or_cursor,
           records,
           %__MODULE__{aggregates: aggregates} = query,
           resource
         ) do
      Enum.reduce_while(aggregates, {:ok, records}, fn agg, {:ok, acc_records} ->
        case compute_and_attach_aggregate(db_or_cursor, acc_records, agg, query, resource) do
          {:ok, next_records} -> {:cont, {:ok, next_records}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp compute_and_attach_aggregate(db_or_cursor, records, %Aggregate{} = agg, query, resource) do
      cond do
        unrelated_aggregate?(agg, resource) ->
          compute_unrelated_aggregate_for_records(db_or_cursor, records, agg, query, resource)

        per_record_related_aggregate?(agg) ->
          compute_per_record_related_aggregate(db_or_cursor, records, agg, query, resource)

        true ->
          compute_batched_related_aggregate(db_or_cursor, records, agg, query, resource)
      end
    end

    defp unrelated_aggregate?(%Aggregate{related?: false}, _resource), do: true

    defp unrelated_aggregate?(%Aggregate{relationship_path: [], resource: agg_res}, resource)
         when not is_nil(agg_res) and agg_res != resource,
         do: true

    defp unrelated_aggregate?(_agg, _resource), do: false

    defp per_record_related_aggregate?(%Aggregate{} = agg) do
      join_filters = Map.get(agg, :join_filters) || %{}
      filter = get_agg_filter(agg)
      (join_filters != %{} and join_filters != []) or filter_uses_parent?(filter)
    end

    defp filter_uses_parent?(nil), do: false
    defp filter_uses_parent?(%Ash.Filter{expression: expr}), do: filter_uses_parent?(expr)

    defp filter_uses_parent?(expr) do
      not is_nil(
        Ash.Filter.find(expr, fn
          %Parent{} -> true
          _ -> false
        end)
      )
    end

    defp compute_batched_related_aggregate(
           db_or_cursor,
           records,
           %Aggregate{} = agg,
           query,
           resource
         ) do
      tenant = Map.get(agg, :tenant) || get_in_agg_context(agg, :tenant) || query.tenant
      actor = get_in_agg_context(agg, :actor) || get_in_query_context(query, :actor)
      domain = query.domain

      with {:ok, grouped_dest} <-
             walk_batched_relationship_path(
               db_or_cursor,
               resource,
               records,
               agg.relationship_path,
               tenant,
               actor,
               domain,
               %{}
             ) do
        dest_res = resolve_path_leaf_resource(resource, agg.relationship_path)
        agg_filter = get_agg_filter(agg)
        agg_sort = get_agg_sort(agg)

        all_dest =
          grouped_dest
          |> Map.values()
          |> List.flatten()

        with {:ok, prefiltered_all} <-
               apply_optional_filter(domain, all_dest, agg_filter, tenant, actor, nil),
             {:ok, loaded_all} <-
               ensure_agg_field_loaded(
                 prefiltered_all,
                 agg.field,
                 dest_res,
                 domain,
                 tenant,
                 actor
               ) do
          loaded_by_pk = index_records_by_pk(loaded_all, dest_res)
          pk_fields = Ash.Resource.Info.primary_key(dest_res)

          updated =
            records
            |> Enum.with_index()
            |> Enum.map(fn {record, idx} ->
              dest_for_parent =
                grouped_dest
                |> Map.get(idx, [])
                |> Enum.flat_map(fn dest_rec ->
                  case Map.fetch(loaded_by_pk, Map.take(dest_rec, pk_fields)) do
                    {:ok, loaded_rec} -> [loaded_rec]
                    :error -> []
                  end
                end)

              sorted =
                apply_optional_sort(dest_for_parent, agg_sort, domain: domain, tenant: tenant)

              value = compute_aggregate_value(sorted, agg, dest_res)
              put_aggregate_result(record, agg, value)
            end)

          {:ok, updated}
        end
      end
    end

    defp compute_per_record_related_aggregate(
           db_or_cursor,
           records,
           %Aggregate{} = agg,
           query,
           resource
         ) do
      tenant = Map.get(agg, :tenant) || get_in_agg_context(agg, :tenant) || query.tenant
      actor = get_in_agg_context(agg, :actor) || get_in_query_context(query, :actor)
      domain = query.domain
      join_filters = normalize_join_filters(Map.get(agg, :join_filters))
      dest_res = resolve_path_leaf_resource(resource, agg.relationship_path)
      agg_filter = get_agg_filter(agg)
      agg_sort = get_agg_sort(agg)

      with {:ok, grouped_dest} <-
             walk_batched_relationship_path(
               db_or_cursor,
               resource,
               records,
               agg.relationship_path,
               tenant,
               actor,
               domain,
               join_filters
             ) do
        records
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {parent_record, idx}, {:ok, acc} ->
          candidates = Map.get(grouped_dest, idx, [])

          with {:ok, filtered} <-
                 apply_optional_filter(
                   domain,
                   candidates,
                   agg_filter,
                   tenant,
                   actor,
                   parent_record
                 ),
               {:ok, loaded} <-
                 ensure_agg_field_loaded(filtered, agg.field, dest_res, domain, tenant, actor) do
            sorted = apply_optional_sort(loaded, agg_sort, domain: domain, tenant: tenant)
            value = compute_aggregate_value(sorted, agg, dest_res)
            {:cont, {:ok, [put_aggregate_result(parent_record, agg, value) | acc]}}
          else
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> reverse_ok()
      end
    end

    defp compute_unrelated_aggregate_for_records(
           db_or_cursor,
           records,
           %Aggregate{resource: target_res} = agg,
           query,
           resource
         ) do
      tenant = Map.get(agg, :tenant) || get_in_agg_context(agg, :tenant) || query.tenant
      actor = get_in_agg_context(agg, :actor) || get_in_query_context(query, :actor)
      domain = query.domain
      agg_filter = get_agg_filter(agg)
      agg_sort = get_agg_sort(agg)
      target_db = resolve_db_for_resource(db_or_cursor, resource, target_res)

      if filter_uses_parent?(agg_filter) do
        records
        |> Enum.reduce_while({:ok, []}, fn parent_record, {:ok, acc} ->
          resolved_filter =
            substitute_parent_in_filter(agg_filter, parent_record, resource, domain)

          sub_query = %__MODULE__{
            resource: target_res,
            domain: domain,
            filter: resolved_filter,
            tenant: tenant,
            sort: agg_sort
          }

          with {:ok, matches} <- execute(target_db, sub_query, target_res),
               {:ok, loaded} <-
                 ensure_agg_field_loaded(matches, agg.field, target_res, domain, tenant, actor) do
            value = compute_aggregate_value(loaded, agg, target_res)
            {:cont, {:ok, [put_aggregate_result(parent_record, agg, value) | acc]}}
          else
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> reverse_ok()
      else
        sub_query = %__MODULE__{
          resource: target_res,
          domain: domain,
          filter: agg_filter,
          tenant: tenant,
          sort: agg_sort
        }

        with {:ok, matches} <- execute(target_db, sub_query, target_res),
             {:ok, loaded} <-
               ensure_agg_field_loaded(matches, agg.field, target_res, domain, tenant, actor) do
          value = compute_aggregate_value(loaded, agg, target_res)
          {:ok, Enum.map(records, &put_aggregate_result(&1, agg, value))}
        end
      end
    end

    defp substitute_parent_in_filter(nil, _parent_record, _parent_resource, _domain), do: nil

    defp substitute_parent_in_filter(filter, parent_record, parent_resource, domain) do
      Ash.Filter.map(filter, fn
        %Parent{expr: p_expr} ->
          case Ash.Expr.eval(p_expr,
                 record: parent_record,
                 resource: parent_resource,
                 domain: domain
               ) do
            {:ok, value} -> value
            _ -> nil
          end

        other ->
          other
      end)
    end

    # Walks relationship steps in batch across all root parent records indexed by integer `0..n-1`.
    defp walk_batched_relationship_path(
           db_or_cursor,
           root_resource,
           root_records,
           path,
           tenant,
           actor,
           domain,
           join_filters
         ) do
      init_frontier =
        root_records
        |> Enum.with_index()
        |> Map.new(fn {rec, idx} -> {idx, [rec]} end)

      root_by_idx =
        root_records
        |> Enum.with_index()
        |> Map.new(fn {rec, idx} -> {idx, rec} end)

      do_walk_steps(
        db_or_cursor,
        root_resource,
        root_resource,
        init_frontier,
        root_by_idx,
        path,
        [],
        tenant,
        actor,
        domain,
        join_filters
      )
    end

    defp do_walk_steps(
           _db,
           _root_res,
           _curr_res,
           frontier,
           _root_by_idx,
           [],
           _prefix,
           _tenant,
           _actor,
           _domain,
           _join_filters
         ) do
      {:ok, frontier}
    end

    defp do_walk_steps(
           db_or_cursor,
           root_res,
           curr_res,
           frontier,
           root_by_idx,
           [step_name | rest_path],
           prefix,
           tenant,
           actor,
           domain,
           join_filters
         ) do
      next_prefix = prefix ++ [step_name]
      rel = Ash.Resource.Info.relationship(curr_res, step_name)

      result =
        if rel.type == :many_to_many do
          do_many_to_many_step(db_or_cursor, root_res, frontier, rel, tenant, actor, domain)
        else
          do_direct_step(db_or_cursor, root_res, frontier, rel, tenant, actor, domain)
        end

      with {:ok, next_frontier} <- result,
           {:ok, filtered_frontier} <-
             apply_step_join_filter(
               next_frontier,
               root_by_idx,
               Map.get(join_filters, next_prefix),
               domain,
               tenant,
               actor
             ) do
        do_walk_steps(
          db_or_cursor,
          root_res,
          rel.destination,
          filtered_frontier,
          root_by_idx,
          rest_path,
          next_prefix,
          tenant,
          actor,
          domain,
          join_filters
        )
      end
    end

    defp do_direct_step(db_or_cursor, root_res, frontier, rel, tenant, actor, domain) do
      all_curr = frontier |> Map.values() |> List.flatten()

      if all_curr == [] do
        {:ok, Map.new(frontier, fn {idx, _} -> {idx, []} end)}
      else
        dest_res = rel.destination
        dest_db = resolve_db_for_resource(db_or_cursor, root_res, dest_res)

        with {:ok, dest_records} <-
               hop_direct_relationship(dest_db, dest_res, all_curr, rel, tenant, actor, domain) do
          if Map.get(rel, :no_attributes?, false) do
            {:ok,
             Map.new(frontier, fn {idx, curr} ->
               {idx, if(curr == [], do: [], else: dest_records)}
             end)}
          else
            grouped = Enum.group_by(dest_records, &Map.get(&1, rel.destination_attribute))

            next_frontier =
              Map.new(frontier, fn {idx, curr_list} ->
                children =
                  Enum.flat_map(curr_list, fn c ->
                    case Map.get(c, rel.source_attribute) do
                      nil -> []
                      key -> Map.get(grouped, key, [])
                    end
                  end)

                {idx, children}
              end)

            {:ok, next_frontier}
          end
        end
      end
    end

    defp do_many_to_many_step(db_or_cursor, root_res, frontier, rel, tenant, actor, domain) do
      all_curr = frontier |> Map.values() |> List.flatten()

      if all_curr == [] do
        {:ok, Map.new(frontier, fn {idx, _} -> {idx, []} end)}
      else
        join_res = rel.through
        dest_res = rel.destination
        join_db = resolve_db_for_resource(db_or_cursor, root_res, join_res)
        dest_db = resolve_db_for_resource(db_or_cursor, root_res, dest_res)

        source_vals =
          all_curr
          |> Enum.map(&Map.get(&1, rel.source_attribute))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        with {:ok, join_records} <-
               fetch_matching_destination_records(
                 join_db,
                 join_res,
                 rel.source_attribute_on_join_resource,
                 source_vals,
                 tenant
               ),
             dest_vals =
               join_records
               |> Enum.map(&Map.get(&1, rel.destination_attribute_on_join_resource))
               |> Enum.reject(&is_nil/1)
               |> Enum.uniq(),
             {:ok, raw_dest_records} <-
               fetch_matching_destination_records(
                 dest_db,
                 dest_res,
                 rel.destination_attribute,
                 dest_vals,
                 tenant
               ),
             {:ok, filtered_dest} <-
               apply_optional_filter(domain, raw_dest_records, rel.filter, tenant, actor, nil) do
          joins_by_src =
            Enum.group_by(join_records, &Map.get(&1, rel.source_attribute_on_join_resource))

          dest_by_key = Enum.group_by(filtered_dest, &Map.get(&1, rel.destination_attribute))

          next_frontier =
            Map.new(frontier, fn {idx, curr_list} ->
              children =
                for curr <- curr_list,
                    src_val = Map.get(curr, rel.source_attribute),
                    not is_nil(src_val),
                    join_row <- Map.get(joins_by_src, src_val, []),
                    dest_val = Map.get(join_row, rel.destination_attribute_on_join_resource),
                    not is_nil(dest_val),
                    dest_row <- Map.get(dest_by_key, dest_val, []) do
                  dest_row
                end

              {idx, children}
            end)

          {:ok, next_frontier}
        end
      end
    end

    defp hop_direct_relationship(dest_db, dest_res, source_records, rel, tenant, actor, domain) do
      candidates_result =
        if Map.get(rel, :no_attributes?, false) do
          execute(
            dest_db,
            %__MODULE__{resource: dest_res, domain: domain, tenant: tenant},
            dest_res
          )
        else
          source_vals =
            source_records
            |> Enum.map(&Map.get(&1, rel.source_attribute))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          fetch_matching_destination_records(
            dest_db,
            dest_res,
            rel.destination_attribute,
            source_vals,
            tenant
          )
        end

      with {:ok, candidates} <- candidates_result do
        apply_optional_filter(domain, candidates, rel.filter, tenant, actor, nil)
      end
    end

    defp fetch_matching_destination_records(_db, _dest_res, _dest_attr, [], _tenant),
      do: {:ok, []}

    defp fetch_matching_destination_records(dest_db, dest_res, dest_attr, values, tenant) do
      [pk_name | _] = Ash.Resource.Info.primary_key(dest_res)
      nested_fk = nested_foreign_key(dest_res)

      cursors =
        cond do
          dest_attr == pk_name ->
            case resolve_pk_candidates(dest_db, dest_res, values, tenant) do
              {:cursors, found} -> found
              {:empty} -> []
            end

          nested_fk != nil and dest_attr == nested_fk ->
            fetch_nested_parent_cursors(dest_db, dest_res, values, tenant)

          true ->
            case find_leading_index(dest_res, dest_attr) do
              %{fields: [^dest_attr]} = idx ->
                doc_ids =
                  Enum.reduce(values, MapSet.new(), fn val, acc ->
                    MapSet.union(
                      acc,
                      Indexer.lookup_secondary_eq(dest_db, dest_res, idx, [val], tenant)
                    )
                  end)

                doc_ids_to_cursors(dest_db, dest_res, doc_ids, tenant)

              %{fields: [^dest_attr | _]} = composite_idx ->
                doc_ids =
                  Enum.reduce(values, MapSet.new(), fn val, acc ->
                    MapSet.union(
                      acc,
                      Indexer.scan_secondary_range(
                        dest_db,
                        dest_res,
                        composite_idx,
                        %{prefix: [val], min: :unbounded, max: :unbounded},
                        tenant
                      )
                    )
                  end)

                doc_ids_to_cursors(dest_db, dest_res, doc_ids, tenant)

              nil ->
                Indexer.all_cursors(dest_db, dest_res, tenant)
            end
        end

      with {:ok, hydrated} <- stage2_hydrate(cursors, %__MODULE__{tenant: tenant}, dest_res) do
        allowed = MapSet.new(values)
        {:ok, Enum.filter(hydrated, &MapSet.member?(allowed, Map.get(&1, dest_attr)))}
      end
    end

    defp apply_step_join_filter(frontier, _root_by_idx, nil, _domain, _tenant, _actor),
      do: {:ok, frontier}

    defp apply_step_join_filter(frontier, root_by_idx, join_filter, domain, tenant, actor) do
      if filter_uses_parent?(join_filter) do
        frontier
        |> Enum.reduce_while({:ok, %{}}, fn {idx, candidates}, {:ok, acc} ->
          parent_record = Map.fetch!(root_by_idx, idx)

          case apply_optional_filter(
                 domain,
                 candidates,
                 join_filter,
                 tenant,
                 actor,
                 parent_record
               ) do
            {:ok, kept} -> {:cont, {:ok, Map.put(acc, idx, kept)}}
            {:error, _} = err -> {:halt, err}
          end
        end)
      else
        all_candidates = frontier |> Map.values() |> List.flatten()
        # Deduplicate only for filter checking using object identity / PK where possible
        case apply_optional_filter(domain, all_candidates, join_filter, tenant, actor, nil) do
          {:ok, kept_list} ->
            kept_set = MapSet.new(kept_list)

            {:ok,
             Map.new(frontier, fn {idx, candidates} ->
               {idx, Enum.filter(candidates, &MapSet.member?(kept_set, &1))}
             end)}

          {:error, _} = err ->
            err
        end
      end
    end

    defp normalize_join_filters(nil), do: %{}
    defp normalize_join_filters(map) when is_map(map), do: map

    defp normalize_join_filters(list) when is_list(list) do
      Map.new(list, fn
        %{relationship_path: path, filter: filter} -> {path, filter}
        {path, filter} -> {path, filter}
      end)
    end

    defp resolve_path_leaf_resource(resource, []), do: resource

    defp resolve_path_leaf_resource(resource, [step | rest]) do
      rel = Ash.Resource.Info.relationship(resource, step)
      resolve_path_leaf_resource(rel.destination, rest)
    end

    defp evaluate_query_aggregates(records, aggregates, query, resource) do
      domain = query.domain
      tenant = query.tenant
      actor = get_in_query_context(query, :actor)

      Enum.reduce_while(aggregates, {:ok, %{}}, fn %Aggregate{} = agg, {:ok, acc} ->
        agg_filter = get_agg_filter(agg)
        agg_sort = get_agg_sort(agg)
        agg_res = agg.resource || resource
        agg_tenant = Map.get(agg, :tenant) || get_in_agg_context(agg, :tenant) || tenant
        agg_actor = get_in_agg_context(agg, :actor) || actor

        with {:ok, filtered} <-
               apply_optional_filter(domain, records, agg_filter, agg_tenant, agg_actor, nil),
             sorted = apply_optional_sort(filtered, agg_sort, domain: domain, tenant: agg_tenant),
             {:ok, loaded} <-
               ensure_agg_field_loaded(sorted, agg.field, agg_res, domain, agg_tenant, agg_actor) do
          value = compute_aggregate_value(loaded, agg, agg_res)
          {:cont, {:ok, Map.put(acc, agg.name, value)}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp ensure_agg_field_loaded([], _field, _res, _domain, _tenant, _actor), do: {:ok, []}
    defp ensure_agg_field_loaded(records, nil, _res, _domain, _tenant, _actor), do: {:ok, records}

    defp ensure_agg_field_loaded(records, field, resource, domain, tenant, actor) do
      if is_atom(field) and not is_nil(Ash.Resource.Info.attribute(resource, field)) do
        {:ok, records}
      else
        Ash.load(records, field, domain: domain, tenant: tenant, actor: actor, authorize?: false)
      end
    end

    defp compute_aggregate_value(records, %Aggregate{} = agg, target_resource) do
      pk_fields = Ash.Resource.Info.primary_key(target_resource)
      field = agg.field || List.first(pk_fields)
      kind = agg.kind
      uniq? = Map.get(agg, :uniq?, false)
      include_nil? = Map.get(agg, :include_nil?, false)
      default_value = Map.get(agg, :default_value)

      case kind do
        :count ->
          values =
            records
            |> Enum.map(&field_value(&1, field))
            |> Enum.reject(&is_nil/1)

          if uniq?, do: values |> Enum.uniq() |> length(), else: length(values)

        :exists ->
          records != []

        :first ->
          values =
            records
            |> Enum.map(&field_value(&1, field))
            |> then(fn vals -> if include_nil?, do: vals, else: Enum.reject(vals, &is_nil/1) end)

          case values do
            [first | _] -> first
            [] -> default_value
          end

        :list ->
          values =
            records
            |> Enum.map(&field_value(&1, field))
            |> then(fn vals -> if include_nil?, do: vals, else: Enum.reject(vals, &is_nil/1) end)
            |> then(fn vals -> if uniq?, do: Enum.uniq(vals), else: vals end)

          if values == [] and is_list(default_value), do: default_value, else: values

        :sum ->
          values = extract_non_nil_agg_values(records, field, uniq?)

          case values do
            [] ->
              default_value

            [%Decimal{} = first | rest] ->
              Enum.reduce(rest, first, &Decimal.add(&2, &1))

            [first | rest] ->
              Enum.reduce(rest, first, &(&2 + &1))
          end

        :min ->
          case extract_non_nil_agg_values(records, field, uniq?) do
            [] -> default_value
            [%Decimal{} = first | rest] -> Enum.reduce(rest, first, &Decimal.min/2)
            values -> Enum.min(values)
          end

        :max ->
          case extract_non_nil_agg_values(records, field, uniq?) do
            [] -> default_value
            [%Decimal{} = first | rest] -> Enum.reduce(rest, first, &Decimal.max/2)
            values -> Enum.max(values)
          end

        :avg ->
          values = extract_non_nil_agg_values(records, field, uniq?)

          case values do
            [] ->
              default_value

            [%Decimal{} = first | rest] ->
              total = Enum.reduce(rest, first, &Decimal.add(&2, &1))
              Decimal.div(total, Decimal.new(length(values)))

            [first | rest] ->
              total = Enum.reduce(rest, first, &(&2 + &1))
              total / length(values)
          end
      end
    end

    defp extract_non_nil_agg_values(records, field, uniq?) do
      records
      |> Enum.map(&field_value(&1, field))
      |> Enum.reject(&is_nil/1)
      |> then(fn vals -> if uniq?, do: Enum.uniq(vals), else: vals end)
    end

    defp put_aggregate_result(record, %Aggregate{load: load_key, name: name}, value) do
      aggs = record |> Map.get(:aggregates, %{}) |> Map.put(name, value)
      record = Map.put(record, :aggregates, aggs)

      if not is_nil(load_key) and is_atom(load_key) do
        Map.put(record, load_key, value)
      else
        record
      end
    end

    # -- Calculations Execution (Expressions + Hydrated Fallback + Module `calculate/3`) --

    defp attach_calculations(records, %__MODULE__{calculations: []}, _resource),
      do: {:ok, records}

    defp attach_calculations([], _query, _resource), do: {:ok, []}

    defp attach_calculations(records, %__MODULE__{calculations: calcs} = query, resource) do
      domain = query.domain
      tenant = query.tenant
      actor = get_in_query_context(query, :actor)

      Enum.reduce_while(calcs, {:ok, records}, fn {calc, expr}, {:ok, acc_records} ->
        case eval_single_calculation(acc_records, calc, expr, resource, domain, tenant, actor) do
          {:ok, updated_records} -> {:cont, {:ok, updated_records}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp eval_single_calculation(
           records,
           %Calculation{} = calc,
           expr,
           resource,
           domain,
           tenant,
           actor
         ) do
      has_expr? = expr != nil or function_exported?(calc.module, :expression, 2)

      if function_exported?(calc.module, :calculate, 3) and not has_expr? do
        eval_module_calculation(records, calc, resource, domain, tenant, actor)
      else
        effective_expr =
          cond do
            expr != nil ->
              expr

            function_exported?(calc.module, :expression, 2) ->
              calc.module.expression(calc.opts, calc.context)

            true ->
              nil
          end

        eval_expression_calculation(
          records,
          calc,
          effective_expr,
          resource,
          domain,
          tenant,
          actor
        )
      end
    end

    defp eval_module_calculation(records, %Calculation{} = calc, _resource, domain, tenant, actor) do
      with {:ok, loaded_for_calc} <- maybe_load_calc_deps(records, calc, domain, tenant, actor),
           {:ok, values} <- invoke_calc_module(calc, loaded_for_calc) do
        {:ok, zip_calculation_values(loaded_for_calc, calc, values)}
      end
    end

    defp maybe_load_calc_deps(
           records,
           %Calculation{module: mod, opts: opts, context: ctx},
           domain,
           tenant,
           actor
         ) do
      deps =
        if function_exported?(mod, :load, 3) do
          mod.load(nil, opts, ctx) || []
        else
          []
        end

      if deps == [] do
        {:ok, records}
      else
        Ash.load(records, deps, domain: domain, tenant: tenant, actor: actor, authorize?: false)
      end
    end

    defp invoke_calc_module(%Calculation{module: mod, opts: opts, context: ctx}, records) do
      case mod.calculate(records, opts, ctx) do
        {:ok, vals} when is_list(vals) -> {:ok, vals}
        {:error, _} = err -> err
        vals when is_list(vals) -> {:ok, vals}
      end
    end

    defp eval_expression_calculation(
           records,
           %Calculation{} = calc,
           expr,
           resource,
           domain,
           tenant,
           actor
         ) do
      calc_actor = get_in_calc_context(calc, :actor) || actor
      calc_tenant = get_in_calc_context(calc, :tenant) || tenant

      source_ctx =
        case Map.get(calc, :context) do
          %Ash.Resource.Calculation.Context{source_context: sc} when is_map(sc) -> sc
          ctx when is_map(ctx) and not is_struct(ctx) -> ctx
          _ -> %{}
        end

      records
      |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
        case Ash.Expr.eval(expr,
               record: record,
               resource: resource,
               domain: domain,
               actor: calc_actor,
               tenant: calc_tenant,
               context: source_ctx
             ) do
          {:ok, raw} ->
            {:ok, casted} = cast_calculation_output(calc, raw)
            {:cont, {:ok, [put_calculation_result(record, calc, casted) | acc]}}

          {:error, _} = err ->
            {:halt, err}

          :unknown ->
            case eval_hydrated_calculation(
                   record,
                   calc,
                   expr,
                   resource,
                   domain,
                   calc_tenant,
                   calc_actor,
                   source_ctx
                 ) do
              {:ok, val} -> {:cont, {:ok, [put_calculation_result(record, calc, val) | acc]}}
              {:error, _} = err -> {:halt, err}
            end
        end
      end)
      |> reverse_ok()
    end

    defp eval_hydrated_calculation(
           record,
           calc,
           expr,
           resource,
           domain,
           tenant,
           actor,
           source_ctx
         ) do
      with {:ok, hydrated} <- Ash.Filter.hydrate_refs(expr, %{resource: resource, public?: false}) do
        case Ash.Expr.eval_hydrated(hydrated,
               record: record,
               resource: resource,
               domain: domain,
               actor: actor,
               tenant: tenant,
               context: source_ctx
             ) do
          {:ok, raw} -> cast_calculation_output(calc, raw)
          {:error, _} = err -> err
          :unknown -> {:ok, nil}
        end
      end
    end

    defp cast_calculation_output(_calc, nil), do: {:ok, nil}
    defp cast_calculation_output(%Calculation{type: nil}, raw), do: {:ok, raw}

    defp cast_calculation_output(%Calculation{type: type, constraints: constraints}, raw) do
      case Ash.Type.cast_input(type, raw, constraints || []) do
        {:ok, casted} -> {:ok, casted}
        _ -> {:ok, raw}
      end
    end

    defp zip_calculation_values(records, calc, values) do
      records
      |> Enum.zip(values)
      |> Enum.map(fn {record, val} -> put_calculation_result(record, calc, val) end)
    end

    defp put_calculation_result(record, %Calculation{load: load_key, name: name}, value) do
      calcs = record |> Map.get(:calculations, %{}) |> Map.put(name, value)
      record = Map.put(record, :calculations, calcs)

      cond do
        not is_nil(load_key) and is_atom(load_key) ->
          Map.put(record, load_key, value)

        is_atom(name) and Map.has_key?(record, name) ->
          Map.put(record, name, value)

        true ->
          record
      end
    end

    # ==========================================================================
    # Stage 5: Distinct, Ordering, Offset & Limit
    # ==========================================================================

    defp stage5_order_and_slice([], _query, _resource), do: []

    defp stage5_order_and_slice(records, %__MODULE__{} = query, resource) do
      opts = [domain: query.domain, tenant: query.tenant, rekey?: false]

      records
      |> apply_distinct_and_sort(query.sort, query.distinct, query.distinct_sort, opts, resource)
      |> apply_offset(query.offset)
      |> apply_limit(query.limit)
    end

    defp apply_distinct_and_sort(records, sort, distinct, distinct_sort, opts, _resource) do
      if distinct in [nil, []] do
        apply_optional_sort(records, sort, opts)
      else
        if distinct_sort in [nil, []] do
          records
          |> apply_optional_sort(sort, opts)
          |> Sort.runtime_distinct(distinct, opts)
        else
          records
          |> apply_optional_sort(distinct_sort, opts)
          |> Sort.runtime_distinct(distinct, opts)
          |> apply_optional_sort(sort, opts)
        end
      end
    end

    defp apply_offset(records, nil), do: records
    defp apply_offset(records, offset) when is_integer(offset), do: Enum.drop(records, offset)

    defp apply_limit(records, nil), do: records
    defp apply_limit(records, limit) when is_integer(limit), do: Enum.take(records, limit)

    # ==========================================================================
    # Stage 6: Field Projection Masking
    # ==========================================================================

    defp stage6_project(records, %__MODULE__{select: nil}, _resource), do: records

    defp stage6_project(records, %__MODULE__{select: select}, resource) when is_list(select) do
      pk_fields = Ash.Resource.Info.primary_key(resource)

      always_selected =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(&Map.get(&1, :always_select?, false))
        |> Enum.map(& &1.name)

      keep_set = MapSet.new(select ++ pk_fields ++ always_selected)

      to_mask =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)
        |> Enum.reject(&MapSet.member?(keep_set, &1))

      Enum.map(records, fn record ->
        Enum.reduce(to_mask, record, fn field, acc ->
          Map.put(acc, field, %Ash.NotLoaded{type: :attribute, field: field})
        end)
      end)
    end

    # ==========================================================================
    # Shared Utilities
    # ==========================================================================

    defp normalize_domain(%__MODULE__{domain: nil} = query, resource) do
      %__MODULE__{query | domain: Ash.Resource.Info.domain(resource)}
    end

    defp normalize_domain(query, _resource), do: query

    defp resolve_db_for_resource(current_db, current_resource, target_resource) do
      if Info.store!(current_resource) == Info.store!(target_resource) do
        current_db
      else
        Store.current_db(Info.store!(target_resource))
      end
    end

    defp apply_optional_filter(_domain, records, nil, _tenant, _actor, _parent),
      do: {:ok, records}

    defp apply_optional_filter(domain, records, filter, tenant, actor, parent) do
      opts =
        [tenant: tenant, actor: actor]
        |> then(fn o -> if parent, do: Keyword.put(o, :parent, parent), else: o end)

      Ash.Filter.Runtime.filter_matches(domain, records, filter, opts)
    end

    defp apply_optional_sort(records, nil, _opts), do: records
    defp apply_optional_sort(records, [], _opts), do: records
    defp apply_optional_sort([], _sort, _opts), do: []

    defp apply_optional_sort(records, sort, opts) do
      Sort.runtime_sort(records, sort, Keyword.put_new(opts, :rekey?, false))
    end

    defp index_records_by_pk(records, resource) do
      pk_fields = Ash.Resource.Info.primary_key(resource)
      Map.new(records, fn rec -> {Map.take(rec, pk_fields), rec} end)
    end

    defp get_agg_filter(%Aggregate{query: %{filter: filter}}), do: filter
    defp get_agg_filter(_), do: nil

    defp get_agg_sort(%Aggregate{query: %{sort: sort}}), do: sort
    defp get_agg_sort(_), do: nil

    defp get_in_query_context(%__MODULE__{context: %{private: %{actor: actor}}}, :actor),
      do: actor

    defp get_in_query_context(%__MODULE__{context: %{actor: actor}}, :actor), do: actor
    defp get_in_query_context(_, _), do: nil

    defp get_in_agg_context(%Aggregate{context: %{actor: actor}}, :actor), do: actor
    defp get_in_agg_context(%Aggregate{context: %{tenant: tenant}}, :tenant), do: tenant
    defp get_in_agg_context(_, _), do: nil

    defp get_in_calc_context(%Calculation{context: %{actor: actor}}, :actor), do: actor
    defp get_in_calc_context(%Calculation{context: %{tenant: tenant}}, :tenant), do: tenant
    defp get_in_calc_context(_, _), do: nil

    defp field_value(record, field) do
      cond do
        Map.has_key?(record, field) and not match?(%Ash.NotLoaded{}, Map.get(record, field)) ->
          Map.get(record, field)

        Map.has_key?(Map.get(record, :calculations, %{}), field) ->
          record.calculations[field]

        Map.has_key?(Map.get(record, :aggregates, %{}), field) ->
          record.aggregates[field]

        true ->
          nil
      end
    end

    defp find_leading_index(resource, field) do
      Info.indexes_for_field(resource, field) |> List.first()
    end

    defp reverse_ok({:ok, rev}), do: {:ok, Enum.reverse(rev)}
    defp reverse_ok({:error, _} = err), do: err
  end
end
