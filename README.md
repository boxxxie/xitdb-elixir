# Xitdb — Idiomatic Elixir Client for `xitdb`

[![Hex.pm](https://img.shields.io/badge/hex-0.1.0-blue.svg)](https://hex.pm/packages/xitdb)
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
  Use `cursor["key"]`, `cursor[idx]`, `get_in/2`, `put_in/3`, `update_in/3`, `pop_in/2`, `Enum.count/1` ($O(1)$ on counted maps/sets/lists), `Enum.member?/2` ($O(1)$ HAMT membership), `Enum.slice/2` ($O(\log N)$ index seek), and lazy `Stream.*` pipelines.
- **Instant Time-Travel & Structural Diffs:**
  Pin historical snapshots in $O(1)$ with `Xitdb.as_of(db, moment)`, diff any two moments in $O(\Delta)$ with `Xitdb.diff_moments/3`, and inspect attribute lineage with `Xitdb.history_of/2`.
- **Compile-Time Validated Sigils (`~x`, `~q`), Pull & Datalog:**
  Validate path selectors (`~x|.users["101"].todos[1]|`) and Datalog queries (`~q"find ?name where ..."`) at compile time, project nested subtrees with Datomic-style `Xitdb.pull/2`, and run Datalog queries with B+Tree secondary index pushdown and grouped aggregations.

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

# 6. Datomic Pull projections & Datalog queries
Xitdb.pull!(alice, "{name, age, roles[0..1]}")
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

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│ Elixir Client Layer (lib/xitdb*.ex)                                        │
│  • %Xitdb{} handle + %Xitdb.Cursor{db_ref, tag, tag_id, value, moment}     │
│  • Access, Enumerable, Inspect protocols                                   │
│  • Xitdb.TxCompiler + Xitdb.Sigils (~x, ~q)                                │
├────────────────────────────────────────────────────────────────────────────┤
│ C-ABI Erlang NIF Boundary (native/nif_entry.c + native/xitdb_nif.odin)     │
│  • ErlNifResourceType + ErlNifRWLock thread safety                         │
│  • Coarse-grained transaction batching & chunked iterator pagination       │
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

See [`benchmarks/README.md`](benchmarks/README.md) for full statistical latency, throughput, and NIF overhead tables, and [`usage-rules.md`](usage-rules.md) for LLM/coding agent integration rules.
