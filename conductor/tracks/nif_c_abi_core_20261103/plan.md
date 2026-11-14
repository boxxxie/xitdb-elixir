# Implementation Plan: `nif_c_abi_core_20261103`

## Phase 1: C-ABI Shim & Mix Compiler
- [x] Task: Create `native/nif_entry.c` with `<erl_nif.h>` resource lifecycle (`ErlNifResourceType`, `ErlNifRWLock`) and term construction helpers.
- [x] Task: Create `Mix.Tasks.Compile.OdinNif` in `mix.exs` to compile `native/xitdb_nif.odin` (`-build-mode:obj -collection:xitdb=native/xitdb-odin/xitdb`) and link with `native/nif_entry.c` into `priv/xitdb_nif.so`.

## Phase 2: Database Lifecycle & Slot Resolution NIFs
- [x] Task: Implement `db_open`, `db_close`, `db_sync`, `db_info`, and `db_root_slot` (latest and `as_of(moment)`).
- [x] Task: Implement fast-path 9-byte `Slot` operations (`slot_get_key`, `slot_get_index`, `slot_count`, `slot_contains`, `slot_slice`, `slot_iter_chunk`, and `slot_materialize`).
