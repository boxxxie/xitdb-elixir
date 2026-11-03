# Specification: Odin C-ABI NIF Core, `ErlNifResourceType` Lifecycle & Coarse-Grained ETF Bridge

## Overview
Implement the native C-ABI bridge (`native/nif_entry.c` + `native/xitdb_nif.odin`) linking `native/xitdb-odin/xitdb` into an Erlang NIF shared library (`priv/xitdb_nif.so`).

## Architecture & Scope
1. **`ErlNifResourceType` Database Handle:**
   - Wrap `xitdb.Core` (`Core_Memory`, `Core_File`, `Core_Buffered_File`) and `xitdb.Database` inside a reference-counted NIF resource equipped with a RWLock (`ErlNifRWLock`) for safe concurrent multi-reader access and serialized single-writer transactions.
   - Register a resource destructor (`dtor`) that cleanly closes OS file descriptors and frees `Core_Memory` buffers when the last BEAM reference is garbage-collected.
2. **Explicit Odin Context & Scratch Allocator Management:**
   - Initialize `context = runtime.default_context()` and `defer free_all(context.temp_allocator)` in every `@(export) proc "c"` entrypoint.
3. **Direct `ERL_NIF_TERM` Construction:**
   - Expose C-ABI helpers in `native/nif_entry.c` for constructing atoms, 64-bit integers, floats, binaries, tuples, lists, and maps directly on the caller's `ErlNifEnv` without intermediate string parsing.
   - Represent container slots as `{:cursor, tag_atom, offset_int}` tuples so the Elixir wrapper can wrap them into `%Xitdb.Cursor{}` structs in $O(1)$ time.
