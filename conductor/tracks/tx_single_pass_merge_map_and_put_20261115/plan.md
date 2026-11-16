# Implementation Plan: Single-Pass `:merge_map` & `:put` Validation and Lazy Pure-Removal Detection in `odin_nif_transact`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `tx_single_pass_merge_map_and_put_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** `:merge_map` and structured write ops validate terms inline during the streaming `Nif_Map_Iter` write walk with clean `rollback_failed_tx` recovery on error, `is_pure_removal_term` runs lazily only when `!exists`, `odin check` + `mix precommit` pass with 0 warnings, and `#12`, `#13`, and `#24` benchmarks + slices are updated.

---

## Phase 1: Single-Pass Inline Validation with Transaction Rollback

- [x] **1.1** Fuse validation into `merge_map_callback` and `structured_op_callback` in `native/xitdb_nif.odin`
  - Store validation error details on `Merge_State` (`Merge_Map_Ctx`) / `Structured_Op_Ctx` and abort cleanly so `rollback_failed_tx` restores `core_set_length`, pre-tx `Root_Header` bytes, and `core_sync` (using `validate_write_term_cold` on unexpected write failures).
  - Remove upfront full-tree validation pre-passes from `ATOM_MERGE_MAP`, `ATOM_PUT`, `ATOM_APPEND`, and `ATOM_INSERT`.
- [x] **1.2** Verify atomic rollback semantics on invalid terms
  - Ensure mid-map or multi-op validation failures return the expected `{:error, ...}` reason and leave database state at the prior moment with 0 partial mutations (`test/xitdb/nif_safety_test.exs`).

---

## Phase 2: Lazy Pure-Removal Detection

- [x] **2.1** Guard `is_pure_removal_term` in `merge_kv_entry_hm` and `merge_kv_entry_sm`
  - Check `nif_can_be_pure_removal` in C and check `exists := hm_has_key` / `sm_has_key`; only invoke `is_pure_removal_term` when `!reset && !exists` (parent key does not exist on disk) to avoid materializing no-op removal containers, skipping `is_pure_removal_term` when `exists` is true.
- [x] **2.2** Stream entry inspection without eager `keys`/`vals` slice allocation
  - Iterate map entries directly via `Nif_Map_Iter` (`nif_map_iter_create` / `nif_map_iter_get_and_next` / `nif_map_iter_destroy`) in `merge_map_entries_hm`, `merge_map_entries_sm`, `merge_node_into_cursor`, and `is_pure_removal_term` so nested maps stream without temporary arrays and short-circuit immediately on the first non-`nil` value.

---

## Phase 3: Verification & Benchmark Refresh

- [x] **3.1** Run static checks and full Elixir test suite
  - Run `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb`, `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`, and `mix precommit`.
- [x] **3.2** Re-benchmark `#12`, `#13`, and `#24` and update documentation
  - Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh` and record improvements in `benchmarks/README.md` and slice docs.
