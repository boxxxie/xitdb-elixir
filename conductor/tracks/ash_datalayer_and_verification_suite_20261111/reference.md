# Reference: `Xitdb.Ash.DataLayer`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_datalayer_and_verification_suite_20261111`](./index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Module:** `lib/xitdb/ash/data_layer.ex`
> - **Purpose:** Complete specification and reference implementation for the Ash 3 DataLayer behaviour implementation for `Xitdb.Ash.DataLayer`.

---

## 1. Concurrency, Execution & Safety Invariants

### 1.1 Ash 3 DataLayer Contract & Feature Capabilities
- Reports explicit capabilities in `can?/2` for filtering, sorting, distinct, limit/offset, aggregates (`:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg`), atomic updates/destroys, and multi-tenancy.
- Wires the Spark extension DSL sections, `BuildIndexPlan` transformer, and AST compile-time verifiers (`VerifyNoSqlFragments`, `VerifyCrossStoreReferences`).

### 1.2 Telemetry Spans
Wraps `run_query/2` in `:telemetry.span([:xitdb, :ash, :query], meta, ...)` and `run_aggregate_query/3` in `:telemetry.span([:xitdb, :ash, :aggregate_query], meta, ...)`.

### 1.3 Transaction Lifecycle Delegation
Delegates `transaction/4`, `in_transaction?/1`, and `rollback/2` directly to `Xitdb.Ash.Store`.

---

## 2. Reference Implementation: `lib/xitdb/ash/data_layer.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.DataLayer do
    @moduledoc """
    Native lock-free Xitdb data layer for Ash Framework 3.37.2+.

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

    @supported_aggregates [:count, :exists, :first, :list, :sum, :min, :max, :avg]

    @impl Ash.DataLayer
    def can?(_resource, {:aggregate, kind}), do: kind in @supported_aggregates
    def can?(_resource, {:query_aggregate, kind}), do: kind in @supported_aggregates

    def can?(_resource, {:aggregate_relationship, relationship}) do
      Ash.Resource.Info.data_layer(relationship.destination) == __MODULE__
    end

    def can?(_resource, {:filter_expr, _expr}), do: true
    def can?(_resource, {:filter_relationship, _rel}), do: false
    def can?(_resource, {:sort, _type}), do: true
    def can?(_resource, {:atomic, :update}), do: true
    def can?(_resource, {:atomic, :destroy}), do: true

    def can?(_resource, feature) do
      feature in [
        :create,
        :bulk_create,
        :read,
        :update,
        :update_query,
        :destroy,
        :destroy_query,
        :upsert,
        :transact,
        :async_engine,
        :multitenancy,
        :boolean_filter,
        :filter,
        :sort,
        :distinct,
        :distinct_sort,
        :limit,
        :offset,
        :select,
        :expr_error,
        :aggregate_filter,
        :aggregate_sort,
        :calculate
      ]
    end

    # -- Query Construction & Shaping Callbacks --

    @impl Ash.DataLayer
    def resource_to_query(resource, domain) do
      %Query{resource: resource, domain: domain}
    end

    @impl Ash.DataLayer
    def set_context(_resource, %Query{} = query, context) when is_map(context) do
      {:ok, %Query{query | context: context}}
    end

    @impl Ash.DataLayer
    def set_tenant(_resource, %Query{} = query, tenant) do
      {:ok, %Query{query | tenant: tenant}}
    end

    @impl Ash.DataLayer
    def filter(%Query{} = query, filter, _resource) do
      merged =
        case query.filter do
          nil -> filter
          existing -> Ash.Filter.add_to_filter!(existing, filter)
        end

      {:ok, %Query{query | filter: merged}}
    end

    @impl Ash.DataLayer
    def sort(%Query{} = query, sort, _resource) do
      {:ok, %Query{query | sort: sort}}
    end

    @impl Ash.DataLayer
    def distinct(%Query{} = query, distinct, _resource) do
      {:ok, %Query{query | distinct: distinct}}
    end

    @impl Ash.DataLayer
    def distinct_sort(%Query{} = query, sort, _resource) do
      {:ok, %Query{query | distinct_sort: sort}}
    end

    @impl Ash.DataLayer
    def limit(%Query{} = query, limit, _resource) do
      {:ok, %Query{query | limit: limit}}
    end

    @impl Ash.DataLayer
    def offset(%Query{} = query, offset, _resource) do
      {:ok, %Query{query | offset: offset}}
    end

    @impl Ash.DataLayer
    def select(%Query{} = query, select, _resource) do
      {:ok, %Query{query | select: select}}
    end

    @impl Ash.DataLayer
    def add_aggregates(%Query{} = query, aggregates, _resource) when is_list(aggregates) do
      {:ok, %Query{query | aggregates: query.aggregates ++ aggregates}}
    end

    @impl Ash.DataLayer
    def add_calculations(%Query{} = query, calculations, _resource) when is_list(calculations) do
      {:ok, %Query{query | calculations: query.calculations ++ calculations}}
    end

    # -- Query Execution Callbacks --

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
