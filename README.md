# Xitdb — Idiomatic Elixir Client for `xitdb`

[![Hex.pm](https://img.shields.io/badge/hex-1.1.0-blue.svg)](https://hex.pm/packages/xitdb)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

`Xitdb` is an idiomatic Elixir client and Odin NIF wrapper for [`xitdb`](https://github.com/xit-vcs/xitdb) (backed by [`odin-xitdb`](https://github.com/boxxxie/odin-xitdb)), an embeddable, immutable, append-only database with persistent structural sharing.

Rather than re-implementing `xitdb`'s wire format in pure Elixir or requiring query boilerplate for every read, `Xitdb` exposes database nodes as **Clojure/Datomic-style lazy `%Xitdb.Cursor{}` values** that implement Elixir's standard `Access`, `Enumerable`, and `Inspect` protocols.

---

## Key Features

- **Lazy 9-Byte `Slot` Cursors (`%Xitdb.Cursor{}`):**
  Navigating nested structures (`db["users"]["alice"]["roles"][0]`) resolves a single 9-byte `Slot` (`tag` + `value`) per hop across the NIF boundary without eagerly deserializing surrounding subtrees into the BEAM heap.
- **Pure-Value Process Safety:**
  Because `%Xitdb.Cursor{}` holds only the NIF resource reference (`db_ref`) and a 9-byte `Slot` coordinate (`tag`, `tag_id`, `value`, `moment`), cursors are **pure immutable Elixir values**. Pass them across `Task.async/1`, GenServers, ETS tables, or Phoenix LiveView assigns with zero mutexes or pointer lifetimes.
- **Standard Elixir `Access` & `Enumerable`:**
  Use `cursor["key"]`, `cursor[idx]`, `get_in/2`, `put_in/3`, `update_in/3`, `pop_in/2`, `Enum.count/1` (`O(1)` on counted maps/sets/lists), `Enum.member?/2` (`O(1)` HAMT membership), `Enum.slice/2` (`O(log N)` index seek), and lazy `Stream.*` pipelines.
- **Instant Time-Travel & Structural Diffs:**
  Pin historical snapshots in `O(1)` with `Xitdb.as_of(db, moment)`, diff any two moments in `O(delta)` with `Xitdb.diff_moments/3`, and inspect attribute lineage with `Xitdb.history_of/2`.
- **Compile-Time Validated Sigils (`~x`, `~q`), Macro DSL (`Xitdb.DSL`), Pull & Datalog:**
  Use standard `Access` for lazy navigation or `use Xitdb.DSL` for compile-time path selectors (`path(users[id].todos[[0]])`), zero-read atomic transaction blocks (`tx db do ... end`), structural Pull patterns (`[:username, todos: 0..2]`), and Ecto-style Datalog queries with `^var` pinning.
- **Native Ash Framework DataLayer, BM25 Search & Spark DSL (`Xitdb.Ash.DataLayer`, `Xitdb.Ash.Resource`):**
  Persist `Ash.Resource` domains directly in immutable `.xit` files with `data_layer: Xitdb.Ash.DataLayer`—complete with ~10ns lock-free `:persistent_term` snapshot reads (`Xitdb.Ash.Store`), single/composite B+Tree secondary indexes (`index [:status, :inserted_at]`), transactional Odin NIF BM25 + prefix search (`Xitdb.Ash.Search`), incoming/outgoing FK cascades (`references`), co-located `nested_in` subtrees, historical time-travel (`Store.with_as_of/3`), and `async: true` sandboxes (`Xitdb.Ash.TestSandbox`)—or attach `extensions: [Xitdb.Ash.Resource]` as a hybrid MDM sync projection extension.

---

## Installation

Add `xitdb` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xitdb, "~> 1.1"}
  ]
end
```

### System Requirements

Building `xitdb` compiles a native C-ABI Erlang NIF bridge to the embedded Odin database engine:
- **Odin Compiler**: `odin` must be installed and available in your `PATH` (see [Odin Getting Started](https://odin-lang.org/docs/install/)).
- **C Compiler**: A standard C compiler (`cc` or `gcc`) for compiling the Erlang NIF C shim.

---

## Quick Start

```elixir
import Xitdb.Sigils

# 1. Open an in-memory or file-backed database
{:ok, db} = Xitdb.open(backend: :memory)

# 2. Commit a moment using standard Elixir maps, lists, and typed collection wrappers
{:ok, db} =
  Xitdb.transact(
    db,
    %{
      "users" => %{
        "alice" => %{
          "username" => "alice",
          "name" => "Alice Liddell",
          "age" => 30,
          "roles" => ["admin", "architect"],
          "flags" => Xitdb.counted_set(["verified", "staff"])
        }
      },
      "audit_log" => Xitdb.linked_list(["init", "seed"])
    },
    doc: "Seed initial users",
    index_rules: [{:index_on, "users", "username", "username->id"}]
  )

# 3. Navigate lazily with standard Elixir Access brackets & Enumerable
root = Xitdb.db(db)
alice = root["users"]["alice"]       # => #Xitdb.Cursor<hash_map offset: ..., preview: [...]>
alice["name"]                        # => "Alice Liddell"
alice["roles"][1]                    # => "architect"
Enum.member?(alice["flags"], "staff") # => true (O(1) HAMT lookup, no list conversion!)

# 4. Mutate nested paths with put_in/3, update_in/3, and pop_in/2 inside Xitdb.transact/2
snapshot_v0 = Xitdb.as_of(db, 0)

{:ok, db} =
  Xitdb.transact(db, fn r ->
    r
    |> update_in(["users", "alice", "age"], &(&1 + 1))
    |> Xitdb.insert_at(["audit_log"], 1, "promoted")
  end, doc: "Increment Alice age")

# 5. Historical snapshots remain immutable
snapshot_v0["users"]["alice"]["age"] # => 30
db["users"]["alice"]["age"]          # => 31

# 6. Datomic Pull projections & Datalog queries (supports both strings and structured DSLs)
Xitdb.pull!(alice, [:name, :age, roles: 0..1])
# => %{"name" => "Alice Liddell", "age" => 31, "roles" => ["admin"]}

Xitdb.query!(db, ~q"""
find ?id, ?age
where
  $username->id[?uname] = ?id
  starts_with(?uname, "al")
  .users[?id].age = ?age
""")
# => %{vars: ["?id", "?age"], rows: [["alice", 31]]}
```

---

## Macro DSLs (`use Xitdb.DSL`)

For operations where Elixir's `Access` protocol has friction—such as auto-vivifying deep paths without intermediate NIF reads, native list `append`/`insert`/`slice`, `O(1)` subtree `fork`, typed collection selectors (`#counted`, `$sorted`, `[[linked]]`), and Datalog queries with pinned runtime variables (`^var`)—`Xitdb` provides a compile-time macro DSL:

```elixir
use Xitdb.DSL

# 1. Atomic transaction block (0 intermediate NIF reads, native collection ops)
{:ok, db} =
  tx db, doc: "promote alice" do
    put users[id].role, "admin"
    append users[id].roles, "staff"
    insert audit_log[[1]], "promoted"
    fork users[id], backups[id]
    update users[id].age, &((&1 || 0) + 1)
  end

# 2. Path selector macro with runtime interpolation & collection tags
role = Xitdb.select!(db, path(users[id].roles[0]))

# 3. Declarative Datalog query macro with ^var pinning
prefix = "al"
min_age = 21

{:ok, %{rows: [["alice", 32]]}} =
  query db do
    find {id, age}

    where [
      sorted("username->id")[uname] == id,
      starts_with(uname, ^prefix),
      users[id].age == age,
      age >= ^min_age
    ]
  end
```

---

## Ash Framework Integration (`Xitdb.Ash.DataLayer` & `Xitdb.Ash.Resource`)

`Xitdb` supports two complementary integration modes with [`Ash`](https://hexdocs.pm/ash):

### 1. Native Lock-Free Ash Storage & BM25 Search (`data_layer: Xitdb.Ash.DataLayer`)

Use `Xitdb.Ash.DataLayer` with a supervised `Xitdb.Ash.Store` for full Ash 3.37.2+ CRUD, atomic updates, relationships, aggregates, calculations, composite B+Tree secondary indexes, same-store FK cascades, time-travel queries, and transactional Odin NIF BM25 + prefix search—with **zero SQL migrations**:

```elixir
defmodule MyApp.Accounts.Profile do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: Xitdb.Ash.DataLayer

  xitdb do
    store MyApp.Store
    collection :profiles

    # Single-field and composite B+Tree (:sorted_map) secondary indexes
    index [:status, :inserted_at]

    # Transactional in-Xitdb BM25 + B+Tree prefix search
    search_field :full_name, boost: 3.0
    search_field :headline, boost: 1.5

    references do
      reference :organization, on_delete: :nilify
    end
  end

  attributes do
    integer_primary_key :id
    attribute :full_name, :string, allow_nil?: false, public?: true
    attribute :headline, :string, public?: true
    attribute :status, :atom, default: :active, public?: true
    timestamps()
  end

  relationships do
    belongs_to :organization, MyApp.Accounts.Organization,
      attribute_type: :integer,
      public?: true
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

Query BM25 search rankings, pin historical time-travel snapshots, and isolate `async: true` tests via `Xitdb.Ash.TestSandbox`:

```elixir
# 1. Ranked BM25 + prefix search preserved on an Ash.Query:
ranked_ids = Xitdb.Ash.Search.ids(MyApp.Accounts.Profile, "alice principal", limit: 25)

profiles =
  MyApp.Accounts.Profile
  |> Ash.Query.filter(id in ^ranked_ids)
  |> Xitdb.Ash.Search.sort_by_rank(ranked_ids)
  |> Ash.read!()

# 2. Time-travel any Ash read, aggregate, or BM25 search to an earlier moment:
MyApp.Store.with_as_of(moment_v0, fn ->
  Ash.read!(MyApp.Accounts.Profile)
end)
```

### 2. Hybrid MDM Sync Extension (`extensions: [Xitdb.Ash.Resource]`)

When pairing `Xitdb` with an external primary store (such as `Ash.DataLayer.Postgres`) as an immutable Master Data Management engine or secondary audit graph, add `Xitdb.Ash.Resource` to `extensions:` to configure collections, survivorship/lock fields, nested sub-collections (`nested_in`), and compile-time verified sync projections (`VerifySyncProjection`):

```elixir
defmodule MyApp.Accounts.Organization do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: Ash.DataLayer.Postgres,
    extensions: [Xitdb.Ash.Resource]

  xitdb do
    store MyApp.MDM.Store
    collection :organizations
    merge_redirect_collection :org_merged_into
    locked_ids_set :locked_org_ids

    editable_fields [:name, :domain]
    passthru_fields [:creatio_id, :parent_organization_id]
    computed_xitdb_fields [:normalized_name]
    field_aliases parent_organization_id: :parent_org_id

    indexes(
      domain: "domain->org_id",
      normalized_name: "norm_name->org_id"
    )
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :domain, :string, public?: true
    attribute :creatio_id, :string, public?: true
    attribute :parent_organization_id, :uuid, public?: true
  end
end
```

Use `tx_for` / `tx_for!` to automatically prepend the resource's configured `index_on` rules at compile time, and `Xitdb.Ash.Info` for `O(1)` precompiled Pull projections:

```elixir
use Xitdb.DSL
alias MyApp.Accounts.Organization

db =
  tx_for! db, Organization, doc: "upsert organization 101" do
    put organizations["101"].id, "101"
    put organizations["101"].name, "Northleaf Capital"
    put organizations["101"].domain, "northleafcapital.com"
    put organizations["101"].normalized_name, "northleaf capital"
  end

db["domain->org_id"]["northleafcapital.com"] # => "101"

pattern = Xitdb.Ash.Info.pull_pattern_for(Organization)
Xitdb.pull!(db["organizations"]["101"], pattern)
```

---

## Documentation & Guides

#### Core Concepts & Protocols
- **[Lazy Cursors, `Access` & `Enumerable` (`docs/access-and-enumerable.md`)](docs/access-and-enumerable.md)** — 9-byte `Slot` cursors, bracket navigation (`db["users"]["alice"]`), `get_in`/`put_in`/`update_in`/`pop_in`, `Xitdb.at/1`, `Enumerable` fast paths (`Enum.count/1`, `Enum.member?/2`, `Enum.slice/2`), and chunked `Stream` pagination.
- **[Collections & Secondary Indexing (`docs/collections-and-indexing.md`)](docs/collections-and-indexing.md)** — Choosing between `hash_map`, `counted_map`, `sorted_map`, `array_list`, `linked_list`, and sets, plus secondary B+Tree indexing (`index_on`).
- **[Time-Travel, Diffs, History & Storage (`docs/time-travel-and-storage.md`)](docs/time-travel-and-storage.md)** — `O(1)` snapshots (`as_of/2`), structural moment diffs (`diff_moments/3`), attribute lineage (`history_of/2`), storage backends (`:memory`, `:file`, `:buffered_file`), and online compaction (`compact/2`).

#### Macro DSLs & Query Languages
- **[Path Selector & Structural Pull DSL (`docs/path-and-pull-dsl.md`)](docs/path-and-pull-dsl.md)** — `path/1`, typed collection modifiers (`counted`, `sorted`, `[[idx]]`), set member probes, wildcard scans (`*`), and structural `Xitdb.pull/2` patterns.
- **[Declarative Transaction Block DSL (`docs/transaction-dsl.md`)](docs/transaction-dsl.md)** — `tx/2,3`, `tx_for/3,4`, `put` (including 1-arity set member additions), `update/2,3`, `rm`, `append`, `insert`, `slice`, `fork`, `index_on`, `meta`, `instant`, `savepoint`, and `abort`.
- **[Declarative Datalog Query DSL (`docs/datalog-dsl.md`)](docs/datalog-dsl.md)** — `datalog/1` and `query/2,3`, `^var` pinning, entity generators (`u <- users`), set membership, transitive graph reachability (`reach/3,4`), cross-moment queries (`at_moment/2`), and aggregations.
- **[Ash & Spark Integration (`docs/ash-and-spark.md`)](docs/ash-and-spark.md)** — Native `Xitdb.Ash.DataLayer`, `Xitdb.Ash.Store`, `Xitdb.Ash.Search` (BM25 + prefix search), `Xitdb.Ash.TestSandbox`, `Xitdb.Ash.Resource` Spark DSL extension, `Xitdb.Ash.Info` introspection, and `tx_for` / `tx_for!`.

---

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Elixir Client & Ash DataLayer (lib/xitdb*.ex)                              │
│  • %Xitdb{} handle + %Xitdb.Cursor{db_ref, tag, tag_id, value, moment}     │
│  • Access, Enumerable, Inspect protocols                                   │
│  • Xitdb.DSL + Xitdb.Pull + Xitdb.TxCompiler + Xitdb.Sigils (~x, ~q)       │
│  • Xitdb.Ash.{DataLayer, Store, Search, TestSandbox, Resource, Info, Tx}   │
├────────────────────────────────────────────────────────────────────────────┤
│ C-ABI Erlang NIF Boundary (native/nif_entry.c + native/xitdb_nif.odin)     │
│  • ErlNifResourceType + ErlNifRWLock thread safety                         │
│  • Coarse-grained transaction batching, B+Tree seek & BM25 search pushdown │
├────────────────────────────────────────────────────────────────────────────┤
│ Native Engine Submodule (native/xitdb-odin/xitdb)                          │
│  • 16-way HAMT, Radix Trie, Counted B-Tree, B+Tree, Compactor & Datalog    │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Development, Testing & Benchmarks

```bash
# 1. Run precommit checks (formatting, --warnings-as-errors, and 4-layer ATDD specs)
mix precommit

# 2. Run the 4-layer Client ATDD executable specification & property suite
mix test --trace

# 3. Run the 1v1 Client Statistical Benchmark Suite (Elixir Wrapper vs Raw Odin)
./benchmarks/compare_1v1.py --runs 5 --warmup 1
./benchmarks/update_readme.sh
```

See [`benchmarks/README.md`](https://github.com/boxxxie/xitdb-elixir/blob/master/benchmarks/README.md) for full statistical latency, throughput, and NIF overhead tables, and [`usage-rules.md`](usage-rules.md) for LLM/coding agent integration rules.
