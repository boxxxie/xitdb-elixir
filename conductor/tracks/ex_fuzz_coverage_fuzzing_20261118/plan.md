# Implementation Plan: Integrate `ExFuzz` Coverage-Guided Fuzz Testing

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ex_fuzz_coverage_fuzzing_20261118`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** `ex_fuzz` (`~> 0.1.0`, `only: [:dev, :test]`) is integrated, all three fuzz target suites (`parsers_and_codecs_fuzz_test.exs`, `nif_boundary_and_search_fuzz_test.exs`, `cursor_state_machine_fuzz_test.exs`) run under `mix fuzz` and `mix test`, all Elixir crashes/parity bugs uncovered in initial fuzzing are fixed with regression seeds in `test/fixtures/fuzz/`, and `mix precommit` passes with zero warnings.

---

## Phase 1: Dependency Setup, Compatibility Check & Harness Smoke Test

- [ ] Task: Add `ex_fuzz` dependency and configuration in `mix.exs`
    - [ ] Add `{:ex_fuzz, "~> 0.1.0", only: [:dev, :test]}` to `deps/0` in `mix.exs` and run `mix deps.get`
    - [ ] Configure `ex_fuzz: [corpus_dir: "test/fixtures/fuzz", cache_dir: "_build/ex_fuzz/corpus", crash_dump_dir: "_build/ex_fuzz"]` in `project/0` (confirming `_build/` ignores cache/dumps while `test/fixtures/fuzz/` is tracked)
    - [ ] Verify precompiled `ExFuzz.Engine` NIF loading and `:peer` worker startup against the repo's Erlang/OTP runtime and `test/test_helper.exs` (`Xitdb.Cursor.register_beam_tracer/0`, `Xitdb.Ash.TestSandbox`)
- [ ] Task: Benchmark startup `ExFuzz.Scope.modules/1` instrumentation cost across `:xitdb` and optional `:ash`/`:spark` deps
    - [ ] Confirm a minimal smoke `fuzz` test runs cleanly with both `mix test --only fuzz` (replay mode) and `mix fuzz <file>:<line> --max-runs 1000` (fuzz mode)
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Dependency Setup, Compatibility Check & Harness Smoke Test' (Protocol in workflow.md)

---

## Phase 2: Core Elixir Parsers, Escapers & Codecs (`parsers_and_codecs_fuzz_test.exs`)

- [ ] Task: Write fuzz targets in `test/fuzz/parsers_and_codecs_fuzz_test.exs` (`async: true`)
    - [ ] Add `fuzz` target for `Xitdb.Selector.parse_selector_steps/2`, `normalize_root_or_steps/1`, and `format_step/2` round-trip invariants (no non-`ArgumentError` crashes or hangs)
    - [ ] Add `fuzz` target for `Xitdb.Sigils.validate_selector!/1` and `validate_datalog!/1` checking `ArgumentError`-only failure behavior and delimiter consistency with `Selector`
    - [ ] Add `fuzz` target for `Xitdb.Pull.compile/1` and `Pull.split_wildcard_plan/1`
    - [ ] Add `fuzz` target for `Xitdb.Ash.Search.tokenize/1` across arbitrary raw binaries / malformed UTF-8 / NUL bytes
    - [ ] Add `fuzz` target for `Xitdb.Ash.Codec` (`encode_doc_id/1`, `decode_doc_id/2`, and composite `encode_index_key/2` order preservation & NUL-escaping collision freedom)
- [ ] Task: Run initial bounded `mix fuzz` campaigns for Group 1 and fix uncovered Elixir defects
    - [ ] Run `mix fuzz` (`--max-time 30000` / `--max-runs 50000` per target) across all Group 1 targets
    - [ ] Fix `Xitdb.Ash.Search.tokenize/1` handling of non-UTF-8 inputs (`:unicode.characters_to_nfc_binary/1` error/incomplete tuples) and any `Selector`/`Sigils`/`Pull`/`Codec` crashes found
    - [ ] Ensure every discovered failing input saved in `test/fixtures/fuzz/` passes once the fix is applied
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Core Elixir Parsers, Escapers & Codecs' (Protocol in workflow.md)

---

## Phase 3: NIF Boundary & `:nif` vs `:elixir` Search Parity (`nif_boundary_and_search_fuzz_test.exs`)

- [ ] Task: Write NIF boundary and search parity fuzz targets in `test/fuzz/nif_boundary_and_search_fuzz_test.exs`
    - [ ] Add `fuzz` target exercising `Xitdb.select/2`, `Xitdb.pull/3`, `Xitdb.query/3`, `Xitdb.history_of/2`, and `Xitdb.transact_ops/2` with fuzzed binaries against an isolated `:memory` database (closed in `after`), asserting `{:ok, _}` / `{:error, %Xitdb.Error{}}` / `ArgumentError` only
    - [ ] Add `fuzz` target indexing byte-derived document strings into an isolated `:memory` Ash store and verifying exact result/rank parity between `Xitdb.Ash.Search.query(..., backend: :nif)` and `backend: :elixir`
- [ ] Task: Run bounded `mix fuzz` campaigns for Group 2 and resolve discrepancies
    - [ ] Run `mix fuzz` across Group 2 targets (`--max-time 30000` per target), checking for Elixir boundary crashes, parity mismatches, timeouts, or worker `:node_down` events
    - [ ] Fix any Elixir-side validation, error-wrapping, or `:nif`/`:elixir` parity discrepancies discovered (and verify regression corpus entries)
- [ ] Task: Conductor - User Manual Verification 'Phase 3: NIF Boundary & Search Backend Parity' (Protocol in workflow.md)

---

## Phase 4: Bytecode-Driven Stateful `Cursor` / `Tx` Fuzzing (`cursor_state_machine_fuzz_test.exs`)

- [ ] Task: Implement deterministic bytecode-to-operation interpreter and reference oracle
    - [ ] Decode `data <- binary()` into bounded `Xitdb` operations (`put_in`/`update_in`/`pop_in`, `transact_ops` map/list ops, `rm`, `as_of`, `diff_moments`, `compact`) paired with an Elixir reference map history oracle
    - [ ] Assert consistency across `Access`, `Xitdb.select/2`, `Xitdb.pull(db, "*")`, `Xitdb.materialize/1`, and historical `as_of/2` snapshots
- [ ] Task: Run bounded `mix fuzz` campaign for Group 3 and fix any uncovered state-machine bugs
    - [ ] Run `mix fuzz` on the stateful `Cursor`/`Tx` target (`--max-time 45000`) and fix any Elixir-side overlay/cursor/rollback edge cases discovered
- [ ] Task: Conductor - User Manual Verification 'Phase 4: Bytecode-Driven Stateful Cursor / Tx Fuzzing' (Protocol in workflow.md)

---

## Phase 5: Documentation & Final Verification

- [ ] Task: Document `mix fuzz` workflows and verify full project gate
    - [ ] Add concise usage notes for `mix test --only fuzz` and `mix fuzz <file>:<line>` to `AGENTS.md` / `README.md` (keeping existing docs intact and respecting Markdown/MathJax rules)
    - [ ] Run `mix precommit` (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`) and confirm zero warnings and 100% passing tests (including replayed `test/fixtures/fuzz/` regression corpus)
- [ ] Task: Conductor - User Manual Verification 'Phase 5: Documentation & Final Verification' (Protocol in workflow.md)
