# Implementation Plan: Slice 06 Bugfixes

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `slice_06_bugfixes_20261116`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Bug Reference:** [`./bugs.md`](./bugs.md)
> - **Done When:** All `BUG-06-01`..`BUG-06-07` items are resolved and verified.

## Resolved Bugs

- [x] `BUG-06-01` (`high`): Documents nonexistent `Xitdb.Ash.Search.scan_prefix/5`, `scan_prefix_cursors/4`, and 5-arity `from_compact_slot/5`
- [x] `BUG-06-02` (`high`): Misstates `path_steps/1` term shape and C function name, omits `Xitdb.path_steps/1`, and recommends unsupported `tx` `insert path_steps(...)`
- [x] `BUG-06-03` (`medium`): Falsely claims `put_in/3` crosses the NIF boundary on every hop and raises on missing intermediate maps
- [x] `BUG-06-04` (`high`): Stale `-dirty` baselines fail `--require-clean`, all 28 NIF source links are off by up to 596 lines, and deleted SHAs remain rendered
- [x] `BUG-06-05` (`medium`): Six slice docs omit `!`/`?` Elixir functions (`select!`, `member?`, `pull!`, `info!`) and `lib/xitdb/nif.ex`
- [x] `BUG-06-06` (`high`): Regressions in `2796eb9`/`c08a2a5`/`687a2c2`: `.users#alice["a.b"]` rewrite, explicit `{__tx}` pull blocked, torn root snapshots, `inspect` crash
- [x] `BUG-06-07` (`high`): Misplaced code patches diverge from Slices 01–05 and leave upstream critical/high bugs unfixed here
