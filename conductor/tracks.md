# Project Tracks

This file tracks all development tracks for the `xitdb` Elixir client (`elixir/xitdb`) in strict dependency execution order, reprioritized for a fast hybrid `AshPostgres` + `Xitdb.Ash.DataLayer` cutover:

- **`Wave 0` (Shipped Core):** NIF foundation, lazy cursors, transactions, Pull & Datalog.
- **`Wave 1` (MVP Prerequisites & Hybrid Schema):** Critical client bugfixes (`@`/`\` escaping, `WireChanges` deadlock fix, `O(1)` op staging) & hybrid-aware Spark DSL/verifiers.
- **`Wave 2` (MVP Ash DataLayer Engine):** Single-writer `Store` + `TestSandbox`, flat top-level `Codec`/`Indexer`, `Query` engine, `Mutator` + Elixir BM25 postings, and hybrid-guarded `DataLayer`.
- **`Wave 3` (Deferred Native Search & Physical Nesting):** Odin NIF BM25 pushdown & physical `nested_in` subtree storage.
- **`Wave 4` (Deferred Core Client Refactoring):** Remaining `Pull`/`Cursor` cleanups, `dsl.ex` 5-module split, and `NimbleOptions` guards.
- **`Wave 5` (Deferred Synthetic ATDD, Guides & Packaging):** Standalone `WorkspaceDsl` ATDD suite, operational guides, and Hex release checks.

Each track has its own specification and implementation plan in [`./tracks/`](./tracks/). Split tracks (`5A`/`5B` and `11A`/`11B`) share their existing track directory so all cross-references stay intact.

---

## Wave 0 — Core Foundation (Shipped)

- [x] **Track 1 [Wave 0 — Core Foundation]: 4-Layer ATDD Client Specification Suite & 1v1 Client Benchmark Harness (Elixir Wrapper vs. Raw Odin)**
  *Link: [./tracks/atdd_client_bench_20261103/](./tracks/atdd_client_bench_20261103/)*

---

- [x] **Track 2 [Wave 0 — Core Foundation]: Odin C-ABI NIF Core, `ErlNifResourceType` Lifecycle & Coarse-Grained ETF Bridge**
  *Link: [./tracks/nif_c_abi_core_20261103/](./tracks/nif_c_abi_core_20261103/)*

---

- [x] **Track 3 [Wave 0 — Core Foundation]: Clojure-Style Lazy `%Xitdb.Cursor{}` (`Access`, `Enumerable`, `Inspect`, Chunked Iteration & Collection Type Wrappers)**
  *Link: [./tracks/lazy_cursor_protocols_20261103/](./tracks/lazy_cursor_protocols_20261103/)*

---

- [x] **Track 4 [Wave 0 — Core Foundation]: Ergonomic Transactions (`put_in`/`update_in`), Time-Travel (`as_of`, `diff_moments`, `history_of`), Pull, Datalog & Compile-Time Sigils (`~x`, `~q`)**
  *Link: [./tracks/dsl_transactions_datalog_20261103/](./tracks/dsl_transactions_datalog_20261103/)*

---

## Wave 1 — MVP Prerequisites & Hybrid Ash Schema

- [x] **Track 5A [Wave 1 — MVP Client Fixes]: Selector/Datalog `@` & `\` Escaping, `^sel_len` Pins, `WireChanges` Deadlock Removal & `O(1)` Op Staging**
  *Link: [./tracks/client_fixes_and_dedup_20261111/](./tracks/client_fixes_and_dedup_20261111/)*
  *MVP Scope:* Execute **Phase 1** (byte-level `@`/`\` escaping for email keys + `^sel_len` bitstring pins), **Phase 3** (per-key `:persistent_term` pair cache with zero global GC removing `WireChanges` deadlocks + parallel-safe `tx_for`), **Phase 4A op-staging** (reverse-list `O(1)` op prepending + `MapSet.size/1` opacity compliance + direct `%Xitdb{}` mutation guard), and Wave 1 `mix.exs` test setup (`:stream_data` + `def cli`). Defer Phase 2 (`Pull` ranges) and Phase 4B cursor refactors to **Track 5B**.

---

- [x] **Track 8 [Wave 1 — Hybrid Ash Schema & Verifiers]: Unified Spark DSL Extension, `BuildIndexPlan` Transformer, Hybrid-Safe Verifiers & Additive `Xitdb.Ash.Info`**
  *Link: [./tracks/ash_dsl_and_verifiers_20261111/](./tracks/ash_dsl_and_verifiers_20261111/)*
  *MVP Scope:* Fully decoupled from Track 6 by extending `v1.0.2` `lib/xitdb/ash/info.ex` and `.formatter.exs` additively. Implement `Index`, `SearchField`, `Reference`, and `NestedIn`; reject multi-column PKs and auto-index `belongs_to` FKs in `BuildIndexPlan`; enforce `VerifyNoSqlFragments` (including unhydrated `%Ash.Query.Call{name: :fragment}`, aggregates, preparations, relationship filters, and field policies); and iterate `Info.references/1` directly in `VerifyCrossStoreReferences` to reject unknown/non-`belongs_to` refs, `on_delete: :nilify` on non-nullable FKs, and cross-DB or cross-store cascades.

---

## Wave 2 — MVP Ash DataLayer Engine (Hybrid Cutover Critical Path)

- [x] **Track 10 [Wave 2 — MVP DataLayer Engine]: Single-Writer `Xitdb.Ash.Store` GenServer, Monitored Writer Leases, Savepoints, Hybrid FK Graph & `TestSandbox`**
  *Link: [./tracks/ash_store_and_test_sandbox_20261111/](./tracks/ash_store_and_test_sandbox_20261111/)*
  *MVP Scope:* Implement `LeaseQueue` (with active-lease `req_ref` timeout release), `{db, moment}`-pinned `Xitdb.Ash.Store` working handles and nested savepoints (seeding moment `0` on empty stores so savepoint/lease rollbacks branch cleanly via `base_moment`), isolated `:memory` / `Xitdb.compact!/2` handles with `:kernel_sup` ETS table heirship in `Xitdb.Ash.TestSandbox`, and hybrid-filtered boot-time reverse-FK rules emitting `%{source_resource, source_collection, source_attribute, destination_attribute, on_delete, nested?}`. Defer `nested_in` reverse-FK auto-synthesis to **Track 11B**.

---

- [x] **Track 11A [Wave 2 — MVP DataLayer Engine]: Order-Preserving Binary Key Codec (`Xitdb.Ash.Codec`) & Flat Top-Level B+Tree Indexer (`Xitdb.Ash.Indexer`)**
  *Link: [./tracks/ash_codec_and_indexer_20261111/](./tracks/ash_codec_and_indexer_20261111/)*
  *MVP Scope:* Implement **Phase 1** (`i64`, `f64`, scale-normalized `Decimal`, truncated `:utc_datetime` vs microsecond `:utc_datetime_usec`, fixed-width Gregorian `:date` and microsecond `:time` keys, `CiString`, `counted_set_fields`, composite secondary keys, and `nil`-safe tenant-prefixed composite identities), **Phase 2** flat index op planning (prefix-aware composite bounds for `:inclusive` max / `:exclusive` min), and **Phase 3** pure `Xitdb.transact_ops/3` tuple emission + `NIF.nif_slot_entries` range streaming. Defer physical `nested_in` storage to **Track 11B** (stubbing `nested_cursors_for_parent/3` to `[]`).

---

- [x] **Track 12 [Wave 2 — MVP DataLayer Engine]: Six-Stage Query Execution Engine (`Xitdb.Ash.Query`)**
  *Link: [./tracks/ash_query_engine_20261111/](./tracks/ash_query_engine_20261111/)*
  *MVP Scope:* Implement query shaping callbacks and all six execution stages for flat collections (PK seek, attribute-tenant-aware unique identity seek, single secondary-index seek/range bounds supporting `AshOban` keyset streams, and `all_cursors/2` fallback; hydration; unrelated & batched single-hop relationship aggregates with `parent_stack`; `Ash.Expr.eval/2` + `Ash.Resource.Calculation` modules; `Ash.Filter.Runtime`; `runtime_sort/3`, distinct, pagination, and select masking). Defer `nested_in` parent-jump planning to **Track 11B**.

---

- [x] **Track 13 [Wave 2 — MVP DataLayer Engine]: Atomic Mutator, Sequences, Atomic Validations, Same-Store Cascades & Elixir BM25 Postings (`Xitdb.Ash.Mutator`)**
  *Link: [./tracks/ash_mutator_and_cascades_20261111/](./tracks/ash_mutator_and_cascades_20261111/)*
  *MVP Scope:* Implement single-commit `Xitdb.transact_ops/3` batching across `meta.sequences`, entity/index writes, and BM25 search postings (`old_record` -> `new_record` diff); implement `create`, `bulk_create`, `update`, `update_query`, `destroy`, `destroy_query`, and PK-safe `upsert/4` (supporting all Ash 3 `upsert_fields` forms); enforce `verify_changeset_filter/3` and `verify_atomic_validations/3` (with `Ash.Filter.Runtime.matches?/4` fallback on `:unknown`); and execute same-store `:restrict`, `:nilify`, and `:delete` FK cascades.

---

- [x] **Track 14 [Wave 2 — MVP DataLayer Engine]: Ash 3 `Xitdb.Ash.DataLayer` Behaviour, Hybrid `AshPostgres` Boundary Guards & Verification Suite**
  *Link: [./tracks/ash_datalayer_and_verification_suite_20261111/](./tracks/ash_datalayer_and_verification_suite_20261111/)*
  *MVP Scope:* Wire `Xitdb.Ash.DataLayer` to `Store`, `Mutator`, and `Query` (`{db, moment}` snapshots) with telemetry spans; advertise `:async_engine`, `:multitenancy`, `:calculate`, `:changeset_filter`, `:update_query`, `:destroy_query`, `{:atomic, :update}`, `{:atomic, :destroy}`, and `:upsert` while omitting `:composite_primary_key`; scope `{:join, other}`, `{:filter_relationship, rel}`, and `{:aggregate_relationship, rel}` strictly to `Xitdb.Ash.DataLayer`; and validate flat multi-store + hybrid boundary workflows in `data_layer_test.exs`.

> [!IMPORTANT]
> **MVP Production Cutover Gate (End of Wave 2):**
> - **Full-Text Search:** Replace old SQL `fragment(...)` FTS filters with an `Ash.Resource.Preparation` that over-fetches candidate IDs from `Xitdb.Ash.Search.ids/3` (e.g., `limit: page_size * 5` or tenant-scoped), filters via `id in ^ranked_ids`, sorts via `Xitdb.Ash.Search.sort_by_rank/2`, and applies the final `Ash.Query.limit/2` *after* `Ash.Policy.Authorizer` row filtering.
> - **Postgres Retention Boundary:** Keep `oban_jobs` and high-churn ephemeral `AshAuthentication` token/audit resources on `AshPostgres` to protect single-writer `Xitdb.Ash.Store` throughput.
> - **Job Enqueue Hygiene:** Enqueue immediate Oban jobs inside `after_transaction` hooks rather than `before_action` so workers never race uncommitted `Store` snapshots.
> - **Dual Test Sandbox:** Check out both `Ecto.Adapters.SQL.Sandbox` and `Xitdb.Ash.TestSandbox` in `DataCase`.

---

## Wave 3 — Deferred Native Search Pushdown & Physical Document Nesting

- [x] **Track 9 [Wave 3 — Native Search Optimization]: Native Odin NIF BM25 Pushdown & Direct B+Tree Prefix Seek**
  *Link: [./tracks/nif_bm25_search_20261111/](./tracks/nif_bm25_search_20261111/)*
  *Deferred Rationale:* Drop-in hot-path acceleration (`odin_nif_bm25_search` and `odin_nif_sorted_map_seek`) behind `Xitdb.Ash.Search` requiring zero Ash resource changes after cutover.

---

- [x] **Track 11B [Wave 3 — Physical Subtree Nesting]: `nested_in` Subtree Storage, Reparenting, Parent-Jump Queries & Recursive Child Index Purging**
  *Link: [./tracks/ash_codec_and_indexer_20261111/](./tracks/ash_codec_and_indexer_20261111/)*
  *Deferred Scope:* Complete physical document-subtree nesting deferred from Tracks 10, 11, 12, and 14 (`fetch_nested_cursor/6`, `nested_cursors_for_parent/3`, foreign-key reparenting, `purge_nested_children/4`, and `Store` implicit `nested_in` `:delete` rule synthesis).

---

## Wave 4 — Deferred Core Client Refactoring & Ergonomics

- [ ] **Track 5B [Wave 4 — Core Client Cleanup]: Inclusive `Xitdb.Pull` Range Semantics, `Cursor` `fetch/2` Deduplication & Stepped `Enumerable.slice/1`**
  *Link: [./tracks/client_fixes_and_dedup_20261111/](./tracks/client_fixes_and_dedup_20261111/)*
  *Deferred Scope:* Complete **Phase 2** (`Xitdb.Pull` inclusive slice formatting) and the remaining **Phase 4** `Cursor` internal deduplication, stepped `Enumerable.slice/1`, and `PreviewTag` inspect polish not exercised by `Xitdb.Ash.DataLayer`.

---

- [ ] **Track 6 [Wave 4 — Core Architecture Cleanup]: Split `lib/xitdb/dsl.ex` (`Selector`, `PathCompiler`, `DatalogCompiler`, `TxRuntime`/`TxRewriter`) & Invert Ash/Spark Dependency**
  *Link: [./tracks/split_dsl_and_invert_ash_dependency_20261111/](./tracks/split_dsl_and_invert_ash_dependency_20261111/)*

---

- [ ] **Track 7 [Wave 4 — Core Client Polish]: `Xitdb.Error` Helpers, Compile-Time `NimbleOptions` Validation, Root-Cursor Guard & IEx Docstring Cleanups**
  *Link: [./tracks/remaining_improvements_20261112/](./tracks/remaining_improvements_20261112/)*
  *Note:* Uses `TxRewriter` from Track 6 in Phase 1; keep sequenced after Track 6.

---

## Wave 5 — Deferred Synthetic ATDD Suite, Guides & Hex Release

- [ ] **Track 15 [Wave 5 — Extended Verification]: Ash DataLayer Phase 1 Verification Suite (Pattern D/E Properties & Synthetic 4-Layer `WorkspaceDsl` ATDD Workflows)**
  *Link: [./tracks/ash_phase1_verification_suite_20261111/](./tracks/ash_phase1_verification_suite_20261111/)*

---

- [ ] **Track 16 [Wave 5 — Release Readiness]: Documentation Alignment, Operational Guides & Unified `Xitdb.Ash` Reference Contracts**
  *Link: [./tracks/doc_fixes_and_operational_guides_20261112/](./tracks/doc_fixes_and_operational_guides_20261112/)*

---

- [ ] **Track 17 [Wave 5 — Release Readiness]: Unified Formatter Exports (`.formatter.exs`), Package `usage-rules.md` & Hex Packaging Verification**
  *Link: [./tracks/formatter_exports_and_usage_rules_20261112/](./tracks/formatter_exports_and_usage_rules_20261112/)*
