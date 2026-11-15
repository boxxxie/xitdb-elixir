# Implementation Plan: Adopt `odin-xitdb` Benchmark Suite Architecture

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `benchmark_suite_adoption_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** All 26 1v1 client benchmarks support selective `--groups`/`--filter`/`--affected` runs with rank-preserving JSONL merge, `benchmarks/slices/` is generated with full Elixir -> NIF -> Odin call-graph links, `benchmarks/update_readme.sh` updates `benchmarks/README.md` cleanly, and `odin check` + `mix precommit` pass with zero warnings.

---

## Phase 1: Runner CLI Flag Parity & Selective JSONL Merging (`bench_client.odin` & `bench_elixir.exs`)

- [x] Task: Upgrade `benchmarks/bench_client.odin` with full CLI argument parsing, group/filter selection, and rank-preserving JSONL merge
    - [x] Parse `--runs`, `--warmup`, `--commit`, `--run-id`, `--append`, `--no-history`, `--groups`, `--filter`, `--output`, and `--history` (plus `.git/packed-refs` commit resolution fallback)
    - [x] Assign each of the 26 benchmarks to its canonical group (`access` `#1–#5`, `enumerable` `#6–#11`, `transactions` `#12–#16`, `time_travel` `#17–#20`, `queries` `#21–#26`) and gate fixture initialization (`seed_fixture_db`, `hist_db`, `diff_db`, `search_db`) on active benchmarks
    - [x] Implement `load_existing_jsonl_ranks` so selective runs (`--groups` or `--filter` without `--append`) update only re-run ranks in `benchmarks/odin.jsonl` while preserving untouched ranks `1..26`
    - [x] Verify with `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`
- [x] Task: Upgrade `benchmarks/bench_elixir.exs` with `System.argv()` CLI parsing, group/filter selection, and rank-preserving JSONL merge
    - [x] Parse `--runs`, `--warmup`, `--commit`, `--run-id`, `--append`, `--no-history`, `--groups`, and `--filter` from `System.argv()`
    - [x] Tag each of the 26 benchmarks with its group atom (`:access`, `:enumerable`, `:transactions`, `:time_travel`, `:queries`) and lazily initialize `db`, `hist_db`, `diff_db`, and `search_db` only when needed by selected benchmarks
    - [x] Merge updated ranks into existing `benchmarks/elixir.jsonl` lines on selective runs (`--groups` / `--filter` without `--append`) and honor `--append` and `--no-history`
- [x] Task: Conductor - User Manual Verification 'Runner CLI Flag Parity & Selective JSONL Merging' (Protocol in workflow.md)

---

## Phase 2: Change-to-Benchmark Planner & Slice Generator (`compare_1v1.py`)

- [x] Task: Update group definitions, CLI flags, and `git diff` change-to-benchmark mapping in `benchmarks/compare_1v1.py`
    - [x] Update `ALL_GROUPS` and `GROUP_RANGES` to the 5 canonical groups covering `#1–#26`
    - [x] Implement `resolve_diff_target`, `map_changes_to_benchmarks`, and `print_benchmark_plan` inspecting `git diff` hunks across `lib/**/*.ex`, `native/xitdb_nif.odin`, `native/nif_entry.c`, `benchmarks/bench_elixir.exs`, and `benchmarks/bench_client.odin`
    - [x] Wire `--plan [GIT_REF]`, `--plan-json [GIT_REF]`, `--affected [GIT_REF]`, and `--lang {odin,elixir,both}` in `main()`, and add per-run sample breakdown lines to `inspect_test`
- [x] Task: Implement automated harness scanning, Elixir-to-NIF-to-Odin static call-graph slicing, and `benchmarks/slices/` generation in `benchmarks/compare_1v1.py`
    - [x] Implement `scan_elixir_harness` and `scan_odin_client_harness` to extract exact `#L<start>-L<end>` ranges, snippets, and entry calls for `#1–#26` from `bench_elixir.exs` and `bench_client.odin`
    - [x] Implement static procedure/function parsers for `lib/**/*.ex`, `native/xitdb_nif.odin`, and `native/xitdb-odin/xitdb/*.odin` to trace `Elixir API -> Xitdb.NIF -> Odin NIF -> xitdb-odin` call graphs
    - [x] Implement `build_code_map()` (`--code-map-json`) and `generate_all_slices()` (`--generate-slices`) producing `benchmarks/slices/README.md` and `benchmarks/slices/01_...md` through `26_...md` with 1v1 statistics, NIF boundary analysis, harness snippets, and `#L<start>-L<end>` source tables
- [x] Task: Conductor - User Manual Verification 'Change-to-Benchmark Planner & Slice Generator' (Protocol in workflow.md)

---

## Phase 3: Enhanced `update_readme.sh`, Documentation & Full Verification

- [x] Task: Upgrade `benchmarks/update_readme.sh` and `benchmarks/README.md`
    - [x] Integrate `--plan-json`, `--generate-slices`, and `--code-map-json` into `benchmarks/update_readme.sh`
    - [x] Add clickable `bench_link` formatting (`bench_elixir.exs#L...`, `bench_client.odin#L...`, and `slices/<slug>.md` `[🔍 Np]`) to all benchmark tables
    - [x] Add selective update `↻` rank markers and the Commit-vs-Commit progression section when multiple commits exist in `benchmarks/history.jsonl`
    - [x] Update `benchmarks/README.md` documentation for `--affected`, `--plan`, `--groups`, `--filter`, `--lang`, and `benchmarks/slices/README.md`
- [x] Task: Run end-to-end verification
    - [x] Run `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`
    - [x] Test `./benchmarks/compare_1v1.py --plan`, `./benchmarks/compare_1v1.py --generate-slices`, and `./benchmarks/compare_1v1.py --from-jsonl`
    - [x] Test selective execution (`./benchmarks/compare_1v1.py --groups access --runs 2 --warmup 1 --no-history`) and verify all 26 ranks remain intact in `benchmarks/odin.jsonl` and `benchmarks/elixir.jsonl`
    - [x] Run `./benchmarks/update_readme.sh` and verify `benchmarks/README.md` and `benchmarks/slices/README.md` formatting (including zero `$...$` MathJax underscores)
    - [x] Run `mix precommit` and confirm zero warnings and all tests passing
- [x] Task: Conductor - User Manual Verification 'Enhanced update_readme.sh, Documentation & Full Verification' (Protocol in workflow.md)
