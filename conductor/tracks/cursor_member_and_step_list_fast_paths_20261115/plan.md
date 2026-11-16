# Implementation Plan: Direct `Enumerable.Xitdb.Cursor` Fast-Path Heads & Batch C Step-List Unpacking for `path_steps/1`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `cursor_member_and_step_list_fast_paths_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** Resolved `Enumerable.Xitdb.Cursor.member?/2` and `count/1` bypass `ensure_resolved/1`, `nif_unpack_step_list` unpacks step lists in a single C call, `Xitdb.select/2` / `select!/2` / `do_select/3` / `do_select!/3` are inlined, `odin check` + `mix precommit` pass cleanly, and `#6`, `#7`, and `#28` benchmarks + slices are updated.

---

## Phase 1: Direct Function-Head Fast Paths in `Enumerable.Xitdb.Cursor`

- [x] **1.1** Add direct head match for `Enumerable.Xitdb.Cursor.member?/2` in `lib/xitdb/cursor.ex`
  - Match `%Cursor{tx_mode: false, root: false, tag_id: tag_id, db_ref: db_ref, value: val}` with `tag_id in [11, 13, 15]` and `is_binary(candidate)` directly against `NIF.nif_slot_contains/4` (plus a non-binary guard checking `NIF.nif_info/1` before returning `{:ok, false}`).
- [x] **1.2** Add direct head match for `Enumerable.Xitdb.Cursor.count/1` in `lib/xitdb/cursor.ex`
  - Match resolved non-`tx_mode` non-`root` cursors (`tag_id > 0`) directly against `NIF.nif_slot_count/3` without invoking `Cursor.ensure_resolved/1` or allocating intermediate `{nid, nval}` tuples.

---

## Phase 2: Batch C Step-List Unpacking & `select!/2` Inlining

- [x] **2.1** Add `nif_unpack_step_list` C helper in `native/nif_entry.c`
  - Unpack flat proper lists (binaries, integers, and typed 2-tuples such as `{:key, key}` / `{:at_moment, m}`) into a caller-supplied stack buffer in a single C FFI call, returning `-3` on improper lists (`"invalid_selector"`) or falling back cleanly on overflow (`> 16` in `decode_steps_term_buf`, `> 17` in `decode_selector_term_buf`) or unsupported terms.
  - Wire `decode_steps_term_buf` and `decode_selector_term_buf` (`convert_raw_steps_buf`) in `native/xitdb_nif.odin` to use `nif_unpack_step_list` on the fast path while retaining full fallback for complex/long paths.
- [x] **2.2** Inline `Xitdb.select/2`, `Xitdb.select!/2`, `do_select/3`, and `do_select!/3` in `lib/xitdb.ex`
  - Add `@compile {:inline, select: 2, select!: 2, do_select: 3, do_select!: 3}` on hot selector wrappers and bypass `{:ok, ...}` wrap/unwrap churn in `select!/2` via `do_select!/3`.

---

## Phase 3: Verification & Benchmark Refresh

- [x] **3.1** Verify static checks and all tests
  - Run `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb`, `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`, and `mix precommit`.
- [x] **3.2** Re-benchmark `#6`, `#7`, and `#28` and update slices
  - Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh`.
