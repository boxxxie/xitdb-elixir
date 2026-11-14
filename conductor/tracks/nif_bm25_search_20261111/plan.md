# Implementation Plan: Track 9 [Wave 3] — Native Odin NIF BM25 Pushdown, Direct B+Tree Prefix Seek & Wave 3 Track 11B Nesting Integration

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `nif_bm25_search_20261111`
> - **Wave:** `Wave 3 — Deferred Native Search Pushdown & Physical Document Nesting` ([`../../tracks.md`](../../tracks.md))
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Implementation & Track 11B Guide:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Docs-Only Planning Note:** Updating these Conductor files does not mutate repository source files (`lib/`, `native/`, `test/`); implementation executes when running Wave 3.
> - **Wave 3 Complete Scope:** Covers **Track 9** (Phases 1–3 below) **and** **Track 11B** (Phase 4 below, cross-referencing shared `Codec`/`Indexer`, `Store`, `Query`, `Mutator`, and `DataLayer` track artifacts so every Wave 3 deliverable is tracked in one execution plan).

---

## Phase 1: Track 9 — Native B+Tree String Prefix Seek (`nif_sorted_map_seek/5`)

- [x] Task: Extend C-ABI NIF shim in `native/nif_entry.c` (see [`./reference.md#2-c-abi-shim-additions-nativenif_entryc`](./reference.md#2-c-abi-shim-additions-nativenif_entryc))
    - [x] Add `int nif_get_map_value(ErlNifEnv* env, ERL_NIF_TERM map, ERL_NIF_TERM key, ERL_NIF_TERM* val_out)` wrapping `enif_get_map_value`
    - [x] Declare `extern ERL_NIF_TERM odin_nif_sorted_map_seek(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]);`
    - [x] Register `{"nif_sorted_map_seek", 5, odin_nif_sorted_map_seek, ERL_NIF_DIRTY_JOB_CPU_BOUND}` in `nif_funcs[]`
- [x] Task: Implement `odin_nif_sorted_map_seek` (arity 5) in `native/xitdb_nif.odin` (see [`./reference.md#3-odin-nif-implementation-nativexitdb_nifodin`](./reference.md#3-odin-nif-implementation-nativexitdb_nifodin))
    - [x] Initialize scoped per-call `mem.Dynamic_Arena` backed by `runtime.default_allocator()` with `defer mem.dynamic_arena_destroy(&arena)` and bind `context.allocator` / `context.temp_allocator` to `arena_alloc`
    - [x] Decode `[db_ref, slot_tag_id, slot_val_int, prefix_bin, limit_int]` using `enif_inspect_binary` (`get_string_from_binary`) — never `enif_get_string`
    - [x] Acquire `nif_rwlock_rlock(handle.rwlock)` and `defer nif_rwlock_runlock(handle.rwlock)`
    - [x] Seek directly via `xitdb.sorted_map_iterator_from_string(sm_col, prefix)`
    - [x] Stream up to `limit_int` matching entries as `{term_bin, slot_tuple}` (via `slot_to_term`, returning lazy 9-byte `{:cursor, ...}` tuples without materializing posting maps)
    - [x] Inspect one lookahead entry when `emitted == limit_int` to return `{:ok, [{term_bin, slot_tuple}, ...], next_cursor_or_nil}`
- [x] Task: Declare `nif_sorted_map_seek/5` in `lib/xitdb/nif.ex` and wire into `Xitdb.Ash.Search.Storage`
    - [x] Add `Storage.scan_prefix_cursors/5` wrapping each `slot_tuple` into `%Xitdb.Cursor{}` via `Xitdb.Cursor.from_nif_tuple/3`
    - [x] Route `Storage.scan_prefix/5` through `nif_sorted_map_seek/5` when `:auto`/`:nif` is active, retaining the Wave 0 `nif_slot_entries/5` binary-search path when `backend: :elixir` is requested

---

## Phase 2: Track 9 — Native BM25 Query Pushdown Kernel (`nif_bm25_search/7`) & `:backend` Toggle

- [x] Task: Pre-intern BM25 option atoms in `odin_nif_init_atoms` (`native/xitdb_nif.odin`)
    - [x] Intern `ATOM_MATCH`, `ATOM_ALL`, `ATOM_ANY`, `ATOM_PREFIX`, `ATOM_MIN_PREFIX_LENGTH`, `ATOM_MAX_PREFIX_EXPANSIONS`, `ATOM_K1`, `ATOM_B`, `ATOM_EXACT_BOOST`, `ATOM_PREFIX_WEIGHT`
- [x] Task: Implement `odin_nif_bm25_search` (arity 7) in `native/xitdb_nif.odin`
    - [x] Decode `[db_ref, root_tag_id, root_val_int, collection_bin, query_terms, limit_int, opts_map]` (`opts_map` parsed via `nif_get_map_value`)
    - [x] Initialize scoped per-call `mem.Dynamic_Arena` with `defer mem.dynamic_arena_destroy(&arena)` and pass `arena_alloc` explicitly to all `make(map[string]f64, ..., arena_alloc)` and `make([dynamic]..., arena_alloc)` calls
    - [x] Clone `.Short_Bytes` keys onto `arena_alloc` (`read_arena_string`) so 8-byte stack buffers never alias map keys
    - [x] Acquire `nif_rwlock_rlock(handle.rwlock)` with `defer nif_rwlock_runlock(handle.rwlock)` and resolve MVCC snapshot root cursor `(root_tag_id, root_val_int)` (`-1` moment index or concrete `Tag.Hash_Map` slot)
    - [x] Traverse `root["idx"]["search"][collection]`, reading `"meta"` (`"doc_count"`, `"total_len"`), `"docs"` (`doc_key -> %{"len" => scaled_dl}`), and `"terms"` (`:sorted_map` `term -> %{doc_key => scaled_tf}`), supporting both `.Uint` and `.Int` integer slots
    - [x] Guard empty corpora / queries (`doc_count <= 0`, `total_len <= 0`, `query_terms == []`, `limit_int <= 0`) returning `{:ok, []}` immediately
    - [x] Merge exact (`exact_boost`) and bounded prefix (`prefix_weight`, up to `max_prefix_expansions` when `utf8.rune_count_in_string(tok) >= min_prefix_length`) postings per query token, unscaling by `BM25_WEIGHT_SCALE = 100.0`
    - [x] Compute non-negative Robertson–Spärck Jones IDF `ln(1.0 + (N - df + 0.5) / (df + 0.5))` and Robertson length normalization (`avg_dl = max((f64(total_len) / 100.0) / f64(N), 1.0e-6)`, `dl = f64(raw_doc_len) / 100.0`)
    - [x] Select Top-K in `O(C log K)` using `BM25_Hit` binary min-heap + deterministic tie-breaking (**descending `score`**, **ascending `doc_key` raw UTF-8 bytes**) and emit `{:ok, [{doc_key_bin, score_float}, ...]}`
- [x] Task: Export `nif_bm25_search/7` in `native/nif_entry.c` (`ERL_NIF_DIRTY_JOB_CPU_BOUND`) and `lib/xitdb/nif.ex`
- [x] Task: Wire selectable backend (`backend: :auto | :nif | :elixir`) in `lib/xitdb/ash/search.ex` (see [`./reference.md#4-elixir-nif-and-search-integration-libxitdbnifex--libxitdbashsearchex`](./reference.md#4-elixir-nif-and-search-integration-libxitdbnifex--libxitdbashsearchex))
    - [x] Add `:backend` (`:auto | :nif | :elixir`, default `:auto`), `:exact_boost` (default `1.25`), and `:prefix_weight` (default `1.0`) to `@query_schema` for `query/3` and `ids/3`
    - [x] Align Elixir baseline `score_candidates/8` to sort `{doc_key, score}` by `{-score, doc_key}` **before** `decode_doc_key/2` so `:integer` PK tie-breaks match UTF-8 `doc_key` byte order identically

---

## Phase 3: Track 9 — Differential Property Verification, Leak Audit & 1v1 Benchmarks

- [x] Task: Implement `test/xitdb/ash/search_nif_test.exs` (see [`./reference.md#5-differential-property--snapshot-isolation-test-suite-testxitdbashsearch_nif_testexs`](./reference.md#5-differential-property--snapshot-isolation-test-suite-testxitdbashsearch_nif_testexs))
    - [x] Verify `nif_sorted_map_seek/5` returns lazy cursor tuples and accurate `next_cursor_or_nil` continuation binaries
    - [x] Run `StreamData` differential property tests comparing `Xitdb.Ash.Search.query(..., backend: :nif)` and `ids(..., backend: :nif)` against `backend: :elixir` (`< 1.0e-5` score tolerance and exact ID ordering) across `:all`/`:any`, prefix flags/caps, custom `k1`/`b`/boosts, UTF-8 multibyte strings, and `:integer`/UUID tie-breaks
    - [x] Verify MVCC time-travel (`Xitdb.as_of/2`) and concurrent `Xitdb.Ash.TestSandbox` snapshot isolation
- [x] Task: Add `1v1` BM25 search & B+Tree prefix-seek benchmarks in `benchmarks/bench_elixir.exs` and `benchmarks/bench_client.odin`, and run `./benchmarks/compare_1v1.py --runs 5 --warmup 1`
- [x] Task: Verify Odin typecheck (`odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb -vet -strict-style -disallow-do -warnings-as-errors`) and run Valgrind / heap leak verification confirming zero retained TLS or heap blocks across `10,000` `nif_bm25_search/7` invocations

---

## Phase 4: Wave 3 Track 11B — Physical `nested_in` Subtree Storage, Reparenting & Recursive Child Index Purging

> [!NOTE]
> Track 11B shares [`../ash_codec_and_indexer_20261111/`](../ash_codec_and_indexer_20261111/index.md) (and sibling Wave 2 reference files) per [`../../tracks.md`](../../tracks.md). Execute all items below alongside Phases 1–3 to complete Wave 3 (detailed file-by-file walkthrough in [`./reference.md#6-wave-3-track-11b-execution-guide-physical-nested_in-subtree-storage-reparenting--recursive-child-index-purging`](./reference.md#6-wave-3-track-11b-execution-guide-physical-nested_in-subtree-storage-reparenting--recursive-child-index-purging)).

- [ ] Task: Complete `nested_in` physical subtree storage & index cleanup in `lib/xitdb/ash/indexer.ex` ([`../ash_codec_and_indexer_20261111/plan.md`](../ash_codec_and_indexer_20261111/plan.md) Phases 5–7 & [`../ash_codec_and_indexer_20261111/reference.md`](../ash_codec_and_indexer_20261111/reference.md))
    - [ ] Wire `plan_entity_location/5` with `idx.<col>._parent[pk_key] => parent_doc_id` routing and parent-existence validation
    - [ ] Implement `Storage.fetch_nested_cursor/6`, `Storage.list_nested_cursors_for_parent/6`, and `Indexer.nested_cursors_for_parent/4` (`:one` map slot and `:many` sub-map)
    - [ ] Implement foreign-key reparenting cleanup (removing old parent subtree slot and updating `_parent` locator on FK update)
    - [ ] Implement `plan_purge_nested_children_ops/5` recursively purging child `_parent`, identity, secondary, and `Xitdb.Ash.Search` (`remove_record/4`) entries before parent deletion
- [ ] Task: Enable implicit `nested_in` reverse-FK graph synthesis in `lib/xitdb/ash/store.ex` ([`../ash_store_and_test_sandbox_20261111/reference.md`](../ash_store_and_test_sandbox_20261111/reference.md))
    - [ ] Activate `build_nested_fk_rules/4` at `Store` boot to synthesize `on_delete: :delete, nested?: true` rules (unless overridden by explicit `:restrict`)
- [ ] Task: Enable `nested_in` parent-jump planning & cascade hooks in `lib/xitdb/ash/query.ex` and `lib/xitdb/ash/mutator.ex`
    - [ ] Activate Stage 1 `nested_in` parent-FK `O(1)` subtree jump + secondary-index intersection and relationship aggregate fast-path in `lib/xitdb/ash/query.ex` ([`../ash_query_engine_20261111/reference.md`](../ash_query_engine_20261111/reference.md))
    - [ ] Activate `nested?: true` cascade checks via `Indexer.nested_cursors_for_parent/4` in `lib/xitdb/ash/mutator.ex` ([`../ash_mutator_and_cascades_20261111/reference.md`](../ash_mutator_and_cascades_20261111/reference.md))
- [ ] Task: Enable full `nested_in` verification suites and pass precommit gate
    - [ ] Extend `test/xitdb/ash/indexer_test.exs` and `test/xitdb/ash/data_layer_test.exs` ([`../ash_datalayer_and_verification_suite_20261111/references/ash3_contract_fixes_and_verification_suite.md`](../ash_datalayer_and_verification_suite_20261111/references/ash3_contract_fixes_and_verification_suite.md)) for `:many` (`AgendaSession`) and `:one` (`Conference`) nested subtrees, reparenting, and parent-destroy cascades (including nested child BM25 search cleanup)
    - [ ] Run `mix precommit` and verify zero warnings, clean formatting, and 100% green test suite
