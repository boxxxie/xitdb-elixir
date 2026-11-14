# Declarative Transaction Block DSL (`tx/2`, `tx/3`, `tx!/2`, `tx!/3`)

While `Xitdb.transact/3` supports standard Elixir [`Access` mutations](access-and-enumerable.md) (`put_in/3`, `update_in/3`, `pop_in/2`) on a root `%Xitdb.Cursor{}`, the `Access` protocol has three inherent limitations for deep or complex mutations:

1. **Intermediate NIF reads:** `put_in(root["users"][id]["profile"]["city"], "NYC")` invokes `Access.get_and_update/3` at every step, crossing the NIF boundary on each hop.
2. **Missing intermediate paths:** If `root["users"][id]` does not exist yet, `Access.get_and_update/3` passes `nil` to the next step and raises unless intermediate maps are initialized first.
3. **No syntax for native list/tree/metadata operations:** `Access` cannot express `xitdb`'s native `O(log N)` list `append`, `insert`, `slice`, `O(1)` zero-copy subtree `fork`, secondary index registration (`index_on`), or commit metadata (`meta`, `instant`, `savepoint`).

`Xitdb.DSL.tx/2,3` and `Xitdb.DSL.tx!/2,3` solve all three problems by compiling path expressions directly into a single atomic NIF transaction batch.

---

## 1. Basic Usage

```elixir
use Xitdb.DSL

{:ok, db} =
  tx db, doc: "promote alice and initialize bob", instant: 1_700_000_060_000 do
    # 1. Attach custom commit metadata to __tx
    meta :author, "ops-bot"
    meta :trace_id, "req-991"

    # 2. Auto-vivifies missing intermediate maps with 0 NIF reads
    put users["bob"].profile.city, "Tokyo"
    put users["alice"].role, "admin"

    # 3. 1-arity set member additions & removals
    put users["alice"].flags.set_member("staff")
    rm users["alice"].flags.set_member("onboarding")

    # 4. Native list, slice, zero-copy fork, and removal ops
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

You can also call `Xitdb.tx/2,3` or `Xitdb.tx!/2,3` directly after `require Xitdb` without importing `Xitdb.DSL`.

---

## 2. Transaction Operations Reference

All path arguments inside `tx` are compiled using [`Xitdb.DSL.path/1`](path-and-pull-dsl.md), supporting runtime variable interpolation (`users[id]`) and typed collection modifiers (`counted(:users)[id]`, `sorted(:catalog)[sku]`, `todos[[0]]`).

### `put path, value` (and 1-Arity Set Member `put`)
Writes a scalar, custom tagged value (`{:tagged, "dc", "19.99"}`), nested Elixir map/list, or typed `%Xitdb.Collection{}` (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, etc.) at `path`. Missing intermediate collections are created automatically with zero NIF reads.

When adding a member to a `Hash_Set`, `Counted_Hash_Set`, or `Sorted_Set`, use the 1-arity `put` form with a set modifier (symmetrical with `rm`):

```elixir
put users[id].profile, %{"city" => "Montreal", "tier" => "pro"}
put users[id].todos, Xitdb.linked_list(["task-1", "task-2"])

# 1-arity set member insertion:
put users[id].flags.set_member("verified")
put users[id].perms.counted_set_member("deploy")
put users[id].badges.sorted_set_member("elixir")
```

### `update path, fun` and `update path, default, fun`
Reads the current value at `path` (preferring any value already staged by an earlier `put`/`update`/`rm` in the same `tx` block, or falling back to `base_moment` in the database), passes it to `fun`, and stages a `put` with the returned value.

If you pass a `default` argument (`update path, default, fun`), `default` is substituted whenever the current value at `path` is `nil`:

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
Appends `value` to the end of an `Array_List` or `Linked_Array_List` at `list_path`.

```elixir
append users[id].audit_log, "logged_in"
```

### `insert list_path[[idx]], value` (or `insert list_path, idx, value`)
Inserts `value` at `idx` in a `Linked_Array_List` in `O(log N)` time, shifting subsequent elements right without copying them.

```elixir
insert users[id].todos[[0]], "urgent-task"
# Equivalent 3-argument form:
insert users[id].todos, 0, "urgent-task"
```

### `slice list_path, first..last` (or `slice list_path, offset, size`)
Slices a `Linked_Array_List` (arbitrary `offset` and `size` in `O(log N)`) or truncates an `Array_List` to `size`.

```elixir
slice users[id].todos, 0..9
# Equivalent offset/size form:
slice users[id].todos, 0, 10
```

### `fork from_path, to_path`
Clones the subtree at `from_path` to `to_path` in **`O(1)` zero-copy time** by copying its 9-byte `Slot` pointer and freezing the transaction watermark so subsequent mutations in the same `tx` block trigger copy-on-write on either branch.

```elixir
fork users[id], backups[id]
```

### `index_on source_map, field_key, index_map` (and `tx_for` / `tx_for!`)
Registers a secondary `Sorted_Map` B+Tree index rule for the transaction, automatically indexing `source_map[record_id][field_key] -> record_id` into `index_map` and evicting stale entries when indexed fields are updated or removed.

```elixir
index_on :users, :username, "username->id"
```

When using [`Xitdb.Ash.Resource`](ash-and-spark.md) (or schema modules defining `__xitdb_indexes__/0`), prefer `tx_for/3,4` and `tx_for!/3,4` over manual `index_on` declarations—`tx_for` automatically injects all `index_on` rules configured on the given resource(s) at compile time:

```elixir
{:ok, db} =
  tx_for db, [Organization, OrganizationProfile], doc: "upsert indexed org" do
    put organizations[id].domain, "northleafcapital.com"
  end
```

### `init_col path, kind` / `reset_col path, kind`
Initializes an empty collection at `path` (or resets an existing collection) with explicit kind (`:hash_map`, `:counted_hash_map`, `:sorted_map`, `:array_list`, `:linked_array_list`, `:hash_set`, `:counted_hash_set`, `:sorted_set`).

```elixir
init_col org.departments, :counted_hash_map
reset_col cache.sessions, :hash_map
```

### `meta key, value` & `instant epoch_ms`
Writes custom commit metadata into the moment's `__tx` map (`db["__tx"][key]`) and sets `__tx.tx_instant` (returned by `Xitdb.history_of/2` as `instant`):

```elixir
instant System.system_time(:millisecond)
meta :author, "alice"
meta :request_id, "req-123"
```

### `savepoint()`
Explicitly freezes all nodes written so far in the current transaction (`database_freeze`) so subsequent mutations in the same `tx` block copy-on-write rather than mutating in-place. (`fork` calls `savepoint` automatically.)

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

## 3. Advanced Patterns & Cookbook Recipes

### Recipe 1: Loops, Comprehensions & Conditionals Inside `tx`
Because `tx` rewrites transaction operations across the full Elixir AST while leaving normal Elixir expressions untouched, you can use `for` comprehensions, `Enum.each/2`, `if/else`, and `case` inside a `tx` block to stage batch imports in a single atomic commit:

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
When you call `put` with a scalar or nested map and then call `update` on a child path in the same `tx` block, `tx` resolves the staged value directly in memory without making an extra NIF call:

```elixir
{:ok, db} =
  tx db do
    # Stages a nested map for "carol":
    put users["carol"], %{"login_count" => 10, "role" => "member"}

    # Reads 10 from the in-memory staged map and updates it to 15:
    update users["carol"].login_count, &(&1 + 5)

    # Conditional guard using the updated value:
    if update(users["carol"].login_count, & &1) > 100 do
      abort :rate_limit_exceeded
    end
  end
```

---

## 4. Transaction Options (`tx/3` and `tx!/3`)

Both `tx/3` and `tx!/3` (as well as `Xitdb.transact/3`) accept keyword options:

- `:doc` (`String.t()`) — Commit message stored in `__tx.doc` (inspected by `Xitdb.history_of/2`).
- `:instant` (`integer()`) — Epoch timestamp in milliseconds stored in `__tx.tx_instant` (inspected by `Xitdb.history_of/2`).
- `:meta` (`map() | keyword()`) — Custom key-value metadata stored in `__tx.<key>`.
- `:base_moment` (`integer()`, default `-1`) — Historical moment index to branch from.
- `:index_rules` (`[{:index_on, source_map, field, index_map}]`, default `[]`) — Secondary B+Tree index rules applied during map or callback transactions.

---

## 5. Concurrency Model: Lock-Free Reads & Single-Writer Serialization

- **Concurrent readers never block each other:** `%Xitdb{}` and `%Xitdb.Cursor{}` handles synchronize NIF slot access with an internal `ErlNifRWLock` and read immutable historical moments, so any number of BEAM processes can query or traverse cursors concurrently.
- **Serialize read-modify-write transactions through one writer:** While `nif_transact` atomically commits each batch under a write lock, Elixir-side read-modify-write steps (`update` inside `tx` and `Xitdb.transact/3` 1-arity callbacks) read the current moment *before* entering `nif_transact`. If two BEAM processes run read-modify-write transactions concurrently against the same `%Xitdb{}` reference, both can read moment `N` and overwrite each other's updates (TOCTOU).

If you are using Ash, supervise `Xitdb.Ash.Store` (see [`docs/ash-and-spark.md`](ash-and-spark.md)). For standalone non-Ash applications, own writes in a single `GenServer` and publish the `%Xitdb{}` handle in `:persistent_term` so readers bypass the `GenServer` mailbox completely:

```elixir
defmodule MyApp.Store do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # Zero-bottleneck concurrent reads (never touches GenServer mailbox)
  def handle, do: :persistent_term.get({__MODULE__, :db})
  def db, do: Xitdb.db(handle())

  # Serialized atomic writes
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
