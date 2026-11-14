# Specification: Track 11 — Ash 3 DataLayer Behaviour & Verification Suite

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_datalayer_and_verification_suite_20261111`
> - **Primary Modules:** `lib/xitdb/ash/data_layer.ex`, `lib/xitdb/ash/transformers/build_index_plan.ex`, `lib/xitdb/ash/verifiers/verify_no_sql_fragments.ex`, `lib/xitdb/ash/verifiers/verify_cross_store_references.ex`
> - **Verification Suite:** `test/xitdb/ash/data_layer_test.exs`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete end-to-end multi-store dual-resource verification suite passes 100% on `async: true` with zero compiler warnings and zero required dependencies for non-Ash callers.

---

## 1. Objectives & Context

Track 11 completes the integration of the pure Xitdb Ash DataLayer by implementing:
1. `Xitdb.Ash.DataLayer`: The Ash 3 `Ash.DataLayer` behaviour coordinating the six-stage query engine (`Xitdb.Ash.Query`), atomic mutator (`Xitdb.Ash.Mutator`), and transactional store (`Xitdb.Ash.Store`).
2. Compile-Time Transformers & Verifiers: Enforcing no SQL fragments and safe cross-store references.
3. Comprehensive Verification Suite: A dual-store test suite validating all Ash 3 data layer capabilities against independent `.xit` file stores via `Xitdb.Ash.TestSandbox`.

---

## 2. Technical Architecture & Component Details

### 2.1 `Xitdb.Ash.DataLayer` Behaviour

Implements `Ash.DataLayer` callbacks:
- **Capabilities (`can?/2`):**
  - Advertises: `:async_engine`, `:transact`, `{:transact, :read_actions}`, `:bulk_create`, `:upsert`, `{:atomic, :update}`, `{:atomic, :destroy}`, `{:join, other}`, `{:filter_expr, _}`, `{:sort, _}`, `{:distinct, _}`, `{:limit, _}`, `{:offset, _}`.
  - **Explicitly omits `:calculate`**: Leaves calculation evaluation to Ash Core's in-memory calculation engine, ensuring nested calculations and relationships load cleanly without SQL emulation.
- **Pass-through `join/7`:**
  - Returns `{:ok, query}` as a no-op because relationship resolution and filter matching are evaluated in memory by `Ash.Filter.Runtime`.
- **Transaction Semantics (`transaction/4`, `in_transaction?/1`, `rollback/2`):**
  - Resolves store module via `Xitdb.Ash.Info.store!(resource)`.
  - Coordinates with `Xitdb.Ash.Store.transact/3` to acquire monitored single-writer leases.
  - Handles savepoints and rollback throws (`{:xitdb_ash_rollback, ^store, reason}`).
- **CRUD Operations:**
  - Delegated to `Xitdb.Ash.Mutator.create/2`, `bulk_create/3`, `update/2`, `update_query/4`, `destroy/2`, `destroy_query/4`, `upsert/4`.
- **Query Operations:**
  - Delegated to `Xitdb.Ash.Query.run_query/2` and `run_aggregate_query/3`.

### 2.2 Transformers & Verifiers

- `Xitdb.Ash.Transformers.BuildIndexPlan`:
  - Inspects `relationships` on resource; automatically synthesizes `:sorted_map` B+Tree indexes for `belongs_to` foreign keys when `index_relationships?` is true.
  - Persists compiled index plan to `dsl_state` without foreign module mutations.
- `Xitdb.Ash.Verifiers.VerifyNoSqlFragments`:
  - Scans calculations, filters, identities, and validations for `Ash.Query.Function.Fragment`.
  - Emits compile-time `Spark.Error.DslError` if any raw SQL fragments are detected.
- `Xitdb.Ash.Verifiers.VerifyCrossStoreReferences`:
  - Inspects `references` block for `on_delete: :delete | :nilify | :restrict`.
  - Asserts that both source and destination resources are assigned to the same `store` module.

### 2.3 Standalone Verification Suite (`test/xitdb/ash/data_layer_test.exs`)

Dual-store verification suite modeling:
- `TestMdmStore`: User, Organization (with identities, search fields, indexes).
- `TestAppStore`: Event, AgendaSession (with `nested_in` relationship, date calculations, references).
- Tests cover:
  - CRUD operations (create, read by PK, read by secondary index, update, destroy).
  - Bulk operations & atomic updates/destroys.
  - Upsert with `%Ash.Resource.Identity{}` and unique constraints.
  - Foreign key cascades (`:delete`, `:nilify`, `:restrict`).
  - Search integration (`Xitdb.Ash.Search.ids/3`).
  - Transactions & rollback isolation.
  - Async concurrency across multiple test processes.
