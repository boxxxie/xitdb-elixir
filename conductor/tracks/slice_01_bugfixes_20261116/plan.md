# Implementation Plan: Slice 01 Bugfixes

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `slice_01_bugfixes_20261116`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Bug Reference:** [`./bugs.md`](./bugs.md)
> - **Done When:** All `BUG-01-01`..`BUG-01-10` items are resolved and verified.

## Resolved Bugs

- [x] `BUG-01-01` (`critical`): `odin_nif_transact` leaks uncommitted bytes and mutates `Root_Header` after `:savepoint`, `:fork`, or 0-moment tx failure
- [x] `BUG-01-02` (`high`): `adapt_steps_for_base_moment` aborts early at depth 0 on new/empty DB paths and misses nested collection / list / set tags
- [x] `BUG-01-03` (`high`): `classify_access_fun/1` disables virtual cursors for `put_in/2` macros, while fallback triggers `2^(D - 1)` retries and skips list key checks
- [x] `BUG-01-04` (`high`): Unguarded `{get_val, %Xitdb.Cursor{}}` match wipes prior `staged_ops` when assigning a snapshot or foreign cursor
- [x] `BUG-01-05` (`high`): `Enumerable.Xitdb.Cursor` swallows `{:error, :closed}` and storage errors into `0`, `false`, or `[]`
- [x] `BUG-01-06` (`high`): `apply_staged_overlay/2` ignores staged ancestor replacements and `materialize_staged_val/1` keeps `nil` values in collection maps
- [x] `BUG-01-07` (`high`): `Enumerable` `unwrap_entry/4` assigns parent `path_steps` to child cursors, misdirecting writes inside `Enum` loops
- [x] `BUG-01-08` (`medium`): `insert_at`/`delete_at`/`fork`/appends desynchronize `staged_overrides`, breaking `[-1]`, `pop_in`, and nested collections
- [x] `BUG-01-09` (`medium`): `do_select/3` drops `@moment` and `root: true`; root `"__tx"` leaks in `pull`/`count`/`slice` and duplicates `Sorted_Map` chunk boundaries
- [x] `BUG-01-10` (`medium`): `rm_if_exists_callback` hardcodes `.Hash_Map_Key` steps for `index_on` eviction, failing on `Counted_Hash_Map` and `Sorted_Map`
