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

## Reference Results (`Elixir NIF Wrapper` vs. `Raw Odin`, `Core_Memory`)

<!-- BEGIN_BENCHMARK_TABLE -->
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `6641d47147c9`, 10 samples across 2 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 5 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#3](bench_elixir.exs#L208-L215) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **624** | 628 ± 16.2 | 2.6% | 1.5M | 1.7M | 20 | 654 | 657 | 606 | 658 | 500 |
| [#4](bench_elixir.exs#L216-L223) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **382** | 381 ± 16.3 | 4.3% | 2.5M | 2.8M | 26 | 404 | 405 | 362 | 405 | 500 |
| [#5](bench_elixir.exs#L224-L231) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **416** | 441 ± 64.8 | 14.7% | 1.8M | 2.6M | 89 | 546 | 548 | 382 | 549 | 500 |
| [#6](bench_elixir.exs#L232-L239) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **174** | 185 ± 32.6 | 17.6% | 3.6M | 5.9M | 5 | 236 | 269 | 169 | 277 | 1K |
| [#7](bench_elixir.exs#L240-L247) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **756** | 769 ± 26.7 | 3.5% | 1.2M | 1.3M | 29 | 814 | 821 | 743 | 823 | 1K |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 21 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_elixir.exs#L192-L199) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **2.49** | 2.50 ± 0.14 | 5.7% | 361K | 427K | 0.22 | 2.71 | 2.76 | 2.34 | 2.77 | 500 |
| [#2](bench_elixir.exs#L200-L207) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **2.28** | 2.29 ± 0.05 | 2.2% | 417K | 448K | 0.05 | 2.37 | 2.39 | 2.23 | 2.40 | 500 |
| [#8](bench_elixir.exs#L248-L255) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **3.61** | 3.60 ± 0.23 | 6.5% | 257K | 301K | 0.41 | 3.89 | 3.89 | 3.33 | 3.89 | 200 |
| [#9](bench_elixir.exs#L256-L263) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **4.71** | 4.79 ± 0.26 | 5.3% | 190K | 220K | 0.31 | 5.22 | 5.25 | 4.56 | 5.26 | 200 |
| [#10](bench_elixir.exs#L264-L271) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **82.7** | 84.6 ± 9.31 | 11.0% | 9.2K | 13.1K | 7.32 | 99.1 | 106.9 | 76.3 | 108.8 | 50 |
| [#11](bench_elixir.exs#L272-L279) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **5.70** | 5.72 ± 0.15 | 2.7% | 165K | 180K | 0.15 | 5.98 | 6.05 | 5.55 | 6.07 | 200 |
| [#12](bench_elixir.exs#L280-L306) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **47.0** | 47.3 ± 17.2 | 36.5% | 15.6K | 32.9K | 32.6 | 64.2 | 64.2 | 30.4 | 64.2 | 100 |
| [#13](bench_elixir.exs#L307-L322) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **1817.8** | 1886.1 ± 960.9 | 50.9% | 335 | 1.1K | 1802.3 | 2926.8 | 2975.1 | 935.5 | 2987.1 | 1 |
| [#14](bench_elixir.exs#L323-L337) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **26.6** | 26.7 ± 15.1 | 56.6% | 24.0K | 82.0K | 28.4 | 41.6 | 41.6 | 12.2 | 41.6 | 100 |
| [#15](bench_elixir.exs#L338-L358) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **19.1** | 21.3 ± 10.2 | 48.0% | 27.6K | 86.9K | 17.9 | 35.4 | 36.1 | 11.5 | 36.3 | 50 |
| [#16](bench_elixir.exs#L359-L376) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **11.1** | 13.7 ± 6.45 | 47.1% | 39.1K | 128K | 9.66 | 23.3 | 25.1 | 7.82 | 25.6 | 100 |
| [#17](bench_elixir.exs#L377-L385) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **3.19** | 4.56 ± 3.59 | 78.7% | 73.7K | 408K | 0.88 | 11.2 | 13.1 | 2.45 | 13.6 | 100 |
| [#18](bench_elixir.exs#L386-L393) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **221.1** | 224.3 ± 13.9 | 6.2% | 3.8K | 4.7K | 9.81 | 246.1 | 257.0 | 211.2 | 259.7 | 50 |
| [#19](bench_elixir.exs#L394-L401) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **332.3** | 346.6 ± 32.0 | 9.2% | 2.3K | 3.0K | 7.28 | 405.9 | 422.3 | 329.6 | 426.4 | 50 |
| [#20](bench_elixir.exs#L402-L413) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **29.0** | 32.3 ± 6.14 | 19.0% | 23.2K | 37.8K | 9.20 | 41.7 | 42.8 | 26.4 | 43.1 | 20 |
| [#21](bench_elixir.exs#L414-L422) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **9.53** | 9.05 ± 0.87 | 9.6% | 101K | 130K | 1.34 | 9.77 | 9.84 | 7.69 | 9.85 | 200 |
| [#22](bench_elixir.exs#L423-L430) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **47.1** | 48.3 ± 3.82 | 7.9% | 17.0K | 21.6K | 1.25 | 54.3 | 58.0 | 46.2 | 58.9 | 50 |
| [#23](bench_elixir.exs#L431-L438) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **566.1** | 567.8 ± 7.17 | 1.3% | 1.7K | 1.8K | 9.45 | 578.4 | 579.5 | 556.4 | 579.8 | 50 |
| [#24](bench_elixir.exs#L439-L455) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **64.9** | 64.8 ± 5.01 | 7.7% | 14.2K | 17.0K | 9.27 | 70.3 | 70.4 | 58.9 | 70.4 | 50 |
| [#25](bench_elixir.exs#L456-L470) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **5.63** | 5.38 ± 0.51 | 9.5% | 162K | 213K | 0.76 | 5.97 | 6.13 | 4.69 | 6.17 | 100 |
| [#26](bench_elixir.exs#L471-L487) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **253.8** | 258.4 ± 11.4 | 4.4% | 3.5K | 4.0K | 5.62 | 279.2 | 284.6 | 250.5 | 286.0 | 50 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `6641d47147c9`, 10 samples across 2 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 7 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_client.odin#L748-L767) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **650** | 667 ± 77.3 | 11.6% | 1.1M | 1.6M | 64 | 789 | 854 | 609 | 870 | 500 |
| [#3](bench_client.odin#L785-L800) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **380** | 382 ± 8.1 | 2.1% | 2.5M | 2.7M | 6 | 396 | 398 | 373 | 398 | 500 |
| [#4](bench_client.odin#L802-L816) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **109** | 109 ± 0.7 | 0.6% | 9.1M | 9.3M | 1 | 110 | 110 | 108 | 110 | 500 |
| [#5](bench_client.odin#L818-L832) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **129** | 129 ± 6.2 | 4.8% | 6.9M | 8.1M | 5 | 139 | 144 | 124 | 145 | 500 |
| [#6](bench_client.odin#L834-L846) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **6** | 6 ± 0.0 | 0.0% | 167M | 167M | 0 | 6 | 6 | 6 | 6 | 1K |
| [#7](bench_client.odin#L848-L862) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **264** | 270 ± 16.3 | 6.1% | 3.2M | 3.9M | 7 | 296 | 311 | 259 | 315 | 1K |
| [#17](bench_client.odin#L1097-L1117) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **577** | 588 ± 37.8 | 6.4% | 1.5M | 1.8M | 63 | 643 | 648 | 548 | 649 | 100 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 19 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#2](bench_client.odin#L769-L783) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **1.10** | 1.13 ± 0.10 | 8.7% | 746K | 952K | 0.08 | 1.31 | 1.33 | 1.05 | 1.34 | 500 |
| [#8](bench_client.odin#L864-L883) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.63** | 1.67 ± 0.11 | 6.6% | 514K | 625K | 0.09 | 1.86 | 1.93 | 1.60 | 1.95 | 200 |
| [#9](bench_client.odin#L885-L908) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **1.50** | 1.50 ± 0.03 | 2.2% | 637K | 683K | 0.04 | 1.55 | 1.57 | 1.47 | 1.57 | 200 |
| [#10](bench_client.odin#L910-L931) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **35.9** | 37.5 ± 3.66 | 9.8% | 22.0K | 28.7K | 2.69 | 44.2 | 45.2 | 34.9 | 45.4 | 50 |
| [#11](bench_client.odin#L933-L948) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **2.71** | 2.73 ± 0.09 | 3.5% | 342K | 383K | 0.09 | 2.88 | 2.92 | 2.61 | 2.92 | 200 |
| [#12](bench_client.odin#L950-L972) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **13.1** | 17.1 ± 7.97 | 46.6% | 30.8K | 77.4K | 1.31 | 32.2 | 32.5 | 12.9 | 32.5 | 100 |
| [#13](bench_client.odin#L974-L993) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **498.4** | 500.4 ± 18.5 | 3.7% | 1.9K | 2.1K | 16.5 | 531.7 | 537.9 | 479.9 | 539.5 | 1 |
| [#14](bench_client.odin#L995-L1017) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **3.76** | 3.85 ± 0.24 | 6.2% | 224K | 272K | 0.09 | 4.26 | 4.43 | 3.67 | 4.47 | 100 |
| [#15](bench_client.odin#L1019-L1044) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **5.48** | 5.62 ± 0.39 | 6.9% | 157K | 191K | 0.17 | 6.33 | 6.38 | 5.23 | 6.39 | 50 |
| [#16](bench_client.odin#L1046-L1073) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **4.11** | 4.17 ± 0.30 | 7.2% | 211K | 260K | 0.45 | 4.62 | 4.71 | 3.84 | 4.74 | 100 |
| [#18](bench_client.odin#L1119-L1132) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **72.4** | 73.7 ± 4.32 | 5.9% | 12.0K | 14.3K | 4.29 | 80.8 | 83.0 | 70.2 | 83.5 | 50 |
| [#19](bench_client.odin#L1151-L1164) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **184.2** | 187.4 ± 9.34 | 5.0% | 4.9K | 5.6K | 15.8 | 201.0 | 201.9 | 179.1 | 202.1 | 50 |
| [#20](bench_client.odin#L1166-L1186) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **18.9** | 19.2 ± 0.85 | 4.5% | 48.6K | 55.5K | 1.25 | 20.4 | 20.5 | 18.0 | 20.6 | 20 |
| [#21](bench_client.odin#L1188-L1203) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **2.88** | 2.84 ± 0.13 | 4.4% | 334K | 371K | 0.23 | 2.98 | 2.99 | 2.69 | 2.99 | 200 |
| [#22](bench_client.odin#L1205-L1226) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **25.7** | 25.9 ± 1.00 | 3.9% | 35.5K | 39.8K | 0.57 | 27.7 | 28.1 | 25.1 | 28.2 | 50 |
| [#23](bench_client.odin#L1228-L1247) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **498.0** | 496.8 ± 25.2 | 5.1% | 1.9K | 2.1K | 45.0 | 528.9 | 533.9 | 465.9 | 535.2 | 50 |
| [#24](bench_client.odin#L1249-L1268) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **51.1** | 51.4 ± 0.62 | 1.2% | 18.9K | 19.6K | 0.76 | 52.4 | 52.7 | 50.9 | 52.8 | 50 |
| [#25](bench_client.odin#L1270-L1306) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **1.54** | 1.53 ± 0.03 | 2.3% | 628K | 670K | 0.04 | 1.59 | 1.59 | 1.49 | 1.59 | 100 |
| [#26](bench_client.odin#L1308-L1336) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **159.0** | 159.2 ± 2.65 | 1.7% | 6.1K | 6.4K | 4.32 | 162.6 | 163.6 | 156.7 | 163.9 | 50 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `6641d47147c9`)

#### 3.1 Sub-Microsecond Fast Path (Elixir `< 1 µs`, 5 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **1.64x** | 380 | **624** | `43.1` ★ | 382 ± 8.1 | 2.1% | 628 ± 16.2 | 2.6% |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **3.50x** | 109 | **382** | `52.8` ★ | 109 ± 0.7 | 0.6% | 381 ± 16.3 | 4.3% |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **3.22x** | 129 | **416** | `15.1` ★ | 129 ± 6.2 | 4.8% | 441 ± 64.8 | 14.7% |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **29.00x** | 6 | **174** | `17.4` ★ | 6 ± 0.0 | 0.0% | 185 ± 32.6 | 17.6% |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **2.86x** | 264 | **756** | `50.4` ★ | 270 ± 16.3 | 6.1% | 769 ± 26.7 | 3.5% |


#### 3.2 Multi-Microsecond Client Operations (Elixir `≥ 1 µs`, 21 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **3.83x** | 0.65 | **2.49** | `35.6` ★ | 0.67 ± 0.08 | 11.6% | 2.50 ± 0.14 | 5.7% |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **2.07x** | 1.10 | **2.28** | `32.9` ★ | 1.13 ± 0.10 | 8.7% | 2.29 ± 0.05 | 2.2% |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **2.22x** | 1.63 | **3.61** | `23.6` ★ | 1.67 ± 0.11 | 6.6% | 3.60 ± 0.23 | 6.5% |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **3.14x** | 1.50 | **4.71** | `40.3` ★ | 1.50 ± 0.03 | 2.2% | 4.79 ± 0.26 | 5.3% |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **2.31x** | 35.9 | **82.7** | `14.9` ★ | 37.5 ± 3.66 | 9.8% | 84.6 ± 9.31 | 11.0% |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **2.10x** | 2.71 | **5.70** | `52.8` ★ | 2.73 ± 0.09 | 3.5% | 5.72 ± 0.15 | 2.7% |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **3.58x** | 13.1 | **47.0** | `5.0` ★ | 17.1 ± 7.97 | 46.6% | 47.3 ± 17.2 | 36.5% |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **3.65x** | 498.4 | **1817.8** | `4.6` ★ | 500.4 ± 18.5 | 3.7% | 1886.1 ± 960.9 | 50.9% |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **7.07x** | 3.76 | **26.6** | `4.8` ★ | 3.85 ± 0.24 | 6.2% | 26.7 ± 15.1 | 56.6% |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **3.49x** | 5.48 | **19.1** | `4.8` ★ | 5.62 ± 0.39 | 6.9% | 21.3 ± 10.2 | 48.0% |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **2.70x** | 4.11 | **11.1** | `4.7` ★ | 4.17 ± 0.30 | 7.2% | 13.7 ± 6.45 | 47.1% |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **5.53x** | 0.58 | **3.19** | `3.5` ★ | 0.59 ± 0.04 | 6.4% | 4.56 ± 3.59 | 78.7% |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **3.05x** | 72.4 | **221.1** | `32.7` ★ | 73.7 ± 4.32 | 5.9% | 224.3 ± 13.9 | 6.2% |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **1.80x** | 184.2 | **332.3** | `15.1` ★ | 187.4 ± 9.34 | 5.0% | 346.6 ± 32.0 | 9.2% |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **1.53x** | 18.9 | **29.0** | `6.7` ★ | 19.2 ± 0.85 | 4.5% | 32.3 ± 6.14 | 19.0% |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **3.31x** | 2.88 | **9.53** | `22.3` ★ | 2.84 ± 0.13 | 4.4% | 9.05 ± 0.87 | 9.6% |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **1.83x** | 25.7 | **47.1** | `17.9` ★ | 25.9 ± 1.00 | 3.9% | 48.3 ± 3.82 | 7.9% |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **1.14x** | 498.0 | **566.1** | `8.6` ★ | 496.8 ± 25.2 | 5.1% | 567.8 ± 7.17 | 1.3% |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **1.27x** | 51.1 | **64.9** | `8.4` ★ | 51.4 ± 0.62 | 1.2% | 64.8 ± 5.01 | 7.7% |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **3.66x** | 1.54 | **5.63** | `23.9` ★ | 1.53 ± 0.03 | 2.3% | 5.38 ± 0.51 | 9.5% |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **1.60x** | 159.0 | **253.8** | `26.9` ★ | 159.2 ± 2.65 | 1.7% | 258.4 ± 11.4 | 4.4% |

### 4. Commit-vs-Commit Progression


#### 4.1 Elixir Client Wrapper (`0421fe5300ba` → `6641d47147c9`)

| # | Benchmark | `0421fe5300ba` Med | `6641d47147c9` Med | Δ% | Speedup | Welch `z` | `0421fe5300ba` Mean ± σ | `6641d47147c9` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 2.52 µs | **2.49 µs** | -1.3% | **1.01x** | `0.1` ~ | 2.51 µs ± 161 ns | 2.50 µs ± 143 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 2.44 µs | **2.28 µs** | -6.7% | **1.07x** | `6.9` ★ | 2.45 µs ± 39 ns | 2.29 µs ± 51 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 636 ns | **624 ns** | -1.9% | **1.02x** | `1.8` ~ | 638 ns ± 6 ns | 628 ns ± 16 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 331 ns | **382 ns** | +15.3% | **0.87x** | `7.1` ★ | 333 ns ± 10 ns | 381 ns ± 16 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 365 ns | **416 ns** | +14.0% | **0.88x** | `3.0` ★ | 375 ns ± 18 ns | 441 ns ± 65 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 195 ns | **174 ns** | -10.8% | **1.12x** | `1.5` ~ | 205 ns ± 18 ns | 185 ns ± 33 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 698 ns | **756 ns** | +8.2% | **0.92x** | `7.2` ★ | 697 ns ± 12 ns | 769 ns ± 27 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 3.36 µs | **3.61 µs** | +7.5% | **0.93x** | `2.8` ★ | 3.38 µs ± 68 ns | 3.60 µs ± 233 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 4.68 µs | **4.71 µs** | +0.5% | **1.00x** | `1.5` ~ | 4.66 µs ± 95 ns | 4.79 µs ± 256 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 81.4 µs | **82.7 µs** | +1.7% | **0.98x** | `1.0` ~ | 81.6 µs ± 761 ns | 84.6 µs ± 9.31 µs |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 3.34 µs | **5.70 µs** | +70.4% | **0.59x** | `37.3` ★ | 3.38 µs ± 90 ns | 5.72 µs ± 153 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 53.7 µs | **47.0 µs** | -12.4% | **1.14x** | `1.4` ~ | 54.9 µs ± 2.65 µs | 47.3 µs ± 17.2 µs |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 2.06 ms | **1.82 ms** | -11.9% | **1.13x** | `0.8` ~ | 2.12 ms ± 107.7 µs | 1.89 ms ± 960.9 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 22.5 µs | **26.6 µs** | +18.5% | **0.84x** | `0.7` ~ | 23.2 µs ± 1.88 µs | 26.7 µs ± 15.1 µs |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 19.7 µs | **19.1 µs** | -3.2% | **1.03x** | `0.4` ~ | 19.9 µs ± 578 ns | 21.3 µs ± 10.2 µs |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 12.0 µs | **11.1 µs** | -7.2% | **1.08x** | `0.6` ~ | 12.4 µs ± 2.21 µs | 13.7 µs ± 6.45 µs |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 2.59 µs | **3.19 µs** | +23.3% | **0.81x** | `1.7` ~ | 2.58 µs ± 160 ns | 4.56 µs ± 3.59 µs |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 207.8 µs | **221.1 µs** | +6.4% | **0.94x** | `2.9` ★ | 210.0 µs ± 5.20 µs | 224.3 µs ± 13.9 µs |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 329.5 µs | **332.3 µs** | +0.9% | **0.99x** | `1.1` ~ | 333.8 µs ± 14.6 µs | 346.6 µs ± 32.0 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 28.7 µs | **29.0 µs** | +1.3% | **0.99x** | `2.1` ★ | 28.2 µs ± 1.09 µs | 32.3 µs ± 6.14 µs |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 5.77 µs | **9.53 µs** | +65.2% | **0.61x** | `11.5` ★ | 5.83 µs ± 131 ns | 9.05 µs ± 870 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 48.3 µs | **47.1 µs** | -2.5% | **1.03x** | `0.1` ~ | 48.3 µs ± 214 ns | 48.3 µs ± 3.82 µs |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 579.1 µs | **566.1 µs** | -2.2% | **1.02x** | `4.5` ★ | 579.4 µs ± 2.63 µs | 567.8 µs ± 7.17 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 80.0 µs | **64.9 µs** | -18.9% | **1.23x** | `3.0` ★ | 77.1 µs ± 8.36 µs | 64.8 µs ± 5.01 µs |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 5.62 µs | **5.63 µs** | +0.3% | **1.00x** | `1.7` ~ | 5.65 µs ± 66 ns | 5.38 µs ± 509 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 257.0 µs | **253.8 µs** | -1.3% | **1.01x** | `0.7` ~ | 263.7 µs ± 15.3 µs | 258.4 µs ± 11.4 µs |



#### 4.2 Raw Odin Baseline (`0421fe5300ba` → `6641d47147c9`)

| # | Benchmark | `0421fe5300ba` Med | `6641d47147c9` Med | Δ% | Speedup | Welch `z` | `0421fe5300ba` Mean ± σ | `6641d47147c9` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 631 ns | **650 ns** | +2.9% | **0.97x** | `0.0` ~ | 665 ns ± 83 ns | 667 ns ± 77 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 1.09 µs | **1.10 µs** | +0.9% | **0.99x** | `0.8` ~ | 1.22 µs ± 225 ns | 1.13 µs ± 99 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 405 ns | **380 ns** | -6.2% | **1.07x** | `2.2` ★ | 425 ns ± 44 ns | 382 ns ± 8 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 160 ns | **109 ns** | -31.9% | **1.47x** | `25.1` ★ | 160 ns ± 5 ns | 109 ns ± 1 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 193 ns | **129 ns** | -33.2% | **1.50x** | `17.4` ★ | 192 ns ± 7 ns | 129 ns ± 6 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 12 ns | **6 ns** | -50.0% | **2.00x** | `99.0` ★ | 12 ns ± 0 ns | 6 ns ± 0 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 410 ns | **264 ns** | -35.6% | **1.55x** | `4.9` ★ | 399 ns ± 58 ns | 270 ns ± 16 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 1.66 µs | **1.63 µs** | -1.8% | **1.02x** | `0.2` ~ | 1.68 µs ± 96 ns | 1.67 µs ± 110 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 1.44 µs | **1.50 µs** | +4.3% | **0.96x** | `4.4` ★ | 1.44 µs ± 18 ns | 1.50 µs ± 34 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 36.4 µs | **35.9 µs** | -1.4% | **1.01x** | `0.6` ~ | 36.8 µs ± 1.19 µs | 37.5 µs ± 3.66 µs |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 2.69 µs | **2.71 µs** | +1.1% | **0.99x** | `0.1` ~ | 2.73 µs ± 105 ns | 2.73 µs ± 94 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 13.6 µs | **13.1 µs** | -3.2% | **1.03x** | `1.2` ~ | 14.0 µs ± 1.09 µs | 17.1 µs ± 7.97 µs |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 486.3 µs | **498.4 µs** | +2.5% | **0.98x** | `0.5` ~ | 495.6 µs ± 16.9 µs | 500.4 µs ± 18.5 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 3.90 µs | **3.76 µs** | -3.4% | **1.04x** | `0.1` ~ | 3.86 µs ± 139 ns | 3.85 µs ± 239 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 5.46 µs | **5.48 µs** | +0.4% | **1.00x** | `0.1` ~ | 5.61 µs ± 465 ns | 5.62 µs ± 389 ns |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 4.18 µs | **4.11 µs** | -1.7% | **1.02x** | `0.4` ~ | 4.13 µs ± 149 ns | 4.17 µs ± 299 ns |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 552 ns | **577 ns** | +4.4% | **0.96x** | `3.0` ★ | 552 ns ± 2 ns | 588 ns ± 38 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 73.0 µs | **72.4 µs** | -0.8% | **1.01x** | `0.7` ~ | 77.7 µs ± 12.4 µs | 73.7 µs ± 4.32 µs |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 183.3 µs | **184.2 µs** | +0.5% | **0.99x** | `0.7` ~ | 184.7 µs ± 6.38 µs | 187.4 µs ± 9.34 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 18.4 µs | **18.9 µs** | +2.9% | **0.97x** | `1.4` ~ | 18.6 µs ± 708 ns | 19.2 µs ± 855 ns |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 2.82 µs | **2.88 µs** | +2.1% | **0.98x** | `0.4` ~ | 2.81 µs ± 155 ns | 2.84 µs ± 125 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 25.7 µs | **25.7 µs** | -0.2% | **1.00x** | `0.3` ~ | 25.8 µs ± 854 ns | 25.9 µs ± 998 ns |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 485.7 µs | **498.0 µs** | +2.5% | **0.98x** | `0.5` ~ | 491.6 µs ± 15.0 µs | 496.8 µs ± 25.2 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 50.9 µs | **51.1 µs** | +0.3% | **1.00x** | `0.5` ~ | 51.2 µs ± 674 ns | 51.4 µs ± 625 ns |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 1.50 µs | **1.54 µs** | +2.7% | **0.97x** | `0.1` ~ | 1.53 µs ± 69 ns | 1.53 µs ± 35 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 182.1 µs | **159.0 µs** | -12.7% | **1.15x** | `2.4` ★ | 188.3 µs ± 27.0 µs | 159.2 µs ± 2.65 µs |



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
