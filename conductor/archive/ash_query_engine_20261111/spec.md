# Specification: Track 12 — Six-Stage Query Execution Engine

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_query_engine_20261111`
> - **Wave:** Wave 2
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Module:** `lib/xitdb/ash/query.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete unit and integration test suite passes with zero warnings, verifying all six pipeline stages, `:context` and `:attribute` multitenancy narrowing, batched relationship & unrelated aggregates (`parent/1` and `join_filters`), relational expression calculations (`Ash.Expr.eval_hydrated/2`), and pagination.

---

## 1. Goal & Architecture

Ash's query engine decouples filter construction, sorting, calculation enrichment, and pagination from physical storage. `Xitdb.Ash.Query` implements a high-throughput, six-stage pipeline executing against immutable `%Xitdb.Cursor{}` / `%Xitdb{}` snapshot handles:

```
[Ash.Query] ──> 1. Narrow ──> 2. Hydrate ──> 3. Pre-Filter ──> 4. Enrich & Filter ──> 5. Order & Slice ──> 6. Project ──> [Results]
```

### The Six Stages

1. **Stage 1: Narrow (Tenant-Aware Index & Key Pushdown):**
   - Threads `query.tenant` into every `Indexer` call (`fetch_cursor/4`, `all_cursors/3`, `lookup_by_identity/5`, `lookup_secondary_eq/5`, `scan_secondary_range/5`) so `:context`-multitenant collections stay strictly isolated.
   - Conjunctive Primary Key: `O(1)` direct seek via `col[pk]`.
   - Unique Identity Seek: `O(log N)` seek via `idx.<col>.id_<name>[key]`, resolving `effective_tenant` from `eq_map[tenant_attr]` when `query.tenant == nil` on `:attribute`-multitenant resources.
   - `nested_in` Parent Jump: Direct navigation to `parent_col[parent_id][path]` when filtering by parent foreign key (activating automatically in Wave 3 Track 11B).
   - Secondary Index & Range Intersections: Intersects candidate ID sets from secondary B+Trees and `:counted_hash_set` posting lists.
   - Fallback: Collection scan using lazy `%Xitdb.Cursor{}` iteration.
2. **Stage 2: Hydrate:**
   - Decodes narrowed entity cursors into `%Resource{}` structs via `Xitdb.Ash.Codec.from_cursor/3`.
3. **Stage 3: Pre-Filter:**
   - Evaluates pure attribute predicates prior to calculating derived fields, discarding non-matching structs early.
4. **Stage 4: Enrich & Filter:**
   - Computes related and unrelated aggregates (`:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg`), batching FK lookups across all candidate records (`O(M)` / `O(N log M)` rather than `O(N * M)` full scans) while honoring `parent/1` references (`parent_stack`) and `join_filters` at every hop.
   - Computes expression and module calculations, falling back to `Ash.Filter.hydrate_refs/2` + `Ash.Expr.eval_hydrated/2` whenever `Ash.Expr.eval/2` returns `:unknown` on relational or `exists/2` expressions (e.g., `Deal.has_materials_access`).
   - Evaluates residual complex filters via `Ash.Filter.Runtime.filter_matches/4`.
5. **Stage 5: Order & Slice:**
   - Applies `distinct` / `distinct_sort` deduplication.
   - Evaluates runtime sorts via `Ash.Actions.Sort.runtime_sort/3` (supporting `tenant` and calculation sorts).
   - Applies `offset` and `limit` pagination in memory.
6. **Stage 6: Project:**
   - Applies `query.select` attribute masking last, replacing unselected fields with `%Ash.NotLoaded{}` while preserving primary keys and `always_selected?` attributes.

---

## 2. Technical Invariants

- **Query-Shaping Helpers & `DataLayer` Delegation:** `Xitdb.Ash.Query` provides pure shaping helpers (`new/2`, `filter/3`, `sort/3`, `distinct/3`, `distinct_sort/3`, `limit/3`, `offset/3`, `select/3`, `set_context/3`, `set_tenant/3`, `add_aggregate/3`, `add_aggregates/3`, `add_calculation/4`, `add_calculations/3`) returning `{:ok, %Query{}}`, delegated directly by `Xitdb.Ash.DataLayer`.
- **Zero `:unknown` Silent Nilification:** Relational expression calculations hydrate and load required cross-store relationships via `Ash.Expr.eval_hydrated/2` rather than silently returning `nil`.
- **Batched & Unrelated Aggregate Accuracy:** Unrelated aggregates (`related?: false` or empty `relationship_path` targeting an external `agg.resource`) query `agg.resource`'s own `Store.current_db/1`, substituting `%Ash.Query.Parent{}` expressions per root record.
- **Lock-Free Reads:** Queries execute concurrently against point-in-time `%Xitdb.Cursor{}` snapshots without messaging the `Store` GenServer.

---

## 3. Acceptance Criteria

1. Primary key and unique identity lookups (including `:attribute`-filtered and `:context`-scoped multitenant queries) bypass whole-collection scans.
2. Complex queries combining B+Tree secondary indexes, composite range bounds, relational expression calculations, and cross-store aggregates return accurate results.
3. Related aggregates batch destination fetches across `N` parent records without `O(N * M)` unindexed collection scans, and honor both `parent/1` filters and `join_filters`.
4. Unrelated aggregates (`exists` / `count` on another resource) query the target resource's store rather than `[root_record]`.
5. Pagination (`limit` and `offset`) and `select` masking produce exact Ash 3 results.
