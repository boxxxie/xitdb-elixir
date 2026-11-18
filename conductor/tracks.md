# Project Tracks

This file tracks active development tracks for the `xitdb` Elixir client (`elixir/xitdb`).

All completed tracks from **Waves 0–5** (Tracks 1–17, including split tracks `5A`/`5B` and `11A`/`11B`) have been archived under [`./archive/`](./archive/).

---

- [ ] **Track: Domain Datatypes, Struct Encoding & Order-Preserving Range Keys**
*Link: [./tracks/domain_datatypes_and_range_keys_20261114/](./tracks/domain_datatypes_and_range_keys_20261114/)*

---

- [x] **Track: Adopt `odin-xitdb` Benchmark Suite Architecture**
*Link: [./tracks/benchmark_suite_adoption_20261115/](./tracks/benchmark_suite_adoption_20261115/)*

---

- [x] **Track: Benchmark Follow-Up Optimizations: Dirty-Tree Sample Isolation, Pull Harness Parity & Bulk Tx Prefix Grouping**
*Link: [./tracks/benchmark_followup_optimizations_20261115/](./tracks/benchmark_followup_optimizations_20261115/)*

---

- [ ] **Track: `odin-xitdb` History/Selector Parity, Full Release Pipeline & `elixir/xitdb` Sync**
*Link: [./tracks/odin_xitdb_history_and_release_sync_20261115/](./tracks/odin_xitdb_history_and_release_sync_20261115/)*

---

- [x] **Track: B+Tree Seek Compact Container Slot Packing & Direct Slot Entry Reads**
*Link: [./tracks/btree_seek_compact_container_slots_20261115/](./tracks/btree_seek_compact_container_slots_20261115/)*

---

- [x] **Track: Adaptive Chunk Sizing in `Enumerable` for `Xitdb.Cursor`**
*Link: [./tracks/cursor_enumerable_adaptive_chunking_20261115/](./tracks/cursor_enumerable_adaptive_chunking_20261115/)*

---

- [x] **Track: Optional Fused Child-Container Entry Decoding in `nif_sorted_map_seek`**
*Link: [./tracks/btree_seek_fused_child_entries_20261115/](./tracks/btree_seek_fused_child_entries_20261115/)*

---

- [x] **Track: Fast-Path Decoding for `path_steps/1` and `Xitdb.select/2`**
*Link: [./tracks/path_steps_and_select_fast_path_20261115/](./tracks/path_steps_and_select_fast_path_20261115/)*

---

- [x] **Track: Universal Compact 3-Tuple `{:cursor, tag_id, slot_val}` in `slot_to_term`**
*Link: [./tracks/compact_cursor_slot_tuples_20261115/](./tracks/compact_cursor_slot_tuples_20261115/)*

---

- [x] **Track: Write-Only Virtual Path Staging in `tx_mode` `Access.get_and_update/3`**
*Link: [./tracks/tx_mode_virtual_write_cursors_20261115/](./tracks/tx_mode_virtual_write_cursors_20261115/)*

---

- [x] **Track: Single-Pass `:merge_map` & `:put` Validation and Lazy Pure-Removal Detection in `odin_nif_transact`**
*Link: [./tracks/tx_single_pass_merge_map_and_put_20261115/](./tracks/tx_single_pass_merge_map_and_put_20261115/)*

---

- [x] **Track: Direct `Enumerable.Xitdb.Cursor` Fast-Path Heads & Batch C Step-List Unpacking for `path_steps/1`**
*Link: [./tracks/cursor_member_and_step_list_fast_paths_20261115/](./tracks/cursor_member_and_step_list_fast_paths_20261115/)*

---

- [x] **Track: Automated Host-Load, Canary & Skew Contention Guardrails in `compare_1v1.py`**
*Link: [./tracks/bench_contention_and_canary_guardrails_20261115/](./tracks/bench_contention_and_canary_guardrails_20261115/)*

---

- [x] **Track: Slice 01 Bugfixes: Virtual Tx Cursors, Adaptive Enumerable & Rollback (BUG-01-01..BUG-01-10)**
*Link: [./tracks/slice_01_bugfixes_20261116/](./tracks/slice_01_bugfixes_20261116/)*

---

- [x] **Track: Slice 02 Bugfixes: Compact 3-Tuple Cursors & Fused B+Tree Seek (BUG-02-01..BUG-02-07)**
*Link: [./tracks/slice_02_bugfixes_20261116/](./tracks/slice_02_bugfixes_20261116/)*

---

- [x] **Track: Slice 03 Bugfixes: Batch C path_steps Unpacking & Inline Select (BUG-03-01..BUG-03-07)**
*Link: [./tracks/slice_03_bugfixes_20261116/](./tracks/slice_03_bugfixes_20261116/)*

---

- [x] **Track: Slice 04 Bugfixes: Single-Pass Tx Writers & Atomic Rollback (BUG-04-01..BUG-04-04)**
*Link: [./tracks/slice_04_bugfixes_20261116/](./tracks/slice_04_bugfixes_20261116/)*

---

- [x] **Track: Slice 05 Bugfixes: Benchmarks #27/#28 & Contention Guardrails (BUG-05-01..BUG-05-07)**
*Link: [./tracks/slice_05_bugfixes_20261116/](./tracks/slice_05_bugfixes_20261116/)*

---

- [x] **Track: Slice 06 Bugfixes: Docs & Clean 1v1 Benchmark Baseline (BUG-06-01..BUG-06-07)**
*Link: [./tracks/slice_06_bugfixes_20261116/](./tracks/slice_06_bugfixes_20261116/)*

---

- [x] **Track: Slice 07 Bugfixes: Conductor Track Schema & Spec Alignment (BUG-07-01..BUG-07-08)**
*Link: [./tracks/slice_07_bugfixes_20261116/](./tracks/slice_07_bugfixes_20261116/)*

---

- [ ] **Track: Upgrade Elixir to 1.20.5 and Erlang/OTP to 29.1.2**
*Link: [./tracks/elixir_1_20_upgrade_20261118/](./tracks/elixir_1_20_upgrade_20261118/)*
