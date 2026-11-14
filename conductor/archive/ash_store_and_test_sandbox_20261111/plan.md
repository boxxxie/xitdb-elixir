# Implementation Plan: Track 10 — Single-Writer Store GenServer, Monitored Writer Leases, Savepoints & TestSandbox

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_store_and_test_sandbox_20261111`
> - **Wave:** Wave 2
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Comprehensive test suite passes with zero warnings, verifying `{db, moment}` snapshot pinning, lease FIFO ordering, zombie-commit rejection, file-backed rollback tip restoration, savepoint hygiene, boot-time reverse-FK graph compilation, and `async: true` isolated test sandboxing.

---

## Phase 1: Shared `LeaseQueue` & `LeaseError`

- [x] Task: Implement `Xitdb.Ash.LeaseError` exception (in `lib/xitdb/ash/lease_error.ex`)
    - [x] Handle `:lease_timeout` and `:lease_expired` reasons
- [x] Task: Implement `Xitdb.Ash.Store.LeaseQueue` (in `lib/xitdb/ash/store/lease_queue.ex`)
    - [x] `new/0`, `acquire/7`, `cancel_waiter/4`, `verify_holder/3`, `release_and_grant_next/3`
    - [x] Store `req_ref` on `active_lease` so `cancel_waiter/4` releases an active lease and wakes the next waiter if a caller timed out at the exact instant the lease was granted
    - [x] `handle_down/4` and `handle_expired/4` with timer and monitor flushing
    - [x] FIFO waiter queue handling with monotonic timestamp expiration checks

---

## Phase 2: `Xitdb.Ash.Store` GenServer, `{db, moment}` Backend & Writer Lease Engine

- [x] Task: Implement `Xitdb.Ash.Store` GenServer lifecycle and `NimbleOptions` schema
    - [x] Options: `:name`, `:path`, `:db`, `:domains`, `:resources`, `:lease_timeout`
    - [x] `Backend.open_db!/1` opening `:memory` via `Xitdb.open!(backend: :memory)` and file paths via `Xitdb.open!(backend: :buffered_file, path: path)`
    - [x] `Backend.ensure_seeded!/1` seeding moment `0` (`[{:init_col, ".meta", "hash_map"}]`) when `Xitdb.moment_count(db) == 0` so `moment >= 0` always holds
    - [x] Macro `__using__/1` generating `child_spec/1`, `start_link/1`, `current_db/0`, `root/0`, `in_transaction?/0`, `transact/2`, `mutate/2`, `rollback/1`
    - [x] Snapshot publication via `Snapshot.put_base/3` at boot and `Backend.publish_commit(store, prev_moment, new_moment)` comparing integer moments
- [x] Task: Implement boot-time reverse foreign-key graph compiler (`compile_reverse_fks/3`)
    - [x] Filter `domains` and `resources` down strictly to resources where `Ash.Resource.Info.data_layer(resource) == Xitdb.Ash.DataLayer` and `Xitdb.Ash.Info.store(resource)` matches `store_mod` (`store_mod` or `{:ok, store_mod}`) so co-located `AshPostgres`, `:embedded`, or `Simple` resources do not crash `Store.init/1`
    - [x] Emit canonical `%{source_resource, source_collection, source_attribute, destination_attribute, on_delete, nested?}` rule maps aligned with `Snapshot`, `Mutator`, and `Indexer`
    - [x] Wire `build_nested_fk_rules/3` cleanly over `Info.nested_in/1` / `Info.nested_mappings/1` (returning `[]` when empty in Wave 2 and activating automatically in Wave 3 Track 11B with zero unused-function warnings)
- [x] Task: Implement monitored writer lease protocol, savepoints & file-backed rollback restoration
    - [x] `transact/3` routing into leased transaction, savepoint, or sandbox with `{db, moment}` working state (`{:xitdb_tx_state, store}`) and pinned `%Xitdb.Cursor{}` reader snapshot (`{:xitdb_tx_db, store}`)
    - [x] `mutate/3` pure mutation helper (`{db, moment} -> {:ok, {new_db, new_moment}, result} | {:error, reason}`)
    - [x] Non-blocking `GenServer.cast(store, {:abort_lease, lease_ref, self()})` on rollback/raise so exhausted `call_timeout` budgets never mask caller exceptions
    - [x] `Backend.reconcile_tip/2` branching a lightweight restore commit from `base_moment: target_moment` whenever uncommitted moments exist at the tail of `db` after an abort or inner savepoint rollback
    - [x] Telemetry event emission for `[:xitdb, :ash, :transaction]`

---

## Phase 3: `Xitdb.Ash.TestSandbox` & `TestSandbox.Coordinator`

- [x] Task: Implement `Xitdb.Ash.TestSandbox` in `lib/xitdb/ash/test_sandbox.ex`
    - [x] Public ETS table lifecycle for `@templates_table` and `@checkouts_table` with `{:heir, Process.whereis(:kernel_sup), nil}` so tables survive dynamic `async: true` caller exits
    - [x] Per-checkout isolated `:memory` handle cloning via `Xitdb.compact!/1` + `Backend.ensure_seeded!/1` so `async: true` tests never mutate a shared `db_ref`
    - [x] `init/0`, `seed_template/2`, `checkout/2`, `checkin/2`, `allow/3`
    - [x] Lock-free `checkout_db/1` resolving `[self() | Process.get(:"$callers", [])]` to a pinned `%Xitdb.Cursor{}` (`Xitdb.as_of(db, moment)`)
- [x] Task: Implement `Xitdb.Ash.TestSandbox.Coordinator` GenServer
    - [x] `Process.flag(:trap_exit, true)` in `init/1` and `Xitdb.close/1` cleanup in `terminate/2`
    - [x] Clamp `lease_timeout = min_timeout(state.lease_timeout, call_timeout)` on `:acquire` and support cast-based `:abort`
    - [x] Monitor test owner process, purge ETS entries, and register `ExUnit.Callbacks.on_exit/2` hook

---

## Phase 4: Test Suite & Verification

- [x] Task: Implement `test/xitdb/ash/store_test.exs`
    - [x] Verify FIFO lease acquisition and waiter timeout race cancellation under concurrency
    - [x] Verify crash recovery (`:DOWN`), lease timeout expiration, and file-backed `.xit` tip restoration on rollback
    - [x] Verify nested savepoints and cross-store rollback hygiene
    - [x] Verify boot-time reverse-FK rule key alignment (`source_resource`, `source_collection`, `source_attribute`, `destination_attribute`, `on_delete`, `nested?`)
- [x] Task: Implement `test/xitdb/ash/test_sandbox_test.exs`
    - [x] Verify concurrent test isolation with `async: true` using isolated `:memory` handles
    - [x] Verify ETS `:heir` resilience when first initializing process exits
    - [x] Verify `$callers` propagation in `Task.async` and `Task.Supervisor`, plus explicit `allow/3`
    - [x] Verify zombie-commit prevention during test lease expiration
- [x] Task: Run `mix precommit` and ensure zero warnings and clean formatting
