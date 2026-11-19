# Xitdb Elixir Client Benchmarks

This directory contains the 1v1 statistical benchmark suite for `Xitdb`, measuring **client-boundary overhead** and throughput (`ops/sec`), median/mean latency (`ns/op`), variance (`±σ`, `CV%`, `IQR`, `p95`, `p99`, `min..max`), and resulting database byte footprint between the **Elixir NIF Wrapper (`lang: "elixir"`)** and **Raw Odin (`lang: "odin"`)**.

Unlike the upstream `odin-xitdb` benchmark suite (which benchmarks low-level HAMT/B+Tree node splits, hashers, and raw byte streams), this suite focuses exclusively on **28 orthogonal, zero-redundancy client-facing workloads** across five groups:
1. **`access` (`#1–#5`, `#28`)**: 3-hop lazy `Access` HAMT navigation (`root["users"][id]["name"]`), single-call selector traversal (`Xitdb.select!/2`), pre-tokenized `path_steps/1` lookup (`#28`), `Sorted_Map` B+Tree binary-search key lookup (`sorted[key]`), `Array_List` 16-way Radix Trie indexing (`items[idx]`), and `Linked_Array_List` count-augmented B-Tree indexing (`linked[idx]`).
2. **`enumerable & stream` (`#6–#11`)**: `O(1)` `Enum.count/1` on `Counted_Hash_Map`, `O(1)` `Enum.member?/2` on `Counted_Hash_Set`, `O(log N)` `Enum.slice/2` on `Array_List`, bounded `Stream.take/2` early-halt on `Sorted_Map`, full `Enum.to_list/1` on `Array_List`, and `Xitdb.materialize/1` subtree conversion.
3. **`transactions` (`#12–#16`)**: Single-entity `Xitdb.transact/2` map commits, bulk 100-entity batch commits, incremental `put_in/3` cursor transactions, `O(log N)` mid-list `Xitdb.insert_at/4` + `Xitdb.delete_at/3` on `Linked_Array_List`, and `O(1)` zero-copy subtree `Xitdb.fork/3`.
4. **`time-travel & lifecycle` (`#17–#20`)**: `Xitdb.as_of/2` historical snapshot resolution across 100 moments, `Xitdb.history_of/2` attribute lineage scan across 100 moments, `O(delta)` `Xitdb.diff_moments/3` structural diffs, and `Xitdb.compact/1` 100-moment database deduplication.
5. **`queries, storage & search` (`#21–#27`)**: Datomic-style `Xitdb.pull/2` nested projections, Datalog B+Tree secondary index prefix seek + join (`Xitdb.query/2`), Datalog grouped aggregations (`count`, `sum`), on-disk `Buffered_File` transactional commits + `Xitdb.sync/1`, `Sorted_Map` B+Tree prefix seek (`limit=16`), BM25 corpus search (`N=200`, 2-term prefix, `limit=10`), and `Indexer` B+Tree range scan + set decode (`#27`, `limit=16`).

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

See [Benchmark Code Slices (`slices/README.md`)](slices/README.md) for side-by-side Elixir harness, Raw Odin baseline, Elixir/NIF wrapper, and reachable `xitdb` core engine call-graph views of `#1–#28`.

To regenerate the slices and reference tables below from `benchmarks/odin.jsonl`, `benchmarks/elixir.jsonl`, and `benchmarks/history.jsonl`:

```bash
./benchmarks/update_readme.sh
```

---

## NIF Boundary Cost Model

Across the 28 orthogonal workloads, the BEAM ↔ Odin NIF boundary separates cleanly into four latency regimes:

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
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `efa5ac160b4d`, 5 samples across 1 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 5 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#3](bench_elixir.exs#L240-L247) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **814** | 743 ± 168 | 22.6% | 1.1M | 1.8M | 303 | 900 | 906 | 562 | 908 | 500 |
| [#4](bench_elixir.exs#L248-L255) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **348** | 356 ± 15.3 | 4.3% | 2.6M | 2.9M | 6 | 377 | 382 | 347 | 383 | 500 |
| [#5](bench_elixir.exs#L256-L263) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **362** | 388 ± 43.9 | 11.3% | 2.2M | 2.8M | 28 | 448 | 460 | 361 | 463 | 500 |
| [#6](bench_elixir.exs#L264-L271) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **163** | 168 ± 10.0 | 6.0% | 5.5M | 6.3M | 17 | 180 | 181 | 160 | 181 | 1K |
| [#7](bench_elixir.exs#L272-L279) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **810** | 859 ± 140 | 16.2% | 909K | 1.3M | 66 | 1,050 | 1,090 | 751 | 1,100 | 1K |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 23 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_elixir.exs#L224-L231) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **2.37** | 2.39 ± 0.10 | 4.2% | 391K | 434K | 0.07 | 2.53 | 2.55 | 2.31 | 2.56 | 500 |
| [#2](bench_elixir.exs#L232-L239) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **2.20** | 2.24 ± 0.13 | 5.9% | 413K | 478K | 0.15 | 2.40 | 2.42 | 2.09 | 2.42 | 500 |
| [#8](bench_elixir.exs#L280-L287) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **3.05** | 3.04 ± 0.05 | 1.6% | 324K | 335K | 0.09 | 3.09 | 3.09 | 2.98 | 3.09 | 200 |
| [#9](bench_elixir.exs#L288-L295) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **3.91** | 3.95 ± 0.06 | 1.6% | 247K | 256K | 0.07 | 4.03 | 4.04 | 3.90 | 4.05 | 200 |
| [#10](bench_elixir.exs#L296-L303) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **63.9** | 65.0 ± 1.67 | 2.6% | 14.8K | 15.7K | 2.17 | 67.1 | 67.4 | 63.7 | 67.4 | 50 |
| [#11](bench_elixir.exs#L304-L311) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **4.65** | 4.77 ± 0.25 | 5.3% | 192K | 217K | 0.14 | 5.12 | 5.20 | 4.61 | 5.21 | 200 |
| [#12](bench_elixir.exs#L312-L338) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **13.1** | 14.1 ± 1.78 | 12.6% | 60.1K | 79.3K | 2.44 | 16.4 | 16.6 | 12.6 | 16.6 | 100 |
| [#13](bench_elixir.exs#L339-L354) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **446.0** | 438.3 ± 50.9 | 11.6% | 2.0K | 2.7K | 58.2 | 493.2 | 498.2 | 368.4 | 499.5 | 1 |
| [#14](bench_elixir.exs#L355-L369) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **14.3** | 14.3 ± 0.14 | 1.0% | 69.0K | 70.7K | 0.20 | 14.5 | 14.5 | 14.1 | 14.5 | 100 |
| [#15](bench_elixir.exs#L370-L390) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **14.3** | 14.9 ± 1.49 | 10.0% | 57.2K | 71.8K | 0.48 | 16.9 | 17.4 | 13.9 | 17.5 | 50 |
| [#16](bench_elixir.exs#L391-L408) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **11.0** | 11.0 ± 0.64 | 5.9% | 83.1K | 96.6K | 0.52 | 11.8 | 12.0 | 10.3 | 12.0 | 100 |
| [#17](bench_elixir.exs#L409-L417) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **2.33** | 2.39 ± 0.10 | 4.1% | 399K | 435K | 0.16 | 2.50 | 2.50 | 2.30 | 2.50 | 100 |
| [#18](bench_elixir.exs#L418-L425) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **54.8** | 56.2 ± 8.24 | 14.6% | 14.7K | 21.1K | 9.79 | 66.5 | 67.8 | 47.3 | 68.1 | 50 |
| [#19](bench_elixir.exs#L426-L433) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **325.2** | 442.0 ± 183.9 | 41.6% | 1.3K | 3.1K | 170.0 | 693.7 | 733.6 | 322.9 | 743.5 | 50 |
| [#20](bench_elixir.exs#L434-L445) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **47.5** | 456.5 ± 921.1 | 201.8% | 475 | 24.9K | 4.68 | 1692.8 | 2021.9 | 40.2 | 2104.2 | 20 |
| [#21](bench_elixir.exs#L446-L453) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **16.4** | 36.4 ± 49.6 | 136.1% | 8.0K | 88.0K | 5.07 | 103.4 | 120.7 | 11.4 | 125.0 | 200 |
| [#22](bench_elixir.exs#L454-L461) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **82.7** | 82.7 ± 0.37 | 0.4% | 12.0K | 12.2K | 0.55 | 83.1 | 83.1 | 82.3 | 83.1 | 50 |
| [#23](bench_elixir.exs#L462-L469) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **2000.3** | 2723.4 ± 2119.8 | 77.8% | 159 | 970 | 1541.7 | 5617.0 | 6156.9 | 1031.1 | 6291.8 | 50 |
| [#24](bench_elixir.exs#L470-L486) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **80.2** | 82.2 ± 5.95 | 7.2% | 10.8K | 12.8K | 2.44 | 90.4 | 92.2 | 78.3 | 92.7 | 50 |
| [#25](bench_elixir.exs#L487-L501) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **11.5** | 12.4 ± 1.79 | 14.5% | 64.4K | 88.7K | 0.76 | 14.9 | 15.4 | 11.3 | 15.5 | 100 |
| [#26](bench_elixir.exs#L502-L518) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **421.2** | 397.0 ± 46.6 | 11.8% | 2.3K | 3.1K | 51.9 | 433.9 | 435.2 | 324.6 | 435.5 | 50 |
| [#27](bench_elixir.exs#L519-L535) | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **18.4** | 18.2 ± 0.85 | 4.7% | 51.9K | 58.3K | 1.08 | 19.1 | 19.2 | 17.2 | 19.3 | 50 |
| [#28](bench_elixir.exs#L536-L544) | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **2.79** | 2.99 ± 0.68 | 22.7% | 258K | 442K | 1.00 | 3.80 | 3.86 | 2.26 | 3.87 | 500 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `efa5ac160b4d`, 5 samples across 1 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 8 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_client.odin#L875-L894) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **681** | 707 ± 83.0 | 11.7% | 1.2M | 1.6M | 114 | 812 | 822 | 627 | 825 | 500 |
| [#3](bench_client.odin#L912-L927) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **398** | 397 ± 4.7 | 1.2% | 2.5M | 2.6M | 7 | 402 | 402 | 391 | 402 | 500 |
| [#4](bench_client.odin#L929-L943) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **116** | 116 ± 0.0 | 0.0% | 8.6M | 8.6M | 0 | 116 | 116 | 116 | 116 | 500 |
| [#5](bench_client.odin#L945-L959) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **130** | 131 ± 4.4 | 3.3% | 7.2M | 7.8M | 2 | 137 | 139 | 128 | 139 | 500 |
| [#6](bench_client.odin#L961-L973) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **7** | 7 ± 0.0 | 0.0% | 143M | 143M | 0 | 7 | 7 | 7 | 7 | 1K |
| [#7](bench_client.odin#L975-L989) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **264** | 278 ± 31.5 | 11.3% | 3.0M | 3.8M | 11 | 322 | 332 | 260 | 334 | 1K |
| [#17](bench_client.odin#L1214-L1234) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **560** | 587 ± 66.9 | 11.4% | 1.4M | 1.8M | 2 | 677 | 700 | 546 | 706 | 100 |
| [#28](bench_client.odin#L1554-L1583) | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **913** | 937 ± 61.9 | 6.6% | 956K | 1.1M | 12 | 1,021 | 1,041 | 893 | 1,046 | 500 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 20 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#2](bench_client.odin#L896-L910) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **1.17** | 1.16 ± 0.07 | 5.7% | 819K | 943K | 0.08 | 1.22 | 1.22 | 1.06 | 1.22 | 500 |
| [#8](bench_client.odin#L991-L1010) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.77** | 1.83 ± 0.10 | 5.4% | 510K | 576K | 0.14 | 1.95 | 1.96 | 1.74 | 1.96 | 200 |
| [#9](bench_client.odin#L1012-L1035) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **1.53** | 1.57 ± 0.06 | 4.0% | 601K | 658K | 0.07 | 1.65 | 1.66 | 1.52 | 1.67 | 200 |
| [#10](bench_client.odin#L1037-L1058) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **37.0** | 37.0 ± 0.36 | 1.0% | 26.8K | 27.5K | 0.26 | 37.3 | 37.3 | 36.4 | 37.4 | 50 |
| [#11](bench_client.odin#L1060-L1075) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **3.31** | 3.10 ± 0.43 | 13.9% | 282K | 390K | 0.66 | 3.51 | 3.53 | 2.57 | 3.54 | 200 |
| [#12](bench_client.odin#L1077-L1094) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **9.74** | 9.29 ± 1.46 | 15.7% | 96.3K | 146K | 1.28 | 10.4 | 10.4 | 6.87 | 10.4 | 100 |
| [#13](bench_client.odin#L1096-L1110) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **300.2** | 326.4 ± 76.4 | 23.4% | 2.2K | 3.5K | 16.4 | 430.1 | 455.9 | 283.7 | 462.3 | 1 |
| [#14](bench_client.odin#L1112-L1134) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **6.68** | 6.92 ± 0.46 | 6.6% | 130K | 151K | 0.35 | 7.55 | 7.66 | 6.61 | 7.69 | 100 |
| [#15](bench_client.odin#L1136-L1161) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **10.2** | 10.5 ± 2.37 | 22.5% | 76.7K | 139K | 2.98 | 12.9 | 13.0 | 7.21 | 13.0 | 50 |
| [#16](bench_client.odin#L1163-L1190) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **4.76** | 5.46 ± 1.54 | 28.3% | 137K | 253K | 2.59 | 7.22 | 7.28 | 3.95 | 7.29 | 100 |
| [#18](bench_client.odin#L1236-L1249) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **31.2** | 31.3 ± 0.19 | 0.6% | 31.7K | 32.2K | 0.08 | 31.5 | 31.6 | 31.1 | 31.6 | 50 |
| [#19](bench_client.odin#L1268-L1281) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **181.3** | 184.2 ± 9.16 | 5.0% | 5.0K | 5.7K | 9.47 | 196.1 | 197.7 | 174.8 | 198.1 | 50 |
| [#20](bench_client.odin#L1283-L1303) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **28.7** | 28.9 ± 1.41 | 4.9% | 32.3K | 36.4K | 1.80 | 30.7 | 30.9 | 27.5 | 31.0 | 20 |
| [#21](bench_client.odin#L1305-L1320) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **3.28** | 3.28 ± 0.22 | 6.7% | 288K | 341K | 0.22 | 3.47 | 3.47 | 2.93 | 3.47 | 200 |
| [#22](bench_client.odin#L1322-L1343) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **42.3** | 42.9 ± 2.08 | 4.8% | 21.6K | 24.6K | 1.16 | 45.6 | 46.1 | 40.7 | 46.2 | 50 |
| [#23](bench_client.odin#L1345-L1364) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **580.6** | 575.8 ± 108.4 | 18.8% | 1.3K | 2.1K | 89.8 | 714.6 | 740.3 | 469.4 | 746.7 | 50 |
| [#24](bench_client.odin#L1366-L1385) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **79.3** | 78.9 ± 1.64 | 2.1% | 12.4K | 13.0K | 2.50 | 80.6 | 80.7 | 76.9 | 80.8 | 50 |
| [#25](bench_client.odin#L1387-L1442) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **2.86** | 2.84 ± 0.13 | 4.7% | 335K | 373K | 0.21 | 2.98 | 2.99 | 2.68 | 2.99 | 100 |
| [#26](bench_client.odin#L1444-L1472) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **197.2** | 206.4 ± 27.2 | 13.2% | 4.1K | 5.5K | 46.6 | 238.6 | 240.5 | 182.2 | 241.0 | 50 |
| [#27](bench_client.odin#L1474-L1552) | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **7.95** | 8.23 ± 0.49 | 5.9% | 113K | 128K | 0.85 | 8.80 | 8.82 | 7.84 | 8.83 | 50 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `efa5ac160b4d`)

#### 3.1 Sub-Microsecond Fast Path (Elixir `< 1 µs`, 5 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **2.05x** | 398 | **814** | `4.6` ★ | 397 ± 4.7 | 1.2% | 743 ± 168 | 22.6% |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **3.00x** | 116 | **348** | `35.0` ★ | 116 ± 0.0 | 0.0% | 356 ± 15.3 | 4.3% |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **2.78x** | 130 | **362** | `13.0` ★ | 131 ± 4.4 | 3.3% | 388 ± 43.9 | 11.3% |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **23.29x** | 7 | **163** | `35.9` ★ | 7 ± 0.0 | 0.0% | 168 ± 10.0 | 6.0% |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **3.07x** | 264 | **810** | `9.1` ★ | 278 ± 31.5 | 11.3% | 859 ± 140 | 16.2% |


#### 3.2 Multi-Microsecond Client Operations (Elixir `≥ 1 µs`, 23 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **3.48x** | 0.68 | **2.37** | `28.9` ★ | 0.71 ± 0.08 | 11.7% | 2.39 ± 0.10 | 4.2% |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **1.88x** | 1.17 | **2.20** | `16.4` ★ | 1.16 ± 0.07 | 5.7% | 2.24 ± 0.13 | 5.9% |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.72x** | 1.77 | **3.05** | `24.3` ★ | 1.83 ± 0.10 | 5.4% | 3.04 ± 0.05 | 1.6% |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **2.56x** | 1.53 | **3.91** | `60.7` ★ | 1.57 ± 0.06 | 4.0% | 3.95 ± 0.06 | 1.6% |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **1.73x** | 37.0 | **63.9** | `36.7` ★ | 37.0 ± 0.36 | 1.0% | 65.0 ± 1.67 | 2.6% |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **1.41x** | 3.31 | **4.65** | `7.5` ★ | 3.10 ± 0.43 | 13.9% | 4.77 ± 0.25 | 5.3% |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **1.34x** | 9.74 | **13.1** | `4.7` ★ | 9.29 ± 1.46 | 15.7% | 14.1 ± 1.78 | 12.6% |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **1.49x** | 300.2 | **446.0** | `2.7` ★ | 326.4 ± 76.4 | 23.4% | 438.3 ± 50.9 | 11.6% |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **2.14x** | 6.68 | **14.3** | `34.5` ★ | 6.92 ± 0.46 | 6.6% | 14.3 ± 0.14 | 1.0% |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **1.40x** | 10.2 | **14.3** | `3.5` ★ | 10.5 ± 2.37 | 22.5% | 14.9 ± 1.49 | 10.0% |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **2.31x** | 4.76 | **11.0** | `7.4` ★ | 5.46 ± 1.54 | 28.3% | 11.0 ± 0.64 | 5.9% |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **4.16x** | 0.56 | **2.33** | `34.1` ★ | 0.59 ± 0.07 | 11.4% | 2.39 ± 0.10 | 4.1% |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **1.75x** | 31.2 | **54.8** | `6.8` ★ | 31.3 ± 0.19 | 0.6% | 56.2 ± 8.24 | 14.6% |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **1.79x** | 181.3 | **325.2** | `3.1` ★ | 184.2 ± 9.16 | 5.0% | 442.0 ± 183.9 | 41.6% |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **1.65x** | 28.7 | **47.5** | `1.0` ~ | 28.9 ± 1.41 | 4.9% | 456.5 ± 921.1 | 201.8% |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **4.98x** | 3.28 | **16.4** | `1.5` ~ | 3.28 ± 0.22 | 6.7% | 36.4 ± 49.6 | 136.1% |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **1.96x** | 42.3 | **82.7** | `42.3` ★ | 42.9 ± 2.08 | 4.8% | 82.7 ± 0.37 | 0.4% |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **3.45x** | 580.6 | **2000.3** | `2.3` ★ | 575.8 ± 108.4 | 18.8% | 2723.4 ± 2119.8 | 77.8% |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **1.01x** | 79.3 | **80.2** | `1.2` ~ | 78.9 ± 1.64 | 2.1% | 82.2 ± 5.95 | 7.2% |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **4.02x** | 2.86 | **11.5** | `11.9` ★ | 2.84 ± 0.13 | 4.7% | 12.4 ± 1.79 | 14.5% |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **2.14x** | 197.2 | **421.2** | `7.9` ★ | 206.4 ± 27.2 | 13.2% | 397.0 ± 46.6 | 11.8% |
| 27 | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **2.31x** | 7.95 | **18.4** | `22.7` ★ | 8.23 ± 0.49 | 5.9% | 18.2 ± 0.85 | 4.7% |
| 28 | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **3.05x** | 0.91 | **2.79** | `6.7` ★ | 0.94 ± 0.06 | 6.6% | 2.99 ± 0.68 | 22.7% |



### 4. Commit-vs-Commit Progression


#### 4.1 Elixir Client Wrapper (`415d6331d9d0` → `efa5ac160b4d`)

| # | Benchmark | `415d6331d9d0` Med | `efa5ac160b4d` Med | Δ% | Speedup | Welch `z` | `415d6331d9d0` Mean ± σ | `efa5ac160b4d` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 2.44 µs | **2.37 µs** | -2.8% | **1.03x** | `1.0` ~ | 2.43 µs ± 7 ns | 2.39 µs ± 100 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 2.02 µs | **2.20 µs** | +8.9% | **0.92x** | `3.6` ★ | 2.02 µs ± 10 ns | 2.24 µs ± 131 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 613 ns | **814 ns** | +32.8% | **0.75x** | `1.7` ~ | 618 ns ± 9 ns | 743 ns ± 168 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 351 ns | **348 ns** | -0.9% | **1.01x** | `0.7` ~ | 351 ns ± 6 ns | 356 ns ± 15 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 373 ns | **362 ns** | -2.9% | **1.03x** | `0.6` ~ | 375 ns ± 9 ns | 388 ns ± 44 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 156 ns | **163 ns** | +4.5% | **0.96x** | `1.2` ~ | 161 ns ± 10 ns | 168 ns ± 10 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 742 ns | **810 ns** | +9.2% | **0.92x** | `1.8` ~ | 745 ns ± 13 ns | 859 ns ± 140 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 3.05 µs | **3.05 µs** | +0.3% | **1.00x** | `0.5` ~ | 3.07 µs ± 161 ns | 3.04 µs ± 49 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 3.67 µs | **3.91 µs** | +6.6% | **0.94x** | `8.0` ★ | 3.68 µs ± 42 ns | 3.95 µs ± 62 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 64.0 µs | **63.9 µs** | -0.1% | **1.00x** | `1.3` ~ | 63.9 µs ± 786 ns | 65.0 µs ± 1.67 µs |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 5.70 µs | **4.65 µs** | -18.5% | **1.23x** | `8.0` ★ | 5.73 µs ± 93 ns | 4.77 µs ± 254 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 12.1 µs | **13.1 µs** | +7.6% | **0.93x** | `1.7` ~ | 12.6 µs ± 1.03 µs | 14.1 µs ± 1.78 µs |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 363.8 µs | **446.0 µs** | +22.6% | **0.82x** | `2.8` ★ | 371.6 µs ± 18.3 µs | 438.3 µs ± 50.9 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 14.1 µs | **14.3 µs** | +1.2% | **0.99x** | `1.9` ~ | 14.1 µs ± 139 ns | 14.3 µs ± 143 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 13.8 µs | **14.3 µs** | +3.8% | **0.96x** | `1.8` ~ | 13.7 µs ± 188 ns | 14.9 µs ± 1.49 µs |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 12.7 µs | **11.0 µs** | -13.7% | **1.16x** | `2.5` ★ | 12.9 µs ± 1.59 µs | 11.0 µs ± 645 ns |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 2.48 µs | **2.33 µs** | -6.0% | **1.06x** | `1.6` ~ | 2.47 µs ± 67 ns | 2.39 µs ± 97 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 48.7 µs | **54.8 µs** | +12.4% | **0.89x** | `2.0` ★ | 48.7 µs ± 735 ns | 56.2 µs ± 8.24 µs |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 325.3 µs | **325.2 µs** | -0.0% | **1.00x** | `1.4` ~ | 328.4 µs ± 5.25 µs | 442.0 µs ± 183.9 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 25.9 µs | **47.5 µs** | +83.3% | **0.55x** | `1.0` ~ | 26.6 µs ± 1.72 µs | 456.5 µs ± 921.1 µs |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 6.51 µs | **16.4 µs** | +151.4% | **0.40x** | `1.3` ~ | 6.51 µs ± 144 ns | 36.4 µs ± 49.6 µs |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 47.5 µs | **82.7 µs** | +74.2% | **0.57x** | `13.4` ★ | 49.7 µs ± 5.48 µs | 82.7 µs ± 372 ns |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 574.7 µs | **2.00 ms** | +248.1% | **0.29x** | `2.3` ★ | 572.8 µs ± 7.89 µs | 2.72 ms ± 2.12 ms |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 63.5 µs | **80.2 µs** | +26.2% | **0.79x** | `5.9` ★ | 64.3 µs ± 3.27 µs | 82.2 µs ± 5.95 µs |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 4.62 µs | **11.5 µs** | +148.8% | **0.40x** | `9.6` ★ | 4.63 µs ± 103 ns | 12.4 µs ± 1.79 µs |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 237.0 µs | **421.2 µs** | +77.7% | **0.56x** | `7.6` ★ | 238.2 µs ± 3.17 µs | 397.0 µs ± 46.6 µs |
| 27 | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | 11.7 µs | **18.4 µs** | +57.4% | **0.64x** | `17.2` ★ | 11.6 µs ± 57 ns | 18.2 µs ± 847 ns |
| 28 | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | 1.97 µs | **2.79 µs** | +41.7% | **0.71x** | `3.4` ★ | 1.97 µs ± 14 ns | 2.99 µs ± 678 ns |



#### 4.2 Raw Odin Baseline (`415d6331d9d0` → `efa5ac160b4d`)

| # | Benchmark | `415d6331d9d0` Med | `efa5ac160b4d` Med | Δ% | Speedup | Welch `z` | `415d6331d9d0` Mean ± σ | `efa5ac160b4d` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 638 ns | **681 ns** | +6.7% | **0.94x** | `1.9` ~ | 637 ns ± 16 ns | 707 ns ± 83 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 1.02 µs | **1.17 µs** | +15.5% | **0.87x** | `4.8` ★ | 1.02 µs ± 14 ns | 1.16 µs ± 66 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 384 ns | **398 ns** | +3.6% | **0.96x** | `1.1` ~ | 390 ns ± 14 ns | 397 ns ± 5 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 107 ns | **116 ns** | +8.4% | **0.92x** | `35.1` ★ | 107 ns ± 1 ns | 116 ns ± 0 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 118 ns | **130 ns** | +10.2% | **0.91x** | `6.0` ★ | 119 ns ± 2 ns | 131 ns ± 4 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 7 ns | **7 ns** | +0.0% | **1.00x** | `1.6` ~ | 9 ns ± 3 ns | 7 ns ± 0 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 260 ns | **264 ns** | +1.5% | **0.98x** | `1.1` ~ | 263 ns ± 5 ns | 278 ns ± 32 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 1.61 µs | **1.77 µs** | +9.8% | **0.91x** | `4.2` ★ | 1.63 µs ± 33 ns | 1.83 µs ± 99 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 1.47 µs | **1.53 µs** | +4.4% | **0.96x** | `2.9` ★ | 1.48 µs ± 27 ns | 1.57 µs ± 62 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 40.2 µs | **37.0 µs** | -7.9% | **1.09x** | `1.3` ~ | 39.7 µs ± 4.65 µs | 37.0 µs ± 359 ns |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 3.82 µs | **3.31 µs** | -13.5% | **1.16x** | `2.6` ★ | 3.67 µs ± 236 ns | 3.10 µs ± 431 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 6.23 µs | **9.74 µs** | +56.2% | **0.64x** | `4.3` ★ | 6.37 µs ± 382 ns | 9.29 µs ± 1.46 µs |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 182.5 µs | **300.2 µs** | +64.5% | **0.61x** | `4.3` ★ | 180.2 µs ± 6.49 µs | 326.4 µs ± 76.4 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 3.67 µs | **6.68 µs** | +81.8% | **0.55x** | `15.5` ★ | 3.70 µs ± 97 ns | 6.92 µs ± 456 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 5.39 µs | **10.2 µs** | +89.5% | **0.53x** | `4.8` ★ | 5.41 µs ± 235 ns | 10.5 µs ± 2.37 µs |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 3.84 µs | **4.76 µs** | +24.1% | **0.81x** | `2.4` ★ | 3.81 µs ± 91 ns | 5.46 µs ± 1.54 µs |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 554 ns | **560 ns** | +1.1% | **0.99x** | `1.1` ~ | 555 ns ± 3 ns | 587 ns ± 67 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 69.5 µs | **31.2 µs** | -55.1% | **2.23x** | `218.7` ★ | 69.7 µs ± 343 ns | 31.3 µs ± 192 ns |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 182.2 µs | **181.3 µs** | -0.5% | **1.00x** | `0.7` ~ | 191.4 µs ± 20.8 µs | 184.2 µs ± 9.16 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 18.9 µs | **28.7 µs** | +51.9% | **0.66x** | `14.9` ★ | 18.7 µs ± 586 ns | 28.9 µs ± 1.41 µs |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 2.72 µs | **3.28 µs** | +20.6% | **0.83x** | `5.5` ★ | 2.73 µs ± 41 ns | 3.28 µs ± 220 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 25.7 µs | **42.3 µs** | +64.7% | **0.61x** | `16.5` ★ | 26.1 µs ± 927 ns | 42.9 µs ± 2.08 µs |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 470.8 µs | **580.6 µs** | +23.3% | **0.81x** | `2.1` ★ | 475.3 µs ± 12.0 µs | 575.8 µs ± 108.4 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 51.3 µs | **79.3 µs** | +54.5% | **0.65x** | `37.4` ★ | 51.3 µs ± 129 ns | 78.9 µs ± 1.64 µs |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 1.65 µs | **2.86 µs** | +73.0% | **0.58x** | `19.5` ★ | 1.67 µs ± 25 ns | 2.84 µs ± 133 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 157.7 µs | **197.2 µs** | +25.1% | **0.80x** | `4.0` ★ | 157.9 µs ± 677 ns | 206.4 µs ± 27.2 µs |
| 27 | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | 7.90 µs | **7.95 µs** | +0.6% | **0.99x** | `1.4` ~ | 7.92 µs ± 77 ns | 8.23 µs ± 488 ns |
| 28 | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | 873 ns | **913 ns** | +4.6% | **0.96x** | `2.3` ★ | 873 ns ± 10 ns | 937 ns ± 62 ns |



### 5. Database Storage Footprint (`bytes_used > 0`)

| # | Benchmark | Ops | Raw Odin Size | Elixir Wrapper Size |
| ---: | :--- | ---: | ---: | ---: |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 100 | 128.3 KB | 128.3 KB |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 1 | 33.5 KB | 33.5 KB |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 100 | 85.3 KB | 85.3 KB |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 50 | 69.7 KB | 69.7 KB |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 100 | 737.3 KB | 731.1 KB |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 20 | 1.0 KB | 1.0 KB |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 50 | 38.5 KB | 38.5 KB |
<!-- END_BENCHMARK_TABLE -->
