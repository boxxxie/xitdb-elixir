# Implementation Plan: Universal Compact 3-Tuple `{:cursor, tag_id, slot_val}` in `slot_to_term`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `compact_cursor_slot_tuples_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** `slot_to_term` and `odin_nif_moment_slot` emit compact 3-tuples `{:cursor, tag_id, slot_val}`, all Elixir unpackers and tests are updated, `odin check` + `mix precommit` pass with 0 warnings, and benchmarks are refreshed.

---

## Phase 1: Audit All `{:cursor, ...}` Match Sites & Update `native/xitdb_nif.odin`

- [x] **1.1** Emit 3-tuple `{:cursor, tag_id, slot_val}` for container slots in NIF
  - Search all occurrences of `:cursor` tuples across `native/`, `lib/`, and `test/`
  - Update `slot_to_term` and `odin_nif_moment_slot` in `native/xitdb_nif.odin` to construct `{:cursor, tag_id, slot_val}` for containers (omitting redundant `tag_atom` and `full_int`)

---

## Phase 2: Update Elixir Unpackers & Test Suite

- [x] **2.1** Handle compact 3-tuple `{:cursor, tag_id, val}` in `Xitdb`, `Xitdb.Cursor`, and Ash internals
  - Update `Xitdb.Cursor.from_nif_tuple/4` and `unwrap_nif_value/4` (`lib/xitdb/cursor.ex`) plus `Xitdb` snapshot/select helpers (`lib/xitdb.ex`) to unpack `{:cursor, tag_id, val}` using `tag_atom_for(tag_id)` and `full: false`
  - Update any unit tests asserting raw NIF tuple shapes and verify `mix precommit` + `odin check` pass with 0 warnings

---

## Phase 3: Benchmark Verification & Slice Refresh

- [x] **3.1** Re-benchmark and update reports
  - Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`
  - Record gains across `#1` (`benchmarks/slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md`), `#17` (`benchmarks/slices/17_time_travel_historical_as_of_db_m_across_100_moments.md`), and related cursor reads
