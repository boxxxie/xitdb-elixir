# Implementation Plan: Write-Only Virtual Path Staging in `tx_mode` `Access.get_and_update/3`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `tx_mode_virtual_write_cursors_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** Intermediate `tx_mode: true` `get_and_update/3` traversal avoids eager `nif_slot_get_key` / `nif_slot_get_index` NIF reads on `put_in/3` while lazily resolving if read by `update_in/3` or `pop_in/2`, all ATDD/property tests + `mix precommit` pass with 0 warnings, and benchmark `#14` + slices are updated.

---

## Phase 1: Design & Implement Lazy Virtual Write Cursors in `Xitdb.Cursor`

- [x] **1.1** Avoid eager intermediate NIF reads in `tx_mode: true` `Access.get_and_update/3`
  - Inspect how `Kernel.put_in/3`, `Kernel.update_in/3`, `Kernel.get_and_update_in/3`, and `Kernel.pop_in/2` invoke `Xitdb.Cursor.get_and_update/3` and `pop/2` in `lib/xitdb/cursor.ex`
  - Advance a virtual write cursor (`path_steps` accumulated without `nif_slot_get_key`/`nif_slot_get_index`) in `tx_mode: true`, lazily resolving the real slot only when a read operation (`fetch`, `materialize`, `Enum`, scalar read) actually inspects it
  - Ensure `Xitdb.Cursor` staged op emission and `odin_nif_transact` / `adapt_steps_for_base_moment` (`native/xitdb_nif.odin`) compile and apply staged operations identically for virtual and resolved cursors

---

## Phase 2: Edge-Case Verification (`put_in`, `update_in`, `pop_in`, Arrays, Missing Paths)

- [x] **2.1** Verify correctness across all `Access` mutators inside `Xitdb.transact/3`
  - Add tests covering `put_in` on existing nested paths, non-existent nested paths, negative/positive array indices, `update_in` inspecting prior values, `get_and_update_in` returning `{old, new}`, and `pop_in` removing keys
  - Run `mix precommit` and confirm zero warnings and 100% passing tests

---

## Phase 3: Benchmark Verification & Slice Refresh

- [x] **3.1** Re-benchmark `#14` and update reports
  - Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`
  - Confirm `#14` drops from `~12.3 µs` toward `~8.5–9.0 µs` in `benchmarks/README.md` and `benchmarks/slices/14_tx_incremental_put_in_nested_attribute_commit.md`
