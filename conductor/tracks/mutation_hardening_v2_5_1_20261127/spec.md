# Specification: Mutation Testing Hardening (`v2.5.1` Baseline)

## 1. Overview
The full-codebase `v2.5.1` Muex run (`reports/muex/v2.5.1/muex-report.parquet`, commit `d631326`) evaluated `5,620` mutants across `43` files and achieved a `62.23%..62.49%` mutation score (`2,406` killed, `1,450` survived, `488` `no_coverage`, `1,086` invalid, `180` equivalent, `10` timeout).

This track systematically hardens the test suite (and removes confirmed dead/unreachable code discovered via `no_coverage`) across the highest-impact modules, raising every targeted module to **>= 75% mutation score** and lifting the overall repository score from `~62.4%` to **>= 75%**.

## 2. Scoring & Baseline Diagnostics
- **Score formula:** `killed / (killed + survived)` (matching Muex's default; `timeout` is reported separately and `invalid`/`equivalent` are excluded). Covering a previously `no_coverage` line moves its mutants into `killed` or `survived`, increasing the denominator — both score (`>= 75%`) and `no_coverage` reduction are tracked per file.
- **Primary assertion gaps (by mutator):**
  - `Muex.Mutator.Boolean` (`449` survived vs. `405` killed — `47.4%` kill rate): compound guard/branch clauses (`and`/`or`/`||`/`&&`) are not exercised on both sides.
  - `Muex.Mutator.Conditional` (`358` survived vs. `562` killed): `if`/guard branches missing negative/else-path assertions.
  - `Muex.Mutator.StatementDeletion` (`235` survived vs. `362` killed): side effects (index updates, cache invalidation, cleanup) executed without verifying resulting state.
  - `Muex.Mutator.Comparison` (`229` survived vs. `339` killed): missing exact boundary tests (`0`, `1`, `n - 1`, `n`, `n + 1`).
- **Top concentration:** Six modules (`cursor.ex`, `ash/query.ex`, `ash/mutator.ex`, `ash/indexer.ex`, `ash/search.ex`, `ash/store.ex`) account for `908 / 1,450` (`62.6%`) of all survived mutants and `254 / 488` (`52.0%`) of all `no_coverage` mutants.
- **Known caveats:**
  - `lib/xitdb/compression.ex` (`31.91%`) contains `177 / 180` of the repo's `equivalent` mutants (shrink-guard heuristics that still round-trip identically); its real gap is `32` survived + `21` `no_coverage`.
  - `lib/xitdb/dsl.ex` (`0%`, `14` survived) consists of compile-time macros (`defmacro` / expansion helpers). Because Muex hot-swaps BEAM modules without recompiling test files that already expanded those macros at compile time, killing those mutants requires runtime `Macro.expand` / `Code.eval_quoted` tests or testing extracted pure helper functions directly.

## 3. Functional Requirements
1. **Phased Module Hardening:** Work module-by-module in four ordered phases covering `19` high-impact modules (Concurrency/Lifecycle -> Small Pure/Compiler -> Core Cursor/Client/Columnar -> Ash Data Layer & Sandbox) so hitting `>= 75%` per targeted module mathematically pushes the overall repo score past `75%`.
2. **Test Placement:** Place new tests where they naturally fit — focused ExUnit unit tests for internal modules (`pull`, `selector`, `cache_owner`, `dsl/path_compiler`, `ash/test_sandbox`, etc.) and 4-layer ATDD specs (`test/features/*_spec.exs`) for user-facing behaviors.
3. **Dead Code Removal:** For `no_coverage` mutants, either add a test exercising the intended behavior or remove confirmed dead/unreachable code from `lib/` when it has no valid caller or semantic purpose.
4. **No Success-Shaped Fallbacks:** Any production code changes must continue to adhere to `Xitdb.Fallback` and `Credo.Check.Warning.NoBusinessLogicRescue`.
5. **Deterministic Verification:** Verify each module with targeted `mix muex --files "<file>" --test-paths "<test_file>" --mirror native --no-filter` (or `--coverage-guided --preset ash` with `:tools` started for multi-file runs) and `mix precommit`.

## 4. Acceptance Criteria
- [ ] Every targeted module across Phases 1–4 reaches **>= 75% mutation score** (`killed / (killed + survived)`), with `lib/xitdb/dsl.ex` verified via runtime macro-expansion / helper tests.
- [ ] Overall repository mutation score improves from `62.23%..62.49%` to **>= 75%**.
- [ ] All confirmed dead/unreachable `no_coverage` paths in targeted modules are either covered by tests or removed.
- [ ] `mix precommit` and `mix credo --strict` pass with zero warnings.

## 5. Out of Scope
- Rewriting `lib/xitdb/compression.ex` shrink-guard heuristics solely to eliminate `equivalent` mutants.
- Modifying `native/xitdb_nif.odin` or `native/xitdb-odin/` unless a real bug is uncovered by a new test.
- Adding tests for `0`-mutant schema/DSL definition files (`ash/dsl.ex`, `ash/index.ex`, `ash/reference.ex`, `ash/search_field.ex`, `ash/compress.ex`, `ash/lease_error.ex`).
