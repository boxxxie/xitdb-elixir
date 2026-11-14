# Specification: Track 6 — Split `lib/xitdb/dsl.ex` & Invert Ash/Spark Dependency Across 4 Steps

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `split_dsl_and_invert_ash_dependency_20261111`
> - **Wave:** Wave 4 (executes after Track 5B [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md) and before Track 7 [`remaining_improvements_20261112`](../remaining_improvements_20261112/index.md))
> - **Prerequisite:** [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md) (Step 1 extracts `encode_quoted/1` and `escape_bytes/2` added in Track 5)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Area:** `lib/xitdb/dsl.ex`, `lib/xitdb/selector.ex`, `lib/xitdb/tx_compiler.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb.ex`, `lib/xitdb/sigils.ex`, `lib/xitdb/ash/search.ex`, `lib/xitdb/dsl/path_compiler.ex`, `lib/xitdb/dsl/datalog_compiler.ex`, `lib/xitdb/dsl/tx_runtime.ex`, `lib/xitdb/dsl/tx_rewriter.ex`, `lib/xitdb/ash/tx.ex`
> - **Reference Documents:**
>   - Master Reference: [`./reference.md`](./reference.md)
>   - Step 1 Reference: [`./references/step1_selector_and_tx_compiler.md`](./references/step1_selector_and_tx_compiler.md)
>   - Step 2 Reference: [`./references/step2_path_compiler.md`](./references/step2_path_compiler.md)
>   - Step 3 Reference: [`./references/step3_datalog_compiler.md`](./references/step3_datalog_compiler.md)
>   - Step 4 Reference: [`./references/step4_tx_rewriter_and_runtime.md`](./references/step4_tx_rewriter_and_runtime.md)
> - **Done When:** All 4 self-contained steps are implemented, `lib/xitdb/dsl.ex` is modularized into specialized compilers and rewriters with inverted dependencies (zero Spark/Ash imports in core DSL), selector guards and key formatters are unified, and `mix precommit` passes with zero warnings.

---

## 1. Goal & Architectural Motivation

The `elixir/xitdb` client library provides an expressive, idiomatic Elixir interface for path access, transaction batching, structural Pull patterns, and Datalog queries. However, as the feature set expanded, `lib/xitdb/dsl.ex` grew into a 1,559-line monolithic module combining unrelated responsibilities:
1. **Path AST compilation & compile-time static folding:** Macro expansion of path expressions (`path/1`), segment parsing, and compile-time concatenation of adjacent static binary selectors.
2. **Datalog AST compilation & query string generation:** `datalog/1`, `query/2,3`, and `query!/2,3` pattern parsing, pinned runtime variable encoding (`^var`), operator transformation (`==`, `!=`, `<`, `>=`, `starts_with`, `contains`, `reach`), and negated clause compilation.
3. **Transaction AST rewriter & macro expansion:** Rewriting imperative transaction blocks (`tx/2,3`, `tx!/2,3`, `tx_for/3,4`, `tx_for!/3,4`) into staged batch operations (`put`, `update`, `rm`, `insert`, `slice`, `append`, `fork`, `init_col`, `reset_col`, `index_on`, `meta`, `instant`, `savepoint`, `abort`).
4. **Dynamic transaction runtime staging:** Collection replacement (`reset_col` + nested `put`s), in-memory read-your-own-writes across ancestor/descendant paths, `%Xitdb.Collection{}` unwrapping, list/fork staging, and secondary index registration.
5. **Architectural Dependency Inversion Violation:** `Xitdb.DSL.tx_for` directly calls `Spark.Dsl.Extension.get_persisted/3` and `Xitdb.Ash.Info`, introducing a reverse coupling where the core client DSL depends on higher-level framework extensions (`Ash` and `Spark`).

Furthermore, selector syntax definitions and escaping logic are fragmented across `lib/xitdb/sigils.ex`, `lib/xitdb/tx_compiler.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb.ex`, and `lib/xitdb/dsl.ex`, and `TxCompiler` contains duplicated empty-collection checking and folding branches.

This track decomposes this monolith into four atomic, self-contained refactoring steps, maintaining `mix compile --warnings-as-errors` and `mix test` green after every step.

---

## 2. Four-Step Architecture & Functional Requirements

```
                       ┌─────────────────────────┐
                       │     Xitdb.Selector      │
                       │   (Syntax & Guards)     │
                       └────────────┬────────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         ▼                          ▼                          ▼
 ┌───────────────┐          ┌───────────────┐          ┌───────────────┐
 │ Xitdb.Sigils  │          │  TxCompiler   │          │ Cursor/Xitdb  │
 │  (~x sigil)   │          │  (kv-folding) │          │  (formatting) │
 └───────────────┘          └───────────────┘          └───────────────┘

 ┌─────────────────────────────────────────────────────────────────────┐
 │                         Xitdb.DSL (Facade)                          │
 └───────┬──────────────────────────┬──────────────────────────┬───────┘
         ▼                          ▼                          ▼
 ┌───────────────┐          ┌───────────────┐          ┌───────────────┐
 │ PathCompiler  │          │DatalogCompiler│          │  TxRewriter & │
 │ (path/1 AST)  │          │(datalog/query)│          │   TxRuntime   │
 └───────────────┘          └───────────────┘          └───────┬───────┘
                                                               │
                                                               ▼
                                                       __xitdb_indexes__/0
                                                       (Inverted Protocol)
```

### Step 1: Extract `Xitdb.Selector` & Deduplicate `TxCompiler`
- **Single Source of Truth (`lib/xitdb/selector.ex`):**
  - Consolidate `@valid_selector_starts` (`[?., ?#, ?$, ?[, ?%, ?^, ?@]`), `@typed_modifiers`, `@map_modifiers`, and `@set_modifiers`.
  - Expose high-performance compile-time guards: `is_valid_selector_start/1`, `is_typed_modifier/1`, `is_map_modifier/1`, `is_set_modifier/1`.
  - Provide unified formatting functions: `format_step/2`, `format_typed_step/2`, `format_bracket_step/1`, `format_root_or_step/1`, `format_path_steps/1`, `format_key/1`, and `encode_quoted/1`.
  - Explicitly reject `nil` and booleans in `format_bracket_step/1` and `format_key/1` (`when is_atom(key) and not is_nil(key) and not is_boolean(key)`), raising `ArgumentError` rather than silently emitting `".users.nil"` or `".users.false"`.
- **Deduplicate `TxCompiler` (`lib/xitdb/tx_compiler.ex`):**
  - Extract `compile_kv_collection/5` to eliminate the duplicated empty-check and `:maps.fold` / `Enum.reduce` branches between plain maps and `%Xitdb.Collection{}` structs (`hash_map`, `counted_hash_map`, `sorted_map`).
  - Provide temporary `defdelegate`s on `TxCompiler` to `Selector` so existing callers in `lib/xitdb/dsl.ex` remain backward compatible until Steps 2–4 complete.
- **Route Callers Directly to `Selector`:**
  - `lib/xitdb/sigils.ex`: Import `Selector.is_valid_selector_start/1` in `sigil_x`.
  - `lib/xitdb.ex`: Call `Selector.format_path_steps/1` and `Selector.format_step/2` directly.
  - `lib/xitdb/cursor.ex`: Call `Selector.format_step/2` directly in path construction.
  - `lib/xitdb/ash/search.ex`: Call `Selector.format_key/1` directly in `Xitdb.Ash.Search.Storage`.

### Step 2: Extract `Xitdb.DSL.PathCompiler` (`lib/xitdb/dsl/path_compiler.ex`)
- Extract path expression AST parsing and static segment folding out of `lib/xitdb/dsl.ex`.
- Handle compile-time static binary concatenation of adjacent path segments (e.g., `path(users.alice.profile)` folds into a single binary `".users.alice.profile"`), including negative integer indices (`roles[-1]`, `todos[[-1]]`) and moments (`at_moment(-1, ...)`).
- Handle dynamic interpolation of runtime keys, integer array indices, typed modifiers (`:counted`, `:sorted`, `:linked`), parenthesized pinned root/receiver prefixes (`path((^base).sorted(:directory)[emp_id].todos[[idx]])`), and pinned moment expressions (`path(at_moment(^m, users[id]))`).
- Wire `Xitdb.DSL.path/1` as a macro forwarding AST expansion to `Xitdb.DSL.PathCompiler.compile/1`.

### Step 3: Extract `Xitdb.DSL.DatalogCompiler` (`lib/xitdb/dsl/datalog_compiler.ex`)
- Extract Datalog query AST compilation for `datalog/1`, `query/2,3`, and `query!/2,3` behind `DatalogCompiler.compile/3`.
- Reuse `PathCompiler`'s `fold_and_quote/1` and `typed_modifier_segment/2` helpers for path patterns in `from` and `where` clauses.
- Parse `find` projections (variables and `count`/`sum`/`min`/`max` aggregations) and `where` conditions (equality, comparison including negative numeric literals, `starts_with`/`contains` predicates, `reach/3,4`, set memberships, and `not` negations) into folded static binaries or `<>` concatenation AST.
- Encode pinned runtime literals (`^var`) via `DatalogCompiler.format_literal/1` (explicitly raising `ArgumentError` on `nil`) and `format_bracket_pin/1`, and include catch-all `compile_error!/2` clauses on `build_collection_binding/3` and `compile_path_segments/4` so malformed AST raises a caller-attributed `CompileError` instead of `FunctionClauseError`.

### Step 4: Extract `Xitdb.DSL.TxRuntime` & `TxRewriter`, Invert Ash/Spark Dependency
- **Extract `Xitdb.DSL.TxRewriter` (`lib/xitdb/dsl/tx_rewriter.ex`):**
  - Handle AST rewriting for `tx`, `tx!`, `tx_for`, and `tx_for!` blocks.
  - Pattern-match `{:ok, tx_ref}` vs `{:error, %Xitdb.Error{}}` from `TxRuntime.init_state/3` so invalid transaction options fail eagerly as `:invalid_options` before any block expressions or `read_current_value/2` execute.
- **Extract `Xitdb.DSL.TxRuntime` (`lib/xitdb/dsl/tx_runtime.ex`):**
  - Handle runtime staging where `TxRuntime.put/3` resets/replaces map and list collections (`reset_col` + nested `put`s via `TxCompiler.compile_node(selector, value, true)`) rather than deep-merging existing committed keys.
  - Maintain exact in-memory read-your-own-writes when `update` is used in a `tx` block: fold staged mutations across exact, ancestor, and descendant paths on top of committed `base_moment` values, recursively unwrap `%Xitdb.Collection{}` wrappers into native Elixir maps/lists/`MapSet`s (`materialize_staged_value/1`), and accurately stage list operations (`append`, `insert`, `slice`) and `fork` snapshots.
- **Invert Ash/Spark Dependency via `__xitdb_indexes__/0` Protocol:**
  - Remove all direct references to `Spark.Dsl.Extension` and `Xitdb.Ash.Info` from `lib/xitdb/dsl.ex` and `tx_for`.
  - Rely exclusively on the schema module's exported `__xitdb_indexes__/0` and optional `__xitdb_collection__/0` callbacks.
- **Macro Hygiene Fix:**
  - Add `require Xitdb.DSL` inside the quoted blocks of `Xitdb.Ash.Tx` macros.
- **Slim `lib/xitdb/dsl.ex`:**
  - Trim `lib/xitdb/dsl.ex` to a clean macro facade exporting `path/1`, `pull_pattern/1`, `tx/2,3`, `tx!/2,3`, `tx_for/3,4`, `tx_for!/3,4`, `datalog/1`, `query/2,3`, and `query!/2,3` (plus `__using__/1`), and remove the temporary Step 1 `defdelegate`s from `lib/xitdb/tx_compiler.ex`.

---

## 3. Non-Functional Requirements & Invariants

1. **Incremental Compilation Greenness:** Every step must independently compile without warnings under `mix compile --warnings-as-errors` and pass the full test suite under `mix test`.
2. **Backward Compatibility:** All existing user-facing APIs (`use Xitdb.DSL`, `Xitdb.path/1`, `pull_pattern/1`, `tx`, `tx_for`, `datalog`, `query`, `~x`, `~q`) retain their exact existing signatures, return types, and semantics.
3. **Zero Runtime Overhead:** Compile-time AST folding and binary segment concatenation remain purely compile-time operations, and `tx` blocks without `update` incur zero staged-read tracking overhead (`staged_log: nil`).
4. **Clean Code Style:** All modified and newly introduced files must adhere to standard Elixir formatting (`mix format --check-formatted`).
