# Reading & Updating with Access & Enum

`Xitdb` lets you read and update database contents just like ordinary Elixir maps and lists. Navigating a database (`db["users"]["alice"]`) stays lazy: instead of loading entire subtrees into memory, container lookups return a lightweight `%Xitdb.Cursor{}` while leaf scalars (strings, numbers, booleans, and custom tagged values) unwrap automatically to native Elixir values.

---

## 1. Reading Nested Data

Both `%Xitdb{}` and `%Xitdb.Cursor{}` implement Elixir's `Access` behaviour:

```elixir
root = Xitdb.db(db)

# 1. String and atom keys on maps
root["users"]["alice"]["name"] # => "Alice Liddell"
root[:users][:alice][:age]     # => 30
root["users"]["missing"]       # => nil

# 2. Positive and negative integer indices on lists
root["users"]["alice"]["roles"][0]  # => "admin"
root["users"]["alice"]["roles"][-1] # => "staff"
root["users"]["alice"]["roles"][99] # => nil

# 3. Deep navigation with Kernel.get_in/2
get_in(root, ["users", "alice", "roles", 0])
# => "admin"
```

When a path resolves to a map, list, or set, `root["users"]` returns a `%Xitdb.Cursor{}`. If you need the entire subtree as plain Elixir data, call `Xitdb.materialize(cursor)` (preferring a leaf entity cursor like `root["users"]["alice"]` over the whole database root).

### Using `Xitdb.at/1` Instead of `Access.at/1`

Elixir's built-in `Access.at/1` guards `when is_list(data)` and raises `FunctionClauseError` when given a `%Xitdb.Cursor{}` list handle. Inside `get_in/2` or `update_in/3` pipelines, either pass integer indices directly in the path list or use `Xitdb.at/1`:

```elixir
# Direct integer key in path list:
get_in(root, ["users", "alice", "roles", 1])
# => "staff"

# Or using the Xitdb.at/1 lens function:
get_in(root, ["users", "alice", "roles", Xitdb.at(1)])
# => "staff"
```

---

## 2. Passing Cursors Across Processes

Because a `%Xitdb.Cursor{}` is a pure, immutable Elixir value pointing to an immutable moment in the store, you can pass cursors freely across `Task.async_stream/3`, `GenServer`s, `:ets` tables, or Phoenix LiveView assigns without copying subtrees or managing manual locks:

```elixir
{:ok, db} = Xitdb.open(backend: :memory)

{:ok, db} =
  Xitdb.transact(db, %{
    "users" => %{
      "alice" => %{"name" => "Alice Liddell", "age" => 30, "roles" => ["admin", "staff"]},
      "bob" => %{"name" => "Bob Builder", "age" => 28, "roles" => ["member"]}
    }
  })

# Grab a lazy cursor to "users" without copying any child entries
users_cursor = db["users"]

# Fan out concurrent reads across BEAM schedulers using the same cursor
names =
  ["alice", "bob"]
  |> Task.async_stream(fn id -> users_cursor[id]["name"] end)
  |> Enum.map(fn {:ok, name} -> name end)
# => ["Alice Liddell", "Bob Builder"]
```

---

## 3. Updating Data with `Access` (`put_in/3`, `update_in/3`, `pop_in/2`)

Direct mutations outside a transaction (such as `put_in(db["a"], 1)`) raise `ArgumentError`. To mutate data using `Access`, pass a 1-arity callback to `Xitdb.transact/3`:

- Inside the callback, `put_in/3`, `update_in/3`, `pop_in/2`, and `get_and_update_in/3` stage changes atomically for a single commit.
- **Read-your-own-writes:** Earlier edits staged inside the callback are immediately visible to subsequent reads and `update_in/3` calls in the same callback.
- Native list and subtree helpers (`Xitdb.insert_at/4`, `Xitdb.delete_at/3`, `Xitdb.fork/3`) pipe directly on the transaction root cursor.

```elixir
{:ok, db} =
  Xitdb.transact(
    db,
    fn root ->
      # 1. Remove a field with pop_in/2
      {_removed, root} = pop_in(root["users"]["alice"]["temp_token"])

      # 2. Pipe standard Access mutations and native collection operations
      root
      |> put_in(["users", "alice", "role"], "principal")
      |> update_in(["users", "alice", "age"], &(&1 + 1))
      |> Xitdb.insert_at(["users", "alice", "roles"], 0, "owner")
      |> Xitdb.fork(".users.alice", ".backups.alice")
    end,
    doc: "Promote Alice via Access pipeline"
  )
```

To abort and roll back from inside a `Xitdb.transact/3` callback, return `{:abort, reason}`:

```elixir
{:error, %Xitdb.Error{reason: :insufficient_balance}} =
  Xitdb.transact(db, fn root ->
    if root["vault"]["balance"] < 500 do
      {:abort, :insufficient_balance}
    else
      update_in(root["vault"]["balance"], &(&1 - 500))
    end
  end)
```

---

## 4. Using `Enum` and `Stream`

`%Xitdb.Cursor{}` implements `Enumerable`, delegating common collection operations directly to the database engine instead of converting collections into Elixir lists first:

| `Enum` / `Stream` Operation | Behavior | Supported Collection Kinds |
| :--- | :--- | :--- |
| `Enum.count(cursor)` | Instant `O(1)` count lookup | `counted_map`, `counted_set`, `sorted_map`, `sorted_set`, `array_list`, `linked_list` *(falls back to `O(N)` scan on uncounted `hash_map` / `hash_set`)* |
| `Enum.member?(set_cur, "val")` | Direct hash/tree membership check (`O(log_16 N)` / `O(log N)`) | `hash_set`, `counted_set`, `sorted_set` |
| `Enum.member?(map_cur, {k, v})` | Direct key lookup + value comparison (`O(log_16 N)` / `O(log N)`) | `hash_map`, `counted_map`, `sorted_map` |
| `Enum.slice(cursor, first..last)`<br>`Enum.at(cursor, idx)` | Direct index/offset seek (`O(log N + K)`) | `array_list`, `linked_list`, `sorted_map` (yields `{k, v}` in key order), `sorted_set` (yields members in key order) |
| `Stream.take(cursor, k)`<br>`Enum.to_list(cursor)` | Lazy chunked iteration (`16 -> 64 -> 256` items per page) | All 8 collection types |

### Examples

```elixir
{:ok, db} =
  Xitdb.transact(db, %{
    "metrics" => Xitdb.counted_map(%{"cpu" => 42, "mem" => 78, "disk" => 19}),
    "leaderboard" => Xitdb.sorted_map(%{"rank:1" => "alice", "rank:2" => "bob", "rank:3" => "carol"}),
    "permissions" => Xitdb.counted_set(["read", "write", "deploy"]),
    "events" => Xitdb.linked_list(["e1", "e2", "e3", "e4", "e5"])
  })

root = Xitdb.db(db)

# 1. Instant count lookup
Enum.count(root["metrics"])     # => 3
Enum.count(root["permissions"]) # => 3

# 2. Direct membership check (does not materialize the set or map)
Enum.member?(root["permissions"], "deploy") # => true
Enum.member?(root["metrics"], {"cpu", 42})  # => true

# 3. Direct slicing on linked lists and sorted maps
Enum.slice(root["events"], 1..3)
# => ["e2", "e3", "e4"]

Enum.slice(root["leaderboard"], 0..1)
# => [{"rank:1", "alice"}, {"rank:2", "bob"}]

# 4. Lazy streaming (fetches only the first chunk)
root["leaderboard"]
|> Stream.map(fn {_rank, user} -> String.upcase(user) end)
|> Enum.take(2)
# => ["ALICE", "BOB"]
```

---

## 5. When to Reach for `select`, `pull`, or `tx`

`Access` and `Enum` cover everyday navigation and updates cleanly. Reach for `Xitdb`'s DSL helpers when you need one of these patterns:

| Need | Recommended Tool | Guide |
| :--- | :--- | :--- |
| Projecting specific fields and bounded list slices from an entity in one step | **`Xitdb.pull/2`** | [Path Selectors & Pull Projections](path-and-pull-dsl.md) |
| Auto-creating missing intermediate maps, batching deep writes, or combining `append`/`insert`/`slice`/`fork` | **`tx db do ... end`** | [Transaction DSL](transaction-dsl.md) |
| Resolving deep dynamic paths in hot loops without intermediate cursors | **`Xitdb.select/2`** with `path_steps/1` or `~x` | [Path Selectors & Pull Projections](path-and-pull-dsl.md) |
| Queries with joins, aggregations, graph traversal, or historical joins | **`query db do ... end`** | [Datalog & Graph Queries](datalog-dsl.md) |

To learn how cursors work internally and compare per-operation NIF boundary costs, see [Architecture, Internals & Performance](architecture-and-internals.md).
