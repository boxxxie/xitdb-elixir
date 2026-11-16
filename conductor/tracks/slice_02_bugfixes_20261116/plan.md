# Implementation Plan: Slice 02 Bugfixes

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `slice_02_bugfixes_20261116`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Bug Reference:** [`./bugs.md`](./bugs.md)
> - **Done When:** All `BUG-02-01`..`BUG-02-07` items are resolved and verified.

## Resolved Bugs

- [x] `BUG-02-01` (`critical`): `slot.full == true` `.Bytes` slots skip offset/length bounds and `dst == nil` check, causing Odin panic or OOM abort (`SIGABRT`)
- [x] `BUG-02-02` (`high`): Non-binary map keys bypass `when is_binary(k)` unwrapping, leaking raw `{:cursor, tag_id, slot_val}` tuples
- [x] `BUG-02-03` (`high`): `stream_prefix_from/4` crashes with `CaseClauseError` on `nil` or scalar entries in `terms` (`:elixir` / fallback path)
- [x] `BUG-02-04` (`high`): `scan_prefix/5`, `scan_prefix_cursors/4`, and `stream_btree_from_key/2` swallow `:closed`/corruption errors and crash/mis-scan on non-`Sorted_Map`
- [x] `BUG-02-05` (`medium`): `nif_sorted_map_seek/5` and `/6` run on normal schedulers (`flags = 0`) with unbounded `limit_int` and blocking `pread` I/O
- [x] `BUG-02-06` (`medium`): `decode_container_entries_term` duplicates chunk-boundary entries on root `Sorted_Map` snapshots containing `"__tx"`
- [x] `BUG-02-07` (`low`): `odin_nif_sorted_map_seek` masks invalid offsets when `limit_int <= 0` and rejects `tag_int == -1` root cursors
