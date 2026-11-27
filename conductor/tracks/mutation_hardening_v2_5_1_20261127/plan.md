# Implementation Plan: Mutation Testing Hardening (`v2.5.1` Baseline)

Baseline source: `reports/muex/v2.5.1/muex-report.parquet` & `reports/muex/v2.5.1/summary_by_file.tsv`.

### Helper Commands
Query surviving and uncovered mutants for any target file:
```bash
duckdb -dark-mode -c "
SELECT line, status, mutator, description, patch_before, patch_after
FROM 'reports/muex/v2.5.1/muex-report.parquet'
WHERE file = '<file>' AND status IN ('survived', 'no_coverage')
ORDER BY line;
"
```

Targeted verification (fast, single module + matching test file, per `AGENTS.md`):
```bash
mix muex --files "<file>" --test-paths "<test_file>" --mirror native --no-filter
```

Multi-file / coverage-guided verification (when a module is exercised across many test files):
```bash
mix do run -e "Application.ensure_all_started(:tools)" + muex \
  --files "<file>" --mirror native --coverage-guided --preset ash
```

---

## Phase 1: High-Risk Concurrency & Lifecycle

- [x] Task: Harden `lib/xitdb/ash/store.ex` (`47.59%` -> `>= 75%`; verified **`75.84%`**)
    - [x] Query surviving and `no_coverage` mutants in `lib/xitdb/ash/store.ex`
    - [x] Add unit/integration tests for compound guards, error/lease branches, and state side effects; remove confirmed dead code
    - [x] Verify with targeted `mix muex` (`>= 75%`) and `mix precommit`
- [x] Task: Harden `lib/xitdb/ash/store/snapshot.ex` (`64.86%` -> `>= 75%`; verified **`78.02%`**) and `lib/xitdb/ash/store/lease_queue.ex` (`53.85%` -> `>= 75%`; verified **`91.43%`**)
    - [x] Query surviving and `no_coverage` mutants in both store helper modules
    - [x] Add unit tests for snapshot boundaries and lease queue ordering/timeout/cancellation paths
    - [x] Verify with targeted `mix muex` (`>= 75%`)
- [x] Task: Harden `lib/xitdb/cache_owner.ex` (`40.00%` -> `>= 75%`; verified **`80.39%..84.31%`**)
    - [x] Query surviving and `no_coverage` mutants in `lib/xitdb/cache_owner.ex` (accounting for `f190925` fallback updates)
    - [x] Add unit tests for ETS ownership, heir handoff, and cleanup side effects; remove confirmed dead code
    - [x] Verify with targeted `mix muex` (`>= 75%`) and `mix precommit`

---

## Phase 2: Small Pure, Parser & Compiler Modules (Quick Wins)

- [x] Task: Harden `lib/xitdb/pull.ex` (`37.04%` -> `>= 75%`; verified **`96.43%`**)
    - [x] Query surviving mutants and add unit tests covering pull pattern edge cases, boundaries, and invalid inputs
    - [x] Verify with targeted `mix muex` (`>= 75%`)
- [x] Task: Harden `lib/xitdb/selector.ex` (`49.12%` -> `>= 75%`; verified **`86.96%..89.86%`**)
    - [x] Query surviving and `no_coverage` mutants; add unit tests for escaping, parsing, and formatting edge cases
    - [x] Verify with targeted `mix muex` (`>= 75%`)
- [x] Task: Harden `lib/xitdb/dsl/path_compiler.ex` (`40.00%` -> `>= 75%`; verified **`88.37%`**) and `lib/xitdb/dsl.ex` (`0%` -> `>= 75%`; verified **`80.56%`**)
    - [x] Query surviving and `no_coverage` mutants in `path_compiler.ex` and `dsl.ex`
    - [x] Add unit tests for `path_compiler.ex`; for `dsl.ex` compile-time macros (`expand_query_2`, `eval_static_pull_ast`, etc.), add runtime `Macro.expand` / `Code.eval_quoted` tests or test extracted pure helpers directly so Muex hot-swapped BEAM modules are exercised
    - [x] Verify with targeted `mix muex` (`>= 75%`) and `mix precommit`

---

## Phase 3: Core Cursor, Client, Tx Compiler & Columnar

- [x] Task: Harden `lib/xitdb/cursor.ex` — Step A: `no_coverage` audit (`87` no_cov)
    - [x] Audit all `87` `no_coverage` mutants in `lib/xitdb/cursor.ex`; add tests for real uncovered behaviors and delete confirmed unreachable branches
- [ ] Task: Harden `lib/xitdb/cursor.ex` — Step B: survivor hardening (`57.06%` -> `>= 75%`; `213` survived)
    - [ ] Kill `Boolean`, `Conditional`, `Comparison`, and `StatementDeletion` survivors across `Access`, `Enumerable`, and navigation paths
    - [ ] Verify with coverage-guided `mix muex` (`>= 75%`)
- [ ] Task: Harden `lib/xitdb.ex` (`68.52%` -> `>= 75%`; `68` survived, `17` no_cov)
    - [x] Audit `17` `no_coverage` mutants and add missing lifecycle/query/transaction edge-case tests
    - [ ] Verify with coverage-guided `mix muex` (`>= 75%`)
- [x] Task: Harden `lib/xitdb/columnar.ex` (`64.29%` -> `>= 75%`; verified **`86.25%`**) and `lib/xitdb/tx_compiler.ex` (`65.96%` -> `>= 75%`; verified **`80.77%`**)
    - [x] Query surviving and `no_coverage` mutants in both modules; add boundary and compilation-error tests
    - [x] Verify with targeted `mix muex` (`>= 75%`) and `mix precommit`

---

## Phase 4: Ash Data Layer Core & Test Sandbox

- [x] Task: Harden `lib/xitdb/ash/test_sandbox.ex` (`35.00%` -> `>= 75%`; verified **`75.24%`**)
    - [x] Query surviving mutants; add unit tests for checkout/checkin, isolation, ownership, and cleanup edge cases
    - [x] Verify with targeted `mix muex` (`>= 75%`)
- [ ] Task: Harden `lib/xitdb/ash/query.ex` — Step A: `no_coverage` audit (`73` no_cov)
    - [ ] Audit all `73` `no_coverage` mutants in `lib/xitdb/ash/query.ex`; cover real branches or remove dead code
- [ ] Task: Harden `lib/xitdb/ash/query.ex` — Step B: survivor hardening (`58.59%` -> `>= 75%`; `197` survived)
    - [ ] Kill filter, sort, limit/offset boundary, and compound boolean-guard survivors
    - [ ] Verify with coverage-guided `mix muex` (`>= 75%`)
- [ ] Task: Harden `lib/xitdb/ash/mutator.ex` — Step A: `no_coverage` audit (`65` no_cov)
    - [ ] Audit all `65` `no_coverage` mutants in `lib/xitdb/ash/mutator.ex`; cover real branches or remove dead code
- [ ] Task: Harden `lib/xitdb/ash/mutator.ex` — Step B: survivor hardening (`58.81%` -> `>= 75%`; `187` survived)
    - [ ] Kill create/update/destroy/bulk side-effect (`StatementDeletion`) and guard survivors
    - [ ] Verify with coverage-guided `mix muex` (`>= 75%`)
- [ ] Task: Harden `lib/xitdb/ash/indexer.ex` (`58.80%` -> `>= 75%`; `124` survived, `8` no_cov)
    - [ ] Kill index maintenance, range-key, and cleanup side-effect survivors
    - [ ] Verify with coverage-guided `mix muex` (`>= 75%`)
- [ ] Task: Harden `lib/xitdb/ash/search.ex` (`71.61%` -> `>= 75%`; `111` survived, `11` no_cov), `lib/xitdb/ash/codec.ex` (`67.01%` -> `>= 75%`; verified **`75.47%`**), and `lib/xitdb/ash/data_layer.ex` (`70.59%` -> `>= 75%`; `15` survived, `12` no_cov)
    - [x] Kill remaining high-value survivors in `codec.ex` (verified `75.47%`), `search.ex`, and `data_layer.ex`
    - [ ] Verify remaining modules with coverage-guided `mix muex` (`>= 75%`) and `mix precommit`

---

## Phase 5: Final Verification

- [ ] Task: Run full quality & mutation verification
    - [ ] Run `mix precommit` and `mix credo --strict`
    - [ ] Run updated full-repo Muex verification (local or Hetzner runner with `--coverage-guided --preset ash`) and confirm overall score `>= 75%`
