# Reference: `Xitdb.Ash.Query`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_query_engine_20261111`](./index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Module:** `lib/xitdb/ash/query.ex`
> - **Purpose:** Complete specification and reference implementation for the six-stage query execution engine, index pushdown planner, and aggregate computer for `Xitdb.Ash.DataLayer`.

---

## 1. Concurrency, Execution & Safety Invariants

### 1.1 Conjunctive Index & Composite Range Pushdown
Stage 1 decomposes conjunctive predicates into `O(1)` primary-key lookups, `O(1)` `nested_in` parent subtree jumps, `O(log N)` unique identity lookups, and composite B+Tree prefix + range scans (`<, <=, ==, in, >=, >`) before hydrating structs.

### 1.2 Cross-Store Aggregates & `Ash.NotLoaded` Projection
Relationship hops inside `add_aggregates/3` and `run_aggregate_query/3` resolve each destination resource's `Store.current_db/1` handle independently so aggregates work seamlessly across `connect_mdm.xit` and `connect_app.xit`, while Stage 6 masks unselected fields to `%Ash.NotLoaded{}` only after filtering and sorting finish.

### 1.3 Gradual Type-System Cleanliness (Elixir 1.19–1.20+)
Dynamic `%Resource{}` structs are updated via `Map.put/3` and `Map.merge/2` rather than untyped `%{record | ...}` map-update syntax so `mix compile --warnings-as-errors` stays clean.

---

## 2. Reference Implementation: `lib/xitdb/ash/query.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Query do
    @moduledoc """
    Data-layer query struct and 6-stage planner/executor for `Xitdb.Ash.DataLayer`.

    Executes Stage 1 index/subtree narrowing -> Stage 2 cursor hydration ->
    Stage 3 pure-attribute pre-filtering -> Stage 4 derived enrichment &
    `Ash.Filter.Runtime` evaluation -> Stage 5 `distinct` / `runtime_sort` / slice ->
    Stage 6 `select` field masking.
    """

    alias Ash.Query.{Aggregate, BooleanExpression, Calculation, Not, Ref}

    alias Ash.Query.Operator.{
      Eq,
      GreaterThan,
      GreaterThanOrEqual,
      In,
      IsNil,
      LessThan,
      LessThanOrEqual
    }

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

    @doc """
    Executes `query` against `db` using the 6-stage index pushdown and runtime pipeline.
    """
    @spec execute(term(), t(), module()) :: {:ok, [struct()]} | {:error, term()}
    def execute(db, %__MODULE__{} = query, resource) when is_atom(resource) do
      with {:ok, candidate_cursors} <- stage1_narrow(db, query, resource),
           {:ok, hydrated} <- stage2_hydrate(candidate_cursors, query, resource),
           {:ok, prefiltered, filter_done?} <- stage3_prefilter(hydrated, query),
           {:ok, matched} <- stage4_enrich_and_filter(db, prefiltered, query, resource, filter_done?) do
        shaped =
          matched
          |> stage5_order_and_slice(query)
          |> stage6_project(query, resource)

        {:ok, shaped}
      end
    end

    @doc """
    Computes `aggregates` (`:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg`)
    over the records matching `query`.
    """
    @spec execute_aggregates(term(), t(), [Aggregate.t()], module()) ::
            {:ok, %{optional(atom()) => term()}} | {:error, term()}
    def execute_aggregates(db, %__MODULE__{} = query, aggregates, resource)
        when is_list(aggregates) and is_atom(resource) do
      unprojected_query = %__MODULE__{query | select: nil}

      with {:ok, records} <- execute(db, unprojected_query, resource) do
        Enum.reduce_while(aggregates, {:ok, %{}}, fn %Aggregate{} = agg, {:ok, acc} ->
          case compute_query_level_aggregate(db, records, agg, query, resource) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, agg.name, value)}}
            {:error, _} = err -> {:halt, err}
          end
        end)
      end
    end

    # -- Stage 1: Conjunctive Index, Identity & Subtree Pushdown --

    defp stage1_narrow(db, %__MODULE__{} = query, resource) do
      conjuncts =
        query.filter
        |> extract_conjuncts()
        |> maybe_add_attribute_tenant_conjunct(resource, query.tenant)

      case plan_narrowing(db, resource, conjuncts, query.tenant) do
        {:empty} ->
          {:ok, []}

        {:cursors, cursors} ->
          {:ok, cursors}

        {:doc_ids, doc_ids} ->
          cursors =
            Enum.flat_map(doc_ids, fn doc_id ->
              with {:ok, pk_val} <- Codec.decode_doc_id(resource, doc_id),
                   {:ok, cursor} <- Indexer.fetch_cursor(db, resource, pk_val) do
                [{doc_id, cursor}]
              else
                _ -> []
              end
            end)

          {:ok, cursors}

        :full_scan ->
          {:ok, Indexer.all_cursors(db, resource)}
      end
    end

    defp plan_narrowing(_db, _resource, [], _tenant), do: :full_scan

    defp plan_narrowing(db, resource, conjuncts, tenant) do
      eq_map = collect_equality_predicates(conjuncts)
      range_map = collect_range_predicates(conjuncts)
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      nested = Info.nested_in(resource)

      cond do
        # 1. Primary-key equality / `in` -> O(1) cursor fetch
        Map.has_key?(eq_map, pk_name) ->
          resolve_pk_candidates(db, resource, Map.fetch!(eq_map, pk_name))

        # 2. Unconditional unique identity equality -> O(log N) B+Tree lookup
        (identity_hit = try_unique_identity_lookup(db, resource, eq_map, tenant)) != :no_match ->
          identity_hit

        # 3. `nested_in` parent FK equality -> O(1) subtree jump (optionally intersected with secondary indexes)
        nested != nil and Map.has_key?(eq_map, nested.foreign_key) ->
          parent_vals = Map.fetch!(eq_map, nested.foreign_key)
          nested_cursors = fetch_nested_parent_cursors(db, resource, parent_vals)
          intersect_cursors_with_secondary(db, resource, nested_cursors, eq_map, range_map, nested.foreign_key)

        # 4. Secondary B+Tree equality, `in`, or composite prefix + range intersection
        true ->
          intersect_secondary_indexes(db, resource, eq_map, range_map, nil)
      end
    end

    defp resolve_pk_candidates(_db, _resource, []), do: {:empty}

    defp resolve_pk_candidates(db, resource, pk_values) do
      cursors =
        pk_values
        |> Enum.uniq_by(&Codec.encode_doc_id/1)
        |> Enum.flat_map(fn pk_val ->
          if is_nil(pk_val) do
            []
          else
            case Indexer.fetch_cursor(db, resource, pk_val) do
              {:ok, cursor} -> [{Codec.encode_doc_id(pk_val), cursor}]
              :none -> []
            end
          end
        end)

      if cursors == [], do: {:empty}, else: {:cursors, cursors}
    end

    defp try_unique_identity_lookup(db, resource, eq_map, tenant) do
      unconditional_identities =
        resource
        |> Ash.Resource.Info.identities()
        |> Enum.filter(fn id ->
          is_nil(Map.get(id, :where)) and
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

          case Indexer.lookup_by_identity(db, resource, identity, key_map, tenant) do
            {:ok, doc_id} -> {:doc_ids, MapSet.new([doc_id])}
            :none -> {:empty}
          end
      end
    end

    defp fetch_nested_parent_cursors(_db, _resource, []), do: []

    defp fetch_nested_parent_cursors(db, resource, parent_vals) do
      parent_vals
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&Codec.encode_doc_id/1)
      |> Enum.flat_map(&Indexer.nested_cursors_for_parent(db, resource, &1))
    end

    defp intersect_cursors_with_secondary(_db, _resource, [], _eq_map, _range_map, _skip_field) do
      {:empty}
    end

    defp intersect_cursors_with_secondary(db, resource, cursors, eq_map, range_map, skip_field) do
      case intersect_secondary_indexes(db, resource, Map.delete(eq_map, skip_field), range_map, skip_field) do
        :full_scan ->
          {:cursors, cursors}

        {:empty} ->
          {:empty}

        {:doc_ids, allowed_ids} ->
          narrowed = Enum.filter(cursors, fn {doc_id, _} -> MapSet.member?(allowed_ids, doc_id) end)
          if narrowed == [], do: {:empty}, else: {:cursors, narrowed}
      end
    end

    defp intersect_secondary_indexes(db, resource, eq_map, range_map, skip_field) do
      resource
      |> Info.indexes()
      |> Enum.reject(fn %{fields: [first | _]} -> first == skip_field end)
      |> Enum.reduce_while(:full_scan, fn index_spec, acc ->
        case evaluate_index_spec(db, resource, index_spec, eq_map, range_map) do
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

    defp evaluate_index_spec(db, resource, %{fields: [single_field]} = index_spec, eq_map, range_map) do
      cond do
        Map.has_key?(eq_map, single_field) ->
          eq_map
          |> Map.fetch!(single_field)
          |> Enum.reduce(MapSet.new(), fn val, acc ->
            MapSet.union(acc, Indexer.lookup_secondary_eq(db, resource, index_spec, [val]))
          end)

        Map.has_key?(range_map, single_field) ->
          bounds = Map.fetch!(range_map, single_field)
          Indexer.scan_secondary_range(db, resource, index_spec, bounds)

        true ->
          :not_applicable
      end
    end

    defp evaluate_index_spec(db, resource, %{fields: fields} = index_spec, eq_map, range_map) do
      {prefix_fields, remaining} =
        Enum.split_while(fields, fn f ->
          match?([_single], Map.get(eq_map, f))
        end)

      prefix_vals = Enum.map(prefix_fields, fn f -> hd(Map.fetch!(eq_map, f)) end)

      cond do
        # Full multi-column equality match
        remaining == [] ->
          Indexer.lookup_secondary_eq(db, resource, index_spec, prefix_vals)

        # Prefix equality + next-column range (or pure prefix equality)
        prefix_fields != [] ->
          [next_field | _] = remaining

          range_bounds =
            case Map.get(range_map, next_field) do
              nil -> %{prefix: prefix_vals}
              bounds -> Map.put(bounds, :prefix, prefix_vals)
            end

          Indexer.scan_secondary_range(db, resource, index_spec, range_bounds)

        # Leading column range without equality prefix
        Map.has_key?(range_map, hd(fields)) ->
          bounds = Map.fetch!(range_map, hd(fields))
          Indexer.scan_secondary_range(db, resource, index_spec, bounds)

        true ->
          :not_applicable
      end
    end

    # -- Stage 2: Cursor Hydration --

    defp stage2_hydrate(cursors, %__MODULE__{tenant: tenant}, resource) do
      cursors
      |> Enum.reduce_while({:ok, []}, fn {_doc_id, cursor}, {:ok, acc} ->
        case Codec.from_cursor(resource, cursor, tenant) do
          {:ok, record} ->
            if matches_attribute_tenant?(resource, record, tenant) do
              {:cont, {:ok, [record | acc]}}
            else
              {:cont, {:ok, acc}}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, rev} -> {:ok, Enum.reverse(rev)}
        {:error, _} = err -> err
      end
    end

    defp matches_attribute_tenant?(_resource, _record, nil), do: true

    defp matches_attribute_tenant?(resource, record, tenant) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
        tenant_attr = Ash.Resource.Info.multitenancy_attribute(resource)
        Map.get(record, tenant_attr) == tenant
      else
        true
      end
    end

    # -- Stage 3: Pure-Attribute Pre-Filter --

    defp stage3_prefilter(records, %__MODULE__{filter: nil}), do: {:ok, records, true}
    defp stage3_prefilter([], _query), do: {:ok, [], true}

    defp stage3_prefilter(records, %__MODULE__{} = query) do
      if filter_uses_derived_or_related?(query.filter) do
        {:ok, records, false}
      else
        case run_runtime_filter(records, query) do
          {:ok, filtered} -> {:ok, filtered, true}
          {:error, _} = err -> err
        end
      end
    end

    # -- Stage 4: Derived Enrichment (`aggregates` + `calculations`) & Residual Filter --

    defp stage4_enrich_and_filter(_db, [], _query, _resource, _filter_done?), do: {:ok, []}

    defp stage4_enrich_and_filter(db, records, %__MODULE__{} = query, resource, filter_done?) do
      with {:ok, with_aggs} <- attach_aggregates(db, records, query, resource),
           {:ok, enriched} <- attach_calculations(with_aggs, query, resource) do
        if filter_done? or is_nil(query.filter) do
          {:ok, enriched}
        else
          run_runtime_filter(enriched, query)
        end
      end
    end

    defp run_runtime_filter(records, %__MODULE__{} = query) do
      actor = get_in(query.context, [:private, :actor])

      Ash.Filter.Runtime.filter_matches(
        query.domain,
        records,
        query.filter,
        actor: actor,
        tenant: query.tenant,
        authorize?: false
      )
    end

    # -- Stage 5: Distinct, Runtime Sort & Offset/Limit --

    defp stage5_order_and_slice([], _query), do: []

    defp stage5_order_and_slice(records, %__MODULE__{} = query) do
      records
      |> apply_distinct(query)
      |> apply_sort(query.sort, query.domain)
      |> apply_offset(query.offset)
      |> apply_limit(query.limit)
    end

    defp apply_distinct(records, %__MODULE__{distinct: nil}), do: records
    defp apply_distinct(records, %__MODULE__{distinct: []}), do: records

    defp apply_distinct(records, %__MODULE__{} = query) do
      distinct_fields = normalize_distinct_fields(query.distinct)
      pre_sort = query.distinct_sort || query.sort

      records
      |> apply_sort(pre_sort, query.domain)
      |> Enum.uniq_by(fn record ->
        Enum.map(distinct_fields, &fetch_record_field(record, &1))
      end)
    end

    defp normalize_distinct_fields(fields) when is_list(fields) do
      Enum.map(fields, fn
        {field, _dir} when is_atom(field) -> field
        field when is_atom(field) -> field
      end)
    end

    defp apply_sort(records, nil, _domain), do: records
    defp apply_sort(records, [], _domain), do: records

    defp apply_sort(records, sort, domain) do
      Ash.Actions.Sort.runtime_sort(records, sort, domain: domain)
    end

    defp apply_offset(records, nil), do: records
    defp apply_offset(records, 0), do: records
    defp apply_offset(records, offset) when is_integer(offset) and offset > 0, do: Enum.drop(records, offset)

    defp apply_limit(records, nil), do: records
    defp apply_limit(records, limit) when is_integer(limit) and limit >= 0, do: Enum.take(records, limit)

    # -- Stage 6: Attribute Selection Projection --

    defp stage6_project(records, %__MODULE__{select: nil}, _resource), do: records

    defp stage6_project(records, %__MODULE__{select: selected}, resource) when is_list(selected) do
      pk_fields = Ash.Resource.Info.primary_key(resource)

      always_selected =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(&Map.get(&1, :always_selected?, false))
        |> Enum.map(& &1.name)

      keep_set =
        selected
        |> Kernel.++(pk_fields)
        |> Kernel.++(always_selected)
        |> MapSet.new()

      unselected_attrs =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)
        |> Enum.reject(&MapSet.member?(keep_set, &1))

      if unselected_attrs == [] do
        records
      else
        not_loaded_mask =
          Map.new(unselected_attrs, fn attr_name ->
            {attr_name, %Ash.NotLoaded{type: :attribute, field: attr_name}}
          end)

        Enum.map(records, &Map.merge(&1, not_loaded_mask))
      end
    end

    # -- Aggregate & Calculation Engines --

    defp attach_aggregates(_db, records, %__MODULE__{aggregates: []}, _resource), do: {:ok, records}

    defp attach_aggregates(db, records, %__MODULE__{aggregates: aggregates} = query, resource) do
      Enum.reduce_while(aggregates, {:ok, records}, fn %Aggregate{} = agg, {:ok, current_records} ->
        case compute_aggregate_for_records(db, current_records, agg, query, resource) do
          {:ok, updated_records} -> {:cont, {:ok, updated_records}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp compute_aggregate_for_records(db, records, %Aggregate{} = agg, query, resource) do
      records
      |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
        with {:ok, target_records} <- resolve_related_targets(db, [record], resource, agg, query),
             {:ok, value} <- reduce_aggregate_value(target_records, agg) do
          {:cont, {:ok, [put_aggregate_result(record, agg, value) | acc]}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, rev} -> {:ok, Enum.reverse(rev)}
        {:error, _} = err -> err
      end
    end

    defp compute_query_level_aggregate(db, root_records, %Aggregate{} = agg, query, resource) do
      with {:ok, target_records} <- resolve_related_targets(db, root_records, resource, agg, query) do
        reduce_aggregate_value(target_records, agg)
      end
    end

    defp resolve_related_targets(_db, [], _resource, _agg, _query), do: {:ok, []}

    defp resolve_related_targets(db, source_records, resource, %Aggregate{} = agg, root_query) do
      rel_path = Map.get(agg, :relationship_path, [])

      with {:ok, terminal_res, candidates} <- walk_relationship_path(db, source_records, resource, rel_path, root_query.tenant) do
        apply_aggregate_subquery(candidates, terminal_res, agg, root_query)
      end
    end

    defp walk_relationship_path(_db, current_records, current_res, [], _tenant) do
      {:ok, current_res, current_records}
    end

    defp walk_relationship_path(_db, [], current_res, _rest_path, _tenant) do
      {:ok, current_res, []}
    end

    defp walk_relationship_path(db, current_records, current_res, [rel_name | rest], tenant) do
      rel = Ash.Resource.Info.relationship(current_res, rel_name)

      case hop_relationship(current_records, rel, tenant) do
        {:ok, next_records} ->
          walk_relationship_path(db, next_records, rel.destination, rest, tenant)

        {:error, _} = err ->
          err
      end
    end

    defp hop_relationship(source_records, %{type: :many_to_many} = rel, tenant) do
      join_rel = Ash.Resource.Info.relationship(rel.source, rel.join_relationship)

      with {:ok, through_records} <- hop_direct_relationship(source_records, join_rel, tenant) do
        dest_fk_vals =
          through_records
          |> Enum.map(&Map.get(&1, rel.destination_attribute_on_join_resource))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        fetch_matching_destination_records(rel.destination, rel.destination_attribute, dest_fk_vals, tenant)
      end
    end

    defp hop_relationship(source_records, rel, tenant) do
      hop_direct_relationship(source_records, rel, tenant)
    end

    defp hop_direct_relationship(source_records, rel, tenant) do
      source_vals =
        if Map.get(rel, :no_attributes?, false) do
          [:all]
        else
          source_records
          |> Enum.map(&Map.get(&1, rel.source_attribute))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
        end

      cond do
        source_vals == [] ->
          {:ok, []}

        source_vals == [:all] ->
          dest_store = Info.store!(rel.destination)
          dest_db = Store.current_db(dest_store)
          dest_query = %__MODULE__{resource: rel.destination, domain: rel.domain, tenant: tenant}
          execute(dest_db, dest_query, rel.destination)

        true ->
          fetch_matching_destination_records(rel.destination, rel.destination_attribute, source_vals, tenant)
      end
    end

    defp fetch_matching_destination_records(_dest_res, _dest_attr, [], _tenant), do: {:ok, []}

    defp fetch_matching_destination_records(dest_res, dest_attr, values, tenant) do
      dest_db = Store.current_db(Info.store!(dest_res))
      [pk_name | _] = Ash.Resource.Info.primary_key(dest_res)
      nested = Info.nested_in(dest_res)

      cursors =
        cond do
          dest_attr == pk_name ->
            case resolve_pk_candidates(dest_db, dest_res, values) do
              {:cursors, found} -> found
              {:empty} -> []
            end

          nested != nil and dest_attr == nested.foreign_key ->
            fetch_nested_parent_cursors(dest_db, dest_res, values)

          true ->
            case Info.indexes_for_field(dest_res, dest_attr) do
              [%{fields: [^dest_attr]} = idx | _] ->
                doc_ids =
                  Enum.reduce(values, MapSet.new(), fn val, acc ->
                    MapSet.union(acc, Indexer.lookup_secondary_eq(dest_db, dest_res, idx, [val]))
                  end)

                Enum.flat_map(doc_ids, fn doc_id ->
                  with {:ok, pk_val} <- Codec.decode_doc_id(dest_res, doc_id),
                       {:ok, cursor} <- Indexer.fetch_cursor(dest_db, dest_res, pk_val) do
                    [{doc_id, cursor}]
                  else
                    _ -> []
                  end
                end)

              _ ->
                Indexer.all_cursors(dest_db, dest_res)
            end
        end

      with {:ok, hydrated} <- stage2_hydrate(cursors, %__MODULE__{tenant: tenant}, dest_res) do
        allowed = MapSet.new(values)
        {:ok, Enum.filter(hydrated, &MapSet.member?(allowed, Map.get(&1, dest_attr)))}
      end
    end

    defp apply_aggregate_subquery(records, _terminal_res, %Aggregate{query: nil}, _root_query) do
      {:ok, records}
    end

    defp apply_aggregate_subquery(records, terminal_res, %Aggregate{query: agg_query}, root_query) do
      domain = agg_query.domain || root_query.domain
      tenant = agg_query.tenant || root_query.tenant

      filtered_result =
        if is_nil(agg_query.filter) do
          {:ok, records}
        else
          sub_q = %__MODULE__{
            resource: terminal_res,
            domain: domain,
            filter: agg_query.filter,
            tenant: tenant,
            context: root_query.context
          }

          run_runtime_filter(records, sub_q)
        end

      case filtered_result do
        {:ok, matched} -> {:ok, apply_sort(matched, agg_query.sort, domain)}
        {:error, _} = err -> err
      end
    end

    defp reduce_aggregate_value(records, %Aggregate{kind: :exists}) do
      {:ok, records != []}
    end

    defp reduce_aggregate_value(records, %Aggregate{kind: :count} = agg) do
      field = agg.field

      values =
        if is_nil(field) do
          records
        else
          records
          |> Enum.map(&extract_agg_field(&1, agg))
          |> Enum.reject(&is_nil/1)
        end

      values = if Map.get(agg, :uniq?, false), do: Enum.uniq(values), else: values
      {:ok, length(values)}
    end

    defp reduce_aggregate_value(records, %Aggregate{kind: :first} = agg) do
      values = extract_agg_values(records, agg)

      case values do
        [first | _] -> {:ok, first}
        [] -> {:ok, Map.get(agg, :default_value)}
      end
    end

    defp reduce_aggregate_value(records, %Aggregate{kind: :list} = agg) do
      values = extract_agg_values(records, agg)
      values = if Map.get(agg, :uniq?, false), do: Enum.uniq(values), else: values
      {:ok, values}
    end

    defp reduce_aggregate_value(records, %Aggregate{kind: :sum} = agg) do
      values =
        records
        |> Enum.map(&extract_agg_field(&1, agg))
        |> Enum.reject(&is_nil/1)

      values = if Map.get(agg, :uniq?, false), do: Enum.uniq(values), else: values

      case values do
        [] -> {:ok, Map.get(agg, :default_value)}
        [head | _] when is_struct(head, Decimal) -> {:ok, Enum.reduce(values, Decimal.new(0), &Decimal.add/2)}
        nums -> {:ok, Enum.sum(nums)}
      end
    end

    defp reduce_aggregate_value(records, %Aggregate{kind: kind} = agg) when kind in [:min, :max] do
      values =
        records
        |> Enum.map(&extract_agg_field(&1, agg))
        |> Enum.reject(&is_nil/1)

      case values do
        [] ->
          {:ok, Map.get(agg, :default_value)}

        [head | tail] ->
          reducer =
            if kind == :min do
              fn v, best -> if compare_agg_vals(v, best) == :lt, do: v, else: best end
            else
              fn v, best -> if compare_agg_vals(v, best) == :gt, do: v, else: best end
            end

          {:ok, Enum.reduce(tail, head, reducer)}
      end
    end

    defp reduce_aggregate_value(records, %Aggregate{kind: :avg} = agg) do
      values =
        records
        |> Enum.map(&extract_agg_field(&1, agg))
        |> Enum.reject(&is_nil/1)

      values = if Map.get(agg, :uniq?, false), do: Enum.uniq(values), else: values

      case values do
        [] ->
          {:ok, Map.get(agg, :default_value)}

        [head | _] when is_struct(head, Decimal) ->
          sum = Enum.reduce(values, Decimal.new(0), &Decimal.add/2)
          {:ok, Decimal.div(sum, Decimal.new(length(values)))}

        nums ->
          {:ok, Enum.sum(nums) / length(nums)}
      end
    end

    defp extract_agg_values(records, %Aggregate{} = agg) do
      include_nil? = Map.get(agg, :include_nil?, false)
      raw = Enum.map(records, &extract_agg_field(&1, agg))
      if include_nil?, do: raw, else: Enum.reject(raw, &is_nil/1)
    end

    defp extract_agg_field(record, %Aggregate{field: nil}), do: record

    defp extract_agg_field(record, %Aggregate{field: field}) when is_atom(field) do
      fetch_record_field(record, field)
    end

    defp extract_agg_field(record, %Aggregate{field: %Calculation{} = calc}) do
      case eval_single_calculation(record, calc, nil, nil, nil) do
        {:ok, val} -> val
        _ -> nil
      end
    end

    defp compare_agg_vals(%Decimal{} = a, %Decimal{} = b), do: Decimal.compare(a, b)
    defp compare_agg_vals(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
    defp compare_agg_vals(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)
    defp compare_agg_vals(%Date{} = a, %Date{} = b), do: Date.compare(a, b)
    defp compare_agg_vals(%Time{} = a, %Time{} = b), do: Time.compare(a, b)

    defp compare_agg_vals(%Ash.CiString{} = a, %Ash.CiString{} = b) do
      Ash.CiString.compare(a, b)
    end

    defp compare_agg_vals(a, b) when a < b, do: :lt
    defp compare_agg_vals(a, b) when a > b, do: :gt
    defp compare_agg_vals(_a, _b), do: :eq

    defp put_aggregate_result(record, %Aggregate{load: nil, name: name}, value) do
      aggs = record |> Map.get(:aggregates, %{}) |> Map.put(name, value)
      Map.put(record, :aggregates, aggs)
    end

    defp put_aggregate_result(record, %Aggregate{load: load_key}, value) do
      Map.put(record, load_key, value)
    end

    defp attach_calculations(records, %__MODULE__{calculations: []}, _resource), do: {:ok, records}

    defp attach_calculations(records, %__MODULE__{calculations: calcs} = query, resource) do
      actor = get_in(query.context, [:private, :actor])

      Enum.reduce_while(calcs, {:ok, records}, fn entry, {:ok, current_records} ->
        {calc, expr} =
          case entry do
            {%Calculation{} = c, e} -> {c, e}
            %Calculation{} = c -> {c, nil}
          end

        case evaluate_calculation_batch(current_records, calc, expr, resource, query, actor) do
          {:ok, next_records} -> {:cont, {:ok, next_records}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp evaluate_calculation_batch(records, %Calculation{} = calc, expr, resource, query, actor) do
      cond do
        expr != nil ->
          eval_expr_calculation_batch(records, calc, expr, resource, query, actor)

        function_exported?(calc.module, :calculate, 3) ->
          case calc.module.calculate(records, calc.opts, calc.context) do
            {:ok, values} ->
              {:ok, zip_calculation_values(records, calc, values)}

            values when is_list(values) ->
              {:ok, zip_calculation_values(records, calc, values)}

            {:error, _} = err ->
              err
          end

        function_exported?(calc.module, :expression, 2) ->
          mod_expr = calc.module.expression(calc.opts, calc.context)
          eval_expr_calculation_batch(records, calc, mod_expr, resource, query, actor)

        true ->
          {:ok, records}
      end
    end

    defp eval_expr_calculation_batch(records, %Calculation{} = calc, expr, resource, query, actor) do
      records
      |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
        case eval_single_calculation(record, calc, expr, {resource, query.domain, query.tenant}, actor) do
          {:ok, val} -> {:cont, {:ok, [put_calculation_result(record, calc, val) | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, rev} -> {:ok, Enum.reverse(rev)}
        {:error, _} = err -> err
      end
    end

    defp eval_single_calculation(record, %Calculation{} = calc, expr, meta_tuple, actor) do
      effective_expr =
        cond do
          expr != nil -> expr
          function_exported?(calc.module, :expression, 2) -> calc.module.expression(calc.opts, calc.context)
          true -> nil
        end

      {resource, domain, tenant} = meta_tuple || {record.__struct__, nil, nil}

      case Ash.Expr.eval(
             effective_expr,
             record: record,
             resource: resource,
             domain: domain,
             actor: actor,
             tenant: tenant,
             context: Map.get(calc, :context, %{})
           ) do
        {:ok, raw} -> cast_calculation_output(calc, raw)
        {:error, _} = err -> err
        :unknown -> {:ok, nil}
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

    defp put_calculation_result(record, %Calculation{load: nil, name: name}, value) do
      calcs = record |> Map.get(:calculations, %{}) |> Map.put(name, value)
      Map.put(record, :calculations, calcs)
    end

    defp put_calculation_result(record, %Calculation{load: load_key}, value) do
      Map.put(record, load_key, value)
    end

    # -- Filter AST Inspection Helpers --

    defp extract_conjuncts(nil), do: []
    defp extract_conjuncts(%Ash.Filter{expression: expr}), do: extract_conjuncts(expr)

    defp extract_conjuncts(%BooleanExpression{op: :and, left: left, right: right}) do
      extract_conjuncts(left) ++ extract_conjuncts(right)
    end

    defp extract_conjuncts(other), do: [other]

    defp maybe_add_attribute_tenant_conjunct(conjuncts, _resource, nil), do: conjuncts

    defp maybe_add_attribute_tenant_conjunct(conjuncts, resource, tenant) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
        tenant_attr = Ash.Resource.Info.multitenancy_attribute(resource)
        attr = Ash.Resource.Info.attribute(resource, tenant_attr)
        ref = %Ref{attribute: attr, relationship_path: [], resource: resource}
        [%Eq{left: ref, right: tenant} | conjuncts]
      else
        conjuncts
      end
    end

    defp collect_equality_predicates(conjuncts) do
      Enum.reduce(conjuncts, %{}, fn expr, acc ->
        case extract_eq_or_in(expr) do
          {:ok, field, values} ->
            Map.update(acc, field, values, fn prev -> intersect_value_lists(prev, values) end)

          :none ->
            acc
        end
      end)
    end

    defp extract_eq_or_in(%Eq{left: left, right: right}) do
      cond do
        local_attr_ref?(left) and literal_value?(right) ->
          {:ok, ref_field_name(left), [right]}

        local_attr_ref?(right) and literal_value?(left) ->
          {:ok, ref_field_name(right), [left]}

        true ->
          :none
      end
    end

    defp extract_eq_or_in(%IsNil{left: left, right: true}) do
      if local_attr_ref?(left), do: {:ok, ref_field_name(left), [nil]}, else: :none
    end

    defp extract_eq_or_in(%In{left: left, right: right}) do
      if local_attr_ref?(left) and (is_list(right) or is_struct(right, MapSet)) do
        list = Enum.to_list(right)

        if Enum.all?(list, &literal_value?/1) do
          {:ok, ref_field_name(left), list}
        else
          :none
        end
      else
        :none
      end
    end

    defp extract_eq_or_in(_other), do: :none

    defp intersect_value_lists(a, b) do
      Enum.filter(a, fn x -> Enum.any?(b, &values_equal?(x, &1)) end)
    end

    defp values_equal?(%Ash.CiString{} = a, %Ash.CiString{} = b), do: Ash.CiString.compare(a, b) == :eq
    defp values_equal?(%Ash.CiString{} = a, b) when is_binary(b), do: String.downcase(Ash.CiString.value(a)) == String.downcase(b)
    defp values_equal?(a, %Ash.CiString{} = b) when is_binary(a), do: String.downcase(a) == String.downcase(Ash.CiString.value(b))
    defp values_equal?(a, b), do: a == b

    defp collect_range_predicates(conjuncts) do
      Enum.reduce(conjuncts, %{}, fn expr, acc ->
        case extract_range_bound(expr) do
          {:ok, field, bound_kind, bound} ->
            Map.update(acc, field, %{bound_kind => bound}, fn existing ->
              merge_range_bound(existing, bound_kind, bound)
            end)

          :none ->
            acc
        end
      end)
    end

    defp extract_range_bound(%GreaterThan{left: l, right: r}), do: orient_range(l, r, :gt)
    defp extract_range_bound(%GreaterThanOrEqual{left: l, right: r}), do: orient_range(l, r, :gte)
    defp extract_range_bound(%LessThan{left: l, right: r}), do: orient_range(l, r, :lt)
    defp extract_range_bound(%LessThanOrEqual{left: l, right: r}), do: orient_range(l, r, :lte)
    defp extract_range_bound(_other), do: :none

    defp orient_range(left, right, op) do
      cond do
        local_attr_ref?(left) and non_nil_literal?(right) ->
          to_bound_tuple(ref_field_name(left), op, right)

        local_attr_ref?(right) and non_nil_literal?(left) ->
          flipped =
            case op do
              :gt -> :lt
              :gte -> :lte
              :lt -> :gt
              :lte -> :gte
            end

          to_bound_tuple(ref_field_name(right), flipped, left)

        true ->
          :none
      end
    end

    defp to_bound_tuple(field, :gt, val), do: {:ok, field, :min, {:exclusive, val}}
    defp to_bound_tuple(field, :gte, val), do: {:ok, field, :min, {:inclusive, val}}
    defp to_bound_tuple(field, :lt, val), do: {:ok, field, :max, {:exclusive, val}}
    defp to_bound_tuple(field, :lte, val), do: {:ok, field, :max, {:inclusive, val}}

    defp merge_range_bound(existing, kind, new_bound) do
      case Map.get(existing, kind) do
        nil ->
          Map.put(existing, kind, new_bound)

        prev_bound ->
          tighter = pick_tighter_bound(kind, prev_bound, new_bound)
          Map.put(existing, kind, tighter)
      end
    end

    defp pick_tighter_bound(:min, {inc1, v1} = b1, {inc2, v2} = b2) do
      case compare_agg_vals(v1, v2) do
        :gt -> b1
        :lt -> b2
        :eq -> if inc1 == :exclusive or inc2 == :exclusive, do: {:exclusive, v1}, else: b1
      end
    end

    defp pick_tighter_bound(:max, {inc1, v1} = b1, {inc2, v2} = b2) do
      case compare_agg_vals(v1, v2) do
        :lt -> b1
        :gt -> b2
        :eq -> if inc1 == :exclusive or inc2 == :exclusive, do: {:exclusive, v1}, else: b1
      end
    end

    defp local_attr_ref?(%Ref{
           attribute: %Ash.Resource.Attribute{},
           relationship_path: []
         }),
         do: true

    defp local_attr_ref?(_), do: false

    defp ref_field_name(%Ref{attribute: %{name: name}}), do: name

    defp non_nil_literal?(val), do: not is_nil(val) and literal_value?(val)

    defp literal_value?(val)
         when is_binary(val) or is_number(val) or is_boolean(val) or is_atom(val) do
      true
    end

    defp literal_value?(%struct_mod{}) do
      struct_mod in [DateTime, NaiveDateTime, Date, Time, Decimal, Ash.CiString]
    end

    defp literal_value?(_), do: false

    defp filter_uses_derived_or_related?(%Ash.Filter{expression: expr}) do
      filter_uses_derived_or_related?(expr)
    end

    defp filter_uses_derived_or_related?(%Ref{relationship_path: [_ | _]}), do: true

    defp filter_uses_derived_or_related?(%Ref{attribute: attr}) do
      not is_struct(attr, Ash.Resource.Attribute)
    end

    defp filter_uses_derived_or_related?(%Ash.Query.Exists{}), do: true
    defp filter_uses_derived_or_related?(%Not{expression: inner}), do: filter_uses_derived_or_related?(inner)

    defp filter_uses_derived_or_related?(%BooleanExpression{left: l, right: r}) do
      filter_uses_derived_or_related?(l) or filter_uses_derived_or_related?(r)
    end

    defp filter_uses_derived_or_related?(%_{} = struct) do
      struct
      |> Map.from_struct()
      |> Map.delete(:__spark_metadata__)
      |> Map.values()
      |> Enum.any?(&filter_uses_derived_or_related?/1)
    end

    defp filter_uses_derived_or_related?(list) when is_list(list) do
      Enum.any?(list, &filter_uses_derived_or_related?/1)
    end

    defp filter_uses_derived_or_related?(tuple) when is_tuple(tuple) do
      tuple |> Tuple.to_list() |> Enum.any?(&filter_uses_derived_or_related?/1)
    end

    defp filter_uses_derived_or_related?(_scalar), do: false

    defp fetch_record_field(record, field) do
      cond do
        Map.has_key?(record, field) ->
          Map.get(record, field)

        Map.has_key?(Map.get(record, :calculations, %{}), field) ->
          record.calculations[field]

        Map.has_key?(Map.get(record, :aggregates, %{}), field) ->
          record.aggregates[field]

        true ->
          nil
      end
    end
  end
end

```

