# Product Guidelines: `Xitdb` Elixir Client

## 1. Idiomatic Elixir Library Standards
- **No Global Configuration (`Application.get_env/3`):** All configuration (`path`, `backend: :memory | :file | :buffered_file`, `hash: :sha1 | :sha256`, `name`) is passed explicitly via `opts` to `Xitdb.open/1` or `Xitdb.start_link/1` and validated with compile-time `NimbleOptions`.
- **Caller-Supervised Lifecycles:** Provide `Xitdb.child_spec/1` so host applications and `async: true` tests (`start_supervised!/1`) supervise database instances without singleton name collisions.
- **Structured Exceptions (`Xitdb.Error`):** Return `{:ok, result} | {:error, %Xitdb.Error{}}` alongside bang variants (`open!/1`, `transact!/2`, `select!/2`, `pull!/3`, `query!/3`, `compact!/2`).
- **Observability via `:telemetry`:** Emit `:telemetry.span/3` events (`[:xitdb, :transact]`, `[:xitdb, :query]`, `[:xitdb, :compact]`) rather than logging directly.
- **LLM & Agent Documentation (`usage-rules.md`):** Ship `usage-rules.md` in the Hex package alongside `README.md` and `AGENTS.md`.

## 2. 4-Layer Client ATDD Specification Architecture
We test `Xitdb` strictly as a **client library** (never duplicating internal Odin B-Tree/HAMT node-splitting unit tests):
- **Layer 1: Executable Specifications (`test/features/*_spec.exs`)** — Express client workflows using `@given`, `@upon`, and `@then` scenario pipelines (`Xitdb.FeatureCase`) and property-based round-trip invariants (`ExUnitProperties`). Zero raw slot offsets or NIF plumbing in Layer 1.
- **Layer 2: Domain-Specific Language (`test/support/dsl/*_dsl.ex`)** — Translates client domain steps into protocol driver calls and enforces cross-cutting client invariants (e.g., verifying that lazy `Access` navigation, selector queries, and `Xitdb.materialize/1` agree).
- **Layer 3: Protocol Drivers (`test/support/drivers/*_driver.ex`)** — Isolates `Xitdb` API calls, NIF resource lifecycle, and temporary database file cleanup.
- **Layer 4: System Under Test (`lib/` & `native/`)** — The Elixir client library and Odin C-ABI NIF wrapper.

## 3. Client-Focused 1v1 Statistical Benchmark Suite (`benchmarks/`)
- Compare **Elixir Client Wrapper (`lang: "elixir"`)** directly against **Raw Odin (`lang: "odin"`)** on client-facing workloads (nested `Access` lookups, `Enumerable` count/member?/slice/stream, subtree materialization, batch transactions, time-travel `as_of`, Pull projections, `diff_moments`, `history_of`, Datalog queries, and compaction).
- Emit identical JSONL statistical records (`benchmarks/elixir.jsonl`, `benchmarks/odin.jsonl`, `benchmarks/history.jsonl`) and use `benchmarks/compare_1v1.py` + `benchmarks/update_readme.sh` with Welch's $z$-score significance testing to quantify NIF/BEAM wrapper overhead vs. raw native Odin execution.
