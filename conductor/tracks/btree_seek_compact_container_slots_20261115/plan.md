# Implementation Plan: B+Tree Seek Compact Container Slot Packing & Direct Slot Entry Reads

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `btree_seek_compact_container_slots_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** Flat 3-tuple `{key_bin, tag_id, slot_val}` container packing in `odin_nif_sorted_map_seek`, `Xitdb.Cursor.from_compact_slot/4`, compact 3-tuple unpacking in `Search.Storage` and `Indexer.Storage`, and unit tests are implemented; `odin check` and `mix precommit` pass with zero warnings; and 1v1 benchmark `#25` + slices are updated.

---

## Phase 1: Compact Container Term Packing in `odin_nif_sorted_map_seek` & `Xitdb.Cursor`

- [x] **1.1** Emit flat 3-tuples for container slots in `odin_nif_sorted_map_seek` and add `Xitdb.Cursor` helpers
  - Update `odin_nif_sorted_map_seek` in `native/xitdb_nif.odin` so container value slots (`is_container_tag(val_slot.tag)`) emit `{key_bin, tag_id, slot_val}` and scalar value slots emit `{key_bin, val}`
  - Add `tag_atom_for/1`, `from_compact_slot/4`, and `{tag_id, val}` support in `from_nif_tuple/4` inside `lib/xitdb/cursor.ex`

---

## Phase 2: Direct Slot Reads in `Search.Storage`, `Indexer.Storage`, and Tests

- [x] **2.1** Unpack compact 3-tuples across `Search.Storage` and `Indexer.Storage` and verify behavior
  - Update `Xitdb.Ash.Search.Storage` (`scan_prefix_cursors/4`, `scan_prefix/5`) in `lib/xitdb/ash/search.ex` to handle flat `{term, p_tag_id, p_val}` tuples via `Xitdb.Cursor.from_compact_slot/4` (with `decode_slot_entries!` for the `:elixir` backend)
  - Update `Xitdb.Ash.Indexer.Storage.stream_btree_from_key/2` in `lib/xitdb/ash/indexer.ex` to consume `{hex_key, set_tag_id, set_val}` and wrap lazy set cursors via `Xitdb.Cursor.from_compact_slot/4`
  - Extend `test/xitdb/ash/search_nif_test.exs` to test flat 3-tuple container returns, direct `nif_slot_entries/5` decoding, scalar 2-tuple returns, and `Storage.scan_prefix_cursors/4` + `Storage.scan_prefix/5` compatibility

---

## Phase 3: Verification & 1v1 Benchmark Refresh

- [x] **3.1** Verify compilation, test suite, and benchmark metrics
  - Run `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb` and `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`
  - Run `mix precommit` and confirm zero warnings and 100% passing tests
  - Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh` to refresh `benchmarks/README.md` and `benchmarks/slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md`
