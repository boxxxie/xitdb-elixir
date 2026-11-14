# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2026-11-14

### Added
- **Native Ash Framework 3.37.2+ DataLayer (`Xitdb.Ash.DataLayer`):**
  - Full `Ash.DataLayer` implementation backed by immutable copy-on-write `.xit` files with lock-free reads, atomic updates/upserts/destroys, bulk creates/updates/destroys, relationships (`belongs_to`, `has_many`, `many_to_many`), expression and module calculations, aggregates (`count`, `exists`, `first`, `list`, `sum`, `min`, `max`, `avg`), multitenancy (`:context` and `:attribute`), and `:telemetry` spans (`[:xitdb, :ash, :query | :aggregate_query | :transaction | :search, ...]`).
  - `Xitdb.Ash.Store`: caller-supervised single-writer store publishing lock-free snapshots via `:persistent_term` and `:atomics` (~10ns reads), monitored caller-process writer leases (`Xitdb.Ash.LeaseError`), nested savepoints (`Store.transact/3`, `Store.rollback/2`, `Store.mutate/3`), and historical time-travel queries (`context: %{xitdb_moment: moment}`, `Store.as_of/2`, `Store.with_as_of/3`).
  - `Xitdb.Ash.Search`: transactional in-Xitdb BM25 and B+Tree prefix search (`search_field :name, boost: 3.0, resolver: ...`) with native Odin NIF scoring pushdown (`nif_bm25_search`), `Xitdb.Ash.Search.query/3`, `ids/3`, `sort_by_rank/2`, `reindex_records/3`, `lookup_field/4`, and historical `as_of:` support.
  - `Xitdb.Ash.TestSandbox`: lock-free isolated `:memory` `%Xitdb{}` test sandbox for `async: true` ExUnit suites (`init/0`, `seed_template/2`, `checkout/2`, `checkin/2`, `allow/3`).
  - `Xitdb.Ash.Codec`, `Xitdb.Ash.Indexer`, `Xitdb.Ash.Query`, and `Xitdb.Ash.Mutator`: binary index key encoding, single-attribute and composite B+Tree (`:sorted_map`) secondary indexes (`index [:status, :inserted_at]`), automatic `belongs_to` foreign-key indexing (`index_relationships? true`), incoming/outgoing same-store foreign-key cascades (`references` with `:nothing | :delete | :nilify | :restrict`), and co-located `nested_in` physical subtrees with reparenting and child index purging.
  - Compile-time Spark transformers and verifiers: `Xitdb.Ash.Transformers.BuildIndexPlan`, `Xitdb.Ash.Verifiers.VerifyNoSqlFragments`, and `Xitdb.Ash.Verifiers.VerifyCrossStoreReferences`.
- **Nested Sub-Collections (`nested_in`) & Expanded `Xitdb.Ash.Info` Introspection:**
  - `nested_in` entity on both `Xitdb.Ash.DataLayer` (co-located parent subtrees for 9-byte `fork` snapshots) and `Xitdb.Ash.Resource` (MDM sub-collections such as `people[id].phones[e164]` or `events[id].conference`).
  - `Xitdb.Ash.Info.nested_in/1`, `nested_mappings/1`, `nested?/1`, `nested_under/2`, `entity_paths/2`, `indexes/1`, `search_fields/1`, `references/1`, `counted_set_fields/1`, and `index_relationships?/1`.
- **Native Odin NIF Range-Seek & Client Hardening:**
  - `nif_sorted_map_seek/5,6` and `nif_bm25_search/7` NIF entrypoints supporting open-ended lower-bound B+Tree range scans (`prefix_only = 0`) and prefix-bounded scans (`prefix_only = 1`).
  - Structured `%Xitdb.Error{reason: ..., details: ...}` exception module (`Exception.message/1`) and `NimbleOptions` validation schemas across `Xitdb.open/1`, `Xitdb.transact/3`, `Xitdb.query/3`, and `Xitdb.compact/2`.
  - Root-cursor guard on `Xitdb.select/2` returning `{:error, %Xitdb.Error{reason: :non_root_cursor}}` when given a non-root child cursor.

### Changed
- `Xitdb.Pull` range slices (`field: first..last`) are now inclusive of `last`, matching Elixir's `Enum.slice/2`.
- Refactored `Xitdb.DSL` into dedicated `PathCompiler`, `DatalogCompiler`, `TxRewriter`, and `TxRuntime` submodules, and inverted `Xitdb.Ash.Tx` compile-time coupling.
- `VerifySyncProjection` validates `nested_in` mappings (`cardinality: :many` key presence, `parent_key`/`key` attribute existence, and no secondary `indexes` on MDM nested resources).

### Fixed
- Escaped `@` and backslashes in selector keys and handled quoted hash-map keys in `TxRuntime` path step parsing.
- Eliminated cyclic compilation deadlocks in `Xitdb.Ash.Transformers.WireChanges` via per-pair `:persistent_term` caching and `O(1)` staged operation accumulation on `%Xitdb.Cursor{}`.
- Cloned BM25 top hits out of the local temporary arena before returning in the Raw Odin benchmark runner.

## [1.0.1] - 2026-11-06

### Changed
- Updated `odin-xitdb` native engine submodule to `b760ee9` (lock-free stateless positional cursors, `vmem`-backed `Core_Memory`, reverse and upper-bound range iterators across all collections, and empty-collection iterator root-read skip optimization).

## [1.0.0] - 2026-11-06

### Added
- Initial release of `Xitdb` Elixir client wrapping `odin-xitdb` via a C-ABI Erlang NIF (`priv/xitdb_nif.so`).
- Lazy 9-byte `Slot` cursor (`%Xitdb.Cursor{}`) implementing `Access`, `Enumerable` (`O(1)` `count/1`, `O(1)` `member?/2`, `O(log N)` `slice/2`, chunked `reduce/3`), and `Inspect`.
- Coarse-grained transactions (`Xitdb.transact/3`) supporting both nested Elixir maps/collections and `put_in/3` / `update_in/3` / `pop_in/2` cursor pipelines.
- Time-travel snapshots (`Xitdb.db/1`, `Xitdb.as_of/2`), structural diffs (`Xitdb.diff_moments/3`), and attribute lineage (`Xitdb.history_of/2`).
- Compile-time validated selector (`~x`) and Datalog (`~q`) sigils, Datomic-style `Xitdb.pull/2` projections, and Datalog queries (`Xitdb.query/3`) with B+Tree secondary index pushdown and grouped aggregations.
- Spark DSL extension (`Xitdb.Ash.Resource`), introspection (`Xitdb.Ash.Info`), transformer (`Xitdb.Ash.Transformers.WireChanges`), verifier (`Xitdb.Ash.Verifiers.VerifySyncProjection`), and declarative transaction macros (`Xitdb.Ash.Tx.tx_for`, `tx_for!`).
- 4-layer Client ATDD executable specification suite (`test/features/*_spec.exs`) and `StreamData` property tests.
- 1v1 Client Statistical Benchmark Suite (`benchmarks/`) comparing the Elixir NIF wrapper against Raw Odin across client workloads.
