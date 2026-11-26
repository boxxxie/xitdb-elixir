# Track Spec: Concurrency Locking, Write-Epoch Lease Fencing & Crash-Safe Rollback

## Context
Addresses concurrency, lease-fencing, rollback durability, and cache/sandbox safety issues surfaced during MDM write-concurrency and crash-recovery hardening (`boxxxie/xitdb-elixir#15`, `fix/concurrency-locking-and-lease-fencing`, `07a3d31`), backed by `native/xitdb-odin` `8302dcd` (`boxxxie/odin-xitdb#14`).

## Scope & Hardening Areas

1. **Cross-Process Exclusive `flock` & `Core_Buffered_File` Fixes** (`native/xitdb-odin/xitdb/core*.odin`, `native/xitdb_nif.odin`)
   - Writable opens acquire a non-blocking exclusive OS `flock(LOCK_EX | LOCK_NB)` before applying `.Trunc`, preventing contending writers from corrupting or wiping active `.xit` files and returning `{:error, %Xitdb.Error{reason: :file_locked}}`.
   - Fix `Core_Buffered_File` mid-file reads (`core_read_at`, `core_read_short_at`, `core_read_block_at`) to fall through to disk instead of returning premature `EOF`, and propagate `os.truncate` errors on writable handles.

2. **Monotonic NIF `write_epoch` Lease Fencing** (`Xitdb`, `Xitdb.NIF`, `Xitdb.Ash.Store`, `Xitdb.Ash.TestSandbox`, `native/xitdb_nif.odin`)
   - Add `write_epoch` to `Db_Handle` (`Xitdb.bump_write_epoch/1`) and enforce it under the NIF write lock in 5-arg `nif_transact/5`.
   - Stamp `%Xitdb{write_epoch: epoch}` on lease grant; bump `write_epoch` before reconciling on commit, abort, expiry, waiter cancel, `DOWN`, and `terminate`.
   - Normalize `:stale_write_epoch` errors to `%Xitdb.Ash.LeaseError{reason: :lease_expired}` so zombie writers cannot commit after lease loss.

3. **Crash-Safe Rollback & Atomic Compaction Swap** (`native/xitdb_nif.odin`, `Xitdb.Ash.Store`)
   - Restore and fsync the committed 8-byte header `file_size` in `rollback_failed_tx` before truncating tail bytes.
   - Check `core_sync` errors in `odin_nif_compact` and clean up on failure.
   - Add `Xitdb.Ash.Store.swap_compacted_base/4` to atomically swap a compacted `%Xitdb{}` handle inside an exclusive lease.

4. **Lease Timeout & Negative-Moment Resolution** (`Xitdb.Ash.Store`, `Xitdb.Ash.Store.Snapshot`, `Xitdb.Columnar`)
   - Stop clamping `state.lease_timeout` to short caller `opts[:timeout]` values.
   - Resolve negative moments (`-1`, `-2`, ...) relative to the caller's visible snapshot in `Snapshot.as_of/2` and to concrete moment indices before keying `:xitdb_page_cache` in `Columnar`.

5. **ETS Cache Survival & `TestSandbox` Monitor Cleanup** (`Xitdb.CacheHeir`, `Xitdb.CacheOwner`, `Xitdb.Ash.TestSandbox`)
   - Add `Xitdb.CacheHeir` as the ETS `:heir` for `:xitdb_page_cache` and `:xitdb_dict_cache` and retry `CacheOwner.ensure_started/0` pings under supervision.
   - Route `TestSandbox.allow/3` through `Coordinator` with deduplicated `Process.monitor` cleanup on `:DOWN`/checkin and lazy purging of stale `:allow`/`:shared` ETS entries.
