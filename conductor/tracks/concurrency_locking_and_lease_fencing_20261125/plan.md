# Track Plan: Concurrency Locking, Write-Epoch Lease Fencing & Crash-Safe Rollback

## Implementation & Verification

- [x] Sync `native/xitdb-odin` submodule to `8302dcd` (`flock(LOCK_EX | LOCK_NB)` before `.Trunc`, `Core_Buffered_File` mid-file read fix, `os.truncate` error propagation) and map `.File_Locked` to `:file_locked` in `native/xitdb_nif.odin`.
- [x] Implement monotonic `write_epoch` fencing (`Xitdb.bump_write_epoch/1`, 5-arg `nif_transact/5`, `:stale_write_epoch` -> `%Xitdb.Ash.LeaseError{reason: :lease_expired}`) across `Xitdb.Ash.Store` and `Xitdb.Ash.TestSandbox`.
- [x] Reorder `rollback_failed_tx` to restore/fsync header `file_size` before tail truncation, check `core_sync` in `odin_nif_compact`, and add `Xitdb.Ash.Store.swap_compacted_base/4`.
- [x] Un-clamp `state.lease_timeout` from caller `opts[:timeout]` and resolve negative moments in `Xitdb.Ash.Store.Snapshot.as_of/2` and `Xitdb.Columnar`.
- [x] Add `Xitdb.CacheHeir` ETS heir supervision for `:xitdb_page_cache` / `:xitdb_dict_cache` and `TestSandbox.Coordinator` monitor/ETS cleanup for `allow/3`.
- [x] Verify `odin check`, `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, and `mix precommit` (384/384 passed) + GitHub CI checks on `boxxxie/xitdb-elixir#15`.

## Remaining Pre-Release Items

- [ ] Fix Windows CI failure on `boxxxie/odin-xitdb#14` and merge into `boxxxie/odin-xitdb` `master`.
- [ ] Merge `boxxxie/xitdb-elixir#15` into `master` and publish Hex release.
