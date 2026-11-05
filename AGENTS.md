# AGENTS.md — `elixir/xitdb` Repository Guide

This document provides the architecture, build/test/benchmark commands, and development rules for coding agents working on `elixir/xitdb`.

---

## Repository Overview & Architecture

- **`lib/`** — Elixir client library (`Xitdb`):
  - [`lib/xitdb.ex`](lib/xitdb.ex): Top-level `%Xitdb{}` struct, lifecycle (`open/1`, `close/1`, `sync/1`, `info/1`, `compact/2`), snapshots (`db/1`, `as_of/2`), transactions (`transact/3`, `insert_at/4`, `delete_at/3`, `fork/3`), queries (`select/2`, `pull/2`, `diff_moments/3`, `history_of/2`, `query/3`), and `Access` delegation.
  - [`lib/xitdb/cursor.ex`](lib/xitdb/cursor.ex): Lazy 9-byte `Slot` cursor (`%Xitdb.Cursor{}`) implementing `Access`, `Enumerable`, and `Inspect`.
  - [`lib/xitdb/collection.ex`](lib/xitdb/collection.ex): Explicit collection wrappers (`counted_map`, `sorted_map`, `linked_list`, `hash_set`, `counted_set`, `sorted_set`).
  - [`lib/xitdb/dsl.ex`](lib/xitdb/dsl.ex): Compile-time macro DSL for path selectors (`path/1`), declarative transactions (`tx/2,3`, `tx!/2,3`, `tx_for/3,4`, `tx_for!/3,4`), Pull patterns (`pull_pattern/1`), and Datalog queries (`datalog/1`, `query/2,3`, `query!/2,3`).
  - [`lib/xitdb/ash/`](lib/xitdb/ash/): Spark DSL extension (`Xitdb.Ash.Resource`), introspection (`Xitdb.Ash.Info`), transformer (`Xitdb.Ash.Transformers.WireChanges`), verifier (`Xitdb.Ash.Verifiers.VerifySyncProjection`), and transaction macro (`Xitdb.Ash.Tx`).
  - [`lib/xitdb/pull.ex`](lib/xitdb/pull.ex): Structural Pull pattern compiler (`Xitdb.Pull.compile/1`, `Xitdb.Pull.compile!/1`).
  - [`lib/xitdb/tx_compiler.ex`](lib/xitdb/tx_compiler.ex): Compiles nested Elixir maps, collections, and staged `put_in`/`update_in`/`pop_in` cursor edits into coarse-grained NIF transaction operations.
  - [`lib/xitdb/sigils.ex`](lib/xitdb/sigils.ex): Compile-time validated `~x` (selector) and `~q` (Datalog) sigils.
  - [`lib/xitdb/nif.ex`](lib/xitdb/nif.ex): `@on_load` loader for `priv/xitdb_nif.so`.
- **`docs/`** — Dedicated reference guides:
  - Core concepts & protocols: [`docs/access-and-enumerable.md`](docs/access-and-enumerable.md), [`docs/collections-and-indexing.md`](docs/collections-and-indexing.md), [`docs/time-travel-and-storage.md`](docs/time-travel-and-storage.md).
  - Macro DSLs & query languages: [`docs/path-and-pull-dsl.md`](docs/path-and-pull-dsl.md), [`docs/transaction-dsl.md`](docs/transaction-dsl.md), [`docs/datalog-dsl.md`](docs/datalog-dsl.md), [`docs/ash-and-spark.md`](docs/ash-and-spark.md).
- **`native/`** — C-ABI Erlang NIF shim & Odin NIF implementation:
  - [`native/nif_entry.c`](native/nif_entry.c): Thin C shim exporting `ERL_NIF_INIT` and wrapping `ErlNifResourceType` / `ErlNifRWLock` callbacks for Odin.
  - [`native/xitdb_nif.odin`](native/xitdb_nif.odin): Odin NIF procedures bridging `ErlNifEnv` terms to `xitdb`.
  - `native/xitdb-odin/`: Git submodule tracking `git@github.com:boxxxie/odin-xitdb.git`.
- **`test/`** — 4-Layer Client ATDD Executable Specification Suite:
  - Layer 1 (`test/features/*_spec.exs`, `test/features/*_test.exs`): Domain specifications and `StreamData` property tests.
  - Layer 2 ([`test/support/dsl/client_dsl.ex`](test/support/dsl/client_dsl.ex) & [`test/support/feature_case.ex`](test/support/feature_case.ex)): `@given`, `@upon`, `@then` macro DSL.
  - Layer 3 ([`test/support/drivers/client_driver.ex`](test/support/drivers/client_driver.ex)): Protocol driver isolating `Xitdb` calls and assertions.
- **`benchmarks/`** — 1v1 Client Statistical Benchmark Suite (Elixir Wrapper vs. Raw Odin):
  - [`benchmarks/bench_elixir.exs`](benchmarks/bench_elixir.exs): Elixir client benchmark runner (`benchmarks/elixir.jsonl`).
  - [`benchmarks/bench_client.odin`](benchmarks/bench_client.odin): Equivalent Raw Odin client baseline (`benchmarks/odin.jsonl`).
  - [`benchmarks/compare_1v1.py`](benchmarks/compare_1v1.py) & [`benchmarks/update_readme.sh`](benchmarks/update_readme.sh): Statistical Welch's $z$-test analyzer and Markdown table generator.

---

## Build, Check, Test & Benchmark Commands

```bash
# 1. Typecheck Odin NIF and Odin client benchmark packages
odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb
odin check benchmarks -collection:xitdb=native/xitdb-odin/xitdb

# 2. Run full Elixir precommit verification (format, compile --warnings-as-errors, test)
mix precommit

# 3. Run the 4-layer ATDD specification suite with trace
mix test --trace

# 4. Run the 1v1 Client Statistical Benchmark Suite and update benchmarks/README.md
./benchmarks/compare_1v1.py --runs 5 --warmup 1
./benchmarks/update_readme.sh
```

---

## Coding & Testing Rules

- **Read [`usage-rules.md`](usage-rules.md) First**: Follow all lazy cursor, `Enumerable` fast-path, and transaction batching conventions.
- **Zero Warnings & Clean Formatting**: Always ensure `mix precommit` passes with zero warnings.
- **Odin NIF Memory Hygiene**: Every NIF entrypoint in [`native/xitdb_nif.odin`](native/xitdb_nif.odin) that uses `context.temp_allocator` must call `defer free_all(context.temp_allocator)` before returning to the BEAM scheduler.
- **4-Layer Client ATDD Architecture**: Add new behavioral tests as scenarios in `test/features/*_spec.exs` using `@given`, `@upon`, and `@then` steps wired through `Xitdb.TestDSL.ClientDSL` and `Xitdb.TestDrivers.ClientDriver`.
