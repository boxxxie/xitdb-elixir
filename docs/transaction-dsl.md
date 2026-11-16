# Transaction DSL

While `Xitdb.transact/3` supports [`Access` mutations](access-and-enumerable.md) (`put_in/3`, `update_in/3`, `pop_in/2`), deep or multi-step transactions often benefit from cleaner syntax and native collection operations:

1. **Automatic intermediate map creation:** Writing `put users[new_id].profile.city, "Tokyo"` creates missing parent maps automatically without checking or initializing each level first.
2. **Flat, readable multi-operation blocks:** Combine puts, updates, removals, list appends/inserts/slices, zero-copy `fork`s, secondary index rules, and commit metadata in a single `tx db do ... end` block.
3. **One atomic commit:** Every operation in the `tx` block is compiled into a single atomic commit (or rolled back cleanly on `abort`).

---

## 1. Basic Usage

```elixir
use Xitdb.DSL

{:ok, db} =
  tx db, doc: "promote alice and initialize bob", instant: 1_700_000_060_000 do
    # 1. Attach custom commit metadata to __tx
    meta :author, "ops-bot"
    meta :trace_id, "req-991"

    # 2. Auto-create missing intermediate maps and set scalars
    put users["bob"].profile.city, "Tokyo"
    put users["alice"].role, "admin"

    # 3. Set member additions & removals (1-arity form)
    put users["alice"].flags.set_member("staff")
    rm users["alice"].flags.set_member("onboarding")

    # 4. List edits, slicing, zero-copy fork, and key removal
    append users["alice"].audit_log, "promoted"
    insert users["alice"].todos[[0]], "urgent-t0"
    slice users["alice"].todos, 0..3
    fork users["alice"], backups["alice"]
    rm users["alice"].temp_token

    # 5. Read-modify-write update (with optional default value when missing)
    update users["alice"].login_count, 0, &(&1 + 1)
    update users["bob"].login_count, 0, &(&1 + 1)
  end
```

You can also call `Xitdb.tx/2,3` or `Xitdb.tx!/2,3` after `require Xitdb` without importing `Xitdb.DSL`.

---

## 2. Transaction Operations Reference

All path arguments inside `tx` follow the same rules as [`path/1`](path-and-pull-dsl.md)—supporting runtime variable interpolation (`users[id]`) and collection modifiers (`counted(:users)[id]`, `sorted(:catalog)[sku]`, `todos[[0]]`). Because Elixir syntax does not allow a leading unary dot, start bare paths with the collection name (`users[id]`, `root.users[id]`, `_.users[id]`, or `:users[id]`).

### `put path, value` (and 1-Arity Set Member `put`)
Writes a scalar, custom tagged value (`{:tagged, "dc", "19.99"}`), nested Elixir map/list, or typed `%Xitdb.Collection{}` (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, etc.) at `path`. Missing intermediate maps are created automatically.

When adding a member to a `Hash_Set`, `Counted_Hash_Set`, or `Sorted_Set`, use the 1-arity `put` form with a set modifier (matching `rm`):

```elixir
put users[id].profile, %{"city" => "Montreal", "tier" => "pro"}
put users[id].todos, Xitdb.linked_list(["task-1", "task-2"])

# 1-arity set member insertion:
put users[id].flags.set_member("verified")
put users[id].perms.counted_set_member("deploy")
put users[id].badges.sorted_set_member("elixir")
```

### `update path, fun` and `update path, default, fun`
Reads the current value at `path` (preferring any value already staged by an earlier `put`, `update`, or `rm` in the same `tx` block, or falling back to `base_moment` in the database), passes it to `fun`, and stages a `put` with the returned value.

Passing `default` (`update path, default, fun`) substitutes `default` whenever the current value at `path` is `nil`:

```elixir
# 3-arity form with default value (recommended when key may not exist yet):
update users[id].login_count, 0, &(&1 + 1)

# 2-arity form (receives nil if key does not exist):
update users[id].login_count, fn count -> (count || 0) + 1 end
```

### `rm path`
Removes a map key, linked-list element (`todos[[idx]]`), or set member (`flags.set_member("temp")`).

```elixir
rm users[id].temp_token
rm users[id].todos[[0]]
rm users[id].flags.set_member("suspended")
```

### `append list_path, value`
Appends `value` to the end of an `:array_list` or `:linked_array_list` at `list_path`.

```elixir
append users[id].audit_log, "logged_in"
```

### `insert list_path[[idx]], value` (or `insert list_path, idx, value`)
Inserts `value` at `idx` in a `:linked_array_list` in `O(log N)` time, shifting subsequent elements right without rewriting the rest of the list.

```elixir
insert users[id].todos[[0]], "urgent-task"
# Equivalent 3-argument form:
insert users[id].todos, 0, "urgent-task"
```

### `slice list_path, first..last` (or `slice list_path, offset, size`)
Slices a `:linked_array_list` (arbitrary `offset` and `size` in `O(log N)`) or truncates an `:array_list` to `size`.

```elixir
slice users[id].todos, 0..9
# Equivalent offset/size form:
slice users[id].todos, 0, 10
```

### `fork from_path, to_path`
Clones the subtree at `from_path` to `to_path` in `O(1)` time without copying its contents, automatically setting a savepoint so subsequent mutations in the same `tx` block copy-on-write cleanly onto either branch.

```elixir
fork users[id], backups[id]
```

### `index_on source_map, field_key, index_map` (and `tx_for` / `tx_for!`)
Registers a secondary `:sorted_map` index rule for the transaction, keeping `index_map[value] => record_id` synchronized across inserts, updates, and deletions.

```elixir
index_on :users, :username, "username->id"
```

When using [`Xitdb.Ash.DataLayer`](ash-and-spark.md) resources (or plain schema modules defining `__xitdb_indexes__/0`), prefer `tx_for/3,4` and `tx_for!/3,4` so declared `index_on` rules are injected automatically at compile time:

```elixir
{:ok, db} =
  tx_for db, [Organization, OrganizationProfile], doc: "upsert indexed org" do
    put organizations[id].domain, "northleafcapital.com"
  end
```

### `init_col path, kind` / `reset_col path, kind`
Initializes an empty collection at `path` (or resets an existing collection) with an explicit kind (`:hash_map`, `:counted_hash_map`, `:sorted_map`, `:array_list`, `:linked_array_list`, `:hash_set`, `:counted_hash_set`, `:sorted_set`).

```elixir
init_col org.departments, :counted_hash_map
reset_col cache.sessions, :hash_map
```

### `meta key, value` & `instant epoch_ms`
Writes custom commit metadata into the moment's `__tx` map (`db["__tx"][key]`) and sets `__tx.tx_instant` (returned by `Xitdb.history_of/2` as `:instant`):

```elixir
instant System.system_time(:millisecond)
meta :author, "alice"
meta :request_id, "req-123"
```

### `savepoint()`
Explicitly freezes all nodes written so far in the current transaction so subsequent edits copy-on-write rather than mutating in-place. (`fork` triggers a savepoint automatically.)

```elixir
savepoint()
```

### `abort reason`
Immediately aborts the `tx` block and rolls back all staged operations, returning `{:error, %Xitdb.Error{reason: reason}}` from `tx/2,3` (or raising `Xitdb.Error` from `tx!/2,3`).

```elixir
{:error, %Xitdb.Error{reason: :insufficient_funds}} =
  tx db do
    put vault.balance, 0
    abort :insufficient_funds
  end
```

---

## 3. Cookbook Recipes

### Recipe 1: Loops, Comprehensions & Conditionals Inside `tx`
Because `tx` leaves ordinary Elixir control flow intact, you can use `for` comprehensions, `Enum.each/2`, `if/else`, and `case` inside a `tx` block to commit an entire batch atomically:

```elixir
{:ok, db} =
  tx db, doc: "batch import users" do
    index_on :users, :email, "email->id"

    for %{id: id, email: email, role: role, vip?: vip?} <- incoming_batch do
      put users[id], %{"email" => email, "role" => role}

      if vip? do
        put users[id].flags.counted_set_member("vip")
      end
    end
  end
```

### Recipe 2: In-Memory Read-After-Write Staging
When you `put` a scalar or map and then `update` a nested path in the same `tx` block, `tx` resolves the staged value directly in memory:

```elixir
{:ok, db} =
  tx db do
    # Stages a nested map for "carol"
    put users["carol"], %{"login_count" => 10, "role" => "member"}

    # Reads 10 from the staged map and updates it to 15
    update users["carol"].login_count, &(&1 + 5)

    # Guard on the updated value
    if update(users["carol"].login_count, & &1) > 100 do
      abort :rate_limit_exceeded
    end
  end
```

---

## 4. Transaction Options (`tx/3` and `tx!/3`)

Both `tx/3` and `tx!/3` (as well as `Xitdb.transact/3`) accept these keyword options:

- `:doc` (`String.t()`) — Commit message stored in `__tx.doc` (returned by `Xitdb.history_of/2`).
- `:instant` (`integer()`) — Epoch timestamp in milliseconds stored in `__tx.tx_instant`.
- `:meta` (`map() | keyword()`) — Custom key-value metadata stored under `__tx.<key>`.
- `:base_moment` (`integer()`, default `-1`) — Historical moment index to branch from.
- `:index_rules` (`[{:index_on, source_map, field, index_map}]`, default `[]`) — Secondary `:sorted_map` index rules applied during map or callback transactions.

---

## 5. Concurrency: Concurrent Readers & Single-Writer Serialization

Any number of BEAM processes can read `%Xitdb{}` and `%Xitdb.Cursor{}` values concurrently without blocking each other. However, read-modify-write transactions (`update` inside `tx` and 1-arity `Xitdb.transact/3` callbacks) read the current state before committing and should be serialized through one writer process to prevent concurrent writers from overwriting each other.

- **With Ash Framework:** Use [`Xitdb.Ash.Store`](ash-and-spark.md), which handles single-writer leases and lock-free reads automatically.
- **Without Ash:** Own writes in a single `GenServer` and publish the `%Xitdb{}` handle via `:persistent_term` so readers bypass the `GenServer` mailbox completely:

```elixir
defmodule MyApp.Store do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Concurrent reads never hit the GenServer mailbox
  def handle, do: :persistent_term.get({__MODULE__, :db})
  def db, do: Xitdb.db(handle())

  # Serialized writes
  def write(fun) when is_function(fun, 1) do
    GenServer.call(__MODULE__, {:write, fun}, :infinity)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, db} = Xitdb.open(opts)
    :persistent_term.put({__MODULE__, :db}, db)
    {:ok, db}
  end

  @impl true
  def handle_call({:write, fun}, _from, db) do
    {:reply, fun.(db), db}
  end

  @impl true
  def terminate(_reason, db) do
    :persistent_term.erase({__MODULE__, :db})
    Xitdb.close(db)
  end
end
```

See [Architecture, Internals & Performance](architecture-and-internals.md) for details on how transaction staging and snapshots work internally.
