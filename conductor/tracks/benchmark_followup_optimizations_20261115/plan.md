# Implementation Plan: Benchmark Follow-Up Optimizations (Sample Isolation, Pull Parity & Bulk Tx Prefix Grouping)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `benchmark_followup_optimizations_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Dirty-worktree benchmark runs are isolated from clean commits, `#21` has 1v1 cursor pre-resolution parity and leaner pull parsing, `#13` avoids shared-prefix HAMT re-traversals in bulk transactions, clean post-commit baselines and slices are regenerated, and `odin check` + `mix precommit` pass with zero warnings.

---

## Phase 1: Dirty-Worktree & Per-Run Sample Isolation (`compare_1v1.py` & `update_readme.sh`)

- [x] Task: Tag dirty working-tree runs and prevent silent pre/post commit pooling
    - [x] Update `benchmarks/compare_1v1.py`, `benchmarks/bench_elixir.exs`, and `benchmarks/bench_client.odin` to append `-dirty` when tracked source files (`lib/`, `native/`, `benchmarks/bench_*`) have uncommitted modifications
    - [x] Add `--latest-run` / run-ID filtering support in `benchmarks/compare_1v1.py` and `benchmarks/update_readme.sh` so single clean runs can be rendered without pooling stale runs from the same commit
    - [x] Verify `--plan`, `--inspect`, and selective `--groups` runs preserve `benchmarks/history.jsonl` and `1..26` ranks cleanly

---

## Phase 2: Benchmark `#21` (`Datomic pull`) Harness Parity & Pattern Parsing Optimization

- [x] Task: Align `#21` harness timing with `bench_client.odin` and reduce `odin_nif_pull` overhead
    - [x] Pre-resolve entity cursor list (`u_cursors`) before the timed loop in `benchmarks/bench_elixir.exs` (`#21`) to match `u_slots[idx]` in `benchmarks/bench_client.odin`
    - [x] Inspect and optimize pull pattern parsing / key matching allocations in `native/xitdb_nif.odin` (`odin_nif_pull` / `nif_pull_cursor`) using `context.temp_allocator` slices without heap churn
    - [x] Verify `mix test test/features/pull_* test/xitdb/pull_test.exs` (or full `mix precommit`) and re-benchmark `--groups queries --filter "Datomic pull"`

---

## Phase 3: Bulk Transaction Prefix Grouping / Subtree Writes (`#13`)

- [x] Task: Eliminate redundant shared-prefix HAMT traversals in bulk transactions
    - [x] Profile `#13` (`Tx: Bulk batch transact (100 entities in 1 commit)`) across `Xitdb.TxCompiler`, BEAM->NIF term decoding, and `odin_nif_transact`
    - [x] Implement common-prefix cursor grouping or direct structured subtree decoding in `lib/xitdb/tx_compiler.ex` and `native/xitdb_nif.odin` so shared ancestors (`"users"`, `"u#{i}"`) are traversed and hashed once per subtree rather than once per leaf attribute
    - [x] Ensure full parity for `Xitdb.Collection` wrappers (`counted_map`, `sorted_map`, `linked_list`, sets), escaped keys, empty containers, and `index_rules`
    - [x] Verify `mix precommit` and `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb`

---

## Phase 4: Clean Post-Commit Baseline, Slices & Final Verification

- [x] Task: Regenerate clean benchmark results, slices, and README tables
    - [x] Commit implementation changes cleanly on the working branch (never push directly to `master`)
    - [x] Run `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb` and `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`
    - [x] Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` on clean `HEAD`
    - [x] Run `./benchmarks/update_readme.sh` to refresh `benchmarks/README.md` and `benchmarks/slices/*.md`
    - [x] Run `mix precommit` and confirm zero compiler/formatter warnings and 100% passing tests
