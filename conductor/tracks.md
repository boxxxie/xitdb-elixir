# Project Tracks

This file tracks all major development tracks for the `xitdb` Elixir client (`elixir/xitdb`). Each track has its own specification and implementation plan in [`./tracks/`](./tracks/).

---

- [x] **Track 1: 4-Layer ATDD Client Specification Suite & 1v1 Client Benchmark Harness (Elixir Wrapper vs. Raw Odin)**
  *Link: [./tracks/atdd_client_bench_20261103/](./tracks/atdd_client_bench_20261103/)*

---

- [x] **Track 2: Odin C-ABI NIF Core, `ErlNifResourceType` Lifecycle & Coarse-Grained ETF Bridge**
  *Link: [./tracks/nif_c_abi_core_20261103/](./tracks/nif_c_abi_core_20261103/)*

---

- [x] **Track 3: Clojure-Style Lazy `%Xitdb.Cursor{}` (`Access`, `Enumerable`, `Inspect`, Chunked Iteration & Collection Type Wrappers)**
  *Link: [./tracks/lazy_cursor_protocols_20261103/](./tracks/lazy_cursor_protocols_20261103/)*

---

- [x] **Track 4: Ergonomic Transactions (`put_in`/`update_in`), Time-Travel (`as_of`, `diff_moments`, `history_of`), Pull, Datalog & Compile-Time Sigils (`~x`, `~q`)**
  *Link: [./tracks/dsl_transactions_datalog_20261103/](./tracks/dsl_transactions_datalog_20261103/)*

---

- [ ] **Track 5: `Xitdb.Ash.DataLayer` Engine (Ash 3 DataLayer, Store GenServer, Test Sandbox & Verification Suite)**
  *Link: [./tracks/ash_datalayer_engine_20261111/](./tracks/ash_datalayer_engine_20261111/)*
