# Specification: Track 7 — `Xitdb.Error` Helpers, `NimbleOptions` Validation, Root-Cursor Guard & IEx Docstring Cleanups

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `remaining_improvements_20261112`
> - **Wave:** Wave 4 (executes immediately after Track 6 [`split_dsl_and_invert_ash_dependency_20261111`](../split_dsl_and_invert_ash_dependency_20261111/index.md))
> - **Prerequisites:**
>   - [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md)
>   - [`split_dsl_and_invert_ash_dependency_20261111`](../split_dsl_and_invert_ash_dependency_20261111/index.md) (creates `lib/xitdb/dsl/tx_rewriter.ex` and `lib/xitdb/dsl/tx_runtime.ex`)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Area:** `lib/xitdb/error.ex`, `lib/xitdb.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb/collection.ex`, `lib/xitdb/dsl/tx_rewriter.ex`, `lib/xitdb/dsl/tx_runtime.ex`
> - **Reference Documents:**
>   - Master Reference: [`./reference.md`](./reference.md)
>   - Step 1 Reference: [`./references/step1_error_helpers_and_option_validation.md`](./references/step1_error_helpers_and_option_validation.md)
> - **Follow-Up Wave 5 Tracks:** Documentation guides and `.formatter.exs` / `usage-rules.md` unification are executed in **Wave 5** ([`doc_fixes_and_operational_guides_20261112`](../doc_fixes_and_operational_guides_20261112/index.md) and [`formatter_exports_and_usage_rules_20261112`](../formatter_exports_and_usage_rules_20261112/index.md)) after `Xitdb.Ash.DataLayer` and `Xitdb.Ash.Store` land—using `Process.flag(:trap_exit, true)` in standalone `MyApp.Store.init/1`, first-class `use Xitdb.Ash.Store` (instead of a hand-rolled `MyApp.MDM.Store` `GenServer`), `require_atomic? false` on `ModifyLockedFields` actions, and unified formatter/usage-rules exports across both Ash layers.
> - **Done When:**
>   - `Xitdb.Error.wrap/2` and `unwrap!/1` are implemented and used across all bang wrappers, NIF wrappers, `validate_opts/2`, and `TxRewriter.wrap_bang/1`.
>   - `@transact_schema`, `@query_schema` (without `default: -1` on `:moment`), and `@compact_schema` compile-time `NimbleOptions` schemas validate options eagerly across `transact/3`, `transact_ops/3`, `TxRuntime.init_state/3`, `query/3`, and `compact/2`.
>   - `do_transact_ops/3` normalizes and deduplicates `validated[:index_rules]` so map transactions, `%Cursor{}` callbacks, map-returning callbacks, and `transact_ops/3` (`tx` / `tx_for`) all honor `:index_rules` identically without double-emitting `{:index_on, ...}`.
>   - `Xitdb.select/2` requires `%Cursor{root: true, tx_mode: false}`, rejecting both nested child sub-cursors (`root: false`) and in-flight transaction cursors (`tx_mode: true`) with `{:error, %Xitdb.Error{reason: :non_root_cursor}}`.
>   - `Xitdb.transact/3` and `transact!/3` `@spec`s cover the full callback return union (`Cursor.t() | map() | {:abort, term()}`), `Xitdb.at/1` has `@doc` and `@spec`, guide documents are indexed in `@moduledoc`, and raw LaTeX math in `@doc` strings is replaced with backtick code spans (`` `O(1)` ``, `` `O(log N)` ``).
>   - Verification tests in `test/xitdb/options_and_cursor_guard_test.exs` and `mix precommit` pass with zero warnings.

---

## 1. Goal & Architectural Motivation

1. **Centralized Error Helpers (`lib/xitdb/error.ex`):**
   - Provide `Xitdb.Error.wrap/2` (handling `:ok`, `{:ok, val}`, `{:error, %Error{}}`, `{:error, reason}`, and bare atom/string `reason`) and `Xitdb.Error.unwrap!/1`.
   - Replaces redundant `case` statements in bang functions (`open!/1`, `info!/1`, `transact!/3`, `select!/2`, `pull!/2`, `query!/3`, `compact!/2`), NIF wrappers, `validate_opts/2`, and `TxRewriter.wrap_bang/1`.
2. **Compile-Time `NimbleOptions` Schemas, Eager `tx` Validation & Unified `:index_rules` (`lib/xitdb.ex`, `lib/xitdb/dsl/tx_runtime.ex`):**
   - Introduces `@transact_schema`, `@query_schema` (omitting `default: -1` on `:moment` so `Xitdb.query(%Cursor{moment: m}, ...)` preserves `m`), and `@compact_schema` alongside `@open_schema`.
   - Defines `defp validate_opts(opts, schema)` explicitly for both keyword lists and invalid non-list arguments, and exposes `@doc false` `validate_transact_opts/1` so `TxRuntime.init_state/3` validates options eagerly before `read_current_value/2` ever runs.
   - Normalizes and prepends unique `:index_rules` inside `do_transact_ops/3` (passing `Keyword.delete(validated, :index_rules)` to `TxCompiler.compile_moment_map/2`) so all four transaction paths honor `:index_rules` without duplicating `{:index_on, ...}` ops.
3. **Root Snapshot & Transaction Cursor Guard on `Xitdb.select/2` (`lib/xitdb.ex`, `lib/xitdb/cursor.ex`):**
   - Adds `root: boolean()` (default `false`) to `%Xitdb.Cursor{}` and marks committed root snapshots from `Xitdb.db/1` and `Xitdb.as_of/2` with `root: true`.
   - Restricts `Xitdb.select/2` on cursors to `%Cursor{root: true, tx_mode: false}`, returning `{:error, %Xitdb.Error{reason: :non_root_cursor}}` for both nested child sub-cursors (`db["users"]`) and in-flight transaction cursors (`%Cursor{tx_mode: true}`) so `select/2` never silently bypasses staged transaction writes.
4. **Complete `@spec`s, Documented `Xitdb.at/1` & IEx-Clean `@doc` Formatting:**
   - Updates `@spec transact/3` and `@spec transact!/3` callback return unions to `Cursor.t() | map() | {:abort, term()}`.
   - Adds `@doc` and `@spec` to `Xitdb.at/1`, guide cross-references in `Xitdb` `@moduledoc`, and replaces raw LaTeX math in docstrings with inline code spans `` `O(log N)` `` and `` `O(1)` ``.

---

## 2. Technical Invariants & Requirements

1. **Error Helper Invariants:**
   - `Error.wrap(:ok, _details)` -> `:ok`
   - `Error.wrap({:ok, val}, _details)` -> `{:ok, val}`
   - `Error.wrap({:error, %Error{}} = err, _details)` -> `err`
   - `Error.wrap({:error, reason}, details)` -> `{:error, %Error{reason: reason, details: details}}`
   - `Error.wrap(%Error{} = err, _details)` -> `err`
   - `Error.wrap(reason, details)` (when `is_atom(reason)` or `is_binary(reason)`) -> `%Error{reason: reason, details: details}`
   - `Error.unwrap!({:ok, val})` -> `val`
   - `Error.unwrap!({:error, err})` -> `raise err`
2. **Options Validation & `:index_rules` Invariants:**
   - `validate_opts/2` validates keyword lists against compile-time `NimbleOptions` schemas and rejects non-list options cleanly as `{:error, %Error{reason: :invalid_options, ...}}`.
   - `TxRuntime.init_state/3` calls `Xitdb.validate_transact_opts/1` before executing the `tx` body so invalid options (e.g., `base_moment: "bad"`) return `{:error, %Error{reason: :invalid_options}}` instead of `:transaction_exception`.
   - `do_transact_ops/3` normalizes `validated[:index_rules]` into `{:index_on, src, field, idx}` string tuples and deduplicates them against `ops`, ensuring map transactions, `%Cursor{}` callbacks, map-returning callbacks, and `transact_ops/3` (`tx` / `tx_for`) all apply `:index_rules` exactly once.
   - `@query_schema` omits `default: -1` on `:moment` so `Xitdb.query(Xitdb.as_of(db, 0), q)` queries moment `0` unless overridden via `moment: m`.
3. **Cursor Root & `tx_mode` Guard Invariants:**
   - Calling `Xitdb.select(cursor, selector)` succeeds only when `cursor` is `%Xitdb{}` or `%Cursor{root: true, tx_mode: false}`.
   - Calling `Xitdb.select(cursor, selector)` on a child cursor (`root: false`) or an in-flight transaction cursor (`tx_mode: true`) returns `{:error, %Error{reason: :non_root_cursor, details: ...}}`.
4. **IEx Clean Rendering:**
   - Zero raw LaTeX math blocks in `@moduledoc` and `@doc` strings.

---

## 3. Module Breakdown & Deliverables

- `lib/xitdb/error.ex`: `wrap/2` and `unwrap!/1` implementations.
- `lib/xitdb.ex`: `@transact_schema`, `@query_schema`, `@compact_schema`, `validate_opts/2`, `validate_transact_opts/1`, `do_transact_ops/3` `:index_rules` normalization/deduplication, complete `transact/3` & `transact!/3` `@spec`s, `root: true` cursor marking, `select/2` guard (`root: true, tx_mode: false`), `at/1` doc/spec, and guide index links.
- `lib/xitdb/cursor.ex`: Struct field `root: false`, `@type t` update, and IEx docstring cleanup.
- `lib/xitdb/collection.ex`: Removal of raw LaTeX from docstrings.
- `lib/xitdb/dsl/tx_rewriter.ex`: Route `wrap_bang/1` through `Xitdb.Error.unwrap!/1`.
- `lib/xitdb/dsl/tx_runtime.ex`: Route `init_state/3` through `Xitdb.validate_transact_opts/1` for eager option validation.
- `test/xitdb/options_and_cursor_guard_test.exs`: ExUnit verification suite.
