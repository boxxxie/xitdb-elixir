# Ash Framework & Full-Text Search

`Xitdb.Ash.DataLayer` is a native data layer for [`Ash`](https://hexdocs.pm/ash) (`~> 3.37 and >= 3.37.2`) that stores `Ash.Resource` records directly in single-file `.xit` stores (or `:memory` for testing).

With `Xitdb.Ash`, your Ash resources get:
- Full CRUD, atomic updates/destroys, relationships, calculations, and aggregates with **zero SQL migrations**
- Single-field and composite `:sorted_map` secondary indexes (`index`)
- Built-in transactional **BM25 + prefix full-text search** (`search_field` + `Xitdb.Ash.Search`)
- Same-store foreign-key `on_delete` cascades (`references`) and co-located child subtrees (`nested_in`)
- Historical time-travel reads (`Xitdb.Ash.Store.with_as_of/3`)
- Isolated `async: true` ExUnit sandboxes (`Xitdb.Ash.TestSandbox`)

---

## 1. Supervising a Store (`Xitdb.Ash.Store`)

Start a supervised `Xitdb.Ash.Store` in your application supervision tree. Readers resolve snapshots lock-free via `:persistent_term` and `:atomics`, while transactions acquire a monitored single-writer lease that runs inside the caller process:

```elixir
# Option A: Supervise directly by registered atom name
children = [
  {Xitdb.Ash.Store,
   name: MyApp.Store,
   path: "/var/data/app.xit",
   domains: [MyApp.Accounts]}
]

# Option B: Define a dedicated store module
defmodule MyApp.Store do
  use Xitdb.Ash.Store
end
```

Key `Xitdb.Ash.Store` functions:
- `Xitdb.Ash.Store.transact(store, fun, opts \\ [])` — runs `fun` inside a monitored writer lease (re-entrant with savepoints) and rolls back on `Xitdb.Ash.Store.rollback(store, reason)`.
- `Xitdb.Ash.Store.mutate(store, fun, opts \\ [])` — runs a raw `{db, moment}` mutation function inside the writer lease.
- `Xitdb.Ash.Store.as_of(store, moment)` — returns a read-only `%Xitdb.Cursor{}` pinned to `moment`.
- `Xitdb.Ash.Store.with_as_of(store, moment, fun)` — pins `moment` across all `Ash.read`, `Ash.count`, aggregates, relationship loads, and `Xitdb.Ash.Search` calls inside `fun`.

---

## 2. Defining an Ash Resource (`xitdb do ... end`)

Set `data_layer: Xitdb.Ash.DataLayer` (which automatically adds the `Xitdb.Ash.Dsl` Spark extension) and configure the `xitdb do ... end` block:

```elixir
defmodule MyApp.Accounts.Profile do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: Xitdb.Ash.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  xitdb do
    store MyApp.Store
    collection :profiles

    # Explicit single-field or composite :sorted_map secondary indexes
    # (belongs_to foreign keys are indexed automatically when index_relationships? is true)
    index [:status, :inserted_at]

    # Transactional BM25 + prefix search fields
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
| `index_relationships?` | `boolean()` | `true` | Automatically creates secondary `:sorted_map` indexes for all `belongs_to` foreign keys. |
| `index` | entity | — | Declares a single-attribute or composite `:sorted_map` secondary index (`index :email`, `index [:status, :inserted_at], name: :idx_status_recent`). |
| `search_field` | entity | — | Declares a field (with optional `boost:` and 2-arity `resolver:`) indexed in `idx.search.<collection>` for BM25 + prefix search. |
| `nested_in` | entity | — | Co-locates records inside `root[parent_collection][parent_id][path]` (`nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many`). |
| `references` | section | — | Foreign-key `on_delete` rules (`:nothing`, `:delete`, `:nilify`, `:restrict`) within the same `.xit` store. |

---

## 3. Full-Text & Prefix Search (`Xitdb.Ash.Search`)

`Xitdb.Ash.Search` maintains inverted term postings inside the same `.xit` store as your records, so searches, `Ash.read!` hydrations, `as_of:` time-travel, and `Xitdb.Ash.TestSandbox` checkouts stay transactionally consistent:

```elixir
require Ash.Query

# Ranked `{id, score}` hits, or just ordered IDs
hits = Xitdb.Ash.Search.query(MyApp.Accounts.Profile, "alice capital", limit: 25)
ranked_ids = Xitdb.Ash.Search.ids(MyApp.Accounts.Profile, "alice capital", limit: 25)

profiles =
  MyApp.Accounts.Profile
  |> Ash.Query.filter(id in ^ranked_ids)
  |> Xitdb.Ash.Search.sort_by_rank(ranked_ids)
  |> Ash.read!()
```

### Reindexing Cross-Record `resolver:` Fields

When a referenced parent record updates a field pulled into a child's `search_field` via `resolver:` (such as `Organization.name` indexed onto `Profile`), call `Xitdb.Ash.Search.reindex_records/4` inside an `after_action` hook on the same store so both changes commit in the same transaction. (When destroying a parent with `on_delete: :nilify`, `Xitdb.Ash.Mutator` automatically re-runs child `search_field` resolvers and `Xitdb.Ash.Search.lookup_field/5` returns `nil` for a `nil` ID, clearing stale postings; `on_delete: :nothing` requires explicit `reindex_records/4`.)

---

## 4. Time-Travel Ash Queries (`Store.with_as_of/3`)

Pin any historical moment across `Ash.read`, `Ash.count`, aggregates, relationship loads, and BM25 searches:

```elixir
# 1. Scoped historical block (propagates across nested relationship/calculation loads)
Xitdb.Ash.Store.with_as_of(MyApp.Store, prev_moment, fn ->
  Ash.read!(MyApp.Accounts.Profile, load: [:organization])
end)

# 2. Per-query Ash context (use `shared:` so Ash 3 copies it to child queries) or Search option
Ash.read!(
  MyApp.Accounts.Profile,
  load: [:organization],
  context: %{shared: %{xitdb_moment: prev_moment}}
)

Xitdb.Ash.Search.ids(MyApp.Accounts.Profile, "northleaf", as_of: prev_moment)
```

---

## 5. Co-Located Subtrees (`nested_in`) & Raw Transactions (`tx_for`)

### Co-Located Child Subtrees (`nested_in`)

When child entities belong inside a parent record's subtree (enabling `O(1)` parent `fork` snapshots while still supporting child `index` and `search_field` declarations), declare both `collection` and `nested_in`:

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

### Automatic Secondary Indexes in Raw Transactions (`tx_for` & `tx_for!`)

When writing raw `Xitdb.DSL` transactions against indexed resources, use `tx_for/3,4` or `tx_for!/3,4` (imported by `use Xitdb.DSL`, or via `require Xitdb.Ash.Tx`) so configured `index_on` rules are injected automatically at compile time:

```elixir
use Xitdb.DSL

db =
  tx_for! db, MyApp.Accounts.Profile, doc: "upsert profile 101" do
    put profiles["101"].id, "101"
    put profiles["101"].full_name, "Alice Smith"
    put profiles["101"].status, "active"
  end
```

You can also use `tx_for` with plain Elixir schema modules (without `Ash.Resource`) by defining `__xitdb_indexes__/0` (returning `[{collection, field, index_name}]`, or `[{field, index_name}]` paired with `__xitdb_collection__/0`):

```elixir
defmodule MyApp.Catalog.ItemSchema do
  def __xitdb_collection__, do: :items
  def __xitdb_indexes__, do: [sku: "sku->item_id"]
end
```

---

## 6. Concurrent Testing (`Xitdb.Ash.TestSandbox`)

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
setup tags do
  :ok = Xitdb.Ash.TestSandbox.checkout([MyApp.Store], shared: not tags[:async])
  on_exit(fn -> Xitdb.Ash.TestSandbox.checkin([MyApp.Store]) end)
  :ok
end
```

For spawned worker processes (such as `Task.async/1`), share the caller's checked-out sandbox via `Xitdb.Ash.TestSandbox.allow(MyApp.Store, self(), worker_pid)`.

---

## 7. Introspection & Compile-Time Guardrails

Use `Xitdb.Ash.Info` to inspect resource configuration at runtime or compile time:
- `Xitdb.Ash.Info.store!/1` / `fetch_store/1` / `resolve_store/2`
- `Xitdb.Ash.Info.collection!/1` / `fetch_collection/1`
- `Xitdb.Ash.Info.indexes/1` / `indexes_for_field/2`
- `Xitdb.Ash.Info.search_fields/1`
- `Xitdb.Ash.Info.references/1`
- `Xitdb.Ash.Info.counted_set_fields/1`
- `Xitdb.Ash.Info.nested_in/1` / `nested?/1`

At compile time, Spark runs:
1. **`Xitdb.Ash.Transformers.BuildIndexPlan`** — validates `store`, `collection`, primary keys, `nested_in`, explicit/auto-`belongs_to` `index`es, `counted_set_fields`, and `search_field`s, generating `__xitdb_store__/0`, `__xitdb_collection__/0`, and `__xitdb_indexes__/0`.
2. **`Xitdb.Ash.Verifiers.VerifyNoSqlFragments`** — rejects SQL `fragment(...)` calls across calculations, policies, validations, and identities.
3. **`Xitdb.Ash.Verifiers.VerifyCrossStoreReferences`** — rejects cross-store `on_delete` cascades (`:delete`, `:nilify`, `:restrict`) and cross-store `nested_in` targets.

---

## 8. Domain Datatypes & Custom Range Indexes

`Xitdb.Ash` provides built-in `Ash.Type`s and codec extension hooks for fixed-point finance metrics, full unsigned 64-bit integers (`> max(i64)`), interval ranges, and tagged binaries:

- **`Xitdb.Ash.Types.UnsignedInteger`** (`storage_type: :unsigned_integer`): supports `0..18_446_744_073_709_551_615`, storing `0..9_223_372_036_854_775_807` as native integer slots and values exceeding signed `max(i64)` as `{:tagged, "u8", <<val::unsigned-big-64>>}`, while indexing all values with 8-byte `Xitdb.Key.encode_u64_be/1` B+Tree keys.
- **`Xitdb.Ash.Types.FixedDecimal64`**: `%Decimal{}` runtime values backed by fixed-scale 64-bit integer slots (`scale:` positive power of 10, default `10_000`; `signed?: true | false`; `representation: :integer | :tagged` using `{:tagged, "d6", <<...>>}`), indexed via 8-byte `Xitdb.Key.encode_fixed_decimal64_be/2` keys.
- **`Xitdb.Ash.Types.RangedUnit`**: domain interval struct (`bound_kind`, `dimension`, `currency`, `min_val`, `max_val`) stored as a compact string-keyed map, exposing `to_indexed_fields/2,3` (`min_d64`, `max_d64`, `bound`, `unit`, with optional `:prefix` and `unbounded: :sentinel`) for B+Tree overlap queries and `overlaps?/2` for exact boundary comparisons.
- **Custom `Ash.Type` Index Hooks**: implement `xitdb_index_key(value, constraints) :: binary()` (and optional `xitdb_fixed_width?(constraints) :: boolean()`) on any custom `Ash.Type` module to control how `Xitdb.Ash.Codec` encodes single and composite B+Tree keys, plus return `{:tagged, <<a, b>>, binary}` directly from `dump_to_native/2` / `dump_to_embedded/2`.

> [!NOTE]
> Native Odin Datalog comparisons (`<`, `>`, `<=`, `>=` in `Xitdb.DSL.query`) compare un-tagged `i64`/`f64`/`string` fields inside `native/xitdb-odin`, whereas `Ash.Query` + `Xitdb.Ash.Indexer.scan_secondary_range/5` handle both `u64 > max(i64)` and `:tagged`-backed `FixedDecimal64` attributes in Elixir using `Xitdb.Key`.
