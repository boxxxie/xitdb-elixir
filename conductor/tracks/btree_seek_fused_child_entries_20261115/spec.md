# Specification: Optional Fused Child-Container Entry Decoding in `nif_sorted_map_seek`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `btree_seek_fused_child_entries_20261115`
> - **Type:** Chore / Performance Optimization
> - **Target Repository:** `elixir/xitdb`
> - **Submodule Boundary:** `native/xitdb-odin` stays 100% untouched (zero API or wire divergence)
> - **Primary Files:** `native/xitdb_nif.odin`, `native/nif_entry.c`, `lib/xitdb/nif.ex`, `lib/xitdb/ash/indexer.ex`, `lib/xitdb/ash/search.ex`, `benchmarks/bench_elixir.exs`, `test/xitdb/ash/search_nif_test.exs`, `benchmarks/README.md`, `benchmarks/slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md`
> - **Done When:** `nif_sorted_map_seek/7` (`decode_children_bool`) supports an optional fused child-entry decoding mode that expands child container entries (`decode_container_entries_term`) inside the single `enif_rwlock_rlock` scope and returns `{key_bin, entries_list}`, `Search.Storage.scan_prefix/5` (`:auto`/`:nif`) and benchmark `#27` adopt fused mode while `Search.Storage.scan_prefix_cursors/4` and `Indexer.Storage.stream_btree_from_key/2` keep lazy `{key_bin, tag_id, slot_val}` slots (with fused-list fallback in `stream_btree_from_key/2`), `odin check` + `mix precommit` pass with 0 warnings, and benchmark `#27` + slices are updated.

---

## 1. Goal & Motivation

In 1v1 benchmark `#27` (`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`), Elixir takes `15.21 µs` vs. Raw Odin's `8.56 µs` (`1.78x` Raw Odin, `+6.65 µs` gap).

Even after compact 3-tuple slot packing (`btree_seek_compact_container_slots_20261115`), eager callers that immediately decode every visited child container still execute **`1 + N` separate NIF crossings** per B+Tree page:
- `Xitdb.Ash.Search.Storage.scan_prefix/5`: `1` `nif_sorted_map_seek` + up to `limit` (`16`) `nif_slot_entries` crossings.
- Eager B+Tree set-decode scans such as `#27` (`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`): `1` `nif_sorted_map_seek` + `16` follow-up `nif_slot_entries` crossings.

Each extra NIF call re-acquires `enif_rwlock_rlock`, looks up the resource handle, and re-constructs a `Database` reader context. Fusing child-container entry decoding directly inside `odin_nif_sorted_map_seek` (`nif_sorted_map_seek/7` with `decode_children = true`) when requested eliminates all `N` follow-up NIF crossings (`16` in `#27` and `scan_prefix/5`) while preserving non-fused lazy cursors (`decode_children = false`) for `scan_prefix_cursors/4` and range-filtered `Indexer.Storage.stream_btree_from_key/2`.

---

## 2. Architectural Invariants & API Alignment

1. **Zero `odin-xitdb` Divergence:** `native/xitdb-odin/` stays completely untouched.
2. **Standard Public `Xitdb` & `Xitdb.Ash` APIs Unchanged:**
   - `Xitdb.Ash.Search.Storage.scan_prefix_cursors/4` (`#26` BM25 cursor pipeline) continues using non-fused mode (`{key_bin, tag_id, slot_val}` -> `%Xitdb.Cursor{}`).
   - `Xitdb.Ash.Search.Storage.scan_prefix/5` returns `[{String.t(), [{String.t(), float() | pos_integer()}]}]` (`:auto`/`:nif` uses fused `nif_sorted_map_seek/7`, `:elixir` uses `stream_prefix_from/4` over `nif_slot_entries`).
   - `Xitdb.Ash.Indexer.Storage.stream_btree_from_key/2` & `stream_index_from/4` return lazy streams of `{binary(), Enumerable.t()}` keeping `decode_children = false` so out-of-range keys are not eagerly decoded, while accepting fused `{hex_key, ids}` list clauses if present.
3. **Backward-Compatible `nif_sorted_map_seek` Variants:**
   - Preserve existing `/5` and `/6` arities (defaulting `decode_children` to `false`) and add 7-arity `nif_sorted_map_seek/7` (`prefix_only_bool`, `decode_children_bool`).
   - Non-fused mode continues emitting `{key_bin, tag_id, slot_val}` for container values and `{key_bin, scalar}` for scalars.
   - Fused mode emits `{key_bin, entries_list}` when `is_container_tag(val_slot.tag)` is true (and `{key_bin, scalar}` for scalars).

---

## 3. Functional Requirements

- Add fused child-container entry decoding to `odin_nif_sorted_map_seek` in `native/xitdb_nif.odin` (reusing `decode_container_entries_term` inside the active `rlock` scope, respecting `defer free_all(context.temp_allocator)`).
- Register `{"nif_sorted_map_seek", 7, odin_nif_sorted_map_seek, ERL_NIF_DIRTY_JOB_CPU_BOUND}` in `native/nif_entry.c` and stub `nif_sorted_map_seek/7` in `lib/xitdb/nif.ex`.
- Update `Xitdb.Ash.Search.Storage.scan_prefix/5` (`lib/xitdb/ash/search.ex`) to request fused child-entry decoding (`nif_sorted_map_seek(..., true, true)`), keep `Indexer.Storage.stream_btree_from_key/2` (`lib/xitdb/ash/indexer.ex`) non-fused (`false, false`) with a fused-list clause (`when is_list(ids)`), and update `#27` in `benchmarks/bench_elixir.exs` (`nif_sorted_map_seek(..., "k10", 16, false, true)`). Extend `test/xitdb/ash/search_nif_test.exs` to verify both fused and non-fused seek modes (empty child containers, nested maps/sets, scalar fallback, pagination cursor continuity).

---

## 4. Technical Invariants

1. **Submodule Isolation:** `native/xitdb-odin/` stays unmodified.
2. **Odin Temp Allocator Hygiene:** Maintain `defer free_all(context.temp_allocator)` in `odin_nif_sorted_map_seek`.
3. **Zero Warnings:** `odin check` (native + benchmarks) and `mix precommit` must pass with 0 warnings.
4. **Benchmark Validation:** Refresh `#27` via `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`, targeting `#27` improvement from `~15.2 µs` (`1.78x`) toward `~10.0 µs` (`~1.18x` Raw Odin).
