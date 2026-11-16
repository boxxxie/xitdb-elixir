# Implementation Plan: Slice 05 Bugfixes

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `slice_05_bugfixes_20261116`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Bug Reference:** [`./bugs.md`](./bugs.md)
> - **Done When:** All `BUG-05-01`..`BUG-05-07` items are resolved and verified.

## Resolved Bugs

- [x] `BUG-05-01` (`high`): Benchmark `#28` pre-resolves `m0_cur` outside the timed loop in Odin while Elixir re-resolves moment `-1` per op
- [x] `BUG-05-02` (`high`): `resolve_git_commit` fails inside Git worktrees (`.git` file) returning `"unknown"` and omits `-dirty` detection
- [x] `BUG-05-03` (`high`): `--lang` single-side runs exit `1` before saving, `pool_by_lang_and_test` mis-stamps commits, and default selective runs drop `--append` history
- [x] `BUG-05-04` (`medium`): `--from-jsonl` ignores filters, drops `--commit` with filters, misses `history.jsonl`, and self-compares canary baselines without `--run-id`
- [x] `BUG-05-05` (`medium`): Git-diff planner treats dirty `benchmarks/*.jsonl` as working-tree edits (falling back to all 28) and omits `do_select!` / `#28`
- [x] `BUG-05-06` (`medium`): `distinct_commits` matches selective partial commits (0-row Section 4 tables) and `--commit` short SHAs produce `Commit unknown, null samples`
- [x] `BUG-05-07` (`high`): Commit `2883a38` duplicates/conflicts with Slice 04 (`11ff6f3`) and adds depth-64, struct, validation, and rollback bugs
