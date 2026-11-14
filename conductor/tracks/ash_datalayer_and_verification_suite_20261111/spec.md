# Specification: Track 14 — Ash 3 `Xitdb.Ash.DataLayer` Behaviour & Standalone Verification Suite

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_datalayer_and_verification_suite_20261111`
> - **Wave:** Wave 2
> - **Prerequisites:**
>   - [`ash_dsl_and_verifiers_20261111`](../ash_dsl_and_verifiers_20261111/index.md) (`Xitdb.Ash.Dsl`, `BuildIndexPlan`, `VerifyNoSqlFragments`, `VerifyCrossStoreReferences`, `Xitdb.Ash.Info`)
>   - [`ash_store_and_test_sandbox_20261111`](../ash_store_and_test_sandbox_20261111/index.md) (`Xitdb.Ash.Store`, `Xitdb.Ash.TestSandbox`)
>   - [`ash_codec_and_indexer_20261111`](../ash_codec_and_indexer_20261111/index.md) (`Xitdb.Ash.Codec`, `Xitdb.Ash.Indexer` — Track 11A flat collections in Wave 2)
>   - [`ash_query_engine_20261111`](../ash_query_engine_20261111/index.md) (`Xitdb.Ash.Query`)
>   - [`ash_mutator_and_cascades_20261111`](../ash_mutator_and_cascades_20261111/index.md) (`Xitdb.Ash.Mutator`)
> - **Primary Module:** `lib/xitdb/ash/data_layer.ex`
> - **Verification Suite:** `test/xitdb/ash/data_layer_test.exs`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Reference Documents:**
>   - [`./reference.md`](./reference.md) (`Xitdb.Ash.DataLayer` behaviour implementation)
>   - [`./references/ash3_contract_fixes_and_verification_suite.md`](./references/ash3_contract_fixes_and_verification_suite.md) (Ash 3 capability & callback contract notes + standalone `data_layer_test.exs`)
> - **Done When:** Complete end-to-end multi-store dual-resource verification suite passes 100% on `async: true` with zero compiler warnings and zero required dependencies for non-Ash callers.

---

## 1. Objectives & Context

Track 14 completes the Wave 2 integration of the native Xitdb Ash DataLayer by implementing:
1. `Xitdb.Ash.DataLayer`: The Ash 3.37+ `Ash.DataLayer` behaviour coordinating the six-stage query engine (`Xitdb.Ash.Query`), single-commit atomic mutator (`Xitdb.Ash.Mutator`), `{db, moment}` single-writer store (`Xitdb.Ash.Store`), and the Spark DSL / verifiers implemented in [`ash_dsl_and_verifiers_20261111`](../ash_dsl_and_verifiers_20261111/index.md).
2. Comprehensive Standalone Verification Suite (`test/xitdb/ash/data_layer_test.exs`): A self-contained dual-store test suite (`TestMdmStore` + `TestAppStore` booted via `TestSandbox.init/0` and `start_supervised!/1` in `setup_all`, with `{:simple_sat, "~> 0.1", only: :test}` added to `mix.exs` so `Ash.Policy.Authorizer` compiles and runs cleanly) validating all Wave 2 Ash 3 data layer capabilities against isolated per-test `:memory` `.xit` handles via `Xitdb.Ash.TestSandbox`. (Physical `nested_in` subtree co-location tests are scheduled in Wave 3 Track 11B.)

---

## 2. Technical Architecture & Component Details

### 2.1 `Xitdb.Ash.DataLayer` Behaviour

Implements `Ash.DataLayer` callbacks in strict alignment with `deps/ash/lib/ash/data_layer/data_layer.ex`:
- **Capabilities (`can?/2`):**
  - Advertises: `:async_engine`, `:multitenancy`, `:transact`, `:create`, `:read`, `:update`, `:destroy`, `:bulk_create`, `:update_query`, `:destroy_query`, `:upsert`, `{:atomic, :update}`, `{:atomic, :upsert}`, `{:atomic, :create}`, `{:atomic, :destroy}`, `:atomic_update`, `:changeset_filter`, `:expr_error`, `:calculate`, `:expression_calculation`, `:expression_calculation_sort`, `:filter`, `:boolean_filter`, `:nested_expressions`, `:through_relationship`, `:aggregate_filter`, `:aggregate_sort`, `{:aggregate, :unrelated}`, `{:exists, :unrelated}`, `{:filter_expr, _}`, `{:sort, _}`, `:sort`, `:distinct`, `:distinct_sort`, `:limit`, `:offset`, `:select`.
  - **Explicitly omits `:composite_primary_key`** in Wave 1/2 to match `BuildIndexPlan`'s single-column primary-key invariant.
  - **Hybrid DataLayer Boundary Guards:** Scopes `{:join, other}`, `{:filter_relationship, %{destination: dest}}`, and `{:aggregate_relationship, %{destination: dest}}` strictly to `Ash.Resource.Info.data_layer(...) == Xitdb.Ash.DataLayer` (returning `false` for `AshPostgres` so Ash Core automatically splits cross-layer `exists/2` predicates into `id in ^ids` subqueries).
- **Complete Query-Shaping & One-Off Calculation Callbacks:**
  - Implements **both** singular and plural callbacks required by `Ash.DataLayer`: `add_aggregate/3` + `add_aggregates/3` and `add_calculation/4` + `add_calculations/3`, delegating to `Xitdb.Ash.Query`.
  - Implements `calculate/3` (`Ash.calculate/3` one-off expression evaluation) via `Ash.Expr.eval/2` / `Ash.Expr.eval_hydrated/2`.
- **Transaction Semantics (`transaction/4`, `in_transaction?/1`, `rollback/2`, `prefer_transaction?/1`):**
  - Resolves store module via `Xitdb.Ash.Info.store!(resource)` and delegates to `Xitdb.Ash.Store.transact/3`, `in_transaction?/1`, and `rollback/2`.
- **CRUD & Bulk Operations:**
  - Delegated to `Xitdb.Ash.Mutator.create/2`, `bulk_create/3`, `update/2`, `update_query/4`, `destroy/2`, `destroy_query/4`, and `upsert/3,4`.
- **Query Execution & Telemetry:**
  - Delegated to `Xitdb.Ash.Query.execute/3` and `execute_aggregates/4` over `Store.current_db(Info.store!(resource))`, wrapped in `:telemetry.span([:xitdb, :ash, :query], ...)` and `:telemetry.span([:xitdb, :ash, :aggregate_query], ...)`.

### 2.2 Standalone Verification Suite (`test/xitdb/ash/data_layer_test.exs`)

Dual-store verification suite (full reference in [`./references/ash3_contract_fixes_and_verification_suite.md`](./references/ash3_contract_fixes_and_verification_suite.md)) modeling flat top-level collections across two stores:
- `TestMdmStore`: `User`, `Organization`, `Profile`, `Event`, `AgendaSession`, `Conference`, `TableTalkSeat`, `TenantDoc`.
- `TestAppStore`: `Deal`, `Message`, `MessageReport`.
- Tests cover:
  - Single-commit CRUD, monotonic sequences, `:ci_string` identities, `counted_set_fields`, and partial `where:` identities.
  - Primary-key preservation across all Ash 3 `upsert_fields` shapes (`:replace_all`, `{:replace, ...}`, `{:replace_all_except, ...}`, `nil`, list) on `uuid_primary_key` resources.
  - Cross-store `Ash.Policy.Authorizer` read/write policies (`exists(organization.profiles, ...)` verifying `:unknown` runtime hydration), pre-update vs. post-update `atomics` (field swap) and `atomic_validations`, and relational `Deal.has_materials_access` calculations.
  - Module calculations (`StartDateCalc`) sorting and filtering.
  - `:context` multitenancy isolation and BM25 `Xitdb.Ash.Search` stale-token cleanup on update/destroy.
  - Foreign key cascades (`:delete`, `:nilify`, `:restrict`), nested savepoints, `$callers` async sandbox propagation, and `VerifyNoSqlFragments` compile-time checks.
