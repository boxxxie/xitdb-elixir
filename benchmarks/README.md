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

1. **Single-Hop Read Floor (`~170–290 ns` per NIF call — `#3–#6`):**
   Every RW-locked NIF crossing pays fixed `enif_get_resource`, `enif_rwlock_rlock`, `resolve_slot_coord`, and `enif_make_*` term construction overhead (`~174 ns` vs. `6 ns` Raw Odin on `O(1)` `Enum.count/1`, and `~245–285 ns` added to single-hop `Array_List`, `Linked_Array_List`, and `Sorted_Map` lookups).
2. **Multi-Hop Navigation vs. Single-Call Selectors & Projections (`#1`, `#2`, `#11`, `#21`):**
   Chaining `N` bracket hops via `Access` (`#1`: `root["users"][id]["name"]`) pays `N × ~255 ns` across separate NIF crossings plus intermediate `%Xitdb.Cursor{}` struct allocations (`~2.49 µs`), whereas `Xitdb.select!/2` (`#2`: `~2.28 µs`), `Xitdb.materialize/1` (`#11`: `~2.10x`), and `Xitdb.pull/2` (`#21`) collapse multi-step traversal or multi-field projection into a single NIF crossing.
3. **Transactional Write Batching vs. `put_in/3` (`tx` / Map `transact/3` vs. `#14`):**
   Single-call batched commits (`#12`, `#13`, `#15`, `#16` at `~1.96x–2.39x` after tier optimizations) pay only one NIF boundary crossing, whereas nested `put_in/3` (`#14`, `~3.27x` after optimizations) traverses intermediate maps via `Access.get_and_update/3`, issuing read-before-write `Cursor.fetch/2` NIF hops before staging the leaf write. Use `Xitdb.DSL.tx` (`put users[id].score, val`) or map `Xitdb.transact/3` in write-heavy paths.
4. **Compute- & Storage-Amortized Engine Operations (`1.09x–1.85x` near-native parity — `#19`, `#20`, `#22–#24`, `#26`):**
   When engine work dominates boundary marshaling—such as structural moment diffs (`#19`, `~1.80x`), database compaction (`#20`, `~1.53x`), Datalog index joins and aggregations (`#22` `~1.83x`, `#23` `~1.14x`), `Buffered_File` sync commits (`#24`, `~1.27x`), and BM25 corpus search (`#26`, `~1.60x`)—Elixir tracks Raw Odin closely.

See [Lazy Cursors, `Access` & `Enumerable`](../docs/access-and-enumerable.md#5-nif-boundary-cost-model--when-to-use-access-vs-the-macro-dsl) for API selection guidelines based on these regimes.

---

## Reference Results (`Elixir NIF Wrapper` vs. `Raw Odin`, `Core_Memory`)

<!-- BEGIN_BENCHMARK_TABLE -->
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `7cce79853656`, 5 samples across 1 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 5 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#3](bench_elixir.exs#L219-L226) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **612** | 616 ± 9.4 | 1.5% | 1.58M | 1.64M | 9 | 628 | 630 | 608 | 631 | 500 |
| [#4](bench_elixir.exs#L227-L234) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **375** | 379 ± 8.2 | 2.2% | 2.6M | 2.7M | 11 | 390 | 391 | 372 | 391 | 500 |
| [#5](bench_elixir.exs#L235-L242) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **402** | 404 ± 6.4 | 1.6% | 2.4M | 2.5M | 7 | 413 | 414 | 398 | 414 | 500 |
| [#6](bench_elixir.exs#L243-L250) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **167** | 168 ± 4.3 | 2.5% | 5.7M | 6.1M | 6 | 173 | 174 | 164 | 174 | 1K |
| [#7](bench_elixir.exs#L251-L258) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **738** | 744 ± 27.6 | 3.7% | 1.3M | 1.4M | 13 | 781 | 790 | 725 | 792 | 1K |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 21 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_elixir.exs#L203-L210) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **2.30** | 2.31 ± 0.02 | 1.0% | 425K | 435K | 0.01 | 2.34 | 2.35 | 2.30 | 2.35 | 500 |
| [#2](bench_elixir.exs#L211-L218) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **2.16** | 2.16 ± 0.01 | 0.3% | 461K | 464K | 0.01 | 2.17 | 2.17 | 2.15 | 2.17 | 500 |
| [#8](bench_elixir.exs#L259-L266) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **3.93** | 4.31 ± 1.00 | 23.2% | 179K | 295K | 1.67 | 5.50 | 5.57 | 3.39 | 5.59 | 200 |
| [#9](bench_elixir.exs#L267-L274) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **4.95** | 5.55 ± 1.31 | 23.6% | 128K | 211K | 0.65 | 7.36 | 7.74 | 4.74 | 7.84 | 200 |
| [#10](bench_elixir.exs#L275-L282) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **82.2** | 84.3 ± 4.58 | 5.4% | 11.1K | 12.6K | 6.00 | 89.9 | 90.4 | 79.5 | 90.5 | 50 |
| [#11](bench_elixir.exs#L283-L290) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **6.42** | 7.11 ± 1.95 | 27.5% | 94.7K | 176K | 0.21 | 9.76 | 10.4 | 5.69 | 10.6 | 200 |
| [#12](bench_elixir.exs#L291-L317) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **13.7** | 14.2 ± 1.04 | 7.3% | 62.4K | 73.3K | 0.40 | 15.6 | 16.0 | 13.6 | 16.0 | 100 |
| [#13](bench_elixir.exs#L318-L333) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **404.2** | 415.3 ± 27.1 | 6.5% | 2.2K | 2.6K | 36.2 | 450.1 | 453.8 | 390.9 | 454.7 | 1 |
| [#14](bench_elixir.exs#L334-L348) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **13.0** | 13.5 ± 1.58 | 11.8% | 61.6K | 81.3K | 0.56 | 15.6 | 16.1 | 12.3 | 16.2 | 100 |
| [#15](bench_elixir.exs#L349-L369) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **11.4** | 11.5 ± 0.17 | 1.5% | 84.8K | 87.8K | 0.21 | 11.8 | 11.8 | 11.4 | 11.8 | 50 |
| [#16](bench_elixir.exs#L370-L387) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **9.25** | 8.85 ± 0.78 | 8.8% | 103K | 127K | 1.10 | 9.59 | 9.65 | 7.86 | 9.67 | 100 |
| [#17](bench_elixir.exs#L388-L396) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **4.14** | 4.04 ± 0.21 | 5.2% | 239K | 272K | 0.16 | 4.18 | 4.18 | 3.68 | 4.18 | 100 |
| [#18](bench_elixir.exs#L397-L404) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **207.8** | 216.0 ± 15.1 | 7.0% | 4.1K | 4.8K | 11.3 | 236.8 | 240.6 | 206.4 | 241.6 | 50 |
| [#19](bench_elixir.exs#L405-L412) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **320.2** | 320.1 ± 0.39 | 0.1% | 3.12K | 3.13K | 0.29 | 320.5 | 320.6 | 319.5 | 320.6 | 50 |
| [#20](bench_elixir.exs#L413-L424) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **31.4** | 31.0 ± 4.33 | 13.9% | 26.4K | 36.8K | 3.96 | 36.6 | 37.6 | 27.2 | 37.9 | 20 |
| [#21](bench_elixir.exs#L425-L432) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **6.56** | 6.50 ± 0.18 | 2.8% | 149K | 160K | 0.23 | 6.69 | 6.71 | 6.27 | 6.71 | 200 |
| [#22](bench_elixir.exs#L433-L440) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **46.2** | 46.2 ± 0.14 | 0.3% | 21.5K | 21.7K | 0.16 | 46.4 | 46.4 | 46.1 | 46.4 | 50 |
| [#23](bench_elixir.exs#L441-L448) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **568.2** | 569.3 ± 1.95 | 0.3% | 1.7K | 1.8K | 1.52 | 572.0 | 572.4 | 567.9 | 572.6 | 50 |
| [#24](bench_elixir.exs#L449-L465) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **61.3** | 60.9 ± 1.56 | 2.6% | 15.8K | 16.9K | 1.46 | 62.8 | 63.1 | 59.1 | 63.1 | 50 |
| [#25](bench_elixir.exs#L466-L480) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **4.60** | 4.64 ± 0.12 | 2.6% | 206K | 220K | 0.06 | 4.81 | 4.85 | 4.55 | 4.86 | 100 |
| [#26](bench_elixir.exs#L481-L497) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **253.9** | 254.2 ± 0.70 | 0.3% | 3.92K | 3.94K | 1.01 | 255.1 | 255.2 | 253.5 | 255.2 | 50 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `7cce79853656`, 5 samples across 1 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 7 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_client.odin#L748-L767) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **650** | 643 ± 15.3 | 2.4% | 1.5M | 1.6M | 23 | 658 | 659 | 624 | 659 | 500 |
| [#3](bench_client.odin#L785-L800) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **377** | 383 ± 9.6 | 2.5% | 2.5M | 2.7M | 8 | 396 | 398 | 377 | 399 | 500 |
| [#4](bench_client.odin#L802-L816) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **109** | 109 ± 0.0 | 0.0% | 9.2M | 9.2M | 0 | 109 | 109 | 109 | 109 | 500 |
| [#5](bench_client.odin#L818-L832) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **122** | 122 ± 1.1 | 0.9% | 8.1M | 8.3M | 1 | 123 | 123 | 120 | 123 | 500 |
| [#6](bench_client.odin#L834-L846) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **8** | 8 ± 0.0 | 0.0% | 125M | 125M | 0 | 8 | 8 | 8 | 8 | 1K |
| [#7](bench_client.odin#L848-L862) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **262** | 264 ± 4.2 | 1.6% | 3.7M | 3.8M | 3 | 270 | 271 | 261 | 271 | 1K |
| [#17](bench_client.odin#L1097-L1117) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **544** | 546 ± 6.3 | 1.1% | 1.8M | 1.9M | 5 | 554 | 556 | 540 | 556 | 100 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 19 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#2](bench_client.odin#L769-L783) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **1.05** | 1.06 ± 0.02 | 2.0% | 917K | 962K | 0.02 | 1.09 | 1.09 | 1.04 | 1.09 | 500 |
| [#8](bench_client.odin#L864-L883) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.61** | 1.62 ± 0.02 | 1.3% | 606K | 625K | 0.03 | 1.65 | 1.65 | 1.60 | 1.65 | 200 |
| [#9](bench_client.odin#L885-L908) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **1.45** | 1.47 ± 0.04 | 2.7% | 654K | 697K | 0.04 | 1.52 | 1.53 | 1.44 | 1.53 | 200 |
| [#10](bench_client.odin#L910-L931) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **35.0** | 35.1 ± 0.27 | 0.8% | 28.2K | 28.7K | 0.41 | 35.4 | 35.4 | 34.8 | 35.4 | 50 |
| [#11](bench_client.odin#L933-L948) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **2.71** | 2.72 ± 0.09 | 3.2% | 349K | 378K | 0.07 | 2.84 | 2.86 | 2.65 | 2.87 | 200 |
| [#12](bench_client.odin#L950-L972) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **12.5** | 12.6 ± 0.12 | 1.0% | 78.4K | 80.4K | 0.07 | 12.7 | 12.8 | 12.4 | 12.8 | 100 |
| [#13](bench_client.odin#L974-L993) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **461.2** | 459.9 ± 4.06 | 0.9% | 2.1K | 2.2K | 4.17 | 464.4 | 465.0 | 454.8 | 465.2 | 1 |
| [#14](bench_client.odin#L995-L1017) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **3.59** | 3.61 ± 0.09 | 2.5% | 270K | 286K | 0.13 | 3.71 | 3.71 | 3.50 | 3.71 | 100 |
| [#15](bench_client.odin#L1019-L1044) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **5.30** | 5.34 ± 0.19 | 3.5% | 180K | 196K | 0.28 | 5.54 | 5.54 | 5.10 | 5.54 | 50 |
| [#16](bench_client.odin#L1046-L1073) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **3.85** | 3.88 ± 0.07 | 1.8% | 252K | 263K | 0.08 | 3.96 | 3.97 | 3.80 | 3.97 | 100 |
| [#18](bench_client.odin#L1119-L1132) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **69.2** | 69.1 ± 0.27 | 0.4% | 14.4K | 14.6K | 0.17 | 69.4 | 69.4 | 68.7 | 69.4 | 50 |
| [#19](bench_client.odin#L1151-L1164) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **188.7** | 187.8 ± 4.05 | 2.2% | 5.2K | 5.5K | 4.01 | 192.3 | 192.9 | 182.4 | 193.0 | 50 |
| [#20](bench_client.odin#L1166-L1186) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **21.7** | 21.3 ± 1.19 | 5.6% | 44.7K | 51.6K | 1.06 | 22.3 | 22.3 | 19.4 | 22.4 | 20 |
| [#21](bench_client.odin#L1188-L1203) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **2.97** | 2.97 ± 0.05 | 1.5% | 331K | 342K | 0.08 | 3.02 | 3.02 | 2.93 | 3.02 | 200 |
| [#22](bench_client.odin#L1205-L1226) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **26.5** | 26.8 ± 0.80 | 3.0% | 36.1K | 38.6K | 1.20 | 27.7 | 27.7 | 25.9 | 27.7 | 50 |
| [#23](bench_client.odin#L1228-L1247) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **465.0** | 470.4 ± 22.2 | 4.7% | 2.0K | 2.2K | 25.2 | 499.1 | 503.0 | 448.6 | 503.9 | 50 |
| [#24](bench_client.odin#L1249-L1268) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **52.8** | 53.5 ± 1.79 | 3.3% | 17.7K | 19.2K | 0.85 | 55.9 | 56.4 | 52.2 | 56.6 | 50 |
| [#25](bench_client.odin#L1270-L1306) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **1.52** | 1.54 ± 0.03 | 2.2% | 630K | 668K | 0.03 | 1.58 | 1.59 | 1.50 | 1.59 | 100 |
| [#26](bench_client.odin#L1308-L1336) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **166.0** | 165.5 ± 2.29 | 1.4% | 6.0K | 6.1K | 4.05 | 167.7 | 167.7 | 162.7 | 167.7 | 50 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `7cce79853656`)

#### 3.1 Sub-Microsecond Fast Path (Elixir `< 1 µs`, 5 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **1.62x** | 377 | **612** | `38.6` ★ | 383 ± 9.6 | 2.5% | 616 ± 9.4 | 1.5% |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **3.44x** | 109 | **375** | `73.7` ★ | 109 ± 0.0 | 0.0% | 379 ± 8.2 | 2.2% |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **3.30x** | 122 | **402** | `96.9` ★ | 122 ± 1.1 | 0.9% | 404 ± 6.4 | 1.6% |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **20.88x** | 8 | **167** | `83.8` ★ | 8 ± 0.0 | 0.0% | 168 ± 4.3 | 2.5% |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **2.82x** | 262 | **738** | `38.4` ★ | 264 ± 4.2 | 1.6% | 744 ± 27.6 | 3.7% |


#### 3.2 Multi-Microsecond Client Operations (Elixir `≥ 1 µs`, 21 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **3.54x** | 0.65 | **2.30** | `133.1` ★ | 0.64 ± 0.02 | 2.4% | 2.31 ± 0.02 | 1.0% |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **2.07x** | 1.05 | **2.16** | `111.4` ★ | 1.06 ± 0.02 | 2.0% | 2.16 ± 0.01 | 0.3% |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **2.44x** | 1.61 | **3.93** | `6.0` ★ | 1.62 ± 0.02 | 1.3% | 4.31 ± 1.00 | 23.2% |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **3.42x** | 1.45 | **4.95** | `7.0` ★ | 1.47 ± 0.04 | 2.7% | 5.55 ± 1.31 | 23.6% |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **2.35x** | 35.0 | **82.2** | `24.0` ★ | 35.1 ± 0.27 | 0.8% | 84.3 ± 4.58 | 5.4% |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **2.37x** | 2.71 | **6.42** | `5.0` ★ | 2.72 ± 0.09 | 3.2% | 7.11 ± 1.95 | 27.5% |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **1.09x** | 12.5 | **13.7** | `3.5` ★ | 12.6 ± 0.12 | 1.0% | 14.2 ± 1.04 | 7.3% |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **0.88x** | 461.2 | **404.2** | `3.6` ★ | 459.9 ± 4.06 | 0.9% | 415.3 ± 27.1 | 6.5% |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **3.61x** | 3.59 | **13.0** | `13.9` ★ | 3.61 ± 0.09 | 2.5% | 13.5 ± 1.58 | 11.8% |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **2.16x** | 5.30 | **11.4** | `54.6` ★ | 5.34 ± 0.19 | 3.5% | 11.5 ± 0.17 | 1.5% |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **2.40x** | 3.85 | **9.25** | `14.2` ★ | 3.88 ± 0.07 | 1.8% | 8.85 ± 0.78 | 8.8% |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **7.60x** | 0.54 | **4.14** | `37.3` ★ | 0.55 ± 0.01 | 1.1% | 4.04 ± 0.21 | 5.2% |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **3.00x** | 69.2 | **207.8** | `21.8` ★ | 69.1 ± 0.27 | 0.4% | 216.0 ± 15.1 | 7.0% |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **1.70x** | 188.7 | **320.2** | `72.7` ★ | 187.8 ± 4.05 | 2.2% | 320.1 ± 0.39 | 0.1% |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **1.45x** | 21.7 | **31.4** | `4.9` ★ | 21.3 ± 1.19 | 5.6% | 31.0 ± 4.33 | 13.9% |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **2.21x** | 2.97 | **6.56** | `42.5` ★ | 2.97 ± 0.05 | 1.5% | 6.50 ± 0.18 | 2.8% |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **1.74x** | 26.5 | **46.2** | `53.6` ★ | 26.8 ± 0.80 | 3.0% | 46.2 ± 0.14 | 0.3% |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **1.22x** | 465.0 | **568.2** | `9.9` ★ | 470.4 ± 22.2 | 4.7% | 569.3 ± 1.95 | 0.3% |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **1.16x** | 52.8 | **61.3** | `7.0` ★ | 53.5 ± 1.79 | 3.3% | 60.9 ± 1.56 | 2.6% |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **3.02x** | 1.52 | **4.60** | `54.4` ★ | 1.54 ± 0.03 | 2.2% | 4.64 ± 0.12 | 2.6% |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **1.53x** | 166.0 | **253.9** | `82.9` ★ | 165.5 ± 2.29 | 1.4% | 254.2 ± 0.70 | 0.3% |

### 4. Commit-vs-Commit Progression


#### 4.1 Elixir Client Wrapper (`6641d47147c9` → `7cce79853656`)

| # | Benchmark | `6641d47147c9` Med | `7cce79853656` Med | Δ% | Speedup | Welch `z` | `6641d47147c9` Mean ± σ | `7cce79853656` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 2.37 µs | **2.30 µs** | -2.9% | **1.03x** | `2.0` ~ | 2.41 µs ± 114 ns | 2.31 µs ± 23 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 2.25 µs | **2.16 µs** | -4.2% | **1.04x** | `8.9` ★ | 2.26 µs ± 23 ns | 2.16 µs ± 6 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 628 ns | **612 ns** | -2.5% | **1.03x** | `2.5` ★ | 635 ns ± 15 ns | 616 ns ± 9 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 365 ns | **375 ns** | +2.7% | **0.97x** | `2.8` ★ | 367 ns ± 6 ns | 379 ns ± 8 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 383 ns | **402 ns** | +5.0% | **0.95x** | `0.8` ~ | 429 ns ± 71 ns | 404 ns ± 6 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 173 ns | **167 ns** | -3.5% | **1.04x** | `2.5` ★ | 175 ns ± 5 ns | 168 ns ± 4 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 753 ns | **738 ns** | -2.0% | **1.02x** | `1.1` ~ | 761 ns ± 24 ns | 744 ns ± 28 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 3.38 µs | **3.93 µs** | +16.3% | **0.86x** | `1.7` ~ | 3.53 µs ± 218 ns | 4.31 µs ± 1.00 µs |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 4.59 µs | **4.95 µs** | +7.9% | **0.93x** | `1.7` ~ | 4.59 µs ± 20 ns | 5.55 µs ± 1.31 µs |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 81.8 µs | **82.2 µs** | +0.5% | **1.00x** | `1.6` ~ | 80.2 µs ± 3.14 µs | 84.3 µs ± 4.58 µs |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 5.69 µs | **6.42 µs** | +12.9% | **0.89x** | `1.6` ~ | 5.73 µs ± 195 ns | 7.11 µs ± 1.95 µs |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 31.0 µs | **13.7 µs** | -55.9% | **2.27x** | `34.4` ★ | 31.0 µs ± 329 ns | 14.2 µs ± 1.04 µs |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 984.9 µs | **404.2 µs** | -59.0% | **2.44x** | `33.9` ★ | 979.6 µs ± 25.6 µs | 415.3 µs ± 27.1 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 12.3 µs | **13.0 µs** | +5.5% | **0.95x** | `1.5` ~ | 12.4 µs ± 241 ns | 13.5 µs ± 1.58 µs |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 11.6 µs | **11.4 µs** | -1.8% | **1.02x** | `1.3` ~ | 12.2 µs ± 1.06 µs | 11.5 µs ± 171 ns |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 8.33 µs | **9.25 µs** | +11.1% | **0.90x** | `1.7` ~ | 8.21 µs ± 297 ns | 8.85 µs ± 782 ns |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 3.25 µs | **4.14 µs** | +27.3% | **0.79x** | `0.1` ~ | 4.16 µs ± 2.32 µs | 4.04 µs ± 209 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 227.3 µs | **207.8 µs** | -8.6% | **1.09x** | `1.4` ~ | 230.7 µs ± 17.7 µs | 216.0 µs ± 15.1 µs |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 338.4 µs | **320.2 µs** | -5.4% | **1.06x** | `2.3` ★ | 362.0 µs ± 41.4 µs | 320.1 µs ± 389 ns |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 38.7 µs | **31.4 µs** | -19.0% | **1.23x** | `1.4` ~ | 36.0 µs ± 6.53 µs | 31.0 µs ± 4.33 µs |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 7.97 µs | **6.56 µs** | -17.6% | **1.21x** | `4.8` ★ | 8.45 µs ± 889 ns | 6.50 µs ± 180 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 46.7 µs | **46.2 µs** | -1.1% | **1.01x** | `2.3` ★ | 46.7 µs ± 421 ns | 46.2 µs ± 142 ns |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 574.0 µs | **568.2 µs** | -1.0% | **1.01x** | `1.4` ~ | 573.1 µs ± 5.59 µs | 569.3 µs ± 1.95 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 59.9 µs | **61.3 µs** | +2.4% | **0.98x** | `0.9` ~ | 60.1 µs ± 1.03 µs | 60.9 µs ± 1.56 µs |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 4.87 µs | **4.60 µs** | -5.5% | **1.06x** | `1.9` ~ | 5.00 µs ± 402 ns | 4.64 µs ± 123 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 252.4 µs | **253.9 µs** | +0.6% | **0.99x** | `0.5` ~ | 253.5 µs ± 2.79 µs | 254.2 µs ± 702 ns |



#### 4.2 Raw Odin Baseline (`6641d47147c9` → `7cce79853656`)

| # | Benchmark | `6641d47147c9` Med | `7cce79853656` Med | Δ% | Speedup | Welch `z` | `6641d47147c9` Mean ± σ | `7cce79853656` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 613 ns | **650 ns** | +6.0% | **0.94x** | `0.8` ~ | 630 ns ± 34 ns | 643 ns ± 15 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 1.06 µs | **1.05 µs** | -1.5% | **1.02x** | `0.3` ~ | 1.06 µs ± 11 ns | 1.06 µs ± 21 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 375 ns | **377 ns** | +0.5% | **0.99x** | `0.7` ~ | 379 ns ± 8 ns | 383 ns ± 10 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 109 ns | **109 ns** | +0.0% | **1.00x** | `1.0` ~ | 109 ns ± 0 ns | 109 ns ± 0 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 124 ns | **122 ns** | -1.6% | **1.02x** | `3.1` ★ | 126 ns ± 3 ns | 122 ns ± 1 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 6 ns | **8 ns** | +33.3% | **0.75x** | `99.0` ★ | 6 ns ± 0 ns | 8 ns ± 0 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 264 ns | **262 ns** | -0.8% | **1.01x** | `0.5` ~ | 265 ns ± 4 ns | 264 ns ± 4 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 1.60 µs | **1.61 µs** | +0.2% | **1.00x** | `0.2` ~ | 1.62 µs ± 16 ns | 1.62 µs ± 21 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 1.48 µs | **1.45 µs** | -2.0% | **1.02x** | `1.2` ~ | 1.49 µs ± 25 ns | 1.47 µs ± 39 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 35.0 µs | **35.0 µs** | +0.0% | **1.00x** | `0.1` ~ | 35.1 µs ± 235 ns | 35.1 µs ± 266 ns |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 2.72 µs | **2.71 µs** | -0.5% | **1.00x** | `0.0` ~ | 2.72 µs ± 22 ns | 2.72 µs ± 88 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 13.0 µs | **12.5 µs** | -3.7% | **1.04x** | `7.2` ★ | 13.0 µs ± 62 ns | 12.6 µs ± 124 ns |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 502.5 µs | **461.2 µs** | -8.2% | **1.09x** | `6.4` ★ | 501.5 µs ± 14.0 µs | 459.9 µs ± 4.06 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 3.76 µs | **3.59 µs** | -4.4% | **1.05x** | `1.9` ~ | 3.90 µs ± 329 ns | 3.61 µs ± 89 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 5.46 µs | **5.30 µs** | -2.9% | **1.03x** | `1.2` ~ | 5.45 µs ± 102 ns | 5.34 µs ± 187 ns |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 3.90 µs | **3.85 µs** | -1.4% | **1.01x** | `1.0` ~ | 3.92 µs ± 68 ns | 3.88 µs ± 69 ns |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 551 ns | **544 ns** | -1.3% | **1.01x** | `1.5` ~ | 565 ns ± 27 ns | 546 ns ± 6 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 70.5 µs | **69.2 µs** | -1.8% | **1.02x** | `8.4` ★ | 70.4 µs ± 203 ns | 69.1 µs ± 273 ns |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 179.4 µs | **188.7 µs** | +5.2% | **0.95x** | `4.6` ★ | 179.4 µs ± 332 ns | 187.8 µs ± 4.05 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 18.6 µs | **21.7 µs** | +16.6% | **0.86x** | `5.0` ★ | 18.5 µs ± 326 ns | 21.3 µs ± 1.19 µs |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 2.70 µs | **2.97 µs** | +9.7% | **0.91x** | `7.2` ★ | 2.73 µs ± 60 ns | 2.97 µs ± 45 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 25.2 µs | **26.5 µs** | +5.4% | **0.95x** | `1.5` ~ | 25.8 µs ± 1.33 µs | 26.8 µs ± 796 ns |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 468.1 µs | **465.0 µs** | -0.7% | **1.01x** | `0.7` ~ | 479.8 µs ± 20.8 µs | 470.4 µs ± 22.2 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 50.9 µs | **52.8 µs** | +3.7% | **0.96x** | `3.1` ★ | 51.0 µs ± 73 ns | 53.5 µs ± 1.79 µs |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 1.54 µs | **1.52 µs** | -0.9% | **1.01x** | `0.5` ~ | 1.55 µs ± 17 ns | 1.54 µs ± 34 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 161.1 µs | **166.0 µs** | +3.0% | **0.97x** | `3.3` ★ | 161.6 µs ± 1.28 µs | 165.5 µs ± 2.29 µs |



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
