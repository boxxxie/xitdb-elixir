# Implementation Plan: `dsl_transactions_datalog_20261103`

## Phase 1: Batch Transactions & Time-Travel
- [x] Task: Implement `Xitdb.transact/2` and `Xitdb.transact!/2` supporting callback mutations (`put_in`/`update_in`/`pop_in`) and batch op lists.
- [x] Task: Implement `Xitdb.db/1`, `Xitdb.as_of/2`, `Xitdb.moment_count/1`, `Xitdb.diff_moments/4`, and `Xitdb.history_of/2`.

## Phase 2: Selectors, Pull, Datalog & Sigils
- [x] Task: Implement `Xitdb.Sigils` (`~x` and `~q`) with compile-time validation.
- [x] Task: Implement `Xitdb.select/2`, `Xitdb.pull/3`, `Xitdb.query/3`, and `Xitdb.compact/2`.
