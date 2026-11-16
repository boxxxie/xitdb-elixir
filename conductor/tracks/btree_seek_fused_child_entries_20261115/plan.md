# Implementation Plan: Optional Fused Child-Container Entry Decoding in `nif_sorted_map_seek`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `btree_seek_fused_child_entries_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** Fused child-container decoding in `odin_nif_sorted_map_seek/7` is wired into `Search.Storage.scan_prefix/5` and benchmark `#27` (while `Indexer.Storage.stream_btree_from_key/2` keeps lazy `decode_children = false` with fused-list handling), unit tests and `odin check` + `mix precommit` pass with 0 warnings, and benchmark `#27` + slices are updated.

---

## Phase 1: Fused Child-Container Decoding in `odin_nif_sorted_map_seek`

- [x] **1.1** Extend `nif_sorted_map_seek` to optionally decode child container entries in-place
  - Add fused decode option in `native/xitdb_nif.odin` (`odin_nif_sorted_map_seek`), `native/nif_entry.c`, and `lib/xitdb/nif.ex` (preserving lazy `{key_bin, tag_id, slot_val}` default mode)
  - When fused mode is active and `is_container_tag(val_slot.tag)`, decode child container entries inside the same `enif_rwlock_rlock` scope and emit `{key_bin, entries_list}`
  - Guard `context.temp_allocator` usage so large B+Tree chunks (e.g. `chunk_size = 64`) do not spike temporary allocations excessively before `free_all`

---

## Phase 2: Adopt Fused Decoding in `Indexer.Storage`, `Search.Storage` & Tests

- [x] **2.1** Adopt fused decoding where eager decode is needed and verify lazy/fused parity
  - Update `Xitdb.Ash.Search.Storage.scan_prefix/5` (`:auto`/`:nif`) in `lib/xitdb/ash/search.ex` to use fused `nif_sorted_map_seek/7` (`true, true`), while keeping `scan_prefix_cursors/4` lazy (`/5`)
  - Keep `Xitdb.Ash.Indexer.Storage.stream_btree_from_key/2` in `lib/xitdb/ash/indexer.ex` using lazy `nif_sorted_map_seek/7` (`false, false`) with an adaptive initial `16` -> `64` page limit so out-of-range keys stay un-decoded, while adding fused-list clause support (`when is_list(ids)`)
  - Extend `test/xitdb/ash/search_nif_test.exs` and `benchmarks/bench_elixir.exs` (`#27` using `false, true`)

---

## Phase 3: Verification & 1v1 Benchmark Refresh

- [x] **3.1** Verify compilation, test suite, and benchmark metrics
  - Run `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb` and `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`
  - Run `mix precommit` and confirm zero warnings and 100% passing tests
  - Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh` to refresh `benchmarks/README.md` and `benchmarks/slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md`
