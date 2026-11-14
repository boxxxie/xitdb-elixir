# Implementation Plan: Track 7 — `Xitdb.Error` Helpers, `NimbleOptions` Validation, Root-Cursor Guard & IEx Docstring Cleanups

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `remaining_improvements_20261112`
> - **Wave:** Wave 4 (depends on Track 6 [`split_dsl_and_invert_ash_dependency_20261111`](../split_dsl_and_invert_ash_dependency_20261111/index.md))
> - **Prerequisites:** [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md), [`split_dsl_and_invert_ash_dependency_20261111`](../split_dsl_and_invert_ash_dependency_20261111/index.md)
> - **Specification:** [`./spec.md`](./spec.md)
> - **Master Reference Document:** [`./reference.md`](./reference.md)
> - **Step 1 Reference Document:** [`./references/step1_error_helpers_and_option_validation.md`](./references/step1_error_helpers_and_option_validation.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Follow-Up Wave 5 Note:** Documentation guides and `.formatter.exs` / `usage-rules.md` packaging were promoted into **Wave 5** tracks ([`doc_fixes_and_operational_guides_20261112`](../doc_fixes_and_operational_guides_20261112/index.md) and [`formatter_exports_and_usage_rules_20261112`](../formatter_exports_and_usage_rules_20261112/index.md)) so they unify both `Xitdb.Ash.Resource` and `Xitdb.Ash.DataLayer` (`use Xitdb.Ash.Store`, `Process.flag(:trap_exit, true)` in standalone `MyApp.Store`, `require_atomic? false` on `ModifyLockedFields` actions, and unified formatter/usage-rules exports) at the end of the pipeline.
> - **Done When:** `Xitdb.Error.wrap/2` and `unwrap!/1`, `NimbleOptions` schemas, unified `:index_rules` in `do_transact_ops/3`, eager option validation in `TxRuntime.init_state/3`, `root: true, tx_mode: false` cursor guard on `Xitdb.select/2`, and IEx docstring cleanups are implemented, `test/xitdb/options_and_cursor_guard_test.exs` passes, and `mix precommit` succeeds with zero warnings.

---

## Phase 1: Error Helpers, `NimbleOptions` Schemas, `:index_rules` & Eager `tx` Validation

- [x] Task: Implement `Xitdb.Error.wrap/2` and `unwrap!/1` (`lib/xitdb/error.ex`)
    - [x] Add `wrap/2` handling `:ok`, `{:ok, val}`, `{:error, %Error{}}`, `{:error, reason}`, `%Error{}`, and bare atom/string `reason`
    - [x] Add `unwrap!/1` returning `val` on `{:ok, val}` and raising on `{:error, err}`
- [x] Task: Compile-time `NimbleOptions` Schemas, `:index_rules` & Bang Simplification (`lib/xitdb.ex`, `lib/xitdb/dsl/tx_rewriter.ex`, `lib/xitdb/dsl/tx_runtime.ex`)
    - [x] Define `@transact_schema`, `@query_schema` (without `default: -1` on `:moment`), and `@compact_schema` via `NimbleOptions.new!/1`
    - [x] Define `defp validate_opts/2` (handling both keyword lists and non-list inputs via `Error.wrap(:invalid_options, ...)`) and `@doc false` `validate_transact_opts/1`
    - [x] Validate options eagerly in `TxRuntime.init_state/3` via `Xitdb.validate_transact_opts/1` so bad `tx` options fail immediately as `:invalid_options`
    - [x] Normalize and deduplicate `validated[:index_rules]` inside `do_transact_ops/3` (passing `Keyword.delete(validated, :index_rules)` to `TxCompiler.compile_moment_map/2`) so map, `%Cursor{}` callback, map-returning callback, and `transact_ops/3` (`tx` / `tx_for`) transactions all apply `:index_rules` identically without duplication
    - [x] Update `@spec transact/3` and `@spec transact!/3` callback return unions to `Cursor.t() | map() | {:abort, term()}`
    - [x] Refactor `open!/1`, `info!/1`, `transact!/3`, `select!/2`, `pull!/2`, `query!/3`, `compact!/2`, and `TxRewriter.wrap_bang/1` to use `Error.unwrap!/1`
    - [x] Refactor `sync/1`, `info/1`, `pull/2`, `diff_moments/3`, `history_of/2`, and `do_query/3` to use `Error.wrap/2`

---

## Phase 2: Root Snapshot & `tx_mode` Cursor Guard, IEx Docstrings & Verification

- [x] Task: Sub-Cursor & Transaction Cursor Safety (`lib/xitdb/cursor.ex`, `lib/xitdb.ex`)
    - [x] Add `root: boolean()` (default `false`) to `Xitdb.Cursor` struct and `@type t`
    - [x] Set `root: true` on committed snapshot cursors produced by `Xitdb.as_of/2` (and delegated `Xitdb.db/1`)
    - [x] Update `Xitdb.select/2` to require `%Cursor{root: true, tx_mode: false}`, returning `{:error, %Error{reason: :non_root_cursor}}` on both child sub-cursors (`root: false`) and in-flight transaction cursors (`tx_mode: true`)
- [x] Task: Document `Xitdb.at/1` & IEx Docstring Cleanups (`lib/xitdb.ex`, `lib/xitdb/collection.ex`, `lib/xitdb/cursor.ex`)
    - [x] Add `@doc` and `@spec` for `Xitdb.at/1`
    - [x] Add guide index links to `Xitdb` `@moduledoc`
    - [x] Replace raw LaTeX math in docstrings with backtick code spans `` `O(...)` `` in `lib/xitdb.ex`, `lib/xitdb/collection.ex`, and `lib/xitdb/cursor.ex`
- [x] Task: Verification Test Suite (`test/xitdb/options_and_cursor_guard_test.exs`)
    - [x] Test unknown/mistyped options returning `:invalid_options` across `compact/2`, `transact/3`, `transact_ops/3`, `query/3`, and `tx` with `update`
    - [x] Test `Xitdb.query/3` preserving `%Cursor{moment: 0}` when `:moment` is omitted
    - [x] Test `:index_rules` across map `transact/3`, `%Cursor{}` callback `transact/3`, map-returning callback `transact/3`, and `transact_ops/3` (`tx`)
    - [x] Test `Xitdb.select/2` accepting committed root cursors and rejecting both child sub-cursors and `tx_mode: true` cursors with `:non_root_cursor`
    - [x] Run `mix precommit` and verify zero warnings
