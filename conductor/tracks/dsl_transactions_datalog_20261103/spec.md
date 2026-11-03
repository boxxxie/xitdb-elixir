# Specification: Transactions, Time-Travel, Pull, Datalog & Compile-Time Sigils

## Overview
Expose `xitdb-odin`'s 5-layer DSL, transactional batch engine, temporal diffing/history, and Datalog engine through an idiomatic Elixir API with compile-time sigils (`~x` and `~q`).

## Functional Requirements
1. **Coarse-Grained Transactions (`Xitdb.transact/2`):**
   - Accept nested Elixir map/list trees, `put_in`/`update_in`/`pop_in` transformations on the root cursor, or declarative operation lists (`[{:put, ".users.alice.name", "Alice"}, {:delete, ".users.bob"}]`), committing atomically in a single NIF call.
   - Roll back cleanly if the callback raises or returns `{:abort, reason}`.
2. **Time-Travel & Temporal Lineage (`as_of`, `diff_moments`, `history_of`):**
   - `Xitdb.db(conn)` returns the latest committed moment cursor; `Xitdb.as_of(conn, moment_idx)` pins a cursor to historical moment `moment_idx` (supporting negative indices like `-1`).
   - `Xitdb.diff_moments(conn, moment_a, moment_b, selector \\ "")` returns structural diffs (`[%{path: ..., kind: :added | :removed | :modified, old_value: ..., new_value: ...}]`).
   - `Xitdb.history_of(conn, selector)` returns `[%{moment_index: i, exists: bool, value: term}]`.
3. **Selectors, Pull Projections, and Datalog Queries:**
   - `Xitdb.Sigils` (`import Xitdb.Sigils`): `~x".users.alice.roles[0]"` and `~q"[:find ?e ?name :where [?e .name ?name]]"` validated at compile time.
   - `Xitdb.select(db_or_cursor, selector)`
   - `Xitdb.pull(db_or_cursor, selector, pattern)`
   - `Xitdb.query(db_or_cursor, datalog_query, inputs \\ [])`
4. **Compaction (`Xitdb.compact/2`):**
   - Garbage-collecting compaction (`Xitdb.compact(conn, target_path, opts)`).
