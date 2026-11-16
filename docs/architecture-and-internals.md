# Architecture, Internals & Performance

This guide covers how `Xitdb` works under the hood—its storage format, lazy 9-byte `Slot` cursor model, C-ABI Erlang NIF boundary cost model, and concurrency patterns.

If you are getting started with `Xitdb`, start with the [Overview](../README.md) or [Reading & Updating with Access & Enum](access-and-enumerable.md) first.

---

## 1. Three-Layer Architecture

```text
+----------------------------------------------------------------------------+
| Elixir Client & Ash DataLayer (lib/xitdb*.ex)                              |
|  - %Xitdb{} handle & %Xitdb.Cursor{} lazy slot wrapper                     |
|  - Access, Enumerable, Inspect protocols                                   |
|  - Xitdb.DSL (path/1, path_steps/1, tx/2,3, query/2,3), Pull & Sigils      |
|  - Xitdb.Ash.{DataLayer, Dsl, Store, Search, TestSandbox, Info, Tx}        |
+----------------------------------------------------------------------------+
| C-ABI Erlang NIF Boundary (native/nif_entry.c + native/xitdb_nif.odin)     |
|  - ErlNifResourceType + ErlNifRWLock thread safety                         |
|  - Batched transaction compilation, B+Tree seek & BM25 search pushdown     |
+----------------------------------------------------------------------------+
| Embedded Engine Submodule (native/xitdb-odin/xitdb)                        |
|  - 16-way HAMT, Radix Trie, Counted B-Tree, B+Tree, Compactor & Datalog    |
+----------------------------------------------------------------------------+
```

Every database operation runs in-process inside the BEAM via a compiled shared library (`priv/xitdb_nif.so`), combining a thin C NIF shim (`native/nif_entry.c`) with the embedded Odin implementation of `xitdb` (`native/xitdb_nif.odin` + `native/xitdb-odin/xitdb`).

---

## 2. How `xitdb` Stores Data on Disk & in Memory

`xitdb` is wire-compatible with the [`xitdb` v2 format](https://github.com/xit-vcs/xitdb) (with backward-compatible v1 support). Rather than storing rows in tables or serializing documents as opaque JSON/ETF blobs, every value is stored as a typed **9-byte `Slot`** (`1-byte tag + 8-byte value/offset`) inside an append-only tree:

- **Append-only moment history:** The root of every database is an `Array_List` of commits ("moments"). Each transaction appends a new root `Slot` that shares unchanged subtrees with prior moments via persistent structural sharing.
- **Persistent tree & trie structures:**
  - `Hash_Map`, `Counted_Hash_Map`, `Hash_Set`, `Counted_Hash_Set`: 16-way Hash Array Mapped Tries (HAMTs) keyed by SHA-1 (`:sha1`, default) or SHA-256 (`:sha256`).
  - `Array_List`: 16-way Radix Trie supporting `O(log_16 N)` indexed lookups and fast appends.
  - `Linked_Array_List`: Count-augmented B-Tree supporting `O(log N)` random access, middle insertions, removals, and offset/length slices.
  - `Sorted_Map`, `Sorted_Set`: Count-augmented B+Trees ordered lexicographically for range scans, prefix seeks, and secondary indexes.
- **Inline `Short_Bytes` optimization:** Strings and byte slices up to `8` bytes (or up to `6` bytes when accompanied by a 2-byte custom `format_tag`) are stored directly inside the 9-byte `Slot` with zero extra disk or heap indirection.
- **Crash safety without a separate WAL:** Transactions commit by writing a `Root_Trailer` verified by a `CRC-64/XZ` checksum (covering file ID, offset, root slot, and commit ID) and updating the `Root_Header`. Unfinished writes from a crash or power loss are ignored when reopening the file and automatically truncated on the next transaction.
- **Stateless positional I/O:** Reads use positional I/O (`pread` on disk files; stable virtual-memory slices via `vmem.reserve` for `:memory` databases) rather than shared seek cursors, so concurrent readers never mutate shared read positions.
- **Intra-transaction write efficiency:** While committed moments are immutable, newly allocated nodes created *within* an active transaction are updated in place until commit or an explicit `savepoint()` / `fork` freeze.

---

## 3. The `%Xitdb.Cursor{}` Model

When you navigate into a collection (`root["users"]["alice"]`, `Xitdb.db(db)`, or `Xitdb.as_of(db, moment)`), `Xitdb` does **not** deserialize the subtree onto the BEAM heap:

- **Containers stay lazy:** Navigating to a map, list, or set returns a `%Xitdb.Cursor{}` containing only the NIF database resource reference (`db_ref`), a 9-byte `Slot` coordinate (`tag`, `tag_id`, `value`), and the pinned `moment`.
- **Scalars unwrap automatically:** Navigating to a scalar (`String.t()`, `integer()`, `float()`, `boolean()`, or `{:tagged, tag, payload}`) decodes and returns the native Elixir value directly.
- **Process safety:** Because `%Xitdb.Cursor{}` holds only immutable integer coordinates and an `ErlNifResourceType` reference (synchronized inside the NIF with `ErlNifRWLock`), cursors are pure immutable Elixir values. Passing them across `Task.async_stream/3`, `GenServer`s, `:ets` tables, or Phoenix LiveView assigns requires no copying of underlying data and no manual locks.
- **Read-your-own-writes staging (`tx_mode: true`):** Inside a 1-arity `Xitdb.transact/3` callback, `%Xitdb.Cursor{}` tracks virtual write cursors (`staged_ops`, `staged_overrides`, `deleted_paths`, `staged_list_edits`, `fork_aliases`). Calling `put_in/3` stages blind writes without issuing intermediate read NIF calls, while subsequent reads inside the same callback resolve uncommitted edits against the in-memory overlay.

---

## 4. NIF Boundary Cost Model & API Selection

Every BEAM-to-Odin NIF crossing pays a predictable marshaling and `ErlNifRWLock` acquisition cost. Understanding this cost model makes it straightforward to pick the fastest `Xitdb` API for a hot path:

### Fixed Per-Call NIF Floor (`~150–250 ns`)

Each RW-locked NIF call (`enif_get_resource` + `enif_rwlock_rlock` + slot resolution + Erlang term construction) carries a fixed overhead of `~150–250 ns` compared to in-process Raw Odin execution:

- **`O(1)` header read (`Enum.count/1` on `Counted_Hash_Map`):** `~155–199 ns` in Elixir vs. `~6–8 ns` in Raw Odin.
- **Single-hop container lookups (`Array_List`, `Linked_Array_List`, `Sorted_Map`):** `~340–580 ns` in Elixir vs. `~108–391 ns` in Raw Odin (adding `~185–255 ns` of boundary overhead).

### Multi-Hop `Access` vs. `Xitdb.select/2` & `Xitdb.pull/2`

- **Chained `Access` (`root["users"][id]["name"]`):** Crosses the NIF boundary once per bracket hop (`3 × nif_slot_get_key`, `~2.28–2.33 µs` for 3 hops vs. `~0.63–0.66 µs` in Raw Odin).
- **Single-call string selector (`Xitdb.select!(db, path(users[id].name))`):** Resolves the entire selector path inside Odin in **1 NIF crossing** (`~2.04–2.08 µs` for 3 hops), keeping boundary overhead constant as path depth grows to 4+ hops.
- **Pre-tokenized `path_steps/1` (`Xitdb.select!(db, path_steps(users[id].name))`):** Compiles the path at compile time into a flat step list decoded directly in C (`decode_steps_term_buf`, `~1.99 µs`), skipping both Elixir selector string formatting and Odin selector parsing on dynamic keys.
- **Structural Pull (`Xitdb.pull!(cursor, [:username, :age, todos: 0..2, profile: [:city]])`):** Projects multiple fields and bounded list slices in **1 NIF crossing** (`~6.28–6.49 µs`) instead of issuing `K` separate `cursor[field]` calls across the boundary.

### `Enumerable` Pushdowns & Adaptive Chunking

`Enumerable.Xitdb.Cursor` delegates common operations directly to native NIF pushdowns instead of converting collections to Elixir lists:

- `Enum.count/1` -> `nif_slot_count` (`O(1)` header lookup on counted maps/sets, sorted maps/sets, and lists; `O(N)` fallback on uncounted `:hash_map` / `:hash_set`).
- `Enum.member?/2` -> `nif_slot_contains` (`O(log_16 N)` HAMT lookup on sets, `O(log N)` B+Tree lookup on sorted sets).
- `Enum.slice/2` / `Enum.at/2` -> `nif_slot_slice` (`O(log N + K)` index seek on lists, `Sorted_Map`, and `Sorted_Set`).
- `Stream.*` / `Enum.to_list/1` -> `nif_slot_entries` with geometrically ramping chunk sizes (`16 -> 64 -> 256`) so `Stream.take(cursor, 2)` only reads the first 16-entry chunk.

### Fused B+Tree Prefix & Range Scans (`nif_sorted_map_seek`)

When scanning a `Sorted_Map` whose values are child containers (such as `Xitdb.Ash.Search` term postings or `Xitdb.Ash.Indexer` secondary index ID sets), fetching the B+Tree keys first and then calling `nif_slot_entries` per key would pay the `~150–250 ns` NIF floor on every child container:

- **Fused decode (`decode_children: true`):** Passing `true` as the 7th argument to `Xitdb.NIF.nif_sorted_map_seek/7` (used by `Xitdb.Ash.Search`) seeks in the B+Tree and materializes each bounded child container inside Odin in a single dirty-CPU NIF crossing, falling back to lazy 3-tuples `{key, tag_id, val}` if a container is oversized.
- **Lazy cursor scan (`decode_children: false`):** `Xitdb.NIF.nif_sorted_map_seek/5` (and 6-arity range seek used by `Xitdb.Ash.Indexer`) returns lazy `%Xitdb.Cursor{}` handles (`Cursor.from_compact_slot/4`) without decoding out-of-range child containers.

### Transactional Writes (`put_in/3` vs. `Xitdb.DSL.tx` / `Xitdb.transact/3`)

- **Nested `put_in/3` (`put_in(root["users"][id]["score"], val)`):** In `tx_mode`, intermediate map brackets stage virtual write cursors without intermediate read NIF calls (`~13.9–14.2 µs` for a 3-hop `put_in/3` commit vs. `~3.60–3.77 µs` in Raw Odin). Inside `odin_nif_transact`, writes commit optimistically for `Hash_Map` and adapt lazily on `.Unexpected_Tag` with atomic rollback of `Root_Header` and file length on failure.
- **Declarative `Xitdb.DSL.tx` & Map `Xitdb.transact/3`:** Eliminate Elixir virtual-cursor closure staging overhead as well, auto-vivifying missing intermediate maps inside Odin and batching all operations into one `nif_transact` commit.

### Choosing the Right API

| Use Case | Recommended API | Why |
| :--- | :--- | :--- |
| Interactive exploration, passing subtrees to functions/LiveViews, or 1–2 hop reads | **`db["users"][id]` (`Access`)** | Returns composable `%Xitdb.Cursor{}` values compatible with `Access`, `Enum`, and `Stream`. |
| Deep (3+ hop) dynamic reads in hot loops | **`Xitdb.select(db, path_steps(users[id].profile.city))`** | Resolves the full path in 1 NIF call without string formatting or selector parsing. |
| Static literal paths or printable selectors (e.g., `history_of/2`) | **`~x|.users.alice.city|`** / **`path(...)`** | `~x` compiles to a static literal; `path/1` builds a properly escaped selector string. |
| Projecting multiple fields + bounded list slices from an entity | **`Xitdb.pull(cursor, [:username, todos: 0..5])`** | Projects the exact shape in 1 NIF call without materializing unneeded subtrees. |
| Deep writes, auto-vivifying missing maps, or batching list `append`/`insert`/`slice`/`fork` | **`Xitdb.DSL.tx db do ... end`** | Zero intermediate NIF reads, zero virtual-cursor closure overhead, one atomic commit. |

For full latency tables comparing Elixir vs. Raw Odin across all 28 workloads, see the [1v1 Client Benchmarks (`benchmarks/README.md`)](https://github.com/boxxxie/xitdb-elixir/blob/master/benchmarks/README.md).

---

## 5. Concurrency & Single-Writer Supervision

- **Concurrent readers never block each other:** `%Xitdb{}` and `%Xitdb.Cursor{}` synchronize NIF access with an internal `ErlNifRWLock` and read immutable historical moments, so any number of BEAM processes can query or traverse cursors concurrently.
- **Serialize read-modify-write transactions through one writer:** While `nif_transact` commits each operation batch atomically under a write lock, Elixir-side read-modify-write steps (`update` inside `tx` and 1-arity `Xitdb.transact/3` callbacks) read the current moment *before* entering `nif_transact`. Running concurrent read-modify-write transactions from multiple processes against the same `%Xitdb{}` handle risks lost updates (TOCTOU).

### Standalone Store Pattern (`GenServer` + `:persistent_term`)

If you use [Ash Framework](ash-and-spark.md), supervise `Xitdb.Ash.Store`—it publishes lock-free `:persistent_term` + `:atomics` snapshots (`~10 ns` reads) while coordinating monitored writer leases with savepoint nesting.

For standalone non-Ash applications, own writes in a single `GenServer` and publish the `%Xitdb{}` handle in `:persistent_term` so readers bypass the `GenServer` mailbox completely:

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
