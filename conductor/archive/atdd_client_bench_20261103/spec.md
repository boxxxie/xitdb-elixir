# Specification: 4-Layer ATDD Client Specification Suite & 1v1 Client Benchmark Harness

## Overview
Establish the executable behavioral contract and performance measurement baseline for `Xitdb` (`elixir/xitdb`) strictly from the perspective of an **Elixir client consumer** rather than an underlying storage engine implementation.

## Functional Requirements

### 1. 4-Layer ATDD Client Specification Suite (`test/`)
- **Layer 1 (`test/features/*_spec.exs`):**
  - `lazy_access_navigation_spec.exs`: Verifies opening in-memory and file-backed databases, transacting nested Elixir data, and navigating lazily via `cursor["key"]`, `cursor[idx]`, and `Kernel.get_in/2` without eagerly loading sibling subtrees. Verifies scalar auto-unwrapping vs. lazy `%Xitdb.Cursor{}` container handles and cross-process `%Xitdb.Cursor{}` passing (`Task.async/1`).
  - `enumerable_collections_spec.exs`: Verifies `Enumerable` protocol operations (`Enum.count/1` $O(1)$ fast path, `Enum.member?/2` HAMT/B+Tree lookup, `Enum.slice/2` $O(\log N)$ index jump, `Enum.to_list/1` / `Stream.take/2` chunked iteration), `Inspect` output, `Xitdb.materialize/1`, and explicit write collection wrappers (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, `Xitdb.hash_set/1`, `Xitdb.sorted_set/1`).
  - `transactions_and_time_travel_spec.exs`: Verifies batch transactions (`Xitdb.transact/2`), `put_in`/`update_in` mutations, atomic error rollback, historical snapshot pinning (`Xitdb.as_of/2`), `Xitdb.diff_moments/4`, and `Xitdb.history_of/2`.
  - `queries_and_datalog_spec.exs`: Verifies selector queries (`Xitdb.select/2` & `~x` sigil), Datomic-style `Xitdb.pull/3`, Datalog queries (`Xitdb.query/3` & `~q` sigil), and database compaction (`Xitdb.compact/2`).
  - `client_roundtrip_properties_test.exs`: `ExUnitProperties` (`StreamData`) property tests verifying arbitrary nested Elixir maps, lists, sets, strings, ints, floats, and booleans round-trip identically through `Xitdb.transact/2`, lazy `Access`, and `Xitdb.materialize/1`.
- **Layer 2 (`test/support/dsl/client_dsl.ex`):**
  - Domain steps (`@given`, `@upon`, `@then`) accepting explicit domain inputs and expected outputs, enforcing cross-cutting client invariants (e.g., lazy `Access` path lookup equals `Xitdb.select/2` and matches the materialized value).
- **Layer 3 (`test/support/drivers/client_driver.ex`):**
  - Protocol driver managing `Xitdb` handles, temporary test directories, and NIF assertions.

### 2. Client-Focused 1v1 Statistical Benchmark Suite (`benchmarks/`)
- Compare **Elixir Client Wrapper (`lang: "elixir"`, `benchmarks/elixir.jsonl`)** against **Raw Odin (`lang: "odin"`, `benchmarks/odin.jsonl`)** on 16 client-relevant benchmarks across 5 groups:
  1. **Group 1 (`access`):** 3-hop lazy `Access` (`db["users"][id]["name"]`), single-call `Xitdb.select/2` (`".users.<id>.name"`), `Array_List` random index `cursor[idx]`, and concurrent BEAM `Task` cursor read.
  2. **Group 2 (`enumerable`):** `Enum.count/1` on `Counted_Hash_Map`, `Enum.member?/2` on `Counted_Hash_Set`, `Enum.slice/2` window on `Array_List`, `Enum.to_list/1` chunked stream (`N=1,000`), and `Xitdb.materialize/1` on a nested profile document.
  3. **Group 3 (`transactions`):** Single entity map transaction commit, bulk batch transaction (`100` entities in `1` tx), and incremental `put_in` attribute update.
  4. **Group 4 (`queries`):** Historical `as_of` point read, Datomic `pull` projection (`N=100`), `diff_moments` (`1` of `500` mutated), `history_of` lineage (`10` moments), and Datalog join + aggregation query (`N=500`).
  5. **Group 5 (`lifecycle`):** `Core_Buffered_File` durable commit and `compact` (`100` moments -> `1`).
- Provide `benchmarks/compare_1v1.py` and `benchmarks/update_readme.sh` to run both suites, pool multi-run sample distributions (`samples_ns`), compute Welch's $z$-scores and NIF wrapper overhead ratios (`Elixir / Odin`), and generate `benchmarks/README.md`.
