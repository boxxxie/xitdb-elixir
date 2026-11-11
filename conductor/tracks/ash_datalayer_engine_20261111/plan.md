# Implementation Plan: Track 1 — `Xitdb.Ash.DataLayer` Engine (in `xitdb` repo)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `xitdb_datalayer_1_engine_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference 2 (DataLayer Architecture & Internals):** [`../pure_xitdb_ash_datalayer_20261111/reference_data_layer_implementation.md`](../pure_xitdb_ash_datalayer_20261111/reference_data_layer_implementation.md)
> - **Reference 4 (Ash 3 Contract Fixes & Verification Suite):** [`./reference_ash3_contract_fixes_and_verification_suite.md`](./reference_ash3_contract_fixes_and_verification_suite.md)
> - **Reference 5 (In-Xitdb BM25 Search & Atomic Snapshots):** [`../pure_xitdb_ash_datalayer_20261111/reference_in_xitdb_search_and_atomic_snapshots.md`](../pure_xitdb_ash_datalayer_20261111/reference_in_xitdb_search_and_atomic_snapshots.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Consumer Repository:** `caasa/connect` (`/home/pauli/projects/nvestiv/caasa/connect`)
> - **Done When:** `mix test test/xitdb/ash/data_layer_test.exs` passes 100% in `xitdb` with zero compiler warnings and zero required dependencies for non-Ash callers.

---

## Phase 1: Package Setup, Boundary Guards, CLI & Formatter

- [ ] Task: Update `mix.exs` in `xitdb`
    - [ ] Add `{:ash, "~> 3.37 and >= 3.37.2", optional: true}`
    - [ ] Add `{:spark, "~> 2.2", optional: true}`
    - [ ] Add `{:nimble_options, "~> 1.1 and >= 1.1.1"}`
    - [ ] Add `{:telemetry, "~> 1.2"}`
    - [ ] Configure `def cli` (`preferred_envs: [precommit: :test]`)
    - [ ] Add `usage-rules.md` and `.formatter.exs` to `package()[:files]`
- [ ] Task: Configure `xitdb/.formatter.exs` exporting `locals_without_parens` for the `xitdb` DSL
- [ ] Task: Ensure all modules under `lib/xitdb/ash/` are guarded by `if Code.ensure_loaded?(Ash.DataLayer)`
- [ ] Task: Verify standalone `mix compile` passes cleanly without Ash

---

## Phase 2: Spark DSL, Local Transformer & Compile-Time Verifiers

- [ ] Task: Implement `lib/xitdb/ash/dsl.ex`
    - [ ] Define `xitdb` section with `store`, `collection`, `Index`, `NestedIn`, `SearchField`, `Reference`
    - [ ] Implement `Xitdb.Ash.Transformers.BuildIndexPlan` to auto-index foreign keys and persist outgoing `%Reference{}` rules strictly on local `dsl_state`
    - [ ] Implement `Xitdb.Ash.Verifiers.VerifyNoSqlFragments` to catch raw SQL fragments at compile time
    - [ ] Implement `Xitdb.Ash.Verifiers.VerifyCrossStoreReferences` ensuring same-store references for `on_delete: :delete | :nilify | :restrict`
- [ ] Task: Implement `lib/xitdb/ash/info.ex`
    - [ ] Expose helpers: `store!/1`, `collection!/1`, `nested_in/1`, `indexes/1`, `search_fields/1`, `references/1`, `incoming_delete_rules/2`

---

## Phase 3: Binary Key Encoding, B+Tree Indexer & In-Xitdb BM25 Search

- [ ] Task: Implement `lib/xitdb/ash/codec.ex`
    - [ ] Handle `Ash.Type.CiString` casing preservation and lowercased index keys
    - [ ] Handle integer keys and `:utc_datetime` epoch microseconds as sign-flipped big-endian 64-bit binaries
    - [ ] Handle `Ash.Type.Date` as ISO-8601 strings
    - [ ] Handle length-prefixed composite identity/index keys (scoped by `tenant`)
    - [ ] Handle safe atom and embedded serialization via `cast_stored/3` and `dump_to_embedded/3`
- [ ] Task: Implement `lib/xitdb/ash/indexer.ex`
    - [ ] Maintain `_parent` locator index for `nested_in` resources
    - [ ] Maintain unique identity indexes honoring `identity.nils_distinct?`
    - [ ] Maintain multi-value secondary indexes using `:counted_hash_set`
    - [ ] Implement recursive subtree index cleanup on delete/reparent
    - [ ] Adapt `find_upsert_existing_id/5` to accept `%Ash.Resource.Identity{}` struct, atom name, or fallback key match list
- [ ] Task: Implement `lib/xitdb/ash/search.ex`
    - [ ] Slot structure: `idx.search.<collection>` with `meta`, `docs`, and `:sorted_map` `terms` mapping to `:counted_map` postings (`doc_id => tf`)
    - [ ] Implement BM25 scoring with `O(1)` document frequencies
    - [ ] Implement prefix search via B+Tree range slicing `[prefix, prefix <> <<0xFF>>)` with zero edge-ngrams
    - [ ] Implement incremental indexing diff inside the write transaction

---

## Phase 4: Single-Writer Store, Savepoints & Atomic Snapshot Engine

- [ ] Task: Implement `lib/xitdb/ash/store/snapshot.ex`
    - [ ] Store `{base_db, atomics_ref, reverse_fks}` in `:persistent_term` once at store boot
    - [ ] Implement 5ns `:atomics.put/3` moment updates on write commit (zero global GC scans)
    - [ ] Implement `Snapshot.committed_db/1` and `Snapshot.reverse_fks/2`
- [ ] Task: Implement `lib/xitdb/ash/store.ex`
    - [ ] Implement caller-supervised `GenServer` with `NimbleOptions` validation
    - [ ] Compile reverse-FK boot lookup map from `domains: [...]`
    - [ ] Implement caller-process monitored writer lease (`Store.transact/3`)
    - [ ] Implement store-scoped savepoint rollbacks (`{:xitdb_ash_rollback, ^store, reason}`)
    - [ ] Implement 3-tier read resolution (Process Dict -> TestSandbox ETS -> `Snapshot.committed_db/1`)

---

## Phase 5: Six-Stage Query Execution Engine

- [ ] Task: Implement `lib/xitdb/ash/query.ex`
    - [ ] Return `{:ok, %Query{}}` from all shaping callbacks (`filter/3`, `sort/3`, `distinct/3`, `distinct_sort/3`, `limit/3`, `offset/3`, `select/3`, `set_context/3`, `set_tenant/3`, `add_aggregates/3`, `add_calculations/3`)
    - [ ] Implement Stage 1 Narrow (PK `O(1)`, `nested_in` parent jump, identity, secondary FK/range B+Tree intersection)
    - [ ] Implement Stage 2 Hydrate (decode narrowed cursors via `Codec.from_cursor/2`)
    - [ ] Implement Stage 3 Pre-Filter (pure attribute predicates)
    - [ ] Implement Stage 4 Enrich & Filter (compute aggregates/calculations, run `Ash.Filter.Runtime.filter_matches/4`)
    - [ ] Implement Stage 5 Order & Slice (distinct, runtime sort, offset, limit)
    - [ ] Implement Stage 6 Project (apply `query.select` attribute masking last)
    - [ ] Implement aggregate calculations (`:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg`)
    - [ ] Wrap `run_query/2` in `:telemetry.span([:xitdb, :ash, :query], ...)` with `:status` metadata

---

## Phase 6: Atomic Mutator, Sequences, Policies & Cascades

- [ ] Task: Implement `lib/xitdb/ash/mutator.ex`
    - [ ] Implement `create/2`, `bulk_create/3`, `update/2`, `update_query/4`, `upsert/4`, `destroy/2`, and `destroy_query/4`
    - [ ] Monotonic integer sequence allocation in `meta.sequences[collection]` with duplicate-PK rejection on `create/2`
    - [ ] Advance `sequences[collection] = max(seq, explicit_id)` when explicit IDs are seeded
    - [ ] Enforce `changeset.filter` (`FilterCheck` write policies + optimistic locks) and `changeset.atomic_validations` before evaluating `changeset.atomics` via `Ash.Expr.eval/2`
    - [ ] Enforce tenant-scoped unique identities and partial `where` filters (`Ash.Filter.Runtime.matches?/3`)
    - [ ] Enforce reverse reference `on_delete` rules (`:restrict`, `:nilify`, `:delete`) and sync `idx.search` in the same transaction

---

## Phase 7: Ash.DataLayer Behaviour & Capabilities

- [ ] Task: Implement `lib/xitdb/ash/data_layer.ex`
    - [ ] Implement all `@behaviour Ash.DataLayer` callbacks
    - [ ] Declare capabilities (`:create`, `:bulk_create`, `:read`, `:update`, `:update_query`, `:destroy`, `:destroy_query`, `:upsert`, `:transact`, `{:atomic, :update}`, `{:atomic, :destroy}`, `:calculate`, `:filter`, `:sort`, `:distinct`, `:distinct_sort`, etc.)
    - [ ] Implement pass-through `join/7` returning `{:ok, query}`
    - [ ] Delegate `transaction/4`, `in_transaction?/1`, `rollback/2` to `Store`

---

## Phase 8: Test Sandbox & Standalone Verification Suite

- [ ] Task: Implement `lib/xitdb/ash/test_sandbox.ex`
    - [ ] Process-isolated copy-on-write fork handles stored in ETS keyed by `self()` and `$callers`
    - [ ] Support `checkout/1` for multiple stores
- [ ] Task: Install and run `test/xitdb/ash/data_layer_test.exs` from Reference 4
    - [ ] Run verification loop in `xitdb`:
      ```bash
      mix format --check-formatted
      mix compile --warnings-as-errors
      mix test test/xitdb/ash/data_layer_test.exs
      ```
    - [ ] Confirm 100% test pass rate with zero warnings
