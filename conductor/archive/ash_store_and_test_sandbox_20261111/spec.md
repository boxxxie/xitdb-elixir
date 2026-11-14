# Specification: Track 10 — Single-Writer `Xitdb.Ash.Store` GenServer, Monitored Writer Leases, Savepoints & `TestSandbox`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_store_and_test_sandbox_20261111`
> - **Wave:** Wave 2
> - **Prerequisite:** [`ash_dsl_and_verifiers_20261111`](../ash_dsl_and_verifiers_20261111/index.md) (unified `Xitdb.Ash.{Info,Reference,NestedIn}` contracts and staged `lib/xitdb/ash/store/snapshot.ex` baseline)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules:** `lib/xitdb/ash/store.ex`, `lib/xitdb/ash/test_sandbox.ex` (building atop `lib/xitdb/ash/store/snapshot.ex`)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Done When:** Unit and concurrency test suites for `Store` and `TestSandbox` pass with zero warnings, verifying `{db, moment}` snapshot pinning, lease timeouts, active-lease waiter cancellation, zombie-commit protection, file-backed `.xit` rollback safety, cross-store savepoint hygiene, boot-time reverse-FK compilation, and async isolated `:memory` handle sandboxing.

---

## 1. Goal & Architecture

`Xitdb` allows unlimited concurrent lock-free readers via immutable point-in-time snapshots (`%Xitdb.Cursor{moment: moment}`), while requiring a single serialized writer per store to guarantee monotonic moment progression without disk corruption or file locking conflicts.

`Xitdb.Ash.Store` and `Xitdb.Ash.TestSandbox` provide the single-writer transaction management, lease queueing, and test isolation architecture:

1. **`{db, moment}` Snapshot Pinning & File-Backed Rollback Hygiene:**
   Because `%Xitdb{}` wraps an append-only native `db_ref` handle, mutating `db` via `Xitdb.transact_ops/3` appends a new moment without changing the Elixir `%Xitdb{}` struct term. Both `Store` and `TestSandbox.Coordinator` pin state to `{db, moment}` (seeding moment `0` via `[{:init_col, ".meta", "hash_map"}]` when `Xitdb.moment_count(db) == 0`), branch every write explicitly from `base_moment: moment`, publish pinned `%Xitdb.Cursor{}` snapshots (`Xitdb.as_of(db, moment)`) to `{:xitdb_tx_db, store}` and ETS, compare `prev_moment` vs `new_moment` in `Backend.publish_commit/3`, and restore the tip moment if an aborted transaction or inner savepoint appended uncommitted moments to a `.xit` file.

2. **Shared `LeaseQueue` with Zombie-Commit & Race-Condition Protection:**
   Both production `Store` processes and per-test `TestSandbox.Coordinator` processes share `Xitdb.Ash.Store.LeaseQueue`. Active leases record `req_ref` alongside `lease_ref` so `cancel_waiter/4` cleanly revokes the active lease and wakes the next waiter even if a caller timed out in `GenServer.call/3` at the exact instant the previous holder granted it the lease. If a caller crashes (`:DOWN`) or exceeds `lease_timeout`, uncommitted moments are rolled back and stale `lease_ref` tokens are rejected with `Xitdb.Ash.LeaseError`.

3. **Monitored Caller-Process Writer Lease (`Store.transact/3`):**
   Instead of funneling mutation payloads through a GenServer message mailbox (which serializes terms and loses caller context), callers request an exclusive lease. The transaction closure executes inside the caller process:
   - Preserves `self()`, `$callers`, Swoosh sandboxes, and Task links.
   - Preserves process dictionary keys across multiple stores (enabling cross-store multi-transaction coordinators).
   - Uses cast-based lease release on abort (`{:abort_lease, lease_ref, self()}`) so an exhausted `call_timeout` never masks the inner rollback or exception.

4. **Cross-Store Savepoint Hygiene & Rollback:**
   `Store.rollback/2` throws `{:xitdb_ash_rollback, store, reason}`. If a nested transaction across `MDM.Store` and `AppStore` aborts the outer store from inside the inner store's block, the inner store restores its own `{prev_db, prev_moment}` working snapshot before re-throwing the outer store's rollback tag.

5. **Aligned Boot-Time Reverse-FK Graph (`compile_reverse_fks/3`):**
   At boot, `Store` compiles incoming same-store `references` across `domains` and `resources` using canonical `Snapshot.reverse_fk()` keys (`source_resource`, `source_collection`, `source_attribute`, `destination_attribute`, `on_delete`, `nested?`) aligned 100% with `Mutator` and `Indexer`, and wires `build_nested_fk_rules/3` over `Info.nested_in/1` / `Info.nested_mappings/1` (returning `[]` when no `nested_in` is configured in Wave 2 and activating seamlessly in Wave 3 Track 11B with zero unused-function warnings).

6. **Per-Test Isolated Handle Cloning + Lock-Free ETS Reads (`Xitdb.Ash.TestSandbox`):**
   `TestSandbox` clones an independent `:memory` `%Xitdb{}` handle per test checkout via `Xitdb.compact!/1` so `async: true` tests never mutate a shared `db_ref`, protects `@templates_table` and `@checkouts_table` with `{:heir, Process.whereis(:kernel_sup), nil}`, serves `Snapshot.current_db/1` reads directly from ETS (`read_concurrency: true`), and closes sandbox handles in `Coordinator.terminate/2`.

---

## 2. Technical Invariants

- **Lease Exclusivity & Expiration:** Stale lease holders are strictly prevented from committing via `LeaseQueue.verify_holder/3` and unique `lease_ref` references.
- **Working Snapshot Tuple (`{db, moment}`):** `Store.mutate/3` passes `{db, moment}` to pure mutation functions `({db, moment} -> {:ok, {new_db, new_moment}, result} | {:error, reason})`, updating both `{:xitdb_tx_state, store}` (`{new_db, new_moment}`) and `{:xitdb_tx_db, store}` (`Xitdb.as_of(new_db, new_moment)`).
- **Root Cursor Convenience (`Store.root/1`):** `Store.root(store)` (and `MyStore.root/0`) returns the active `%Xitdb.Cursor{}` root for direct inspection in tests and administrative scripts.
- **Zero-GC Moment Publication:** Upon commit, `Backend.publish_commit(store, prev_moment, new_moment)` advances `Snapshot` moment via `:atomics` in ~5ns without global GC whenever `new_moment != prev_moment`.
- **ETS Sandbox Lookup & Cleanup:** `TestSandbox.checkout_db/1` inspects `[self() | Process.get(:"$callers", [])]` and explicit `allow/3` mappings in `O(1)` without messaging any GenServer, returning a pinned `%Xitdb.Cursor{}`.

---

## 3. Acceptance Criteria

1. Concurrent callers competing for `Store.transact/3` serialize in FIFO order via `LeaseQueue`, including race-free cancellation when a waiter times out just as a lease is granted.
2. Writer crash (`:DOWN`), abort, or lease timeout triggers `LeaseError` (when applicable), restores file-backed `.xit` tip moments if uncommitted moments were appended, and safely hands the lease to the next waiting caller.
3. Nested savepoints branch from `base_moment: moment` and roll back locally without leaking uncommitted moments into outer reads or reopened `.xit` files.
4. Cross-store rollbacks restore intermediate stores' `{db, moment}` savepoints cleanly without timeout exit masking.
5. Boot-time reverse-FK compilation produces `%{source_resource, source_collection, source_attribute, destination_attribute, on_delete, nested?}` rules with zero compiler warnings.
6. `TestSandbox` isolates concurrent `async: true` test processes on independent `:memory` `%Xitdb{}` handles (`Xitdb.compact!/1`), survives dynamic caller exits via `:kernel_sup` ETS heirs, and closes handles on coordinator termination.
