# Specification: Automated Host-Load, Canary & Skew Contention Guardrails in `compare_1v1.py`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `bench_contention_and_canary_guardrails_20261115`
> - **Type:** Chore / Benchmark Tooling
> - **Target Repository:** `elixir/xitdb`
> - **Primary Files:** `benchmarks/compare_1v1.py`, `benchmarks/README.md`
> - **Done When:** `benchmarks/compare_1v1.py` samples 1-minute host load average during runs and records `median_min_ratio` per benchmark row, automatically prints `[CONTENTION WARNING]` banners when load, canary drift, or variance thresholds are tripped, supports `--require-clean` to protect `benchmarks/*.jsonl` from contended overwrites, and is documented cleanly in `benchmarks/README.md`.

---

## 1. Goal & Motivation

Comparing the rejected contended run (`run-1794746326`, host load `6.3–12.0`) against `run-1794747522` (host load `1.7`) demonstrated that single-number Elixir/Odin ratios can severely mislead under CPU contention:
- Unmodified fast-path canary `#4` (`Array_List` lookup) degraded `4.7x` in Raw Odin (`513 ns` vs. `125 ns`),
- Odin `#14` spiked to `89.4%` CV (`23.89 µs` median vs. `5.54 µs` min), artificially compressing the Elixir/Odin ratio to `1.13x`,
- Whereas clean runs show `CV 0.2%–1.6%` and `median_ns` within `0.3%–1.5%` of `min_ns`.

Today, detecting contended runs requires manual inspection. Encoding these guardrails directly into `benchmarks/compare_1v1.py` guarantees reproducible benchmark hygiene before updating baselines.

---

## 2. Functional Requirements

1. **Run-Quality Telemetry:**
   - Capture `os.getloadavg()[0]` (1-minute load average) before and after running `Raw Odin` and `Elixir` (`sample_loadavg_1m`), and record `median_min_ratio` (`median_ns / max(min_ns, 1e-9)`) per benchmark record in JSONL summaries without breaking `update_readme.sh`.
2. **Automated Contention & Canary Detection:**
   - Check three orthogonal contention signals at the end of a run:
     - **Host Load:** `load_avg_1m > 4.0` (configurable or scaled cleanly),
     - **Fast-Path Canaries (`#3–#6`):** median slows by `> 1.5x` relative to historical clean baseline medians in `benchmarks/history.jsonl`,
     - **Sample Skew / Variance:** in-memory (`Core_Memory`, non-sync `#24`) workloads showing `cv_pct > 15.0%` or `median_ns / min_ns > 1.25` (excluding sub-50 ns clock-quantized timer tests like `#6` Odin at `7 ns`).
   - Print a clear `[CONTENTION WARNING]` report naming every tripped benchmark and metric.
3. **Optional Baseline Protection (`--require-clean`):**
   - When `--require-clean` is passed and contention is detected, exit non-zero without overwriting `benchmarks/odin.jsonl`, `benchmarks/elixir.jsonl`, or appending to `benchmarks/history.jsonl`.

---

## 3. Technical Invariants

1. **Backwards JSONL & `jq` Schema Compatibility:** `benchmarks/update_readme.sh` continues parsing `benchmarks/odin.jsonl`, `benchmarks/elixir.jsonl`, and `benchmarks/history.jsonl` with zero schema breakage.
2. **Portable Python Stdlib Only:** Use Python 3 stdlib (`os`, `statistics`, `json`, `argparse`) with zero external pip dependencies.
