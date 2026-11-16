# Xitdb Elixir Client Benchmarks

This directory contains the 1v1 statistical benchmark suite for `Xitdb`, measuring **client-boundary overhead** and throughput (`ops/sec`), median/mean latency (`ns/op`), variance (`±σ`, `CV%`, `IQR`, `p95`, `p99`, `min..max`), and resulting database byte footprint between the **Elixir NIF Wrapper (`lang: "elixir"`)** and **Raw Odin (`lang: "odin"`)**.

Unlike the upstream `odin-xitdb` benchmark suite (which benchmarks low-level HAMT/B+Tree node splits, hashers, and raw byte streams), this suite focuses exclusively on **26 orthogonal, zero-redundancy client-facing workloads** across five groups:
1. **`access` (`#1–#5`)**: 3-hop lazy `Access` HAMT navigation (`root["users"][id]["name"]`), single-call selector traversal (`Xitdb.select!/2`), `Sorted_Map` B+Tree binary-search key lookup (`sorted[key]`), `Array_List` 16-way Radix Trie indexing (`items[idx]`), and `Linked_Array_List` count-augmented B-Tree indexing (`linked[idx]`).
2. **`enumerable & stream` (`#6–#11`)**: `O(1)` `Enum.count/1` on `Counted_Hash_Map`, `O(1)` `Enum.member?/2` on `Counted_Hash_Set`, `O(log N)` `Enum.slice/2` on `Array_List`, bounded `Stream.take/2` early-halt on `Sorted_Map`, full `Enum.to_list/1` on `Array_List`, and `Xitdb.materialize/1` subtree conversion.
3. **`transactions` (`#12–#16`)**: Single-entity `Xitdb.transact/2` map commits, bulk 100-entity batch commits, incremental `put_in/3` cursor transactions, `O(log N)` mid-list `Xitdb.insert_at/4` + `Xitdb.delete_at/3` on `Linked_Array_List`, and `O(1)` zero-copy subtree `Xitdb.fork/3`.
4. **`time-travel & lifecycle` (`#17–#20`)**: `Xitdb.as_of/2` historical snapshot resolution across 100 moments, `Xitdb.history_of/2` attribute lineage scan across 100 moments, `O(delta)` `Xitdb.diff_moments/3` structural diffs, and `Xitdb.compact/1` 100-moment database deduplication.
5. **`queries, storage & search` (`#21–#26`)**: Datomic-style `Xitdb.pull/2` nested projections, Datalog B+Tree secondary index prefix seek + join (`Xitdb.query/2`), Datalog grouped aggregations (`count`, `sum`), on-disk `Buffered_File` transactional commits + `Xitdb.sync/1`, `Sorted_Map` B+Tree prefix seek (`limit=16`), and BM25 corpus search (`N=200`, 2-term prefix, `limit=10`).

---

## Running the Benchmarks

Run both the Raw Odin baseline and the Elixir NIF wrapper back-to-back with unified Git commit/run tagging and Welch's `z`-score comparison:

```bash
./benchmarks/compare_1v1.py --runs 5 --warmup 1
```

Or run either side, preview git-diff-affected slices, inspect run history, or regenerate per-benchmark code slices:

```bash
# Preview git-diff benchmark plan without running benchmarks
./benchmarks/compare_1v1.py --plan

# Run only benchmarks affected by recent/uncommitted code changes
./benchmarks/compare_1v1.py --affected --runs 5 --warmup 1

# Run specific canonical groups or substring filters (or a single side via --lang)
./benchmarks/compare_1v1.py --groups access,enumerable --filter "3-hop|Sorted_Map" --runs 5 --warmup 1
./benchmarks/compare_1v1.py --lang elixir --groups time_travel

# Run either harness directly (supports --groups, --filter, --append, --no-history, --output, --history)
odin run benchmarks -collection:xitdb=native/xitdb-odin/xitdb -o:speed -microarch:native -- --runs 5 --warmup 1
mix run benchmarks/bench_elixir.exs -- --runs 5 --warmup 1

# History inspection, multi-commit comparisons, and code slice generation
./benchmarks/compare_1v1.py --list-commits
./benchmarks/compare_1v1.py --inspect "3-hop"
./benchmarks/compare_1v1.py --compare-commits 1a603bf720c0 0421fe5300ba --lang elixir
./benchmarks/compare_1v1.py --generate-slices
```

See [Benchmark Code Slices (`slices/README.md`)](slices/README.md) for side-by-side Elixir harness, Raw Odin baseline, Elixir/NIF wrapper, and reachable `xitdb` core engine call-graph views of `#1–#26`.

To regenerate the slices and reference tables below from `benchmarks/odin.jsonl`, `benchmarks/elixir.jsonl`, and `benchmarks/history.jsonl`:

```bash
./benchmarks/update_readme.sh
```

---

## NIF Boundary Cost Model

Across the 26 orthogonal workloads, the BEAM ↔ Odin NIF boundary separates cleanly into four latency regimes:

1. **Single-Hop Read Floor (`~165–300 ns` per NIF call — `#3–#6`):**
   Every RW-locked NIF crossing pays fixed `enif_get_resource`, `enif_rwlock_rlock`, `resolve_slot_coord`, and `enif_make_*` term construction overhead (`165 ns` vs. `6 ns` Raw Odin on `O(1)` `Enum.count/1`, and `~246–300 ns` added to single-hop `Sorted_Map`, `Array_List`, and `Linked_Array_List` lookups).
2. **Multi-Hop Navigation vs. Single-Call Selectors & Projections (`#1`, `#2`, `#11`, `#17`, `#21`):**
   Chaining `N` bracket hops via `Access` (`#1`: `root["users"][id]["name"]` at `2.46 µs`, or `#17`: `as_of(db, m)["users"]["alice"]["score"]` at `2.40 µs` / `4.43x`) pays `N` separate NIF crossings plus intermediate `%Xitdb.Cursor{}` struct allocations, whereas `Xitdb.select!/2` (`#2`: `2.13 µs` / `2.10x`), `Xitdb.materialize/1` (`#11`: `6.09 µs` / `2.30x`), and `Xitdb.pull/2` (`#21`: `6.33 µs` / `2.37x`) collapse multi-step traversal or multi-field projection into a single NIF crossing.
3. **Transactional Write Batching vs. `put_in/3` (`tx` / Map `transact/3` vs. `#14`):**
   Single-call batched commits (`#12` at `2.25x` [`14.1 µs` vs. `6.29 µs`], `#13` at `2.28x` [`414.5 µs` vs. `182.0 µs`], `#15` at `2.16x`, and `#16` at `2.08x`) pay only one NIF boundary crossing via `:merge_map` subtree cursors, whereas nested `put_in/3` (`#14`, `3.40x`) traverses intermediate maps via `Access.get_and_update/3`, issuing read-before-write `Cursor.fetch/2` NIF hops before staging the leaf write. Use `Xitdb.DSL.tx` (`put users[id].score, val`) or map `Xitdb.transact/3` in write-heavy paths.
4. **Compute- & Storage-Amortized Engine Operations (`1.15x–1.86x` near-native parity — `#19`, `#20`, `#22–#24`, `#26`):**
   When engine work dominates boundary marshaling—such as structural moment diffs (`#19`, `1.85x`), database compaction (`#20`, `1.33x`), Datalog index joins and aggregations (`#22` `1.86x`, `#23` `1.20x`), `Buffered_File` sync commits (`#24`, `1.15x`), and BM25 corpus search (`#26`, `1.69x`)—Elixir tracks Raw Odin closely.

See [Lazy Cursors, `Access` & `Enumerable`](../docs/access-and-enumerable.md#5-nif-boundary-cost-model--when-to-use-access-vs-the-macro-dsl) for API selection guidelines based on these regimes.

---

## Reference Results (`Elixir NIF Wrapper` vs. `Raw Odin`, `Core_Memory`)

<!-- BEGIN_BENCHMARK_TABLE -->
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `415d6331d9d0`, 5 samples across 1 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 5 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#3](bench_elixir.exs#L240-L247) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **613** | 618 ± 9.5 | 1.5% | 1.59M | 1.64M | 17 | 629 | 629 | 610 | 629 | 500 |
| [#4](bench_elixir.exs#L248-L255) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **351** | 351 ± 5.7 | 1.6% | 2.8M | 2.9M | 1 | 357 | 358 | 342 | 358 | 500 |
| [#5](bench_elixir.exs#L256-L263) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **373** | 375 ± 9.0 | 2.4% | 2.6M | 2.7M | 3 | 387 | 390 | 369 | 391 | 500 |
| [#6](bench_elixir.exs#L264-L271) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **156** | 161 ± 9.9 | 6.1% | 5.6M | 6.5M | 4 | 174 | 177 | 155 | 178 | 1K |
| [#7](bench_elixir.exs#L272-L279) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **742** | 745 ± 13.4 | 1.8% | 1.3M | 1.4M | 20 | 761 | 762 | 730 | 762 | 1K |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 23 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_elixir.exs#L224-L231) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **2.44** | 2.43 ± 0.01 | 0.3% | 410K | 413K | 0.00 | 2.44 | 2.44 | 2.42 | 2.44 | 500 |
| [#2](bench_elixir.exs#L232-L239) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **2.02** | 2.02 ± 0.01 | 0.5% | 491K | 497K | 0.01 | 2.04 | 2.04 | 2.01 | 2.04 | 500 |
| [#8](bench_elixir.exs#L280-L287) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **3.05** | 3.07 ± 0.16 | 5.3% | 298K | 339K | 0.09 | 3.29 | 3.34 | 2.95 | 3.35 | 200 |
| [#9](bench_elixir.exs#L288-L295) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **3.67** | 3.68 ± 0.04 | 1.2% | 268K | 276K | 0.06 | 3.73 | 3.73 | 3.63 | 3.73 | 200 |
| [#10](bench_elixir.exs#L296-L303) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **64.0** | 63.9 ± 0.79 | 1.2% | 15.4K | 15.9K | 1.26 | 64.7 | 64.8 | 63.0 | 64.8 | 50 |
| [#11](bench_elixir.exs#L304-L311) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **5.70** | 5.73 ± 0.09 | 1.6% | 170K | 177K | 0.06 | 5.86 | 5.88 | 5.66 | 5.89 | 200 |
| [#12](bench_elixir.exs#L312-L338) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **12.1** | 12.6 ± 1.03 | 8.2% | 69.5K | 84.0K | 0.14 | 14.0 | 14.3 | 11.9 | 14.4 | 100 |
| [#13](bench_elixir.exs#L339-L354) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **363.8** | 371.6 ± 18.3 | 4.9% | 2.5K | 2.8K | 6.73 | 396.8 | 402.4 | 359.4 | 403.8 | 1 |
| [#14](bench_elixir.exs#L355-L369) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **14.1** | 14.1 ± 0.14 | 1.0% | 70.1K | 71.6K | 0.26 | 14.3 | 14.3 | 14.0 | 14.3 | 100 |
| [#15](bench_elixir.exs#L370-L390) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **13.8** | 13.7 ± 0.19 | 1.4% | 72.4K | 74.7K | 0.22 | 13.8 | 13.8 | 13.4 | 13.8 | 50 |
| [#16](bench_elixir.exs#L391-L408) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **12.7** | 12.9 ± 1.59 | 12.3% | 66.6K | 91.2K | 1.92 | 14.8 | 15.0 | 11.0 | 15.0 | 100 |
| [#17](bench_elixir.exs#L409-L417) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **2.48** | 2.47 ± 0.07 | 2.7% | 393K | 417K | 0.12 | 2.54 | 2.54 | 2.40 | 2.54 | 100 |
| [#18](bench_elixir.exs#L418-L425) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **48.7** | 48.7 ± 0.74 | 1.5% | 20.1K | 21.0K | 0.25 | 49.6 | 49.7 | 47.7 | 49.8 | 50 |
| [#19](bench_elixir.exs#L426-L433) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **325.3** | 328.4 ± 5.25 | 1.6% | 3.0K | 3.1K | 9.06 | 334.5 | 334.7 | 324.1 | 334.8 | 50 |
| [#20](bench_elixir.exs#L434-L445) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **25.9** | 26.6 ± 1.72 | 6.4% | 34.1K | 39.9K | 1.71 | 28.9 | 29.2 | 25.0 | 29.3 | 20 |
| [#21](bench_elixir.exs#L446-L453) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **6.51** | 6.51 ± 0.14 | 2.2% | 150K | 158K | 0.22 | 6.66 | 6.67 | 6.33 | 6.67 | 200 |
| [#22](bench_elixir.exs#L454-L461) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **47.5** | 49.7 ± 5.48 | 11.0% | 16.8K | 21.3K | 0.52 | 57.1 | 59.1 | 46.9 | 59.5 | 50 |
| [#23](bench_elixir.exs#L462-L469) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **574.7** | 572.8 ± 7.89 | 1.4% | 1.7K | 1.8K | 12.3 | 581.2 | 581.9 | 563.8 | 582.1 | 50 |
| [#24](bench_elixir.exs#L470-L486) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **63.5** | 64.3 ± 3.27 | 5.1% | 14.4K | 16.5K | 2.63 | 68.6 | 69.2 | 60.7 | 69.4 | 50 |
| [#25](bench_elixir.exs#L487-L501) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **4.62** | 4.63 ± 0.10 | 2.2% | 211K | 222K | 0.18 | 4.74 | 4.74 | 4.51 | 4.74 | 100 |
| [#26](bench_elixir.exs#L502-L518) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **237.0** | 238.2 ± 3.17 | 1.3% | 4.1K | 4.2K | 0.57 | 242.5 | 243.5 | 235.8 | 243.8 | 50 |
| [#27](bench_elixir.exs#L519-L535) | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **11.7** | 11.6 ± 0.06 | 0.5% | 85.5K | 86.4K | 0.09 | 11.7 | 11.7 | 11.6 | 11.7 | 50 |
| [#28](bench_elixir.exs#L536-L544) | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **1.97** | 1.97 ± 0.01 | 0.7% | 503K | 513K | 0.01 | 1.99 | 1.99 | 1.95 | 1.99 | 500 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `415d6331d9d0`, 5 samples across 1 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 8 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_client.odin#L868-L887) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **638** | 637 ± 15.6 | 2.5% | 1.5M | 1.6M | 17 | 656 | 658 | 619 | 659 | 500 |
| [#3](bench_client.odin#L905-L920) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **384** | 390 ± 14.1 | 3.6% | 2.4M | 2.6M | 6 | 410 | 414 | 382 | 415 | 500 |
| [#4](bench_client.odin#L922-L936) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **107** | 107 ± 0.5 | 0.5% | 9.26M | 9.35M | 1 | 108 | 108 | 107 | 108 | 500 |
| [#5](bench_client.odin#L938-L952) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **118** | 119 ± 1.6 | 1.4% | 8.3M | 8.5M | 2 | 121 | 121 | 117 | 121 | 500 |
| [#6](bench_client.odin#L954-L966) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **7** | 9 ± 3.3 | 35.0% | 76.9M | 143M | 6 | 13 | 13 | 7 | 13 | 1K |
| [#7](bench_client.odin#L968-L982) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **260** | 263 ± 4.8 | 1.8% | 3.7M | 3.9M | 6 | 269 | 270 | 259 | 270 | 1K |
| [#17](bench_client.odin#L1207-L1227) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **554** | 555 ± 3.3 | 0.6% | 1.79M | 1.81M | 3 | 559 | 560 | 552 | 560 | 100 |
| [#28](bench_client.odin#L1533-L1556) | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **873** | 873 ± 10.0 | 1.1% | 1.1M | 1.2M | 8 | 886 | 888 | 861 | 888 | 500 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 20 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#2](bench_client.odin#L889-L903) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **1.02** | 1.02 ± 0.01 | 1.4% | 967K | 1.0M | 0.02 | 1.03 | 1.03 | 1.00 | 1.03 | 500 |
| [#8](bench_client.odin#L984-L1003) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.61** | 1.63 ± 0.03 | 2.0% | 595K | 622K | 0.05 | 1.68 | 1.68 | 1.61 | 1.68 | 200 |
| [#9](bench_client.odin#L1005-L1028) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **1.47** | 1.48 ± 0.03 | 1.8% | 661K | 690K | 0.04 | 1.51 | 1.51 | 1.45 | 1.51 | 200 |
| [#10](bench_client.odin#L1030-L1051) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **40.2** | 39.7 ± 4.65 | 11.7% | 22.6K | 28.7K | 9.11 | 44.2 | 44.3 | 34.8 | 44.3 | 50 |
| [#11](bench_client.odin#L1053-L1068) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **3.82** | 3.67 ± 0.24 | 6.4% | 260K | 299K | 0.35 | 3.84 | 3.85 | 3.34 | 3.85 | 200 |
| [#12](bench_client.odin#L1070-L1087) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **6.23** | 6.37 ± 0.38 | 6.0% | 142K | 166K | 0.09 | 6.88 | 7.00 | 6.03 | 7.03 | 100 |
| [#13](bench_client.odin#L1089-L1103) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **182.5** | 180.2 ± 6.49 | 3.6% | 5.3K | 5.8K | 8.92 | 187.4 | 188.4 | 173.5 | 188.6 | 1 |
| [#14](bench_client.odin#L1105-L1127) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **3.67** | 3.70 ± 0.10 | 2.6% | 261K | 280K | 0.07 | 3.82 | 3.83 | 3.57 | 3.84 | 100 |
| [#15](bench_client.odin#L1129-L1154) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **5.39** | 5.41 ± 0.24 | 4.3% | 174K | 195K | 0.27 | 5.69 | 5.72 | 5.12 | 5.73 | 50 |
| [#16](bench_client.odin#L1156-L1183) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **3.84** | 3.81 ± 0.09 | 2.4% | 254K | 271K | 0.08 | 3.92 | 3.93 | 3.70 | 3.94 | 100 |
| [#18](bench_client.odin#L1229-L1242) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **69.5** | 69.7 ± 0.34 | 0.5% | 14.3K | 14.4K | 0.61 | 70.1 | 70.1 | 69.4 | 70.1 | 50 |
| [#19](bench_client.odin#L1261-L1274) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **182.2** | 191.4 ± 20.8 | 10.9% | 4.4K | 5.5K | 4.32 | 219.8 | 226.7 | 180.6 | 228.5 | 50 |
| [#20](bench_client.odin#L1276-L1296) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **18.9** | 18.7 ± 0.59 | 3.1% | 52.0K | 56.4K | 0.52 | 19.2 | 19.2 | 17.7 | 19.2 | 20 |
| [#21](bench_client.odin#L1298-L1313) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **2.72** | 2.73 ± 0.04 | 1.5% | 361K | 372K | 0.08 | 2.77 | 2.77 | 2.69 | 2.77 | 200 |
| [#22](bench_client.odin#L1315-L1336) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **25.7** | 26.1 ± 0.93 | 3.6% | 36.0K | 39.1K | 0.23 | 27.4 | 27.7 | 25.6 | 27.8 | 50 |
| [#23](bench_client.odin#L1338-L1357) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **470.8** | 475.3 ± 12.0 | 2.5% | 2.0K | 2.2K | 10.5 | 491.2 | 493.7 | 463.8 | 494.3 | 50 |
| [#24](bench_client.odin#L1359-L1378) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **51.3** | 51.3 ± 0.13 | 0.3% | 19.4K | 19.5K | 0.25 | 51.4 | 51.4 | 51.2 | 51.4 | 50 |
| [#25](bench_client.odin#L1380-L1421) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **1.65** | 1.67 ± 0.02 | 1.5% | 585K | 606K | 0.01 | 1.70 | 1.71 | 1.65 | 1.71 | 100 |
| [#26](bench_client.odin#L1423-L1451) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **157.7** | 157.9 ± 0.68 | 0.4% | 6.3K | 6.4K | 0.20 | 158.8 | 159.0 | 157.4 | 159.1 | 50 |
| [#27](bench_client.odin#L1453-L1531) | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **7.90** | 7.92 ± 0.08 | 1.0% | 124K | 127K | 0.10 | 8.02 | 8.03 | 7.85 | 8.03 | 50 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `415d6331d9d0`)

#### 3.1 Sub-Microsecond Fast Path (Elixir `< 1 µs`, 5 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **1.60x** | 384 | **613** | `30.0` ★ | 390 ± 14.1 | 3.6% | 618 ± 9.5 | 1.5% |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **3.28x** | 107 | **351** | `94.7` ★ | 107 ± 0.5 | 0.5% | 351 ± 5.7 | 1.6% |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **3.16x** | 118 | **373** | `62.6` ★ | 119 ± 1.6 | 1.4% | 375 ± 9.0 | 2.4% |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **22.29x** | 7 | **156** | `32.5` ★ | 9 ± 3.3 | 35.0% | 161 ± 9.9 | 6.1% |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **2.85x** | 260 | **742** | `75.5` ★ | 263 ± 4.8 | 1.8% | 745 ± 13.4 | 1.8% |


#### 3.2 Multi-Microsecond Client Operations (Elixir `≥ 1 µs`, 23 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **3.82x** | 0.64 | **2.44** | `235.8` ★ | 0.64 ± 0.02 | 2.5% | 2.43 ± 0.01 | 0.3% |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **1.99x** | 1.02 | **2.02** | `127.9` ★ | 1.02 ± 0.01 | 1.4% | 2.02 ± 0.01 | 0.5% |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.89x** | 1.61 | **3.05** | `19.6` ★ | 1.63 ± 0.03 | 2.0% | 3.07 ± 0.16 | 5.3% |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **2.50x** | 1.47 | **3.67** | `97.9` ★ | 1.48 ± 0.03 | 1.8% | 3.68 ± 0.04 | 1.2% |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **1.59x** | 40.2 | **64.0** | `11.5` ★ | 39.7 ± 4.65 | 11.7% | 63.9 ± 0.79 | 1.2% |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **1.49x** | 3.82 | **5.70** | `18.3` ★ | 3.67 ± 0.24 | 6.4% | 5.73 ± 0.09 | 1.6% |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **1.95x** | 6.23 | **12.1** | `12.7` ★ | 6.37 ± 0.38 | 6.0% | 12.6 ± 1.03 | 8.2% |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **1.99x** | 182.5 | **363.8** | `22.0` ★ | 180.2 ± 6.49 | 3.6% | 371.6 ± 18.3 | 4.9% |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **3.84x** | 3.67 | **14.1** | `137.5` ★ | 3.70 ± 0.10 | 2.6% | 14.1 ± 0.14 | 1.0% |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **2.56x** | 5.39 | **13.8** | `61.3` ★ | 5.41 ± 0.24 | 4.3% | 13.7 ± 0.19 | 1.4% |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **3.32x** | 3.84 | **12.7** | `12.8` ★ | 3.81 ± 0.09 | 2.4% | 12.9 ± 1.59 | 12.3% |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **4.47x** | 0.55 | **2.48** | `64.2` ★ | 0.55 ± 0.00 | 0.6% | 2.47 ± 0.07 | 2.7% |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **0.70x** | 69.5 | **48.7** | `57.9` ★ | 69.7 ± 0.34 | 0.5% | 48.7 ± 0.74 | 1.5% |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **1.79x** | 182.2 | **325.3** | `14.3` ★ | 191.4 ± 20.8 | 10.9% | 328.4 ± 5.25 | 1.6% |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **1.37x** | 18.9 | **25.9** | `9.8` ★ | 18.7 ± 0.59 | 3.1% | 26.6 ± 1.72 | 6.4% |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **2.39x** | 2.72 | **6.51** | `56.5` ★ | 2.73 ± 0.04 | 1.5% | 6.51 ± 0.14 | 2.2% |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **1.85x** | 25.7 | **47.5** | `9.5` ★ | 26.1 ± 0.93 | 3.6% | 49.7 ± 5.48 | 11.0% |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **1.22x** | 470.8 | **574.7** | `15.2` ★ | 475.3 ± 12.0 | 2.5% | 572.8 ± 7.89 | 1.4% |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **1.24x** | 51.3 | **63.5** | `8.9` ★ | 51.3 ± 0.13 | 0.3% | 64.3 ± 3.27 | 5.1% |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **2.80x** | 1.65 | **4.62** | `62.4` ★ | 1.67 ± 0.02 | 1.5% | 4.63 ± 0.10 | 2.2% |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **1.50x** | 157.7 | **237.0** | `55.4` ★ | 157.9 ± 0.68 | 0.4% | 238.2 ± 3.17 | 1.3% |
| 27 | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **1.48x** | 7.90 | **11.7** | `86.5` ★ | 7.92 ± 0.08 | 1.0% | 11.6 ± 0.06 | 0.5% |
| 28 | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **2.25x** | 0.87 | **1.97** | `139.0` ★ | 0.87 ± 0.01 | 1.1% | 1.97 ± 0.01 | 0.7% |



### 4. Commit-vs-Commit Progression


#### 4.1 Elixir Client Wrapper (`a6ad2e15d006` → `415d6331d9d0`)

| # | Benchmark | `a6ad2e15d006` Med | `415d6331d9d0` Med | Δ% | Speedup | Welch `z` | `a6ad2e15d006` Mean ± σ | `415d6331d9d0` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 2.46 µs | **2.44 µs** | -1.0% | **1.01x** | `5.3` ★ | 2.47 µs ± 12 ns | 2.43 µs ± 7 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 2.13 µs | **2.02 µs** | -5.1% | **1.05x** | `6.5` ★ | 2.14 µs ± 38 ns | 2.02 µs ± 10 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 626 ns | **613 ns** | -2.1% | **1.02x** | `2.0` ★ | 629 ns ± 8 ns | 618 ns ± 9 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 376 ns | **351 ns** | -6.6% | **1.07x** | `6.5` ★ | 375 ns ± 6 ns | 351 ns ± 6 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 418 ns | **373 ns** | -10.8% | **1.12x** | `3.5` ★ | 433 ns ± 36 ns | 375 ns ± 9 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 165 ns | **156 ns** | -5.5% | **1.06x** | `1.5` ~ | 175 ns ± 19 ns | 161 ns ± 10 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 808 ns | **742 ns** | -8.2% | **1.09x** | `8.2` ★ | 813 ns ± 13 ns | 745 ns ± 13 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 3.52 µs | **3.05 µs** | -13.3% | **1.15x** | `6.1` ★ | 3.55 µs ± 68 ns | 3.07 µs ± 161 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 4.76 µs | **3.67 µs** | -22.8% | **1.30x** | `38.6` ★ | 4.76 µs ± 45 ns | 3.68 µs ± 42 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 78.8 µs | **64.0 µs** | -18.8% | **1.23x** | `37.1` ★ | 78.9 µs ± 442 ns | 63.9 µs ± 786 ns |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 6.09 µs | **5.70 µs** | -6.4% | **1.07x** | `4.3` ★ | 6.16 µs ± 202 ns | 5.73 µs ± 93 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 14.1 µs | **12.1 µs** | -14.1% | **1.16x** | `3.5` ★ | 14.4 µs ± 575 ns | 12.6 µs ± 1.03 µs |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 414.5 µs | **363.8 µs** | -12.3% | **1.14x** | `4.1` ★ | 411.5 µs ± 11.6 µs | 371.6 µs ± 18.3 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 12.6 µs | **14.1 µs** | +11.8% | **0.89x** | `2.7` ★ | 13.0 µs ± 928 ns | 14.1 µs ± 139 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 11.4 µs | **13.8 µs** | +20.8% | **0.83x** | `21.8` ★ | 11.4 µs ± 134 ns | 13.7 µs ± 188 ns |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 7.77 µs | **12.7 µs** | +63.9% | **0.61x** | `6.0` ★ | 8.12 µs ± 840 ns | 12.9 µs ± 1.59 µs |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 2.40 µs | **2.48 µs** | +3.0% | **0.97x** | `1.9` ~ | 2.40 µs ± 36 ns | 2.47 µs ± 67 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 208.3 µs | **48.7 µs** | -76.6% | **4.28x** | `104.5` ★ | 208.7 µs ± 3.34 µs | 48.7 µs ± 735 ns |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 328.8 µs | **325.3 µs** | -1.1% | **1.01x** | `0.2` ~ | 328.8 µs ± 483 ns | 328.4 µs ± 5.25 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 25.2 µs | **25.9 µs** | +3.0% | **0.97x** | `1.8` ~ | 25.1 µs ± 496 ns | 26.6 µs ± 1.72 µs |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 6.33 µs | **6.51 µs** | +2.8% | **0.97x** | `2.5` ★ | 6.34 µs ± 49 ns | 6.51 µs ± 144 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 46.4 µs | **47.5 µs** | +2.3% | **0.98x** | `1.3` ~ | 46.6 µs ± 589 ns | 49.7 µs ± 5.48 µs |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 557.1 µs | **574.7 µs** | +3.2% | **0.97x** | `4.5` ★ | 556.9 µs ± 525 ns | 572.8 µs ± 7.89 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 59.5 µs | **63.5 µs** | +6.8% | **0.94x** | `3.3` ★ | 59.5 µs ± 423 ns | 64.3 µs ± 3.27 µs |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 4.66 µs | **4.62 µs** | -0.7% | **1.01x** | `0.4` ~ | 4.65 µs ± 77 ns | 4.63 µs ± 103 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 260.6 µs | **237.0 µs** | -9.1% | **1.10x** | `11.2` ★ | 259.3 µs ± 2.80 µs | 238.2 µs ± 3.17 µs |



#### 4.2 Raw Odin Baseline (`a6ad2e15d006` → `415d6331d9d0`)

| # | Benchmark | `a6ad2e15d006` Med | `415d6331d9d0` Med | Δ% | Speedup | Welch `z` | `a6ad2e15d006` Mean ± σ | `415d6331d9d0` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 606 ns | **638 ns** | +5.3% | **0.95x** | `0.0` ~ | 638 ns ± 62 ns | 637 ns ± 16 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 1.01 µs | **1.02 µs** | +0.1% | **1.00x** | `0.2` ~ | 1.01 µs ± 11 ns | 1.02 µs ± 14 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 380 ns | **384 ns** | +1.1% | **0.99x** | `0.2` ~ | 388 ns ± 19 ns | 390 ns ± 14 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 106 ns | **107 ns** | +0.9% | **0.99x** | `0.8` ~ | 112 ns ± 15 ns | 107 ns ± 1 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 118 ns | **118 ns** | +0.0% | **1.00x** | `0.6` ~ | 118 ns ± 1 ns | 119 ns ± 2 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 6 ns | **7 ns** | +16.7% | **0.86x** | `2.2` ★ | 6 ns ± 0 ns | 9 ns ± 3 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 262 ns | **260 ns** | -0.8% | **1.01x** | `1.1` ~ | 268 ns ± 8 ns | 263 ns ± 5 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 1.61 µs | **1.61 µs** | +0.2% | **1.00x** | `0.2` ~ | 1.63 µs ± 29 ns | 1.63 µs ± 33 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 1.46 µs | **1.47 µs** | +0.3% | **1.00x** | `0.3` ~ | 1.47 µs ± 30 ns | 1.48 µs ± 27 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 35.3 µs | **40.2 µs** | +14.0% | **0.88x** | `2.2` ★ | 35.2 µs ± 160 ns | 39.7 µs ± 4.65 µs |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 2.64 µs | **3.82 µs** | +44.5% | **0.69x** | `9.3` ★ | 2.67 µs ± 41 ns | 3.67 µs ± 236 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 6.29 µs | **6.23 µs** | -0.9% | **1.01x** | `0.3` ~ | 6.31 µs ± 173 ns | 6.37 µs ± 382 ns |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 182.0 µs | **182.5 µs** | +0.3% | **1.00x** | `0.9` ~ | 183.3 µs ± 4.21 µs | 180.2 µs ± 6.49 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 3.71 µs | **3.67 µs** | -0.9% | **1.01x** | `0.7` ~ | 3.74 µs ± 119 ns | 3.70 µs ± 97 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 5.27 µs | **5.39 µs** | +2.3% | **0.98x** | `1.0` ~ | 5.31 µs ± 59 ns | 5.41 µs ± 235 ns |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 3.74 µs | **3.84 µs** | +2.5% | **0.98x** | `0.7` ~ | 3.76 µs ± 136 ns | 3.81 µs ± 91 ns |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 543 ns | **554 ns** | +2.0% | **0.98x** | `4.6` ★ | 545 ns ± 3 ns | 555 ns ± 3 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 69.9 µs | **69.5 µs** | -0.6% | **1.01x** | `1.0` ~ | 69.9 µs ± 99 ns | 69.7 µs ± 343 ns |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 177.4 µs | **182.2 µs** | +2.7% | **0.97x** | `1.5` ~ | 177.5 µs ± 631 ns | 191.4 µs ± 20.8 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 18.9 µs | **18.9 µs** | +0.1% | **1.00x** | `0.2` ~ | 18.7 µs ± 324 ns | 18.7 µs ± 586 ns |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 2.67 µs | **2.72 µs** | +1.9% | **0.98x** | `2.7` ★ | 2.68 µs ± 16 ns | 2.73 µs ± 41 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 25.0 µs | **25.7 µs** | +2.6% | **0.97x** | `1.1` ~ | 25.4 µs ± 966 ns | 26.1 µs ± 927 ns |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 464.9 µs | **470.8 µs** | +1.3% | **0.99x** | `0.6` ~ | 469.0 µs ± 18.9 µs | 475.3 µs ± 12.0 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 51.7 µs | **51.3 µs** | -0.8% | **1.01x** | `2.3` ★ | 51.8 µs ± 461 ns | 51.3 µs ± 129 ns |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 1.52 µs | **1.65 µs** | +8.9% | **0.92x** | `0.4` ~ | 1.62 µs ± 231 ns | 1.67 µs ± 25 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 154.3 µs | **157.7 µs** | +2.2% | **0.98x** | `0.6` ~ | 161.4 µs ± 12.9 µs | 157.9 µs ± 677 ns |



### 5. Database Storage Footprint (`bytes_used > 0`)

| # | Benchmark | Ops | Raw Odin Size | Elixir Wrapper Size |
| ---: | :--- | ---: | ---: | ---: |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 100 | 128.3 KB | 128.3 KB |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 1 | 33.5 KB | 33.5 KB |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 100 | 85.3 KB | 85.3 KB |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 50 | 69.7 KB | 69.7 KB |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 100 | 737.3 KB | 730.5 KB |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 20 | 1.0 KB | 1.0 KB |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 50 | 38.5 KB | 38.5 KB |
<!-- END_BENCHMARK_TABLE -->
