# Specification: Track 6 — Native Odin NIF BM25 Pushdown & Direct B+Tree Prefix Seek

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `nif_bm25_search_20261111`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Area:** `native/xitdb_nif.odin`, `native/xitdb-odin/xitdb/`, `lib/xitdb/nif.ex`, `lib/xitdb/ash/search.ex`

---

## 1. Goal & Architectural Motivation

While `Xitdb.Ash.Search` provides transactional in-Xitdb BM25 search and prefix matching in pure Elixir by binary-searching `NIF.nif_slot_entries`, large text corpora (100,000+ distinct terms and large candidate posting sets) incur Erlang term copying overhead across the NIF boundary when reading posting maps.

This track pushes prefix seeking and BM25 candidate scoring directly into the native Odin engine (`native/xitdb_nif.odin`), delivering:
1. **Direct B+Tree String Prefix Seek (`nif_sorted_map_seek/4`):**
   Wraps `sorted_map_iterator_from_string` from `native/xitdb-odin/xitdb/dsl.odin`, eliminating the log-V binary search hops over `nif_slot_entries` and directly streaming prefix matches in native memory.
2. **Native Odin BM25 Query Pushdown (`nif_bm25_search/6`):**
   Traverses `idx.search.<collection>`, collects exact and prefix postings directly inside Odin's `context.temp_allocator`, computes Robertson-Spärck Jones IDF and Okapi BM25 scores in native C/Odin memory, and returns only the top-K `{doc_id, score}` tuples to the BEAM scheduler.
3. **1v1 Statistical Benchmark Verification:**
   Compares native Odin BM25 throughput against the Elixir reference implementation using `benchmarks/compare_1v1.py`.

---

## 2. Technical Architecture & Invariants

### 2.1 Direct B+Tree String Prefix Seek

In `native/xitdb_nif.odin`:
```odin
@(export)
odin_nif_sorted_map_seek :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
    context = runtime.default_context()
    defer free_all(context.temp_allocator)

    // argv: [db_handle, tag_id, val_int, prefix_bin, limit_int]
    // Seeks directly using xitdb.sorted_map_iterator_from_string
    // Returns [{term, posting_cursor}]
}
```

### 2.2 Native BM25 Scoring Kernel

In `native/xitdb_nif.odin`:
```odin
@(export)
odin_nif_bm25_search :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
    context = runtime.default_context()
    defer free_all(context.temp_allocator)

    // argv: [db_handle, collection_bin, tokens_list, k1_float, b_float, limit_int]
    // Reads meta (doc_count, total_len), calculates avg_dl
    // For each token: fetches postings, applies exact_match_boost or prefix expansion
    // Calculates BM25 score per candidate in native float64
    // Emits top-K [{doc_id, score}] directly as an Erlang list
}
```

### 2.3 Memory Safety & Hygiene

- **Every NIF procedure** must initialize `context = runtime.default_context()` and `defer free_all(context.temp_allocator)`.
- No lingering pointers or memory leaks across BEAM scheduler invocations.
- Zero NIF string validation failures on valid UTF-8 terms.

---

## 3. Acceptance Criteria

1. `Xitdb.NIF.nif_sorted_map_seek/5` succeeds and returns matched `{term, postings}` tuples starting at `prefix`.
2. `Xitdb.NIF.nif_bm25_search/6` produces scores matching `Xitdb.Ash.Search` within float epsilon (`1.0e-5`).
3. `Xitdb.Ash.Search` transparently delegates to native NIF when available, falling back gracefully to pure Elixir when running in non-NIF sandboxes.
4. `mix precommit` passes with zero compiler warnings and zero memory leaks.
