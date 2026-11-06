# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-11-06

### Added
- Initial release of `Xitdb` Elixir client wrapping `odin-xitdb` via a C-ABI Erlang NIF (`priv/xitdb_nif.so`).
- Lazy 9-byte `Slot` cursor (`%Xitdb.Cursor{}`) implementing `Access`, `Enumerable` ($O(1)$ `count/1`, $O(1)$ `member?/2`, $O(\log N)$ `slice/2`, chunked `reduce/3`), and `Inspect`.
- Coarse-grained transactions (`Xitdb.transact/3`) supporting both nested Elixir maps/collections and `put_in/3` / `update_in/3` / `pop_in/2` cursor pipelines.
- Time-travel snapshots (`Xitdb.db/1`, `Xitdb.as_of/2`), structural diffs (`Xitdb.diff_moments/3`), and attribute lineage (`Xitdb.history_of/2`).
- Compile-time validated selector (`~x`) and Datalog (`~q`) sigils, Datomic-style `Xitdb.pull/2` projections, and Datalog queries (`Xitdb.query/3`) with B+Tree secondary index pushdown and grouped aggregations.
- Spark DSL extension (`Xitdb.Ash.Resource`), introspection (`Xitdb.Ash.Info`), transformer (`Xitdb.Ash.Transformers.WireChanges`), verifier (`Xitdb.Ash.Verifiers.VerifySyncProjection`), and declarative transaction macros (`Xitdb.Ash.Tx.tx_for`, `tx_for!`).
- 4-layer Client ATDD executable specification suite (`test/features/*_spec.exs`) and `StreamData` property tests.
- 1v1 Client Statistical Benchmark Suite (`benchmarks/`) comparing the Elixir NIF wrapper against Raw Odin across 16 client workloads.
