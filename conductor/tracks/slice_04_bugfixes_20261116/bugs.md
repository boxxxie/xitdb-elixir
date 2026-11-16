---
worktree: 04-single-pass-tx-and-rollback
branch: perf/04-single-pass-tx-and-rollback
head_sha: 11ff6f3
slice_base_sha: ddffc7a
upstream_branch: perf/03-path-steps-unpack-and-select
bug_count: 4
severities:
  critical: 1
  high: 3
  medium: 0
  low: 0
---

# Bug Reference — `04-single-pass-tx-and-rollback` (`perf/04-single-pass-tx-and-rollback`)

| ID | Severity | Category | Primary Files | Summary |
| :--- | :--- | :--- | :--- | :--- |
| `BUG-04-01` | `critical` | `tx-rollback` | `native/xitdb_nif.odin` | `odin_nif_transact` rollback risks `Root_Header` corruption via `database_write_root_header`, skips `core_sync`, and ignores rollback errors |
| `BUG-04-02` | `high` | `tx-validation` | `native/xitdb_nif.odin` | Off-by-one `MAX_WRITE_DEPTH` (`64`) between single-pass writers (accepting 65-level scalar/nil maps) and `is_pure_removal_term` / `validate_write_term_cold` |
| `BUG-04-03` | `high` | `tx-validation` | `native/xitdb_nif.odin` | Forged `%MapSet{map: ...}` structs bypass `nif_is_map` and `ATOM_STRUCT` checks in set writers and validators |
| `BUG-04-04` | `high` | `memory-safety` | `native/xitdb_nif.odin`, `native/nif_entry.c` | Unchecked `temp_allocator` allocation in `extract_map_kvs` can pass `NULL` buffers into `nif_map_to_kv_arrays` (`SIGSEGV`) |

---

## Likely Bugs

### `BUG-04-01`: Rollback in `odin_nif_transact` can corrupt `Root_Header`, skips `core_sync` after `fsync`ed commits, and ignores rollback errors before retry
- **Severity:** `critical` | **Confidence:** `high` | **Category:** `tx-rollback` | **Scope:** `this-slice`
- **Introduced In:** `bca6525` / `11ff6f3`
- **Files:** `native/xitdb_nif.odin:4416-4447`
- **Symbols:** `odin_nif_transact`, `xitdb.database_write_root_header`, `xitdb.core_set_length`, `xitdb.core_sync`
- **Verify With:** `mix test test/xitdb/nif_safety_test.exs`

**Explanation:** On rollback, `odin_nif_transact` calls `database_write_root_header(&handle.db, pre_header.root)`, which reads live `core_length(db.core)` rather than `pre_header.file_size`—so if `core_set_length` fails (silently swallowed by `os.truncate` in `core.odin`) or is skipped (`len_err != nil`), it stamps an un-truncated `file_size` into `Root_Header` with no valid `Root_Trailer`, permanently failing future opens/reads with `"Invalid_Database"`. It also omits `core_sync` after `fsync`ed `:savepoint` / 0-moment root-init writes (`core_flush` does not `fsync`), rewrites `ROOT_HEADER_START` unnecessarily when `hdr_changed == false`, and ignores rollback errors before retrying on `.Unexpected_Tag`.

**Fix Hint:** Compute `len_changed` against the tx's own growth (`cur_len != pre_len` when `pre_len_err == nil`, or `cur_len != pre_header.file_size` when `hdr_changed`), only rewrite `ROOT_HEADER_START` when `hdr_changed` is true using `xitdb.root_header_to_bytes(pre_header)` directly (never `database_write_root_header`), call `core_sync` when `hdr_changed` is true, and abort retrying if rollback itself fails.

---

### `BUG-04-02`: Off-by-one `MAX_WRITE_DEPTH` (`64`) mismatch between single-pass writers and `is_pure_removal_term` / `validate_write_term_cold`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `tx-validation` | **Scope:** `this-slice`
- **Introduced In:** `11ff6f3`
- **Files:** `native/xitdb_nif.odin:3064-3071`, `native/xitdb_nif.odin:3383-3391`, `native/xitdb_nif.odin:3482-3490`, `native/xitdb_nif.odin:3924-4002`, `native/xitdb_nif.odin:4049-4067`
- **Symbols:** `is_pure_removal_term`, `validate_col_data_cold`, `validate_write_term_cold`, `validate_deferred_tx_ops`
- **Verify With:** `mix test test/xitdb/nif_safety_test.exs`

**Explanation:** Single-pass writers handle scalar and `nil` leaves inline at `depth == 64` (accepting 65-level maps such as `Enum.reduce(1..65, "leaf", ...)`), whereas `is_pure_removal_term` and `validate_write_term_cold` check `depth > MAX_WRITE_DEPTH` before inspecting `ATOM_NIL` or `decode_writeable_value` at `depth = 65`. Consequently, merging a 65-level all-`nil` map succeeds if the top-level key already exists (because `!exists` skips `is_pure_removal_term`) but fails with `:invalid_put_op` when absent, and cold validation misclassifies valid 65-level maps on `[]` or scalar paths as `:invalid_put_op` instead of `"Invalid_Range"` / `"Unexpected_Tag"`.

**Fix Hint:** Check `if term == ATOM_NIL { return true, nil }` before `depth > MAX_WRITE_DEPTH` in `is_pure_removal_term` (and restore `nif_can_be_pure_removal` lookahead after the depth/nil checks), and check `decode_writeable_value` before `depth > MAX_WRITE_DEPTH` in `validate_write_term_cold`—or unify on a single strict container-depth limit across writers and validators.

---

### `BUG-04-03`: Malformed or forged `%MapSet{map: ...}` bypasses `nif_is_map` and `ATOM_STRUCT` guards in set writers and validators
- **Severity:** `high` | **Confidence:** `high` | **Category:** `tx-validation` | **Scope:** `this-slice`
- **Introduced In:** `bca6525` / `11ff6f3`
- **Files:** `native/xitdb_nif.odin:2477-2488`, `native/xitdb_nif.odin:2614-2636`, `native/xitdb_nif.odin:2662-2684`, `native/xitdb_nif.odin:3886-3907`
- **Symbols:** `is_valid_set_container`, `write_hash_set_entries`, `write_sorted_set_entries`, `validate_set_elements_cold`
- **Verify With:** `mix test test/xitdb/nif_safety_test.exs`

**Explanation:** Unlike `is_valid_kv_container`, `is_valid_set_container` extracts `ms_map` from `:map` without checking `nif_is_map(env, ms_map) != 0` or `nif_get_map_value(env, ms_map, ATOM_STRUCT, &inner_st) == 0`. Passing `%{__struct__: MapSet, map: :not_a_map}` initializes/mutates the target cursor before failing, and passing `%{__struct__: MapSet, map: ~D[2026-01-01]}` succeeds and stores `["__struct__", "calendar", "day", "month", "year"]` as set members.

**Fix Hint:** Require `nif_is_map(env, ms_map) != 0 && nif_get_map_value(env, ms_map, ATOM_STRUCT, &inner_st) == 0` in `is_valid_set_container`, `write_hash_set_entries`, `write_sorted_set_entries`, and `validate_set_elements_cold`.

---

### `BUG-04-04`: Unchecked `temp_allocator` allocation in `extract_map_kvs` can pass `NULL` buffers into C `nif_map_to_kv_arrays` (`SIGSEGV`)
- **Severity:** `high` | **Confidence:** `high` | **Category:** `memory-safety` | **Scope:** `this-slice`
- **Introduced In:** `bca6525` / `11ff6f3`
- **Files:** `native/xitdb_nif.odin:3041-3062`, `native/nif_entry.c:178-201`, `native/nif_entry.c:225-259`
- **Symbols:** `extract_map_kvs`, `nif_map_to_kv_arrays`, `nif_extract_map_kvs`
- **Verify With:** `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb && mix test test/xitdb/nif_safety_test.exs`

**Explanation:** On maps with `> 32` keys, `extract_map_kvs` calls `make([]ERL_NIF_TERM, n, context.temp_allocator)` without checking for `Allocator_Error`. If `temp_allocator` returns a `nil`-backed slice under memory pressure, `nif_map_to_kv_arrays` writes `keys_out[0] = k` without checking for `NULL`, segfaulting the BEAM scheduler thread; copying all `2 * n` terms upfront also wastes memory and stack frames (`KV_Stack_Buf`).

**Fix Hint:** Fold WT 05 commit `2883a38`'s streaming `Nif_Map_Iter` loops into Slice 04 to eliminate `extract_map_kvs` and `KV_Stack_Buf` altogether (while keeping `11ff6f3`'s `ATOM_STRUCT` check and `validate_deferred_tx_ops`), and add a defensive `if (max_cnt > 0 && (!keys_out || !vals_out)) return 0;` guard in `nif_map_to_kv_arrays`.

---

## Upstream Stack & Rebase Notes

- Worktree `04-single-pass-tx-and-rollback` branched off `ddffc7a` (initial Slice 03 commit) and does **not** yet include upstream fix commits `ed475ed` / `43a62d0` (Slice 01), `2c18838` / `de134a7` (Slice 02), or `6cef6c6` (Slice 03).
- Do **not** re-patch Slice 01–03 files here; rebase onto `perf/03-path-steps-unpack-and-select` once Slices 01–03 are updated (remembering to preserve `ed475ed`'s `adapt_containers` in `merge_map_callback` / `merge_node_into_cursor`).
- Worktree 05 commit `2883a38` (`fix(tx,nif): guard write depth, stream map writers, and harden rollback`) belongs folded into Slice 04 (`perf/04-single-pass-tx-and-rollback`) alongside `11ff6f3` to resolve the current `KV_Stack_Buf` vs `Nif_Map_Iter` and depth-error divergence.
