---
worktree: 02-compact-cursors-and-btree-seek
branch: perf/02-compact-cursors-and-btree-seek
head_sha: de134a7
slice_base_sha: 66b65f5
upstream_branch: perf/01-cursor-virtual-tx-and-enum
bug_count: 7
severities:
  critical: 1
  high: 3
  medium: 2
  low: 1
---

# Bug Reference — `02-compact-cursors-and-btree-seek` (`perf/02-compact-cursors-and-btree-seek`)

| ID | Severity | Category | Primary Files | Summary |
| :--- | :--- | :--- | :--- | :--- |
| `BUG-02-01` | `critical` | `memory-safety` | `native/xitdb_nif.odin` | `slot.full == true` `.Bytes` slots skip offset/length bounds and `dst == nil` check, causing Odin panic or OOM abort (`SIGABRT`) |
| `BUG-02-02` | `high` | `cursor-semantics` | `native/xitdb_nif.odin`, `lib/xitdb/cursor.ex`, `lib/xitdb/ash/search.ex` | Non-binary map keys bypass `when is_binary(k)` unwrapping, leaking raw `{:cursor, tag_id, slot_val}` tuples |
| `BUG-02-03` | `high` | `error-handling` | `lib/xitdb/ash/search.ex` | `stream_prefix_from/4` crashes with `CaseClauseError` on `nil` or scalar entries in `terms` (`:elixir` / fallback path) |
| `BUG-02-04` | `high` | `error-handling` | `lib/xitdb/ash/search.ex`, `lib/xitdb/ash/indexer.ex` | `scan_prefix/5`, `scan_prefix_cursors/4`, and `stream_btree_from_key/2` swallow `:closed`/corruption errors and crash/mis-scan on non-`Sorted_Map` |
| `BUG-02-05` | `medium` | `scheduler-safety` | `native/nif_entry.c`, `native/xitdb_nif.odin` | `nif_sorted_map_seek/5` and `/6` run on normal schedulers (`flags = 0`) with unbounded `limit_int` and blocking `pread` I/O |
| `BUG-02-06` | `medium` | `cursor-semantics` | `native/xitdb_nif.odin` | `decode_container_entries_term` duplicates chunk-boundary entries on root `Sorted_Map` snapshots containing `"__tx"` |
| `BUG-02-07` | `low` | `error-handling` | `native/xitdb_nif.odin` | `odin_nif_sorted_map_seek` masks invalid offsets when `limit_int <= 0` and rejects `tag_int == -1` root cursors |

---

## Likely Bugs

### `BUG-02-01`: Unvalidated `slot.full == true` `.Bytes` length reads and missing `dst == nil` check crash the BEAM VM
- **Severity:** `critical` | **Confidence:** `high` | **Category:** `memory-safety` | **Scope:** `this-slice`
- **Introduced In:** `fcff070` / `2c18838`
- **Files:** `native/xitdb_nif.odin:348-373`, `native/xitdb_nif.odin:393-396`, `native/xitdb_nif.odin:406-445`, `native/xitdb_nif.odin:7058-7066`
- **Symbols:** `slot_to_term`, `read_key_cursor_string`, `read_arena_string`
- **Verify With:** `mix test test/xitdb/ash/search_nif_test.exs`

**Explanation:** Commit `2c18838` only added `core_length` / `HEADER_LENGTH` / `val_size` validation to the `!slot.full` `.Bytes` path and dropped the `dst == nil` check after `nif_alloc_binary_term` at line 394. Passing a forged or corrupt in-bounds `.Bytes` slot with `full = 1` (`tag_id = 6`) whose 8-byte length prefix has its MSB set or exceeds `128` triggers either a negative slice-bound panic in `cursor_read_bytes_buf` or an unbounded `make([]u8, int(value_size))` OOM abort (`SIGABRT`) inside `cursor_read_bytes_object` / `cursor_read_string`.

**Fix Hint:** Validate `slot.value >= HEADER_LENGTH`, `core_len >= 8`, `slot.value <= core_len - 8`, and `0 <= val_size <= core_len - (slot.value + 8) - (2 if slot.full else 0)` before branching on `slot.full` across `slot_to_term`, `read_key_cursor_string`, and `read_arena_string`, and restore `if dst == nil { return ATOM_NIL, xitdb.Xitdb_Error.Invalid_Offset }` at line 394.

---

### `BUG-02-02`: Non-binary map keys in `decode_container_entries_term` leak raw `{:cursor, tag_id, slot_val}` 3-tuples to Elixir
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `this-slice`
- **Introduced In:** `2c18838` / `de134a7`
- **Files:** `native/xitdb_nif.odin:7314-7340`, `lib/xitdb/cursor.ex:1607-1613`, `lib/xitdb/ash/search.ex:897-901`, `lib/xitdb/ash/indexer.ex:1970-1972`
- **Symbols:** `decode_container_entries_term`, `Enumerable.Xitdb.Cursor.unwrap_entry/4`, `Xitdb.Ash.Search.Storage.unwrap_decoded_entries/3`, `Xitdb.Cursor.unwrap_nif_value/4`
- **Verify With:** `mix test test/xitdb/ash/search_nif_test.exs`

**Explanation:** `decode_container_entries_term` supports non-plain-bytes map keys by emitting `{k_term, val_term}` where `k_term` may be `{:tagged, fmt, val}`, an integer, or a boolean. However, `Enumerable.Xitdb.Cursor.unwrap_entry/4` and `Search.Storage.unwrap_decoded_entries/3` both guard 2-tuple unwrapping with `when is_binary(k)`, causing non-binary keys paired with container values to fall through unchanged and return raw `{k_term, {:cursor, tag_id, slot_val}}` NIF tuples to callers.

**Fix Hint:** Drop `when is_binary(k)` (keeping `k != :__xitdb_set__`) in `unwrap_entry/4` and `unwrap_decoded_entries/3`, and unwrap both `k` and `raw_val` via `Xitdb.Cursor.unwrap_nif_value/4`.

---

### `BUG-02-03`: `Search.Storage.stream_prefix_from/4` crashes with `CaseClauseError` on `nil` or scalar entries in `terms`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `error-handling` | **Scope:** `this-slice`
- **Introduced In:** `de134a7`
- **Files:** `lib/xitdb/ash/search.ex:867-884`, `lib/xitdb/ash/search.ex:750-758`, `lib/xitdb/ash/search.ex:775-779`
- **Symbols:** `Xitdb.Ash.Search.Storage.stream_prefix_from/4`, `Xitdb.Ash.Search.Storage.scan_prefix/5`
- **Verify With:** `mix test test/xitdb/ash/search_nif_test.exs`

**Explanation:** Calling `Search.Storage.scan_prefix(db, col, "alpha_", 10, :elixir)` (or hitting the `:elixir` fallback) on a `terms` `Sorted_Map` containing `nil` or a scalar entry raises `CaseClauseError`. Commit `de134a7` handled scalar/`nil` values in the `:nif` path (`scan_prefix/5` and `scan_prefix_cursors/4`), but left `stream_prefix_from/4` matching only cursor tuples, `%Xitdb.Cursor{}`, and lists.

**Fix Hint:** Add a catch-all `_other -> []` (or `materialize_postings_list(other)`) clause to the `case ids` block inside `stream_prefix_from/4`.

---

### `BUG-02-04`: `Search.Storage` and `Indexer.Storage` swallow `:closed` / B+Tree corruption errors and mis-scan or crash on non-`Sorted_Map` `terms`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `error-handling` | **Scope:** `this-slice`
- **Introduced In:** `fcff070` / `de134a7`
- **Files:** `lib/xitdb/ash/search.ex:717-738`, `lib/xitdb/ash/search.ex:765-780`, `lib/xitdb/ash/search.ex:816-866`, `lib/xitdb/ash/indexer.ex:1951-1968`
- **Symbols:** `Xitdb.Ash.Search.Storage.scan_prefix/5`, `Xitdb.Ash.Search.Storage.scan_prefix_cursors/4`, `Xitdb.Ash.Search.Storage.scan_prefix_via_slot_entries_cursor/3`, `Xitdb.Ash.Search.Storage.find_prefix_start_index/4`, `Xitdb.Ash.Search.Storage.stream_prefix_from/4`, `Xitdb.Ash.Indexer.Storage.stream_btree_from_key/2`
- **Verify With:** `mix test test/xitdb/ash/search_nif_test.exs`

**Explanation:** Closing `db` or corrupting a `BTree_Header` causes `Search.Storage.scan_prefix/5`, `scan_prefix_cursors/4`, and `Indexer.Storage.stream_btree_from_key/2` to silently return `[]` or `{[], nil}` because wildcard `_ ->` clauses swallow `{:error, :closed}` and NIF corruption errors (even when `de134a7` added `raise Xitdb.Error` in `decode_slot_entries!/4`). Furthermore, if `idx.search.<col>.terms` is an `Array_List` or `Counted_Hash_Map`, `scan_prefix/5` catches `{:error, :unsupported}` from `nif_sorted_map_seek/7` and either crashes with `FunctionClauseError` in `Stream.take_while(fn {term, _} -> ... end)` or binary-searches unsorted hash buckets.

**Fix Hint:** Raise `Xitdb.Error, reason: reason` on `{:error, reason}` in `scan_prefix/5` (when `terms.tag == :sorted_map` or on `:closed`/corruption errors), `scan_prefix_cursors/4`, `scan_prefix_via_slot_entries_cursor/3`, `find_prefix_start_index/4`, `stream_prefix_from/4`, and `Indexer.Storage.stream_btree_from_key/2`; do not invoke binary search when `terms.tag != :sorted_map`.

---

### `BUG-02-05`: `nif_sorted_map_seek/5` and `/6` run on normal BEAM schedulers with unbounded `limit_int` and blocking `pread` I/O
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `scheduler-safety` | **Scope:** `this-slice`
- **Introduced In:** `fcff070` / `2c18838`
- **Files:** `native/nif_entry.c:302-304`, `native/xitdb_nif.odin:7376-7540`, `lib/xitdb/ash/search.ex:717`
- **Symbols:** `nif_funcs`, `odin_nif_sorted_map_seek`, `Xitdb.Ash.Search.Storage.scan_prefix_cursors/4`
- **Verify With:** `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb && mix test test/xitdb/ash/search_nif_test.exs`

**Explanation:** Commit `2c18838` moved 7-arity `nif_sorted_map_seek/7` back to `ERL_NIF_DIRTY_JOB_CPU_BOUND`, but left 5-arity and 6-arity `nif_sorted_map_seek` at `flags = 0` on normal BEAM schedulers. Scanning a large or `:file`/`:buffered_file`-backed `Sorted_Map` with a large `limit_int` runs blocking OS `pread` syscalls and allocates unbounded Erlang binaries and 3-tuples directly on normal scheduler threads, risking >1 ms scheduler stalls.

**Fix Hint:** Restore `ERL_NIF_DIRTY_JOB_CPU_BOUND` on `nif_sorted_map_seek/5` and `/6` (or dynamically reschedule via `enif_schedule_nif` whenever the backend is file-backed or `limit_int > 64`).

---

### `BUG-02-06`: `decode_container_entries_term` duplicates chunk-boundary entries on root `Sorted_Map` snapshots containing `"__tx"`
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `this-slice`
- **Introduced In:** `2c18838`
- **Files:** `native/xitdb_nif.odin:7280-7282`, `native/xitdb_nif.odin:7320-7322`, `native/xitdb_nif.odin:1462-1470`
- **Symbols:** `decode_container_entries_term`, `odin_nif_slot_entries`
- **Verify With:** `mix test test/xitdb/ash/search_nif_test.exs test/features/enumerable_collections_spec.exs`

**Explanation:** When enumerating a root `Sorted_Map` snapshot with >16 user keys and `"__tx"` metadata (`tx_meta`), chunk 0 skips `"__tx"` at raw B+Tree rank 0 and emits 16 user entries (`k01..k16`), after which chunk 1 calls `odin_nif_slot_entries(..., offset = 16)`. `decode_container_entries_term` calls `cursor_iterator_sorted_from_index(cur, 16)` without accounting for the skipped `"__tx"` entry, landing back on `"k16"` and emitting `"k16"` twice.

**Fix Hint:** When `skip_tx && slot.tag == .Sorted_Map && offset > 0`, probe `"__tx"` rank via `cursor_iterator_sorted_from_key(cur, "__tx")` and seek to `offset + 1` whenever `"__tx"` exists at rank `<= offset`.

---

### `BUG-02-07`: `odin_nif_sorted_map_seek` masks invalid offsets when `limit_int <= 0` and rejects `tag_int == -1` root cursors
- **Severity:** `low` | **Confidence:** `high` | **Category:** `error-handling` | **Scope:** `this-slice`
- **Introduced In:** `fcff070`
- **Files:** `native/xitdb_nif.odin:7422-7450`
- **Symbols:** `odin_nif_sorted_map_seek`, `resolve_slot_arg`
- **Verify With:** `mix test test/xitdb/ash/search_nif_test.exs`

**Explanation:** Calling `nif_sorted_map_seek(db.db_ref, 14, 5, "a", 0, true, true)` returns `{:ok, [], nil}` instead of `{:error, :invalid_slot}` because `odin_nif_sorted_map_seek` returns early on `limit_int <= 0` before calling `resolve_slot_arg`. Additionally, line 7422 rejects `tag_int < 0`, preventing unresolved `as_of` root cursors (`tag_id: -1`) pointing at a root `Sorted_Map` from being queried.

**Fix Hint:** Call `resolve_slot_arg(handle, tag_int, val_int)` after acquiring the read lock before checking `limit_int <= 0` or `.None`, and skip `"__tx"` if `is_root` is true.

---

## Upstream Stack & Rebase Notes

- Worktree `02-compact-cursors-and-btree-seek` branched off `66b65f5` (the initial Slice 01 commit) and does **not** yet include Slice 01's subsequent fix commits (`ed475ed` and `43a62d0`, or fixes for `BUG-01-01`..`BUG-01-10`).
- Do **not** re-patch Slice 01 `cursor.ex` / intra-tx NIF bugs inside this worktree; resolve `BUG-01-*` in `perf/01-cursor-virtual-tx-and-enum` first and then `git rebase perf/01-cursor-virtual-tx-and-enum`.
- When integrating Slice 02 with Slice 01, note that `Enumerable.Xitdb.Cursor.do_reduce/6` (`BUG-01-05`) directly affects lazy `%Xitdb.Cursor{}` posting sets returned by `Indexer.Storage.stream_btree_from_key/2`.
