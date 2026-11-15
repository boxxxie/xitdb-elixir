# Specification: Adopt `odin-xitdb` Benchmark Suite Architecture

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `benchmark_suite_adoption_20261115`
> - **Type:** Chore / Benchmark Infrastructure
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Submodule Boundary:** `native/xitdb-odin` stays untouched (read-only for static call-graph slice analysis)
> - **Primary Files:** `benchmarks/bench_elixir.exs`, `benchmarks/bench_client.odin`, `benchmarks/compare_1v1.py`, `benchmarks/update_readme.sh`, `benchmarks/README.md`, `benchmarks/slices/`
> - **Done When:** All 26 1v1 client benchmarks support selective `--groups`/`--filter`/`--affected` execution with rank-preserving JSONL merges, `--generate-slices` produces `benchmarks/slices/*.md` + `benchmarks/slices/README.md`, `update_readme.sh` embeds slice/harness links and commit-vs-commit progression tables, and `odin check` + `mix precommit` pass with zero warnings.

---

## 1. Goal & Motivation

`native/xitdb-odin/benchmarks/` evolved a significantly richer statistical benchmark workflow than `elixir/xitdb/benchmarks/`:
- Selective execution (`--groups`, `--filter`, `--affected [GIT_REF]`, `--plan [GIT_REF]`, `--lang`) that maps `git diff` changes at the file and procedure level to only the affected benchmarks and merges updated ranks into `odin.jsonl` / `elixir.jsonl` without wiping untouched benchmarks.
- Automated per-benchmark code slices (`--generate-slices`, `--code-map-json`, `benchmarks/slices/<rank>_<slug>.md`, and `benchmarks/slices/README.md`) linking each benchmark row to its exact `#L<start>-L<end>` harness code, static call-graph slice, and architectural analysis.
- Commit-vs-commit progression reporting and selective `↻` markers in `benchmarks/update_readme.sh`.

Meanwhile, auditing `elixir/xitdb/benchmarks/` revealed several gaps and drift:
1. **`bench_elixir.exs` ignores all CLI flags** (`System.argv()` is never parsed), and **`bench_client.odin` only parses `--runs`** (ignoring `--warmup`, `--commit`, `--run-id`, `--append`, `--no-history`, `--groups`, and `--filter`).
2. **Selective runs clobber JSONL files:** Running a subset of benchmarks would overwrite `elixir.jsonl` / `odin.jsonl` instead of merging updated ranks into existing baseline lines.
3. **Stale group map & stubbed planner in `compare_1v1.py`:** `ALL_GROUPS` and `GROUP_RANGES` still reference 4 groups (`#1–#16`) instead of the 5 groups covering `#1–#26` (`access`, `enumerable`, `transactions`, `time_travel`, `queries`), and `map_changes_to_benchmarks` is a dummy stub.
4. **No `benchmarks/slices/` generator or harness `#L<start>-L<end>` code map.**

> [!NOTE]
> **Why We Keep the 26 Client Workloads (Instead of Copying `bench_xitdb.odin`'s 75 Engine Microbenchmarks):**
> `native/xitdb-odin/benchmarks/bench_xitdb.odin` tests low-level internal storage primitives (`remove_map_slot` branch shortening, SHA-1 vs. SHA-256 hashers, raw `Cursor_Reader`/`Cursor_Writer` stream chunks, internal `Memory_Offset_Map` vs. `File_Offset_Map`) that are not separate Elixir APIs. The 26 orthogonal client workloads (`#1–#26`) in `bench_elixir.exs` and `bench_client.odin` are purpose-built for the Elixir NIF client boundary and remain the canonical benchmark set.

---

## 2. Functional Requirements

### 2.1 Full CLI Flag & Selective JSONL Merge Parity (`bench_elixir.exs` & `bench_client.odin`)
- Both runners (`benchmarks/bench_elixir.exs` and `benchmarks/bench_client.odin`) must parse and honor all CLI flags passed by `compare_1v1.py`:
  - `--runs <N>` (default `5`)
  - `--warmup <N>` (default `1`)
  - `--commit <SHA>` (default: current 12-char Git HEAD SHA, including `.git/packed-refs` fallback in Odin)
  - `--run-id <ID>` (default: `run-<unix_sec>`)
  - `--append` (append all executed records to `elixir.jsonl` / `odin.jsonl` for multi-run sample pooling)
  - `--no-history` (skip appending to `benchmarks/history.jsonl`)
  - `--groups <csv>` (filter by group: `access`, `enumerable`, `transactions`, `time_travel`, `queries`, or `all`, plus convenient aliases like `enum`, `stream`, `tx`, `history`, `lifecycle`, `query`, `search`, `storage`)
  - `--filter <pattern>` (pipe- or comma-separated case-insensitive benchmark name substrings)
- **Selective JSONL Rank Merging:** When `--groups` or `--filter` is active (and `--append` is false), both runners must load existing lines by `rank` from `benchmarks/elixir.jsonl` / `benchmarks/odin.jsonl`, replace only the ranks that were executed in the current run, write the full merged 26-rank file back in rank order (`1..26`), and append only the newly executed records to `benchmarks/history.jsonl` (unless `--no-history` is set).
- **Lazy Fixture Setup:** Only initialize fixtures (`seed_fixture_db`, `hist_db`, `diff_db`, `search_db`) required by the active benchmarks in a selective run so targeted runs execute fast.

### 2.2 Git-Diff Change-to-Benchmark Planner (`compare_1v1.py`)
- Update `ALL_GROUPS` and `GROUP_RANGES` to reflect the 5 canonical groups across `#1–#26`:
  - `access`: `#1–#5 (Lazy Access Navigation, Selectors & Collection Indexing)`
  - `enumerable`: `#6–#11 (Enumerable Protocol, Stream Halting & Subtree Materialization)`
  - `transactions`: `#12–#16 (Transactions, Batch Commits, Cursor Edits, List Ops & Fork)`
  - `time_travel`: `#17–#20 (Time-Travel Snapshots, Lineage, Structural Diff & Compaction)`
  - `queries`: `#21–#26 (Pull Projections, Datalog Engine, Buffered File Sync & BM25/Prefix Search)`
- Implement `resolve_diff_target(git_ref)` and `map_changes_to_benchmarks(git_ref)` in `benchmarks/compare_1v1.py`:
  - Inspect `git diff --unified=0` across `lib/**/*.ex`, `native/xitdb_nif.odin`, `native/nif_entry.c`, `benchmarks/bench_elixir.exs`, and `benchmarks/bench_client.odin`.
  - Attribute modified hunks to Elixir functions (`def`/`defp` in `lib/`) and Odin NIF procedures (`nif_*` / helpers in `native/xitdb_nif.odin`) and map them to the minimal affected `odin_groups`, `elixir_groups`, and `filter` substrings:
    - `lib/xitdb/cursor.ex`: map `Access` functions (`fetch`/`get_and_update`/`pop`) to `access` + `transactions`, or `Enumerable` functions (`count`/`member?`/`slice`/`reduce`) to `enumerable`.
    - `lib/xitdb/tx_compiler.ex`: map to `transactions` (`#12–#14`).
    - `lib/xitdb/pull.ex`: map to `queries` with `filter="pull"`.
    - `lib/xitdb/selector.ex`: map to `access`, `transactions`, `time_travel`.
    - `lib/xitdb/dsl/**`: map `path_compiler` to `access`, `datalog_compiler` to `queries` (`filter="Datalog"`), `tx_rewriter`/`tx_runtime` to `transactions`.
    - `lib/xitdb/ash/search.ex`: map to `queries` (`filter="BM25|prefix seek"`).
    - `native/xitdb_nif.odin`: map specific `nif_*` procedures (`nif_bm25_search`, `nif_sorted_map_seek`, `nif_pull`, `nif_query_datalog`, `nif_diff_moments`, `nif_history_of`, `nif_compact`, `nif_transact`, `nif_cursor_*`, etc.) to their exact benchmark groups and filters.
- Add CLI flags to `benchmarks/compare_1v1.py`:
  - `--plan [GIT_REF]` (dry-run human-readable execution plan)
  - `--plan-json [GIT_REF]` (JSON execution plan for `update_readme.sh`)
  - `--affected [GIT_REF]` (run only the benchmarks affected by `GIT_REF` or working tree changes)
  - `--lang {odin,elixir,both}` (allow running or comparing either language individually or both)
  - Enhance `--inspect <pattern>` to also list per-run session sample breakdowns (`Run #k (run-...): median=... ns/op, samples=[...]`).

### 2.3 Automated Per-Benchmark Code Slices & NIF Boundary Analysis (`benchmarks/slices/`)
- Add `--generate-slices` and `--code-map-json` to `benchmarks/compare_1v1.py`:
  - **Harness Scanner:** Parse `benchmarks/bench_elixir.exs` and `benchmarks/bench_client.odin` to extract each benchmark's exact `#L<start>-L<end>` line numbers, source snippet, and entry calls (`Xitdb.*` / `Enum.*` / `Xitdb.NIF.*` in Elixir; `xitdb.*` / `bench_raw_bm25_search` in Odin).
  - **Cross-Language Static Call-Graph Tracer:**
    - Parse Elixir functions in `lib/xitdb.ex`, `lib/xitdb/*.ex`, and `lib/xitdb/ash/search.ex` (`def` / `defp` with `#L<start>-L<end>` ranges) and trace calls into `Xitdb.NIF.nif_*`.
    - Parse Odin NIF procedures in `native/xitdb_nif.odin` (`nif_*` entrypoints and helpers with `#L<start>-L<end>` ranges) and trace calls into `native/xitdb-odin/xitdb/*.odin` procedures.
  - **Slice Markdown Generation (`benchmarks/slices/<rank>_<slug>.md` & `benchmarks/slices/README.md`):**
    - Generate 26 per-benchmark slice files (`01_...md` to `26_...md`) and an index page (`benchmarks/slices/README.md`) containing:
      1. **1v1 Statistical Performance Summary** (Elixir NIF Wrapper vs. Raw Odin median, mean±σ, CV%, `p95`, throughput `ops/s`, storage footprint, NIF overhead ratio, and Welch's `z`).
      2. **NIF Boundary & Architectural Analysis** (explaining what crosses the BEAM ↔ Odin NIF boundary for that workload, how `ErlNifResourceType` / 9-byte `Slot` cursors / batch `tx_compiler` / direct `enif_make_*` term construction work, and why the NIF ratio is what it is).
      3. **Side-by-Side Harness Code (`#L<start>-L<end>`)** for Elixir (`bench_elixir.exs`) and Raw Odin (`bench_client.odin`).
      4. **Touched Source Call-Graph Tables (`#L<start>-L<end>`)** across Elixir (`lib/xitdb/**`), Odin NIF (`native/xitdb_nif.odin`), and core `xitdb-odin` (`native/xitdb-odin/xitdb/*.odin`).

### 2.4 Enhanced `benchmarks/update_readme.sh` & `benchmarks/README.md`
- Update `benchmarks/update_readme.sh` to:
  - Invoke `compare_1v1.py --plan-json`, `--generate-slices`, and `--code-map-json`.
  - Render clickable benchmark links in every table row pointing to `bench_elixir.exs#L...`, `bench_client.odin#L...`, and `slices/<slug>.md` (`[🔍 Np](slices/<slug>.md)`).
  - Include **Commit-vs-Commit Progression** when `history.jsonl` contains `>= 2` commits (using the 99% confidence gate: `z >= 2.58`, `med_z >= 2.58`, `|delta_pct| >= 10%`, `|med_b - med_a| >= 5 ns`) and mark selectively re-run benchmarks with `↻`.
  - Preserve all existing records in `benchmarks/history.jsonl`.
  - Ensure all generated Markdown avoids underscores inside `$...$` math blocks per repo Markdown/MathJax rules (use `` `z` `` instead of `$z$`).

---

## 3. Technical Invariants

1. **History Preservation:** `benchmarks/history.jsonl` is strictly append-only; existing historical records must never be truncated or lost.
2. **Submodule Isolation:** `native/xitdb-odin/` is read-only.
3. **Markdown MathJax Safety:** Never output `$z$` or underscored identifiers inside `$...$` in `benchmarks/README.md` or `benchmarks/slices/*.md`; always use inline code spans like `` `z` ``.
4. **Odin & Elixir Cleanliness:** `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb` and `mix precommit` must pass with zero warnings.

---

## 4. Out of Scope

- Porting the 75 low-level internal storage-engine microbenchmarks from `native/xitdb-odin/benchmarks/bench_xitdb.odin` that do not correspond to Elixir client APIs.
- Adding non-Odin comparison baselines (such as ETS, DETS, or Lua).

---

## 5. Acceptance Criteria

1. `benchmarks/bench_elixir.exs` and `benchmarks/bench_client.odin` honor `--runs`, `--warmup`, `--commit`, `--run-id`, `--append`, `--no-history`, `--groups`, and `--filter`, and preserve untouched ranks in `elixir.jsonl` / `odin.jsonl` during selective runs.
2. `./benchmarks/compare_1v1.py --plan` and `./benchmarks/compare_1v1.py --affected` accurately map `git diff` changes in `lib/` and `native/` to affected benchmark groups and filters.
3. `./benchmarks/compare_1v1.py --generate-slices` generates `benchmarks/slices/README.md` and all 26 `benchmarks/slices/<rank>_<slug>.md` files with valid `#L<start>-L<end>` links across `bench_elixir.exs`, `bench_client.odin`, `lib/`, `native/xitdb_nif.odin`, and `native/xitdb-odin/xitdb/`.
4. `./benchmarks/update_readme.sh` updates `benchmarks/README.md` with clickable harness/slice links and statistical tables while preserving `benchmarks/history.jsonl`.
5. `odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb` and `mix precommit` pass with zero errors or warnings.
