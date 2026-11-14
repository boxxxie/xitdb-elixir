# Implementation Plan: Track 6 — Split `lib/xitdb/dsl.ex` & Invert Ash/Spark Dependency Across 4 Steps

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `split_dsl_and_invert_ash_dependency_20261111`
> - **Wave:** Wave 4 (after Track 5B [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md), before Track 7 [`remaining_improvements_20261112`](../remaining_improvements_20261112/index.md))
> - **Prerequisite:** [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md)
> - **Specification:** [`./spec.md`](./spec.md)
> - **Master Reference Document:** [`./reference.md`](./reference.md)
> - **Step Reference Documents:**
>   - Step 1: [`./references/step1_selector_and_tx_compiler.md`](./references/step1_selector_and_tx_compiler.md)
>   - Step 2: [`./references/step2_path_compiler.md`](./references/step2_path_compiler.md)
>   - Step 3: [`./references/step3_datalog_compiler.md`](./references/step3_datalog_compiler.md)
>   - Step 4: [`./references/step4_tx_rewriter_and_runtime.md`](./references/step4_tx_rewriter_and_runtime.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** All 4 atomic steps are implemented, verified by their respective test suites, and `mix precommit` passes with zero warnings.

---

## Phase 1: Step 1 — Extract `Xitdb.Selector` & Deduplicate `TxCompiler` (Reference: [`step1_selector_and_tx_compiler.md`](./references/step1_selector_and_tx_compiler.md))

- [ ] Task: Implement `Xitdb.Selector` (`lib/xitdb/selector.ex`)
    - [ ] Consolidate `@valid_selector_starts`, `@typed_modifiers`, `@map_modifiers`, and `@set_modifiers`
    - [ ] Define `is_valid_selector_start/1`, `is_typed_modifier/1`, `is_map_modifier/1`, and `is_set_modifier/1` guards
    - [ ] Implement `format_step/2`, `format_typed_step/2`, `format_bracket_step/1`, `format_root_or_step/1`, and `format_path_steps/1`
    - [ ] Reject `nil` and booleans in `format_bracket_step/1` and `format_key/1` (`when is_atom(key) and not is_nil(key) and not is_boolean(key)`), raising `ArgumentError`
    - [ ] Implement `encode_quoted/1` and tail-recursive `escape_bytes/2`
- [ ] Task: Update `lib/xitdb/sigils.ex`
    - [ ] Import `Xitdb.Selector, only: [is_valid_selector_start: 1]`
    - [ ] Refactor `sigil_x` validation to use `is_valid_selector_start` guard
- [ ] Task: Deduplicate `lib/xitdb/tx_compiler.ex`
    - [ ] Extract `compile_kv_collection/5` to handle both plain maps and `Xitdb.Collection` structs
    - [ ] Add temporary `defdelegate`s for selector formatting functions pointing to `Xitdb.Selector`
    - [ ] Update internal calls to use `Xitdb.Selector`
- [ ] Task: Update `lib/xitdb.ex`, `lib/xitdb/cursor.ex`, and `lib/xitdb/ash/search.ex`
    - [ ] Update `insert_at/4` and `delete_at/3` in `lib/xitdb.ex` to call `Selector.format_path_steps/1` and `Selector.format_step/2`
    - [ ] Update cursor path reconstruction in `lib/xitdb/cursor.ex` to call `Selector.format_step/2`
    - [ ] Update `Xitdb.Ash.Search.Storage` in `lib/xitdb/ash/search.ex` to call `Selector.format_key/1`
- [ ] Task: Add test suite and verify Step 1
    - [ ] Implement `test/xitdb/selector_test.exs` covering path steps formatting, canonical selectors, collection folding, and `ArgumentError` on `nil`/boolean keys
    - [ ] Run `mix compile --warnings-as-errors` and `mix test test/xitdb/selector_test.exs`

---

## Phase 2: Step 2 — Extract `Xitdb.DSL.PathCompiler` (Reference: [`step2_path_compiler.md`](./references/step2_path_compiler.md))

- [ ] Task: Implement `Xitdb.DSL.PathCompiler` (`lib/xitdb/dsl/path_compiler.ex`)
    - [ ] Extract `path/1` AST parser and segment extractor from `lib/xitdb/dsl.ex` behind `PathCompiler.compile/1`
    - [ ] Implement static binary segment folding at compile time (`fold_static_segments/1`, `segments_to_quoted/1`)
    - [ ] Expose shared helpers `typed_modifier_segment/2` and `fold_and_quote/1` for reuse in `DatalogCompiler`
    - [ ] Support compile-time folding for negative indices (`roles[-1]`, `todos[[-1]]`) and moments (`at_moment(-1, ...)`)
    - [ ] Support pinned root/receiver expressions (`(^base).sorted(...)`) and pinned moments (`at_moment(^m, ...)`) in `moment_segment/1`
- [ ] Task: Clean up guards and wire `Xitdb.DSL.path/1` macro
    - [ ] Remove `@typed_modifiers` from `lib/xitdb/dsl.ex` in favor of `Xitdb.Selector` guards (`is_typed_modifier/1`, `is_set_modifier/1`, `is_map_modifier/1`)
    - [ ] Route `Selector` calls directly and delegate `path/1` AST expansion to `PathCompiler.compile/1`
    - [ ] Update transaction mutation macros (`put`, `update`, `rm`, `insert`, `slice`, `append`, `fork`, `init_col`, `reset_col`) to call `PathCompiler.compile/1`
- [ ] Task: Add test suite and verify Step 2
    - [ ] Implement `test/xitdb/dsl/path_compiler_test.exs` covering static folding, negative indices/moments, `(^base)` pinned prefixes, `at_moment(^m, ...)`, and `ArgumentError` on `nil`/boolean runtime bracket keys
    - [ ] Run `mix compile --warnings-as-errors` and `mix test`

---

## Phase 3: Step 3 — Extract `Xitdb.DSL.DatalogCompiler` (Reference: [`step3_datalog_compiler.md`](./references/step3_datalog_compiler.md))

- [ ] Task: Implement `Xitdb.DSL.DatalogCompiler` (`lib/xitdb/dsl/datalog_compiler.ex`)
    - [ ] Extract Datalog query AST compilation (`find`, `from`, `where`) from `lib/xitdb/dsl.ex` behind `DatalogCompiler.compile/3`
    - [ ] Implement `compile_find!/2` for logic variable and aggregation (`count`, `sum`, `min`, `max`) formatting
    - [ ] Implement `compile_where_clause!/4` with `not`, `reach` (3- and 4-arg), predicates, comparisons, and set modifiers
    - [ ] Implement negative numeric literals (`delta >= -50`), negative moments (`@-1`), and negative bracket indices (`[-1]`, `[[-1]]`)
    - [ ] Reject `nil` in `DatalogCompiler.format_literal/1` (`raise ArgumentError, "cannot match nil in Datalog where clause"`) and invalid pins in `format_bracket_pin/1`
    - [ ] Add catch-all `compile_error!/2` clauses to `build_collection_binding/3` and `compile_path_segments/4` so invalid AST raises `CompileError` with caller `file`/`line`
- [ ] Task: Wire `Xitdb.DSL` datalog & query macros and clean up `dsl.ex`
    - [ ] Update `datalog/1`, `query/2,3`, and `query!/2,3` macros (supporting runtime option variables) to delegate AST expansion to `DatalogCompiler.compile/3`
    - [ ] Remove extracted private Datalog compiler functions and unused `Selector` imports from `lib/xitdb/dsl.ex`
- [ ] Task: Add test suite and verify Step 3
    - [ ] Implement `test/xitdb/dsl/datalog_compiler_test.exs` verifying aggregations, negative literals, `^nil` `ArgumentError`, and malformed path/collection `CompileError`s
    - [ ] Run `mix compile --warnings-as-errors` and `mix test`

---

## Phase 4: Step 4 — Extract `TxRuntime` & `TxRewriter`, Invert Ash/Spark Dependency (Reference: [`step4_tx_rewriter_and_runtime.md`](./references/step4_tx_rewriter_and_runtime.md))

- [ ] Task: Implement `Xitdb.DSL.TxRewriter` (`lib/xitdb/dsl/tx_rewriter.ex`)
    - [ ] Extract `tx/2,3`, `tx!/2,3`, `tx_for/3,4`, and `tx_for!/3,4` AST rewriters from `lib/xitdb/dsl.ex`
    - [ ] Match `{:ok, tx_ref} | {:error, %Xitdb.Error{}}` from `TxRuntime.init_state/3` for eager option validation
- [ ] Task: Implement `Xitdb.DSL.TxRuntime` (`lib/xitdb/dsl/tx_runtime.ex`)
    - [ ] Implement process-dictionary transaction state machine (`init_state/3`, `commit_state/1`, `cleanup_state/1`)
    - [ ] Implement accurate staged read-your-own-writes (`staged_log` folding across exact, ancestor, and descendant paths on top of committed `base_moment` values)
    - [ ] Recursively unwrap `%Xitdb.Collection{}` structs via `materialize_staged_value/1` and stage `append`, `insert`, `slice`, and `fork` mutations accurately
- [ ] Task: Invert Ash/Spark dependency in `tx_for` & fix `Xitdb.Ash.Tx` hygiene
    - [ ] Replace `Spark.Dsl.Extension.get_persisted/3` and `Xitdb.Ash.Info` calls with `__xitdb_indexes__/0` and `__xitdb_collection__/0`
    - [ ] Add `require Xitdb.DSL` in `lib/xitdb/ash/tx.ex`
- [ ] Task: Trim `lib/xitdb/dsl.ex` to a thin macro facade & remove temporary delegates
    - [ ] Remove extracted private helpers from `lib/xitdb/dsl.ex` and temporary `defdelegate`s from `lib/xitdb/tx_compiler.ex`
    - [ ] Implement `test/xitdb/dsl/tx_rewriter_and_runtime_test.exs` covering standalone `tx_for!`, parent overwrite eviction, ancestor `update` after child `put`/`rm`, `%Collection{}` `update`, and `append`/`insert`/`slice`/`fork` staging
    - [ ] Run `mix precommit` and verify zero warnings
