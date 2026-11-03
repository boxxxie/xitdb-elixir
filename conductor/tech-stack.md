# Tech Stack: `xitdb` Elixir Client

- **Host Language & Runtime:** Elixir `~> 1.18` (tested on Elixir 1.19.6 / Erlang/OTP 28 `[erts-16.4]`)
- **Native Engine Submodule:** [`native/xitdb-odin`](../native/xitdb-odin) (`git@github.com:boxxxie/odin-xitdb.git`, pure-Odin `v1` wire implementation)
- **FFI / NIF Bridge:**
  - `native/xitdb_nif.odin` (`package xitdb_nif`, compiled with `odin build ... -build-mode:obj -collection:xitdb=native/xitdb-odin/xitdb -o:speed`)
  - `native/nif_entry.c` (`<erl_nif.h>` C-ABI bridge and `ErlNifResourceType` lifecycle, linked into `priv/xitdb_nif.so`)
  - Custom Mix compiler task `Mix.Tasks.Compile.OdinNif` in [`mix.exs`](../mix.exs)
- **Core Elixir Dependencies:**
  - `nimble_options` (`~> 1.1`) — Compile-time option validation
  - `telemetry` (`~> 1.3`) — Span instrumentation
  - `stream_data` (`~> 1.1`, `:test` only) — Property-based testing (`ExUnitProperties`)
  - `ex_doc` (`~> 0.34`, `:dev` only) — Documentation generation
- **Test Architecture:** 4-Layer ATDD Suite (`ExUnit` + `Xitdb.FeatureCase` `@given`/`@upon`/`@then` scenarios + `ExUnitProperties`)
- **Benchmarking Harness:** Statistical multi-sample JSONL runner (`benchmarks/bench_elixir.exs` vs. `benchmarks/bench_client.odin`), `benchmarks/compare_1v1.py` (Welch's $t$/$z$-test, p50/p95/p99, IQR, CV%), and `benchmarks/update_readme.sh`.
