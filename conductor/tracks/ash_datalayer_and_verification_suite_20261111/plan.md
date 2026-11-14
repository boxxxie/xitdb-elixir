# Implementation Plan: Track 14 — Ash 3 `Xitdb.Ash.DataLayer` Behaviour & Standalone Verification Suite

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_datalayer_and_verification_suite_20261111`
> - **Wave:** Wave 2
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Documents:**
>   - [`./reference.md`](./reference.md) (`Xitdb.Ash.DataLayer` implementation)
>   - [`./references/ash3_contract_fixes_and_verification_suite.md`](./references/ash3_contract_fixes_and_verification_suite.md) (Standalone `data_layer_test.exs` & Ash 3 contract notes)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Note:** Spark DSL entities, `BuildIndexPlan`, `VerifyNoSqlFragments`, and `VerifyCrossStoreReferences` are implemented in prerequisite track [`ash_dsl_and_verifiers_20261111`](../ash_dsl_and_verifiers_20261111/index.md).
> - **Done When:** Complete end-to-end multi-store verification suite passes with zero warnings on `async: true`.

---

## Phase 1: DataLayer Behaviour (`Xitdb.Ash.DataLayer`)

- [ ] Task: Implement `lib/xitdb/ash/data_layer.ex`
    - [ ] Wire Spark extension sections, `BuildIndexPlan` transformer, and `VerifyNoSqlFragments` / `VerifyCrossStoreReferences` verifiers from `Xitdb.Ash.Dsl`
    - [ ] Implement `can?/2` with accurate Ash 3.37+ feature flags and hybrid `AshPostgres` boundary guards:
      - Omit `:composite_primary_key` (aligning with `BuildIndexPlan` single-column PK check in Wave 1/2)
      - Advertise `:async_engine, :multitenancy, :transact, :create, :read, :update, :destroy, :bulk_create, :update_query, :destroy_query, :upsert, :filter, :boolean_filter, :nested_expressions, :through_relationship, :changeset_filter, :atomic_update, :expr_error, :calculate, :expression_calculation, :expression_calculation_sort, :aggregate_filter, :aggregate_sort, :sort, :distinct, :distinct_sort, :limit, :offset, :select`
      - Advertise `{:atomic, :update | :upsert | :create | :destroy}`, `{:aggregate, :unrelated}`, `{:exists, :unrelated}`, and `{:aggregate | :query_aggregate, kind}` for `:count, :exists, :first, :list, :sum, :min, :max, :avg`
      - Scope `can?(_resource, {:join, other})`, `can?(_resource, {:filter_relationship, %{destination: dest}})`, and `can?(_resource, {:aggregate_relationship, %{destination: dest}})` strictly to `Ash.Resource.Info.data_layer(...) == Xitdb.Ash.DataLayer`
    - [ ] Implement both singular and plural query-shaping callbacks (`add_aggregate/3`, `add_aggregates/3`, `add_calculation/4`, `add_calculations/3`, `filter/3`, `sort/3`, `distinct/3`, `distinct_sort/3`, `limit/3`, `offset/3`, `select/3`, `set_context/3`, `set_tenant/3`) delegating to `Xitdb.Ash.Query`
    - [ ] Implement `calculate/3` for one-off `Ash.calculate/3` evaluations
    - [ ] Implement `transaction/4`, `in_transaction?/1`, `rollback/2`, `prefer_transaction?/1`, and `prefer_transaction_for_atomic_updates?/1` delegating to `Xitdb.Ash.Store`
    - [ ] Wire `create/2`, `bulk_create/3`, `update/2`, `update_query/4`, `destroy/2`, `destroy_query/4`, `upsert/3,4` to `Xitdb.Ash.Mutator`
    - [ ] Wire `run_query/2` and `run_aggregate_query/3` to `Xitdb.Ash.Query` over `Store.current_db/1` with `:telemetry.span` wrappers

---

## Phase 2: Standalone Dual-Store Verification Suite & CI Integration

- [ ] Task: Add `{:simple_sat, "~> 0.1", only: :test}` (or `:picosat_elixir`) to `mix.exs` test dependencies so `Ash.Policy.Authorizer` SAT-solver policy compilation runs with zero warnings
- [ ] Task: Implement self-contained `test/xitdb/ash/data_layer_test.exs` (from [`./references/ash3_contract_fixes_and_verification_suite.md`](./references/ash3_contract_fixes_and_verification_suite.md), keeping `AgendaSession` and `Conference` flat in Wave 2 and deferring physical `nested_in` subtree tests to Track 11B in Wave 3)
    - [ ] Boot `TestSandbox.init()` plus supervised `TestMdmStore` and `TestAppStore` in `setup_all`, and check out per-test isolated `:memory` handles in `setup`
    - [ ] Verify single-commit CRUD, monotonic sequences, `:ci_string` identities, `counted_set_fields`, and partial `where:` identities
    - [ ] Verify PK preservation on `uuid_primary_key` upserts across `:replace_all`, `{:replace, ...}`, `{:replace_all_except, ...}`, `nil`, and field lists
    - [ ] Verify cross-store `Deal` `:update` atomic policy with `exists(organization.profiles, ...)` (`:unknown` hydration), pre-update vs. post-update `atomics` / `atomic_validations`, and `Deal.has_materials_access` relational calculation
    - [ ] Verify `StartDateCalc` module calculation sorting/filtering, `:context` multitenancy isolation, and BM25 `Search` stale-token cleanup on update/destroy
    - [ ] Verify `:restrict`, `:nilify`, and `:delete` cascades, nested savepoint rollbacks, `$callers` async worker propagation, and `VerifyNoSqlFragments` compile-time guard
- [ ] Task: Run `mix precommit` and ensure zero warnings and clean formatting
