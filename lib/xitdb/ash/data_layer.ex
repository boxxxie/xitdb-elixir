if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.DataLayer do
    @moduledoc """
    Native Ash Framework 3.37+ data layer backed by immutable `.xit` stores.

    Supports full Ash CRUD, atomic updates/destroys, relationships, aggregates,
    calculations, single/composite B+Tree secondary indexes (`index`), built-in
    BM25 + prefix search (`Xitdb.Ash.Search`), same-store foreign-key `on_delete`
    cascades (`references`), co-located subtrees (`nested_in`), time-travel reads
    (`Xitdb.Ash.Store.with_as_of/3`), and isolated `async: true` test sandboxes
    (`Xitdb.Ash.TestSandbox`)—with zero SQL migrations.

    See [Ash Framework & Full-Text Search](docs/ash-and-spark.md) for setup and usage.

    ## Telemetry

    * `[:xitdb, :ash, :query, :start | :stop | :exception]` — emitted by `run_query/2`,
      carrying `%{resource: module(), collection: atom(), status: :ok | :error}`.
    * `[:xitdb, :ash, :aggregate_query, :start | :stop | :exception]` — emitted by
      `run_aggregate_query/3`, carrying `%{resource: module(), collection: atom(), status: :ok | :error}`.
    """

    @behaviour Ash.DataLayer

    use Spark.Dsl.Extension,
      sections: Xitdb.Ash.Dsl.sections(),
      transformers: [Xitdb.Ash.Transformers.BuildIndexPlan],
      verifiers: [
        Xitdb.Ash.Verifiers.VerifyNoSqlFragments,
        Xitdb.Ash.Verifiers.VerifyCrossStoreReferences
      ]

    alias Xitdb.Ash.{Info, Mutator, Query, Store}

    @supported_features MapSet.new([
                          :async_engine,
                          :multitenancy,
                          :transact,
                          :create,
                          :read,
                          :update,
                          :destroy,
                          :bulk_create,
                          :update_query,
                          :destroy_query,
                          :upsert,
                          :filter,
                          :boolean_filter,
                          :nested_expressions,
                          :through_relationship,
                          :changeset_filter,
                          :atomic_update,
                          :expr_error,
                          :calculate,
                          :expression_calculation,
                          :expression_calculation_sort,
                          :aggregate_filter,
                          :aggregate_sort,
                          :sort,
                          :distinct,
                          :distinct_sort,
                          :limit,
                          :offset,
                          :select
                        ])

    @supported_aggregates [:count, :exists, :first, :list, :sum, :min, :max, :avg]

    @impl Ash.DataLayer
    def can?(_resource, {:join, other}) when is_atom(other) do
      Ash.Resource.Info.data_layer(other) == __MODULE__
    end

    def can?(_resource, {:filter_relationship, %{destination: dest}}) do
      Ash.Resource.Info.data_layer(dest) == __MODULE__
    end

    def can?(_resource, {:aggregate_relationship, %{destination: dest}}) do
      Ash.Resource.Info.data_layer(dest) == __MODULE__
    end

    def can?(_resource, {:atomic, kind}) when kind in [:create, :update, :upsert, :destroy],
      do: true

    def can?(_resource, {:aggregate, :unrelated}), do: true
    def can?(_resource, {:exists, :unrelated}), do: true
    def can?(_resource, {:aggregate, kind}) when kind in @supported_aggregates, do: true
    def can?(_resource, {:query_aggregate, kind}) when kind in @supported_aggregates, do: true
    def can?(_resource, {:filter_expr, _}), do: true
    def can?(_resource, {:sort, _}), do: true
    def can?(_resource, :composite_primary_key), do: false

    def can?(resource, action_type) when action_type in [:update, :destroy] do
      Ash.Resource.Info.primary_key(resource) != []
    end

    def can?(_resource, feature) when is_atom(feature) do
      MapSet.member?(@supported_features, feature)
    end

    def can?(_resource, _feature), do: false

    @impl Ash.DataLayer
    def prefer_lateral_join_for_many_to_many?, do: false

    @impl Ash.DataLayer
    def prefer_transaction?(_resource), do: true

    @impl Ash.DataLayer
    def prefer_transaction_for_atomic_updates?(_resource), do: false

    @impl Ash.DataLayer
    def source(resource) do
      resource |> Info.collection!() |> Atom.to_string()
    end

    # -- Query Construction & Shaping Callbacks --

    @impl Ash.DataLayer
    def resource_to_query(resource, domain) do
      Query.new(resource, domain)
    end

    @impl Ash.DataLayer
    def set_context(resource, %Query{} = query, context) when is_map(context) do
      Query.set_context(resource, query, context)
    end

    @impl Ash.DataLayer
    def set_tenant(resource, %Query{} = query, tenant) do
      Query.set_tenant(resource, query, tenant)
    end

    @impl Ash.DataLayer
    def filter(%Query{} = query, filter, resource) do
      Query.filter(query, filter, resource)
    end

    @impl Ash.DataLayer
    def sort(%Query{} = query, sort, resource) do
      Query.sort(query, sort, resource)
    end

    @impl Ash.DataLayer
    def distinct(%Query{} = query, distinct, resource) do
      Query.distinct(query, distinct, resource)
    end

    @impl Ash.DataLayer
    def distinct_sort(%Query{} = query, sort, resource) do
      Query.distinct_sort(query, sort, resource)
    end

    @impl Ash.DataLayer
    def limit(%Query{} = query, limit, resource) do
      Query.limit(query, limit, resource)
    end

    @impl Ash.DataLayer
    def offset(%Query{} = query, offset, resource) do
      Query.offset(query, offset, resource)
    end

    @impl Ash.DataLayer
    def select(%Query{} = query, select, resource) do
      Query.select(query, select, resource)
    end

    @impl Ash.DataLayer
    def add_aggregate(%Query{} = query, aggregate, resource) do
      Query.add_aggregate(query, aggregate, resource)
    end

    @impl Ash.DataLayer
    def add_aggregates(%Query{} = query, aggregates, resource) when is_list(aggregates) do
      Query.add_aggregates(query, aggregates, resource)
    end

    @impl Ash.DataLayer
    def add_calculation(%Query{} = query, calculation, expression, resource) do
      Query.add_calculation(query, calculation, expression, resource)
    end

    @impl Ash.DataLayer
    def add_calculations(%Query{} = query, calculations, resource) when is_list(calculations) do
      Query.add_calculations(query, calculations, resource)
    end

    # -- Query & One-Off Calculation Execution Callbacks --

    @impl Ash.DataLayer
    def run_query(%Query{} = query, resource) do
      meta = %{resource: resource, collection: Info.collection!(resource)}

      :telemetry.span([:xitdb, :ash, :query], meta, fn ->
        result =
          with_query_db(query, resource, fn db ->
            Query.execute(db, query, resource)
          end)

        status = if match?({:ok, _}, result), do: :ok, else: :error
        {result, Map.put(meta, :status, status)}
      end)
    end

    @impl Ash.DataLayer
    def run_aggregate_query(%Query{} = query, aggregates, resource) do
      meta = %{resource: resource, collection: Info.collection!(resource)}

      :telemetry.span([:xitdb, :ash, :aggregate_query], meta, fn ->
        result =
          with_query_db(query, resource, fn db ->
            Query.execute_aggregates(db, query, aggregates, resource)
          end)

        status = if match?({:ok, _}, result), do: :ok, else: :error
        {result, Map.put(meta, :status, status)}
      end)
    end

    defp with_query_db(%Query{context: context}, resource, fun) do
      store = Info.store!(resource)

      case extract_db_override(context) do
        {:override, moment_or_db} ->
          Store.with_as_of(store, moment_or_db, fn ->
            fun.(Store.current_db(store))
          end)

        :none ->
          fun.(Store.current_db(store))
      end
    end

    defp extract_db_override(context) when is_map(context) do
      dl_ctx = Map.get(context, :data_layer) || %{}
      xitdb_ctx = Map.get(context, :xitdb) || %{}
      shared_ctx = Map.get(context, :shared) || %{}

      db =
        Map.get(context, :xitdb_db) ||
          (is_map(dl_ctx) && Map.get(dl_ctx, :xitdb_db)) ||
          (is_map(xitdb_ctx) && Map.get(xitdb_ctx, :db))

      moment =
        Map.get(context, :xitdb_moment) ||
          (is_map(dl_ctx) && (Map.get(dl_ctx, :as_of) || Map.get(dl_ctx, :xitdb_moment))) ||
          (is_map(xitdb_ctx) && (Map.get(xitdb_ctx, :as_of) || Map.get(xitdb_ctx, :moment)))

      cond do
        db != nil ->
          {:override, db}

        is_integer(moment) ->
          {:override, moment}

        is_map(shared_ctx) and map_size(shared_ctx) > 0 ->
          extract_db_override(Map.delete(shared_ctx, :shared))

        true ->
          :none
      end
    end

    defp extract_db_override(_), do: :none

    @impl Ash.DataLayer
    def calculate(resource, expressions, context) when is_list(expressions) and is_map(context) do
      with_context_db(context, resource, fn db ->
        calc_ctx = Map.get(context, :calculation_context)

        actor = if calc_ctx, do: calc_ctx.actor, else: Map.get(context, :actor)
        tenant = if calc_ctx, do: calc_ctx.tenant, else: Map.get(context, :tenant)
        domain = if calc_ctx, do: calc_ctx.domain, else: Ash.Resource.Info.domain(resource)

        plain_ctx =
          cond do
            match?(%Ash.Resource.Calculation.Context{}, context) ->
              context.source_context || %{}

            is_struct(context) ->
              Map.from_struct(context)

            true ->
              context
          end

        source_ctx =
          cond do
            match?(%Ash.Resource.Calculation.Context{}, calc_ctx) and
                is_map(calc_ctx.source_context) ->
              calc_ctx.source_context

            is_map(Map.get(plain_ctx, :source_context)) ->
              Map.get(plain_ctx, :source_context)

            true ->
              plain_ctx
          end

        record =
          Map.get(context, :record) ||
            Map.get(plain_ctx, :record) ||
            Map.get(source_ctx, :record)

        base_eval_opts =
          [
            resource: resource,
            domain: domain,
            actor: actor,
            tenant: tenant,
            context: source_ctx
          ]
          |> then(fn opts ->
            if is_nil(record), do: opts, else: Keyword.put(opts, :record, record)
          end)

        expressions
        |> Enum.reduce_while({:ok, []}, fn raw_expr, {:ok, acc} ->
          expr =
            Query.preresolve_unrelated_exists(db, resource, raw_expr, tenant, domain, source_ctx)

          case Ash.Expr.eval(expr, base_eval_opts) do
            {:ok, value} ->
              {:cont, {:ok, [value | acc]}}

            :unknown ->
              case Ash.Filter.hydrate_refs(expr, %{resource: resource, public?: false}) do
                {:ok, hydrated} ->
                  case Ash.Expr.eval_hydrated(hydrated, base_eval_opts) do
                    {:ok, val} ->
                      {:cont, {:ok, [val | acc]}}

                    :unknown ->
                      case eval_relational_fallback(
                             hydrated,
                             record,
                             base_eval_opts,
                             domain,
                             actor,
                             tenant
                           ) do
                        {:ok, val} ->
                          {:cont, {:ok, [val | acc]}}

                        :unknown ->
                          {:halt,
                           {:error,
                            "unable to evaluate expression #{inspect(raw_expr)} without a loaded record"}}

                        {:error, _} = err ->
                          {:halt, err}
                      end

                    {:error, _} = err ->
                      {:halt, err}
                  end

                {:error, _} = err ->
                  {:halt, err}
              end

            {:error, _} = err ->
              {:halt, err}
          end
        end)
        |> case do
          {:ok, rev} -> {:ok, Enum.reverse(rev)}
          {:error, _} = err -> err
        end
      end)
    end

    defp with_context_db(context, resource, fun) do
      calc_ctx = Map.get(context, :calculation_context)
      direct_source_ctx = Map.get(context, :source_context)

      calc_source_ctx =
        if is_map(calc_ctx), do: Map.get(calc_ctx, :source_context), else: nil

      override =
        Enum.find_value([context, calc_ctx, direct_source_ctx, calc_source_ctx], :none, fn ctx ->
          if is_map(ctx) do
            case extract_db_override(ctx) do
              {:override, _} = found -> found
              :none -> nil
            end
          end
        end)

      case {Info.fetch_store(resource), override} do
        {{:ok, store}, {:override, moment_or_db}} ->
          Store.with_as_of(store, moment_or_db, fn ->
            fun.(safe_current_db(store))
          end)

        {{:ok, store}, :none} ->
          fun.(safe_current_db(store))

        {:error, _} ->
          fun.(nil)
      end
    end

    defp safe_current_db(store) do
      Store.current_db(store)
    rescue
      _ -> nil
    end

    defp eval_relational_fallback(_expr, nil, _eval_opts, _domain, _actor, _tenant), do: :unknown

    defp eval_relational_fallback(expr, record, eval_opts, domain, actor, tenant)
         when is_map(record) do
      if boolean_filter_expr?(expr) do
        case Ash.Filter.Runtime.filter_matches(domain, [record], expr,
               actor: actor,
               tenant: tenant,
               authorize?: false
             ) do
          {:ok, [_ | _]} -> {:ok, true}
          {:ok, []} -> {:ok, false}
          {:error, _} = err -> err
        end
      else
        case collect_refs_to_load(expr) do
          [] ->
            :unknown

          refs ->
            load_ctx = Keyword.get(eval_opts, :context, %{})

            with {:ok, [loaded]} <-
                   Ash.load([record], refs,
                     domain: domain,
                     actor: actor,
                     tenant: tenant,
                     context: load_ctx,
                     authorize?: false
                   ),
                 {:ok, val} <-
                   Ash.Expr.eval_hydrated(expr, Keyword.put(eval_opts, :record, loaded)) do
              {:ok, val}
            else
              :unknown -> :unknown
              {:error, _} = err -> err
              _ -> :unknown
            end
        end
      end
    rescue
      _ -> :unknown
    end

    @boolean_filter_structs [
      Ash.Filter,
      Ash.Query.Exists,
      Ash.Query.BooleanExpression,
      Ash.Query.Not,
      Ash.Query.Operator.IsNil,
      Ash.Query.Operator.In,
      Ash.Query.Operator.Eq,
      Ash.Query.Operator.NotEq,
      Ash.Query.Operator.LessThan,
      Ash.Query.Operator.LessThanOrEqual,
      Ash.Query.Operator.GreaterThan,
      Ash.Query.Operator.GreaterThanOrEqual
    ]

    defp boolean_filter_expr?(%mod{}) when mod in @boolean_filter_structs, do: true

    defp boolean_filter_expr?(%{__struct__: mod}) do
      function_exported?(mod, :evaluate_operator, 1) and
        Code.ensure_loaded?(Ash.Filter.Simple) and
        Ash.Filter.Simple in (mod.__info__(:attributes)[:behaviour] || [])
    end

    defp boolean_filter_expr?(_), do: false

    defp collect_refs_to_load(expr) do
      expr
      |> do_collect_refs_to_load([])
      |> Enum.uniq()
    end

    defp do_collect_refs_to_load(
           %Ash.Query.Ref{relationship_path: [_ | _] = path, attribute: attr},
           acc
         ) do
      leaf =
        case attr do
          %{__struct__: mod, name: name}
          when mod in [Ash.Resource.Calculation, Ash.Resource.Aggregate] ->
            [name]

          _ ->
            []
        end

      [nest_load_path(path, leaf) | acc]
    end

    defp do_collect_refs_to_load(
           %Ash.Query.Ref{relationship_path: [], attribute: %{__struct__: mod, name: name}},
           acc
         )
         when mod in [Ash.Resource.Calculation, Ash.Resource.Aggregate] do
      [name | acc]
    end

    defp do_collect_refs_to_load(%_{} = struct, acc) do
      struct
      |> Map.from_struct()
      |> Enum.reduce(acc, fn {_k, v}, inner -> do_collect_refs_to_load(v, inner) end)
    end

    defp do_collect_refs_to_load(list, acc) when is_list(list) do
      Enum.reduce(list, acc, &do_collect_refs_to_load/2)
    end

    defp do_collect_refs_to_load(tuple, acc) when is_tuple(tuple) do
      tuple |> Tuple.to_list() |> Enum.reduce(acc, &do_collect_refs_to_load/2)
    end

    defp do_collect_refs_to_load(map, acc) when is_map(map) do
      Enum.reduce(map, acc, fn {_k, v}, inner -> do_collect_refs_to_load(v, inner) end)
    end

    defp do_collect_refs_to_load(_other, acc), do: acc

    defp nest_load_path([last], []), do: last
    defp nest_load_path([last], leaf), do: {last, leaf}
    defp nest_load_path([head | rest], leaf), do: {head, [nest_load_path(rest, leaf)]}

    # -- Mutation & Transaction Callbacks --

    @impl Ash.DataLayer
    def create(resource, changeset), do: Mutator.create(resource, changeset)

    @impl Ash.DataLayer
    def bulk_create(resource, stream, options), do: Mutator.bulk_create(resource, stream, options)

    @impl Ash.DataLayer
    def update(resource, changeset), do: Mutator.update(resource, changeset)

    @impl Ash.DataLayer
    def update_query(query, changeset, resource, options) do
      Mutator.update_query(query, changeset, resource, options)
    end

    @impl Ash.DataLayer
    def upsert(resource, changeset, keys, identity \\ nil) do
      Mutator.upsert(resource, changeset, keys, identity)
    end

    @impl Ash.DataLayer
    def destroy(resource, changeset), do: Mutator.destroy(resource, changeset)

    @impl Ash.DataLayer
    def destroy_query(query, changeset, resource, options) do
      Mutator.destroy_query(query, changeset, resource, options)
    end

    @impl Ash.DataLayer
    def transaction(resource, fun, timeout, _reason) do
      Store.transact(Info.store!(resource), fun, timeout: timeout)
    end

    @impl Ash.DataLayer
    def in_transaction?(resource) do
      Store.in_transaction?(Info.store!(resource))
    end

    @impl Ash.DataLayer
    def rollback(resource, value) do
      Store.rollback(Info.store!(resource), value)
    end
  end
end
