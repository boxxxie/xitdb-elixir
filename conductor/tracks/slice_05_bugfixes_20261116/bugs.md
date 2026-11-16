---
worktree: 05-bench-27-28-and-guardrails
branch: feat/05-bench-27-28-and-guardrails
head_sha: 86bdd17
slice_base_sha: bca6525
upstream_branch: perf/04-single-pass-tx-and-rollback
bug_count: 7
severities:
  critical: 0
  high: 4
  medium: 3
  low: 0
---

# Bug Reference — `05-bench-27-28-and-guardrails` (`feat/05-bench-27-28-and-guardrails`)

| ID | Severity | Category | Primary Files | Summary |
| :--- | :--- | :--- | :--- | :--- |
| `BUG-05-01` | `high` | `benchmark-parity` | `benchmarks/bench_client.odin`, `benchmarks/bench_elixir.exs` | Benchmark `#28` pre-resolves `m0_cur` outside the timed loop in Odin while Elixir re-resolves moment `-1` per op |
| `BUG-05-02` | `high` | `cli-tooling` | `benchmarks/bench_client.odin` | `resolve_git_commit` fails inside Git worktrees (`.git` file) returning `"unknown"` and omits `-dirty` detection |
| `BUG-05-03` | `high` | `cli-tooling` | `benchmarks/compare_1v1.py`, `benchmarks/bench_client.odin`, `benchmarks/bench_elixir.exs` | `--lang` single-side runs exit `1` before saving, `pool_by_lang_and_test` mis-stamps commits, and default selective runs drop `--append` history |
| `BUG-05-04` | `medium` | `cli-tooling` | `benchmarks/compare_1v1.py` | `--from-jsonl` ignores filters, drops `--commit` with filters, misses `history.jsonl`, and self-compares canary baselines without `--run-id` |
| `BUG-05-05` | `medium` | `cli-tooling` | `benchmarks/compare_1v1.py` | Git-diff planner treats dirty `benchmarks/*.jsonl` as working-tree edits (falling back to all 28) and omits `do_select!` / `#28` |
| `BUG-05-06` | `medium` | `cli-tooling` | `benchmarks/update_readme.sh` | `distinct_commits` matches selective partial commits (0-row Section 4 tables) and `--commit` short SHAs produce `Commit unknown, null samples` |
| `BUG-05-07` | `high` | `cross-slice-conflict` | `native/nif_entry.c`, `native/xitdb_nif.odin`, `test/xitdb/nif_safety_test.exs` | Commit `2883a38` duplicates/conflicts with Slice 04 (`11ff6f3`) and adds depth-64, struct, validation, and rollback bugs |

---

## Likely Bugs

### `BUG-05-01`: Benchmark `#28` (`Pre-tokenized path_steps`) apples-to-oranges 1v1 parity bug (`86bdd17` Elixir change is a no-op)
- **Severity:** `high` | **Confidence:** `high` | **Category:** `benchmark-parity` | **Scope:** `this-slice`
- **Introduced In:** `7b8e1f7` / `86bdd17`
- **Files:** `benchmarks/bench_client.odin:794-798`, `benchmarks/bench_client.odin:1481-1501`, `benchmarks/bench_elixir.exs:126`, `benchmarks/bench_elixir.exs:536-544`, `lib/xitdb.ex:648-671`, `native/xitdb_nif.odin:4251`
- **Symbols:** `main` (`#28` in `bench_client.odin`), `Xitdb.ClientBench.run/1`, `Xitdb.select!/2`, `odin_nif_select`
- **Verify With:** `./benchmarks/compare_1v1.py --filter "path_steps" --runs 2 --warmup 1`

**Explanation:** Commit `86bdd17` tried to equalize `#28` by passing a pre-resolved `root` cursor to `Xitdb.select!(root, ...)`, but `Xitdb.do_select!/3` ignores `root.value` and passes `moment = -1` to `NIF.nif_select`. On every one of the 500 timed ops, Elixir calls `resolve_slot_arg(handle, -1, -1)` (reading `Root_Header`, `Root_Trailer`, and moments `Array_List`), while `bench_client.odin` calls `read_steps_cursor` on `m0_cur` pre-resolved once outside the loop—artificially inflating the `#28` Elixir/Odin ratio.

**Fix Hint:** Resolve the latest moment cursor (`database_root_cursor` + `read_array_list_init` + `array_list_get_cursor(..., -1)`) inside the 500-op loop in `bench_client.odin` (matching `odin_nif_select`, as in WT 06 `ef0d7e0`) and revert `bench_elixir.exs` to `Xitdb.select!(db, ...)`.

---

### `BUG-05-02`: `bench_client.odin` fails to resolve git commit inside worktrees and never marks `-dirty`
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cli-tooling` | **Scope:** `this-slice`
- **Introduced In:** `7b8e1f7` (pre-existing in touched runner)
- **Files:** `benchmarks/bench_client.odin:45-80`, `benchmarks/compare_1v1.py:393-403`, `benchmarks/compare_1v1.py:606-631`
- **Symbols:** `resolve_git_commit`
- **Verify With:** `odin run benchmarks -collection:xitdb=native/xitdb-odin/xitdb -- --filter "path_steps" --runs 1 --warmup 0`

**Explanation:** `resolve_git_commit` calls `os.read_entire_file(".git/HEAD")`, which fails (`ENOTDIR`) inside any linked Git worktree where `.git` is a `gitdir:` file, returning `"unknown"` (silently discarded by `update_readme.sh` and `compute_canary_baselines`). It also never checks `git status --porcelain` for `-dirty`, so standalone runs on a dirty tree stamp a fake clean SHA into `history.jsonl`, corrupting canary baselines and failing commit pairing against Elixir's `<sha>-dirty`.

**Fix Hint:** Parse `.git` when it is a file (`gitdir: <path>` + `<gitdir>/commondir`) or invoke `git rev-parse --short=12 HEAD` and `git status --porcelain` for `lib/`, `native/`, `benchmarks/bench_elixir.exs`, and `benchmarks/bench_client.odin`.

---

### `BUG-05-03`: `compare_1v1.py` `--lang` runs exit `1` before saving, `pool_by_lang_and_test` mis-stamps commits, and non-clean selective runs wipe `--append` history
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cli-tooling` | **Scope:** `this-slice`
- **Introduced In:** `7b8e1f7` / `86bdd17`
- **Files:** `benchmarks/compare_1v1.py:437`, `benchmarks/compare_1v1.py:455-457`, `benchmarks/compare_1v1.py:490-509`, `benchmarks/compare_1v1.py:708-745`, `benchmarks/compare_1v1.py:2264-2285`, `benchmarks/bench_client.odin:228-243`, `benchmarks/bench_elixir.exs:594-617`
- **Symbols:** `print_1v1_comparison`, `pool_by_lang_and_test`, `merge_jsonl_lines`, `main`, `load_existing_jsonl_ranks`
- **Verify With:** `./benchmarks/compare_1v1.py --lang elixir --filter "Indexer:" --runs 1 --warmup 0`

**Explanation:** First, `main()` runs `print_1v1_comparison` before `persist_clean_jsonl`, so `--lang elixir` or `--lang odin` exits `1` whenever the un-run side's JSONL is missing or lacks matching ranks (e.g. `#27`/`#28`), discarding results. Second, `pool_by_lang_and_test` overwrites every benchmark's `commit` with `filtered[-1]["commit"]`, mislabeling partial runs. Third, selective runs without `--require-clean` bypass `merge_jsonl_lines` and delegate to `bench_client.odin` / `bench_elixir.exs`, which only store 1 line per rank and delete accumulated `--append` samples on untouched benchmarks.

**Fix Hint:** Support single-language summaries in `print_1v1_comparison` when `run_lang != "both"`, keep each benchmark's own `latest_for_name` commit in `pool_by_lang_and_test`, and route all runs (not only `--require-clean`) through `merge_jsonl_lines` while accumulating lists of lines per rank in both language runners.

---

### `BUG-05-04`: `compare_1v1.py --from-jsonl` ignores filters, drops `--commit` with filters, misses `history.jsonl`, and self-compares canaries
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `cli-tooling` | **Scope:** `this-slice`
- **Introduced In:** `7b8e1f7` / `86bdd17`
- **Files:** `benchmarks/compare_1v1.py:2215-2220`, `benchmarks/compare_1v1.py:2255-2273`
- **Symbols:** `main`, `compute_canary_baselines`
- **Verify With:** `./benchmarks/compare_1v1.py --from-jsonl --groups access --require-clean`

**Explanation:** Under `--from-jsonl`, `main()` never filters loaded rows by `odin_groups`, `elixir_groups`, or `bench_filter`, resets `snapshot_commit = None` whenever `--commit` is paired with `--groups`/`--filter`, and never checks `history.jsonl` if the requested `--commit` or `--run-id` is absent from `odin.jsonl`/`elixir.jsonl`. Furthermore, without `--run-id`, `excluded_run_id` is `None`, so a non-dirty throttled run stays in `prior_history` and matches itself as `latest_clean_commit` (`1.00x`).

**Fix Hint:** Load `history.jsonl` as fallback when `--commit`/`--run-id` isn't in the primary JSONLs, preserve `snapshot_commit = args.commit`, apply group/filter selection to `--from-jsonl` rows, and exclude the evaluated run's `run_ids` from `prior_history`.

---

### `BUG-05-05`: `compare_1v1.py` git-diff planner is broken by dirty `benchmarks/*.jsonl` and omits `do_select!` / `#28` attribution
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `cli-tooling` | **Scope:** `this-slice`
- **Introduced In:** `7b8e1f7` / `86bdd17`
- **Files:** `benchmarks/compare_1v1.py:61`, `benchmarks/compare_1v1.py:251`, `benchmarks/compare_1v1.py:1670-1683`, `benchmarks/compare_1v1.py:1932-1938`
- **Symbols:** `resolve_diff_target`, `map_changes_to_benchmarks`, `BENCHMARK_CATALOG`
- **Verify With:** `./benchmarks/compare_1v1.py --plan`

**Explanation:** `resolve_diff_target("auto")` checks `git status --porcelain -- lib/ native/ benchmarks/`. Any earlier benchmark run that dirtied `benchmarks/*.jsonl` forces auto-detection into `"working tree vs HEAD"`, which then ignores `.jsonl` files and falls back to running all 28 benchmarks instead of planning `HEAD~1..HEAD`. Separately, `map_changes_to_benchmarks` omits `"do_select!"` and only attributes `select!` changes to `#2`, missing `#28` (`"Pre-tokenized path_steps"`).

**Fix Hint:** Scope `resolve_diff_target` and `map_changes_to_benchmarks` status checks to `lib/`, `native/`, `benchmarks/bench_elixir.exs`, and `benchmarks/bench_client.odin`, and add `"do_select!"` plus `"Pre-tokenized path_steps"` (`#28`) to `BENCHMARK_CATALOG` and the `select` attribution rule.

---

### `BUG-05-06`: `benchmarks/update_readme.sh` emits empty Commit-vs-Commit tables on selective commits and corrupts `README.md` on short `--commit` prefixes
- **Severity:** `medium` | **Confidence:** `high` | **Category:** `cli-tooling` | **Scope:** `this-slice`
- **Introduced In:** `7b8e1f7` (integration with `update_readme.sh`)
- **Files:** `benchmarks/update_readme.sh:242-247`, `benchmarks/update_readme.sh:278-290`, `benchmarks/update_readme.sh:338`, `benchmarks/update_readme.sh:364-375`
- **Symbols:** `distinct_commits`, `compare_commits_table`, `latest_snapshot_for_lang`, `single_lang_section`
- **Verify With:** `bash -n benchmarks/update_readme.sh`

**Explanation:** `distinct_commits` picks any non-dirty commit in `history.jsonl` regardless of benchmark coverage, so a selective `#27`/`#28` run followed by `update_readme.sh` produces an empty intersection with the prior 26-benchmark commit and writes 0-row Section 4 Commit-vs-Commit tables. In addition, `--commit <short_sha>` uses exact equality (`(.commit // "unknown") == $target_commit`), writing `Commit unknown, null samples across null run(s)` into `benchmarks/README.md` when given a 7-char SHA against 12-char JSONL commits.

**Fix Hint:** Restrict `distinct_commits` to full-suite commits (or commits with high rank overlap), match `$target_commit` by prefix (`startswith`), and fail cleanly if `$ex_list | length == 0` before touching `README.md`.

---

### `BUG-05-07`: Cross-slice NIF commit `2883a38` introduces depth-64, struct, validation, and rollback bugs and directly conflicts with Slice 04 (`11ff6f3`)
- **Severity:** `high` | **Confidence:** `high` | **Category:** `cross-slice-conflict` | **Scope:** `cross-slice-conflict`
- **Introduced In:** `2883a38`
- **Files:** `native/nif_entry.c:222-225`, `native/xitdb_nif.odin:2444-2456`, `native/xitdb_nif.odin:2863-2895`, `native/xitdb_nif.odin:3025-3034`, `native/xitdb_nif.odin:3929-4010`, `native/xitdb_nif.odin:4185-4196`, `test/xitdb/nif_safety_test.exs:451-455`, `test/xitdb/nif_safety_test.exs:523-535`
- **Symbols:** `is_structured_write_candidate`, `is_pure_removal_term`, `structured_op_callback`, `odin_nif_transact`
- **Verify With:** `mix test test/xitdb/nif_safety_test.exs`

**Explanation:** Commit `2883a38` modified Slice 04 NIF and test files independently of WT 04 (`11ff6f3`), causing direct merge conflicts (`Nif_Map_Iter` vs `KV_Stack_Buf`, `:max_write_depth_exceeded` at depth 64 vs `:invalid_put_op` at depth > 64, and contradictory assertions at `nif_safety_test.exs:451`). It also contains four bugs inside `2883a38`: (1) `is_pure_removal_term` checks `depth >= MAX_WRITE_DEPTH` before verifying if the leaf is a map, falsely rejecting valid 64-level maps when the root key is absent; (2) `is_structured_write_candidate` accepts arbitrary structs (`%URI{}`, `%Date{}`), returning `"Invalid_Range"` instead of `:invalid_put_op`; (3) cold validation (`parse_tx_ops` + `validate_deferred_tx_ops`) is missing; and (4) rollback skips `core_set_length` when `len_err != nil && hdr_changed`.

**Fix Hint:** Fold `2883a38`'s streaming `Nif_Map_Iter` writer improvements into Slice 04 (`perf/04-single-pass-tx-and-rollback`) alongside `11ff6f3`'s struct filter, `validate_deferred_tx_ops`, and fixed `core_set_length` / `root_header_to_bytes` rollback, and drop `2883a38` from Slice 05 so Slice 05 only touches `benchmarks/`.

---

## Upstream Stack & Rebase Notes

- Worktree `05-bench-27-28-and-guardrails` branched off `bca6525` (initial Slice 04 commit) and does **not** yet include upstream fix commits `ed475ed` / `43a62d0` (Slice 01), `2c18838` / `de134a7` (Slice 02), `6cef6c6` (Slice 03), or `11ff6f3` (Slice 04).
- After reconciling `2883a38` and `11ff6f3` inside `perf/04-single-pass-tx-and-rollback`, drop `2883a38` when rebasing `feat/05-bench-27-28-and-guardrails` onto `perf/04-single-pass-tx-and-rollback`.
