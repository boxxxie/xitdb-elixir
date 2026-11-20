# Time-Travel, Diffs & Storage

In `Xitdb`, every committed transaction creates a numbered, immutable **moment** (`0`, `1`, `2`, ...) using persistent structural sharing. Updating a single user record only writes the changed path on disk while sharing the rest of the database tree with previous moments.

That design gives you time-travel reads, structural diffs, field audit trails, speculative history branching, and instant zero-copy subtree cloning out of the box.

---

## 1. Reading Historical Snapshots (`Xitdb.as_of/2`)

Pin a snapshot to any moment index (`0..moment_count - 1`, or negative offsets from the latest commit like `-1` and `-2`) with `Xitdb.as_of/2`:

```elixir
use Xitdb.DSL

{:ok, db} = Xitdb.open(backend: :memory)
{:ok, db} = tx db, doc: "v0 seed" do put config.version, "1.0.0" end
{:ok, db} = tx db, doc: "v1 bump" do put config.version, "2.0.0" end
{:ok, db} = tx db, doc: "v2 bump" do put config.version, "3.0.0" end

# Pin historical cursors by positive index or negative relative offset
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

## 2. Comparing Moments (`Xitdb.diff_moments/3`)

Because unchanged subtrees share identical pointers across commits, `Xitdb.diff_moments/3` skips unchanged branches in `O(1)` and returns only the paths that differ between two moments:

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

## 3. Field Audit History (`Xitdb.history_of/2`)

`Xitdb.history_of(db, selector)` walks the database's moment timeline and returns every moment where the value at `selector` changed—automatically skipping moments that didn't touch that path—along with the commit `:doc` message and `:instant` timestamp:

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

# Moment 1 is skipped automatically because users["alice"].role did not change
{:ok, lineage} = Xitdb.history_of(db, path(users["alice"].role))
# => [
#   %{moment_index: 0, value: "member", doc: "create alice", instant: 1_700_000_000_000},
#   %{moment_index: 2, value: "admin", doc: "promote alice to admin", instant: 1_700_000_060_000}
# ]
```

---

## 4. Branching History (`base_moment`) & Zero-Copy Cloning (`fork`)

### Branching a Transaction from a Past Moment (`base_moment`)

By default, new transactions build on top of the latest moment (`base_moment: -1`). Passing `base_moment: moment_idx` branches the new transaction from an earlier snapshot—making it simple to revert a mistake or explore an alternative state:

```elixir
# Branch a new commit directly on top of moment 0
{:ok, db} =
  tx db, base_moment: 0, doc: "hotfix on top of v0" do
    put config.version, "1.0.1"
  end

db["config"]["version"] # => "1.0.1"
```

### Zero-Copy Subtree Cloning (`fork`)

Inside a transaction, `fork from_path, to_path` (or `Xitdb.fork/3`) clones any subtree—even a collection with millions of entries—in `O(1)` time by copying its root reference and isolating future edits via copy-on-write:

```elixir
{:ok, db} =
  tx db, doc: "snapshot production tenant into staging" do
    fork tenants["acme_prod"], tenants["acme_staging"]
    put tenants["acme_staging"].env, "staging"
  end
```

---

## 5. Storage Backends & Lifecycle

`Xitdb.open/1` supports three storage backends and two hash algorithms (`:sha1` default, or `:sha256`):

```elixir
# 1. In-memory backend (ideal for unit tests, ephemeral caches, and sandboxes)
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

# 4. Flush buffered writes and close
:ok = Xitdb.sync(disk_db)
:ok = Xitdb.close(disk_db)
```

### Choosing a Backend & Hash Algorithm

- **`:memory`** — Backed by an in-memory buffer with zero disk I/O; ideal for `async: true` ExUnit tests, ephemeral caches, and scratchpad projections.
- **`:buffered_file`** — Buffers writes in user space and flushes cleanly on commit or `Xitdb.sync/1`; recommended for production disk workloads.
- **`:file`** — Issues unbuffered OS file reads and writes directly against the file descriptor; useful for small CLI utilities or memory-constrained environments with infrequent writes.
- **`:sha1` vs. `:sha256`** — Selects the hash algorithm used for HAMT map/set keys (`:sha1` by default for compact keys; `:sha256` when policy requires SHA-2). Always reopen an existing `.xit` file with the same `:hash` setting it was created with.

### Crash Safety Without a WAL

Transactions commit by appending a checksummed trailer (`CRC-64/XZ`) and updating the file header—no separate write-ahead log (WAL) file is needed. If a process crashes mid-write, incomplete trailing bytes are ignored when reopening the file and truncated automatically on the next commit.

---

## 6. Reclaiming Space with Compaction (`Xitdb.compact/2`)

Because commits are append-only, write-heavy databases accumulate older moments over time. `Xitdb.compact/2` copies only the reachable data from the **latest moment** into a fresh, deduplicated store (in `:memory` if `:path` is omitted, or to a new `.xit` file):

```elixir
{:ok, compacted_db} = Xitdb.compact(disk_db, path: "/var/lib/myapp/store.compacted.xit")

Xitdb.moment_count(compacted_db)
# => 1 (latest state preserved, historical data reclaimed)
```

`Xitdb.compact/2` copies compressed `format_tag` payloads verbatim without re-inflating them and garbage-collects unreachable entries under `__blobs`, `__dicts`, and `__col_pages` that are no longer referenced by the latest moment.

---

## 7. Value Compression, Shared Dictionaries & Columnar Chunks

For repetitive large binaries (such as HTML email bodies, headers, and template dispatches), Xitdb supports transparent compression layered onto `format_tag` slots:

### Transparent Value Codecs (`Xitdb.Compression`)

| Tag | Mechanism | Storage / Behavior |
| :--- | :--- | :--- |
| `"cz"` | `:zlib` deflate | Inline compressed payload with `min_bytes` (`128`) / `min_savings` (`16`) shrink guard |
| `"zs"` | `:zstd` (OTP 28+) | Inline zstd frame with strict `max_decompressed_bytes` (`64 MB`) safety cap |
| `"zd"` | Shared dictionary | Dictionary-assisted compression referencing `.__dicts.<name>` (`Xitdb.Compression.Dictionary`) |
| `"bp"` | Interned blob | Content-addressed 32-byte SHA-256 pointer into `.__blobs.<sha256>` (deduplicated across commits) |
| `"pg"` | Columnar pointer | `O(1)` random-access pointer into an immutable `"XCP1"` page in `.__col_pages` |

```elixir
# Train and persist an immutable shared dictionary from representative HTML samples
{:ok, db, _dict_bytes} = Xitdb.Compression.Dictionary.train_and_put(db, :email_html, sample_bodies)

# Write transparently compressed / dictionary-assisted / interned values
db =
  Xitdb.transact!(db, %{
    "emails" => %{
      "e1" => {:compressed, html_body, dictionary: :email_html},
      "e2" => {:compressed, legal_pdf, intern: true, codec: :zstd},
      "e3" => {:compressed, draft_body, codec: :zlib}
    }
  })

# Or auto-compress all eligible binaries >= min_bytes in a transaction
db = Xitdb.transact!(db, bulk_map, compress: [codec: :zstd, min_bytes: 128])

# Reads, select, pull, materialize, diff_moments, history_of, and Datalog decode transparently:
db["emails"]["e1"]                                      # => plaintext HTML binary
Xitdb.select!(db, ".emails.e1")                         # => plaintext HTML binary
Xitdb.select!(db, ".emails.e1", raw_tagged: true)       # => {:tagged, "zd", <<...>>}
{:ok, changes} = Xitdb.diff_moments(db, 0, 1)           # => hides __blobs/__dicts/__col_pages unless include_internal: true
```

### Parquet-Style Row-Group Columnar Pages (`Xitdb.Columnar`)

Use `Xitdb.Columnar.put_rows/4` when ingesting high-volume row collections so repetitive columns are batched across row groups (`row_group_size: 128`) into immutable `"XCP1"` pages (`:plain_block`, `:dict_rle`, or `:dict_block`):

```elixir
db =
  Xitdb.Columnar.put_rows!(db, "activities", rows,
    columns: [
      {:body, encoding: :dict_block, dictionary: :email_html, codec: :zstd},
      {:header_properties, encoding: :dict_rle, codec: :zstd}
    ],
    row_group_size: 128
  )

# Projections omitting columnar fields perform 0 page reads and 0 decompressions:
meta = Xitdb.pull!(db["activities"]["10"], "{id, title}")

# Single-row reads decompress at most one row-group page and cache it in bounded ETS (`:xitdb_page_cache`):
body = db["activities"]["10"]["body"]
```
