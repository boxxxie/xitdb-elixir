# Specification: Track 1 — `Xitdb.Ash.DataLayer` Engine (in `xitdb` repo)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `xitdb_datalayer_1_engine_20261111`
> - **Parent Track:** [`pure_xitdb_ash_datalayer_20261111`](../pure_xitdb_ash_datalayer_20261111/)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Consumer Repository:** `caasa/connect` (`/home/pauli/projects/nvestiv/caasa/connect`)
> - **Primary References:**
>   - [Reference 2: DataLayer Architecture & Implementation Internals](../pure_xitdb_ash_datalayer_20261111/reference_data_layer_implementation.md)
>   - [Reference 3: Concrete Implementation Modules](../pure_xitdb_ash_datalayer_20261111/reference_modules_implementation.md)
>   - [Reference 4: Ash 3 Contract Fixes & Standalone Verification Suite](./reference_ash3_contract_fixes_and_verification_suite.md)

---

## 1. Goal & Architectural Scope

Implement `Xitdb.Ash.DataLayer` as a complete, first-class Ash 3 data layer extension within the standalone `xitdb` package. This layer gives Ash applications native `O(1)` primary key reads, B+Tree secondary indexes, monotonic integer sequence allocation, lock-free `:persistent_term` snapshot access, transaction savepoints, and process-isolated `async: true` testing without PostgreSQL or any external database dependencies.

All Ash functionality must be **strictly optional** in `xitdb/mix.exs` so non-Ash callers of `xitdb` incur zero dependency overhead.

---

## 2. Package Boundaries & Optional Dependencies

In `xitdb/mix.exs`:
```elixir
def deps do
  [
    {:telemetry, "~> 1.2"},
    {:ash, "~> 3.0", optional: true},
    {:spark, "~> 2.2", optional: true}
  ]
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

## 3. Module Inventory & Ash 3 Contract Alignment (`lib/xitdb/ash/`)

### 3.1 `dsl.ex` (`Xitdb.Ash.Dsl`)
Spark DSL extension defining the `xitdb do ... end` section for Ash resources:
- `store`: Required atom naming the `Xitdb.Ash.Store` module (e.g. `CaasaConnect.MDMStore`).
- `collection`: String collection name in Xitdb slot tree (defaults to underscored resource name).
- `Index`: Entity defining secondary B+Tree index (`name`, `fields`, `unique?`, `where`, `type`).
- `NestedIn`: Entity defining subtree containment (`parent_resource`, `cardinality`, `parent_locator`).
- `Reference`: Entity defining foreign key relationships with `on_delete: :nothing | :delete | :nilify | :restrict`.
- `Transformers.BuildIndexPlan`: Automatically synthesizes B+Tree indexes for `belongs_to` foreign keys and registers reverse references.
- `Verifiers.VerifyNoSqlFragments`: Raises at compile time if `Ash.Query.Function.Fragment` appears in filter, calculation, or validation expressions.

### 3.2 `info.ex` (`Xitdb.Ash.Info`)
Compile-time DSL introspection helpers:
- `store!/1`, `store/1`
- `collection!/1`, `collection/1`
- `nested_in/1`
- `indexes/1`, `unique_indexes/1`
- `references/1`, `incoming_delete_rules/2`

### 3.3 `codec.ex` (`Xitdb.Ash.Codec`)
Type conversion between Ash types and Xitdb slots:
- `Ash.Type.CiString`: Store original string; hydrate `%Ash.CiString{}`; index with `String.downcase/1`.
- `Ash.Type.UtcDatetime` / `UtcDatetimeUsec`: Encode as integer epoch microseconds (`DateTime.to_unix(dt, :microsecond)`) for range-query ordering in `:sorted_map`.
- `Ash.Type.Date`: Encode as ISO-8601 `"YYYY-MM-DD"` string.
- Atoms & embedded resources: Serialize to binary/map slots safely without atom leaks.

### 3.4 `indexer.ex` (`Xitdb.Ash.Indexer`)
Index maintenance for `:sorted_map` and `:hash_map` slots:
- `_parent` locator index: `idx.<collection>._parent[id] => parent_id` for `nested_in` subtrees.
- Unique identity indexes: `idx.<collection>.<index_name>[key] => entity_id`.
- Secondary multi-value indexes: `idx.<collection>.<index_name>[key] => :counted_hash_set(entity_ids)`.
- Index differential update: Extract old keys, compute additions/removals, apply atomically.
- **Ash 3 Upsert Identity Struct Handling:** `find_upsert_existing_id/5` must accept `%Ash.Resource.Identity{}` struct, atom name, or fallback key match list to correctly resolve existing record IDs during upsert.

### 3.5 `store.ex` (`Xitdb.Ash.Store`)
Store management and snapshot transactions:
- `use Xitdb.Ash.Store, otp_app: :app` macro generating GenServer writer and snapshot publisher.
- 3-tier read-handle resolution:
  1. Process dictionary (`:xitdb_ash_tx_handle`) during active transactions.
  2. ETS table (`Xitdb.Ash.TestSandbox`) during active ExUnit tests.
  3. `:persistent_term.get({store, :current_db})` for lock-free application reads.
- Transaction savepoint stack supporting nested `transaction/3` and `rollback/2` via throw `{:xitdb_ash_rollback, store, reason}`.

### 3.6 `query.ex` (`Xitdb.Ash.Query`)
Two-tier query planner and runtime executor:
- **Tier 1 (Narrow):** Inspect `query.filter`. If direct primary key filter (`id == ^val` or `id in ^list`), retrieve directly (`O(1)`). If `nested_in` with known parent, read directly from parent subtree. If indexed field, perform `:sorted_map` lookup (`O(log N)`). If multiple indexes, intersect candidate ID sets.
- **Tier 2 (Hydrate & Evaluate):** Hydrate entities from slots. Pass through `Ash.Filter.Runtime.filter_matches/4` for arbitrary complex residual filters (calculations, expressions, logic operators).
- **Tier 3 (Shape):** Apply sorting (`runtime_sort`), `limit`, and `offset`.
- **Aggregates:** Compute `:count`, `:exists`, `:first`, `:list`, `:sum`, `:min`, `:max`, `:avg` natively.

### 3.7 `mutator.ex` (`Xitdb.Ash.Mutator`)
Atomic mutations executed exclusively inside the Store GenServer writer:
- `create/2`: Auto-allocate monotonic integer PK from `meta.sequences[collection]` when `:id` is `nil`. Validate unique identities and insert into entity slots and indexes.
- `update/2`: Evaluate `changeset.atomics` via `Ash.Expr.eval/2` against current state. Re-index modified keys.
- `upsert/4`: Atomic get-or-create/update using identity key.
- `destroy/2`: Enforce reverse foreign key rules (`:restrict` raises `Ash.Error.Invalid`, `:nilify` clears references, `:delete` cascades recursively). Delete entity slot and clear index entries.
- `bulk_create/3`: Batch sequence allocation, validation, and index insertion in a single transaction.

### 3.8 `data_layer.ex` (`Xitdb.Ash.DataLayer`)
The `@behaviour Ash.DataLayer` implementation:
- Implements `can?/2` declaring full capabilities (`:create`, `:read`, `:update`, `:destroy`, `:transact`, `:bulk_create`, `:nested_expressions`, `:sort`, `:filter`, etc.).
- **Calculations Delegation:** Leave `:calculate` **off** `can?/2` so Ash Core (`Ash.Actions.Read.Calculations`) batch-loads referenced relationships and `exists(...)` subqueries before evaluating expression calculations (e.g. `Deal.has_materials_access`) in Elixir.
- **Pass-Through `join/7`:** Implement no-op `join(%Query{} = query, _, _, _, _, _, _)` returning `{:ok, query}` so `can?(resource, {:join, other})` allows Ash query planning while `Ash.Filter.Runtime` handles in-memory joins.
- Handles cross-store relationships via Ash's `{:join, other}` protocol.
- Emits `:telemetry.span([:xitdb, :ash, :query | :mutation], ...)` events.

### 3.9 `test_sandbox.ex` (`Xitdb.Ash.TestSandbox`)
ExUnit test sandbox:
- `checkout/1`: Copies initial store database handle via lightweight copy-on-write fork (`Xitdb.fork/1`). Stores test handle in ETS keyed by `self()` and propagates across `$callers`.
- Guarantees complete test isolation with `async: true` without disk persistence or database rollback transactions.

---

## 4. Test Strategy & Acceptance Criteria

1. **Standalone ExUnit Verification Suite (`xitdb/test/xitdb/ash/data_layer_test.exs`):**
   - Dual-store architecture (`TestMdmStore` and `TestAppStore`).
   - Monotonic integer sequence ID allocation (`meta.sequences`).
   - Case-insensitive `CiString` identities and counted sets.
   - Partial `where:` identities on create and status transitions.
   - `nested_in` containment (`:many` and `:one`) with `_parent` locator index resolution.
   - Filtered aggregates (`count :active_roster_count`) and cross-store `exists(...)` filters.
   - `Ash.Policy.Authorizer` cross-store read/write policy evaluation.
   - Relational calculations (`Deal.has_materials_access`).
   - Atomic updates and nested savepoint rollbacks (`Ash.DataLayer.rollback/2`).
   - Foreign key cascading rules (`:restrict`, `:delete`, `:nilify`).
   - `TestSandbox` `$callers` propagation across `Task.async_stream`.
   - Compile-time rejection of SQL `fragment(...)` expressions via `VerifyNoSqlFragments`.
2. **Quality Gates:**
   - `mix format --check-formatted`
   - `mix compile --warnings-as-errors`
   - `mix test test/xitdb/ash/data_layer_test.exs` passes 100%.
   - Zero required dependencies when compiled in a standalone project without Ash.
