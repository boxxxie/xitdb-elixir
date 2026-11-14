# Reference: Track 16 — Documentation Fixes & Operational Guides (`docs/*.md`)

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Track ID:** `doc_fixes_and_operational_guides_20261112`
> - **Prerequisites:** Wave 1–4 tracks + [`ash_phase1_verification_suite_20261111`](../ash_phase1_verification_suite_20261111/index.md)
> - **Parent Track:** [`remaining_improvements_20261112`](../remaining_improvements_20261112/index.md) (Step 2)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Target Documents:**
>   - [`docs/path-and-pull-dsl.md`](../../../docs/path-and-pull-dsl.md)
>   - [`docs/time-travel-and-storage.md`](../../../docs/time-travel-and-storage.md)
>   - [`docs/transaction-dsl.md`](../../../docs/transaction-dsl.md)
>   - [`docs/ash-and-spark.md`](../../../docs/ash-and-spark.md)
>   - [`docs/access-and-enumerable.md`](../../../docs/access-and-enumerable.md)
>   - [`docs/collections-and-indexing.md`](../../../docs/collections-and-indexing.md)
>   - [`docs/datalog-dsl.md`](../../../docs/datalog-dsl.md)

---

## 1. Overview & Architectural Motivation

Track 16 resolves the path-output mismatch, strips any leftover `$O(...)` LaTeX math blocks in `docs/*.md`, and documents the unified operational contracts across four guides:

* **Corrected `sorted/1` selector output & root-cursor note (`docs/path-and-pull-dsl.md`):** Fixes the `path(sorted("email->id")[email])` example, which previously showed `"$[\"email->id\"].[\"alice.liddell@acme.io\"]"` instead of the actual compiled selector `".email->id$[\"alice.liddell@acme.io\"]"`, and clarifies that `Xitdb.select/2` expects a `%Xitdb{}` handle or root snapshot cursor (`Xitdb.db/1` / `Xitdb.as_of/2`) rather than a nested child cursor.

* **Backend trade-offs (`docs/time-travel-and-storage.md`):** Contrasts `:memory`, `:buffered_file`, and `:file`—which was previously listed in `Xitdb.open/1` without explanation in the storage guide—along with `:sha1` vs. `:sha256` digest selection.

* **Write serialization & `:index_rules` (`docs/transaction-dsl.md`):** Documents `:index_rules` alongside `:doc`, `:instant`, `:meta`, and `:base_moment`, and adds a concurrency section explaining why standalone non-Ash read-modify-write transactions (`update` in `tx` and `Xitdb.transact/3` callbacks) should serialize writes through a single owner `GenServer` (or `Xitdb.Ash.Store` in Ash apps) while keeping reads lock-free.

* **First-class `Xitdb.Ash.Store`, `DataLayer`, `TestSandbox` & `lock_change` contracts (`docs/ash-and-spark.md`):** Documents `use Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer`, and `Xitdb.Ash.TestSandbox` alongside `MyApp.MDM.Changes.ModifyLockedFields` (explicitly noting the `require_atomic? false` requirement on `lock_action` and `unlock_action`), rather than recommending a hand-rolled `GenServer` store.

---

## 2. Complete Code Changes (`diff`)

````diff
diff --git a/docs/path-and-pull-dsl.md b/docs/path-and-pull-dsl.md
--- a/docs/path-and-pull-dsl.md
+++ b/docs/path-and-pull-dsl.md
@@ -52,7 +52,7 @@
 # => ".accounts.[\"alice.liddell@acme.io\"].balance"
 
 path(sorted("email->id")[email])
-# => "$[\"email->id\"].[\"alice.liddell@acme.io\"]"
+# => ".email->id$[\"alice.liddell@acme.io\"]"
 ```
 
 ---
@@ -96,9 +96,10 @@
 Compiled selectors work across all `Xitdb` read, history, and mutation APIs:
 
 ```elixir
-# 1. Single-call selection against the latest moment or a historical moment:
+# 1. Single-call root-anchored selection against `%Xitdb{}` or a root snapshot (`Xitdb.db/1`, `Xitdb.as_of/2`):
 todo = Xitdb.select!(db, path(users[id].todos[[0]]))
 v0_role = Xitdb.select!(db, path(at_moment(0, users[id].role)))
+# Note: Selectors always resolve from the moment root; for child cursors (`db["users"]`), use `Access` or `Xitdb.pull/2`.
 
 # 2. Inspecting the temporal lineage of a path across all commits:
 {:ok, lineage} = Xitdb.history_of(db, path(users[id].role))
diff --git a/docs/time-travel-and-storage.md b/docs/time-travel-and-storage.md
--- a/docs/time-travel-and-storage.md
+++ b/docs/time-travel-and-storage.md
@@ -28,11 +28,18 @@
 :ok = Xitdb.close(disk_db)
 ```
 
+### Choosing a Backend & Hash Algorithm
+
+- **`:memory`** — Backed by an in-memory buffer with zero filesystem I/O; ideal for `async: true` ExUnit tests, ephemeral caches, and scratchpad projections.
+- **`:buffered_file`** — Buffers node writes in user space before flushing to the OS file descriptor on commit or `Xitdb.sync/1`; recommended for production workloads because multi-node HAMT/B+Tree commits avoid per-slot `write` syscalls.
+- **`:file`** — Issues unbuffered OS file reads/writes directly against the file descriptor; useful for small CLI utilities or constrained memory environments with infrequent writes.
+- **`:sha1` vs. `:sha256`** — Controls the cryptographic digest used for HAMT key hashing (`:sha1` by default for slightly faster hashing and compact digests; `:sha256` when collision-resistance policies require SHA-2). Once a database file is created, always reopen it with the same `:hash` setting.
+
 ---
 
 ## 2. Instant Time-Travel Snapshots (`Xitdb.as_of/2`)
 
-Pinning a snapshot to any historical moment index (`0..moment_count - 1`, or negative offsets from the latest commit like `-1`, `-2`) is an **$O(1)$ operation** that returns a `%Xitdb.Cursor{}` bound to that moment:
+Pinning a snapshot to any historical moment index (`0..moment_count - 1`, or negative offsets from the latest commit like `-1`, `-2`) is an **`O(1)` operation** that returns a `%Xitdb.Cursor{}` bound to that moment:
 
 ```elixir
 use Xitdb.DSL
@@ -79,7 +86,7 @@
 
 ### Zero-Copy Subtree Cloning (`fork`)
 
-Inside a transaction, `fork from_path, to_path` (or `Xitdb.fork/3`) clones any subtree—even a collection with millions of entries—in **$O(1)$ time and 9 bytes** by copying its `Slot` pointer and freezing the transaction watermark (`savepoint`) so subsequent edits to either path trigger copy-on-write isolation:
+Inside a transaction, `fork from_path, to_path` (or `Xitdb.fork/3`) clones any subtree—even a collection with millions of entries—in **`O(1)` time and 9 bytes** by copying its `Slot` pointer and freezing the transaction watermark (`savepoint`) so subsequent edits to either path trigger copy-on-write isolation:
 
 ```elixir
 {:ok, db} =
@@ -93,7 +100,7 @@
 
 ## 4. Structural Diffs (`Xitdb.diff_moments/3`)
 
-Because unchanged subtrees share identical 9-byte `Slot` pointers (`tag` + byte `offset`) across moments, `Xitdb.diff_moments(db, moment_a, moment_b)` skips identical subtrees in **$O(1)$ time** without traversing their children, computing the exact delta in $O(\Delta \text{ changed paths})$:
+Because unchanged subtrees share identical 9-byte `Slot` pointers (`tag` + byte `offset`) across moments, `Xitdb.diff_moments(db, moment_a, moment_b)` skips identical subtrees in **`O(1)` time** without traversing their children, computing the exact delta in `O(delta changed paths)`:
 
 ```elixir
 {:ok, changes} = Xitdb.diff_moments(db, 0, 1)
diff --git a/docs/transaction-dsl.md b/docs/transaction-dsl.md
--- a/docs/transaction-dsl.md
+++ b/docs/transaction-dsl.md
@@ -4,7 +4,7 @@
 
 1. **Intermediate NIF reads:** `put_in(root["users"][id]["profile"]["city"], "NYC")` invokes `Access.get_and_update/3` at every step, crossing the NIF boundary on each hop.
 2. **Missing intermediate paths:** If `root["users"][id]` does not exist yet, `Access.get_and_update/3` passes `nil` to the next step and raises unless intermediate maps are initialized first.
-3. **No syntax for native list/tree/metadata operations:** `Access` cannot express `xitdb`'s native $O(\log N)$ list `append`, `insert`, `slice`, $O(1)$ zero-copy subtree `fork`, secondary index registration (`index_on`), or commit metadata (`meta`, `instant`, `savepoint`).
+3. **No syntax for native list/tree/metadata operations:** `Access` cannot express `xitdb`'s native `O(log N)` list `append`, `insert`, `slice`, `O(1)` zero-copy subtree `fork`, secondary index registration (`index_on`), or commit metadata (`meta`, `instant`, `savepoint`).
 
 `Xitdb.DSL.tx/2,3` and `Xitdb.DSL.tx!/2,3` solve all three problems by compiling path expressions directly into a single atomic NIF transaction batch.
 
@@ -95,7 +95,7 @@
 ```
 
 ### `insert list_path[[idx]], value` (or `insert list_path, idx, value`)
-Inserts `value` at `idx` in a `Linked_Array_List` in $O(\log N)$ time, shifting subsequent elements right without copying them.
+Inserts `value` at `idx` in a `Linked_Array_List` in `O(log N)` time, shifting subsequent elements right without copying them.
 
 ```elixir
 insert users[id].todos[[0]], "urgent-task"
@@ -104,7 +104,7 @@
 ```
 
 ### `slice list_path, first..last` (or `slice list_path, offset, size`)
-Slices a `Linked_Array_List` (arbitrary `offset` and `size` in $O(\log N)$) or truncates an `Array_List` to `size`.
+Slices a `Linked_Array_List` (arbitrary `offset` and `size` in `O(log N)`) or truncates an `Array_List` to `size`.
 
 ```elixir
 slice users[id].todos, 0..9
@@ -113,7 +113,7 @@
 ```
 
 ### `fork from_path, to_path`
-Clones the subtree at `from_path` to `to_path` in **$O(1)$ zero-copy time** by copying its 9-byte `Slot` pointer and freezing the transaction watermark so subsequent mutations in the same `tx` block trigger copy-on-write on either branch.
+Clones the subtree at `from_path` to `to_path` in **`O(1)` zero-copy time** by copying its 9-byte `Slot` pointer and freezing the transaction watermark so subsequent mutations in the same `tx` block trigger copy-on-write on either branch.
 
 ```elixir
 fork users[id], backups[id]
@@ -221,3 +221,49 @@
 - `:instant` (`integer()`) — Epoch timestamp in milliseconds stored in `__tx.tx_instant` (inspected by `Xitdb.history_of/2`).
 - `:meta` (`map() | keyword()`) — Custom key-value metadata stored in `__tx.<key>`.
 - `:base_moment` (`integer()`, default `-1`) — Historical moment index to branch from.
+- `:index_rules` (`[{:index_on, source_map, field, index_map}]`, default `[]`) — Secondary B+Tree index rules applied during map or callback transactions.
+
+---
+
+## 5. Concurrency Model: Lock-Free Reads & Single-Writer Serialization
+
+- **Concurrent readers never block each other:** `%Xitdb{}` and `%Xitdb.Cursor{}` handles synchronize NIF slot access with an internal `ErlNifRWLock` and read immutable historical moments, so any number of BEAM processes can query or traverse cursors concurrently.
+- **Serialize read-modify-write transactions through one writer:** While `nif_transact` atomically commits each batch under a write lock, Elixir-side read-modify-write steps (`update` inside `tx` and `Xitdb.transact/3` 1-arity callbacks) read the current moment *before* entering `nif_transact`. If two BEAM processes run read-modify-write transactions concurrently against the same `%Xitdb{}` reference, both can read moment `N` and overwrite each other's updates (TOCTOU).
+
+If you are using Ash, supervise `Xitdb.Ash.Store` (see [`docs/ash-and-spark.md`](ash-and-spark.md)). For standalone non-Ash applications, own writes in a single `GenServer` and publish the `%Xitdb{}` handle in `:persistent_term` so readers bypass the `GenServer` mailbox completely:
+
+```elixir
+defmodule MyApp.Store do
+  use GenServer
+
+  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
+
+  # Zero-bottleneck concurrent reads (never touches GenServer mailbox)
+  def handle, do: :persistent_term.get({__MODULE__, :db})
+  def db, do: Xitdb.db(handle())
+
+  # Serialized atomic writes
+  def write(fun) when is_function(fun, 1) do
+    GenServer.call(__MODULE__, {:write, fun}, :infinity)
+  end
+
+  @impl true
+  def init(opts) do
+    Process.flag(:trap_exit, true)
+    {:ok, db} = Xitdb.open(opts)
+    :persistent_term.put({__MODULE__, :db}, db)
+    {:ok, db}
+  end
+
+  @impl true
+  def handle_call({:write, fun}, _from, db) do
+    {:reply, fun.(db), db}
+  end
+
+  @impl true
+  def terminate(_reason, db) do
+    :persistent_term.erase({__MODULE__, :db})
+    Xitdb.close(db)
+  end
+end
+```
diff --git a/docs/ash-and-spark.md b/docs/ash-and-spark.md
--- a/docs/ash-and-spark.md
+++ b/docs/ash-and-spark.md
@@ -152,7 +152,7 @@
 ### 1. `Xitdb.Ash.Transformers.WireChanges`
 At compile time, `WireChanges`:
 - Automatically attaches `{lock_change_mod, op: :lock}` to `lock_action` and `{lock_change_mod, op: :unlock}` to `unlock_action` (idempotently skipping any action that already declares `lock_change_mod` or does not exist on the resource).
-- Precomputes and compiles literal module callbacks (`__xitdb_editable_field_strings__/0`, `__xitdb_pull_fields__/0`, `__xitdb_pull_pattern__/0`, `__xitdb_collection__/0`, `__xitdb_indexes__/0`, `__xitdb_store__/0`, `__xitdb_lock_change__/0`, plus pre-merged companion pair lookups) directly onto the resource module so runtime `Xitdb.Ash.Info` lookups run in **$O(1)$ (~30 ns)** with zero heap allocations.
+- Precomputes and compiles literal module callbacks (`__xitdb_editable_field_strings__/0`, `__xitdb_pull_fields__/0`, `__xitdb_pull_pattern__/0`, `__xitdb_collection__/0`, `__xitdb_indexes__/0`, `__xitdb_store__/0`, `__xitdb_lock_change__/0`, plus pre-merged companion pair lookups) directly onto the resource module so runtime `Xitdb.Ash.Info` lookups run in **`O(1)` (~30 ns)** with zero heap allocations.
 
 ### 2. `Xitdb.Ash.Verifiers.VerifySyncProjection`
 At compile time, `VerifySyncProjection` verifies four invariants and raises a `Spark.Error.DslError` if any fails:
@@ -228,4 +228,79 @@
   def __xitdb_collection__, do: :items
   def __xitdb_indexes__, do: [sku: "sku->item_id"]
 end
 ```
+
+---
+
+## 5. Store Supervision (`Xitdb.Ash.Store`), `DataLayer`, `TestSandbox` & `lock_change` Contracts
+
+Rather than hand-rolling a bespoke `GenServer`, use `Xitdb.Ash.Store` for both pure `Xitdb.Ash.DataLayer` resources and hybrid `Xitdb.Ash.Resource` MDM projections:
+
+### 1. Defining & Supervising `MyApp.MDM.Store` (`use Xitdb.Ash.Store`)
+
+`Xitdb.Ash.Store` publishes lock-free snapshots via `:persistent_term`, serializes writes with monitored caller-process writer leases, supports nested savepoints (`Store.transact/3`, `Store.rollback/2`), and integrates natively with `Xitdb.Ash.TestSandbox` for `async: true` ExUnit suites:
+
+```elixir
+defmodule MyApp.MDM.Store do
+  use Xitdb.Ash.Store
+end
+
+# In MyApp.Application.start/2:
+children = [
+  {MyApp.MDM.Store,
+   path: "/var/lib/myapp/mdm.xit",
+   domains: [MyApp.Accounts]}
+]
+
+# Lock-free root snapshot cursor (`%Xitdb.Cursor{}` pinned to the latest committed moment):
+root_cursor = MyApp.MDM.Store.root()
+
+# Serialized MDM `tx_for!` batch inside the store's writer lease (re-entrant inside transactions).
+# `mutate/3` passes and expects `{db, moment}` working snapshots:
+{:ok, :synced} =
+  Xitdb.Ash.Store.mutate(MyApp.MDM.Store, fn {db, moment} ->
+    next_db =
+      tx_for! db, [MyApp.Accounts.Organization],
+        base_moment: moment,
+        doc: "sync org 101" do
+        put organizations["101"].id, "101"
+        put organizations["101"].domain, "northleaf.ca"
+      end
+
+    {:ok, {next_db, Xitdb.moment_count(next_db) - 1}, :synced}
+  end)
+```
+
+For resources persisted directly in `.xit` files without Postgres, set `data_layer: Xitdb.Ash.DataLayer` (which automatically includes the `xitdb do ... end` DSL, secondary `index` / `search_field` / `references` entities, and `Store` transaction coordination) and isolate concurrent tests in `test_helper.exs` / `DataCase` via `Xitdb.Ash.TestSandbox.init()` and `Xitdb.Ash.TestSandbox.checkout([MyApp.MDM.Store])`.
+
+### 2. Reference `lock_change` Module (`MyApp.MDM.Changes.ModifyLockedFields`)
+
+`WireChanges` attaches `{lock_change_mod, op: :lock}` to `lock_action` and `{lock_change_mod, op: :unlock}` to `unlock_action`.
+
+> [!IMPORTANT]
+> Because `ModifyLockedFields` inspects `Ash.Changeset.get_data(changeset, :locked_fields)` inside `change/3` without an `atomic/3` callback—and `WireChanges` preserves your action flags as written—both `lock_action` (`:lock_field`) and `unlock_action` (`:unlock_field`) **must** set `require_atomic? false` on the resource (as shown in Section 1).
+
+```elixir
+defmodule MyApp.MDM.Changes.ModifyLockedFields do
+  use Ash.Resource.Change
+  alias Xitdb.Ash.Info, as: XitdbInfo
+
+  @impl true
+  def change(changeset, opts, _context) do
+    field = Ash.Changeset.get_argument(changeset, :field)
+    allowed = XitdbInfo.editable_field_strings(changeset.resource)
+
+    if field in allowed do
+      current = Ash.Changeset.get_data(changeset, :locked_fields) || []
+
+      updated =
+        case Keyword.fetch!(opts, :op) do
+          :lock -> Enum.uniq(current ++ [field])
+          :unlock -> List.delete(current, field)
+        end
+
+      Ash.Changeset.force_change_attribute(changeset, :locked_fields, updated)
+    else
+      Ash.Changeset.add_error(changeset, field: :field, message: "is not an editable Xitdb field")
+    end
+  end
+end
+```
diff --git a/docs/access-and-enumerable.md b/docs/access-and-enumerable.md
--- a/docs/access-and-enumerable.md
+++ b/docs/access-and-enumerable.md
@@ -10,7 +10,7 @@ Each `%Xitdb.Cursor{}` wraps only the NIF database resource reference (`db_ref`)
 
 When you read from a `%Xitdb{}` handle (`Xitdb.db(db)`, `Xitdb.as_of(db, moment)`, or `db["users"]`):
 
-1. **Containers return `%Xitdb.Cursor{}` in $O(1)$ heap space:**
+1. **Containers return `%Xitdb.Cursor{}` in `O(1)` heap space:**
    If the target slot is a collection (`:hash_map`, `:counted_hash_map`, `:sorted_map`, `:array_list`, `:linked_array_list`, `:hash_set`, `:counted_hash_set`, `:sorted_set`), `Xitdb` returns a lightweight `%Xitdb.Cursor{}` struct pointing to that collection's byte offset.
 2. **Leaf scalars unwrap automatically:**
    If the target slot is a scalar (`String.t()`, `integer()`, `float()`, `boolean()`, or `{:tagged, tag, payload}`), `Xitdb` immediately decodes and returns the native Elixir value.
@@ -124,14 +124,14 @@ To abort and roll back from inside a `Xitdb.transact/3` callback, return `{:abor
 
 ## 4. `Enumerable` Fast-Path Pushdowns & `Stream` Pagination
 
-`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure pushdowns so common `Enum` operations execute in $O(1)$ or $O(\log N)$ inside Odin rather than linearly scanning elements in Elixir:
+`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure pushdowns so common `Enum` operations execute in `O(1)` or `O(log N)` inside Odin rather than linearly scanning elements in Elixir:
 
 | `Enum` / `Stream` Operation | Backing NIF Pushdown | Complexity | Supported Collection Kinds |
 | :--- | :--- | :--- | :--- |
-| `Enum.count(cursor)` | `nif_slot_count` | **$O(1)$** | `Counted_Hash_Map`, `Counted_Hash_Set`, `Sorted_Map`, `Sorted_Set`, `Array_List`, `Linked_Array_List` *(falls back to $O(N)$ reducer on uncounted `Hash_Map` / `Hash_Set`)* |
-| `Enum.member?(set_cur, "val")` | `nif_slot_contains` | **$O(1)$ / $O(\log N)$** | `Hash_Set`, `Counted_Hash_Set` ($O(\log_{16} N)$ HAMT), `Sorted_Set` ($O(\log N)$ B+Tree) |
-| `Enum.member?(map_cur, {k, v})` | `Cursor.fetch` + equality | **$O(1)$ / $O(\log N)$** | `Hash_Map`, `Counted_Hash_Map`, `Sorted_Map` |
-| `Enum.slice(cursor, first..last)`<br>`Enum.at(cursor, idx)` | `nif_slot_slice` | **$O(\log N + K)$** | `Array_List`, `Linked_Array_List`, `Sorted_Map` (yields `{k, v}` tuples in key order), `Sorted_Set` (yields members in key order) |
+| `Enum.count(cursor)` | `nif_slot_count` | **`O(1)`** | `Counted_Hash_Map`, `Counted_Hash_Set`, `Sorted_Map`, `Sorted_Set`, `Array_List`, `Linked_Array_List` *(falls back to `O(N)` reducer on uncounted `Hash_Map` / `Hash_Set`)* |
+| `Enum.member?(set_cur, "val")` | `nif_slot_contains` | **`O(1)` / `O(log N)`** | `Hash_Set`, `Counted_Hash_Set` (`O(log_16 N)` HAMT), `Sorted_Set` (`O(log N)` B+Tree) |
+| `Enum.member?(map_cur, {k, v})` | `Cursor.fetch` + equality | **`O(1)` / `O(log N)`** | `Hash_Map`, `Counted_Hash_Map`, `Sorted_Map` |
+| `Enum.slice(cursor, first..last)`<br>`Enum.at(cursor, idx)` | `nif_slot_slice` | **`O(log N + K)`** | `Array_List`, `Linked_Array_List`, `Sorted_Map` (yields `{k, v}` tuples in key order), `Sorted_Set` (yields members in key order) |
 | `Stream.take(cursor, k)`<br>`Enum.to_list(cursor)` | `nif_slot_entries` | **Adaptive chunks (`16 -> 64 -> 256`)** | All 8 collection types |
 
 ### Examples
diff --git a/docs/collections-and-indexing.md b/docs/collections-and-indexing.md
--- a/docs/collections-and-indexing.md
+++ b/docs/collections-and-indexing.md
@@ -3,9 +3,9 @@
 By default, when you pass standard Elixir data structures to `Xitdb.transact/3` or `put` inside `Xitdb.DSL.tx`:
 - Plain Elixir maps (`%{}`) are stored as `:hash_map` (16-way HAMT).
 - Plain Elixir lists (`[]`) are stored as `:array_list` (16-way Radix Trie).
-- `%MapSet{}` values are stored as `:counted_hash_set` (16-way HAMT set with $O(1)$ count).
+- `%MapSet{}` values are stored as `:counted_hash_set` (16-way HAMT set with `O(1)` count).
 
-When your workload requires **$O(1)$ map cardinality**, **lexicographical B+Tree key ordering and range scans**, or **$O(\log N)$ middle-of-list insertions and removals**, wrap your data in `Xitdb`'s explicit collection constructors (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, etc.) or initialize them with `init_col` in `tx`.
+When your workload requires **`O(1)` map cardinality**, **lexicographical B+Tree key ordering and range scans**, or **`O(log N)` middle-of-list insertions and removals**, wrap your data in `Xitdb`'s explicit collection constructors (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, etc.) or initialize them with `init_col` in `tx`.
 
 ---
 
@@ -15,14 +15,14 @@ When your workload requires **$O(1)$ map cardinality**, **lexicographical B+Tree
 
 | Collection Kind | Constructor | Selector Sigil | Backing Structure | `get` / `member?` | `put` / `append` | `insert` / `rm` / `slice` | `Enum.count/1` |
 | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
-| `:hash_map` | `Xitdb.hash_map(map)` *(or `%{}`)* | `.key` | 16-way HAMT | $O(\log_{16} N)$ | $O(\log_{16} N)$ | `rm`: $O(\log_{16} N)$ | $O(N)$ scan |
-| `:counted_hash_map` | `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count slot | $O(\log_{16} N)$ | $O(\log_{16} N)$ | `rm`: $O(\log_{16} N)$ | **$O(1)$** |
-| `:sorted_map` | `Xitdb.sorted_map(map)` | `$key` | Count-augmented B+Tree | $O(\log N)$ | $O(\log N)$ | `rm` & `slice`: **$O(\log N)$** | **$O(1)$** |
-| `:array_list` | `Xitdb.array_list(list)` *(or `[]`)* | `[idx]` | 16-way Radix Trie | $O(\log_{16} N)$ | $O(\log_{16} N)$ | Tail `slice` only; no middle `insert`/`rm` | **$O(1)$** |
-| `:linked_array_list` | `Xitdb.linked_list(list)` | `[[idx]]` | Count-augmented B-Tree | $O(\log N)$ | $O(\log N)$ | Arbitrary `insert`, `rm`, `slice`: **$O(\log N)$** | **$O(1)$** |
-| `:hash_set` | `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | $O(\log_{16} N)$ | $O(\log_{16} N)$ | `rm`: $O(\log_{16} N)$ | $O(N)$ scan |
-| `:counted_hash_set` | `Xitdb.counted_set(enum)` *(or `MapSet`)* | `#%member` | 16-way HAMT set + count | $O(\log_{16} N)$ | $O(\log_{16} N)$ | `rm`: $O(\log_{16} N)$ | **$O(1)$** |
-| `:sorted_set` | `Xitdb.sorted_set(enum)` | `^member` | Count-augmented B+Tree set | $O(\log N)$ | $O(\log N)$ | `rm` & `slice`: **$O(\log N)$** | **$O(1)$** |
+| `:hash_map` | `Xitdb.hash_map(map)` *(or `%{}`)* | `.key` | 16-way HAMT | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | `O(N)` scan |
+| `:counted_hash_map` | `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count slot | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | **`O(1)`** |
+| `:sorted_map` | `Xitdb.sorted_map(map)` | `$key` | Count-augmented B+Tree | `O(log N)` | `O(log N)` | `rm` & `slice`: **`O(log N)`** | **`O(1)`** |
+| `:array_list` | `Xitdb.array_list(list)` *(or `[]`)* | `[idx]` | 16-way Radix Trie | `O(log_16 N)` | `O(log_16 N)` | Tail `slice` only; no middle `insert`/`rm` | **`O(1)`** |
+| `:linked_array_list` | `Xitdb.linked_list(list)` | `[[idx]]` | Count-augmented B-Tree | `O(log N)` | `O(log N)` | Arbitrary `insert`, `rm`, `slice`: **`O(log N)`** | **`O(1)`** |
+| `:hash_set` | `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | `O(N)` scan |
+| `:counted_hash_set` | `Xitdb.counted_set(enum)` *(or `MapSet`)* | `#%member` | 16-way HAMT set + count | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | **`O(1)`** |
+| `:sorted_set` | `Xitdb.sorted_set(enum)` | `^member` | Count-augmented B+Tree set | `O(log N)` | `O(log N)` | `rm` & `slice`: **`O(log N)`** | **`O(1)`** |
 
 ---
 
@@ -30,15 +30,15 @@ When your workload requires **$O(1)$ map cardinality**, **lexicographical B+Tree
 
 ### Maps: `hash_map` vs. `counted_map` vs. `sorted_map`
 - **Use `%{}` / `Xitdb.hash_map/1`** for entity attributes (`%{"username" => "alice", "age" => 30}`) and general key-value lookups where you don't need `Enum.count/1` or sorted key iteration.
-- **Use `Xitdb.counted_map/1`** for entity tables (`"departments"`, `"tenants"`) when you frequently call `Enum.count(db["tenants"])` and want $O(1)$ cardinality without B+Tree key sorting overhead.
+- **Use `Xitdb.counted_map/1`** for entity tables (`"departments"`, `"tenants"`) when you frequently call `Enum.count(db["tenants"])` and want `O(1)` cardinality without B+Tree key sorting overhead.
 - **Use `Xitdb.sorted_map/1`** for lexicographically ordered directories, time-series keys (`"2026-11-03T22:00:00Z"`), leaderboards, and secondary indexes where you need ordered iteration, `Enum.slice/2` pagination by rank, or Datalog `starts_with` / `>=` B+Tree range pushdowns.
 
 ### Lists: `array_list` vs. `linked_list`
 - **Use `[]` / `Xitdb.array_list/1`** for append-only logs, fixed-order arrays, or random index reads (`roles[0]`). `Array_List` supports fast tail `append` and tail truncation (`slice list, 0, new_size`), but does **not** allow middle-of-list insertions or element deletion.
-- **Use `Xitdb.linked_list/1`** for task queues, ordered feeds, or editable lists where items are inserted at index `0` (`insert todos[[0]], "urgent"`), removed by index (`rm todos[[2]]`), or sliced at arbitrary offsets (`slice todos, 10..19`) in **$O(\log N)$** time without re-indexing subsequent elements.
+- **Use `Xitdb.linked_list/1`** for task queues, ordered feeds, or editable lists where items are inserted at index `0` (`insert todos[[0]], "urgent"`), removed by index (`rm todos[[2]]`), or sliced at arbitrary offsets (`slice todos, 10..19`) in **`O(log N)`** time without re-indexing subsequent elements.
 
 ### Sets: `hash_set` vs. `counted_set` vs. `sorted_set`
-- **Use `Xitdb.counted_set/1` (or `MapSet.new/1`)** for user roles, permissions, or feature flags when you need $O(1)$ `Enum.count/1` and $O(1)$ `Enum.member?/2`.
+- **Use `Xitdb.counted_set/1` (or `MapSet.new/1`)** for user roles, permissions, or feature flags when you need `O(1)` `Enum.count/1` and `O(1)` `Enum.member?/2`.
 - **Use `Xitdb.sorted_set/1`** when set members should always iterate and slice in deterministic alphabetical order (e.g., tags or badges).
 
 ```elixir
@@ -96,7 +96,7 @@ Xitdb.select!(db, path(sorted("email->id")["daria@acme.io"])) # => "u102"
 
 | Elixir Value | `xitdb` Storage Representation | Round-Trip Value |
 | :--- | :--- | :--- |
-| `"hello"` | `Tag.Short_Bytes` ($\le 8$ bytes inline in `Slot`) or `Tag.Bytes` | `"hello"` |
+| `"hello"` | `Tag.Short_Bytes` (`<= 8` bytes inline in `Slot`) or `Tag.Bytes` | `"hello"` |
 | `42` (non-negative `integer()`) | `Tag.Uint` (`u64`) | `42` |
 | `-42` (negative `integer()`) | `Tag.Int` (`i64`) | `-42` |
 | `3.14` (`float()`) | `Tag.Float` (`f64`) | `3.14` |
diff --git a/docs/datalog-dsl.md b/docs/datalog-dsl.md
--- a/docs/datalog-dsl.md
+++ b/docs/datalog-dsl.md
@@ -2,7 +2,7 @@
 
 `Xitdb` includes a native structural and temporal Datalog engine in Odin that supports:
 - Pattern unification across maps, counted maps, sorted maps, lists, and sets
-- Automatic $O(\log N)$ B+Tree secondary index prefix and range pushdown
+- Automatic `O(log N)` B+Tree secondary index prefix and range pushdown
 - Negated clauses (`not`) and key existence checks
 - Cycle-safe BFS transitive graph traversal (`reach/3,4`)
 - Cross-moment and full-history temporal queries (`at_moment/2`)
@@ -197,8 +197,8 @@ Non-aggregated variables in `find` automatically act as the grouping key. If all
   - `u.tags.sorted_set_member("elixir")` (`^` `Sorted_Set`)
 - **Comparisons:** `==`, `!=`, `>`, `>=`, `<`, `<=` (works between two logic variables like `new_salary > old_salary` or a variable and a literal/pinned value like `salary >= ^min_salary`)
 - **String predicates & B+Tree Pushdown:**
-  - `starts_with(var, "prefix")` — triggers an **$O(\log N)$ B+Tree prefix seek** when `var` is unified against a `Sorted_Map` (`sorted(...)`) or `Sorted_Set`!
-  - `var >= "lower_bound"` / `var > "lower_bound"` — also triggers an **$O(\log N)$ B+Tree lower-bound seek** on `Sorted_Map` / `Sorted_Set` keys!
+  - `starts_with(var, "prefix")` — triggers an **`O(log N)` B+Tree prefix seek** when `var` is unified against a `Sorted_Map` (`sorted(...)`) or `Sorted_Set`!
+  - `var >= "lower_bound"` / `var > "lower_bound"` — also triggers an **`O(log N)` B+Tree lower-bound seek** on `Sorted_Map` / `Sorted_Set` keys!
   - `contains(var, "substring")`
 - **Negation:** `not <clause>` (e.g. `not u.flags.set_member("suspended")`, `not u.deleted_at`, or `not (u.role == "guest")`)
 
````
