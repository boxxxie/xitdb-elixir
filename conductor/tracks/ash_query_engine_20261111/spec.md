# Specification: Track 9 — Six-Stage Query Execution Engine

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_query_engine_20261111`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Module:** `lib/xitdb/ash/query.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Complete unit and integration test suite passes with zero warnings, verifying all six pipeline stages, primary key direct lookups, composite index intersections, runtime calculations, aggregates, and pagination.

---

## 1. Goal & Architecture

Ash's query engine decouples filter construction, sorting, calculation enrichment, and pagination from physical storage. `Xitdb.Ash.Query` implements a high-throughput, six-stage pipeline executing against immutable `%Xitdb{}` snapshot handles:

```
[Ash.Query] ──> 1. Narrow ──> 2. Hydrate ──> 3. Pre-Filter ──> 4. Enrich & Filter ──> 5. Order & Slice ──> 6. Project ──> [Results]
```

### The Six Stages

1. **Stage 1: Narrow (Index & Key Pushdown):**
   - Conjunctive Primary Key: `O(1)` direct seek via `col[pk]`.
   - `nested_in` Parent Jump: Direct navigation to `parent_col[parent_id][path]` when filtering by parent foreign key.
   - Unique Identity Seek: `O(log N)` seek via `idx.<col>.id_<name>[key]`.
   - Secondary Index & Range Intersections: Intersects candidate ID sets from secondary B+Trees and `:counted_hash_set` posting lists.
   - Fallback: Unbounded collection scan using lazy `%Xitdb.Cursor{}` iteration.
2. **Stage 2: Hydrate:**
   - Decodes narrowed entity cursors into `%Resource{}` structs via `Xitdb.Ash.Codec.from_cursor/3`.
3. **Stage 3: Pre-Filter:**
   - Evaluates pure attribute predicates prior to calculating expensive derived fields, discarding non-matching structs early.
4. **Stage 4: Enrich & Filter:**
   - Computes needed calculations and aggregates (`:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg`).
   - Evaluates residual complex filters via `Ash.Filter.Runtime.filter_matches/4`.
5. **Stage 5: Order & Slice:**
   - Applies distinct deductions.
   - Evaluates runtime sorts via `Ash.Actions.Sort.runtime_sort/3`.
   - Applies offset and limit pagination in memory.
6. **Stage 6: Project:**
   - Applies `query.select` attribute masking last, replacing non-selected fields with `%Ash.NotLoaded{}` while preserving primary keys.

---

## 2. Technical Invariants

- **Callback Contract:** All query-shaping callbacks (`filter/3`, `sort/3`, `distinct/3`, `distinct_sort/3`, `limit/3`, `offset/3`, `select/3`, `set_context/3`, `set_tenant/3`, `add_aggregates/3`, `add_calculations/3`) must return `{:ok, %Query{}}`.
- **Zero SQL Dependency:** Evaluates all expressions using portable `Ash.Expr` and `Ash.Filter.Runtime`.
- **Lock-Free Reads:** Queries execute concurrently against point-in-time `%Xitdb{}` handles without messaging the `Store` GenServer.

---

## 3. Acceptance Criteria

1. Primary key lookups bypass whole-collection scans and resolve in constant time.
2. Complex queries combining B+Tree secondary indexes, range bounds, calculations, and aggregates return accurate results.
3. Pagination (`limit` and `offset`) produces identical results to full-collection slicing.
4. Calculations and aggregates populate correctly into record struct fields and calculation maps.
