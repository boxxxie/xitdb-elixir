# Xitdb Elixir Client Usage Rules

This file defines the canonical usage patterns, performance invariants, and anti-patterns for the `Xitdb` Elixir client library.

---

## 1. Lazy `%Xitdb.Cursor{}` Navigation vs. Eager Materialization

- **Default to Lazy `Access` Navigation (`db["users"]["alice"]["name"]`)**:
  - Indexing a `%Xitdb{}` handle or `%Xitdb.Cursor{}` with `cursor["key"]`, `cursor[index]`, or `get_in/2` resolves a single 9-byte `Slot` (`tag` + `value`) per step.
  - Intermediate containers (`Hash_Map`, `Counted_Hash_Map`, `Sorted_Map`, `Array_List`, `Linked_Array_List`, sets) return a new lazy `%Xitdb.Cursor{}` in $O(1)$ heap space. Leaf scalars (`String`, `Integer`, `Float`, `Boolean`, `{:tagged, tag, bin}`) decode directly into native Elixir terms.
- **Use `Xitdb.at/1` Instead of `Access.at/1` on Lazy List Cursors**:
  - Elixir's built-in `Access.at/1` guards `is_list(data)` and raises on structs. When navigating `Array_List` or `Linked_Array_List` cursors with `get_in/2` or `put_in/3`, either pass integer keys directly in the path list (`get_in(root, ["users", "alice", "roles", 1])`) or use `Xitdb.at(1)`.
- **Call `Xitdb.materialize/1` or `Xitdb.pull/2` Only at the Leaf Subtree**:
  - Never call `Xitdb.materialize(db)` on the entire database root in hot paths. Navigate to the target entity first (`user = db["users"][id]`) and then call `Xitdb.materialize(user)` or `Xitdb.pull!(user, "{name, age, roles[0..5]}")`.

---

## 2. `Enumerable` Protocol Fast Paths

`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure fast paths:
- **`Enum.count(cursor)`**:
  - Executes in **$O(1)$** on `:counted_hash_map`, `:counted_hash_set`, `:array_list`, `:linked_array_list`, `:sorted_map`, and `:sorted_set`.
  - When you need fast cardinality checks on maps or sets, wrap them at transaction time with `Xitdb.counted_map/1` or `Xitdb.counted_set/1`.
- **`Enum.member?(cursor, elem)`**:
  - Executes in **$O(1)$ / $O(\log_{16} N)$** on sets (`:hash_set`, `:counted_hash_set`, `:sorted_set`) and maps (`{key, value}` pairs) via direct HAMT/B+Tree slot lookup—never call `Enum.to_list(cursor)` before checking membership.
- **`Enum.slice(cursor, range)`**:
  - Executes in **$O(\log N + K)$** on `:array_list`, `:linked_array_list`, `:sorted_map`, and `:sorted_set` by seeking directly to the start index in the underlying Radix Trie or B+Tree.

---

## 3. Coarse-Grained Transactions (`Xitdb.transact/3`)

- **Batch Mutations into a Single `Xitdb.transact/3` Call**:
  - `xitdb` is an append-only copy-on-write store where each `Xitdb.transact/3` call commits a new top-level moment.
  - Prefer passing either a nested map (`Xitdb.transact(db, %{"users" => ...})`) or a cursor pipeline (`Xitdb.transact(db, fn root -> root |> put_in(...) |> update_in(...) end)`) so all mutations execute in a single NIF call and a single atomic moment commit.
- **Explicit Collection Wrappers**:
  - Plain Elixir maps (`%{}`) default to `:hash_map`, plain lists (`[]`) default to `:array_list`, and `%MapSet{}` defaults to `:counted_hash_set`.
  - Use `Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, `Xitdb.hash_set/1`, `Xitdb.counted_set/1`, and `Xitdb.sorted_set/1` when you need B+Tree ordering, $O(1)$ map counts, or $O(\log N)$ mid-list insertions (`Xitdb.insert_at/4`, `Xitdb.delete_at/3`).

---

## 4. Concurrency & Time-Travel Snapshots

- **`%Xitdb.Cursor{}` Is Process-Safe**:
  - You can freely pass `%Xitdb.Cursor{}` structs across `Task.async/1`, GenServers, and Phoenix LiveView processes.
- **Pin Snapshots with `Xitdb.as_of/2`**:
  - `Xitdb.db(db)` resolves the latest moment (`-1`) at the time it is called.
  - Once you have a `%Xitdb.Cursor{}` (via `Xitdb.db(db)` or `Xitdb.as_of(db, moment)`), its `Slot` is immutable and isolated from any future `Xitdb.transact/3` commits.
