# Development Workflow: `xitdb` Elixir Client

## 1. Red-First 4-Layer ATDD Loop
1. **Write or update a client scenario** in Layer 1 (`test/features/*_spec.exs`) using `@given`, `@upon`, and `@then`.
2. **Bridge domain steps** in Layer 2 (`test/support/dsl/client_dsl.ex`) and Layer 3 (`test/support/drivers/client_driver.ex`).
3. **Run targeted test** (`mix test test/features/<file>_spec.exs:<line>`) to confirm Red failure when building new features.
4. **Implement NIF / Elixir functionality** in `native/` and `lib/` until Green.
5. **Run `mix precommit`** (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`) and verify zero warnings and zero leaks.

## 2. Native Odin NIF Safety Rules
- Always initialize `context = runtime.default_context()` at the start of every `proc "c"` NIF function in `native/xitdb_nif.odin`.
- Always `defer free_all(context.temp_allocator)` inside every `proc "c"` entrypoint so scratch allocations never accumulate across BEAM scheduler calls.
- Free all heap-allocated `xitdb` structs (`tx_destroy`, `tx_report_destroy`, `core_destroy`) inside their scope or `ErlNifResourceType` destructor callback.

## 3. Client 1v1 Benchmark Verification
- Run `./benchmarks/compare_1v1.py --run` to execute both the Raw Odin client benchmark binary (`benchmarks/bench_client.odin`) and the Elixir wrapper benchmark script (`benchmarks/bench_elixir.exs`), outputting `benchmarks/odin.jsonl` and `benchmarks/elixir.jsonl`.
- Run `./benchmarks/update_readme.sh` to regenerate statistical comparison tables in `benchmarks/README.md`.
