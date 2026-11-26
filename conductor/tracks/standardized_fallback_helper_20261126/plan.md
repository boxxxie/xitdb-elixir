# Implementation Plan: Standardized Fallback Helper & Guardrails

## Phase 1: Core Helper & Tests (Red-First)
- [x] Write failing ExUnit tests in `test/xitdb/fallback_test.exs` verifying `Xitdb.Fallback.run/2,3` and `Xitdb.Fallback.try_run/3,4` return values, `[:xitdb, :fallback, :used]` telemetry event emission, metadata propagation, and `Logger.warning` output.
- [x] Create `lib/xitdb/fallback.ex` implementing `Xitdb.Fallback.run/2,3` and `Xitdb.Fallback.try_run/3,4` with `@moduledoc` documenting the 3-question fallback gate, `:telemetry.execute([:xitdb, :fallback, :used], ...)`, and `Logger.warning`.
- [x] Run `mix test test/xitdb/fallback_test.exs` to verify Green.

## Phase 2: Agent Rules & Audit Invariants
- [x] Add the `Xitdb.Fallback.run/2,3` / `try_run/3,4` and no-success-shaped-fallback rule to `AGENTS.md` (banning ad-hoc `rescue` returning `:ok`, `_ -> :ok` catch-alls, and silent defaults on write/NIF/persistence paths).
- [x] Create/update `.agents/audit-packs/project-invariants.md` so `bug-finder` / `elixir-bug-finder` flags ad-hoc fallbacks bypassing `Xitdb.Fallback`.

## Phase 3: Credo Setup, Custom AST Check & Existing `rescue`/`catch` Triage
- [x] Add `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` to `mix.exs` and generate `.credo.exs`.
- [x] Implement `Credo.Check.Warning.NoBusinessLogicRescue` in `credo/checks/no_business_logic_rescue.ex` (outside `lib/`, skipping observe-and-reraise blocks), register `requires: ["credo/checks/*.ex"]` in `.credo.exs`, and add unit tests in `test/credo/no_business_logic_rescue_test.exs`.
- [x] Audit the 38 existing `rescue`/`catch` sites in `lib/`: eliminate raw `rescue` in `ash/data_layer.ex`, `ash/query.ex`, `ash/types/fixed_decimal64.ex`, and `ensure_blobs_cursor/2` in `compression.ex`, and allowlist intentional low-level boundaries in `.credo.exs`.
- [x] Verify `mix credo --strict`, `mix precommit`, and `MIX_ENV=prod mix compile --warnings-as-errors` all pass with zero warnings.

## Phase 4: Diff-Scoped Mutation Testing (`muex` Spike & Agent Fallback)
- [x] Spike `:muex` (`only: [:dev, :test]`) on Elixir 1.20.5 / Erlang/OTP 29.1.2; `:muex ~> 0.13.1` compiled and ran cleanly with `--mirror native --no-filter`, so keep it in `mix.exs` and configure diff-scoped `mix muex` alongside the zero-dependency agent diff-mutation workflow.
- [x] Run `muex` on `lib/xitdb/fallback.ex` (`test/xitdb/fallback_test.exs`), strengthen guard tests for surviving mutants, and document the workflow in `AGENTS.md`.
