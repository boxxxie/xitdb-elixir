# Specification: Clojure-Style Lazy `%Xitdb.Cursor{}` & Elixir Protocols

## Overview
Implement `%Xitdb.Cursor{}` as an immutable, pure-value Elixir struct holding a NIF database reference and a 9-byte `Slot` (`tag` + `value`) that implements `Access`, `Enumerable`, and `Inspect`.

## Functional Requirements
1. **`Access` Behaviour (`fetch/2`, `get_and_update/3`, `pop/2`):**
   - String/atom key lookup on `:hash_map`, `:counted_hash_map`, and `:sorted_map`.
   - Integer index lookup (including negative indices from the end) on `:array_list` and `:linked_array_list`.
   - Seamless composition with `Kernel.get_in/2`, `put_in/3`, `update_in/3`, `pop_in/2`, `Access.at/1`, `Access.all/0`, and `Access.filter/1`.
2. **`Enumerable` Protocol (`count/1`, `member?/2`, `slice/1`, `reduce/3`):**
   - $O(1)$ `count/1` on `:counted_hash_map`, `:sorted_map`, `:array_list`, `:linked_array_list`, `:counted_hash_set`, and `:sorted_set`.
   - $O(1)$ / $O(\log N)$ `member?/2` on sets and maps via native HAMT/B+Tree lookup.
   - $O(\log N)$ `slice/1` on `:array_list` and `:linked_array_list`.
   - Chunked `reduce/3` streaming elements in batches across the NIF boundary.
3. **`Inspect` Protocol & `Xitdb.materialize/1`:**
   - Safe, bounded `Inspect` representation showing collection kind, count, and a preview of elements.
   - `Xitdb.materialize/1` converting any cursor subtree into native Elixir maps, lists, and `MapSet`s.
4. **Collection Type Wrappers:**
   - `Xitdb.hash_map/1`, `Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.array_list/1`, `Xitdb.linked_list/1`, `Xitdb.hash_set/1`, `Xitdb.counted_set/1`, `Xitdb.sorted_set/1`.
