# Implementation Plan: Adaptive Chunk Sizing in `Enumerable` for `Xitdb.Cursor`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `cursor_enumerable_adaptive_chunking_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** Geometric chunk ramp (`16 -> 64 -> 256`) with short-chunk EOF termination (`chunk_len < chunk_size -> next_size = 0`) is active in `Enumerable` for `Xitdb.Cursor`, boundary/suspend/halt tests pass, `mix precommit` passes with 0 warnings, and benchmarks `#9` + `#10` are refreshed.

---

## Phase 1: Implement Geometric Chunk Ramp in `Xitdb.Cursor`

- [x] **1.1** Update `Enumerable` `reduce/3` and `do_reduce` in `lib/xitdb/cursor.ex`
  - Replace single fixed `@chunk_size 256` initial fetch with `@initial_chunk_size 16` and a helper `next_chunk_size/1` (`16 -> 64 -> 256`)
  - Terminate cleanly without a trailing empty `nif_slot_entries` call via short-chunk EOF detection (`chunk_len < chunk_size -> next_size = 0`)
  - Ensure `do_reduce` advances `offset` by the fetched `chunk_len` and preserves `:halt` and `:suspend` continuation behavior across chunk boundaries

---

## Phase 2: Tests & Multi-Boundary Verification

- [x] **2.1** Verify all container types and stream protocols across chunk boundaries
  - Add ATDD scenarios or unit tests covering `Stream.take(10)`, `Enum.find/2`, `Stream.zip/2` (`:suspend`), and exact boundary sizes (`15`, `16`, `17`, `63`, `64`, `65`, `79`, `80`, `81`, `160`, `335`, `336`, `337`, `416`, `500` items) across `Sorted_Map`, `Array_List`, `Linked_Array_List`, `Counted_Hash_Map`, and `Counted_Hash_Set`
  - Run `mix precommit` and verify zero warnings

---

## Phase 3: Benchmark Verification & Slice Refresh

- [x] **3.1** Re-benchmark and update benchmark reports
  - Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`
  - Confirm `#9` drops from `~6.06 µs` (`4.11x`) toward `~2.3 µs` (`~1.5x`) and `#10` shows zero regression in `benchmarks/README.md` and `benchmarks/slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md`
