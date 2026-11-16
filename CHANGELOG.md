# Changelog

All notable changes to this project will be documented in this file.

## [2.0.0] - 2026-11-16

### Breaking Changes
- **Minimum Elixir Version (`~> 1.19`):** Bumped minimum required Elixir version from `~> 1.18` to `~> 1.19` in `mix.exs`, CI, and `README.md`.
- **Removed App-Specific Ash MDM Extension & Sync Helpers:**
  - Removed `Xitdb.Ash.Resource`, `Xitdb.Ash.Transformers.WireChanges`, `Xitdb.Ash.Verifiers.VerifySyncProjection`, `editable_fields`/`passthru_fields` from `Xitdb.Ash.Dsl`, legacy MDM fields from `Xitdb.Ash.NestedIn`, and MDM sync-projection helpers from `Xitdb.Ash.Info`.
  - `Xitdb.Ash` now focuses exclusively on `Xitdb.Ash.DataLayer`, `Xitdb.Ash.Dsl`, `Xitdb.Ash.Store`, `Xitdb.Ash.Search`, `Xitdb.Ash.TestSandbox`, `Xitdb.Ash.Info`, and `Xitdb.Ash.Tx`.

### Added
- **GitHub Actions CI & Badges:** Added [`.github/workflows/ci.yml`](.github/workflows/ci.yml) running `odin check` and `mix precommit` across Elixir `1.19` / `1.20` and OTP `28`, plus CI, version, and benchmark badges in `README.md`.
- **1v1 Benchmarks `#27` & `#28` and Contention Guardrails:**
  - Added benchmark `#27` (`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`) and `#28` (`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`).
  - Added `/proc/stat` CPU busy-% contention checks, `#3-#6` canary drift detection, `CV%` / `median_min_ratio` skew guardrails, `--require-clean`, and git worktree / `-dirty` tag handling in `benchmarks/compare_1v1.py`, `benchmarks/bench_client.odin`, and `benchmarks/update_readme.sh`.

### Changed
- **Virtual Write Cursors & Adaptive `Enumerable` (`Xitdb.Cursor`, `native/xitdb_nif.odin`):**
  - Staged write-only virtual cursors during `tx_mode` `Access` updates (`put_in/3` blind writes avoid intermediate read NIF crossings) with `classify_access_fun/1` and foreign/snapshot cursor guards.
  - Tracked intra-transaction container replacements (`Replaced_Path`) in `odin_nif_transact` and restored `Root_Header` + `core_length` atomically on `.Unexpected_Tag` retries or commit errors.
  - Ramped `Enumerable.Xitdb.Cursor` chunks geometrically (`16 -> 64 -> 256`), added `O(1)` `count/1` and `member?/2` fast paths, propagated `:closed` errors strictly, and filtered root `"__tx"` across `pull`, `count`, and `slice`.
- **Compact 3-Tuple Cursors & Fused B+Tree Seek (`Xitdb.Cursor`, `Xitdb.NIF`, `Xitdb.Ash.Search`, `Xitdb.Ash.Indexer`):**
  - Shrunk NIF container cursor returns to 3-tuples `{:cursor, tag_id, slot_val}` decoded via `Cursor.from_compact_slot/4` and `unwrap_nif_value/4`.
  - Added dirty-CPU `nif_sorted_map_seek/7` (`ERL_NIF_DIRTY_JOB_CPU_BOUND`) for fused B+Tree prefix seek and bounded child decoding in `Xitdb.Ash.Search`, while keeping `Xitdb.Ash.Indexer` range streams lazy on 6-arity seek.
- **C Batch Step-List Unpacking & Inlined `select` (`native/nif_entry.c`, `lib/xitdb.ex`, `Xitdb.DSL.PathCompiler`):**
  - Added `nif_unpack_step_list` (`NifRawStep`) in C for up to 16 `path_steps/1` steps plus optional `{:at_moment, m}` with bounds guards and Odin fallback.
  - Inlined `Xitdb.select/2` and `Xitdb.select!/2` scalar unwrapping while preserving `@moment` and `root: true` semantics.
- **Single-Pass Streaming Writers & Atomic Rollback (`native/nif_entry.c`, `native/xitdb_nif.odin`):**
  - Streamed Elixir map entries directly via `enif_map_iterator_*` (`Nif_Map_Iter`, 32-slot `KV_Stack_Buf` fast path + checked `temp_allocator` fallback) with `MAX_WRITE_DEPTH` (64) and struct validation guards.
  - Enforced atomic `Root_Header`, `core_set_length`, and `core_sync` rollback on mid-payload failures and adaptive retries.

### Fixed
- **Elixir 1.20 Gradual Type-Checker & 1.19+ Warnings:** Resolved gradual type-checker warnings in `Xitdb.Ash.Search`, `Xitdb.Ash.Query`, and `Xitdb.Ash.Transformers.BuildIndexPlan`, and fixed an Elixir 1.19+ `MapSet` struct-update warning.
- **NIF, Selector & B+Tree Seek Hardening:**
  - Hardened `.Bytes` slot offset/length bounds (`>= HEADER_LENGTH`), root `"__tx"` chunk deduplication, pure-removal validation (`%Xitdb.Collection{}` / map depth ordering), `tx_mode` non-binary key path aliasing, `MAX_FUSED_TOTAL_ENTRIES` overflow accounting, `sorted_map_tx_rank` error propagation, and `>128B` `stack_buf` reads.
  - Fixed selector escaping and sigil handling (`#col["k"]`, `$col["k"]`, `."k.1"`, `@` rejection, quoted-tail checks), typed-modifier guards in `PathCompiler`, `{:linked_list, [idx]}` unwrapping in NIF, and `Linked_Array_List`/set support in `history_of`.
- **Documentation & Benchmarks:** Updated stale `Xitdb.Ash.Resource` references in `docs/transaction-dsl.md`, synced workload counts (`28`) in `README.md` and `benchmarks/README.md`, and fixed `-dirty` commit matching and coverage filtering in `benchmarks/update_readme.sh`.

## [1.2.0] - 2026-11-15

### Added
- **Pre-Tokenized `Xitdb.DSL.path_steps/1` & Direct Step-List API:**
  - Added [`Xitdb.DSL.path_steps/1`](lib/xitdb/dsl.ex) to compile Elixir path expressions into pre-tokenized `[term()]` path-step lists at compile time, eliminating runtime selector formatting and NIF-side selector parsing.
  - Widened `Xitdb.select/2`, `Xitdb.select!/2`, `Xitdb.history_of/2`, `Xitdb.fork/3`, and `Xitdb.DSL` transaction helpers (`put`, `put_set_member`, `update`, `rm`, `append`, `slice`, `init_col`) to accept pre-tokenized step lists alongside selector strings.

### Changed
- **Client & NIF Fast Paths:**
  - Added stack-buffered step-list execution in `native/xitdb_nif.odin` and fast-path `Xitdb.transact/3`, `Xitdb.insert_at/4`, and `Xitdb.fork/3` clauses for default options and empty staged cursor ops.
  - Updated 1v1 benchmark baseline, history, and static code slices (`benchmarks/`).

## [1.1.2] - 2026-11-15

### Changed
- **Client, Cursor, Pull & NIF Performance Optimizations:**
  - Replaced `:binary.match/2` pattern lists in `Xitdb.Selector` with compile-time byte pattern matching (`bare_key?/1` and `needs_escape?/1`).
  - Removed redundant `ensure_resolved/1` calls on string/atom keys in `Xitdb.Cursor` (`fetch/2`, `get_and_update/3`, `pop/2`), deferred `steps_to_selector/1` to leaf writes, and added empty-collection fast paths for staged overrides.
  - Precomputed default `NimbleOptions` schemas in `Xitdb`, skipped `index_rules` `MapSet` allocation when empty, and bypassed `Pull.split_wildcard_plan/1` when patterns contain no `"*"`.
  - Added subtree `merge_map` transaction operation, Pull fast path, and moment slot lookup fast path in `native/xitdb_nif.odin` (`odin_nif_transact`, `odin_nif_pull`, `odin_nif_sorted_map_seek`, `odin_nif_bm25_search`), and eliminated duplicate step slice cloning and eager visited-map allocation.
- **Benchmarks & Documentation:**
  - Added selective 1v1 benchmark runner, git-diff change-to-benchmark planner, dirty-run isolation, and static call-graph code slices (`benchmarks/slices/`), and updated the 1v1 baseline and `~255 ns` NIF boundary cost model documentation.
  - Expanded `Xitdb.Ash.Store`, `Xitdb.Ash.Search`, `Xitdb.Ash.TestSandbox`, and `nested_in` documentation, and fixed `timestamps` `public?` examples, the `Cursor` diagram, and search notes in `README.md`, `docs/ash-and-spark.md`, and `usage-rules.md`.

### Fixed
- **Ash `Info` Cache & `Search` Option Validation:**
  - Keyed `Xitdb.Ash.Info` pair cache by module MD5 and purged stale `:persistent_term` entries on recompile in `Xitdb.Ash.Transformers.WireChanges`.
  - Restricted `Xitdb.Ash.Search` `:db` option validation to `%Xitdb{}`, `%Xitdb.Cursor{}`, or `nil`, and aligned `reverse_fk` typespecs for `nested_in` resources.
  - Added test coverage for shared `xitdb_moment` propagation, `:nilify` BM25 cleanup, and raw `nil`/empty map `TxCompiler` assertions.

## [1.1.1] - 2026-11-15

### Fixed
- **NIF Boundary & Safety Hardening:**
  - Moved heavy read/query NIFs (`nif_slot_materialize`, `nif_pull`, `nif_diff_moments`, `nif_history_of`, `nif_query_datalog`) to dirty CPU schedulers (`ERL_NIF_DIRTY_JOB_CPU_BOUND`), added rwlock helpers (`acquire_rlock`/`acquire_wlock`), validated forged slots and malformed transaction op terms, and prevented duplicate leaf key crashes when building Erlang maps.
- **Client, Cursor, Pull & DSL Hardening:**
  - Added staged overlay prefix purging/forking on `%Xitdb.Cursor{}`, wildcard pull plan splitting/merging with escaped field names in `Xitdb.Pull`, and adversarial key escaping across `Xitdb.DSL`, `Xitdb.Sigils`, and internal selector/Datalog/transaction compilers.
- **Ash DataLayer, Search & Spark DSL Hardening:**
  - Restricted `Xitdb.Ash.Search` `:as_of` validation to `:non_neg_integer | nil`, typed `search_field :resolver` as `{:fun, 2} | nil` in `Xitdb.Ash.Dsl` and `Xitdb.Ash.Resource` (supporting inline `fn` resolvers), and hardened `Codec`, `Indexer`, `Mutator`, `Query`, `Store`, and `TestSandbox` edge cases (empty maps, `nil`-valued overrides, lease queue, and snapshot handling).
- **Benchmarks & Documentation:**
  - Normalized `Ops` counts in benchmarks `#10` (`Enum.to_list/1`) and `#13` (bulk 100-entity batch transact) to measure per-call/commit latency, fixed `benchmarks/update_readme.sh` to retain all 26 rows across partial commit runs, fixed Ash examples in `README.md` and `docs/ash-and-spark.md`, and cleaned up ExDoc module groups and extras in `mix.exs`.

## [1.1.0] - 2026-11-14

### Added
- **Native Ash Framework 3.37.2+ DataLayer (`Xitdb.Ash.DataLayer`):**
  - Full `Ash.DataLayer` implementation backed by immutable copy-on-write `.xit` files with lock-free reads, atomic updates/upserts/destroys, bulk creates/updates/destroys, relationships (`belongs_to`, `has_many`, `many_to_many`), expression and module calculations, aggregates (`count`, `exists`, `first`, `list`, `sum`, `min`, `max`, `avg`), multitenancy (`:context` and `:attribute`), and `:telemetry` spans (`[:xitdb, :ash, :query | :aggregate_query | :transaction | :search, ...]`).
  - `Xitdb.Ash.Store`: caller-supervised single-writer store publishing lock-free snapshots via `:persistent_term` and `:atomics` (~10ns reads), monitored caller-process writer leases (`Xitdb.Ash.LeaseError`), nested savepoints (`Store.transact/3`, `Store.rollback/2`, `Store.mutate/3`), and historical time-travel queries (`context: %{shared: %{xitdb_moment: moment}}`, `Store.as_of/2`, `Store.with_as_of/3`).
  - `Xitdb.Ash.Search`: transactional in-Xitdb BM25 and B+Tree prefix search (`search_field :name, boost: 3.0, resolver: ...`) with native Odin NIF scoring pushdown (`nif_bm25_search`), `Xitdb.Ash.Search.query/3`, `ids/3`, `sort_by_rank/2`, `reindex_records/3`, `lookup_field/4`, and historical `as_of:` support.
  - `Xitdb.Ash.TestSandbox`: lock-free isolated `:memory` `%Xitdb{}` test sandbox for `async: true` ExUnit suites (`init/0`, `seed_template/2`, `checkout/2`, `checkin/2`, `allow/3`).
  - `Xitdb.Ash.Codec`, `Xitdb.Ash.Indexer`, `Xitdb.Ash.Query`, and `Xitdb.Ash.Mutator`: binary index key encoding, single-attribute and composite B+Tree (`:sorted_map`) secondary indexes (`index [:status, :inserted_at]`), automatic `belongs_to` foreign-key indexing (`index_relationships? true`), incoming/outgoing same-store foreign-key cascades (`references` with `:nothing | :delete | :nilify | :restrict`), and co-located `nested_in` physical subtrees with reparenting and child index purging.
  - Compile-time Spark transformers and verifiers: `Xitdb.Ash.Transformers.BuildIndexPlan`, `Xitdb.Ash.Verifiers.VerifyNoSqlFragments`, and `Xitdb.Ash.Verifiers.VerifyCrossStoreReferences`.
- **Nested Sub-Collections (`nested_in`) & Expanded `Xitdb.Ash.Info` Introspection:**
  - `nested_in` entity on `Xitdb.Ash.DataLayer` for co-located parent subtrees (enabling 9-byte `fork` snapshots), alongside the MDM `nested_in` support on `Xitdb.Ash.Resource`.
  - Added `Xitdb.Ash.Info.nested_in/1`, `indexes/1`, `search_fields/1`, `references/1`, `counted_set_fields/1`, and `index_relationships?/1`.
- **Native Odin NIF Range-Seek, Client Hardening & Benchmarks:**
  - `nif_sorted_map_seek/5,6` and `nif_bm25_search/7` NIF entrypoints supporting open-ended lower-bound B+Tree range scans (`prefix_only = 0`) and prefix-bounded scans (`prefix_only = 1`).
  - Structured `%Xitdb.Error{reason: ..., details: ...}` exception module (`Exception.message/1`) and `NimbleOptions` validation schemas across `Xitdb.open/1`, `Xitdb.transact/3`, `Xitdb.query/3`, and `Xitdb.compact/2`.
  - Root-cursor guard on `Xitdb.select/2` returning `{:error, %Xitdb.Error{reason: :non_root_cursor}}` when given a non-root child cursor.
  - Added two 1v1 benchmark workloads: `#25` (`Search: Sorted_Map B+Tree prefix seek (limit=16)`) and `#26` (`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`).

### Changed
> **Breaking / Behavior Change:**
> - `Xitdb.Pull` range slices (`field: first..last`) are now **inclusive** of `last` (matching Elixir's `Enum.slice/2`), so `0..2` returns 3 elements (`0`, `1`, `2`) instead of 2. Audit existing `first..last` Pull patterns when upgrading from `1.0.x`.
> - `Xitdb` operations now return `{:error, %Xitdb.Error{reason: ..., details: ...}}` structs instead of bare error atoms/tuples. Audit `{:error, reason}` pattern matches that expect bare atoms.

- `Xitdb.Pull` range slices (`field: first..last`) are now inclusive of `last`, matching Elixir's `Enum.slice/2`.
- Refactored `Xitdb.DSL` into dedicated `PathCompiler`, `DatalogCompiler`, `TxRewriter`, and `TxRuntime` submodules, and inverted `Xitdb.Ash.Tx` compile-time coupling.

### Fixed
- Escaped `@` and backslashes in selector keys and handled quoted hash-map keys in `TxRuntime` path step parsing.
- Eliminated cyclic compilation deadlocks in `Xitdb.Ash.Transformers.WireChanges` via per-pair `:persistent_term` caching and `O(1)` staged operation accumulation on `%Xitdb.Cursor{}`.
- Cloned BM25 top hits out of the local temporary arena before returning in the Raw Odin benchmark runner.

## [1.0.2] - 2026-11-11

### Added
- `nested_in` entity on the `Xitdb.Ash.Resource` DSL. A resource can now live inside a parent entity (`people[id].phones[e164]`, `events[id].conference`) instead of a top-level collection, and can be nested in several parents.
- `Xitdb.Ash.Info.nested_mappings/1`, `nested?/1`, `nested_under/2`, and `entity_paths/2` for resolving where a record is stored.
- `__xitdb_nested_in__/0` is compiled onto every resource.

### Changed
- `collection` is no longer required when the resource declares `nested_in`.
- `VerifySyncProjection` rejects resources that declare neither or both of `collection` and `nested_in`, `cardinality: :many` mappings without a `key`, unknown `parent_key`/`key` attributes, and `indexes` on nested resources.

## [1.0.1] - 2026-11-06

### Changed
- Updated `odin-xitdb` native engine submodule to `b760ee9` (lock-free stateless positional cursors, `vmem`-backed `Core_Memory`, reverse and upper-bound range iterators across all collections, and empty-collection iterator root-read skip optimization).

## [1.0.0] - 2026-11-06

### Added
- Initial release of `Xitdb` Elixir client wrapping `odin-xitdb` via a C-ABI Erlang NIF (`priv/xitdb_nif.so`).
- Lazy 9-byte `Slot` cursor (`%Xitdb.Cursor{}`) implementing `Access`, `Enumerable` (`O(1)` `count/1`, `O(1)` `member?/2`, `O(log N)` `slice/2`, chunked `reduce/3`), and `Inspect`.
- Coarse-grained transactions (`Xitdb.transact/3`) supporting both nested Elixir maps/collections and `put_in/3` / `update_in/3` / `pop_in/2` cursor pipelines.
- Time-travel snapshots (`Xitdb.db/1`, `Xitdb.as_of/2`), structural diffs (`Xitdb.diff_moments/3`), and attribute lineage (`Xitdb.history_of/2`).
- Compile-time validated selector (`~x`) and Datalog (`~q`) sigils, Datomic-style `Xitdb.pull/2` projections, and Datalog queries (`Xitdb.query/3`) with B+Tree secondary index pushdown and grouped aggregations.
- Spark DSL extension (`Xitdb.Ash.Resource`), introspection (`Xitdb.Ash.Info`), transformer (`Xitdb.Ash.Transformers.WireChanges`), verifier (`Xitdb.Ash.Verifiers.VerifySyncProjection`), and declarative transaction macros (`Xitdb.Ash.Tx.tx_for`, `tx_for!`).
- 4-layer Client ATDD executable specification suite (`test/features/*_spec.exs`) and `StreamData` property tests.
- 1v1 Client Statistical Benchmark Suite (`benchmarks/`) comparing the Elixir NIF wrapper against Raw Odin across 16 client workloads.
