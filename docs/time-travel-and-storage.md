# Time-Travel, Structural Diffs, Lineage & Storage Lifecycle

Because `xitdb` is an **immutable, append-only database** where every transaction appends a new root `Slot` to the top-level history `Array_List`, every committed moment is preserved with persistent structural sharing.

---

## 1. Storage Backends & Database Lifecycle

`Xitdb.open/1` supports three storage backends and two cryptographic HAMT hash algorithms (`:sha1` default, or `:sha256`):

```elixir
# 1. In-memory backend (ideal for unit tests, ephemeral caches, and sandboxed state)
{:ok, mem_db} = Xitdb.open(backend: :memory)

# 2. Buffered file backend (recommended for production disk persistence)
{:ok, disk_db} =
  Xitdb.open(
    backend: :buffered_file,
    path: "/var/lib/myapp/store.xit",
    hash: :sha256
  )

# 3. Inspect moment count and file size in bytes
{:ok, %{moment_count: 1, file_size: 4096}} = Xitdb.info(disk_db)

# 4. Flush buffered OS writes and close
:ok = Xitdb.sync(disk_db)
:ok = Xitdb.close(disk_db)
```

---

## 2. Instant Time-Travel Snapshots (`Xitdb.as_of/2`)

Pinning a snapshot to any historical moment index (`0..moment_count - 1`, or negative offsets from the latest commit like `-1`, `-2`) is an **$O(1)$ operation** that returns a `%Xitdb.Cursor{}` bound to that moment:

```elixir
use Xitdb.DSL

{:ok, db} = Xitdb.open(backend: :memory)
{:ok, db} = tx db, doc: "v0 seed" do put config.version, "1.0.0" end
{:ok, db} = tx db, doc: "v1 bump" do put config.version, "2.0.0" end
{:ok, db} = tx db, doc: "v2 bump" do put config.version, "3.0.0" end

# Pin historical cursors by positive index or negative relative offset:
v0 = Xitdb.as_of(db, 0)
prev = Xitdb.as_of(db, -2)
latest = Xitdb.db(db)

v0["config"]["version"]     # => "1.0.0"
prev["config"]["version"]   # => "2.0.0"
latest["config"]["version"] # => "3.0.0"
```

Historical cursors work everywhere a latest cursor works:
- `Access` navigation (`v0["config"]["version"]`)
- `Enumerable` & `Stream` (`Enum.to_list(v0["config"])`)
- `Xitdb.select/2` (`Xitdb.select!(v0, path(config.version))` or `Xitdb.select!(db, path(at_moment(0, config.version)))`)
- `Xitdb.pull/2` (`Xitdb.pull!(v0, [:config])`)
- `Xitdb.query/3` (`Xitdb.query!(v0, ~q"...")` or `query!(db, moment: 0) do ... end`)

---

## 3. Branching from Historical Moments (`base_moment`) & Zero-Copy `fork`

### Branching a Transaction from a Past Moment (`base_moment`)

By default, transactions build on top of the latest moment (`base_moment: -1`). Passing `base_moment: moment_idx` branches the new transaction off an earlier historical snapshot—making it trivial to revert state or explore speculative branches:

```elixir
# Roll back / branch a new commit directly from moment 0:
{:ok, db} =
  tx db, base_moment: 0, doc: "hotfix on top of v0" do
    put config.version, "1.0.1"
  end

db["config"]["version"] # => "1.0.1"
```

### Zero-Copy Subtree Cloning (`fork`)

Inside a transaction, `fork from_path, to_path` (or `Xitdb.fork/3`) clones any subtree—even a collection with millions of entries—in **$O(1)$ time and 9 bytes** by copying its `Slot` pointer and freezing the transaction watermark (`savepoint`) so subsequent edits to either path trigger copy-on-write isolation:

```elixir
{:ok, db} =
  tx db, doc: "snapshot production tenant into staging" do
    fork tenants["acme_prod"], tenants["acme_staging"]
    put tenants["acme_staging"].env, "staging"
  end
```

---

## 4. Structural Diffs (`Xitdb.diff_moments/3`)

Because unchanged subtrees share identical 9-byte `Slot` pointers (`tag` + byte `offset`) across moments, `Xitdb.diff_moments(db, moment_a, moment_b)` skips identical subtrees in **$O(1)$ time** without traversing their children, computing the exact delta in $O(\Delta \text{ changed paths})$:

```elixir
{:ok, changes} = Xitdb.diff_moments(db, 0, 1)
# => [
#   %{
#     op: :put,
#     path: ".config.version",
#     old_value: "1.0.0",
#     new_value: "2.0.0"
#   }
# ]
```

---

## 5. Attribute Lineage & Audit History (`Xitdb.history_of/2`)

`Xitdb.history_of(db, selector)` walks the moment history and returns every moment where the `Slot` at `selector` changed, along with the commit's `:doc` message and `:instant` timestamp (`__tx.doc` and `__tx.tx_instant`):

```elixir
use Xitdb.DSL

{:ok, db} = Xitdb.open(backend: :memory)

{:ok, db} =
  tx db, doc: "create alice", instant: 1_700_000_000_000 do
    put users["alice"].role, "member"
  end

{:ok, db} =
  tx db, doc: "unrelated config change", instant: 1_700_000_030_000 do
    put config.maintenance, false
  end

{:ok, db} =
  tx db, doc: "promote alice to admin", instant: 1_700_000_060_000 do
    put users["alice"].role, "admin"
  end

# Moment 1 is automatically skipped in O(1) because `.users.alice.role` did not change!
{:ok, lineage} = Xitdb.history_of(db, path(users["alice"].role))
# => [
#   %{moment_index: 0, value: "member", doc: "create alice", instant: 1_700_000_000_000},
#   %{moment_index: 2, value: "admin", doc: "promote alice to admin", instant: 1_700_000_060_000}
# ]
```

---

## 6. Database Compaction (`Xitdb.compact/2`)

Over time, append-only workloads accumulate historical moments and unreachable intermediate nodes. `Xitdb.compact/2` copies only the reachable nodes of the **latest moment** into a fresh, deduplicated database (either in-memory if `:path` is omitted, or to a new file path):

```elixir
{:ok, compacted_db} = Xitdb.compact(disk_db, path: "/var/lib/myapp/store.compacted.xit")

Xitdb.moment_count(compacted_db)
# => 1 (latest state preserved, historical garbage reclaimed)
```
