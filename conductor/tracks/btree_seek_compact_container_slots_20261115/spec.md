# Specification: B+Tree Seek Compact Container Slot Packing & Direct Slot Entry Reads

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `btree_seek_compact_container_slots_20261115`
> - **Type:** Chore / Performance Optimization
> - **Target Repository:** `elixir/xitdb`
> - **Submodule Boundary:** `native/xitdb-odin` stays 100% untouched (zero API or wire divergence)
> - **Primary Files:** `native/xitdb_nif.odin`, `lib/xitdb/cursor.ex`, `lib/xitdb/ash/search.ex`, `lib/xitdb/ash/indexer.ex`, `test/xitdb/ash/search_nif_test.exs`, `benchmarks/README.md`, `benchmarks/slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md`
> - **Done When:** Container-valued `Sorted_Map` entries from `odin_nif_sorted_map_seek` emit flat 3-tuples `{key_bin, tag_id, slot_val}` (cutting BEAM heap allocations from 9 words to 4 words per entry), `Xitdb.Ash.Indexer.Storage` and `Xitdb.Ash.Search.Storage` unpack flat 3-tuples via `Xitdb.Cursor.from_compact_slot/4` (and direct `decode_slot_entries!` on the `:elixir` backend) while preserving 100% public API compatibility, `odin check` + `mix precommit` pass with zero warnings, and 1v1 benchmark `#25` + slices are updated.

---

## 1. Goal & Motivation

Every production caller of `Xitdb.NIF.nif_sorted_map_seek/5,6` in `lib/xitdb/ash/` scans container-valued B+Trees:

1. `Xitdb.Ash.Indexer.Storage.stream_index_from/4` (`stream_btree_from_key/2` in `lib/xitdb/ash/indexer.ex`): Values are `:counted_hash_set` (`tag_id == 13`) slots holding matching primary keys (`16` initial page limit, `64` subsequent page limit).
2. `Xitdb.Ash.Search.Storage.scan_prefix_cursors/4` and `scan_prefix/5` (`lib/xitdb/ash/search.ex`): Values are `:counted_hash_map` (`tag_id == 12`) posting lists (`limit = 16`).

Currently, for container-valued B+Tree entries, `odin_nif_sorted_map_seek` constructs `{key_bin, {:cursor, tag_atom, tag_id, slot_val, full_int}}`:
- Two NIF tuple allocations (**9 BEAM heap words**) per entry before constructing `%Xitdb.Cursor{}` (or reading `(db_ref, tag_id, slot_val)` via `nif_slot_entries/5`).
- Because container slots (`.Array_List`, `.Linked_Array_List`, `.Hash_Map`, `.Counted_Hash_Map`, `.Sorted_Map`, `.Hash_Set`, `.Counted_Hash_Set`, `.Sorted_Set`) never set `slot.full`, and `tag_atom` is a compile-time function of `tag_id`, emitting a flat 3-tuple `{key_bin, tag_id, slot_val}` (**4 BEAM heap words**, 1 NIF tuple allocation) cuts NIF tuple allocations in half and enables `Xitdb.Cursor.from_compact_slot/4` (and direct `nif_slot_entries/5` calls in `decode_slot_entries!`) without unpacking nested `{:cursor, ...}` 5-tuples.

---

## 2. Architectural Invariants & API Alignment

1. **Zero `odin-xitdb` Divergence:** `native/xitdb-odin/` has no Erlang NIF term awareness and remains completely untouched.
2. **Standard Public `Xitdb` & `Xitdb.Ash` APIs Unchanged:**
   - `Xitdb`, `Xitdb.Cursor`, `Xitdb.Ash.Search`, and `Xitdb.Ash.Indexer` preserve their exact public functions, structs, and return types.
   - `Xitdb.Ash.Search.Storage.scan_prefix_cursors/4` still returns `{[{String.t(), %Xitdb.Cursor{}}], String.t() | nil}` by reconstructing `%Xitdb.Cursor{}` via `Xitdb.Cursor.from_compact_slot/4`.
   - `Xitdb.Ash.Search.Storage.scan_prefix/5` still returns `[{String.t(), [{String.t(), pos_integer()}]}]`.
   - `Xitdb.Ash.Indexer.Storage.stream_index_from/4` (`stream_btree_from_key/2`) still returns a lazy stream of `{binary(), Enumerable.t()}` (yielding lazy `%Xitdb.Cursor{}` set cursors via `Xitdb.Cursor.from_compact_slot/4`).
3. **Internal NIF Return Shape (`nif_sorted_map_seek/5,6,7`):**
   - Container value slots (`is_container_tag(val_slot.tag)`): `{key_bin, tag_id, slot_val}` (flat 3-tuple).
   - Scalar value slots (`.Uint`, `.Int`, `.Float`, `.Bytes`, `.Short_Bytes`, `.None`): `{key_bin, scalar_val}` (flat 2-tuple).

---

## 3. Functional Requirements

- Update `odin_nif_sorted_map_seek` in `native/xitdb_nif.odin` to emit `{key_bin, tag_id, slot_val}` when `is_container_tag(val_slot.tag)` is true, and `{key_bin, scalar_val}` for scalar value slots.
- Add `Xitdb.Cursor.tag_atom_for/1`, `Xitdb.Cursor.from_compact_slot/4`, and a `{tag_id, val}` clause on `Xitdb.Cursor.from_nif_tuple/4` in `lib/xitdb/cursor.ex`.
- Update `Xitdb.Ash.Search.Storage` (`scan_prefix_cursors/4`, `scan_prefix/5`) in `lib/xitdb/ash/search.ex` to unpack `{term, p_tag_id, p_val}` via `Xitdb.Cursor.from_compact_slot/4` (with `decode_slot_entries!` for the `:elixir` backend).
- Update `Xitdb.Ash.Indexer.Storage.stream_btree_from_key/2` in `lib/xitdb/ash/indexer.ex` to unpack `{hex_key, set_tag_id, set_val}` via `Xitdb.Cursor.from_compact_slot/4`.
- Extend `test/xitdb/ash/search_nif_test.exs` to verify both flat 3-tuple container entries (`tag_id == 12`, direct `nif_slot_entries/5` reads) and 2-tuple scalar entries from `nif_sorted_map_seek/5,6`.

---

## 4. Technical Invariants

1. **Submodule Isolation:** `native/xitdb-odin/` stays unmodified.
2. **Odin Temp Allocator Hygiene:** `odin_nif_sorted_map_seek` retains `defer free_all(context.temp_allocator)`.
3. **Markdown MathJax Safety:** Never place underscores inside `$...$` or `$$...$$` blocks; always use inline code spans (e.g., `` `tag_id` ``, `` `slot_val` ``).
4. **Verification Gate:** `odin check` (native + benchmarks), `mix precommit`, and 1v1 benchmark regeneration must pass with zero warnings.
