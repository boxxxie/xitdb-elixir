# Specification: Standardized Fallback Helper & Anti-Success-Shaped-Fallback Guardrails

## Overview
Prevent silent error swallowing ("success-shaped code") in `elixir/xitdb` by routing all legitimate read-only/cache-miss/codec fallbacks through a single observable helper (`Xitdb.Fallback.run/2,3`), documenting the rule for agents, enforcing deterministic Credo AST checks against ad-hoc `rescue`/`catch` blocks, and establishing diff-scoped mutation testing.

## Requirements
1. **`Xitdb.Fallback` Helper (`lib/xitdb/fallback.ex`):**
   - Provide `Xitdb.Fallback.run(reason, metadata \\ %{}, fun)` and `Xitdb.Fallback.try_run(reason, metadata \\ %{}, try_fun, fallback_fun)` where `reason` is an atom/string and `fun` is a 0-arity function (`fallback_fun` may be 0-arity or 1-arity receiving the exception), named `run`/`try_run` rather than `use` to avoid colliding with `Kernel.SpecialForms.use/2`.
   - Document the **3-question fallback gate** in `@moduledoc`:
     1. Is it strictly read-only / query-planner / cache-miss / display-only without mutating DB state, transactions, or persistence?
     2. Does it emit a `:telemetry` event (not just a log line)?
     3. Is it exercised regularly or covered by an ExUnit test?
   - Emit `:telemetry.execute([:xitdb, :fallback, :used], %{count: 1}, Map.put(metadata, :reason, reason))` and log a structured `Logger.warning` before invoking `fun.()`.
   - Strictly forbidden on write, transaction (`Xitdb.transact/3`, `Xitdb.TxCompiler`, `Xitdb.DSL.tx`), NIF boundary, lock/lease-fencing, compaction, or Ash mutator paths — those must fail fast and return `{:error, ...}` or raise.

2. **Agent & Audit Documentation:**
   - Add a concise rule to `AGENTS.md` naming `Xitdb.Fallback.run/2,3` and `Xitdb.Fallback.try_run/3,4` and banning ad-hoc `rescue` returning `:ok`, `_ -> :ok` catch-alls, early `:ok` on missing required slots/records, and silent config defaults.
   - Create/update `.agents/audit-packs/project-invariants.md` so `bug-finder` / `elixir-bug-finder` flags ad-hoc fallbacks bypassing `Xitdb.Fallback.run/2,3` or `try_run/3,4`.

3. **Deterministic Guardrails (Credo + Custom AST Check):**
   - Add `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` to `mix.exs` and create `.credo.exs` in the repo root.
   - Implement `Credo.Check.Warning.NoBusinessLogicRescue` in `credo/checks/no_business_logic_rescue.ex` (**outside `lib/`**, because `:credo` is `only: [:dev, :test], runtime: false` and `lib/` is compiled in `:prod` and packaged in Hex).
   - Register `requires: ["credo/checks/*.ex"]` in `.credo.exs`, walking `lib/` ASTs to flag `try`/`def`/`defp`/`defmacro`/`defmacrop` `rescue` and `catch` blocks outside explicitly allowlisted boundary modules (skipping pure observe-and-reraise blocks whose every clause terminates in `reraise` or `:erlang.raise/3`).
   - Triage the existing **38** `rescue`/`catch` occurrences across 12 files in `lib/` (`lib/xitdb.ex`, `lib/xitdb/pull.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb/compression.ex`, `lib/xitdb/dsl/tx_rewriter.ex`, `lib/xitdb/ash/store.ex`, `lib/xitdb/ash/test_sandbox.ex`, `lib/xitdb/ash/data_layer.ex`, `lib/xitdb/ash/query.ex`, `lib/xitdb/ash/mutator.ex`, `lib/xitdb/ash/types/fixed_decimal64.ex`, `lib/xitdb/ash/types/ranged_unit.ex`): eliminate raw `rescue` in `data_layer.ex`, `query.ex`, `fixed_decimal64.ex`, and `ensure_blobs_cursor/2` in `compression.ex`, and explicitly allowlist the 9 genuine low-level boundary files in `.credo.exs` so `mix credo --strict` passes cleanly.
   - Wire `credo --strict` into `mix precommit`.

4. **Diff-Scoped Mutation Testing (`muex` Spike + Zero-Dependency Agent Fallback):**
   - Spike `:muex` (`only: [:dev, :test]`) on Elixir 1.20.5 / Erlang/OTP 29.
   - If `:muex` compiles and runs cleanly on Elixir 1.20.5, configure/document a diff-scoped `mix muex` command targeting changed modules rather than the full repository.
   - If `:muex` is incompatible with Elixir 1.20.5 / OTP 29, skip adding `:muex` to `mix.exs` and standardize on the zero-dependency **agent diff-mutation workflow**: delete each newly added `rescue`, catch-all, and default in a PR diff one at a time, re-run targeted `mix test`, and either add the missing test or delete the dead fallback.

5. **Verification:**
   - Add ExUnit tests (`test/xitdb/fallback_test.exs` and/or 4-layer ATDD specs under `test/features/`) verifying `Xitdb.Fallback.run/2,3` return value, `[:xitdb, :fallback, :used]` telemetry emission, metadata propagation, and `Logger.warning` output.
   - Add unit tests for `Credo.Check.Warning.NoBusinessLogicRescue`.
   - Confirm `mix precommit`, `mix credo --strict`, and `MIX_ENV=prod mix compile` all pass with zero warnings.

## Reference: Custom Credo Check (`NoBusinessLogicRescue`)
Place in `credo/checks/no_business_logic_rescue.ex` (outside `lib/`):
```elixir
defmodule Credo.Check.Warning.NoBusinessLogicRescue do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed_paths: ["lib/xitdb/fallback.ex"]],
    explanations: [
      check:
        "Avoid `rescue`/`catch` outside boundary modules; fail fast or use `Xitdb.Fallback.run/2,3`."
    ]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    allowed = Params.get(params, :allowed_paths, __MODULE__)

    if Enum.any?(allowed, &String.starts_with?(filename, &1)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp traverse({:try, meta, [blocks]} = ast, issues, issue_meta) when is_list(blocks) do
    if Keyword.has_key?(blocks, :rescue) or Keyword.has_key?(blocks, :catch) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse({def_kind, meta, [_, blocks]} = ast, issues, issue_meta)
       when def_kind in [:def, :defp, :defmacro, :defmacrop] and is_list(blocks) do
    if Keyword.has_key?(blocks, :rescue) or Keyword.has_key?(blocks, :catch) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message: "Unexpected `rescue`/`catch` outside boundary modules.",
      line_no: line_no
    )
  end
end
```
