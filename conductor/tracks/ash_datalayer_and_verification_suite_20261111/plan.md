# Implementation Plan: Track 11 — Ash 3 DataLayer Behaviour & Verification Suite

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_datalayer_and_verification_suite_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Complete end-to-end multi-store verification suite passes with zero warnings on `async: true`.

---

## Phase 1: Compile-Time Transformers & Verifiers

- [ ] Task: Implement `lib/xitdb/ash/transformers/build_index_plan.ex`
    - [ ] Auto-generate B+Tree indexes for `belongs_to` foreign keys when `index_relationships?` is true
    - [ ] Persist compiled indexes into `dsl_state` without foreign module mutations
- [ ] Task: Implement `lib/xitdb/ash/verifiers/verify_no_sql_fragments.ex`
    - [ ] Walk AST of resource calculations, validations, and filters to reject `Ash.Query.Function.Fragment`
- [ ] Task: Implement `lib/xitdb/ash/verifiers/verify_cross_store_references.ex`
    - [ ] Assert that `references` with cascading actions target resources within the same `store`

---

## Phase 2: DataLayer Behaviour (`Xitdb.Ash.DataLayer`)

- [ ] Task: Implement `lib/xitdb/ash/data_layer.ex`
    - [ ] Implement `can?/2` with appropriate capabilities (excluding `:calculate`)
    - [ ] Implement no-op `join/7` returning `{:ok, query}`
    - [ ] Implement `transaction/4`, `in_transaction?/1`, and `rollback/2`
    - [ ] Wire `create/2`, `bulk_create/3`, `update/2`, `update_query/4`, `destroy/2`, `destroy_query/4`, `upsert/4` to `Xitdb.Ash.Mutator`
    - [ ] Wire `run_query/2` and `run_aggregate_query/3` to `Xitdb.Ash.Query`
    - [ ] Add `:telemetry.span([:xitdb, :ash, :query], ...)` wrapper

---

## Phase 3: Verification Suite & CI Integration

- [ ] Task: Implement `test/xitdb/ash/data_layer_test.exs`
    - [ ] Multi-store setup (`TestMdmStore`, `TestAppStore`)
    - [ ] Test CRUD and bulk lifecycle
    - [ ] Test atomic mutations and policy filter checks
    - [ ] Test identity upserts with `%Ash.Resource.Identity{}`
    - [ ] Test secondary index lookups and composite range queries
    - [ ] Test `nested_in` parent-child lifecycle and cascading deletes
    - [ ] Test concurrent async isolation with `Xitdb.Ash.TestSandbox`
- [ ] Task: Run `mix precommit` and ensure zero warnings and clean formatting
