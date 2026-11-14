# Implementation Plan: Track 6 — Native Odin NIF BM25 Pushdown & Direct B+Tree Prefix Seek

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `nif_bm25_search_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)

---

## Phase 1: Native String Prefix Seek in Odin NIF

- [ ] Task: Implement `odin_nif_sorted_map_seek` in `native/xitdb_nif.odin`
    - [ ] Decode `[handle, tag_id, val_int, prefix_bin, limit_int]`
    - [ ] Wrap `xitdb.sorted_map_iterator_from_string`
    - [ ] Stream up to `limit` entries while `strings.has_prefix(term, prefix)`
    - [ ] Ensure `defer free_all(context.temp_allocator)` is called
- [ ] Task: Export in `native/nif_entry.c` and declare in `lib/xitdb/nif.ex`
- [ ] Task: Wire into `Xitdb.Ash.Search.Storage.scan_prefix/4`

---

## Phase 2: Native BM25 Query Pushdown Kernel

- [ ] Task: Implement `odin_nif_bm25_search` in `native/xitdb_nif.odin`
    - [ ] Resolve `.idx.search.<collection>` root cursor in Odin
    - [ ] Read `meta["doc_count"]` and `meta["total_len"]`
    - [ ] Aggregate postings for all input tokens into native hash map
    - [ ] Compute Robertson-Spärck Jones IDF and BM25 scores with Robertson length normalization
    - [ ] Sort top-K and emit `[{doc_id, score}]` Erlang term list
- [ ] Task: Export in `native/nif_entry.c` and `lib/xitdb/nif.ex`
- [ ] Task: Wire fast-path in `Xitdb.Ash.Search.query/3`

---

## Phase 3: Verification & Statistical Benchmark

- [ ] Task: Write ExUnit test suite comparing native NIF BM25 output against Elixir baseline
- [ ] Task: Add 1v1 search benchmark in `benchmarks/bench_elixir.exs` and `benchmarks/bench_client.odin`
- [ ] Task: Verify clean `mix precommit` and zero memory leaks under valgrind / heap profiling
