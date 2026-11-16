# Specification: Adaptive Chunk Sizing in `Enumerable` for `Xitdb.Cursor`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `cursor_enumerable_adaptive_chunking_20261115`
> - **Type:** Chore / Performance Optimization
> - **Target Repository:** `elixir/xitdb`
> - **Submodule Boundary:** `native/xitdb-odin` stays 100% untouched (zero API or wire divergence)
> - **Primary Files:** `lib/xitdb/cursor.ex`, `test/features/enumerable_collections_spec.exs`, `test/xitdb/cursor_refactor_test.exs`, `benchmarks/README.md`, `benchmarks/slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md`, `benchmarks/slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md`
> - **Done When:** `Enumerable` for `Xitdb.Cursor` uses a geometric chunk ramp (`16 -> 64 -> 256`) with short-chunk EOF termination so early-halting consumers (`Stream.take(10)`, `Enum.take/2`, `Enum.find/2`, `Enum.any?/2`) avoid allocating 256 BEAM terms on the initial NIF crossing and short collections skip trailing empty NIF calls, multi-chunk boundary tests and `mix precommit` pass with zero warnings, and 1v1 benchmark `#9` + slices are refreshed.

---

## 1. Goal & Motivation

1v1 benchmark `#9` (`Stream: Lazy Stream.take(10) early halt on Sorted_Map`) exhibits the highest read overhead ratio in the 28-benchmark suite: **`4.11x` Raw Odin** (`6.06 µs` Elixir vs. `1.47 µs` Raw Odin).

In `lib/xitdb/cursor.ex`, `Enumerable.Xitdb.Cursor.reduce/3` currently sets a fixed `@chunk_size 256` on the very first `Xitdb.NIF.nif_slot_entries(db_ref, tag_id, val, offset, limit)` call. Consequently:
- Every early-halting operation (`Stream.take(10)`, `Enum.take/2`, `Enum.find/2`, `Enum.any?/2`, `Enum.at/2`) decodes and allocates up to **256 entries** in the NIF and on the BEAM heap on the first call, discarding up to 246 unused tuples/binaries upon `:halt`.
- Replacing the fixed initial chunk size with a geometric ramp (`16 -> 64 -> 256`) cuts first-page allocations by **93.75%** for short reads while short-chunk EOF termination (`chunk_len < chunk_size -> next_size = 0`) eliminates trailing empty `nif_slot_entries` calls and adds at most 2 lightweight NIF crossings (`~0.2 µs` each) on full 500-item collection scans (`#10`).

---

## 2. Architectural Invariants & API Alignment

1. **Zero `odin-xitdb` Divergence:** `native/xitdb-odin/` stays completely untouched.
2. **Public `Enumerable` Protocol Parity:**
   - All container types (`:array_list`, `:linked_array_list`, `:hash_map`, `:counted_hash_map`, `:sorted_map`, `:hash_set`, `:counted_hash_set`, `:sorted_set`) must yield the exact same elements in the exact same order across `{:cont, acc}`, `{:halt, acc}`, and `{:suspend, acc}` reducer commands.
   - `Enumerable.count/1`, `Enumerable.member?/2`, and `Enumerable.slice/1` fast paths remain unchanged.

---

## 3. Functional Requirements

- Update `Enumerable` implementation for `Xitdb.Cursor` in `lib/xitdb/cursor.ex` so `do_reduce` tracks the current `chunk_size` starting at `16`, advancing to `64`, capping at `@chunk_size` (`256`) on subsequent pages, and setting `next_size = 0` on short chunks (`length(raw_chunk) < chunk_size`) so the next exhaustion step returns `{:done, acc}` without a trailing empty NIF call.
- Verify no element gaps, duplicates, or early termination errors across chunk boundaries (`15`, `16`, `17`, `63`, `64`, `65`, `79`, `80`, `81`, `160`, `335`, `336`, `337`, `416`, `500` items) and when wrapped in `Stream.take/2`, `Stream.zip/2` (`{:suspend, acc}`), and `Enum.find/2`.
- Add or extend behavioral specs in `test/features/enumerable_collections_spec.exs` (and/or unit tests in `test/xitdb/cursor_refactor_test.exs`).

---

## 4. Technical Invariants

1. **Submodule Isolation:** `native/xitdb-odin/` stays unmodified.
2. **Zero Warnings & Clean Formatting:** `mix precommit` and `odin check` must pass with 0 warnings.
3. **Benchmark Validation:** Refresh `#9` and `#10` via `./benchmarks/compare_1v1.py --groups enumerable --runs 5 --warmup 1` (plus full run and `./benchmarks/update_readme.sh`), targeting `~2.3 µs` (`~1.5x` Raw Odin) on `#9` with no regression on `#10`.
