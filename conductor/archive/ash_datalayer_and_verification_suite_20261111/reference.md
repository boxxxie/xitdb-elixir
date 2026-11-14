# Reference: `Xitdb.Ash.DataLayer`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_datalayer_and_verification_suite_20261111`](./index.md)
> - **Wave:** Wave 2
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Module:** `lib/xitdb/ash/data_layer.ex`
> - **Purpose:** Complete specification and reference implementation for the Ash 3.37+ `Ash.DataLayer` behaviour (`Xitdb.Ash.DataLayer`).

---

## 1. Concurrency, Execution & Safety Invariants

### 1.1 Ash 3.37+ DataLayer Capabilities & Hybrid Boundary Guards
- **Supported Features:** Advertises `:async_engine`, `:multitenancy`, `:transact`, `:create`, `:read`, `:update`, `:destroy`, `:bulk_create`, `:update_query`, `:destroy_query`, `:upsert`, `{:atomic, :update | :upsert | :create | :destroy}`, `:atomic_update`, `:changeset_filter`, `:expr_error`, `:calculate`, `:expression_calculation`, `:expression_calculation_sort`, `{:aggregate, :unrelated}`, `{:exists, :unrelated}`, `:aggregate_filter`, `:aggregate_sort`, `:filter`, `:boolean_filter`, `:nested_expressions`, `:through_relationship`, `:sort`, `:distinct`, `:distinct_sort`, `:limit`, `:offset`, `:select`, and all eight aggregate kinds (`:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg`).
- **Single-Column PK Alignment:** Explicitly omits `:composite_primary_key` in Wave 1/2 to match `BuildIndexPlan`'s single-column primary-key verifier.
- **Cross-Layer Isolation:** Scopes `{:join, other}`, `{:filter_relationship, %{destination: dest}}`, and `{:aggregate_relationship, %{destination: dest}}` strictly to `Ash.Resource.Info.data_layer(...) == __MODULE__`. Relationships crossing into `AshPostgres` return `false`, instructing Ash Core's `Ash.Filter.run_other_data_layer_filters/4` to split cross-DB `exists/2` predicates into pre-resolved `id in ^ids` subqueries while same-layer relationships across `.xit` stores (`MDM.Store` + `AppStore`) evaluate via `Ash.Filter.Runtime` and `Xitdb.Ash.Query`.
- **Complete Shaping Arities:** Implements both `add_aggregate/3` and `add_aggregates/3`, both `add_calculation/4` and `add_calculations/3`, `upsert/3` and `upsert/4`, and `calculate/3`.

### 1.2 Telemetry Spans & Lock-Free Snapshot Reads
Wraps `run_query/2` in `:telemetry.span([:xitdb, :ash, :query], meta, ...)` and `run_aggregate_query/3` in `:telemetry.span([:xitdb, :ash, :aggregate_query], meta, ...)`, reading `Store.current_db(Info.store!(resource))` (`%Xitdb.Cursor{}` pinned to the active transaction, `TestSandbox` checkout, or `:persistent_term` snapshot) with zero `GenServer.call` bottlenecks.

### 1.3 Transaction Lifecycle Delegation
Delegates `transaction/4`, `in_transaction?/1`, and `rollback/2` directly to `Xitdb.Ash.Store`, setting `prefer_transaction?/1` and `prefer_transaction_for_atomic_updates?/1` to `false` so single-record mutations execute directly inside `Store.mutate/3` unless Ash hooks or multi-resource actions request an explicit surrounding transaction.

---

## 2. Reference Implementation: `lib/xitdb/ash/data_layer.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.DataLayer do
    @moduledoc """
    Native lock-free Xitdb data layer for Ash Framework 3.37+.

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
    def prefer_transaction?(_resource), do: false

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
        db = Store.current_db(Info.store!(resource))
        result = Query.execute(db, query, resource)
        status = if match?({:ok, _}, result), do: :ok, else: :error
        {result, Map.put(meta, :status, status)}
      end)
    end

    @impl Ash.DataLayer
    def run_aggregate_query(%Query{} = query, aggregates, resource) do
      meta = %{resource: resource, collection: Info.collection!(resource)}

      :telemetry.span([:xitdb, :ash, :aggregate_query], meta, fn ->
        db = Store.current_db(Info.store!(resource))
        result = Query.execute_aggregates(db, query, aggregates, resource)
        status = if match?({:ok, _}, result), do: :ok, else: :error
        {result, Map.put(meta, :status, status)}
      end)
    end

    @impl Ash.DataLayer
    def calculate(resource, expressions, context) when is_list(expressions) and is_map(context) do
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

      eval_opts = [
        resource: resource,
        domain: domain,
        actor: actor,
        tenant: tenant,
        context: plain_ctx
      ]

      expressions
      |> Enum.reduce_while({:ok, []}, fn expr, {:ok, acc} ->
        case Ash.Expr.eval(expr, eval_opts) do
          {:ok, value} ->
            {:cont, {:ok, [value | acc]}}

          :unknown ->
            case Ash.Filter.hydrate_refs(expr, %{resource: resource, public?: false}) do
              {:ok, hydrated} ->
                case Ash.Expr.eval_hydrated(hydrated, eval_opts) do
                  {:ok, val} -> {:cont, {:ok, [val | acc]}}
                  :unknown -> {:cont, {:ok, [nil | acc]}}
                  {:error, _} = err -> {:halt, err}
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
    end

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
```
