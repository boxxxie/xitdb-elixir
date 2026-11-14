# Specification: Track 12 — Spark DSL Extension, BuildIndexPlan Transformer, Compile-Time Verifiers & Info Introspection

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_dsl_and_verifiers_20261111`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules & Files:** `xitdb/.formatter.exs`, `lib/xitdb/ash/dsl.ex`, `lib/xitdb/ash/info.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete unit and compile-time verification tests pass with zero warnings, ensuring `.formatter.exs` exports `locals_without_parens`, `BuildIndexPlan` safely transforms and persists index/reference plans without cyclic compilation dependencies, `VerifyNoSqlFragments` catches all SQL fragments, `VerifyCrossStoreReferences` enforces store boundaries and `nested_in` parent collection alignment, and `Xitdb.Ash.Info` yields `O(1)` persisted metadata.

---

## 1. Goal & Architecture

`Xitdb.Ash.Dsl` provides the declarative `xitdb do ... end` Spark extension for configuring `Xitdb.Ash.DataLayer` resources. It bridges developer declarations into strictly validated, pre-indexed metadata structures used by `Xitdb.Ash.Store`, `Xitdb.Ash.Indexer`, `Xitdb.Ash.Query`, and `Xitdb.Ash.Mutator`.

Track 12 implements:
1. **Formatter Export (`xitdb/.formatter.exs`):**
   - Exports `locals_without_parens` for all `xitdb` DSL keywords (`collection`, `store`, `index`, `nested_in`, `reference`, `search_field`, etc.) so consuming applications can import `:xitdb` formatting rules cleanly without requiring `:spark` in non-Ash projects.
2. **Spark Extension Entities & Schema (`Xitdb.Ash.Dsl`):**
   - `@index`: Single-attribute or composite B+Tree secondary indexes with optional naming.
   - `@nested_in`: Co-locates child entities into a parent's entity slot for 9-byte `fork` snapshots and hierarchical integrity.
   - `@search_field`: Tokenized attributes or cross-collection resolvers with boost weighting for transactional BM25 search.
   - `@reference`: Foreign-key rules configuring `on_delete` behaviors (`:nothing`, `:delete`, `:nilify`, `:restrict`) on `belongs_to` relationships.
   - Section options: `store`, `collection`, `index_relationships?`, `editable_fields`, `counted_set_fields`.
3. **Local Transformer (`BuildIndexPlan`):**
   - Runs strictly on the local resource's `dsl_state` after `Ash.Resource.Transformers.BelongsToAttribute`.
   - Validates declared index fields against existing resource attributes.
   - Synthesizes automatic secondary indexes for `belongs_to` foreign keys when `index_relationships?` is `true`.
   - Deduplicates indexes and validates field order.
   - Persists pre-partitioned entities (`:xitdb_indexes`, `:xitdb_nested_in`, `:xitdb_search_fields`, `:xitdb_references`) into Spark state for `O(1)` zero-allocation runtime lookup.
4. **Compile-Time Verifiers:**
   - **`VerifyNoSqlFragments`:** Walks calculations, identities, action changes, validations, read filters, and `Ash.Policy.Authorizer` rules to proactively catch and reject `%Ash.Query.Function.Fragment{}` structs and `{:fragment, _, _}` AST nodes.
   - **`VerifyCrossStoreReferences`:** Runs in Spark's post-compile verifier phase to verify that foreign-key cascading rules (`:delete`, `:nilify`) only target resources in the same `.xit` store, and validates that `nested_in` parent collections match their destination resources.
5. **Introspection Module (`Xitdb.Ash.Info`):**
   - Provides `O(1)` query APIs over compiled modules and in-flight DSL maps (`store`, `store!`, `collection`, `collection!`, `indexes`, `indexes_for_field`, `search_fields`, `references`, `nested_in`, `editable_fields`, `counted_set_fields`).

---

## 2. Technical Invariants & Compilation Boundaries

- **Zero `mix xref` Compilation Cycles:** `BuildIndexPlan` must never call code on external destination resources during initial compilation. Cross-resource validations are deferred to the post-compile verifier phase in `VerifyCrossStoreReferences`.
- **Soft Dependency Boundary:** All Ash-related code is guarded with `if Code.ensure_loaded?(Ash.DataLayer)` so `xitdb` remains fully functional as a lightweight standalone database client without Ash installed.
- **Deep Fragment Traversal:** `VerifyNoSqlFragments` must exhaustively inspect nested boolean expressions (`:and`, `:or`, `:not`), policy conditions, and calculation expressions to prevent runtime failures in the query planner.
- **Deterministic Field Ordering:** `indexes_for_field/2` must return matching indexes ordered from narrowest (single-column) to widest composite index for greedy Stage 1 query planning.

---

## 3. Acceptance Criteria

1. `mix format --check-formatted` succeeds on all resources utilizing `xitdb do ... end` without parens.
2. `BuildIndexPlan` generates synthetic indexes for `belongs_to` relationships when enabled, and avoids duplicate indexes when explicitly defined.
3. Defining a SQL `fragment(...)` anywhere in calculations, validations, or policies raises a compile-time `Spark.Error.DslError`.
4. Defining an `on_delete: :delete` reference targeting a resource in a different store raises a compile-time `Spark.Error.DslError`.
5. Defining a `nested_in` referencing a mismatched parent collection raises a compile-time `Spark.Error.DslError`.
6. `Xitdb.Ash.Info` returns persisted index and reference plans in `O(1)` time.
