# Collections, Data Modeling & Secondary Indexes (`Xitdb.Collection`)

By default, when you pass standard Elixir data structures to `Xitdb.transact/3` or `put` inside `Xitdb.DSL.tx`:
- Plain Elixir maps (`%{}`) are stored as `:hash_map` (16-way HAMT).
- Plain Elixir lists (`[]`) are stored as `:array_list` (16-way Radix Trie).
- `%MapSet{}` values are stored as `:counted_hash_set` (16-way HAMT set with `O(1)` count).

When your workload requires **`O(1)` map cardinality**, **lexicographical B+Tree key ordering and range scans**, or **`O(log N)` middle-of-list insertions and removals**, wrap your data in `Xitdb`'s explicit collection constructors (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, etc.) or initialize them with `init_col` in `tx`.

---

## 1. Persistent Collection Types & Complexity Matrix

`xitdb` provides **8 persistent, structurally shared collection types**:

| Collection Kind | Constructor | Selector Sigil | Backing Structure | `get` / `member?` | `put` / `append` | `insert` / `rm` / `slice` | `Enum.count/1` |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `:hash_map` | `Xitdb.hash_map(map)` *(or `%{}`)* | `.key` | 16-way HAMT | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | `O(N)` scan |
| `:counted_hash_map` | `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count slot | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | **`O(1)`** |
| `:sorted_map` | `Xitdb.sorted_map(map)` | `$key` | Count-augmented B+Tree | `O(log N)` | `O(log N)` | `rm` & `slice`: **`O(log N)`** | **`O(1)`** |
| `:array_list` | `Xitdb.array_list(list)` *(or `[]`)* | `[idx]` | 16-way Radix Trie | `O(log_16 N)` | `O(log_16 N)` | Tail `slice` only; no middle `insert`/`rm` | **`O(1)`** |
| `:linked_array_list` | `Xitdb.linked_list(list)` | `[[idx]]` | Count-augmented B-Tree | `O(log N)` | `O(log N)` | Arbitrary `insert`, `rm`, `slice`: **`O(log N)`** | **`O(1)`** |
| `:hash_set` | `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | `O(N)` scan |
| `:counted_hash_set` | `Xitdb.counted_set(enum)` *(or `MapSet`)* | `#%member` | 16-way HAMT set + count | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | **`O(1)`** |
| `:sorted_set` | `Xitdb.sorted_set(enum)` | `^member` | Count-augmented B+Tree set | `O(log N)` | `O(log N)` | `rm` & `slice`: **`O(log N)`** | **`O(1)`** |

---

## 2. Choosing the Right Collection Type

### Maps: `hash_map` vs. `counted_map` vs. `sorted_map`
- **Use `%{}` / `Xitdb.hash_map/1`** for entity attributes (`%{"username" => "alice", "age" => 30}`) and general key-value lookups where you don't need `Enum.count/1` or sorted key iteration.
- **Use `Xitdb.counted_map/1`** for entity tables (`"departments"`, `"tenants"`) when you frequently call `Enum.count(db["tenants"])` and want `O(1)` cardinality without B+Tree key sorting overhead.
- **Use `Xitdb.sorted_map/1`** for lexicographically ordered directories, time-series keys (`"2026-11-03T22:00:00Z"`), leaderboards, and secondary indexes where you need ordered iteration, `Enum.slice/2` pagination by rank, or Datalog `starts_with` / `>=` B+Tree range pushdowns.

### Lists: `array_list` vs. `linked_list`
- **Use `[]` / `Xitdb.array_list/1`** for append-only logs, fixed-order arrays, or random index reads (`roles[0]`). `Array_List` supports fast tail `append` and tail truncation (`slice list, 0, new_size`), but does **not** allow middle-of-list insertions or element deletion.
- **Use `Xitdb.linked_list/1`** for task queues, ordered feeds, or editable lists where items are inserted at index `0` (`insert todos[[0]], "urgent"`), removed by index (`rm todos[[2]]`), or sliced at arbitrary offsets (`slice todos, 10..19`) in **`O(log N)`** time without re-indexing subsequent elements.

### Sets: `hash_set` vs. `counted_set` vs. `sorted_set`
- **Use `Xitdb.counted_set/1` (or `MapSet.new/1`)** for user roles, permissions, or feature flags when you need `O(1)` `Enum.count/1` and `O(1)` `Enum.member?/2`.
- **Use `Xitdb.sorted_set/1`** when set members should always iterate and slice in deterministic alphabetical order (e.g., tags or badges).

```elixir
use Xitdb.DSL

{:ok, db} = Xitdb.open(backend: :memory)

{:ok, db} =
  Xitdb.transact(db, %{
    "departments" => Xitdb.counted_map(%{"eng" => %{"budget" => 500_000}}),
    "catalog" => Xitdb.sorted_map(%{"sku-001" => "Keyboard", "sku-002" => "Monitor"}),
    "job_queue" => Xitdb.linked_list(["job-a", "job-b", "job-c"]),
    "tags" => Xitdb.sorted_set(["rust", "elixir", "odin"])
  })

Enum.to_list(db["tags"])
# => ["elixir", "odin", "rust"] (lexicographically ordered!)
```

---

## 3. Secondary B+Tree Indexes (`index_on`)

`xitdb` can automatically maintain secondary `Sorted_Map` (`$`) indexes whenever records in a source map are inserted, updated, or deleted:

1. **Automatic population:** Writing `users[id].username = "alice"` automatically writes `"alice" -> id` into the target `Sorted_Map` index (`"username->id"`).
2. **Automatic stale-key eviction:** Updating `users[id].username` from `"alice"` to `"alicia"`—or deleting `users[id]` via `rm users[id]`—automatically evicts the old `"alice"` key from `"username->id"` in the same atomic transaction.

You can declare `index_on` rules either inside `Xitdb.DSL.tx` or via `index_rules:` in `Xitdb.transact/3`:

```elixir
use Xitdb.DSL

{:ok, db} =
  tx db, doc: "seed indexed users" do
    index_on :users, :username, "username->id"
    index_on :users, :email, "email->id"

    put users["u101"], %{"username" => "dan", "email" => "dan@acme.io"}
    put users["u102"], %{"username" => "daria", "email" => "daria@acme.io"}
  end

# Point lookup via the Sorted_Map secondary index:
user_id = db["username->id"]["dan"] # => "u101"

# Or in a single NIF hop with path/1:
Xitdb.select!(db, path(sorted("email->id")["daria@acme.io"])) # => "u102"
```

---

## 4. Scalar Types & Custom 2-Byte Format Tags (`{:tagged, tag, payload}`)

`xitdb` natively encodes scalars into 9-byte `Slot`s (`Short_Bytes` inline up to 8 bytes, `Bytes`, `Uint`, `Int`, `Float`):

| Elixir Value | `xitdb` Storage Representation | Round-Trip Value |
| :--- | :--- | :--- |
| `"hello"` | `Tag.Short_Bytes` (`<= 8` bytes inline in `Slot`) or `Tag.Bytes` | `"hello"` |
| `42` (non-negative `integer()`) | `Tag.Uint` (`u64`) | `42` |
| `-42` (negative `integer()`) | `Tag.Int` (`i64`) | `-42` |
| `3.14` (`float()`) | `Tag.Float` (`f64`) | `3.14` |
| `true` / `false` | `Tag.Short_Bytes` with 2-byte format tag `"bl"` (`"1"` / `"0"`) | `true` / `false` |
| `{:tagged, <<a, b>>, binary}` | `Tag.Bytes` / `Tag.Short_Bytes` with custom 2-byte `format_tag` | `{:tagged, <<a, b>>, binary}` |

Custom 2-byte format tags let you store domain-typed scalars (such as UUIDs, decimals, timestamps, or CBOR/Protobuf payloads) without wrapper maps:

```elixir
use Xitdb.DSL

{:ok, db} =
  tx db do
    put orders["ord-1"].total, {:tagged, "dc", "199.95"}
    put orders["ord-1"].created_at, {:tagged, "dt", "2026-11-03T22:00:00Z"}
  end

db["orders"]["ord-1"]["total"]
# => {:tagged, "dc", "199.95"}
```
