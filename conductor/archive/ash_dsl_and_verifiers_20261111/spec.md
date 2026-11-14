# Specification: Track 8 — Unified Spark DSL Extension, `BuildIndexPlan` Transformer, Compile-Time Verifiers & Additive `Xitdb.Ash.Info` Introspection

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_dsl_and_verifiers_20261111` (`Track 8 [Wave 1]`)
> - **Prerequisite:** [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md) (`Track 5A [Wave 1]` only; `split_dsl_and_invert_ash_dependency_20261111` is deferred to Wave 4 and is **not** a prerequisite)
> - **Conductor Patch & Scope Note:** `wave1_mvp_prereqs_and_schema.patch` packages the Conductor specifications, execution plans, and complete self-contained reference implementations/diffs for Wave 1 execution (Tracks 5A and 8) against `master` (`v1.0.2`), including complete bootstrap implementations for `lib/xitdb/ash/store/snapshot.ex` and `lib/xitdb/ash/search.ex` so applying Wave 1 from `master` has zero missing module baselines.
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules & Files:**
>   - `.formatter.exs`
>   - `lib/xitdb/ash/index.ex`, `lib/xitdb/ash/nested_in.ex`, `lib/xitdb/ash/reference.ex`, `lib/xitdb/ash/search_field.ex`
>   - `lib/xitdb/ash/resource.ex`, `lib/xitdb/ash/dsl.ex`, `lib/xitdb/ash/info.ex`, `lib/xitdb/ash/tx.ex`
>   - `lib/xitdb/ash/transformers/build_index_plan.ex` (or inline in `lib/xitdb/ash/dsl.ex`), `lib/xitdb/ash/verifiers/verify_no_sql_fragments.ex`, `lib/xitdb/ash/verifiers/verify_cross_store_references.ex`
>   - Self-contained Wave 1 bootstrap baselines: `lib/xitdb/ash/store/snapshot.ex`, `lib/xitdb/ash/search.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **CRITICAL v1.0.2 Compatibility Guardrail:** Do **not** overwrite `lib/xitdb/ash/resource.ex`, `lib/xitdb/ash/info.ex`, or `.formatter.exs` from scratch. Extend `Xitdb.Ash.Resource` and `Xitdb.Ash.Info` **additively** so all shipped `v1.0.2` MDM sync-projection APIs (`editable_field_strings/1`, `pull_fields/1`, `pull_pattern_for/1`, `nested_mappings/1`, `nested?/1`, `nested_under/2`, `entity_paths/2`, `resolve_store/2`, `resolve_lock_change/1`, `WireChanges`, `VerifySyncProjection`, `cached_pair/4`, `__purge_pair_cache__/1`) remain 100% intact alongside `Xitdb.Ash.DataLayer` / `Xitdb.Ash.Dsl`.
> - **Done When:** Complete unit and compile-time verification tests pass with zero warnings, ensuring `.formatter.exs` preserves all `Xitdb.DSL` + `Xitdb.Ash.Resource` + `Xitdb.Ash.DataLayer` locals (keeping test-only `scenario: 2` local), `BuildIndexPlan` persists `:xitdb_nesting_plan` without colliding with `:xitdb_nested_in`, rejects composite primary keys and invalid index/attribute declarations, `VerifyNoSqlFragments` catches hydrated and unhydrated SQL fragments across all resource expression sections, `VerifyCrossStoreReferences` enforces store/nullability/reference boundaries without `MatchError` crashes, and `Xitdb.Ash.Info` yields `O(1)` persisted metadata alongside all `v1.0.2` helpers.

---

## 1. Goal & Architecture

`Xitdb.Ash.Dsl` provides the declarative `xitdb do ... end` Spark extension for configuring `Xitdb.Ash.DataLayer` resources (and can be attached directly via `extensions: [Xitdb.Ash.Dsl]` in Wave 1 tests prior to Wave 2's `Xitdb.Ash.DataLayer`). It bridges developer declarations into strictly validated, pre-indexed metadata structures consumed by `Xitdb.Ash.Store`, `Xitdb.Ash.Indexer`, `Xitdb.Ash.Query`, `Xitdb.Ash.Mutator`, and `Xitdb.Ash.Search`.

Track 8 implements:

1. **Additive Formatter Export (`.formatter.exs`):**
   - Preserves **100%** of existing `Xitdb.DSL` transaction/Datalog macros (`tx`, `tx!`, `tx_for`, `tx_for!`, `put`, `update`, `rm`, `append`, `insert`, `slice`, `fork`, `index_on`, `init_col`, `reset_col`, `meta`, `instant`, `abort`, `datalog`, `query`, `query!`, `find`, `from`, `where`) and `v1.0.2` `Xitdb.Ash.Resource` MDM options (`store`, `collection`, `merge_redirect_collection`, `locked_ids_set`, `companion_resource`, `editable_fields`, `passthru_fields`, `computed_xitdb_fields`, `field_aliases`, `indexes`, `sync_update_action`, `ignored_sync_attributes`, `lock_action`, `unlock_action`, `lock_change`) while adding `Xitdb.Ash.DataLayer` keywords (`nested_in: 1,2`, `index: 1,2`, `index_relationships?: 1`, `counted_set_fields: 1`, `search_field: 1,2`, `reference: 1,2`).
   - Keeps ATDD test-only `scenario: 2` in local `locals_without_parens` (`exported_locals ++ [scenario: 2]`) out of `export`, and preserves `"benchmarks"` in `inputs`.

2. **Unified Top-Level Entity Structs (`Xitdb.Ash.{Index, NestedIn, Reference, SearchField}`):**
   - `Xitdb.Ash.Index` (`:fields`, `:name`, `:__identifier__`, `:__spark_metadata__`)
   - `Xitdb.Ash.NestedIn` unifying both `v1.0.2` MDM fields (`:parent`, `:as`, `:parent_key`, `:key`) and `DataLayer` subtree fields (`:parent_collection`, `:foreign_key`, `:path`, `cardinality: :many`, `:__identifier__`, `:__spark_metadata__`)
   - `Xitdb.Ash.SearchField` (`:field`, `:boost`, `:resolver`, `:__identifier__`, `:__spark_metadata__`)
   - `Xitdb.Ash.Reference` (`:relationship`, `:on_delete`, `:__identifier__`, `:__spark_metadata__`)

3. **Spark Extension Registration (`Xitdb.Ash.Dsl` & Additive `Xitdb.Ash.Resource`):**
   - `Xitdb.Ash.Resource` keeps `store` optional (falling back to `:default_store` / `context[:xitdb_store]` so `v1.0.2` MDM resources like `MutualUser` that omit `store` compile cleanly) while adding `counted_set_fields` and `index_relationships?` options and `@search_field`, `@index`, and `@references_section` entities.
   - `Xitdb.Ash.Dsl` registers `use Spark.Dsl.Extension, sections: [@xitdb], transformers: [Xitdb.Ash.Transformers.BuildIndexPlan], verifiers: [Xitdb.Ash.Verifiers.VerifyNoSqlFragments, Xitdb.Ash.Verifiers.VerifyCrossStoreReferences]`, simultaneously acting as a complete Spark extension in Wave 1 (`extensions: [Xitdb.Ash.Dsl]`) and exporting `sections/0`, `transformers/0`, `verifiers/0` for `Xitdb.Ash.DataLayer` in Wave 2.
   - `@reference` declares `identifier: :relationship` and `@search_field` declares `identifier: :field`.

4. **Local Transformer (`BuildIndexPlan`):**
   - Runs strictly on the local resource's `dsl_state` after `Ash.Resource.Transformers.BelongsToAttribute` and `Ash.Resource.Transformers.CreateJoinRelationship`.
   - Enforces required `store` and `collection` options on `Xitdb.Ash.Dsl` / `Xitdb.Ash.DataLayer` resources.
   - Rejects composite primary keys (`length(pk_fields) > 1`) at compile time with `"composite primary keys are not yet supported by Xitdb.Ash.DataLayer"`, aligning compile-time validation with Wave 2 `DataLayer.can?(_, :composite_primary_key) == false`.
   - Validates explicit `index` declarations (non-empty `fields`, all attributes defined on the resource, no duplicate `fields` lists, no colliding custom `name`s), `counted_set_fields` (must exist as `{:array, _}` or `MapSet`-compatible attributes), `editable_fields` / `passthru_fields` (must exist as resource attributes), and `search_field` entries (`boost > 0.0`, attribute exists when `resolver` is `nil`).
   - Synthesizes automatic secondary indexes (`%Xitdb.Ash.Index{fields: [fk_attr], name: nil}`) for `belongs_to` foreign keys when `index_relationships?` is `true`, deduplicating against primary keys and explicit indexes whose leading field already covers `fk_attr`.
   - Persists `:xitdb_nesting_plan` (`%Xitdb.Ash.NestedIn{} | nil` — avoiding any collision with `Xitdb.Ash.Resource`'s `:xitdb_nested_in` list!), `:xitdb_indexes`, `:xitdb_search_fields`, `:xitdb_references`, `:xitdb_store`, `:xitdb_collection`, and `:xitdb_normalized_indexes`, and defines `__xitdb_collection__/0`, `__xitdb_store__/0`, and `__xitdb_indexes__/0` so `Xitdb.DSL.tx_for` / `Xitdb.Ash.Tx.tx_for` works identically across both `v1.0.2` MDM (`indexes: [...]`) and `DataLayer` (`index ...`) resources.

5. **Compile-Time Verifiers (`VerifyNoSqlFragments` & `VerifyCrossStoreReferences`):**
   - **`VerifyNoSqlFragments`:** Places `%Ash.Query.Function.Fragment{}`, `%Ash.Query.Call{name: :fragment}`, and `{:fragment, _meta, args} when is_list(args)` clauses **before** the generic `%_{} = struct` traversal clause (preventing unreachable-clause warnings in Elixir 1.20 while catching both hydrated and unhydrated fragments), and exhaustively audits:
     - `calculations`
     - `aggregates` (`filter` and `join_filters`)
     - `relationships` (`filter`)
     - `identities` (`where`)
     - `validations`, `changes`, and `preparations` (resource-level)
     - `actions` (`filter`, `changes`, `validations`, `preparations`)
     - `Ash.Policy.Info.policies/1` and `Ash.Policy.Info.field_policies/1` (when `Ash.Policy.Info` is loaded and `Ash.Policy.Authorizer` is active)
   - **`VerifyCrossStoreReferences`:**
     - Iterates over declared `Info.references(dsl_state)` first and halts with `DslError` if any `ref.relationship` does not match a `belongs_to` relationship on the resource (eliminating silent typos).
     - Rejects `on_delete: :nilify` when the `belongs_to` relationship has `allow_nil?: false` (`"cannot set `on_delete: :nilify` when `belongs_to :...` has `allow_nil?: false`"`).
     - Calls `Code.ensure_compiled(dest)` before inspecting destination resources.
     - Allows plain `belongs_to` relationships (`on_delete: :nothing`) pointing to `AshPostgres` or cross-store resources, while rejecting `on_delete in [:delete, :nilify, :restrict]` toward non-Xitdb resources or distinct `.xit` stores (`"Cross-store on_delete: :delete from ... to ... is not supported."`).
     - Validates `nested_in` parent resources via safe `case` expressions (zero bare `{:ok, _} = ...` `MatchError` crashes) when a destination lacks Xitdb configuration, uses a different store, or declares a mismatched collection.

6. **Additive Introspection (`Xitdb.Ash.Info`) & Self-Contained Wave 1 Baselines (`Snapshot` & `Search`):**
   - Preserves 100% of `v1.0.2` MDM + Track 5A Step 3 functions (`Spark.InfoGenerator` `xitdb_*` helpers, `editable_field_strings/1`, `pull_fields/1`, `pull_pattern_for/1`, `nested_mappings/1`, `nested?/1`, `nested_under/2`, `entity_paths/2`, `resolve_store/2`, `resolve_lock_change/1`, atomic per-pair `cached_pair/4`, `__purge_pair_cache__/1`) while providing `store/1`, `store!/1`, `collection/1`, `collection!/1`, `editable_fields/1`, `passthru_fields/1`, `counted_set_fields/1`, `index_relationships?/1`, `nested_in/1` (reading `:xitdb_nesting_plan`), `indexes/1`, `indexes_for_field/2`, `search_fields/1`, and `references/1`.
   - Includes complete reference implementations for `lib/xitdb/ash/store/snapshot.ex` and `lib/xitdb/ash/search.ex` so Wave 1 compiles cleanly from `master` with zero missing dependencies.

---

## 2. Technical Invariants & Compilation Boundaries

- **Zero `mix xref` Compilation Cycles:** `BuildIndexPlan` never calls functions on external destination resources during initial compilation. Cross-resource store/collection checks run strictly in `VerifyCrossStoreReferences` using `Code.ensure_compiled/1`.
- **Distinct Nesting Persistence Keys:** `WireChanges` (`Xitdb.Ash.Resource`) persists `:xitdb_nested_in` as `[%Xitdb.Ash.NestedIn{}]`, whereas `BuildIndexPlan` (`Xitdb.Ash.Dsl` / `Xitdb.Ash.DataLayer`) persists `:xitdb_nesting_plan` as `%Xitdb.Ash.NestedIn{} | nil`. Neither extension ever clobbers the other's persisted Spark state.
- **Soft Dependency Boundary:** All Ash/Spark modules are guarded with `if Code.ensure_loaded?(...)` so `xitdb` compiles cleanly in standalone projects without Ash installed.
- **Deterministic Field Ordering:** `indexes_for_field/2` returns matching indexes ordered from narrowest (single-column) to widest composite index for greedy Stage 1 query planning.

---

## 3. Acceptance Criteria

1. `mix format --check-formatted` succeeds across `lib/`, `test/`, and `benchmarks/`, preserving all `Xitdb.DSL`, `Xitdb.Ash.Resource`, and `Xitdb.Ash.DataLayer` locals without exporting `scenario: 2`.
2. Existing `v1.0.2` `Xitdb.Ash.Resource` fixtures (`TestOrg`, `TestPerson`, `TestPhone`, `TestOrgProfile`, `TestSearchProfile`, `MutualUser`) compile without warnings even when `store` is omitted, and `tx_for` works with both `Xitdb.Ash.Resource` (`indexes: [...]`) and `Xitdb.Ash.Dsl` (`index ...`) modules.
3. `BuildIndexPlan` synthesizes `belongs_to` FK indexes when `index_relationships?: true`, deduplicates against explicit indexes, and raises `Spark.Error.DslError` on composite primary keys, duplicate index fields/names, invalid `counted_set_fields`, or unknown attributes.
4. Defining `fragment(...)` (hydrated or unhydrated `%Ash.Query.Call{name: :fragment}`) in calculations, aggregates, relationship filters, identities, validations, changes, preparations, action clauses, policies, or field policies raises `Spark.Error.DslError`.
5. `VerifyCrossStoreReferences` rejects typos in `reference :nonexistent`, rejects `on_delete: :nilify` on `allow_nil?: false` foreign keys, rejects cross-store/cross-DB `on_delete: :delete | :nilify | :restrict` (matching `~r/[Cc]ross-store .*on_delete: :delete/`), allows plain `:nothing` cross-DB `belongs_to` links, and reports `DslError` (never `MatchError`) on invalid `nested_in` parents.
6. `Xitdb.Ash.Info`, `Xitdb.Ash.Store.Snapshot`, and `Xitdb.Ash.Search` compile with zero warnings under `mix precommit`.
