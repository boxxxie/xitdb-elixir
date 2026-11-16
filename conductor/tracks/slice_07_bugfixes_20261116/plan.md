# Implementation Plan: Slice 07 Bugfixes

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `slice_07_bugfixes_20261116`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Bug Reference:** [`./bugs.md`](./bugs.md)
> - **Done When:** All `BUG-07-01`..`BUG-07-08` items are resolved and verified.

## Resolved Bugs

- [x] `BUG-07-01` (`high`): All 9 new `metadata.json` files use `"id"`/`"title"` instead of `"track_id"`/`"description"`, breaking Conductor/Linear tooling
- [x] `BUG-07-02` (`high`): Missing `---` section dividers lump 9 completed `[x]` tracks onto the open `[ ]` `odin_xitdb_history_and_release_sync` block
- [x] `BUG-07-03` (`medium`): Hallucinated `test/features/*_spec.exs` paths and inaccurate `Primary Files` across 4 tracks
- [x] `BUG-07-04` (`medium`): `HEAD` (`b16332f`) cites wrong chunk ramp (`32 -> 128 -> 256` vs `16 -> 64 -> 256`, fixed only in dirty working tree) and invalid `--group access` CLI flag (`--groups enumerable`)
- [x] `BUG-07-05` (`medium`): Inverted `hm_has_key`/`sm_has_key` polarity for `is_pure_removal_term` and inaccurate `database_truncate` rollback note
- [x] `BUG-07-06` (`medium`): False `stream_prefix_from/4` seek claims, stale `Indexer` eager-seek claim (reverted in `de134a7`), and nonexistent `read_slot_entries_term`
- [x] `BUG-07-07` (`low`): Nonexistent `NIF.nif_slot_set_member?/4`, `resolve_moment_cursor/2`, `--only 4,6`, and unimplemented `Done When` claims
- [x] `BUG-07-08` (`high`): Uncommitted cross-slice edits leak `.beam` binaries in `:persistent_term` via `BeamTracer` and risk stack rebase conflicts
