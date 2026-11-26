# Xitdb

[![CI](https://github.com/boxxxie/xitdb-elixir/actions/workflows/ci.yml/badge.svg)](https://github.com/boxxxie/xitdb-elixir/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/badge/hex-2.5.1-blue.svg?logo=elixir&logoColor=white)](https://hex.pm/packages/xitdb)
[![Elixir](https://img.shields.io/badge/Elixir-~%3E%201.19-4B275F.svg?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09%2B-3882D2.svg)](https://odin-lang.org)
[![Ash](https://img.shields.io/badge/Ash-3.37.2%2B-E04F5F.svg)](https://ash-hq.org)
[![Format](https://img.shields.io/badge/xitdb-v2%20wire%20format-5C6BC0.svg)](https://github.com/xit-vcs/xitdb)
[![Benchmarks](https://img.shields.io/badge/benchmarks-32%20workloads-orange.svg)](https://github.com/boxxxie/xitdb-elixir/blob/master/benchmarks/README.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

`Xitdb` brings [`xitdb`](https://github.com/xit-vcs/xitdb) to Elixir—an embedded, single-file database where you store nested maps, lists, sorted maps, and sets directly on disk, and every transaction commits an immutable snapshot in time.

Think **SQLite meets Elixir's immutable data structures with Git-like history built in**: there is no external database server, no SQL migrations, and no JSON-blob serialization boilerplate. You read and update nested data with standard Elixir `Access` (`db["users"]["alice"]["roles"][0]`), `Enum`, and `Stream`, or reach for `Xitdb`'s declarative transaction blocks, Pull projections, Datalog queries, and native [Ash Framework](https://ash-hq.org) integration with built-in full-text search.

---

## What is xitdb?

- **Embedded & nested, not flat tables or opaque blobs:** Runs in `:memory` or a single `.xit` file like SQLite, while natively storing arbitrarily nested maps, lists, sorted B+Tree maps, and sets directly on disk.
- **Git-like history built into every write:** Updating a value never overwrites past commits. Every transaction appends a new immutable *moment* that shares unchanged subtrees with earlier moments—giving you time-travel, diffs, and field audit history out of the box.
- **Lazy cursors, not whole-file loads:** Accessing `db["users"]["alice"]` returns a lightweight `%Xitdb.Cursor{}` handle instead of loading the entire database into memory. Only the keys or slices you actually read are fetched, and cursors pass freely across BEAM processes, `Task`s, and LiveViews.

---

## Features

- **Feels Like Native Elixir (`Access`, `Enum` & `Stream`):** Navigate nested maps and lists with bracket lookups, `get_in/2`, `put_in/3`, `update_in/3`, and `pop_in/2`, or pipe collections straight into `Enum.count/1`, `Enum.member?/2`, `Enum.slice/2`, and lazy `Stream` pipelines.
- **Built-In Time-Travel, Diffs & Audit History:** Pin any past commit with `Xitdb.as_of/2`, compare any two commits with `Xitdb.diff_moments/3`, trace when and why any field changed with `Xitdb.history_of/2`, or branch new transactions from an older moment.
- **Instant Zero-Copy Cloning (`fork`):** Duplicate an entire user, tenant, or document tree inside a transaction without copying its underlying data; subsequent edits diverge cleanly via copy-on-write.
- **Rich Persistent Collections & Automatic Indexes:** Plain Elixir maps, lists, and `MapSet`s work out of the box, with opt-in `Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, and `Xitdb.sorted_set/1`, plus automatic secondary indexes (`index_on`) that stay in sync across updates and deletes.
- **Expressive Elixir DSLs (`tx`, `pull`, & Datalog):** Stage deep multi-path writes with `tx db do ... end`, fetch shaped entity slices in one step with `Xitdb.pull/2`, and run joins, aggregations, recursive graph `reach`, and cross-moment `at_moment` queries with `query db do ... end`.
- **Crash-Safe Single-File Storage & Compaction:** Append-only checksummed commits require no separate WAL sidecar, recover cleanly after crashes, and reclaim historical space online via `Xitdb.compact/2`.
- **Drop-In Ash Framework DataLayer & Full-Text Search:** Persist `Ash.Resource` domains in `.xit` files (`data_layer: Xitdb.Ash.DataLayer`) with relationships, secondary indexes, ranked BM25 + prefix search (`Xitdb.Ash.Search`), foreign-key cascades, time-travel (`Xitdb.Ash.Store.with_as_of/3`), and `async: true` `Xitdb.Ash.TestSandbox` isolation—with zero SQL migrations.

---

## A Tour in Code

### 1. Read and Update Like Plain Elixir Data

```elixir
# Open in memory (or use backend: :buffered_file, path: "app.xit" for disk persistence)
{:ok, db} = Xitdb.open(backend: :memory)

# Commit a nested Elixir map as moment 0
{:ok, db} =
  Xitdb.transact(
    db,
    %{
      "users" => %{
        "alice" => %{
          "username" => "alice",
          "name" => "Alice Liddell",
          "age" => 30,
          "roles" => ["admin", "architect"]
        }
      }
    },
    doc: "Seed initial users",
    index_rules: [{:index_on, "users", "username", "username->id"}]
  )

# Navigate lazily with standard Access brackets and Enum
db["users"]["alice"]["name"]      # => "Alice Liddell"
db["users"]["alice"]["roles"][0]  # => "admin"
Enum.to_list(db["users"]["alice"]["roles"])
# => ["admin", "architect"]

# Update nested paths inside a transaction (creates moment 1)
{:ok, db} =
  Xitdb.transact(
    db,
    fn root ->
      update_in(root["users"]["alice"]["age"], &(&1 + 1))
    end,
    doc: "Birthday bump"
  )
```

### 2. Time-Travel, Diffs & Field History

```elixir
# Pin an immutable snapshot of moment 0 without copying data
v0 = Xitdb.as_of(db, 0)

v0["users"]["alice"]["age"] # => 30
db["users"]["alice"]["age"] # => 31

# Diff any two moments
Xitdb.diff_moments(db, 0, 1)
# => {:ok, [%{op: :put, path: ".users.alice.age", old_value: 30, new_value: 31}]}

# Inspect every commit that changed a field
Xitdb.history_of(db, ".users.alice.age")
# => {:ok, [
#   %{moment_index: 0, value: 30, doc: "Seed initial users", instant: 0},
#   %{moment_index: 1, value: 31, doc: "Birthday bump", instant: 0}
# ]}
```

### 3. Declarative Transactions, Pull & Datalog

```elixir
use Xitdb.DSL

id = "alice"

# Atomic transaction block with secondary indexes, list ops & zero-copy fork
{:ok, db} =
  tx db, doc: "promote alice" do
    index_on :users, :username, "username->id"
    put users[id].role, "principal"
    append users[id].roles, "staff"
    fork users[id], backups[id]
    update users[id].age, 0, &(&1 + 1)
  end

# Shape-based Pull projection with bounded list slicing
Xitdb.pull!(db["users"]["alice"], [:name, :role, roles: 0..1])
# => %{"name" => "Alice Liddell", "role" => "principal", "roles" => ["admin", "architect"]}

# Datalog query with pinned runtime variables (^var)
prefix = "al"
min_age = 21

{:ok, %{rows: [["alice", 32]]}} =
  query db do
    find {uid, age}

    where [
      sorted("username->id")[uname] == uid,
      starts_with(uname, ^prefix),
      users[uid].age == age,
      age >= ^min_age
    ]
  end
```

### 4. Ash Framework & Built-In Full-Text Search

```elixir
defmodule MyApp.Accounts.Profile do
  use Ash.Resource,
    domain: MyApp.Accounts,
    data_layer: Xitdb.Ash.DataLayer

  xitdb do
    store MyApp.Store
    collection :profiles

    index [:status, :inserted_at]

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
end
```

Run ranked BM25 + prefix search and time-travel reads straight through Ash:

```elixir
require Ash.Query

ranked_ids = Xitdb.Ash.Search.ids(MyApp.Accounts.Profile, "alice principal", limit: 25)

profiles =
  MyApp.Accounts.Profile
  |> Ash.Query.filter(id in ^ranked_ids)
  |> Xitdb.Ash.Search.sort_by_rank(ranked_ids)
  |> Ash.read!()

# Time-travel any Ash read, aggregate, or search to an earlier moment
Xitdb.Ash.Store.with_as_of(MyApp.Store, moment_v0, fn ->
  Ash.read!(MyApp.Accounts.Profile)
end)
```

---

## Installation

Add `xitdb` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xitdb, "~> 2.4"}
  ]
end
```

### System Requirements

Compiling `xitdb` builds an embedded Erlang NIF wrapping the Odin database engine:

- **Odin Compiler:** `odin` must be available in your `PATH` (see [Odin Getting Started](https://odin-lang.org/docs/install/)).
- **C Compiler:** A standard C compiler (`cc` or `gcc`) for the thin NIF entry shim.

---

## Guides

### Core Concepts
- **[Reading & Updating with Access & Enum](docs/access-and-enumerable.md)** — Bracket navigation, `get_in`/`put_in`/`update_in`/`pop_in`, `Xitdb.at/1`, passing cursors across processes, and `Enum` / `Stream` pipelines.
- **[Collections & Secondary Indexes](docs/collections-and-indexing.md)** — Choosing between maps (`hash_map`, `counted_map`, `sorted_map`), lists (`array_list`, `linked_list`), sets, custom tagged scalars, and `index_on` secondary indexes.
- **[Time-Travel, Diffs & Storage](docs/time-travel-and-storage.md)** — Snapshots (`as_of/2`), moment diffs (`diff_moments/3`), field lineage (`history_of/2`), branching history, zero-copy `fork`, backends, and compaction.

### DSLs, Queries & Ash
- **[Transaction DSL](docs/transaction-dsl.md)** — Declarative `tx` and `tx_for` blocks, automatic path creation, list edits, `fork`, metadata, savepoints, and rollbacks.
- **[Path Selectors & Pull Projections](docs/path-and-pull-dsl.md)** — Shape-based `Xitdb.pull/2` projections, `pull_pattern/1`, `path/1`, `~x`, and automatic key escaping.
- **[Datalog & Graph Queries](docs/datalog-dsl.md)** — `query` and `datalog` blocks, `^var` pinning, multi-collection joins, aggregations, recursive `reach`, and cross-moment `at_moment` queries.
- **[Ash Framework & Full-Text Search](docs/ash-and-spark.md)** — `Xitdb.Ash.DataLayer`, `Xitdb.Ash.Store`, `Xitdb.Ash.Search` (BM25 + prefix search), `nested_in` subtrees, `tx_for`, and `async: true` `Xitdb.Ash.TestSandbox`.

### Under the Hood
- **[Architecture, Internals & Performance](docs/architecture-and-internals.md)** — Storage format, 9-byte `Slot` cursors, WAL-free crash safety, NIF boundary cost model, and single-writer supervision.

---

## Under the Hood & Development

`Xitdb` embeds [`odin-xitdb`](https://github.com/boxxxie/odin-xitdb) in-process via a C-ABI Erlang NIF (`native/nif_entry.c` + `native/xitdb_nif.odin`), giving Elixir applications direct access to `xitdb`'s persistent tries, B+Trees, Datalog engine, and BM25 search without serialization overhead or an external daemon. See [Architecture, Internals & Performance](docs/architecture-and-internals.md) for the full technical design and [1v1 Client Benchmarks (`benchmarks/README.md`)](https://github.com/boxxxie/xitdb-elixir/blob/master/benchmarks/README.md) for latency and throughput numbers across 32 workloads.

```bash
# Run formatting, --warnings-as-errors compile, and tests
mix precommit

# Run the specification and property test suite with trace
mix test --trace

# Replay ExFuzz regression seeds or run a bounded coverage-guided fuzz campaign
mix test --only fuzz
mix fuzz test/fuzz/parsers_and_codecs_fuzz_test.exs:90 --max-runs 50000
```
