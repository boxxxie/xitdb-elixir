# Lazy Cursors, `Access` & `Enumerable` (`%Xitdb.Cursor{}`)

Unlike traditional embedded database wrappers that eagerly deserialize on-disk records into BEAM heap maps on every read, `Xitdb` exposes database nodes as **Clojure/Datomic-style lazy `%Xitdb.Cursor{}` handles**.

Each `%Xitdb.Cursor{}` wraps only the NIF database resource reference (`db_ref`) and a **9-byte `Slot` coordinate** (`tag`, `tag_id`, `value`, `moment`). Navigating or slicing a cursor resolves only the requested path steps across the NIF boundary without touching or copying sibling subtrees.

---

## 1. The 9-Byte `Slot` Cursor Model & Process Safety

When you read from a `%Xitdb{}` handle (`Xitdb.db(db)`, `Xitdb.as_of(db, moment)`, or `db["users"]`):

1. **Containers return `%Xitdb.Cursor{}` in `O(1)` heap space:**
   If the target slot is a collection (`:hash_map`, `:counted_hash_map`, `:sorted_map`, `:array_list`, `:linked_array_list`, `:hash_set`, `:counted_hash_set`, `:sorted_set`), `Xitdb` returns a lightweight `%Xitdb.Cursor{}` struct pointing to that collection's byte offset.
2. **Leaf scalars unwrap automatically:**
   If the target slot is a scalar (`String.t()`, `integer()`, `float()`, `boolean()`, or `{:tagged, tag, payload}`), `Xitdb` immediately decodes and returns the native Elixir value.
3. **Pure Elixir values across BEAM processes:**
   Because `%Xitdb.Cursor{}` holds only an `ErlNifResourceType` reference (`db_ref`) and integer slot coordinates—with `ErlNifRWLock` reader/writer synchronization inside the NIF—cursors are **pure, immutable Elixir values**. You can pass them freely across `Task.async_stream/3`, GenServers, `:ets` tables, and Phoenix LiveView assigns without locks or lifetime hazards:

```elixir
{:ok, db} = Xitdb.open(backend: :memory)

{:ok, db} =
  Xitdb.transact(db, %{
    "users" => %{
      "alice" => %{"name" => "Alice Liddell", "age" => 30, "roles" => ["admin", "staff"]},
      "bob" => %{"name" => "Bob Builder", "age" => 28, "roles" => ["member"]}
    }
  })

# Grab a lazy cursor to the "users" Hash_Map (O(1), 0 map keys copied)
users_cursor = db["users"]

# Fan out concurrent reads across BEAM schedulers using the same cursor value
names =
  ["alice", "bob"]
  |> Task.async_stream(fn id -> users_cursor[id]["name"] end)
  |> Enum.map(fn {:ok, name} -> name end)
# => ["Alice Liddell", "Bob Builder"]
```

---

## 2. Reading with `Access` (`cursor[key]`, `get_in/2`, `Xitdb.at/1`)

Both `%Xitdb{}` and `%Xitdb.Cursor{}` implement Elixir's `@behaviour Access`:

```elixir
root = Xitdb.db(db)

# 1. String and atom keys on maps (Hash_Map, Counted_Hash_Map, Sorted_Map)
root["users"]["alice"]["name"] # => "Alice Liddell"
root[:users][:alice][:age]     # => 30
root["users"]["missing"]       # => nil

# 2. Positive and negative integer indices on lists (Array_List, Linked_Array_List)
root["users"]["alice"]["roles"][0]  # => "admin"
root["users"]["alice"]["roles"][-1] # => "staff"
root["users"]["alice"]["roles"][99] # => nil

# 3. Deep navigation with Kernel.get_in/2
get_in(root, ["users", "alice", "roles", 0])
# => "admin"
```

### Using `Xitdb.at/1` Instead of `Access.at/1`

Elixir's built-in `Access.at/1` function guards `when is_list(data)` and raises `FunctionClauseError` when given a `%Xitdb.Cursor{}` struct. When building functional lens pipelines with `get_in/2` or `update_in/3`, either pass raw integer indices in the path list or use `Xitdb.at/1`:

```elixir
# Direct integer key in path list:
get_in(root, ["users", "alice", "roles", 1])
# => "staff"

# Or using the Xitdb.at/1 lens function:
get_in(root, ["users", "alice", "roles", Xitdb.at(1)])
# => "staff"
```

---

## 3. Transactional `Access` Mutations (`put_in/3`, `update_in/3`, `pop_in/2`)

When you pass a 1-arity callback to `Xitdb.transact/3`, the callback receives a root `%Xitdb.Cursor{}` with `tx_mode: true`.

In `tx_mode: true`:
- `put_in/3`, `update_in/3`, `pop_in/2`, and `get_and_update_in/3` stage coarse-grained transaction operations on the root cursor.
- **Read-your-own-writes:** Staged puts (`staged_overrides`) and removals (`deleted_paths`) are tracked in memory on the cursor so subsequent `cursor[key]` or `update_in/3` calls in the same callback see your uncommitted edits immediately.
- Native list and subtree helpers (`Xitdb.insert_at/4`, `Xitdb.delete_at/3`, `Xitdb.fork/3`) pipe directly on the root cursor.

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

## 4. `Enumerable` Fast-Path Pushdowns & `Stream` Pagination

`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure pushdowns so common `Enum` operations execute in `O(1)` or `O(log N)` inside Odin rather than linearly scanning elements in Elixir:

| `Enum` / `Stream` Operation | Backing NIF Pushdown | Complexity | Supported Collection Kinds |
| :--- | :--- | :--- | :--- |
| `Enum.count(cursor)` | `nif_slot_count` | **`O(1)`** | `Counted_Hash_Map`, `Counted_Hash_Set`, `Sorted_Map`, `Sorted_Set`, `Array_List`, `Linked_Array_List` *(falls back to `O(N)` reducer on uncounted `Hash_Map` / `Hash_Set`)* |
| `Enum.member?(set_cur, "val")` | `nif_slot_contains` | **`O(1)` / `O(log N)`** | `Hash_Set`, `Counted_Hash_Set` (`O(log_16 N)` HAMT), `Sorted_Set` (`O(log N)` B+Tree) |
| `Enum.member?(map_cur, {k, v})` | `Cursor.fetch` + equality | **`O(1)` / `O(log N)`** | `Hash_Map`, `Counted_Hash_Map`, `Sorted_Map` |
| `Enum.slice(cursor, first..last)`<br>`Enum.at(cursor, idx)` | `nif_slot_slice` | **`O(log N + K)`** | `Array_List`, `Linked_Array_List`, `Sorted_Map` (yields `{k, v}` tuples in key order), `Sorted_Set` (yields members in key order) |
| `Stream.take(cursor, k)`<br>`Enum.to_list(cursor)` | `nif_slot_entries` | **Adaptive chunks (`16 -> 64 -> 256`)** | All 8 collection types |

### Examples

```elixir
{:ok, db} =
  Xitdb.transact(db, %{
    "metrics" => Xitdb.counted_map(%{"cpu" => 42, "mem" => 78, "disk" => 19}),
    "leaderboard" => Xitdb.sorted_map(%{" rank:1" => "alice", " rank:2" => "bob", " rank:3" => "carol"}),
    "permissions" => Xitdb.counted_set(["read", "write", "deploy"]),
    "events" => Xitdb.linked_list(["e1", "e2", "e3", "e4", "e5"])
  })

root = Xitdb.db(db)

# 1. O(1) count header lookup
Enum.count(root["metrics"])     # => 3
Enum.count(root["permissions"]) # => 3

# 2. O(1) HAMT membership check (does NOT convert the set or map to a list)
Enum.member?(root["permissions"], "deploy") # => true
Enum.member?(root["metrics"], {"cpu", 42})  # => true

# 3. O(log N + K) index-seek slicing on Linked_Array_List and Sorted_Map
Enum.slice(root["events"], 1..3)
# => ["e2", "e3", "e4"]

Enum.slice(root["leaderboard"], 0..1)
# => [{" rank:1", "alice"}, {" rank:2", "bob"}]

# 4. Lazy streaming with adaptive chunking (fetches only the first 16-item page)
root["leaderboard"]
|> Stream.map(fn {_rank, user} -> String.upcase(user) end)
|> Enum.take(2)
# => ["ALICE", "BOB"]
```

---

## 5. NIF Boundary Cost Model & When to Use `Access` vs. the Macro DSL

Every BEAM-to-Odin NIF call pays a predictable boundary marshaling and lock-acquisition cost. Understanding this cost model makes it easy to pick the fastest `Xitdb` API for a given workload:

### Fixed Per-Call NIF Floor (`~150–250 ns`)

Each RW-locked NIF call (`enif_get_resource` + `enif_rwlock_rlock` + `resolve_slot_coord` + `enif_make_*` term construction) carries a fixed overhead of **`~150–250 ns`** relative to in-process Raw Odin execution:
- **`O(1)` header read (`Enum.count/1` on `Counted_Hash_Map`):** `~155–199 ns` in Elixir vs. `~6–8 ns` in Raw Odin.
- **Single-hop container lookups (`Array_List`, `Linked_Array_List`, `Sorted_Map`):** `~340–580 ns` in Elixir vs. `~108–391 ns` in Raw Odin (adding `~185–255 ns` of boundary overhead).

### Multi-Hop `Access` (`N × ~200 ns`) vs. Single-Call `Xitdb.select/2` & `Xitdb.pull/2`

- **Chained `Access` (`root["users"][id]["name"]`):** Executes one NIF crossing per bracket hop (`3 × nif_slot_get_key`) with inlined slot/tag unwrapping (`~2.28–2.33 µs` for 3 hops vs. `~0.63–0.66 µs` in Raw Odin).
- **Single-call string selector (`Xitdb.select!(db, path(users[id].name))`):** Resolves the entire selector path inside Odin in **1 NIF crossing** (`~2.04–2.08 µs` for 3 hops), keeping boundary overhead constant as path depth grows to 4+ hops.
- **Pre-tokenized `path_steps/1` (`use Xitdb.DSL`; `Xitdb.select!(db, path_steps(users[id].name))`):** Compiles the path at compile time into a flat step list (`["users", id, "name"]`, or `{kind, val}` tuples when typed modifiers are used) that C (`decode_steps_term_buf`) unpacks directly (`~1.99 µs`)—eliminating Elixir string interpolation and Odin selector parsing on dynamic keys. Prefer `Xitdb.DSL.path_steps/1` over `path/1` in hot `select/2`, `select!/2`, and `history_of/2` loops with runtime variables (`Xitdb.DSL.tx` blocks already compile bare path expressions directly); keep `~x` for zero-allocation static literal paths or `path/1` when you need a printable selector string.
- **Structural Pull (`Xitdb.pull!(cursor, [:username, :age, todos: 0..3, profile: [:city]])`):** Projects multiple fields and bounded list slices in **1 NIF crossing** (`~6.28–6.49 µs`) instead of issuing `K` separate `cursor[field]` calls across the boundary.

### Fused B+Tree Prefix & Range Scans (`nif_sorted_map_seek/7`)

When scanning a `Sorted_Map` B+Tree whose values are child containers (such as `Xitdb.Ash.Search` term postings or `Xitdb.Ash.Indexer` secondary index ID sets), fetching the B+Tree keys first and then calling `nif_slot_entries` per key pays the `~150–250 ns` NIF floor on every child container.

- **Fused decode (`decode_children: true`):** Passing `true` as the 7th argument to `Xitdb.NIF.nif_sorted_map_seek/7` (used by `Xitdb.Ash.Search.Storage.scan_prefix/5`) seeks to the start key / prefix in the B+Tree and materializes each bounded child container inside Odin in a single NIF crossing, returning `{key, entries}` directly (falling back to lazy 3-tuples `{key, tag_id, val}` when oversized).
- **Lazy cursor scan (`decode_children: false`):** Use `Xitdb.NIF.nif_sorted_map_seek/5` (or `Xitdb.Ash.Search.Storage.scan_prefix_cursors/4` and `Xitdb.Ash.Indexer.Storage.stream_index_from/4`) when you want lazy `%Xitdb.Cursor{}` handles (`from_compact_slot/5`) without decoding out-of-range child containers.

### Transactional Writes (`put_in/3` vs. `Xitdb.DSL.tx` / Map `Xitdb.transact/3`)

- **Nested `put_in/3` (`put_in(root["users"][id]["score"], val)`):** In `tx_mode`, intermediate map brackets (`root["users"][id]`) stage virtual write cursors without intermediate read NIF calls before compiling `{:put, selector, val}` (`~13.9–14.2 µs` for a 3-hop `put_in/3` commit vs. `~3.60–3.77 µs` in Raw Odin; `odin_nif_transact` commits optimistically for `Hash_Map` and adapts lazily on `.Unexpected_Tag`).
- **Declarative `Xitdb.DSL.tx` (`put users[id].score, val`) & map `Xitdb.transact/3`:** Avoid Elixir struct/closure path staging as well, compiling all operations into a single batched `nif_transact` call (auto-vivifying missing intermediate maps inside Odin).

### Choosing the Right API

| Use Case | Recommended API | Why |
| :--- | :--- | :--- |
| Interactive exploration, passing subtrees to functions/LiveViews, or shallow 1–2 hop reads | **Lazy `Access` (`db["users"][id]`)** | Returns composable `%Xitdb.Cursor{}` values that work with standard Elixir `Enum`, `Stream`, and `Access` functions. |
| Reading a known deep (3+ hop) path with dynamic keys in a single NIF crossing | **`Xitdb.select(db, path_steps(users[id].profile.city))`** | Eliminates Elixir selector string formatting and Odin selector parsing while resolving the entire path in 1 NIF call. |
| Reading a static literal path or passing a string selector (e.g., `history_of/2`) | **`~x|.users.alice.city|`** / **`path(...)`** | `~x` compiles to a static binary literal at compile time; `path/1` produces a formatted selector string. |
| Projecting multiple fields + bounded list slices from an entity | **`Xitdb.pull(cursor, [:username, todos: 0..5])`** | Projects the exact shape in 1 NIF call without materializing unneeded subtrees. |
| Scanning `Sorted_Map` prefix/range buckets whose values are child sets/maps | **`nif_sorted_map_seek/7` (`decode_children: true`)** | Fuses B+Tree seek and child container decoding inside Odin in 1 NIF call instead of paying `~150–250 ns` per child slot. |
| Writing to deep paths in tight loops, auto-vivifying missing maps, or batching list `append`/`insert`/`slice`/`fork` | **`Xitdb.DSL.tx db do ... end`** | Avoids virtual `put_in/3` struct/closure staging overhead, auto-vivifies missing intermediate collections with **zero intermediate NIF reads**, and batches all ops into one commit. |
