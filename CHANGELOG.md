# Changelog

All notable changes to this project will be documented in this file.

## [2.5.0] - 2026-11-26

### Added
- **Standardized Observable Fallback Helper (`Xitdb.Fallback`):**
  - Added `Xitdb.Fallback.run/2,3` and `Xitdb.Fallback.try_run/3,4` emitting `[:xitdb, :fallback, :used]` telemetry and structured warning logs for legitimate read-only, query-planner, cache-miss, and display-only fallbacks.
  - Replaced ad-hoc `rescue` blocks and silent catch-all defaults across `Xitdb.Ash.DataLayer`, `Xitdb.Ash.Query`, `Xitdb.Ash.Store`, `Xitdb.Ash.Store.Snapshot`, `Xitdb.Ash.Types.FixedDecimal64`, `Xitdb.Compression`, and `Xitdb.Key` with `Xitdb.Fallback` or explicit error paths.
- **Fallback & Mutation Guardrails (`Credo.Check.Warning.NoBusinessLogicRescue`, `muex`):**
  - Added custom Credo check `Credo.Check.Warning.NoBusinessLogicRescue` (`credo/checks/no_business_logic_rescue.ex`) wired into `.credo.exs` and `mix precommit`.
  - Added `muex` (`~> 0.3.2`) for diff-scoped and coverage-guided mutation testing.

### Changed
- **Dependencies:**
  - Updated `ash` (`3.37.7` -> `3.38.1`) in `mix.lock` and `native/xitdb-odin` submodule to `v2.2.2` (`cf7e585`).

## [2.4.2] - 2026-11-23

### Fixed
- **Iterative, Header-Only Compression Reference GC During Compaction (`native/xitdb_nif.odin`, `Xitdb.compact/2`):**
  - Replaced recursive `gc_collect_slot/5` traversal with iterative worklist-based `gc_collect_slots_iterative/5` (sharing a single pooled `Nif_Iter_Pool` iterator and pre-filtering/deduplicating containers via `gc_enqueue_or_mark_slot/5`) so compaction stays `O(1)` in C stack depth on arbitrarily deep trees.
  - Replaced full-payload `cursor_read_bytes_object` reads in compression reference marking with header-only reads (`gc_mark_tagged_slot/4`, `gc_mark_col_page_dict/4`) and stack-buffered key probing (`gc_encode_sha256_hex_buf/2`, `gc_mark_page_ref/5`, `gc_lookup_page_live/4`), bounding `"pg"` pointer reads and avoiding transient `temp_allocator` memory spikes on large compressed databases.

## [2.4.1] - 2026-11-23

### Fixed
- **Missing Secondary Indexes on `allow_existing_cursor?: true` Coalesced `Ash.bulk_create` (`Xitdb.Ash.Mutator`):**
  - Updated `accumulate_bulk_secondary/7` to check actual `idx.<col>.<slot>[new_hex]` set membership via `fetch_cached_set_cur/5` and `IndexStorage.set_container_member?/2` before skipping `old_raw == new_raw` entries, so hydrating pre-existing raw entity cursors whose secondary index buckets have not yet been populated still populates all `attr_*` secondary indexes while caching per-key bucket cursors across repeated rows.

## [2.4.0] - 2026-11-23

### Added
- **Batched Multi-Key Slot Lookup (`native/xitdb_nif.odin`, `native/nif_entry.c`, `Xitdb.NIF`):**
  - Added `Xitdb.NIF.nif_slot_get_keys/4` (`odin_nif_slot_get_keys`) to fetch multiple keys from `Hash_Map`, `Counted_Hash_Map`, or `Sorted_Map` slots in a single read-locked NIF crossing.
- **Incremental Batch BM25 Indexing (`Xitdb.Ash.Search`):**
  - Added `Xitdb.Ash.Search.index_records!/3,4` (`:tenant`, `:parallel`, `:assume_new?`, `:worker_wrapper`, `:timeout`, `:lease_timeout`) to incrementally index or update deferred batches into populated collections in one atomic commit without re-scanning existing rows.
- **Ash & Bulk NIF Benchmark Suites (`benchmarks/`):**
  - Added [`benchmarks/bench_ash_bulk.exs`](benchmarks/bench_ash_bulk.exs) and 1v1 client benchmark workloads `#29` (`:bulk_put_maps`), `#30` (`:bulk_put_nested_maps`), `#31` (`:bulk_index_puts`), and `#32` (`nif_slot_get_keys/4`).

### Changed
- **Precompiled Read Plans & Batched Bulk Prefetching (`Xitdb.Ash.Codec`, `Xitdb.Ash.Mutator`, `Xitdb.Ash.Query`):**
  - Added `Xitdb.Ash.Codec.compile_read_plan/3` and `from_cursor_fast/3` using `nif_slot_get_keys/4`, prebuilt struct templates, and primitive attribute fast paths across `Query.stage2_hydrate/3`, `Search.rebuild_index!/3`, and `Mutator` overwrites.
  - Enabled Stage 2 `Ash.Query.select/2` hydration narrowing on all resources (including uncompressed resources), falling back conservatively to `:all` on `exists(...)` / `parent(...)` filters and skipping redundant `stage6_project/4` passes when no extra attributes were hydrated.
  - Added probe-first batched `Mutator` prefetching (`prefetch_bulk_lookups/10`) in 2,048-key chunks and switched coalesced `Ash.bulk_create` search staging to shared `Search.plan_bulk_index_ops/4` with precompiled zero-closure term extraction, batched `Search.Storage.read_docs_from_cursor/2`, and `parallel: :auto` (`>= 500` non-resolver rows).

### Fixed
- **Unselected Filter & Sort Dependencies in `Xitdb.Ash.Query`:**
  - Fixed `collect_expr_ref_names/2` and `add_sort_key_names/2` to retain `%Ash.Query.Ref{attribute: %Ash.Resource.Attribute{}}` and `%Ash.Resource.Attribute{}` dependencies when narrowing Stage 2 hydration on `select` queries.

## [2.3.0] - 2026-11-23

### Added
- **Bulk NIF Transaction Operations (`native/xitdb_nif.odin`):**
  - Added coarse-grained `:bulk_put_maps`, `:bulk_put_nested_maps`, and `:bulk_index_puts` (`:unique`, `:counted_set_add`, `:hash_map_merge`) transaction callbacks with deferred cold validation, adaptive container initialization, and atomic rollback on failure.
- **Single-Pass BM25 Rebuild & Deferred Search Indexing (`Xitdb.Ash.Search`, `Xitdb.Ash.Mutator`, `Xitdb.Ash.Indexer`):**
  - Added `Xitdb.Ash.Search.rebuild_index!/2,3` to rebuild `idx.search` in a single atomic commit with optional parallel term extraction (`:tenant`, `:parallel`, `:only_attrs`, `:worker_wrapper`, `:timeout`, and `:lease_timeout`).
  - Added `context: %{xitdb: %{skip_search_index?: true}}` support across coalesced, `nested_in :one`, and `:row_group` `Ash.bulk_create` batches to defer BM25 indexing until a single `Search.rebuild_index!/3` pass.

### Changed
- **Coalesced `Ash.bulk_create` Engine, Fast Attribute Plan & ASCII Tokenizer (`Xitdb.Ash.Mutator`, `Xitdb.Ash.Codec`, `Xitdb.Ash.Search`):**
  - Coalesced standard and `nested_in :many` `Ash.bulk_create` streams into a single staging pass compiling directly to bulk NIF operations with cached sequence, cursor, parent, and index-slot lookups.
  - Added precompiled primitive attribute fast paths in `Xitdb.Ash.Codec.compile_attr_plan/1` and `to_cursor_map_fast/2`, and replaced regex tokenization in `Xitdb.Ash.Search.tokenize/1` with a fast binary-scanning ASCII tokenizer (falling back to Unicode regex only on non-ASCII bytes).

### Fixed
- **Bulk Overwrite Cleanup, Compression & Base-Moment Adaptation (`Xitdb.Ash.Mutator`, `Xitdb.Ash.Indexer`, `Xitdb.Ash.Search`, `native/xitdb_nif.odin`):**
  - Preserved `Xitdb.Encoder` struct encoding in `:map`/embedded attributes and deduplicated `__blobs` value compression during coalesced `Ash.bulk_create`.
  - Cleaned up stale unique identity keys (supporting same-batch key reuse), pruned obsolete secondary index memberships and empty B+Tree buckets, cleared `nil`'d attributes, and removed orphaned old-parent subtrees on `allow_existing_cursor?: true` overwrites for top-level and `nested_in :many` resources.
  - Preserved all tenants during `Search.rebuild_index!/3` on `:attribute`-multitenant resources, re-raised exception structs unwrapped on commit failures, propagated `skip_search_index?: true` to `nested_in :one` evictions, and tracked child container `pending_tags` / `fork_aliases` across bulk callbacks in `adapt_tx_ops_for_base_moment`.

## [2.2.1] - 2026-11-21

### Changed
- **Underlying `odin-xitdb` `v2.1.0` (`9ad5d10`):** Updated `native/xitdb-odin` to `v2.1.0`, bringing in-place `cursor_iterator*_init` procedures, pooled `_Iter_Pool` recursive traversals in DSL `pull`/`diff_cursors`/`unmarshal_into`/Datalog, wire/B-Tree/HAMT hardening, and Odin `dev-2026-11a+` / ARM64 `-vet` compatibility (`xitdb/sha_ni_amd64.odin`, `xitdb/sha_ni_other.odin`).

### Fixed
- **BEAM Dirty-Scheduler Stack Overflows (`SIGSEGV`) in `native/xitdb_nif.odin`:**
  - Replaced stack-allocated `~4.4 KB` `Cursor_Iterator` values in recursive and multi-branch NIF functions with pooled or heap/arena-allocated pointer-initialized iterators (`Nif_Iter_Pool` + `xitdb.cursor_iterator*_init`), cutting per-frame stack usage across `materialize_slot`, `nif_pull_wildcard`, `nif_pull_range`, `nif_pull_cursor`, `gc_collect_slot`, `gc_collect_dead_compression_ops` (`odin_nif_compact`), `nif_dl_eval_pattern_steps`, `decode_container_entries_term`, `decode_child_container_entries_term`, `odin_nif_slot_slice`, `odin_nif_sorted_map_seek`, `odin_nif_bm25_search`, `collect_postings_into_map`, `sorted_map_tx_rank`, `evict_source_map_indexes`, and `odin_nif_history_of`.
  - Added concurrent 16-level deep-nesting regression tests in `test/xitdb/nif_safety_test.exs` covering `Xitdb.diff_moments/3`, `Xitdb.materialize/2`, `Xitdb.pull/2`, `Xitdb.sync/1`, and `Xitdb.compact/2` under default BEAM dirty-scheduler stack sizes.

## [2.2.0] - 2026-11-20

### Added
- **Read-Only Mode, Transaction Metadata & Scoped Attribution (`Xitdb`, `Xitdb.Ash.Mutator`):**
  - Added `read_only: true` support to `Xitdb.open/1`, `Xitdb.tx_meta/2` / `Xitdb.tx_meta!/2` for inspecting commit metadata, and `Xitdb.with_tx_context/2` / `Xitdb.current_tx_context/0` for process-scoped `__tx` attribution (`doc`, `tx_instant`, `actor_id`, `source_system`, and custom metadata).
- **Query & Transaction Telemetry (`Xitdb.Ash.Query`, `Xitdb.Ash.DataLayer`):**
  - Added `Xitdb.Ash.Query.execute_with_stats/3` emitting query narrowing telemetry (`narrowing_strategy`, `candidate_count`, and `result_count`) alongside transaction attribution telemetry.
- **Storage Modeling & Bulk Batching Guidance (`usage-rules.md`):**
  - Documented HAMT storage amplification vs. packed leaf blobs and `Xitdb.Columnar`, consistent collection tag modifiers across writers, off-lock encoding/serialization, and coarse bulk batching.

### Changed
- **Bulk Ash Indexer/Mutator Optimizations & Lease Overrides (`Xitdb.Ash.*`):**
  - Optimized bulk indexing and mutation pipelines across `Xitdb.Ash.Indexer`, `Xitdb.Ash.Mutator`, and `Xitdb.Ash.Search`.
  - Propagated per-transaction `:lease_timeout` overrides across `Xitdb.Ash.Store` and `Xitdb.Ash.TestSandbox`, and added support for in-place `Ash.create` projections (`mdm_materializer` / `allow_existing_cursor?`).
- **Updated Mix Dependencies:**
  - Updated dependencies to latest Hex releases (`ash` `3.37.7`, `spark` `2.7.10`, `telemetry` `1.4.3`, `plug` `1.20.4`, `reactor` `1.0.8`, `ex_doc` `0.40.5`, `ex_fuzz` `0.1.1`).

### Fixed
- **Ash `3.37.5+` Expression Calculation Infinite Recursion (`Xitdb.Ash.Query`, `Xitdb.Ash.DataLayer`, `Xitdb.Ash.Mutator`):**
  - Prevented re-entrant `Ash.load!/3` infinite recursion caused by `Ash.Filter.Runtime.paths_to_load/3` under `ash 3.37.5+` when resources with read preparations (`prepare build(load: [...])`) evaluate dependent expression calculations.
  - Updated `Xitdb.Ash.Query` (`eval_expression_calculation/10`, `external_loads_for_expression/3`, `load_external_deps/7`, `build_isolated_load_query/6`, `maybe_load_calc_deps/7`), `Xitdb.Ash.DataLayer.calculate/3`, and `Xitdb.Ash.Mutator` (`eval_boolean_condition/6`, `eval_value_expr/6`) to expand inlineable `Xitdb.Ash.DataLayer` expression calculations against a clean `base_records` snapshot, batch-load external dependencies via an isolated `for_read` + `Ash.Query.unset` query, and evaluate hydrated expressions without `:domain` (passing `unknown_on_unknown_refs?: has_custom_calculate?` so optional `nil` relationships resolve properly).
- **Rollback, Seed & Reindex `__tx` Metadata (`Xitdb.Ash.Store`, `Xitdb.Ash.Mutator`, `Xitdb.Ash.Indexer`, `Xitdb.Ash.Search`):**
  - Recorded `restored_moment`, `rolled_back_from`, `rollback_reason`, fresh `doc` / `tx_instant`, and actor/source metadata in `Store.Backend.reconcile_tip/3` and `ensure_seeded!/1`, defaulted Mutator `actor_id` to `"system"`, and attributed `Indexer` and `Search` reindex commits in `__tx`.

## [2.1.0] - 2026-11-19

### Added
- **Transparent Value Compression & Content-Addressed Interning (`Xitdb.Compression`):**
  - Added transparent `format_tag` codecs (`"cz"` zlib deflate, `"zs"` zstd, `"zd"` dictionary-assisted via `__dicts`, and `"bp"` content-addressed `__blobs` deduplication) with automatic shrink guards and `max_decompressed_bytes` enforcement across `materialize/2`, `select/3`, `pull/3`, `diff_moments/4`, `history_of/3`, and cooperative Datalog batch decoding (`nif_query_datalog/6`).
  - Added `Xitdb.Compression.Dictionary` (`train_dictionary/2`, `put/4`, `get/2`, `train_and_put/4`) and supervised `Xitdb.CacheOwner` (`Xitdb.Application`) owning `:xitdb_page_cache` and `:xitdb_dict_cache` ETS tables.
- **Parquet-Style Columnar Row-Group Pages (`Xitdb.Columnar`, `Xitdb.Columnar.Page`):**
  - Added `"XCP1"` row-group column pages (`:plain_block`, `:dict_rle`, `:dict_block`), compact `"pg"` pointers, `O(1)` row slicing, zero-page-read metadata projections, and bounded LRU `:xitdb_page_cache` caching.
  - Added Ash `compress` Spark DSL support (`Xitdb.Ash.Dsl`, `Xitdb.Ash.Compress`, `Xitdb.Ash.Mutator`, `Xitdb.Ash.Query`) with pre-compression BM25 tokenization and selective hydration.
- **Online GC Compaction (`Xitdb.compact/2`, `Core_Overlay`):**
  - Added zero-copy `Core_Overlay` GC compaction pruning unreachable `__blobs`, `__dicts`, and `__col_pages` entries on `Xitdb.compact/2` while keeping source handles intact.
- **Typed Codecs & Ash Domain Types (`Xitdb.Key`, `Xitdb.Encoder`, `FixedDecimal64`, `RangedUnit`):**
  - Added `Xitdb.Key` and `Xitdb.Encoder` protocols, unsigned `u64` support, `Xitdb.Ash.Types.FixedDecimal64`, and `Xitdb.Ash.Types.RangedUnit` with B+Tree interval decomposition.
- **Coverage-Guided Fuzzing & Toolchain Support:**
  - Integrated `ExFuzz` coverage-guided fuzz suites (`test/fuzz/*`) with persisted corpus fixtures (`test/fixtures/fuzz/`).
  - Updated toolchain and CI matrix to Elixir `1.20.5` and Erlang/OTP `29.1.2`.

### Changed
- **Underlying `odin-xitdb` & NIF Traversal:** Synced `native/xitdb-odin` (`bd20160`), deduplicated pre-hashed `history_of` traversal, refreshed 1v1 client benchmarks, and updated `README.md`, HexDocs, and guide indexes.

### Fixed
- **Compression, Columnar & NIF Hardening:**
  - Supervised `:xitdb_page_cache` and `:xitdb_dict_cache` under `Xitdb.CacheOwner` with atomic bounded eviction, copied decoded `Page` subbinaries via `:binary.copy/1`, rejected empty/oversized dictionary names, and dropped stale shared `:dictionary_bytes` on per-column overrides.
  - Separated `prepare_list/6` from `prepare_kv_list/6` so `{:compressed, bin}` 2-tuples in lists, `array_list`, and `linked_list` rewrite cleanly; freed corrupt zlib buffers in `decode_cz_bytes`; replaced `transmute` with `u64` cast in `nif_dl_make_cache_key`; and propagated `:max_decompressed_bytes` plus `history_of(..., raw_tagged: true)`.
- **Ash Query, Mutator & `RangedUnit` Hardening:**
  - Normalized columnar bulk errors into `Ash.Error.Changes.InvalidAttribute`, hydrated `filter`/`sort`/`distinct` calculation dependencies cleanly, initialized synthetic query calculations via `Ash.Query.Calculation.from_resource_calculation/3` and `has_expression?/1`, validated exact `RangedUnit` bounds, and supported partial existing suffix prefixes in `RangedUnit.to_indexed_fields/2,3`.

## [2.0.1] - 2026-11-16

### Changed
- **NIF & Cursor Performance (`native/xitdb_nif.odin`, `Xitdb`, `Xitdb.Cursor`):**
  - Built `MapSet` terms directly inside `native/xitdb_nif.odin` on materialization and skipped the redundant Elixir unwrap pass.
  - Deferred disk cursor resolution (`ov_key` via `NIF.nif_select/3`) in `Xitdb.Cursor.stage_list_edit/3` until materializing a list with staged descendants or fork aliases, avoiding an extra NIF call on standard `insert_at/4` and `delete_at/3` mutations.
- **Underlying `odin-xitdb` `2.0.1`:** Updated `native/xitdb-odin` to `2.0.1` (`e4176e5`), resolving variable shadowing warnings under `odin check -vet` across `cursor.odin`, `lua.odin`, and `types.odin`.

### Fixed
- **NIF Index Merges, Base-Moment Forks, Pull & Datalog (`native/xitdb_nif.odin`):**
  - Ran secondary index removals before insertions during merges, evicted stale indexes on non-nil overwrites/resets, and tolerated `.Key_Not_Found` in `rm_if_exists_callback`.
  - Prioritized `fork_aliases` over `pending_tags`, honored `.None` tombstones, preserved child pending tags across `.Fork`, and recorded `.Hash_Map` for new plain maps in `merge_map`.
  - Hid root `"__tx"` in `slot_get_key` and `bm25_search`, fixed `slot_contains` reader initialization, added adaptive step fallback in `nif_pull_cursor`, and handled unquoted escapes in pull splitters.
  - Preserved float precision in `sum` aggregations, handled exact signed vs. unsigned Datalog integer comparisons, avoided splitting after `@moment` prefixes, propagated `check_only`, and clamped large `u64` counts.
- **Client, Cursor, DSL, Selector & Sets (`Xitdb`, `Xitdb.Cursor`, `Xitdb.DSL`, `Xitdb.Selector`, `Xitdb.TxCompiler`, `Xitdb.Ash.Codec`):**
  - Pinned negative/implicit moments on cursors returned by `select/2` and `pull/2`, and supported standard Elixir lists in `Xitdb.at/1`.
  - Propagated nested/chained `fork_aliases`, applied list edits after fork aliases, materialized parent lists with disk slots when child list edits or forks exist, normalized `fetch_edited_list/2` outputs, and inspected inner `:erl_eval` closures for outer variable capture.
  - Supported 2-arity keyword `do:` options in `tx/2`, `tx!/2`, `query/2`, and `query!/2`, threaded `find_vars`/`binds` across Datalog collection bindings, and added list-step RYOW and `:array_list` `rm_at_steps/2` recursion guards.
  - Raised `ArgumentError` on malformed `Xitdb.Selector` syntax, validated raw set members in `Xitdb.TxCompiler`, and stringified typed `counted_set_fields` in `Xitdb.Ash.Codec`.
- **Ash DataLayer, Mutator, Query, Search & Verifiers (`Xitdb.Ash.*`):**
  - Bounded `Exists`/`Parent` AST scans and substitutions to the current scope, threaded target domains/context/actor across `exists` and aggregates, guarded non-Xitdb or `nil` targets, and used semantic `:min`/`:max` comparators.
  - Passed `%Ash.Query{}` to calculation `load/3`, preserved query context in `Ash.load` and `DataLayer.with_context_db/3`, fell back to `calculate/3` on `nil`/`:unknown` expressions, and avoided boolean coercion in `DataLayer`.
  - Staged `run_bulk_upserts/7` in a single atomic commit with intra-batch target resolution, and honored `touch_update_defaults?: false`.
  - Cleared deleted ancestors on staged `Search` writes, overlaid descendants on staged maps, removed `TestSandbox` TOCTOU lookup, allowed `0 ms` lease timeouts, fell back on `store: nil`, and scanned `base_filter`, `default_sort`, and `:action` preparations in `VerifyNoSqlFragments`.

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
  - **Underlying `odin-xitdb` `2.0.0` (`v2` Wire Format):** Updated `native/xitdb-odin` to `2.0.0` (`2dd638f`, adopting the 8-byte aligned v2 root header while preserving v1 read/write backward compatibility) and updated `rollback_failed_tx` in `native/xitdb_nif.odin` to restore the version-aware `database_file_size_start` 8-byte offset across both v1 and v2 databases.
  - Enforced atomic `file_size`, `core_set_length`, and `core_sync` rollback on mid-payload failures and adaptive retries.

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
