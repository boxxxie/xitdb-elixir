# Implementation Plan: Slice 03 Bugfixes

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `slice_03_bugfixes_20261116`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Bug Reference:** [`./bugs.md`](./bugs.md)
> - **Done When:** All `BUG-03-01`..`BUG-03-07` items are resolved and verified.

## Resolved Bugs

- [x] `BUG-03-01` (`high`): `Xitdb.do_select/3` and `do_select!/3` drop `@moment` / `{:at_moment, m}` overrides on returned container cursors
- [x] `BUG-03-02` (`high`): Root `select` (`""`, `[]`, `"@0"`, `[{:at_moment, 0}]`) returns `root: false`, leaking `"__tx"` and failing chained `select/2`
- [x] `BUG-03-03` (`high`): `read_steps_cursor_adaptive` & `adapt_steps_for_base_moment` miss `Linked_Array_List`/sets while weakening explicit `#`/`$` strictness
- [x] `BUG-03-04` (`high`): `read_prehashed_steps_slot` & `odin_nif_history_of` fail on `Sorted_Map`/`Linked_Array_List`/sets and wipe `doc`/`instant` on `.Unexpected_Tag`
- [x] `BUG-03-05` (`medium`): `parse_selector_steps/2` inverts root `#col["k"]`/`$col["k"]` tags, breaks `."k.1"`, and misses cross-quote unescaping
- [x] `BUG-03-06` (`medium`): `parse_escaped_steps_buf` accepts `@0` as a literal write key and mis-shifts root `$["k1"]["k2"]`
- [x] `BUG-03-07` (`low`): Invalid static step tuples crash with `FunctionClauseError` and `{:at_moment, m}` is accepted inside non-root brackets
