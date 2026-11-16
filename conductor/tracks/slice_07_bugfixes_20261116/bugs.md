---
worktree: 07-conductor-tracks
branch: chore/07-conductor-tracks
head_sha: b16332f
slice_base_sha: f768876
upstream_branch: chore/06-bench-baseline-and-docs
bug_count: 8
severities:
  critical: 0
  high: 3
  medium: 4
  low: 1
---

# Bug Reference — `07-conductor-tracks` (`chore/07-conductor-tracks`)

| ID | Severity | Category | Primary Files | Summary |
| :--- | :--- | :--- | :--- | :--- |
| `BUG-07-01` | `high` | `conductor-schema` | `conductor/tracks/*_20261115/metadata.json` | All 9 new `metadata.json` files use `"id"`/`"title"` instead of `"track_id"`/`"description"`, breaking Conductor/Linear tooling |
| `BUG-07-02` | `high` | `conductor-schema` | `conductor/tracks.md` | Missing `---` section dividers lump 9 completed `[x]` tracks onto the open `[ ]` `odin_xitdb_history_and_release_sync` block |
| `BUG-07-03` | `medium` | `conductor-spec-drift` | `conductor/tracks/*/spec.md`, `plan.md` | Hallucinated `test/features/*_spec.exs` paths and inaccurate `Primary Files` across 4 tracks |
| `BUG-07-04` | `medium` | `conductor-spec-drift` | `conductor/tracks/cursor_enumerable_adaptive_chunking_20261115/*` | `HEAD` (`b16332f`) cites wrong chunk ramp (`32 -> 128 -> 256` vs `16 -> 64 -> 256`, fixed only in dirty working tree) and invalid `--group access` CLI flag (`--groups enumerable`) |
| `BUG-07-05` | `medium` | `conductor-spec-drift` | `conductor/tracks/tx_single_pass_merge_map_and_put_20261115/*` | Inverted `hm_has_key`/`sm_has_key` polarity for `is_pure_removal_term` and inaccurate `database_truncate` rollback note |
| `BUG-07-06` | `medium` | `conductor-spec-drift` | `conductor/tracks/btree_seek_*_20261115/*` | False `stream_prefix_from/4` seek claims, stale `Indexer` eager-seek claim (reverted in `de134a7`), and nonexistent `read_slot_entries_term` |
| `BUG-07-07` | `low` | `conductor-spec-drift` | `conductor/tracks/*_20261115/*` | Nonexistent `NIF.nif_slot_set_member?/4`, `resolve_moment_cursor/2`, `--only 4,6`, and unimplemented `Done When` claims |
| `BUG-07-08` | `high` | `cross-slice-conflict` | `lib/xitdb/cursor.ex`, `lib/xitdb/ash/*`, `native/xitdb_nif.odin`, `benchmarks/compare_1v1.py` | Uncommitted cross-slice edits leak `.beam` binaries in `:persistent_term` via `BeamTracer` and risk stack rebase conflicts |

---

## Likely Bugs

### `BUG-07-01`: Non-standard `metadata.json` schema across all 9 new tracks (plus stale `"pending"` status on a completed sibling track)
- **Severity:** `high` | **Confidence:** `high` | **Category:** `conductor-schema` | **Scope:** `this-slice`
- **Introduced In:** `b16332f`
- **Files:** `conductor/tracks/bench_contention_and_canary_guardrails_20261115/metadata.json:1-10`, `conductor/tracks/btree_seek_compact_container_slots_20261115/metadata.json:1-10`, `conductor/tracks/btree_seek_fused_child_entries_20261115/metadata.json:1-10`, `conductor/tracks/compact_cursor_slot_tuples_20261115/metadata.json:1-10`, `conductor/tracks/cursor_enumerable_adaptive_chunking_20261115/metadata.json:1-10`, `conductor/tracks/cursor_member_and_step_list_fast_paths_20261115/metadata.json:1-10`, `conductor/tracks/path_steps_and_select_fast_path_20261115/metadata.json:1-10`, `conductor/tracks/tx_mode_virtual_write_cursors_20261115/metadata.json:1-10`, `conductor/tracks/tx_single_pass_merge_map_and_put_20261115/metadata.json:1-10`, `conductor/tracks/benchmark_followup_optimizations_20261115/metadata.json:1-10`
- **Symbols:** `metadata.json` (`track_id`, `description`, `status`)
- **Verify With:** `python3 -c 'import glob, json; [json.load(open(p))["track_id"] for p in glob.glob("conductor/tracks/*/metadata.json")]'`

**Explanation:** All 17 archived tracks and the earlier active tracks use `{"track_id", "type", "status", "created_at", "updated_at", "description"}` with UTC `Z` timestamps, whereas all 9 `metadata.json` files added in `b16332f` emit `"id"` and `"title"` without `"track_id"` or `"description"` (and use `+08:00` offsets plus `"current_phase"`/`"current_task"`). Any Conductor or `mix linear.sync` parser expecting `"track_id"` or `"description"` receives `nil` / `KeyError`. (Pre-existing `benchmark_followup_optimizations_20261115/metadata.json` also still has `"status": "pending"` despite being `[x]` in `tracks.md:17`.)

**Fix Hint:** Rename `"id"` -> `"track_id"` and `"title"` -> `"description"`, normalize timestamps to UTC `...Z` (and fix `benchmark_followup_optimizations_20261115/metadata.json` `"status"` to `"completed"`).

---

### `BUG-07-02`: Missing `---` section separators between tracks in `conductor/tracks.md`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `conductor-schema` | **Scope:** `this-slice`
- **Introduced In:** `b16332f`
- **Files:** `conductor/tracks.md:20-48`
- **Symbols:** `conductor/tracks.md`
- **Verify With:** `rg -n '^---$|^## \[' conductor/tracks.md`

**Explanation:** Conductor's `newTrack` and `implement` tooling splits `conductor/tracks.md` on `---` dividers when parsing or archiving completed tracks. Commit `b16332f` appended all 9 `[x]` tracks directly under the open `[ ]` `odin_xitdb_history_and_release_sync_20261115` entry without `---` dividers, fusing 11 mixed `[ ]`/`[x]` tracks into a single section so archiving any completed track risks deleting or corrupting all 11 entries.

**Fix Hint:** Insert a `---` horizontal rule separator between every `- [ ]` / `- [x]` track entry in `conductor/tracks.md`.

---

### `BUG-07-03`: Hallucinated `test/features/*_spec.exs` file paths and inaccurate `Primary Files` across 4 tracks
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `conductor-spec-drift` | **Scope:** `this-slice`
- **Introduced In:** `b16332f`
- **Files:** `conductor/tracks/cursor_enumerable_adaptive_chunking_20261115/spec.md:9,37`, `conductor/tracks/path_steps_and_select_fast_path_20261115/spec.md:9,41`, `conductor/tracks/path_steps_and_select_fast_path_20261115/plan.md:25`, `conductor/tracks/tx_mode_virtual_write_cursors_20261115/spec.md:9,38`, `conductor/tracks/tx_mode_virtual_write_cursors_20261115/plan.md:17`, `conductor/tracks/tx_single_pass_merge_map_and_put_20261115/spec.md:9`
- **Symbols:** `Primary Files`, `test/features/*`
- **Verify With:** `ls test/features/ test/xitdb/ test/xitdb/dsl/`

**Explanation:** Four tracks reference nonexistent spec files derived from `docs/*.md` names (`test/features/access_and_enumerable_spec.exs`, `test/features/path_and_pull_dsl_spec.exs`, `test/features/transaction_dsl_spec.exs` instead of actual `enumerable_collections_spec.exs`, `lazy_access_navigation_spec.exs`, `macro_dsl_spec.exs`, `queries_and_datalog_spec.exs`, `transactions_and_time_travel_spec.exs`). `tx_mode_virtual_write_cursors_20261115` also lists untouched `lib/xitdb/tx_compiler.ex` while omitting `native/xitdb_nif.odin`, and `tx_single_pass_merge_map_and_put_20261115` omits `native/nif_entry.c` and `test/xitdb/nif_safety_test.exs`.

**Fix Hint:** Update those `Primary Files` and test references to the actual feature specs and unit test files (`cursor_refactor_test.exs`, `path_compiler_test.exs`, `nif_safety_test.exs`).

---

### `BUG-07-04`: Wrong geometric chunk ramp in `HEAD` (`32 -> 128 -> 256`) and invalid `--group access` command in `cursor_enumerable_adaptive_chunking_20261115`
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `conductor-spec-drift` | **Scope:** `this-slice`
- **Introduced In:** `b16332f`
- **Files:** `conductor/tracks/cursor_enumerable_adaptive_chunking_20261115/spec.md:10,20,35,36,45`, `conductor/tracks/cursor_enumerable_adaptive_chunking_20261115/plan.md:8,15`
- **Symbols:** `@initial_chunk_size`, `next_chunk_size/1`, `compare_1v1.py`
- **Verify With:** `rg -n '@initial_chunk_size|next_chunk_size|--group' lib/xitdb/cursor.ex conductor/tracks/cursor_enumerable_adaptive_chunking_20261115/`

**Explanation:** In committed `HEAD` (`b16332f`), both `spec.md` and `plan.md` claim `Enumerable.Xitdb.Cursor` uses `@initial_chunk_size 32` ramping `32 -> 128 -> 256` (`87.5%` reduction, boundaries `32`, `160`, `416`), whereas `lib/xitdb/cursor.ex` implements `@initial_chunk_size 16` ramping `16 -> 64 -> 256` (`93.75%` reduction, boundaries `16`, `80`, `336`). Uncommitted working-tree edits on `plan.md` / `spec.md` partially updated the ramp to `16 -> 64 -> 256`, but `spec.md:45` still instructs running `./benchmarks/compare_1v1.py --group access` for `#9` and `#10` in both `HEAD` and the working tree—which fails because the flag is `--groups` (plural) and `#9`/`#10` belong to group `enumerable`.

**Fix Hint:** Commit the `16 -> 64 -> 256` chunk ramp correction (boundaries `16`, `80`, `336`) and change `--group access` on `spec.md:45` to `--groups enumerable`.

---

### `BUG-07-05`: Inverted `hm_has_key`/`sm_has_key` polarity and inaccurate `database_truncate` claim in `tx_single_pass_merge_map_and_put_20261115`
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `conductor-spec-drift` | **Scope:** `this-slice`
- **Introduced In:** `b16332f`
- **Files:** `conductor/tracks/tx_single_pass_merge_map_and_put_20261115/spec.md:36-37`, `conductor/tracks/tx_single_pass_merge_map_and_put_20261115/plan.md:15,25`
- **Symbols:** `is_pure_removal_term`, `merge_kv_entry_hm`, `merge_kv_entry_sm`, `odin_nif_transact`
- **Verify With:** `rg -n 'is_pure_removal_term|root_header' native/xitdb_nif.odin`

**Explanation:** `plan.md:25` and `spec.md:36-37` claim `is_pure_removal_term` is only invoked when the target parent key already exists on disk and skipped when absent—exact opposite of the code, which skips `is_pure_removal_term` when `exists == true` and runs it only when `!exists`. Also, `plan.md:15` claims errors rely on `tx_commit`'s `database_truncate` rollback, whereas `odin_nif_transact` performs explicit `core_set_length` + `Root_Header` restoration because `tx_commit` mutates the root header before running ops on empty DBs.

**Fix Hint:** Invert the `hm_has_key`/`sm_has_key` condition in `spec.md` and `plan.md` (`!exists` runs removal detection; existing parent keys skip it) and document the explicit `Root_Header` / `core_set_length` rollback in `odin_nif_transact`.

---

### `BUG-07-06`: Outdated `Indexer` / `Search` `nif_sorted_map_seek` claims and nonexistent `read_slot_entries_term` name in `btree_seek_*_20261115`
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `conductor-spec-drift` | **Scope:** `this-slice`
- **Introduced In:** `b16332f`
- **Files:** `conductor/tracks/btree_seek_compact_container_slots_20261115/spec.md:10,23,34,45,46`, `conductor/tracks/btree_seek_compact_container_slots_20261115/plan.md:8,23,24`, `conductor/tracks/btree_seek_fused_child_entries_20261115/spec.md:10,20,22,32,42,44`, `conductor/tracks/btree_seek_fused_child_entries_20261115/plan.md:8,24,25`
- **Symbols:** `Search.Storage.stream_prefix_from/4`, `Search.Storage.scan_prefix/5`, `Indexer.Storage.stream_btree_from_key/2`, `decode_child_container_entries_term`
- **Verify With:** `rg -n 'nif_sorted_map_seek|stream_prefix_from' lib/xitdb/ash/ native/xitdb_nif.odin`

**Explanation:** Both `btree_seek_*` tracks state that `Search.Storage.stream_prefix_from/4` uses `nif_sorted_map_seek` and flat 3-tuples (in reality only `scan_prefix/5` uses fused `nif_sorted_map_seek/7`, while `stream_prefix_from/4` is the `:elixir` fallback via `nif_slot_entries`). They also claim `Indexer.Storage.stream_btree_from_key/2` uses fused 7-arity `nif_sorted_map_seek` returning materialized `[String.t()]` lists—which Slice 02 (`de134a7`) reverted back to lazy 6-arity `nif_sorted_map_seek` + `Cursor.from_compact_slot/4`—and cite nonexistent Odin proc `read_slot_entries_term` instead of `decode_child_container_entries_term`.

**Fix Hint:** Align `Search.Storage.scan_prefix/5` vs `stream_prefix_from/4`, document Slice 02 `de134a7`'s lazy 6-arity `Indexer.Storage.stream_btree_from_key/2`, and rename `read_slot_entries_term` to `decode_child_container_entries_term` / `decode_container_entries_term`.

---

### `BUG-07-07`: Nonexistent NIF/Elixir symbols, `--only` CLI flag, and unimplemented `Done When` claims across 4 tracks
- **Severity:** `low` | **Confidence:** `high` | **Category:** `conductor-spec-drift` | **Scope:** `this-slice`
- **Introduced In:** `b16332f`
- **Files:** `conductor/tracks/cursor_member_and_step_list_fast_paths_20261115/plan.md:15`, `conductor/tracks/compact_cursor_slot_tuples_20261115/spec.md:32`, `conductor/tracks/path_steps_and_select_fast_path_20261115/spec.md:10`, `conductor/tracks/bench_contention_and_canary_guardrails_20261115/spec.md:9,27`, `conductor/tracks/bench_contention_and_canary_guardrails_20261115/plan.md:14-16,29`
- **Symbols:** `NIF.nif_slot_contains/4`, `Xitdb.as_of/2`, `Xitdb.Cursor.try_resolve/1`, `Xitdb.select/2`, `evaluate_contention_guardrails`
- **Verify With:** `rg -n 'nif_slot_set_member|resolve_moment_cursor|--only' lib/ native/ benchmarks/`

**Explanation:** Four `[x]` completed tracks list symbols, flags, or deliverables absent from the codebase: `cursor_member_and_step_list_fast_paths_20261115` cites `NIF.nif_slot_set_member?/4` (actual: `NIF.nif_slot_contains/4`); `compact_cursor_slot_tuples_20261115` cites `resolve_moment_cursor/2` (actual: `Xitdb.as_of/2` / `Cursor.try_resolve/1`); `path_steps_and_select_fast_path_20261115` `Done When` claims `select/2` reuses cached root slots (never implemented in `nif_select/3`); and `bench_contention_and_canary_guardrails_20261115` cites nonexistent `--only 4,6` CLI flags and console-banner `load_avg_1m` / `median_min_ratio` output (only printed when `[CONTENTION WARNING]` fires).

**Fix Hint:** Replace the phantom symbol and flag names with the implemented ones and remove the unimplemented cached-root-slot and console-banner claims from `Done When` / `[x]` tasks.

---

### `BUG-07-08`: Uncommitted cross-slice code edits on `chore/07-conductor-tracks` leak `.beam` binaries in `:persistent_term` via `BeamTracer` and risk stack rebase conflicts
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cross-slice-conflict` | **Scope:** `cross-slice-conflict`
- **Introduced In:** `working-tree (uncommitted atop b16332f)`
- **Files:** `lib/xitdb/cursor.ex:18-44`, `lib/xitdb/cursor.ex:779-808`, `lib/xitdb/ash/indexer.ex:1945-2002`, `lib/xitdb/ash/search.ex:717-899`, `native/xitdb_nif.odin:7264-7500`, `benchmarks/compare_1v1.py:570-705`
- **Symbols:** `Xitdb.Cursor.BeamTracer.trace/2`, `Xitdb.Cursor.BeamTracer.register/0`, `build_and_cache_fun_map/2`
- **Verify With:** `git status -s && mix test test/xitdb/cursor_refactor_test.exs`

**Explanation:** Uncommitted working-tree edits mix 14 Slice 01/02/05 code, NIF, test, and benchmark files (plus an untracked `deps -> ../../deps` symlink not in `.gitignore`) directly onto `chore/07-conductor-tracks`. Within those edits, `BeamTracer.trace/2` stores the full raw `.beam` binary of every compiled module into `:persistent_term.put({Xitdb.Cursor, :bytecode, mod}, bytecode)` without ever evicting it after disassembly—leaking permanent off-heap literal memory for every compiled module and triggering global VM literal-GC scans across all processes on hot recompiles—while `BeamTracer.register/0` performs a non-atomic read-modify-write on `Code.put_compiler_option(:tracers, ...)`.

**Fix Hint:** Move the `lib/`, `native/`, `benchmarks/`, and `test/` changes out of `chore/07-conductor-tracks` into Slices 01, 02, and 05 (and remove or ignore the `deps` symlink before committing). In `BeamTracer`, disassemble `bytecode` directly inside `trace/2` to store only the tiny `{fname => class}` map (or delete `{Xitdb.Cursor, :bytecode, mod}` immediately after `:beam_disasm.file/1`, avoiding `:persistent_term` churn on recompiles).

---

## Upstream Stack & Rebase Notes

- Worktree `07-conductor-tracks` (`b16332f`) is branched off `f768876` prior to all post-split fixes in Slices 01–06 (`ed475ed`, `43a62d0`, `2c18838`, `de134a7`, `6cef6c6`, `11ff6f3`, `2883a38`, `86bdd17`, and `ef0d7e0`..`c08a2a5`).
- Do **not** land `lib/`, `native/`, `benchmarks/`, or `docs/` edits directly on `chore/07-conductor-tracks`; fix the Conductor metadata/spec bugs here, route the working-tree code edits back to Slices 01/02/05, and `git rebase chore/06-bench-baseline-and-docs` once Slices 01–06 are reconciled.
