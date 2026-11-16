# Ash & Spark Integration (`Xitdb.Ash.DataLayer`, `Xitdb.Ash.Dsl`, `Xitdb.Ash.Store`, `Xitdb.Ash.Search`)

`Xitdb` integrates natively with [`Ash`](https://hexdocs.pm/ash) via `data_layer: Xitdb.Ash.DataLayer`—persisting `Ash.Resource` entities directly in immutable copy-on-write `.xit` files managed by `Xitdb.Ash.Store`, with ~10ns lock-free `:persistent_term` snapshot reads, single/composite B+Tree secondary indexes (`index`), transactional Odin NIF BM25 + prefix search (`search_field` & `Xitdb.Ash.Search`), incoming/outgoing FK cascades (`references`), co-located parent subtrees (`nested_in`), historical time-travel (`Store.with_as_of/3`), `async: true` sandboxes (`Xitdb.Ash.TestSandbox`), and resource-aware transactions (`tx_for/3,4` and `tx_for!/3,4`).

---

## 1. Declaring `xitdb` on an `Ash.Resource`

Set `data_layer: Xitdb.Ash.DataLayer` (which automatically includes `Xitdb.Ash.Dsl`) and configure the `xitdb do ... end` section:

```elixir
defmodule MyApp.Accounts.Profile do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: Xitdb.Ash.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  xitdb do
    store MyApp.Store
    collection :profiles

    # Explicit single-field or composite B+Tree (:sorted_map) secondary indexes
    # (belongs_to foreign keys are indexed automatically when index_relationships? is true)
    index [:status, :inserted_at]

    # Transactional in-Xitdb BM25 + B+Tree prefix search fields
    search_field :full_name, boost: 3.0
    search_field :headline, boost: 1.5

    search_field :firm_name,
      boost: 2.0,
      resolver: fn profile, db ->
        Xitdb.Ash.Search.lookup_field(db, :organizations, profile.organization_id, "name")
      end

    # Incoming/outgoing foreign-key cascade actions within the same store
    references do
      reference :organization, on_delete: :nilify
    end
  end

  attributes do
    integer_primary_key :id
    attribute :full_name, :string, allow_nil?: false, public?: true
    attribute :headline, :string, public?: true
    attribute :status, :atom, default: :active, public?: true
    timestamps(public?: true)
  end

  relationships do
    belongs_to :organization, MyApp.Accounts.Organization,
      attribute_type: :integer,
      attribute_writable?: true,
      public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end
end
```

### `xitdb` Section Options & Entities Reference

| Option / Entity | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `store` | `atom()` | `nil` | Supervised `Xitdb.Ash.Store` module or registered name (falls back to `config :xitdb, :default_store`). |
| `collection` | `atom()` | *(required)* | Logical collection & sequence key in the `.xit` store (`:profiles`, `:organizations`, `:events`). |
| `counted_set_fields` | `[atom()]` | `[]` | `{:array, inner_type}` attributes backed by `:counted_hash_set` slots. |
| `index_relationships?` | `boolean()` | `true` | Automatically creates secondary B+Tree indexes for all `belongs_to` foreign keys. |
| `index` | entity | — | Declares a single-attribute or composite `:sorted_map` B+Tree secondary index (`index :email`, `index [:status, :inserted_at], name: :idx_status_recent`). |
| `search_field` | entity | — | Declares a field (with optional `boost:` and 2-arity `resolver:`) indexed in `idx.search.<collection>` for BM25 + prefix search. |
| `nested_in` | entity | — | Co-locates records inside `root[parent_collection][parent_id][path]` (`nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many`). |
| `references` | section | — | Foreign-key `on_delete` rules (`:nothing`, `:delete`, `:nilify`, `:restrict`) within the same `.xit` store. |

---

## 2. Co-Located Subtrees (`nested_in`) & `Xitdb.Ash.Info` Introspection

For child entities co-located inside a parent entity's subtree (enabling 9-byte `fork` snapshots and parent-jump queries while still supporting child secondary `index` / `search_field` declarations), declare **both** `collection` (for `meta.sequences` and `idx.<collection>._parent` locators) and `nested_in`:

```elixir
defmodule MyApp.Events.Session do
  use Ash.Resource,
    domain: MyApp.Events,
    data_layer: Xitdb.Ash.DataLayer

  xitdb do
    store MyApp.Store
    collection :agenda_sessions
    nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many

    index :session_type

    references do
      reference :event, on_delete: :delete
    end
  end

  attributes do
    integer_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :session_type, :atom, default: :talk, public?: true
  end

  relationships do
    belongs_to :event, MyApp.Events.Event,
      attribute_type: :integer,
      allow_nil?: false,
      attribute_writable?: true,
      public?: true
  end
end
```

Use `Xitdb.Ash.Info` to inspect resource metadata:
- `Xitdb.Ash.Info.store!(Resource)` / `fetch_store/1` / `resolve_store/2`
- `Xitdb.Ash.Info.collection!(Resource)` / `fetch_collection/1`
- `Xitdb.Ash.Info.indexes(Resource)` / `indexes_for_field/2`
- `Xitdb.Ash.Info.search_fields(Resource)`
- `Xitdb.Ash.Info.references(Resource)`
- `Xitdb.Ash.Info.counted_set_fields(Resource)`
- `Xitdb.Ash.Info.nested_in(Resource)` / `nested?(Resource)`

---

## 3. Compile-Time Transformer & Verifiers

1. **`Xitdb.Ash.Transformers.BuildIndexPlan`** validates `store`, `collection`, primary keys, `nested_in`, explicit/auto-`belongs_to` `index`es, `counted_set_fields`, and `search_field`s at compile time, persisting the plans and generating `__xitdb_store__/0`, `__xitdb_collection__/0`, and `__xitdb_indexes__/0` callbacks on the resource.
2. **`Xitdb.Ash.Verifiers.VerifyNoSqlFragments`** rejects SQL `fragment(...)` calls across calculations, policies, validations, and identities at compile time.
3. **`Xitdb.Ash.Verifiers.VerifyCrossStoreReferences`** rejects cross-store `on_delete` cascades (`:delete`, `:nilify`, `:restrict`) and cross-store `nested_in` targets at compile time.

---

## 4. `Xitdb.Ash.Store` (Supervision, Transactions & Time-Travel)

`Xitdb.Ash.Store` is a caller-supervised single-writer `GenServer` that publishes lock-free `:persistent_term` + `:atomics` snapshots (~10ns reads) and coordinates monitored writer leases for transactions:

```elixir
# Option A: Supervise directly by registered atom name
children = [
  {Xitdb.Ash.Store,
   name: MyApp.Store,
   path: "/var/data/app.xit",
   domains: [MyApp.Accounts]}
]

# Option B: Define a dedicated module with `use Xitdb.Ash.Store`
defmodule MyApp.Store do
  use Xitdb.Ash.Store
end
```

Key store APIs:
- `Xitdb.Ash.Store.transact(store, fun, opts \\ [])` — acquires a monitored writer lease (re-entrant with savepoints) and commits or rolls back on `Xitdb.Ash.Store.rollback(store, reason)`.
- `Xitdb.Ash.Store.mutate(store, fun, opts \\ [])` — executes a raw `{db, moment}` mutation function inside the writer lease.
- `Xitdb.Ash.Store.as_of(store, moment)` — returns a read-only `%Xitdb.Cursor{}` pinned to `moment`.
- `Xitdb.Ash.Store.with_as_of(store, moment, fun)` — pins `moment` in process-dictionary context across all `Ash.read`, `Ash.count`, aggregates, relationship loads, and `Xitdb.Ash.Search` calls inside `fun` (or pass `context: %{shared: %{xitdb_moment: moment}}` per Ash call so Ash 3 propagates it to child relationship/calculation queries).

---

## 5. `Xitdb.Ash.Search` (BM25 + Prefix Search & Reindexing)

Declare `search_field` entries inside `xitdb do ... end` on `Xitdb.Ash.DataLayer` resources (with optional `boost:` and 2-arity `resolver: fn record, db -> ... end`), then query the transactional `idx.search.<collection>` B+Tree index:

```elixir
require Ash.Query

# Ranked hits with score metadata, or just ordered IDs:
hits = Xitdb.Ash.Search.query(MyApp.Accounts.Profile, "alice capital", limit: 25)
ranked_ids = Xitdb.Ash.Search.ids(MyApp.Accounts.Profile, "alice capital", limit: 25)

profiles =
  MyApp.Accounts.Profile
  |> Ash.Query.filter(id in ^ranked_ids)
  |> Xitdb.Ash.Search.sort_by_rank(ranked_ids)
  |> Ash.read!()

# Historical search at a prior moment:
Xitdb.Ash.Search.ids(MyApp.Accounts.Profile, "alice", as_of: prev_moment)
```

When a referenced parent record changes a field indexed onto a child via `resolver:`, call `Xitdb.Ash.Search.reindex_records(db_or_snapshot, ChildResource, children)` (using `Xitdb.Ash.Search.lookup_field/4` inside the resolver) in an `after_action` hook on the same store (with `require_atomic? false` on the `:update` action, or a `Change` module implementing `atomic/3`) so both updates commit atomically. When destroying a parent with `on_delete: :nilify`, `Xitdb.Ash.Mutator` automatically re-runs child `search_field` resolvers (and `Xitdb.Ash.Search.lookup_field/4` short-circuits to `nil` when given a `nil` ID), purging stale BM25 postings in the same commit; `on_delete: :nothing` requires explicit `reindex_records/4`.

---

## 6. Automatic Secondary Index Transactions (`tx_for` & `tx_for!`)

Instead of repeating `index_on` rules in every raw transaction block, use `tx_for/3,4` or `tx_for!/3,4` (imported automatically by `use Xitdb.DSL`, or via `require Xitdb.Ash.Tx`).

`tx_for` resolves all `__xitdb_indexes__/0` rules configured on the given `Ash.Resource` (or plain schema module) **at compile time** and prepends the corresponding `index_on(collection, field, index_name)` operations to the transaction batch:

```elixir
use Xitdb.DSL

db =
  tx_for! db, MyApp.Accounts.Profile, doc: "upsert profile 101" do
    put profiles["101"].id, "101"
    put profiles["101"].full_name, "Alice Smith"
    put profiles["101"].status, "active"
  end
```

### Using `tx_for` with Plain Elixir Schema Modules
You can also pass plain Elixir modules (without `Ash.Resource`) to `tx_for` by defining `__xitdb_indexes__/0` (returning `[{collection, field, index_name}]`, or `[{field, index_name}]` alongside `__xitdb_collection__/0`):

```elixir
defmodule MyApp.Catalog.ItemSchema do
  def __xitdb_collection__, do: :items
  def __xitdb_indexes__, do: [sku: "sku->item_id"]
end
```

---

## 7. `Xitdb.Ash.TestSandbox` (Concurrent `async: true` Testing)

`Xitdb.Ash.TestSandbox` isolates `:memory` `%Xitdb{}` snapshots per test process so `async: true` ExUnit suites run concurrently without lock contention:

```elixir
# test/test_helper.exs
Xitdb.Ash.TestSandbox.init()
ExUnit.start()

# Optional once-per-suite fixture template seeding:
Xitdb.Ash.TestSandbox.seed_template(MyApp.Store, fn db ->
  # seed shared baseline records and return updated db
  db
end)

# test/support/data_case.ex
setup do
  :ok = Xitdb.Ash.TestSandbox.checkout([MyApp.Store])
  on_exit(fn -> Xitdb.Ash.TestSandbox.checkin([MyApp.Store]) end)
  :ok
end
```

For spawned worker processes (such as `Task.async/1`), share the caller's checked-out sandbox via `Xitdb.Ash.TestSandbox.allow(MyApp.Store, self(), worker_pid)`.
