---
worktree: 01-cursor-virtual-tx-and-enum
branch: perf/01-cursor-virtual-tx-and-enum
head_sha: 43a62d0
slice_base_sha: 8613b81
upstream_branch: master
bug_count: 10
severities:
  critical: 1
  high: 6
  medium: 3
  low: 0
---

# Bug Reference — `01-cursor-virtual-tx-and-enum` (`perf/01-cursor-virtual-tx-and-enum`)

| ID | Severity | Category | Primary Files | Summary |
| :--- | :--- | :--- | :--- | :--- |
| `BUG-01-01` | `critical` | `tx-rollback` | `native/xitdb_nif.odin` | `odin_nif_transact` leaks uncommitted bytes and mutates `Root_Header` after `:savepoint`, `:fork`, or 0-moment tx failure |
| `BUG-01-02` | `high` | `tx-adaptation` | `native/xitdb_nif.odin` | `adapt_steps_for_base_moment` aborts early at depth 0 on new/empty DB paths and misses nested collection / list / set tags |
| `BUG-01-03` | `high` | `cursor-semantics` | `lib/xitdb/cursor.ex` | `classify_access_fun/1` disables virtual cursors for `put_in/2` macros, while fallback triggers `2^(D - 1)` retries and skips list key checks |
| `BUG-01-04` | `high` | `data-corruption` | `lib/xitdb/cursor.ex` | Unguarded `{get_val, %Xitdb.Cursor{}}` match wipes prior `staged_ops` when assigning a snapshot or foreign cursor |
| `BUG-01-05` | `high` | `error-handling` | `lib/xitdb/cursor.ex` | `Enumerable.Xitdb.Cursor` swallows `{:error, :closed}` and storage errors into `0`, `false`, or `[]` |
| `BUG-01-06` | `high` | `cursor-semantics` | `lib/xitdb/cursor.ex` | `apply_staged_overlay/2` ignores staged ancestor replacements and `materialize_staged_val/1` keeps `nil` values in collection maps |
| `BUG-01-07` | `high` | `data-corruption` | `lib/xitdb/cursor.ex` | `Enumerable` `unwrap_entry/4` assigns parent `path_steps` to child cursors, misdirecting writes inside `Enum` loops |
| `BUG-01-08` | `medium` | `cursor-semantics` | `lib/xitdb/cursor.ex`, `lib/xitdb.ex` | `insert_at`/`delete_at`/`fork`/appends desynchronize `staged_overrides`, breaking `[-1]`, `pop_in`, and nested collections |
| `BUG-01-09` | `medium` | `cursor-semantics` | `lib/xitdb.ex`, `lib/xitdb/cursor.ex`, `native/xitdb_nif.odin` | `do_select/3` drops `@moment` and `root: true`; root `"__tx"` leaks in `pull`/`count`/`slice` and duplicates `Sorted_Map` chunk boundaries |
| `BUG-01-10` | `medium` | `tx-indexing` | `native/xitdb_nif.odin` | `rm_if_exists_callback` hardcodes `.Hash_Map_Key` steps for `index_on` eviction, failing on `Counted_Hash_Map` and `Sorted_Map` |

---

## Likely Bugs

### `BUG-01-01`: Missing `Root_Header` and file-length rollback across `tx_commit` failures and `.Unexpected_Tag` retries
- **Severity:** `critical` | **Confidence:** `high` | **Category:** `tx-rollback` | **Scope:** `this-slice`
- **Introduced In:** `66b65f5` / `ed475ed`
- **Files:** `native/xitdb_nif.odin:4311-4314`, `native/xitdb_nif.odin:4360-4364`, `native/xitdb_nif.odin:4402-4408`
- **Symbols:** `odin_nif_transact`, `xitdb.tx_commit`, `xitdb.tx_savepoint`, `xitdb.database_freeze`, `xitdb.database_truncate`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs test/features/transactions_and_time_travel_spec.exs`

**Explanation:** Calling `Xitdb.transact_ops(db, [{:put, ".big", String.duplicate("x", 4096)}, {:savepoint}, {:rm, ".missing"}])` leaves `file_size` grown by over 4 KB after `{:error, _}`, and failing a first tx on an empty 0-moment DB commits an `Array_List` root header. Because `:savepoint` / `:fork` calls `database_freeze` and `tx_commit` writes the empty root header before `_execute_tx_cb`, `database_truncate` only rewinds to `frozen_at` while `odin_nif_transact` neither snapshots nor restores pre-transaction state before retrying or returning an error.

**Fix Hint:** Snapshot `pre_header` (via `database_read_root_header`) and `pre_len` (via `core_length`) before the retry loop, then truncate `core_set_length` back to `pre_header.file_size` (or `pre_len` if `pre_hdr_err != nil`). Restore `Root_Header` bytes directly with `root_header_to_bytes(pre_header)` rather than `database_write_root_header` (which recomputes `file_size` from `core_length`), and call `core_sync` whenever `hdr_changed` is true.

---

### `BUG-01-02`: `adapt_steps_for_base_moment` exits early on new paths / empty DBs and skips deeper nested containers, `Linked_Array_List`, and sets
- **Severity:** `high` | **Confidence:** `high` | **Category:** `tx-adaptation` | **Scope:** `this-slice`
- **Introduced In:** `ed475ed`
- **Files:** `native/xitdb_nif.odin:3871-3992`, `native/xitdb_nif.odin:4020-4108`
- **Symbols:** `adapt_steps_for_base_moment`, `adapt_tx_ops_for_base_moment`, `infer_term_container_tag`, `record_merge_map_replacements`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs`

**Explanation:** Forking or creating a `Sorted_Map` / `Counted_Hash_Map` at a new path or on an empty DB and mutating inside it in the same tx (e.g. `fork(".smap", ".smap_copy") |> put_in(["smap_copy", "b"], 2)` or `put ".smap", counted_map(%{"inner" => sorted_map(...)})` followed by `put ".smap.inner.y", 2`) fails with `"Unexpected_Tag"`. At `i = 0`, `steps[:0]` (`[]`) never matches `replaced`, so missing paths (`!found` or `.None` root) return `false` before `i >= 1` is reached; `found_rep` also exits before adapting deeper steps, `infer_term_container_tag` does not recurse into nested `%Xitdb.Collection{}` terms, and `.Linked_Array_List` / set leaf steps are ignored (`len(steps) == 1` is also skipped).

**Fix Hint:** Track recursive pending container tags by canonical path across nested `%Xitdb.Collection{}` / lists, mark `base_valid = false` instead of returning early when `base_cur` misses, continue checking pending tags for all steps `0 .. len(steps) - 1`, and adapt untyped `.Array_List_Idx` on `.Linked_Array_List` and `.Hash_Map_Key` on set containers.

---

### `BUG-01-03`: `classify_access_fun/1` defeats `put_in/2` macro virtual cursors, while fallback triggers `2^(D - 1)` retries and skips list key validation
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `this-slice`
- **Introduced In:** `66b65f5` / `43a62d0`
- **Files:** `lib/xitdb/cursor.ex:628-646`, `lib/xitdb/cursor.ex:749-813`
- **Symbols:** `Xitdb.Cursor.get_and_update/3`, `classify_access_fun/1`, `invoke_virtual_or_fallback/5`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs test/features/lazy_access_navigation_spec.exs`

**Explanation:** Three defects affect virtual write probing: (1) `put_in(r["users"]["alice"]["score"], i)` compiles into closures belonging to the caller's module rather than `Kernel`, so `classify_access_fun/1` (`:module == Kernel`) returns `:other` and forces synchronous `nif_slot_get` reads on every hop; (2) returning an unmodified child container cursor from `update_in(root, ["a", "b", "c", "d"], fn cur -> cur end)` matches `updated === virtual_child`, causing `invoke_virtual_or_fallback/5` to re-execute the leaf callback `2^(D - 1)` times; (3) `get_and_update_in(root, ["arr", "bad_key"], fun)` on an existing `:array_list` passes `value: -2` (`:hash_map`), gets `{:ok, nil}` from `nif_select`, and stages invalid writes instead of raising `:unexpected_tag`.

**Fix Hint:** Allow macro `put_in/2` / `update_in/2` paths to use virtual probing (handling non-match exceptions cleanly and distinguishing container-vs-step mismatch from missing keys in `fetch_virtual_disk`), and propagate a non-virtual state or disable virtual fallback retries so unmodified real-cursor returns execute the leaf callback `O(1)` times rather than `O(2^D)`.

---

### `BUG-01-04`: Passing a snapshot or foreign `%Xitdb.Cursor{}` as the new value in `Access` drops the write and wipes `staged_ops`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `data-corruption` | **Scope:** `this-slice`
- **Introduced In:** `66b65f5`
- **Files:** `lib/xitdb/cursor.ex:649-652`, `lib/xitdb/cursor.ex:1415-1423`
- **Symbols:** `Xitdb.Cursor.get_and_update/3`, `Xitdb.Cursor.merge_child_staged/2`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs`

**Explanation:** Staging `root = put_in(root["important"], 123)` followed by `put_in(root["copy"], snap_u0)` (where `snap_u0 = Xitdb.db(db)["users"]["u0"]` or an earlier `root["users"]["u0"]` binding) silently leaves both `db["copy"]` and `db["important"]` as `nil`. Line 650 matches `{get_val, %__MODULE__{} = updated_child}` without verifying that `updated_child` came from the recursive traversal at `child_steps`, so `merge_child_staged/2` overwrites `cursor.staged_ops`, `staged_overrides`, and `deleted_paths` with `updated_child`'s stale or empty state.

**Fix Hint:** Guard the `%__MODULE__{}` match in `get_and_update/3` with `when updated_child.tx_mode == true and updated_child.path_steps == child_steps`, and raise an explicit `ArgumentError` (directing callers to `Xitdb.fork/3` or `Xitdb.materialize/1`) when a foreign or snapshot cursor is passed as the replacement value.

---

### `BUG-01-05`: `Enumerable.Xitdb.Cursor` swallows `{:error, :closed}` and storage errors into `0`, `false`, or `[]`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `error-handling` | **Scope:** `this-slice`
- **Introduced In:** `66b65f5`
- **Files:** `lib/xitdb/cursor.ex:1433-1474`, `lib/xitdb/cursor.ex:1493-1496`, `lib/xitdb/cursor.ex:1537-1561`, `lib/xitdb/cursor.ex:1627-1637`, `lib/xitdb/cursor.ex:1656-1689`
- **Symbols:** `Enumerable.Xitdb.Cursor.count/1`, `Enumerable.Xitdb.Cursor.member?/2`, `Enumerable.Xitdb.Cursor.slice/1`, `Enumerable.Xitdb.Cursor.do_reduce/6`, `Inspect.Xitdb.Cursor.inspect/2`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs test/features/enumerable_collections_spec.exs`

**Explanation:** After calling `Xitdb.close(db)` on previously obtained resolved cursors (`items`, `cset`, `cmap`), `Enum.to_list(items)` returns `[]`, `Enum.count(cmap)` returns `0`, `Enum.slice(items, 0..1)` returns `[]`, and `Enum.member?(cset, "x")` returns `false` instead of raising `Xitdb.Error` (`:closed`). Because resolved cursors skip `ensure_resolved/1`, `count/1`, `member?/2`, and `slice/1` fall back on `{:error, :closed}` to `do_reduce/6`, whose `{:error, _} -> {:done, acc}` clause silently finishes with the initial accumulator.

**Fix Hint:** Raise `Xitdb.Error` on `{:error, reason}` in `do_reduce/6` and in `count/1`, `member?/2`, and `slice/1` whenever `reason not in [:uncounted, :unsupported]` (checking handle liveness on non-binary `member?/2` lookups too). When making `Enumerable` raise on `:closed`, also rescue `Xitdb.Error` inside `Inspect.Xitdb.Cursor.inspect/2` so `inspect(Xitdb.db(db))` after `close/1` safely renders `#Xitdb.Cursor<unresolved (:closed)>` instead of crashing.

---

### `BUG-01-06`: `apply_staged_overlay/2` misses staged ancestor replacements and `materialize_staged_val/1` retains `nil` map entries on `%Xitdb.Collection{}`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `this-slice`
- **Introduced In:** `66b65f5`
- **Files:** `lib/xitdb/cursor.ex:1010-1065`, `lib/xitdb/cursor.ex:1570-1586`
- **Symbols:** `Xitdb.Cursor.apply_staged_overlay/2`, `Xitdb.Cursor.materialize_staged_val/1`, `Enumerable.Xitdb.Cursor.reduce/3`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs`

**Explanation:** After `root = put_in(root["users"], %{"alice" => %{"age" => 30}})`, reading `alice = root["users"]["alice"]` succeeds for `alice["age"]`, yet `Xitdb.materialize(alice)` returns `%{}` and `Enum.to_list(alice)` returns `[]`. `apply_staged_overlay/2` only collects `staged_overrides` entries at or beneath `base_sel` (`".users.alice"`), ignoring the staged ancestor map under `".users"`; additionally, `materialize_staged_val/1` omits `Enum.reject(fn {_k, v} -> is_nil(v) end)` for `%Xitdb.Collection{}` map kinds unlike plain maps.

**Fix Hint:** Seed `base` in `apply_staged_overlay/2` by resolving any matching staged ancestor replacement or ancestor deletion along `cursor.path_steps` before merging deeper `matching_overrides` and `matching_deletes`, and reject `nil` values when materializing `%Xitdb.Collection{}` map entries.

---

### `BUG-01-07`: `Enumerable` `unwrap_entry/4` assigns parent `path_steps` to yielded child cursors, corrupting writes through enumerated cursors
- **Severity:** `high` | **Confidence:** `high` | **Category:** `data-corruption` | **Scope:** `this-slice`
- **Introduced In:** `66b65f5`
- **Files:** `lib/xitdb/cursor.ex:1552`, `lib/xitdb/cursor.ex:1608-1616`, `lib/xitdb/cursor.ex:1643-1649`
- **Symbols:** `Enumerable.Xitdb.Cursor.slice/1`, `Enumerable.Xitdb.Cursor.do_reduce/6`, `Enumerable.Xitdb.Cursor.unwrap_entry/4`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs`

**Explanation:** Inside `Xitdb.transact!/2`, binding `[{"alice", alice_cur}] = Enum.to_list(root["users"])` and running `put_in(alice_cur["role"], "admin")` writes to `db["users"]["role"]` instead of `db["users"]["alice"]["role"]` (and similarly corrupts elements from `Enum.slice(root["items"], 0..0)`). Both `do_reduce/6` and `slice/1` forward the parent container's `cursor.path_steps` to `unwrap_entry/4` without prepending `{cursor.tag, key_or_idx}` or inheriting staged overlay state.

**Fix Hint:** Track element indices in `do_reduce/6` and `slice/1`, build `child_steps = [{cursor.tag, key_or_idx} | cursor.path_steps]` when `cursor.tx_mode` is `true` (keeping `[]` otherwise), and pass unwrapped child cursors through `Cursor.inherit_staged(child_cur, parent_cur)` in `tx_mode`.

---

### `BUG-01-08`: Staged list & prefix desynchronization in `tx_mode` (`insert_at`, `delete_at`, `fork`, `pop_in`, negative indices)
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `this-slice`
- **Introduced In:** `66b65f5` / `43a62d0`
- **Files:** `lib/xitdb/cursor.ex:184`, `lib/xitdb/cursor.ex:289-342`, `lib/xitdb/cursor.ex:720-745`, `lib/xitdb/cursor.ex:862-1005`, `lib/xitdb.ex:490-548`
- **Symbols:** `Xitdb.Cursor.fetch/2`, `Xitdb.Cursor.purge_staged_prefix/2`, `Xitdb.Cursor.fork_staged_prefix/3`, `Xitdb.Cursor.staged_or_nif_count/1`, `Xitdb.Cursor.pop/2`, `Xitdb.Cursor.materialize_current_list/2`, `Xitdb.insert_at/4`, `Xitdb.delete_at/3`, `Xitdb.fork/3`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs test/features/transactions_and_time_travel_spec.exs`

**Explanation:** Multiple staged-state mismatches affect intra-tx operations: `staged_or_nif_count/1` ignores `insert_at`, `delete_at`, and staged appends (`put_in(root["arr"][cnt], v)`), causing a subsequent `[-1]` read or `pop_in(root["arr"][-1])` to target the wrong index; `materialize_current_list/2` strips nested `%Xitdb.Collection{}` wrappers into plain maps on `pop_in`; `purge_staged_prefix/2` and `fork_staged_prefix/3` format `#` / `$` instead of canonical `.` keys; `fork/3` copies overrides without tracking base-moment reads for subsequent `update_in` calls on the forked path; and `fetch/2` line 184 passes raw negative `key` instead of `resolved_key` to `nif_slot_get`.

**Fix Hint:** Canonicalize `#`/`$` keys to `.` in prefix helpers, pass `resolved_key` at `fetch/2` line 184, include staged `[idx]` overrides and list insertions/deletions in `staged_or_nif_count/1`, preserve `%Xitdb.Collection{kind: child.tag, data: ...}` inside `materialize_current_list/2`, and track source-subtree aliases on `fork/3`.

---

### `BUG-01-09`: Root `"__tx"` leakage, `@moment` / `root: true` loss in `select/2`, and `Sorted_Map` chunk-boundary duplicates
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `this-slice`
- **Introduced In:** `66b65f5`
- **Files:** `lib/xitdb.ex:627-631`, `lib/xitdb/cursor.ex:1441-1454`, `lib/xitdb/cursor.ex:1535-1557`, `lib/xitdb/cursor.ex:1670`, `native/xitdb_nif.odin:1116-1138`, `native/xitdb_nif.odin:1266-1355`, `native/xitdb_nif.odin:1415-1417`
- **Symbols:** `Xitdb.do_select/3`, `Inspect.Xitdb.Cursor.inspect/2`, `odin_nif_slot_count`, `odin_nif_slot_slice`, `odin_nif_slot_entries`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs test/features/enumerable_collections_spec.exs`

**Explanation:** `Xitdb.do_select/3` discards `@<m>` moment overrides and fails to set `root: true` on root selectors (`""`, `[]`, `"@0"`), leaking `"__tx"` in `materialize`/`Enum`/`pull` and breaking chained `select/2`. Meanwhile, `odin_nif_slot_count`, `odin_nif_slot_slice`, and `odin_nif_slot_entries` miss root `"__tx"` count/index adjustments on root snapshots—causing chunked `Enum.to_list` over a >16-key root `Sorted_Map` to emit entry 16 twice—and `Inspect` queries raw disk counts instead of `Enumerable.count(cursor)` on staged `tx_mode` cursors.

**Fix Hint:** Propagate `effective_moment` and `root: true` on root selectors in `do_select/3` (and pin the resolved `moment` in `as_of(db, -1)` so root cursors do not tear across concurrent commits), offset `Sorted_Map` index seeks past `"__tx"` when `is_root`, adjust root `.Hash_Map` counts/slices for `"__tx"` without blocking explicit `Xitdb.pull(db, "{__tx}")`, and use `Enumerable.count(cursor)` in `Inspect`.

---

### `BUG-01-10`: `rm_if_exists_callback` hardcodes `.Hash_Map_Key` steps during `index_on` eviction, breaking `Counted_Hash_Map` and `Sorted_Map`
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `tx-indexing` | **Scope:** `this-slice`
- **Introduced In:** `ed475ed` (pre-existing in modified NIF path)
- **Files:** `native/xitdb_nif.odin:2861-2888`, `native/xitdb_nif.odin:3485-3495`
- **Symbols:** `rm_if_exists_callback`, `merge_kv_entry_sm`
- **Verify With:** `mix test test/xitdb/cursor_refactor_test.exs`

**Explanation:** Calling `pop_in(root["users"]["u1"]["username"])` (or setting the field to `nil`) when `index_rules: [{:index_on, "users", "username", "username->id"}]` targets a `Counted_Hash_Map` or `Sorted_Map` fails with `%Xitdb.Error{reason: "Unexpected_Tag"}`. `rm_if_exists_callback` builds `[3]Path_Step{hm(...), hm(...), hm(...)}` and calls strict `xitdb.read_steps_cursor` instead of `read_steps_cursor_adaptive`, and `merge_kv_entry_sm` (unlike `merge_kv_entry_hm`) also omits the `depth == 2` non-scalar index eviction check.

**Fix Hint:** Switch `rm_if_exists_callback` to `read_steps_cursor_adaptive(moment_hm.read_hash_map.cursor, lookup[:])`, and mirror `merge_kv_entry_hm`'s `depth == 2` container-overwrite index eviction logic in `merge_kv_entry_sm`.
