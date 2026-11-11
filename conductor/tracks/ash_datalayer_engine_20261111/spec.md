# Specification: Track 1 — `Xitdb.Ash.DataLayer` Engine (in `xitdb` repo)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `xitdb_datalayer_1_engine_20261111`
> - **Parent Track:** [`pure_xitdb_ash_datalayer_20261111`](../pure_xitdb_ash_datalayer_20261111/)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Consumer Repository:** `caasa/connect` (`/home/pauli/projects/nvestiv/caasa/connect`)
> - **Primary References:**
>   - [Reference 1: Architecture Vision & Zero-Postgres Domain](../pure_xitdb_ash_datalayer_20261111/reference.md)
>   - [Reference 2: DataLayer Architecture & Implementation Internals](../pure_xitdb_ash_datalayer_20261111/reference_data_layer_implementation.md)
>   - [Reference 4: Ash 3 Contract Fixes & Standalone Verification Suite](./reference_ash3_contract_fixes_and_verification_suite.md)
>   - [Reference 5: In-Xitdb BM25 Search & Lock-Free Atomic Snapshot Reads](../pure_xitdb_ash_datalayer_20261111/reference_in_xitdb_search_and_atomic_snapshots.md)

---

## 1. Goal & Architectural Scope

Implement `Xitdb.Ash.DataLayer` and `Xitdb.Ash.Search` as a complete, first-class Ash 3.37.2+ data layer and search engine within the standalone `xitdb` package. This layer gives Ash applications native `O(1)` primary key reads, binary-key B+Tree secondary indexes, monotonic integer sequence allocation, lock-free `:persistent_term` + `:atomics` snapshot access (~10ns, zero global GC), caller-process writer leases with store-scoped savepoints, in-Xitdb BM25 search (`idx.search`), and process-isolated `async: true` testing without PostgreSQL or any external database dependencies.

All Ash functionality must be **strictly optional** in `xitdb/mix.exs` so non-Ash callers of `xitdb` incur zero dependency overhead.

---

## 2. Package Boundaries & Optional Dependencies

In `xitdb/mix.exs`:
```elixir
def deps do
  [
    {:ash, "~> 3.37 and >= 3.37.2", optional: true},
    {:spark, "~> 2.2", optional: true},
    {:nimble_options, "~> 1.1 and >= 1.1.1"},
    {:telemetry, "~> 1.2"}
  ]
end

def cli do
  [preferred_envs: [precommit: :test]]
end

defp package do
  [
    files: ~w(lib .formatter.exs mix.exs README* LICENSE* usage-rules.md)
  ]
end
```

All modules under `lib/xitdb/ash/` must begin with:
```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  # module implementation
end
```
to ensure `mix compile` in `xitdb` succeeds even when `:ash` is omitted.

---

## 3. Module Inventory & Ash 3.37.2+ Contract Alignment (`lib/xitdb/ash/`)

### 3.1 `dsl.ex` (`Xitdb.Ash.Dsl`)
Spark DSL extension defining the `xitdb do ... end` section for Ash resources:
- `store`: Required atom naming the `Xitdb.Ash.Store` module (e.g. `CaasaConnect.MDM.Store`).
- `collection`: Atom collection name in Xitdb slot tree (defaults to underscored resource name).
- `Index`: Entity defining secondary B+Tree index (`fields`, `name`).
- `NestedIn`: Entity defining subtree containment (`parent_collection`, `foreign_key`, `path`, `cardinality: :one | :many`).
- `SearchField`: Entity defining tokenized BM25 search fields (`field`, `resolver`, `boost: 1.0`).
- `Reference`: Entity defining foreign key relationships with `on_delete: :nothing | :delete | :nilify | :restrict`.
- `Transformers.BuildIndexPlan`: Automatically adds every `belongs_to` `source_attribute` to the secondary index plan and persists outgoing `%Reference{}` rules.
- `Verifiers.VerifyNoSqlFragments`: Raises at compile time if `Ash.Query.Function.Fragment` appears.
- `Verifiers.VerifyCrossStoreReferences`: Verifies every `reference` with `on_delete: :delete | :nilify | :restrict` targets a resource on the **same** store, directing cross-store cleanup to `Ash.Signals`.

### 3.2 `info.ex` (`Xitdb.Ash.Info`)
Compile-time DSL introspection helpers:
- `store!/1`, `store/1`
- `collection!/1`, `collection/1`
- `nested_in/1`
- `indexes/1`, `search_fields/1`
- `references/1`, `incoming_delete_rules/2`

### 3.3 `codec.ex` (`Xitdb.Ash.Codec`)
Type conversion between Ash types and Xitdb slots:
- `Ash.Type.CiString`: Store original string; hydrate `%Ash.CiString{}`; index with `String.downcase/1`.
- Integer keys and `:utc_datetime` / `:utc_datetime_usec`: Encode as sign-flipped 64-bit big-endian binaries (`<<bxor(val, 0x8000_0000_0000_0000)::unsigned-big-64>>`) so `:sorted_map` B+Trees sort negative and multi-digit values accurately.
- `Ash.Type.Date`: Encode as ISO-8601 `"YYYY-MM-DD"` strings.
- Composite identities: Prefix parts with 32-bit byte lengths (scoped by `tenant`) to prevent collision.
- Safe atom & embedded serialization via `Ash.Type.cast_stored/3` and `Ash.Type.dump_to_embedded/3`.

### 3.4 `indexer.ex` (`Xitdb.Ash.Indexer`)
Index maintenance for `:sorted_map` and `:hash_map` slots:
- `_parent` locator index: `idx.<collection>._parent[id] => parent_id` for `nested_in` subtrees.
- Unique identity indexes: `idx.<collection>.id_<name>[key] => entity_id` honoring `identity.nils_distinct?`.
- Secondary multi-value indexes: `idx.<collection>.<index_name>[key] => :counted_hash_set(entity_ids)`.
- Recursive subtree cleanup: When deleting or reparenting a child, purges/updates child `_parent`, secondary, identity, and search entries in the same transaction.
- **Ash 3 Upsert Identity Struct Handling:** `find_upsert_existing_id/5` accepts `%Ash.Resource.Identity{}` struct, atom name, or fallback key match list to correctly resolve existing record IDs during upsert.

### 3.5 `search.ex` (`Xitdb.Ash.Search`)
In-Xitdb transactional BM25 search engine:
- Persisted slot structure: `idx.search.<collection>` with `meta` (`doc_count`, `total_len`), `docs[id]` (`len`, `terms`), and `terms[term]` (`:sorted_map` B+Tree -> `:counted_map` postings `doc_id => tf`).
- Document frequency (`df`) is `O(1)` via `Enum.count/1`.
- Prefix searches slice `[prefix, prefix <> <<0xFF>>)` directly on the B+Tree with zero edge-ngram bloat.
- Incremental indexing diffs old terms against new terms in the same write transaction.
- Queries execute in `O(log V)` and observe the exact same snapshot moment as `Ash.read`.

### 3.6 `store.ex` & `store/snapshot.ex` (`Xitdb.Ash.Store` & `Store.Snapshot`)
Store management, atomic snapshot publication, and writer leases:
- `use Xitdb.Ash.Store, otp_app: :app` macro generating caller-supervised GenServer with reverse-FK boot compilation (`domains: [...]`).
- **Lock-Free Atomic Snapshot Publishing (`:persistent_term` + `:atomics`):**
  Store `{base_db, atomics_ref, reverse_fks}` in `:persistent_term` once at boot. On commit, execute `:atomics.put(atomics_ref, 1, moment)` (~5ns atomic store, zero global GC). Readers call `Snapshot.committed_db(store)` (~10ns), guaranteeing atomic consistency between BM25 search and entity hydration.
- **Caller-Process Writer Leases & Savepoints:**
  `Store.transact/3` acquires a monitored writer lease from `Store` and executes the transaction closure **inside the caller process** (preserving `self()`, `$callers`, `Swoosh` sandbox, and multi-store dictionaries). Nested transactions snapshot `prev_db` and catch `{:xitdb_ash_rollback, ^store, reason}` for `O(1)` rollback.
- 3-tier read-handle resolution:
  1. Process dictionary (`:xitdb_tx_db`) during active transactions.
  2. ETS table (`Xitdb.Ash.TestSandbox`) during active ExUnit tests.
  3. `Snapshot.committed_db(store)` for lock-free application reads.

### 3.7 `query.ex` (`Xitdb.Ash.Query`)
Six-stage query execution engine:
- All query-shaping callbacks (`filter/3`, `sort/3`, `distinct/3`, `distinct_sort/3`, `limit/3`, `offset/3`, `select/3`, `set_context/3`, `set_tenant/3`, `add_aggregates/3`, `add_calculations/3`) return `{:ok, %Query{}}`.
- Six stages:
  1. **Narrow:** Conjunctive PK (`O(1)`), `nested_in` parent jump, identity, or secondary FK/range B+Tree intersection (`O(log N)`).
  2. **Hydrate:** Decode narrowed cursors into `%Resource{}` structs via `Codec.from_cursor/2`.
  3. **Pre-Filter:** Evaluate pure attribute predicates prior to computing derived fields.
  4. **Enrich & Filter:** Compute needed aggregates & calculations, then evaluate `Ash.Filter.Runtime.filter_matches/4`.
  5. **Order & Slice:** Apply distinct, runtime sort (`Ash.Actions.Sort.runtime_sort/3`), offset, and limit.
  6. **Project:** Apply `query.select` attribute masking last.
- Aggregates: Compute `:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg` natively.

### 3.8 `mutator.ex` (`Xitdb.Ash.Mutator`)
Atomic mutations executed inside the single-writer lease:
- Implements `create/2`, `bulk_create/3`, `update/2`, `update_query/4`, `upsert/4`, `destroy/2`, and `destroy_query/4`.
- Monotonic sequence allocation in `meta.sequences[collection]` with duplicate-PK rejection on `create/2`.
- Atomic policy & validation enforcement: Hydrate target records and enforce `changeset.filter` (`FilterCheck` write policies + optimistic locks) and `changeset.atomic_validations` before evaluating `changeset.atomics` (`Ash.Expr.eval/2`).
- Tenant-scoped unique identities & partial `where` filters.
- Enforce same-store reverse FK `on_delete` rules (`:restrict`, `:nilify`, `:delete`) and sync `idx.search` in the same transaction.

### 3.9 `data_layer.ex` (`Xitdb.Ash.DataLayer`)
The `@behaviour Ash.DataLayer` implementation:
- Declares capabilities: `:create`, `:bulk_create`, `:read`, `:update`, `:update_query`, `:destroy`, `:destroy_query`, `:upsert`, `:transact`, `{:atomic, :update}`, `{:atomic, :destroy}`, `:calculate`, `:boolean_filter`, `:filter`, `:sort`, `:distinct`, `:distinct_sort`, `:limit`, `:offset`, `:select`, `:aggregate_filter`, `:aggregate_sort`, and aggregates.
- `resource_to_query/2` returns `%Query{}`; shaping callbacks return `{:ok, %Query{}}`.
- Pass-through `join/7` callback returning `{:ok, query}`.
- Wraps `run_query/2` in `:telemetry.span([:xitdb, :ash, :query], ...)` with `:status` metadata.

### 3.10 `test_sandbox.ex` (`Xitdb.Ash.TestSandbox`)
ExUnit test sandbox:
- `checkout/1`: Copies initial store database handle via lightweight copy-on-write fork (`Xitdb.fork/1`). Stores test handle in ETS keyed by `self()` and propagates across `$callers`.
- Guarantees complete test isolation with `async: true` without disk persistence or database rollback transactions.

---

## 4. Test Strategy & Acceptance Criteria

1. **Standalone ExUnit Verification Suite (`xitdb/test/xitdb/ash/data_layer_test.exs`):**
   - Dual-store architecture (`TestMdmStore` and `TestAppStore`).
   - Monotonic integer sequence ID allocation (`meta.sequences`) and duplicate-PK rejection.
   - Case-insensitive `CiString` identities and counted sets.
   - Partial `where:` identities on create and status transitions.
   - `nested_in` containment (`:many` and `:one`) with `_parent` locator index resolution.
   - In-Xitdb BM25 search queries with prefix range scans.
   - Filtered aggregates (`count :active_roster_count`) and cross-store `exists(...)` filters.
   - `Ash.Policy.Authorizer` cross-store read/write policy evaluation.
   - Atomic updates and nested savepoint rollbacks (`Ash.DataLayer.rollback/2`).
   - Foreign key cascading rules (`:restrict`, `:delete`, `:nilify`).
   - `TestSandbox` `$callers` propagation across `Task.async_stream`.
   - Compile-time rejection of SQL `fragment(...)` expressions via `VerifyNoSqlFragments`.
   - Compile-time rejection of cross-store `on_delete` references via `VerifyCrossStoreReferences`.
2. **Quality Gates:**
   - `mix format --check-formatted`
   - `mix compile --warnings-as-errors`
   - `mix test test/xitdb/ash/data_layer_test.exs` passes 100%.
   - Zero required dependencies when compiled in a standalone project without Ash.
