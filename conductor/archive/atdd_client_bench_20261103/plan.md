# Implementation Plan: `atdd_client_bench_20261103`

## Phase 1: Project Scaffolding & `xitdb-odin` Submodule
- [x] Task: Initialize Mix project (`elixir/xitdb`) and add `native/xitdb-odin` git submodule.
  - [x] Configure `mix.exs` with `Mix.Tasks.Compile.OdinNif`, `elixirc_paths`, `nimble_options`, `telemetry`, `stream_data`, and `ex_doc`.
  - [x] Add `ols.json` mapping `xitdb` collection to `native/xitdb-odin/xitdb`.

## Phase 2: 4-Layer ATDD Test Architecture (`test/`)
- [x] Task: Implement `Xitdb.FeatureCase` (`@given` / `@upon` / `@then` scenario macro), Layer 2 `Xitdb.TestDSL.ClientDSL`, and Layer 3 `Xitdb.TestDrivers.ClientDriver`.
  - [x] Write Layer 1 specs in `test/features/lazy_access_navigation_spec.exs`.
  - [x] Write Layer 1 specs in `test/features/enumerable_collections_spec.exs`.
  - [x] Write Layer 1 specs in `test/features/transactions_and_time_travel_spec.exs`.
  - [x] Write Layer 1 specs in `test/features/queries_and_datalog_spec.exs`.
  - [x] Write Layer 1 property invariants in `test/features/client_roundtrip_properties_test.exs`.

## Phase 3: Client-Focused 1v1 Benchmark Suite (`benchmarks/`)
- [x] Task: Build Raw Odin client benchmark baseline (`benchmarks/bench_client.odin`) and Elixir wrapper benchmark runner (`benchmarks/bench_elixir.exs`).
  - [x] Implement 16 client-relevant benchmarks emitting identical JSONL statistical schemas (`benchmarks/odin.jsonl`, `benchmarks/elixir.jsonl`, `benchmarks/history.jsonl`).
  - [x] Implement `benchmarks/compare_1v1.py` and `benchmarks/update_readme.sh` comparing Elixir Wrapper vs. Raw Odin with overhead ratios and Welch's $z$-scores.
  - [x] Verify `mix test` and `./benchmarks/compare_1v1.py` execute end-to-end cleanly.
