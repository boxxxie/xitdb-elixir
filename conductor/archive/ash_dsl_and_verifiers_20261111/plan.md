# Implementation Plan: Track 8 — Unified Spark DSL Extension, `BuildIndexPlan` Transformer, Compile-Time Verifiers & Additive `Xitdb.Ash.Info` Introspection

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_dsl_and_verifiers_20261111` (`Track 8 [Wave 1]`)
> - **Prerequisite:** [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md) (`Track 5A [Wave 1]` only; `split_dsl_and_invert_ash_dependency_20261111` is deferred to Wave 4)
> - **Conductor Patch & Scope Note:** `wave1_mvp_prereqs_and_schema.patch` packages the Conductor specifications, execution plans, and complete self-contained reference implementations/diffs for Wave 1 execution (Tracks 5A and 8) against `master` (`v1.0.2`), including bootstrap implementations for `lib/xitdb/ash/store/snapshot.ex` and `lib/xitdb/ash/search.ex`.
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Compatibility Note:** Extend `lib/xitdb/ash/resource.ex`, `lib/xitdb/ash/info.ex`, and `.formatter.exs` **additively** (preserving 100% of shipped `v1.0.2` `Xitdb.Ash.Resource` MDM options/helpers and `Xitdb.DSL` macros, unifying top-level `Xitdb.Ash.{Index,NestedIn,Reference,SearchField}` structs, persisting DataLayer nesting under `:xitdb_nesting_plan` so `:xitdb_nested_in` never collides, and bootstrapping `lib/xitdb/ash/store/snapshot.ex` & `lib/xitdb/ash/search.ex`).
> - **Done When:** Complete test suite passes with zero warnings (`mix precommit`), verifying additive formatter exports, Spark DSL schema compilation, `BuildIndexPlan` validation & index synthesis, deep hydrated/unhydrated SQL fragment detection across all expression sections, post-compile cross-store/nullability/reference constraints, and `Xitdb.Ash.Info` persisted lookups without breaking any `v1.0.2` MDM resource tests.

---

## Phase 1: Additive Formatter Export (`.formatter.exs`)

- [x] Task: Update `.formatter.exs` additively (preserving all `Xitdb.DSL` and `v1.0.2` MDM locals)
    - [x] Keep all `dsl_locals_without_parens` (`tx: 2,3`, `tx!: 2,3`, `tx_for: 2,3,4`, `tx_for!: 2,3,4`, `put: 1,2`, `update: 2,3`, `rm: 1`, `append: 2`, `insert: 2,3`, `slice: 2,3`, `fork: 2`, `index_on: 3`, `init_col: 2`, `reset_col: 2`, `meta: 2`, `instant: 1`, `abort: 1`, `datalog: 1`, `query: 2,3`, `query!: 2,3`, `find: 1,2,3,4`, `from: 1`, `where: 1`)
    - [x] Keep all `v1.0.2` `Xitdb.Ash.Resource` MDM locals (`store: 1`, `collection: 1`, `merge_redirect_collection: 1`, `locked_ids_set: 1`, `companion_resource: 1`, `editable_fields: 1`, `passthru_fields: 1`, `computed_xitdb_fields: 1`, `field_aliases: 1`, `indexes: 1`, `sync_update_action: 1`, `ignored_sync_attributes: 1`, `lock_action: 1`, `unlock_action: 1`, `lock_change: 1`)
    - [x] Add `Xitdb.Ash.DataLayer` / `Xitdb.Ash.Dsl` locals (`nested_in: 1,2`, `index: 1,2`, `index_relationships?: 1`, `counted_set_fields: 1`, `search_field: 1,2`, `reference: 1,2`)
    - [x] Keep `scenario: 2` in local `locals_without_parens: exported_locals ++ [scenario: 2]` (excluded from `export`) and preserve `"{config,lib,test,benchmarks}/**/*.{ex,exs}"` in `inputs`
    - [x] Verify `mix format --check-formatted` passes cleanly.

---

## Phase 2: Unified Top-Level Structs, `Xitdb.Ash.Resource` & `Xitdb.Ash.Dsl`

- [x] Task: Create/update unified top-level Spark entity structs
    - [x] `lib/xitdb/ash/index.ex` (`Xitdb.Ash.Index` with `:fields`, `:name`, `:__identifier__`, `:__spark_metadata__`)
    - [x] `lib/xitdb/ash/nested_in.ex` (`Xitdb.Ash.NestedIn` unifying MDM `:parent`, `:as`, `:parent_key`, `:key` AND DataLayer `:parent_collection`, `:foreign_key`, `:path`, `cardinality: :many`, `:__identifier__`, `:__spark_metadata__`)
    - [x] `lib/xitdb/ash/search_field.ex` (`Xitdb.Ash.SearchField` with `:field`, `:boost`, `:resolver`, `:__identifier__`, `:__spark_metadata__`)
    - [x] `lib/xitdb/ash/reference.ex` (`Xitdb.Ash.Reference` with `:relationship`, `:on_delete`, `:__identifier__`, `:__spark_metadata__`)
- [x] Task: Extend `lib/xitdb/ash/resource.ex` additively and implement `lib/xitdb/ash/dsl.ex`
    - [x] Preserve optional `store` on `Xitdb.Ash.Resource` (`MutualUser` / `TestPerson` without `store` continue compiling cleanly) while adding `counted_set_fields` and `index_relationships?` options plus `@search_field`, `@index`, and `@references_section` entities
    - [x] Define `Xitdb.Ash.Dsl` with `use Spark.Dsl.Extension, sections: [@xitdb], transformers: [Xitdb.Ash.Transformers.BuildIndexPlan], verifiers: [Xitdb.Ash.Verifiers.VerifyNoSqlFragments, Xitdb.Ash.Verifiers.VerifyCrossStoreReferences]` so it executes directly via `extensions: [Xitdb.Ash.Dsl]` in Wave 1 and exports `sections/0`, `transformers/0`, `verifiers/0` for Wave 2 `Xitdb.Ash.DataLayer`
    - [x] Set `identifier: :relationship` on `@reference` and `identifier: :field` on `@search_field`.

---

## Phase 3: Local Transformer (`BuildIndexPlan`) & `tx_for` Compatibility

- [x] Task: Implement `Xitdb.Ash.Transformers.BuildIndexPlan`
    - [x] Configure `after?/1` for `Ash.Resource.Transformers.BelongsToAttribute` and `Ash.Resource.Transformers.CreateJoinRelationship`
    - [x] Validate `store` and `collection` are configured on the resource
    - [x] Reject composite primary keys (`length(pk_fields) > 1`) with `DslError` (`"composite primary keys are not yet supported by Xitdb.Ash.DataLayer"`)
    - [x] Validate explicit `index` entities: non-empty `fields`, all `fields` exist in resource attributes, no duplicate `fields` lists, and no colliding explicit `name`s
    - [x] Validate `counted_set_fields` (attribute exists and is `{:array, _}` or `MapSet`-compatible), `editable_fields` / `passthru_fields` (attributes exist), and `search_field` entries (`boost > 0.0`, attribute exists when `resolver` is `nil`)
    - [x] Synthesize auto-generated foreign-key `%Xitdb.Ash.Index{fields: [fk_attr], name: nil}` entries for `belongs_to` relationships when `index_relationships?` is `true`, deduplicating against primary keys and explicit leading fields
    - [x] Persist `:xitdb_nesting_plan` (`%Xitdb.Ash.NestedIn{} | nil` — zero collision with `:xitdb_nested_in`), `:xitdb_indexes`, `:xitdb_search_fields`, `:xitdb_references`, `:xitdb_store`, `:xitdb_collection`, and `:xitdb_normalized_indexes`, and inject `__xitdb_collection__/0`, `__xitdb_store__/0`, and `__xitdb_indexes__/0` so `Xitdb.DSL.tx_for` / `Xitdb.Ash.Tx.tx_for` works seamlessly on `DataLayer` / `Xitdb.Ash.Dsl` resources.

---

## Phase 4: Compile-Time Verifiers (`VerifyNoSqlFragments` & `VerifyCrossStoreReferences`)

- [x] Task: Implement `Xitdb.Ash.Verifiers.VerifyNoSqlFragments`
    - [x] Place `%Ash.Query.Function.Fragment{}`, `%Ash.Query.Call{name: :fragment}`, and `{:fragment, _meta, args} when is_list(args)` clauses **before** generic `%_{} = struct` traversal so Elixir 1.20 emits zero unreachable-clause warnings and catches unhydrated fragments
    - [x] Traverse `calculations`, `aggregates` (`filter`, `join_filters`), `relationships` (`filter`), `identities` (`where`), resource `validations` / `changes` / `preparations`, `actions` (`filter`, `changes`, `validations`, `preparations`), `Ash.Policy.Info.policies/1`, and `Ash.Policy.Info.field_policies/1`
- [x] Task: Implement `Xitdb.Ash.Verifiers.VerifyCrossStoreReferences`
    - [x] Validate every declared `%Xitdb.Ash.Reference{}` in `Info.references(dsl_state)` matches an actual `belongs_to` relationship on the resource (halting with `DslError` on typos)
    - [x] Reject `on_delete: :nilify` when the `belongs_to` relationship has `allow_nil?: false`
    - [x] Call `Code.ensure_compiled(dest)` before inspecting destination resources
    - [x] Allow plain `belongs_to` links (`on_delete: :nothing`) to `AshPostgres` or cross-store resources without error
    - [x] Reject cross-DB and cross-store `on_delete: :delete | :nilify | :restrict` cascades with clear `DslError` messages (matching `~r/[Cc]ross-store .*on_delete: :delete/`)
    - [x] Validate `nested_in` parent resource store and collection using safe `case` branches (zero bare `{:ok, _} = ...` `MatchError` crashes).

---

## Phase 5: Additive `Xitdb.Ash.Info` & Self-Contained Wave 1 Baselines (`Snapshot` & `Search`)

- [x] Task: Extend `lib/xitdb/ash/info.ex` additively
    - [x] Preserve `use Spark.InfoGenerator, extension: Xitdb.Ash.Resource, sections: [:xitdb]` and all `v1.0.2` MDM + Track 5A Step 3 helpers (`editable_field_strings/1`, `pull_fields/1`, `pull_pattern_for/1`, `nested_mappings/1`, `nested?/1`, `nested_under/2`, `entity_paths/2`, `resolve_store/2`, `resolve_lock_change/1`, atomic per-pair `cached_pair/4`, `__purge_pair_cache__/1`)
    - [x] Provide `DataLayer` helpers supporting both compiled module atoms and in-flight `Spark.Dsl.t()` maps: `store/1`, `store!/1`, `fetch_store/1`, `collection/1`, `collection!/1`, `fetch_collection/1`, `editable_fields/1`, `passthru_fields/1`, `counted_set_fields/1`, `index_relationships?/1`, `nested_in/1` (reading `:xitdb_nesting_plan`), `indexes/1`, `indexes_for_field/2`, `search_fields/1`, and `references/1`
- [x] Task: Bootstrap self-contained Wave 1 baseline modules
    - [x] Create/verify `lib/xitdb/ash/store/snapshot.ex` (`Xitdb.Ash.Store.Snapshot`)
    - [x] Create/verify `lib/xitdb/ash/search.ex` (`Xitdb.Ash.Search`, `RankCalculation`, `Storage`).

---

## Phase 6: Unit & Compile-Time Test Suite (`test/xitdb/ash/dsl_test.exs`)

- [x] Task: Implement `test/xitdb/ash/dsl_test.exs`
    - [x] Test DSL configuration parsing, defaults, and `Xitdb.Ash.Info` `O(1)` persisted lookups
    - [x] Test auto-generation and deduplication of `belongs_to` secondary indexes
    - [x] Test compile-time rejection of composite primary keys, unknown index/editable/`counted_set_fields` attributes, and duplicate index fields/names
    - [x] Test compile-time rejection of hydrated and unhydrated SQL `fragment(...)` across calculations, aggregates, relationship filters, preparations, actions, policies, and field policies
    - [x] Test post-compile rejection of unknown `reference` names, `on_delete: :nilify` on `allow_nil?: false`, cross-store/cross-DB `on_delete` cascades (`~r/[Cc]ross-store .*on_delete: :delete/`), and invalid `nested_in` parent stores/collections
    - [x] Test `tx_for` compatibility across both `Xitdb.Ash.Resource` (`indexes: [...]`) and `Xitdb.Ash.Dsl` (`index ...`) modules, then run `mix precommit`.
