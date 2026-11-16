# Specification: Universal Compact 3-Tuple `{:cursor, tag_id, slot_val}` in `slot_to_term`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `compact_cursor_slot_tuples_20261115`
> - **Type:** Chore / Performance Optimization
> - **Target Repository:** `elixir/xitdb`
> - **Submodule Boundary:** `native/xitdb-odin` stays 100% untouched (zero API or wire divergence)
> - **Primary Files:** `native/xitdb_nif.odin`, `lib/xitdb/cursor.ex`, `lib/xitdb.ex`, `test/xitdb/cursor_refactor_test.exs`, `test/xitdb/ash/search_nif_test.exs`, `test/features/lazy_access_navigation_spec.exs`, `benchmarks/README.md`, `benchmarks/slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md`, `benchmarks/slices/17_time_travel_historical_as_of_db_m_across_100_moments.md`
> - **Done When:** `slot_to_term` and `odin_nif_moment_slot` emit compact 3-tuples `{:cursor, tag_id, slot_val}` (`4` BEAM heap words instead of `6`) for container tags, `Xitdb.Cursor` and `Xitdb` unpack the 3-tuple format via `Cursor.tag_atom_for/1`, `odin check` + `mix precommit` pass with zero warnings, and benchmarks (`#1`, `#9`, `#17`, etc.) are refreshed.

---

## 1. Goal & Motivation

While `odin_nif_sorted_map_seek` now emits flat 3-tuples for container slots (`btree_seek_compact_container_slots_20261115`), every general-purpose slot-returning NIF (`nif_slot_get_key`, `nif_slot_get_index`, `nif_moment_slot`, `nif_slot_entries`, and container-returning `nif_select`) goes through `slot_to_term` / `odin_nif_moment_slot` in `native/xitdb_nif.odin` and still builds a 5-tuple `{:cursor, tag_atom, tag_id, slot_val, full_int}` (**6 BEAM heap words**).

For every container tag (`is_container_tag(slot.tag)`):
1. `slot.full` is **always `0`** (only `.Bytes` / `.Short_Bytes` ever set `full`).
2. `tag_atom` is a pure deterministic lookup from `tag_id` (already available in `Xitdb.Cursor.tag_atom_for/1`).

Returning `{:cursor, tag_id, slot_val}` (**4 BEAM heap words**, **-33% tuple words**) cuts NIF young-generation heap allocation and tuple construction work across every multi-hop cursor traversal (`#1` `3.55x`, `#17` `3.77x`) and every container-valued `nif_slot_entries` call (`#9`).

---

## 2. Architectural Invariants & API Alignment

1. **Zero `odin-xitdb` Divergence:** `native/xitdb-odin/` stays completely untouched.
2. **Public `Xitdb` & `Xitdb.Cursor` APIs Unchanged:**
   - All public functions return `%Xitdb.Cursor{tag: atom, tag_id: integer, value: integer, full: boolean, ...}` with identical struct fields and values (`full: false` for containers).
3. **Internal NIF Wire Compatibility:**
   - Audit every match site on `{:cursor, ...}` across `lib/` and `test/` (including `from_nif_tuple/4`, `unwrap_nif_value/4`, `try_resolve/1`, `as_of/2`, and any tests asserting on raw NIF returns).

---

## 3. Functional Requirements

- Update `slot_to_term` and `odin_nif_moment_slot` in `native/xitdb_nif.odin` to emit `{:cursor, tag_id, slot_val}` (`tag_id` + 64-bit `slot_val`) for container slots.
- Update `Xitdb.Cursor` (`lib/xitdb/cursor.ex`), `Xitdb` (`lib/xitdb.ex`), and any internal callers of `nif_moment_slot` / `nif_slot_get_key` / `nif_slot_get_index` / `nif_slot_entries` / `nif_select` to match `{:cursor, tag_id, val}` and resolve `tag: Cursor.tag_atom_for(tag_id)` (keeping `{:cursor, tag_atom, tag_id, val, full}` fallback clause if needed for backward compatibility).
- Update any unit tests matching raw 5-tuple NIF returns to verify the compact 3-tuple format.

---

## 4. Technical Invariants

1. **Submodule Isolation:** `native/xitdb-odin/` stays unmodified.
2. **Odin Temp Allocator Hygiene:** All modified NIF procedures preserve `defer free_all(context.temp_allocator)`.
3. **Zero Warnings:** `odin check` (native + benchmarks) and `mix precommit` must pass with 0 warnings.
4. **Benchmark Validation:** Refresh the 1v1 benchmark suite and confirm read cursor hops (`#1`, `#9`, `#17`) show lower or equal latency with zero regressions.
