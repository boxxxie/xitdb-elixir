# Specification: Track 7 — Single-Writer Store GenServer, Monitored Writer Leases, Savepoints & TestSandbox

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_store_and_test_sandbox_20261111`
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules:** `lib/xitdb/ash/store.ex`, `lib/xitdb/ash/test_sandbox.ex`
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Unit and concurrency test suites for `Store` and `TestSandbox` pass with zero warnings, verifying lease timeouts, zombie-commit protection, cross-store savepoint hygiene, implicit `nested_in` cascade compilation, and async CoW test isolation.

---

## 1. Goal & Architecture

`Xitdb` allows unlimited concurrent lock-free readers via immutable point-in-time snapshots, but requires a single serialized writer per store to guarantee monotonic moment progression without disk corruption or file locking conflicts.

`Xitdb.Ash.Store` and `Xitdb.Ash.TestSandbox` provide the single-writer transaction management, lease queueing, and test isolation architecture:

1. **Shared `LeaseQueue` with Zombie-Commit Protection:**
   Both production `Store` processes and per-test `TestSandbox.Coordinator` processes share `Xitdb.Ash.Store.LeaseQueue`. If a caller crashes (`:DOWN`) or exceeds `lease_timeout`, the uncommitted working handle is discarded and stale `lease_ref` tokens are rejected with `Xitdb.Ash.LeaseError` so a hung caller can never overwrite a later transaction.

2. **Monitored Caller-Process Writer Lease (`Store.transact/3`):**
   Instead of funneling mutation payloads through a GenServer message mailbox (which serializes terms and loses caller context), callers request an exclusive lease. The transaction closure executes inside the caller process:
   - Preserves `self()`, `$callers`, Swoosh sandboxes, and Task links.
   - Preserves process dictionary keys across multiple stores (enabling cross-store multi-transaction coordinators).
   - If the caller crashes or times out, the GenServer detects the monitor `{:DOWN, ref, :process, ...}` and resets the lease safely.

3. **Cross-Store Savepoint Hygiene & Rollback:**
   `Store.rollback/2` throws `{:xitdb_ash_rollback, store, reason}`. If a nested transaction across `MDM.Store` and `AppStore` aborts the outer store from inside the inner store's block, the inner store restores its own `prev_db` before re-throwing the outer store's rollback tag.

4. **Implicit `nested_in` Index Cleanup Graph:**
   At boot, `Store` compiles incoming `references` across `domains` and automatically synthesizes `:delete` cleanup entries for `nested_in` children (unless overridden with `:restrict`), ensuring parent deletes purge child `_parent`, secondary, identity, and `idx.search` entries.

5. **Per-Test Lease Serialization + Lock-Free ETS Reads (`Xitdb.Ash.TestSandbox`):**
   `TestSandbox` serves `Snapshot.current_db/1` reads directly from a public `read_concurrency: true` ETS table while serializing concurrent writes *within* the same test (`Task.async_stream`, LiveView + async tasks) via a per-checkout coordinator—giving production-identical single-writer guarantees with zero cross-test contention under `async: true`.

---

## 2. Technical Invariants

- **Lease Exclusivity & Expiration:** Stale lease holders are strictly prevented from committing via `LeaseQueue.verify_holder/3` and unique `lease_ref` references.
- **Pure Mutation Helper:** `Store.mutate/3` accepts pure `db -> {:ok, new_db, result} | {:error, reason}` functions, executing either inside an existing lease or wrapping in `transact/3` automatically.
- **Zero-GC Moment Publication:** Upon commit, `Backend.publish_commit/3` advances `Snapshot` moment in ~5ns without global GC.
- **Process Dict Storage:** During an active lease, `Process.get({:xitdb_tx_db, store})` returns the active working handle, intercepted by `Snapshot.current_db/1`.
- **ETS Sandbox Lookup:** In tests, `TestSandbox.checkout_db/1` inspects `[self() | Process.get(:"$callers", [])]` and explicit `allow/3` mappings in `O(1)` without messaging any GenServer.

---

## 3. Acceptance Criteria

1. Concurrent callers competing for `Store.transact/3` serialize correctly in FIFO order via `LeaseQueue`.
2. Writer crash (`:DOWN`) or lease timeout triggers `LeaseError` and safely hands the lease to the next waiting caller.
3. Nested savepoints rollback locally without aborting outer transaction modifications.
4. Cross-store rollbacks restore intermediate stores' savepoints cleanly.
5. Boot-time reverse-FK compilation auto-generates `:delete` cleanup rules for `nested_in` child entities.
6. `TestSandbox` allows concurrent test processes running with `async: true` to mutate independent CoW stores simultaneously with zero collision or locking errors.
