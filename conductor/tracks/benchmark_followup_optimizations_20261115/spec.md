# Specification: Benchmark Follow-Up Optimizations (Sample Isolation, Pull Parity & Bulk Tx Prefix Grouping)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `benchmark_followup_optimizations_20261115`
> - **Type:** Chore / Performance & Benchmark Tooling
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Submodule Boundary:** `native/xitdb-odin` stays untouched (read-only)
> - **Primary Files:** `benchmarks/compare_1v1.py`, `benchmarks/update_readme.sh`, `benchmarks/bench_elixir.exs`, `lib/xitdb/tx_compiler.ex`, `lib/xitdb.ex`, `native/xitdb_nif.odin`, `benchmarks/README.md`, `benchmarks/slices/`
> - **Done When:** Dirty-worktree benchmark runs never silently pool with prior baseline runs of the same `HEAD` SHA, benchmark `#21` isolates `Xitdb.pull!/2` from harness key lookups and reduces pattern-parsing overhead, `#13` bulk transactions group shared prefixes or nested subtrees to avoid redundant HAMT traversals, clean post-commit benchmark baselines and slices are regenerated, and `odin check` + `mix precommit` pass with zero warnings.

---

## 1. Goal & Motivation

Analysis of the post-optimization 1v1 client benchmark results revealed three concrete follow-up opportunities across tooling, harness parity, and transaction compilation:
1. **Silent Sample Pooling Across Pre/Post Edits (`compare_1v1.py` & `update_readme.sh`):** Running `./benchmarks/compare_1v1.py` with uncommitted changes tags samples with the current `git HEAD` SHA. Because `benchmarks/update_readme.sh` and `history.jsonl` aggregate all samples sharing the same `commit` string, pre-optimization and post-optimization runs on an uncommitted working tree pooled together—inflating `CV%` (`36%–56%` on `#12–#16`) and averaging pre/post medians in [`benchmarks/README.md`](../../../benchmarks/README.md).
2. **Benchmark `#21` (`Datomic pull`) Harness Mismatch & Pattern Parsing:** In [`benchmarks/bench_client.odin`](../../../benchmarks/bench_client.odin), `#21` iterates pre-resolved entity `u_slots[idx]` and times only `xitdb.pull`, whereas [`benchmarks/bench_elixir.exs`](../../../benchmarks/bench_elixir.exs) performs `users_cur["u#{idx}"]` (`~0.85 µs` `nif_slot_get_key` + string interpolation) inside the timed loop before calling `Xitdb.pull!/2`. Even after isolating the lookup, `odin_nif_pull` repeatedly parses string patterns on every invocation.
3. **Bulk Transaction Prefix Overhead (`#13` — 100 Entities in 1 Commit):** `TxCompiler.compile_moment_map/2` flattens nested maps (`%{"users" => %{"u0" => %{"name" => ..., "age" => ..., "score" => ...}, ...}}`) into 300 independent root-anchored `:put` selector strings (`.users.u0.name`, `.users.u0.age`, `.users.u0.score`, ...), causing `odin_nif_transact` and `xitdb-odin` to re-hash and re-traverse `"users"` and `"u#{i}"` HAMT nodes 3× per entity instead of writing each entity subtree from a grouped cursor or subtree op.

---

## 2. Functional Requirements

### 2.1 Dirty-Worktree & Per-Run Sample Isolation (`compare_1v1.py` & `update_readme.sh`)
- Detect uncommitted working-tree modifications (`git status --porcelain` excluding generated `benchmarks/*.jsonl`, `benchmarks/README.md`, and `benchmarks/slices/` or explicit code paths) in `benchmarks/compare_1v1.py`, `benchmarks/bench_elixir.exs`, and `benchmarks/bench_client.odin`:
  - Tag dirty working-tree runs distinctly (e.g., `<sha>-dirty`) so uncommitted experiments never pool into clean `HEAD` commit statistics in `benchmarks/history.jsonl` or `benchmarks/README.md`.
- Add run-isolation controls to `benchmarks/compare_1v1.py` and `benchmarks/update_readme.sh` (e.g., `--latest-run` or per-`run_id` selection when inspecting or rendering tables) so mixed runs for a SHA can be inspected independently without losing append-only history.
- Ensure selective `--affected` / `--groups` runs replace cleanly without leaving stale mixed-version stats in `benchmarks/elixir.jsonl` and `benchmarks/odin.jsonl`.

### 2.2 Benchmark `#21` (`Datomic pull`) Harness Parity & Pull Pattern Overhead (`bench_elixir.exs` & `native/xitdb_nif.odin`)
- Pre-resolve `users_cur["u#{i}"]` entity cursors outside the timed `Xitdb.pull!/2` loop in [`benchmarks/bench_elixir.exs`](../../../benchmarks/bench_elixir.exs), matching [`benchmarks/bench_client.odin`](../../../benchmarks/bench_client.odin)'s pre-resolved `u_slots[idx]` setup so `#21` measures `Xitdb.pull!/2` overhead cleanly without conflating an uncached `nif_slot_get_key` hop.
- Profile and reduce pull pattern parsing/dispatch overhead in [`native/xitdb_nif.odin`](../../../native/xitdb_nif.odin) (`odin_nif_pull` / `nif_pull_cursor`) and [`lib/xitdb.ex`](../../../lib/xitdb.ex) (`Xitdb.pull/2`), ensuring full compatibility with existing Datomic pull syntax and specs.

### 2.3 Bulk Transaction Prefix Grouping / Subtree Writes (`#13` — `lib/xitdb/tx_compiler.ex` & `native/xitdb_nif.odin`)
- Eliminate redundant root-to-entity HAMT path traversals and key hashing when committing nested maps or flat `:put` batches that share common container prefixes (`"users"` → `"u#{i}"` across 100 entities × 3 attributes in `#13`):
  - Evaluate structured subtree writes (encoding nested Elixir maps directly as structured `:put` container ops or grouping common path prefixes in `TxCompiler` / `odin_nif_transact` / `_execute_tx_cb`) vs. grouped cursor callbacks.
  - Preserve full semantics for typed wrappers (`%Xitdb.Collection{}`), `index_rules`, escaped keys, and empty map/list semantics verified by `test/` property and ATDD suites.

### 2.4 Clean Post-Commit Benchmark Baseline & Slice Regeneration
- Re-run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` on clean commits (without dirty pooling) and run `./benchmarks/update_readme.sh`.
- Regenerate `benchmarks/README.md` and `benchmarks/slices/*.md` + `benchmarks/slices/README.md` with clean post-optimization medians, tight `CV%`, and updated NIF boundary analysis.

---

## 3. Technical Invariants

1. **History Preservation:** `benchmarks/history.jsonl` remains strictly append-only; existing historical records must never be truncated or lost.
2. **Submodule Isolation:** `native/xitdb-odin/` remains read-only.
3. **Markdown MathJax Safety:** Never use underscores inside `$...$` or `$$...$$` LaTeX blocks in any documentation, slice, or README file; always use inline code spans (e.g., `` `CV%` ``, `` `u_slots` ``).
4. **Odin & Elixir Cleanliness:** `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb`, `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb`, and `mix precommit` must pass with zero warnings and zero test failures.

---

## 4. Out of Scope

- Altering core `xitdb` engine internals inside the read-only `native/xitdb-odin/` submodule.
- Changing non-benchmark public `Xitdb` or `Xitdb.Ash` APIs in backwards-incompatible ways.

---

## 5. Acceptance Criteria

1. Running `./benchmarks/compare_1v1.py` on a dirty working tree tags records as `<sha>-dirty` (or isolates them) so clean commit statistics in `benchmarks/history.jsonl` and `benchmarks/README.md` never average pre- and post-edit runs.
2. Benchmark `#21` in `benchmarks/bench_elixir.exs` pre-resolves entity cursors identically to `benchmarks/bench_client.odin`, and `odin_nif_pull` pattern overhead is minimized without regressions in `Pull` tests.
3. Bulk nested map transactions (`#13`) avoid redundant shared-prefix HAMT traversals, measurably improving Elixir `#13` latency and ratio vs. Raw Odin while passing all `TxCompiler` and ATDD tests.
4. `./benchmarks/compare_1v1.py --runs 5 --warmup 1` and `./benchmarks/update_readme.sh` produce clean, unpooled tables and updated `benchmarks/slices/`.
5. `odin check` (native + benchmarks) and `mix precommit` exit `0` with zero warnings.
