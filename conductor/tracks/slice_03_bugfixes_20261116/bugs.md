---
worktree: 03-path-steps-unpack-and-select
branch: perf/03-path-steps-unpack-and-select
head_sha: 6cef6c6
slice_base_sha: fcff070
upstream_branch: perf/02-compact-cursors-and-btree-seek
bug_count: 7
severities:
  critical: 0
  high: 4
  medium: 2
  low: 1
---

# Bug Reference — `03-path-steps-unpack-and-select` (`perf/03-path-steps-unpack-and-select`)

| ID | Severity | Category | Primary Files | Summary |
| :--- | :--- | :--- | :--- | :--- |
| `BUG-03-01` | `high` | `cursor-semantics` | `lib/xitdb.ex` | `Xitdb.do_select/3` and `do_select!/3` drop `@moment` / `{:at_moment, m}` overrides on returned container cursors |
| `BUG-03-02` | `high` | `cursor-semantics` | `lib/xitdb.ex` | Root `select` (`""`, `[]`, `"@0"`, `[{:at_moment, 0}]`) returns `root: false`, leaking `"__tx"` and failing chained `select/2` |
| `BUG-03-03` | `high` | `selector-semantics` | `native/xitdb_nif.odin` | `read_steps_cursor_adaptive` & `adapt_steps_for_base_moment` miss `Linked_Array_List`/sets while weakening explicit `#`/`$` strictness |
| `BUG-03-04` | `high` | `history-query` | `native/xitdb_nif.odin` | `read_prehashed_steps_slot` & `odin_nif_history_of` fail on `Sorted_Map`/`Linked_Array_List`/sets and wipe `doc`/`instant` on `.Unexpected_Tag` |
| `BUG-03-05` | `medium` | `selector-parsing` | `lib/xitdb/selector.ex` | `parse_selector_steps/2` inverts root `#col["k"]`/`$col["k"]` tags, breaks `."k.1"`, and misses cross-quote unescaping |
| `BUG-03-06` | `medium` | `selector-parsing` | `native/xitdb_nif.odin` | `parse_escaped_steps_buf` accepts `@0` as a literal write key and mis-shifts root `$["k1"]["k2"]` |
| `BUG-03-07` | `low` | `dsl-validation` | `lib/xitdb/dsl/path_compiler.ex`, `lib/xitdb/selector.ex` | Invalid static step tuples crash with `FunctionClauseError` and `{:at_moment, m}` is accepted inside non-root brackets |

---

## Likely Bugs

### `BUG-03-01`: `Xitdb.select/2` and `Xitdb.select!/2` drop `@moment` and `{:at_moment, m}` on returned container cursors
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `this-slice`
- **Introduced In:** `ddffc7a`
- **Files:** `lib/xitdb.ex:628-639`, `lib/xitdb.ex:660-671`
- **Symbols:** `Xitdb.do_select/3`, `Xitdb.do_select!/3`, `odin_nif_select`
- **Verify With:** `mix test test/xitdb/dsl/path_compiler_test.exs`

**Explanation:** Calling `c = Xitdb.select!(db, "@0.users")` or `Xitdb.select!(db, [{:at_moment, 0}, "users"])` returns `%Xitdb.Cursor{moment: -1}` (or leaves `moment: 1` when called on `Xitdb.as_of(db, 1)`), causing subsequent `Xitdb.query!(c, ...)` or `Xitdb.pull!(c, ...)` calls to inspect the wrong historical moment. `odin_nif_select` resolves `effective_moment` internally without returning it, while `do_select/3` and `do_select!/3` forward the caller's original `moment` argument to `Cursor.unwrap_nif_value/4`.

**Fix Hint:** Add a shared `wrap_selected/4` helper in `lib/xitdb.ex` that computes `effective_moment(moment, selector)` from `[{:at_moment, m} | _]` or trimmed `"@<int>..."` prefixes (be sure to `String.trim_leading/1` before matching `"@"` to match Odin's `parse_escaped_selector_buf`).

---

### `BUG-03-02`: Root `select/2` and `select!/2` return `%Xitdb.Cursor{root: false}`, leaking `"__tx"` and breaking chained `select/2`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cursor-semantics` | **Scope:** `this-slice`
- **Introduced In:** `ddffc7a`
- **Files:** `lib/xitdb.ex:633-634`, `lib/xitdb.ex:665-666`
- **Symbols:** `Xitdb.do_select/3`, `Xitdb.do_select!/3`
- **Verify With:** `mix test test/xitdb/dsl/path_compiler_test.exs`

**Explanation:** Selecting a root path (`""`, `[]`, `"@0"`, `[{:at_moment, 0}]`, `" @0 "`) returns a `%Xitdb.Cursor{root: false}` struct. Because `"__tx"` exclusion in `Xitdb.materialize/1`, `Enumerable`, `pull/2`, and the root-cursor guard in `Xitdb.select/2` all depend on `root: true`, `Xitdb.materialize(r_cur)` and `Xitdb.pull!(r_cur, "*")` leak `"__tx"` and `Xitdb.select(r_cur, ".k")` fails with `:non_root_cursor`.

**Fix Hint:** In `wrap_selected/4`, set `%Cursor{cursor | root: true}` whenever `selector` contains zero path steps (`[]`, `[{:at_moment, _}]`, `""`, whitespace-only binary, or trimmed `"@<int>"` with an empty tail).

---

### `BUG-03-03`: `read_steps_cursor_adaptive` and `adapt_steps_for_base_moment` break `path_steps/1` on `Linked_Array_List`/sets and loosen explicit `#`/`$` strictness
- **Severity:** `high` | **Confidence:** `high` | **Category:** `selector-semantics` | **Scope:** `this-slice`
- **Introduced In:** `ddffc7a`
- **Files:** `native/xitdb_nif.odin:3901-3974`, `native/xitdb_nif.odin:4393-4405`
- **Symbols:** `read_steps_cursor_adaptive`, `adapt_steps_for_base_moment`, `odin_nif_select`
- **Verify With:** `mix test test/xitdb/dsl/path_compiler_test.exs`

**Explanation:** Running `Xitdb.select!(db, path_steps(linked[1]))` or `Xitdb.select!(db, path_steps(roles["admin"]))` returns `nil` (and `{:put, path_steps(linked[1]), "v"}` fails with `"Unexpected_Tag"`) because `path_steps/1` emits generic `.Array_List_Idx` / `.Hash_Map_Key` steps that `read_steps_cursor_adaptive` and `adapt_steps_for_base_moment` never adapt for `.Linked_Array_List` or set containers (and `adapt_steps_for_base_moment` exits early on `len(steps) < 2`). Conversely, line 3910 matches explicit `.Counted_Hash_Map_Key` and `.Sorted_Map_Key` across mismatched map kinds, allowing `select(db, [{:counted_map, "hmap"}, "k"])` to succeed on a plain `Hash_Map`.

**Fix Hint:** Adapt **only untyped** `.Hash_Map_Key` across maps/sets and **only untyped** `.Array_List_Idx` across `.Array_List`/`.Linked_Array_List`, enforce exact container tags on explicit `#`/`$`/`[[i]]`/set steps, and change `len(steps) < 2` to `len(steps) == 0`.

---

### `BUG-03-04`: `Xitdb.history_of/2` fails on `Sorted_Map`, `Linked_Array_List`, and sets with `path_steps/1` and wipes `doc`/`instant` on `.Unexpected_Tag`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `history-query` | **Scope:** `this-slice`
- **Introduced In:** `ddffc7a` (pre-existing step-list path in touched NIF)
- **Files:** `native/xitdb_nif.odin:5035-5094`, `native/xitdb_nif.odin:5176-5197`
- **Symbols:** `read_prehashed_steps_slot`, `odin_nif_history_of`
- **Verify With:** `mix test test/xitdb/dsl/path_compiler_test.exs test/features/transactions_and_time_travel_spec.exs`

**Explanation:** Calling `Xitdb.history_of(db, path_steps(smap["k1"].field))`, `path_steps(linked[1])`, or `path_steps(cset["admin"])` returns `{:ok, []}` because `read_prehashed_steps_slot` reads `cur.slot_ptr.slot.tag` without `cursor_resolved(cur)`, skips `.Sorted_Map`/`.Linked_Array_List`/sets, and calls `read_counted_hash_map_init` on `.Counted_Hash_Set`. Moreover, when a value changes from a container to a scalar in moment `m1`, `odin_nif_history_of` catches `.Unexpected_Tag` and emits `doc: "", instant: 0` instead of reading `m1`'s `__tx` metadata.

**Fix Hint:** Resolve `sp := xitdb.cursor_resolved(cur) or_return` in `read_prehashed_steps_slot`, dispatch untyped `.Hash_Map_Key` and `.Array_List_Idx` steps across all matching map/list/set `read_*_init` procs, and on `s_err == .Unexpected_Tag` in `odin_nif_history_of` reset `cur_slot = xitdb.Slot{}` and fall through to read `__tx.doc` / `__tx.tx_instant`.

---

### `BUG-03-05`: `Xitdb.Selector.parse_selector_steps/2` inverts root `#col["k"]`/`$col["k"]` tags, breaks `."k.1"`, and lacks cross-quote unescaping
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `selector-parsing` | **Scope:** `this-slice`
- **Introduced In:** `ddffc7a` (`selector.ex` integration via `PathCompiler`)
- **Files:** `lib/xitdb/selector.ex:253-308`, `lib/xitdb/selector.ex:333-373`, `lib/xitdb/dsl/path_compiler.ex:136-235`
- **Symbols:** `Xitdb.Selector.parse_selector_steps/2`, `do_parse_steps/2`, `parse_key_token/1`, `parse_quoted_string/2`, `parse_single_quoted_string/2`
- **Verify With:** `mix test test/xitdb/selector_test.exs test/xitdb/dsl/path_compiler_test.exs`

**Explanation:** Passing `~x|$catalog["apple"]|` to `path_steps/1` returns `[{:sorted_map, "catalog"}, {:hash_map, "apple"}]` (inverted tags, causing `{:put, ...}` to fail with `"Unexpected_Tag"`), while `~x|.users."alice.1".name|` splits `"\"alice"` and `"1\""` into separate steps and `parse_quoted_string/2` / `parse_single_quoted_string/2` do not unescape `\'` in double quotes or `\"` in single quotes.

**Fix Hint:** Add `<<?", ...>>` / `<<?', ...>>` handling to `parse_key_token/1` and generic `\\` unescaping to both string parsers. Crucially, in canonical `xitdb` selector syntax (`.users#alice["a.b"]`), `"alice"` IS the `Counted_Hash_Map` key and `"a.b"` IS a plain `Hash_Map` key inside `"alice"`—so only shift `#`/`$` onto a following `["key"]` for root-level bare `#col["key"]` / `$col["key"]` (never on nested `.users#alice["a.b"]` or root `$["k1"]["k2"]`).

---

### `BUG-03-06`: Odin `parse_escaped_steps_buf` accepts `@0` as a literal write key and mis-shifts root `$["k1"]["k2"]`
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `selector-parsing` | **Scope:** `this-slice`
- **Introduced In:** `ddffc7a`
- **Files:** `native/xitdb_nif.odin:1731-1845`, `lib/xitdb/dsl/tx_runtime.ex:57-59`
- **Symbols:** `parse_escaped_steps_buf`, `parse_escaped_ident_or_bracket`
- **Verify With:** `mix test test/xitdb/dsl/path_compiler_test.exs test/xitdb/selector_test.exs`

**Explanation:** Running `Xitdb.transact_ops(db, [{:put, "@0.users.x", 1}])` silently creates a literal root map key `"@0"` instead of returning `:invalid_selector`, because `parse_escaped_steps_buf` has no `@` guard (whereas `decode_steps_term_buf` rejects `[{:at_moment, 0}, ...]`). Additionally, line 1808 (`if total_len == 1`) checks step count instead of whether `#` or `$` consumed a bare identifier, mis-shifting `$["k1"]["k2"]` into `.["k1"]$["k2"]` while failing to handle nested bare shorthand consistently.

**Fix Hint:** Reject `@` (`case '@': return nil, "invalid_selector"`) in `parse_escaped_steps_buf`, and track whether `#` (non-`#%`) / `$` consumed an unbracketed identifier (`s[i] != '[' && s[i] != '"' && s[i] != '\''`) rather than checking `total_len == 1`.

---

### `BUG-03-07`: `PathCompiler.static_typed_step/2` crashes on invalid step tuples and `Selector` accepts `{:at_moment, m}` inside non-root brackets
- **Severity:** `low` | **Confidence:** `high` | **Category:** `dsl-validation` | **Scope:** `this-slice`
- **Introduced In:** `ddffc7a` / `6cef6c6`
- **Files:** `lib/xitdb/dsl/path_compiler.ex:85-89`, `lib/xitdb/dsl/path_compiler.ex:113-129`, `lib/xitdb/selector.ex:80-111`, `lib/xitdb/selector.ex:177-202`, `lib/xitdb/selector.ex:219-221`
- **Symbols:** `Xitdb.DSL.PathCompiler.static_typed_step/2`, `Xitdb.Selector.format_typed_step/2`, `format_bracket_step/1`, `normalize_bracket_step/1`
- **Verify With:** `mix test test/xitdb/dsl/path_compiler_test.exs`

**Explanation:** Compiling `path_steps([{:bogus, "x"}])` or `path_steps([{:array_list, "0"}])` raises an unhandled `FunctionClauseError` instead of `ArgumentError` (same for `path([{:bogus, "x"}])`). Furthermore, passing `k = {:at_moment, 0}` inside `path(users[k])` or `path_steps(users[k])` silently produces `".users@0"` or `["users", {:at_moment, 0}]` instead of raising `ArgumentError`.

**Fix Hint:** Add catch-all `ArgumentError` clauses to `static_typed_step/2` and `format_typed_step/2`, and guard `when kind != :at_moment` on `format_bracket_step/1` and `normalize_bracket_step/1` while allowing `{:at_moment, m}` strictly at the root head.

---

## Upstream Stack & Rebase Notes

- Worktree `03-path-steps-unpack-and-select` branched off `fcff070` (initial Slice 02 commit) and does **not** yet include upstream fix commits `ed475ed` / `43a62d0` (Slice 01) or `2c18838` / `de134a7` (Slice 02).
- Do **not** patch Slice 01/02 files inside this worktree; rebase onto `perf/02-compact-cursors-and-btree-seek` once Slices 01–02 are updated. When rebasing `ed475ed`, preserve `BUG-03-03`'s untyped `.Array_List_Idx` -> `.Linked_Array_List` and `.Hash_Map_Key` -> Set adaptations alongside `ed475ed`'s `hit_scalar` and strict `#`/`$` rules.
