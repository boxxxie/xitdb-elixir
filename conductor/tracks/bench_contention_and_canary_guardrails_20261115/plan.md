# Implementation Plan: Automated Host-Load, Canary & Skew Contention Guardrails in `compare_1v1.py`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `bench_contention_and_canary_guardrails_20261115`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `elixir/xitdb`
> - **Done When:** `compare_1v1.py` captures host load & skew telemetry, emits clear `[CONTENTION WARNING]` diagnostics on contended runs, supports `--require-clean` before persisting JSONL results, and is verified + documented.

---

## Phase 1: Host Load & Skew Telemetry

- [x] **1.1** Sample 1-minute load average (`os.getloadavg()[0]`) before and after benchmark phases (`sample_loadavg_1m`) and compute `median_min_ratio` in `summarize_samples` inside `benchmarks/compare_1v1.py`
  - Record `median_min_ratio` in JSONL rows safely without breaking `update_readme.sh`.
- [x] **1.2** Compute per-workload `median_ns / min_ns` skew alongside `cv_pct` in comparison summaries.

---

## Phase 2: Canary Checks, Contention Detector & `--require-clean` Gate

- [x] **2.1** Add clean canary baseline lookup (`#3–#6`) from `benchmarks/history.jsonl` (ignoring `-dirty` or noisy historical runs) and flag `> 1.5x` slowdown on fast-path canaries.
- [x] **2.2** Flag in-memory benchmarks with `CV > 15%` or `median_ns / min_ns > 1.25` (respecting sub-50 ns timer quantization floors) in a `[CONTENTION WARNING]` summary, and add `--require-clean` to abort before mutating `odin.jsonl`, `elixir.jsonl`, or `history.jsonl`.

---

## Phase 3: Verification & Docs

- [x] **3.1** Verify `--help`, dry-run / filtered `--filter "Array_List random|Enum.count" --runs 3 --warmup 1`, and `--require-clean` behavior, and document `--require-clean` in `benchmarks/README.md`.
