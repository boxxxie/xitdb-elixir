# Implementation Plan: Track 7 — Single-Writer Store GenServer, Monitored Writer Leases, Savepoints & TestSandbox

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `ash_store_and_test_sandbox_20261111`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Reference Document:** [`./reference.md`](./reference.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Done When:** Comprehensive test suite passes with zero warnings, verifying lease FIFO ordering, zombie-commit rejection, savepoint hygiene, boot-time reverse-FK graph compilation, and `async: true` test sandbox isolation.

---

## Phase 1: Shared `LeaseQueue` & `LeaseError`

- [ ] Task: Implement `Xitdb.Ash.LeaseError` exception in `lib/xitdb/ash/store.ex`
    - [ ] Handle `:lease_timeout` and `:lease_expired` reasons
- [ ] Task: Implement `Xitdb.Ash.Store.LeaseQueue`
    - [ ] `new/0`, `acquire/7`, `cancel_waiter/2`, `verify_holder/3`, `release_and_grant_next/3`
    - [ ] `handle_down/4` and `handle_expired/4` with timer and monitor flushing
    - [ ] FIFO waiter queue handling with monotonic timestamp expiration checks

---

## Phase 2: `Xitdb.Ash.Store` GenServer & Writer Lease Engine

- [ ] Task: Implement `Xitdb.Ash.Store` GenServer lifecycle and `NimbleOptions` schema
    - [ ] Options: `:name`, `:path`, `:db`, `:domains`, `:resources`, `:lease_timeout`
    - [ ] Macro `__using__/1` generating `child_spec/1`, `start_link/1`, `transact/2`, `rollback/1`, `current_db/0`
    - [ ] Snapshot publication via `Snapshot.put_base/3` at boot
- [ ] Task: Implement boot-time reverse foreign-key graph compiler
    - [ ] Parse `domains` and `resources` for `belongs_to` relationships and `references`
    - [ ] Auto-synthesize `:delete` cleanup rules for `nested_in` child collections
    - [ ] Enforce same-store boundary check for foreign key cascades
- [ ] Task: Implement monitored writer lease protocol & savepoints
    - [ ] `transact/3` routing into leased transaction, savepoint, or sandbox
    - [ ] `mutate/3` pure mutation helper (`db -> {:ok, new_db, result} | {:error, reason}`)
    - [ ] Cross-store savepoint rollback hygiene (`{:xitdb_ash_rollback, ^store, reason}`)
    - [ ] Telemetry event emission for `[:xitdb, :ash, :transaction]`

---

## Phase 3: `Xitdb.Ash.TestSandbox` & `TestSandbox.Coordinator`

- [ ] Task: Implement `Xitdb.Ash.TestSandbox` in `lib/xitdb/ash/test_sandbox.ex`
    - [ ] Public ETS table lifecycle for `@templates_table` and `@checkouts_table`
    - [ ] `init/0`, `seed_template/2`, `checkout/2`, `checkin/2`, `allow/3`
    - [ ] Lock-free `checkout_db/1` resolving `[self() | Process.get(:"$callers", [])]`
- [ ] Task: Implement `Xitdb.Ash.TestSandbox.Coordinator` GenServer
    - [ ] Per-test coordinator managing isolated CoW `%Xitdb{}` handles and `LeaseQueue`
    - [ ] Monitor test owner process and auto-cleanup checkouts on exit
    - [ ] `ExUnit.Callbacks.on_exit/2` hook registration

---

## Phase 4: Test Suite & Verification

- [ ] Task: Implement `test/xitdb/ash/store_test.exs`
    - [ ] Verify FIFO lease acquisition under high concurrency
    - [ ] Verify crash recovery (`:DOWN`) and lease timeout expiration
    - [ ] Verify nested savepoints and cross-store rollback hygiene
    - [ ] Verify implicit `nested_in` reverse-FK graph synthesis
- [ ] Task: Implement `test/xitdb/ash/test_sandbox_test.exs`
    - [ ] Verify concurrent test isolation with `async: true`
    - [ ] Verify `$callers` propagation in `Task.async` and `Task.Supervisor`
    - [ ] Verify explicit `allow/3` for unlinked processes
    - [ ] Verify zombie-commit prevention during test lease expiration
- [ ] Task: Run `mix precommit` and ensure zero warnings and clean formatting
