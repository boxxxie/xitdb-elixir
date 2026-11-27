# Project Tracks

This file tracks active development tracks for the `xitdb` Elixir client (`elixir/xitdb`), ordered in recommended execution order.

Completed tracks (**Waves 0–5**, benchmark/optimization tracks, **bugfix slices 01–07**, **Elixir 1.20.5 / OTP 29.1.2 upgrade**, **ExFuzz coverage-guided fuzzing**, **`odin-xitdb` parity & release sync**, **domain datatypes & range keys**, and **Parquet-style columnar & transparent blob compression**) are archived locally under `./archive/` (gitignored).

---

- [~] **Track: Mutation Testing Hardening (`v2.5.1` Baseline -> >= 75% Score)**
  *Link: [./tracks/mutation_hardening_v2_5_1_20261127/](./tracks/mutation_hardening_v2_5_1_20261127/)*

- [x] **Track: Standardized Fallback Helper & Anti-Success-Shaped-Fallback Guardrails**
  *Link: [./tracks/standardized_fallback_helper_20261126/](./tracks/standardized_fallback_helper_20261126/)*

- [x] **Track: Concurrency Locking, Write-Epoch Lease Fencing & Crash-Safe Rollback** *(PR #15 — `fix/concurrency-locking-and-lease-fencing`)*
  *Link: [./tracks/concurrency_locking_and_lease_fencing_20261125/](./tracks/concurrency_locking_and_lease_fencing_20261125/)*
