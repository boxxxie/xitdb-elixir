# Collections & Secondary Indexes

You don't have to pick storage types up front—plain Elixir data structures work automatically whenever you pass them to `Xitdb.transact/3` or `put` inside `tx`:

- Plain maps (`%{}`) are stored as `:hash_map`.
- Plain lists (`[]`) are stored as `:array_list`.
- `%MapSet{}` values are stored as `:counted_hash_set`.

When a collection needs **instant `Enum.count/1`**, **sorted key iteration and range queries**, or **middle-of-list insertions and removals**, wrap your initial value in one of `Xitdb`'s explicit constructors (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, etc.) or initialize it with `init_col` inside `tx`.

---

## 1. Choosing a Collection by Use Case

### Maps: `hash_map` vs. `counted_map` vs. `sorted_map`
- **`%{}` / `Xitdb.hash_map/1`:** Default choice for entity attributes (`%{"username" => "alice", "age" => 30}`) and general key-value lookups where you don't need `Enum.count/1` or sorted iteration.
- **`Xitdb.counted_map/1`:** Best for entity tables (`"departments"`, `"tenants"`) when you frequently call `Enum.count/1` and want `O(1)` cardinality without maintaining key sort order.
- **`Xitdb.sorted_map/1`:** Best for lexicographically ordered directories, ISO-8601 time-series keys (`"2026-11-03T22:00:00Z"`), leaderboards, and secondary indexes where you need ordered `Enum` iteration, `Enum.slice/2` pagination by rank, or Datalog `starts_with` / `>=` prefix and range queries.

### Lists: `array_list` vs. `linked_list`
- **`[]` / `Xitdb.array_list/1`:** Best for append-only logs, fixed-order arrays, and fast random index lookups (`roles[0]`). Supports fast tail `append` and tail truncation (`slice list, 0, size`), but does **not** support middle-of-list `insert` or element `rm`.
- **`Xitdb.linked_list/1`:** Best for task queues, priority feeds, and editable ordered lists where items are inserted at arbitrary positions (`insert todos[[0]], "urgent"`), deleted by index (`rm todos[[2]]`), or sliced at arbitrary offsets (`slice todos, 10..19`) in `O(log N)` time.

### Sets: `counted_set` vs. `sorted_set` vs. `hash_set`
- **`MapSet.new/1` / `Xitdb.counted_set/1`:** Best for roles, permissions, or feature flags when you need `O(1)` `Enum.count/1` and fast `Enum.member?/2` checks.
- **`Xitdb.sorted_set/1`:** Best when unique members should always iterate and slice in deterministic alphabetical order (e.g., tags or badges).
- **`Xitdb.hash_set/1`:** Compact uncounted membership set when you only need `Enum.member?/2` checks.

```elixir
{:ok, db} = Xitdb.open(backend: :memory)

{:ok, db} =
  Xitdb.transact(db, %{
    "departments" => Xitdb.counted_map(%{"eng" => %{"budget" => 500_000}}),
    "catalog" => Xitdb.sorted_map(%{"sku-001" => "Keyboard", "sku-002" => "Monitor"}),
    "job_queue" => Xitdb.linked_list(["job-a", "job-b", "job-c"]),
    "tags" => Xitdb.sorted_set(["rust", "elixir", "odin"])
  })

Enum.to_list(db["tags"])
# => ["elixir", "odin", "rust"]
```

---

## 2. Collection Reference Table

`xitdb` provides 8 persistent, structurally shared collection types:

| Collection Kind | Constructor | Selector Sigil | Ordering | `Enum.count/1` | Supported Edits |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `:hash_map` | `Xitdb.hash_map(map)` *(or `%{}`)* | `.key` | Hash order | `O(N)` scan | `put`, `rm` (`O(log_16 N)`) |
| `:counted_hash_map` | `Xitdb.counted_map(map)` | `#key` | Hash order | **`O(1)`** | `put`, `rm` (`O(log_16 N)`) |
| `:sorted_map` | `Xitdb.sorted_map(map)` | `$key` | Lexicographical | **`O(1)`** | `put`, `rm`, `slice` (`O(log N)`) |
| `:array_list` | `Xitdb.array_list(list)` *(or `[]`)* | `[idx]` | Index order | **`O(1)`** | `append`, tail `slice` (`O(log_16 N)`) |
| `:linked_array_list` | `Xitdb.linked_list(list)` | `[[idx]]` | Index order | **`O(1)`** | `append`, `insert`, `rm`, `slice` (`O(log N)`) |
| `:hash_set` | `Xitdb.hash_set(enum)` | `%member` | Hash order | `O(N)` scan | add/remove member (`O(log_16 N)`) |
| `:counted_hash_set` | `Xitdb.counted_set(enum)` *(or `MapSet`)* | `#%member` | Hash order | **`O(1)`** | add/remove member (`O(log_16 N)`) |
| `:sorted_set` | `Xitdb.sorted_set(enum)` | `^member` | Lexicographical | **`O(1)`** | add/remove/slice member (`O(log N)`) |

---

## 3. Automatic Secondary Indexes (`index_on`)

`Xitdb` can automatically maintain secondary `:sorted_map` indexes whenever records in a source map are inserted, updated, or deleted:

1. **Automatic population:** Writing `users[id].username = "alice"` automatically writes `"alice" => id` into `"username->id"`.
2. **Automatic stale-key eviction:** Updating `users[id].username` from `"alice"` to `"alicia"`—or deleting `users[id]` with `rm users[id]`—removes the stale `"alice"` key from `"username->id"` in the same atomic transaction.

Declare `index_on` rules inside `tx` (see [Transaction DSL](transaction-dsl.md)) or via `index_rules:` in `Xitdb.transact/3`:

```elixir
use Xitdb.DSL

{:ok, db} =
  tx db, doc: "seed indexed users" do
    index_on :users, :username, "username->id"
    index_on :users, :email, "email->id"

    put users["u101"], %{"username" => "dan", "email" => "dan@acme.io"}
    put users["u102"], %{"username" => "daria", "email" => "daria@acme.io"}
  end

# Point lookup via the Sorted_Map secondary index
db["username->id"]["dan"]
# => "u101"

# Or in a single call with path/1
Xitdb.select!(db, path(sorted("email->id")["daria@acme.io"]))
# => "u102"
```

> If you are using Ash Framework or modules defining `__xitdb_indexes__/0`, `tx_for` / `tx_for!` automatically prepends all declared `index_on` rules at compile time so indexes never drift. See [Ash Framework & Full-Text Search](ash-and-spark.md).

---

## 4. Scalar Types & Custom Format Tags (`{:tagged, tag, payload}`)

`Xitdb` stores standard Elixir scalars directly alongside custom 2-byte tagged binaries (`{:tagged, <<a, b>>, payload}`):

| Elixir Value | Round-Trip Value | Notes |
| :--- | :--- | :--- |
| `"hello"` | `"hello"` | Strings up to 8 bytes are inlined directly in the 9-byte slot |
| `42` (`>= 0` integer) | `42` | Stored as `u64` |
| `-42` (`< 0` integer) | `-42` | Stored as `i64` |
| `3.14` (`float()`) | `3.14` | Stored as `f64` |
| `true` / `false` | `true` / `false` | Stored with built-in `"bl"` format tag |
| `{:tagged, <<a, b>>, binary}` | `{:tagged, <<a, b>>, binary}` | Custom 2-byte format tag for domain scalars |

Custom 2-byte format tags let you preserve domain types—such as decimals, timestamps, UUIDs, or encoded payloads—without wrapping them in extra maps:

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

---

## 5. Order-Preserving Binary Range Keys (`Xitdb.Key`)

Because `:sorted_map` sorts keys lexicographically by raw unsigned bytes, store numeric range keys using `Xitdb.Key` encoders so `<, <=, ==, >=, >` order is preserved across negative, zero, positive, and `> max(i64)` values:

- `Xitdb.Key.encode_i64_be/1` / `decode_i64_be/1` — 8-byte sign-flipped big-endian signed `i64`
- `Xitdb.Key.encode_u64_be/1` / `decode_u64_be/1` — 8-byte big-endian unsigned `u64` (`0..18_446_744_073_709_551_615`)
- `Xitdb.Key.encode_f64_be/1` — 8-byte order-preserving IEEE-754 `f64` (`-0.0` normalized to `+0.0`)
- `Xitdb.Key.encode_decimal_key/1` — variable-length canonical scale-invariant `Decimal` key
- `Xitdb.Key.encode_fixed_decimal64_be/2` / `decode_fixed_decimal64_be/2` — 8-byte fixed-scale `Decimal` key (`[scale: 10_000, signed?: true]`)
- `Xitdb.Key.stream_range/2` — lazy `O(log N + K)` B+Tree range scanner over `:sorted_map` cursors via `nif_sorted_map_seek` (`:prefix`, `:min`, `:min_inclusive?`, `:max`, `:max_inclusive?`, `:page_size`)

```elixir
max_i64 = 9_223_372_036_854_775_807

{:ok, db} =
  Xitdb.transact(db, %{
    "offsets" =>
      Xitdb.sorted_map([
        {Xitdb.Key.encode_u64_be(10), "small"},
        {Xitdb.Key.encode_u64_be(max_i64 + 1), "large"}
      ])
  })

Xitdb.db(db)["offsets"]
|> Xitdb.Key.stream_range(min: Xitdb.Key.encode_u64_be(max_i64), min_inclusive?: false)
|> Enum.map(fn {k, v} -> {Xitdb.Key.decode_u64_be(k), v} end)
# => [{9_223_372_036_854_775_808, "large"}]
```

---

## 6. Automatic Struct Serialization (`Xitdb.Encoder`)

`Xitdb.Encoder` lets Elixir structs encode automatically across `Xitdb.transact/3`, `put_in/3` / `update_in/3`, `Xitdb.insert_at/4`, and `Xitdb.DSL.tx` blocks. Built-in implementations cover:

| Struct | Encoded Term |
| :--- | :--- |
| `%Decimal{}` *(when `Decimal` is loaded)* | `{:tagged, "dc", Decimal.to_string(dec, :normal)}` |
| `%Date{}` | `{:tagged, "dt", Date.to_iso8601(d)}` |
| `%Time{}` | `{:tagged, "tm", Time.to_iso8601(t)}` |
| `%DateTime{}` | `{:tagged, "ts", <<DateTime.to_unix(dt, :microsecond)::signed-big-64>>}` |
| `%NaiveDateTime{}` | `{:tagged, "nt", NaiveDateTime.to_iso8601(ndt)}` |
| `%Xitdb.Ash.Types.RangedUnit{}` | Compact `%{"b" => ..., "d" => ..., ...}` interval map |

Implement `defimpl Xitdb.Encoder, for: MyStruct` to return any writeable map, list, scalar, `{:tagged, tag, binary}`, or nested encodable struct. Unimplemented structs continue to raise `Protocol.UndefinedError` (normalized to `{:error, %Xitdb.Error{reason: :transaction_exception}}` inside transactions).
