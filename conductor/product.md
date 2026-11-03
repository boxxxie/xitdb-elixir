# Product Overview: `xitdb` for Elixir (`Xitdb`)

`Xitdb` is an idiomatic Elixir client and FFI wrapper around [`xitdb-odin`](../native/xitdb-odin), an embeddable, immutable, append-only database with persistent structural sharing (`v1` binary wire format).

Rather than re-implementing `xitdb`'s 9-byte tagged slots, 144-byte index blocks, 16-way HAMT/Radix-Trie, count-augmented B-Tree/B+Tree, and hardware-accelerated SHA-NI/CRC-64/XZ primitives in pure Elixir, `Xitdb` binds to [`xitdb-odin`](../native/xitdb-odin) via a C-ABI Erlang NIF (`priv/xitdb_nif.so`) and exposes a **Clojure/Datomic-style lazy persistent data structure experience** using standard Elixir protocols and behaviours.

---

## Core Architectural Principles

### 1. FFI over Pure-Elixir Reimplementation
- **Zero Wire-Engine Duplication:** All low-level HAMT/Radix-Trie/B-Tree/B+Tree mutations, SHA-NI digest hashing, CRC-64/XZ root trailer verification, garbage-collecting compaction, and Datalog query execution run in native Odin (`native/xitdb-odin/xitdb`).
- **Explicit Memory Lifetimes across the NIF:** Every `@(export) proc "c"` entrypoint initializes `context = runtime.default_context()` and uses scoped arenas / `context.temp_allocator` so temporary query/Datalog allocations are freed in $O(1)$ before returning to the BEAM.
- **Multiple Concurrent Readers, Serialized Writer:** Because `xitdb` is append-only and historical moments are immutable, read operations use `pread` and execute concurrently across BEAM processes without connection pooling or reader locks. Write transactions (`Xitdb.transact/2`) and compaction (`Xitdb.compact/2`) serialize safely at the database resource boundary.

### 2. Clojure-Style Lazy `%Xitdb.Cursor{}` via Elixir Protocols
- **Pure-Value 9-Byte Slot Handles:** Every node in `xitdb` is uniquely addressed by a 9-byte `Slot` (`tag: Tag` + `value: i64`). `%Xitdb.Cursor{db_ref: ref, tag: tag, value: offset, moment: moment}` holds no mutable C cursor pointer—making it a pure Elixir value that can be passed across BEAM processes, stored in ETS, or assigned in Phoenix LiveViews without dangling pointers or mutexes.
- **Scalars Auto-Unwrap, Containers Stay Lazy:**
  - Resolving a primitive slot (`:short_bytes`, `:bytes`, `:uint`, `:int`, `:float`) immediately returns the native Elixir scalar (`"Alice"`, `42`, `3.14`, `true`, `nil`).
  - Resolving a container slot (`:hash_map`, `:counted_hash_map`, `:sorted_map`, `:array_list`, `:linked_array_list`, `:hash_set`, `:counted_hash_set`, `:sorted_set`) returns a lazy `%Xitdb.Cursor{}` pointing to the child slot.
- **Native Protocol Implementations:**
  - **`Access` Behaviour:** Supports `db["users"]["alice"]["name"]`, `cursor[0]`, and `Kernel.get_in/2` (`Access.at/1`, `Access.all/0`, `Access.filter/1`).
  - **`Enumerable` Protocol:**
    - `Enum.count/1`: Runs in **$O(1)$** on `:array_list`, `:linked_array_list`, `:counted_hash_map`, `:counted_hash_set`, `:sorted_map`, and `:sorted_set` by reading the on-disk count slot directly.
    - `Enum.member?/2`: Runs in **$O(1)$ / $O(\log N)$** via native HAMT or B+Tree key lookup rather than linear enumeration.
    - `Enum.slice/2`: Uses `Enumerable.slice/1` to jump directly to index offsets in $O(\log_{16} N)$ without scanning preceding elements.
    - `Enum.reduce/3` (`Enum.map/2`, `Enum.to_list/1`, `Stream.*`): Uses **chunked iterator batches** across the NIF (`nif_iter_chunk`) to amortize FFI boundary crossings.
  - **`Inspect` Protocol:** Pretty-prints shallow collection metadata (`#Xitdb.Cursor<CountedHashMap count: 1420, keys: ["alice", "bob", ...]>`) in `iex` without materializing gigabytes of disk data into the BEAM heap.
  - **`Xitdb.materialize/1`:** Eagerly materializes any `%Xitdb.Cursor{}` subtree into plain Elixir maps, lists, and `MapSet`s in a single NIF traversal.

### 3. Collection Type Wrappers on Write
- On **reads**, the 9-byte `Slot` tag automatically identifies the collection type (`Hash_Map`, `Counted_Hash_Map`, `Sorted_Map`, `Array_List`, `Linked_Array_List`, sets).
- On **writes**, standard Elixir terms map to sensible defaults (`%{}` -> `Counted_Hash_Map`, `[]` -> `Array_List`, `MapSet` -> `Counted_Hash_Set`), while explicit wrapper structs allow opting into specific `xitdb` data structures:
  - `Xitdb.hash_map(map)` -> `Hash_Map` (uncounted HAMT)
  - `Xitdb.counted_map(map)` -> `Counted_Hash_Map` ($O(1)$ `Enum.count/1` HAMT)
  - `Xitdb.sorted_map(enum)` -> `Sorted_Map` (lexicographically ordered B+Tree with rank & range scans)
  - `Xitdb.array_list(list)` -> `Array_List` (16-way Radix Trie)
  - `Xitdb.linked_list(list)` -> `Linked_Array_List` (count-augmented B-Tree with $O(\log N)$ `insert_at`, `delete_at`, `concat`, `slice`)
  - `Xitdb.hash_set(enum)` / `Xitdb.counted_set(enum)` / `Xitdb.sorted_set(enum)` -> Set variants

### 4. Coarse-Grained Transactions, Time-Travel, Pull, Datalog & Sigils
- **Coarse-Grained Write Batches (`Xitdb.transact/2`):** Supports mutating the root via `put_in/3`, `update_in/3`, `pop_in/2`, or declarative transaction batches that flush in a single atomic NIF transaction commit.
- **Zero-Cost Snapshot Isolation (`Xitdb.db/1`, `Xitdb.as_of/2`):** Pin a `%Xitdb.Cursor{}` to the latest moment or any historical moment index `0..N-1`.
- **5-Layer DSL Surface:** Exposes `Xitdb.select/2` (`~x".users.alice.roles[0]"`), `Xitdb.pull/3`, `Xitdb.diff_moments/4`, `Xitdb.history_of/2`, and `Xitdb.query/3` (`~q"[:find ?e ?name :where ...]"`).
