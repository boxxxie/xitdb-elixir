# Specification: Single-Pass `:merge_map` & `:put` Validation and Lazy Pure-Removal Detection in `odin_nif_transact`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `tx_single_pass_merge_map_and_put_20261115`
> - **Type:** Chore / Performance Optimization
> - **Target Repository:** `elixir/xitdb`
> - **Submodule Boundary:** `native/xitdb-odin` stays 100% untouched (zero API or wire divergence)
> - **Primary Files:** `native/xitdb_nif.odin`, `native/nif_entry.c`, `test/features/transactions_and_time_travel_spec.exs`, `test/xitdb/cursor_refactor_test.exs`, `test/xitdb/nif_safety_test.exs`, `benchmarks/README.md`, `benchmarks/slices/12_tx_single_nested_entity_transact_commit_6_attributes.md`, `benchmarks/slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md`, `benchmarks/slices/24_storage_buffered_file_transact_sync_50_commits.md`
> - **Done When:** `odin_nif_transact` eliminates upfront `validate_merge_map_term` / `validate_write_term` pre-passes and eager `is_pure_removal_term` traversals by streaming entries via `Nif_Map_Iter` and validating inline during the single transaction write walk (rolling back via `rollback_failed_tx` on invalid input) while skipping `is_pure_removal_term` when keys already exist on disk; `odin check`, `mix precommit`, and invalid-term rollback tests pass with 0 warnings; and benchmarks `#12`, `#13`, and `#24` reflect the speedup.

---

## 1. Goal & Motivation

In `run-1794747522`, removing eager pre-validation from `put_in/3` (`#14`) cut latency by `-34.0%` (`12.76 µs` -> `8.42 µs`). However, map-based transactions (`Xitdb.transact(db, map)` / `:merge_map`, exercising `#12`, `#13`, and `#24`) and structured writes (`:put`, `:append`, `:insert`) still fall into multi-pass traversal overhead in `native/xitdb_nif.odin`:

1. **Pass 1 (upfront term validation):** Recursively extracts every nested map into `keys`/`vals` arrays (heap-allocating slices when `N > 16`, e.g., `N = 100` in `#13`) and decodes every key and scalar leaf before `tx_commit` starts.
2. **Pass 2 (`is_pure_removal_term`):** Inside `merge_kv_entry_hm` / `merge_kv_entry_sm` whenever `!reset`, extracts nested maps into `keys`/`vals` a second time to check whether all leaves are `nil` — even when the parent key already exists on disk (so we must traverse it anyway) or contains non-removal entries.
3. **Pass 3 (`merge_map_entries_hm` / `merge_map_entries_sm`):** Extracts `keys`/`vals` again into temporary slices to perform the actual database writes.

Collapsing these traversals into a single optimistic streaming write pass via `Nif_Map_Iter` with atomic rollback on invalid terms (`rollback_failed_tx`) targets substantial reductions in `#12` (`13.0 µs` vs. `6.05 µs` Odin), `#13` (`427.2 µs` vs. `173.6 µs` Odin), and `#24` (`58.8 µs`).

---

## 2. Architectural Invariants & API Alignment

1. **Zero `odin-xitdb` Divergence:** `native/xitdb-odin/` stays completely untouched.
2. **Atomic Rollback on Invalid Input:** Any validation failure discovered mid-traversal inside `merge_map_callback` (`Merge_State` / `Merge_Map_Ctx`) or `structured_op_callback` (`Structured_Op_Ctx`) records the specific error reason on `validation_err` (with `validate_write_term_cold` on unexpected write failures) and aborts `tx_commit`, whereupon `rollback_failed_tx` restores `core_set_length`, rewrites the pre-transaction `Root_Header` bytes, and calls `core_sync` so zero partial writes remain on disk or in memory.
3. **Exact Nil / Removal Semantics:** Partial or full `nil` deletions inside existing vs. non-existing subtrees preserve 100% identical semantics across `Hash_Map`, `Counted_Hash_Map`, and `Sorted_Map`.

---

## 3. Functional Requirements

- Fuse key and value validation directly into `merge_map_callback` / `merge_node_into_cursor` and `structured_op_callback` (`native/xitdb_nif.odin`), removing upfront validation passes from the fast path while streaming map entries via `Nif_Map_Iter` (`nif_map_iter_create` / `nif_map_iter_get_and_next` / `nif_map_iter_destroy`) without temporary `keys`/`vals` arrays.
- Guard `is_pure_removal_term` lazily inside `merge_kv_entry_hm` / `merge_kv_entry_sm`: first check `nif_can_be_pure_removal != 0` in C and check `exists := hm_has_key` / `sm_has_key`; only when **`!exists`** (parent key does not exist on disk) run `is_pure_removal_term` so pure-removal subtrees are skipped without creating empty containers (`return nil`), and short-circuit immediately on the first non-`nil` leaf using `Nif_Map_Iter`. (When `exists` is true, skip `is_pure_removal_term` and traverse directly into the existing subtree.)
- Ensure invalid Elixir terms (non-string keys, unsupported value types, malformed nested structs) mid-batch still fail cleanly with exact error tuples and leave prior committed state untouched.

---

## 4. Technical Invariants

1. **Odin Memory Hygiene:** `defer free_all(context.temp_allocator)` remains active on all NIF entrypoints.
2. **Zero Warnings & Clean Formatting:** `odin check` and `mix precommit` pass with 0 warnings.
3. **Benchmark Validation:** Refresh `#12`, `#13`, and `#24` via `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`.
