# Implementation Plan: Slice 04 Bugfixes

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `slice_04_bugfixes_20261116`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Bug Reference:** [`./bugs.md`](./bugs.md)
> - **Done When:** All `BUG-04-01`..`BUG-04-04` items are resolved and verified.

## Resolved Bugs

- [x] `BUG-04-01` (`critical`): `odin_nif_transact` rollback risks `Root_Header` corruption via `database_write_root_header`, skips `core_sync`, and ignores rollback errors
- [x] `BUG-04-02` (`high`): Off-by-one `MAX_WRITE_DEPTH` (`64`) between single-pass writers (accepting 65-level scalar/nil maps) and `is_pure_removal_term` / `validate_write_term_cold`
- [x] `BUG-04-03` (`high`): Forged `%MapSet{map: ...}` structs bypass `nif_is_map` and `ATOM_STRUCT` checks in set writers and validators
- [x] `BUG-04-04` (`high`): Unchecked `temp_allocator` allocation in `extract_map_kvs` can pass `NULL` buffers into `nif_map_to_kv_arrays` (`SIGSEGV`)
