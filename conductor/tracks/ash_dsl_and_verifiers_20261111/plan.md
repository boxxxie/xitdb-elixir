# Implementation Plan: Track 12 — Spark DSL Extension, BuildIndexPlan Transformer, Compile-Time Verifiers & Info Introspection

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_dsl_and_verifiers_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Complete test suite passes with zero warnings, verifying formatter exports, Spark DSL schema compilation, `BuildIndexPlan` index synthesis, deep SQL fragment detection, post-compile cross-store constraints, and `Xitdb.Ash.Info` persisted lookups.

---

## Phase 1: Formatter Export (`.formatter.exs`)

- [ ] Task: Update `xitdb/.formatter.exs`
    - [ ] Export `spark_locals_without_parens` containing:
      - `collection: 1`
      - `counted_set_fields: 1`
      - `editable_fields: 1`
      - `index: 1`, `index: 2`
      - `index_relationships?: 1`
      - `nested_in: 1`, `nested_in: 2`
      - `reference: 1`, `reference: 2`
      - `search_field: 1`, `search_field: 2`
      - `store: 1`
    - [ ] Verify `mix format --check-formatted` passes on the repository.

---

## Phase 2: Spark DSL Extension & Entities (`lib/xitdb/ash/dsl.ex`)

- [ ] Task: Implement Spark entity structs in `lib/xitdb/ash/dsl.ex`
    - [ ] `Xitdb.Ash.Dsl.Index` (`:fields`, `:name`, `:__spark_metadata__`)
    - [ ] `Xitdb.Ash.Dsl.NestedIn` (`:parent_collection`, `:foreign_key`, `:path`, `:cardinality`, `:__spark_metadata__`)
    - [ ] `Xitdb.Ash.Dsl.SearchField` (`:field`, `:boost`, `:resolver`, `:__spark_metadata__`)
    - [ ] `Xitdb.Ash.Dsl.Reference` (`:relationship`, `:on_delete`, `:__spark_metadata__`)
- [ ] Task: Define Spark schema & DSL sections
    - [ ] `@index` entity declaration with args `[:fields]`
    - [ ] `@nested_in` entity declaration with args `[:parent_collection]`
    - [ ] `@search_field` entity declaration with args `[:field]`
    - [ ] `@reference` entity declaration with args `[:relationship]`
    - [ ] `@references_section` subsection
    - [ ] `@xitdb` top-level section with options (`:store`, `:collection`, `:index_relationships?`, `:editable_fields`, `:counted_set_fields`)
    - [ ] Extension registration with `Spark.Dsl.Extension` linking transformers and verifiers.

---

## Phase 3: Local Transformer (`BuildIndexPlan`)

- [ ] Task: Implement `BuildIndexPlan` transformer in `lib/xitdb/ash/dsl.ex`
    - [ ] Configure `after_compiler [Ash.Resource.Transformers.BelongsToAttribute]`
    - [ ] Validate declared secondary index fields against known resource attributes
    - [ ] Synthesize auto-generated foreign-key indexes for `belongs_to` relationships when `index_relationships?` is true
    - [ ] Deduplicate declared and auto-generated indexes
    - [ ] Persist pre-partitioned entities:
      - `:xitdb_indexes`
      - `:xitdb_nested_in`
      - `:xitdb_search_fields`
      - `:xitdb_references`

---

## Phase 4: Compile-Time Verifiers

- [ ] Task: Implement `VerifyNoSqlFragments` verifier
    - [ ] Inspect resource calculations for `%Ash.Query.Function.Fragment{}` and `{:fragment, _, _}` AST
    - [ ] Inspect unique identity `where:` expressions
    - [ ] Inspect resource validations and action validations
    - [ ] Inspect resource changes and action changes
    - [ ] Inspect action read filters and action atomic changes
    - [ ] Inspect `Ash.Policy.Authorizer` policies and conditions
    - [ ] Raise descriptive `Spark.Error.DslError` on any detected SQL fragments.
- [ ] Task: Implement `VerifyCrossStoreReferences` post-compile verifier
    - [ ] Post-compile execution avoiding circular compilation locks
    - [ ] Verify `belongs_to` foreign-key references: reject `:delete` and `:nilify` cascades when destination resource belongs to a different `Xitdb.Ash.Store`
    - [ ] Verify `nested_in` parent collection matches destination resource collection.

---

## Phase 5: Introspection Module (`lib/xitdb/ash/info.ex`)

- [ ] Task: Implement `Xitdb.Ash.Info`
    - [ ] `store/1` and `store!/1`
    - [ ] `collection/1` and `collection!/1`
    - [ ] `editable_fields/1` and `counted_set_fields/1`
    - [ ] `index_relationships?/1`
    - [ ] `nested_in/1`
    - [ ] `indexes/1` and `indexes_for_field/2` (ordered narrowest to widest)
    - [ ] `search_fields/1`
    - [ ] `references/1`
    - [ ] Support both compiled module atoms and in-flight `Spark.Dsl.t()` states.

---

## Phase 6: Unit & Compile-Time Test Suite

- [ ] Task: Implement `test/xitdb/ash/dsl_test.exs`
    - [ ] Test DSL configuration parsing and default values
    - [ ] Test auto-generation and deduplication of `belongs_to` secondary indexes
    - [ ] Test compile-time rejection of unknown index fields
    - [ ] Test compile-time rejection of SQL `fragment(...)` in calculations, validations, and policies
    - [ ] Test post-compile rejection of cross-store cascading references
    - [ ] Test post-compile rejection of mismatched `nested_in` parent collections
    - [ ] Test `Xitdb.Ash.Info` accessor functions.
