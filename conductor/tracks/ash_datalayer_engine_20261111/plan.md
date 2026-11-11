# Implementation Plan: Track 1 — `Xitdb.Ash.DataLayer` Engine (in `xitdb` repo)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `xitdb_datalayer_1_engine_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference 4 (Ash 3 Contract Fixes & Verification Suite):** [`./reference_ash3_contract_fixes_and_verification_suite.md`](./reference_ash3_contract_fixes_and_verification_suite.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Consumer Repository:** `caasa/connect` (`/home/pauli/projects/nvestiv/caasa/connect`)
> - **Done When:** `mix test test/xitdb/ash/data_layer_test.exs` passes 100% in `xitdb` with zero compiler warnings and zero required dependencies for non-Ash callers.

---

## Phase 1: Package Setup, Boundary Guards & Mix Configuration

- [ ] Task: Update `mix.exs` in `xitdb`
    - [ ] Add `{:telemetry, "~> 1.2"}`
    - [ ] Add `{:ash, "~> 3.0", optional: true}`
    - [ ] Add `{:spark, "~> 2.2", optional: true}`
    - [ ] Add `usage-rules.md` to `package()[:files]`
- [ ] Task: Ensure all modules under `lib/xitdb/ash/` are guarded by `if Code.ensure_loaded?(Ash.DataLayer)`
- [ ] Task: Verify standalone `mix compile` passes without Ash

---

## Phase 2: Spark DSL, Info Introspection & Verifiers

- [ ] Task: Implement `lib/xitdb/ash/dsl.ex`
    - [ ] Define `xitdb` section with `store`, `collection`, `Index`, `NestedIn`, `Reference`
    - [ ] Implement `Xitdb.Ash.Transformers.BuildIndexPlan` to auto-index foreign keys and register reverse references
    - [ ] Implement `Xitdb.Ash.Verifiers.VerifyNoSqlFragments` to catch raw SQL fragments at compile time
- [ ] Task: Implement `lib/xitdb/ash/info.ex`
    - [ ] Expose helpers: `store!/1`, `collection!/1`, `nested_in/1`, `indexes/1`, `references/1`, `incoming_delete_rules/2`

---

## Phase 3: Type Codec & B+Tree Secondary Indexer

- [ ] Task: Implement `lib/xitdb/ash/codec.ex`
    - [ ] Handle `Ash.Type.CiString` casing preservation and lowercased index keys
    - [ ] Handle `Ash.Type.UtcDatetime` / `UtcDatetimeUsec` as epoch microseconds for range queries
    - [ ] Handle `Ash.Type.Date` as ISO strings
    - [ ] Handle atom, map, and embedded type serialization
- [ ] Task: Implement `lib/xitdb/ash/indexer.ex`
    - [ ] Maintain `_parent` locator index for `nested_in` resources
    - [ ] Maintain unique identity indexes
    - [ ] Maintain multi-value secondary indexes using `:counted_hash_set`
    - [ ] Implement index differential computation on update/destroy
    - [ ] **Ash 3 Fix:** Adapt `find_upsert_existing_id/5` to accept `%Ash.Resource.Identity{}` struct, atom name, or fallback key match list

---

## Phase 4: Single-Writer Store, Savepoints & Atomic Snapshot Engine

- [ ] Task: Implement `lib/xitdb/ash/store.ex` and `lib/xitdb/ash/store/snapshot.ex`
    - [ ] Implement `use Xitdb.Ash.Store` macro with GenServer writer
    - [ ] Implement `Xitdb.Ash.Store.Snapshot` using `:persistent_term` for static `{base_db, atomics}` handle and `:atomics` for per-commit 5ns moment updates (zero global GC scans)
    - [ ] Implement 3-tier read resolution (Process Dict -> TestSandbox ETS -> `Snapshot.current_db/1`)
    - [ ] Implement nested transaction savepoint stack and rollback via throw `{:xitdb_ash_rollback, store, reason}`

---

## Phase 5: Two-Tier Query Planner, Evaluator & Aggregates

- [ ] Task: Implement `lib/xitdb/ash/query.ex`
    - [ ] Implement Tier 1 index lookup (PK `O(1)`, `_parent`, FK `:sorted_map`, multi-index intersection)
    - [ ] Implement Tier 2 entity hydration and residual filtering via `Ash.Filter.Runtime.filter_matches/4`
    - [ ] Implement Tier 3 in-memory sorting, pagination (`limit`, `offset`)
    - [ ] Implement aggregate calculations (`:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg`)

---

## Phase 6: Atomic Mutator, Sequences & Cascading References

- [ ] Task: Implement `lib/xitdb/ash/mutator.ex`
    - [ ] Implement monotonic integer sequence allocation in `meta.sequences[collection]`
    - [ ] Implement `create/2`, `update/2`, `upsert/4`, `destroy/2`, and `bulk_create/3`
    - [ ] Evaluate `changeset.atomics` with `Ash.Expr.eval/2` inside single-writer process
    - [ ] Enforce unique identity checks and partial identity filters
    - [ ] Enforce reverse reference `on_delete` rules (`:restrict`, `:nilify`, `:delete`)

---

## Phase 7: Ash.DataLayer Behaviour, Cross-Store Joins & Ash 3 Contract Fixes

- [ ] Task: Implement `lib/xitdb/ash/data_layer.ex`
    - [ ] Implement all `@behaviour Ash.DataLayer` callbacks
    - [ ] **Ash 3 Fix:** Remove `:calculate` from `can?/2` to delegate expression calculation loading to Ash Core's `Ash.Actions.Read.Calculations`
    - [ ] **Ash 3 Fix:** Implement no-op `join/7` callback returning `{:ok, query}` for `can?(resource, {:join, other})`
    - [ ] Support cross-store relationship loading via Ash `{:join, other}` protocol
    - [ ] Instrument with `:telemetry.span`

---

## Phase 8: Test Sandbox & Standalone Verification Suite

- [ ] Task: Implement `lib/xitdb/ash/test_sandbox.ex`
    - [ ] Process-isolated copy-on-write fork handles stored in ETS keyed by `self()` and `$callers`
    - [ ] Support `checkout/1` for multiple stores
- [ ] Task: Install `test/xitdb/ash/data_layer_test.exs` from [Reference 4](./reference_ash3_contract_fixes_and_verification_suite.md)
    - [ ] Verify sequences, `CiString` identities, counted sets, upserts
    - [ ] Verify partial `where:` identities on create and status transitions
    - [ ] Verify `nested_in` subtrees (`:many` and `:one`) & `_parent` direct lookup
    - [ ] Verify aggregates, cross-store joins, `exists(...)`, and `Ash.Policy.Authorizer`
    - [ ] Verify atomic updates, nested savepoint rollbacks, and FK `on_delete` rules
    - [ ] Verify `TestSandbox` `$callers` isolation & `VerifyNoSqlFragments` verifier
- [ ] Task: Run verification loop in `xitdb`:
    ```bash
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix test test/xitdb/ash/data_layer_test.exs
    ```
