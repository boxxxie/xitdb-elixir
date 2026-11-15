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
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `b9e57a998e69-dirty`, 5 samples across 1 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 5 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#3](bench_elixir.exs#L219-L226) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **638** | 657 ± 44.0 | 6.7% | 1.4M | 1.6M | 7 | 716 | 731 | 633 | 735 | 500 |
| [#4](bench_elixir.exs#L227-L234) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **471** | 471 ± 116 | 24.7% | 1.5M | 2.7M | 109 | 622 | 650 | 371 | 657 | 500 |
| [#5](bench_elixir.exs#L235-L242) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **436** | 500 ± 113 | 22.7% | 1.6M | 2.6M | 172 | 633 | 639 | 389 | 640 | 500 |
| [#6](bench_elixir.exs#L243-L250) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **200** | 206 ± 41.8 | 20.3% | 3.6M | 5.8M | 30 | 262 | 273 | 173 | 276 | 1K |
| [#7](bench_elixir.exs#L251-L258) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **846** | 836 ± 25.2 | 3.0% | 1.15M | 1.24M | 39 | 863 | 865 | 809 | 866 | 1K |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 21 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_elixir.exs#L203-L210) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **2.43** | 2.59 ± 0.27 | 10.3% | 333K | 419K | 0.31 | 2.95 | 2.99 | 2.39 | 3.00 | 500 |
| [#2](bench_elixir.exs#L211-L218) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **2.49** | 2.50 ± 0.20 | 8.0% | 355K | 441K | 0.08 | 2.76 | 2.81 | 2.27 | 2.82 | 500 |
| [#8](bench_elixir.exs#L259-L266) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **3.32** | 3.38 ± 0.17 | 5.1% | 272K | 310K | 0.04 | 3.61 | 3.66 | 3.23 | 3.67 | 200 |
| [#9](bench_elixir.exs#L267-L274) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **4.58** | 4.62 ± 0.18 | 3.9% | 203K | 224K | 0.05 | 4.86 | 4.92 | 4.47 | 4.93 | 200 |
| [#10](bench_elixir.exs#L275-L282) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **82.1** | 81.9 ± 0.78 | 1.0% | 12.1K | 12.4K | 0.99 | 82.7 | 82.8 | 80.9 | 82.8 | 50 |
| [#11](bench_elixir.exs#L283-L290) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **5.85** | 5.94 ± 0.18 | 3.1% | 160K | 173K | 0.15 | 6.19 | 6.23 | 5.78 | 6.24 | 200 |
| [#12](bench_elixir.exs#L291-L317) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **13.3** | 13.5 ± 0.78 | 5.8% | 67.2K | 76.7K | 0.36 | 14.6 | 14.8 | 13.0 | 14.9 | 100 |
| [#13](bench_elixir.exs#L318-L333) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **436.8** | 435.1 ± 23.7 | 5.4% | 2.2K | 2.5K | 37.6 | 459.8 | 460.9 | 405.9 | 461.1 | 1 |
| [#14](bench_elixir.exs#L334-L348) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **11.9** | 12.0 ± 0.35 | 2.9% | 79.5K | 85.4K | 0.32 | 12.5 | 12.6 | 11.7 | 12.6 | 100 |
| [#15](bench_elixir.exs#L349-L369) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **9.01** | 9.59 ± 1.41 | 14.7% | 82.6K | 114K | 0.12 | 11.5 | 12.0 | 8.80 | 12.1 | 50 |
| [#16](bench_elixir.exs#L370-L387) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **7.53** | 8.37 ± 1.66 | 19.9% | 88.7K | 136K | 0.89 | 10.7 | 11.2 | 7.37 | 11.3 | 100 |
| [#17](bench_elixir.exs#L388-L396) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **2.40** | 2.45 ± 0.09 | 3.8% | 384K | 419K | 0.08 | 2.57 | 2.60 | 2.38 | 2.60 | 100 |
| [#18](bench_elixir.exs#L397-L404) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **47.1** | 48.8 ± 3.96 | 8.1% | 18.0K | 22.1K | 2.31 | 54.2 | 55.2 | 45.2 | 55.4 | 50 |
| [#19](bench_elixir.exs#L405-L412) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **344.4** | 348.5 ± 12.7 | 3.6% | 2.8K | 3.0K | 23.6 | 362.4 | 362.6 | 336.4 | 362.7 | 50 |
| [#20](bench_elixir.exs#L413-L424) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **28.3** | 29.4 ± 4.48 | 15.3% | 27.0K | 39.4K | 1.42 | 35.4 | 36.7 | 25.4 | 37.0 | 20 |
| [#21](bench_elixir.exs#L425-L432) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **6.47** | 6.41 ± 0.10 | 1.6% | 154K | 160K | 0.13 | 6.49 | 6.49 | 6.26 | 6.49 | 200 |
| [#22](bench_elixir.exs#L433-L440) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **47.8** | 48.7 ± 1.72 | 3.5% | 19.5K | 21.1K | 2.07 | 51.0 | 51.3 | 47.4 | 51.3 | 50 |
| [#23](bench_elixir.exs#L441-L448) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **593.9** | 600.0 ± 25.1 | 4.2% | 1.6K | 1.7K | 34.0 | 632.0 | 635.7 | 576.9 | 636.7 | 50 |
| [#24](bench_elixir.exs#L449-L465) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **58.2** | 58.3 ± 0.36 | 0.6% | 17.0K | 17.3K | 0.47 | 58.7 | 58.7 | 57.8 | 58.7 | 50 |
| [#25](bench_elixir.exs#L466-L480) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **7.65** | 7.10 ± 1.19 | 16.7% | 128K | 200K | 0.30 | 7.80 | 7.83 | 5.00 | 7.84 | 100 |
| [#26](bench_elixir.exs#L481-L497) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **254.0** | 253.7 ± 3.24 | 1.3% | 3.9K | 4.0K | 3.45 | 257.0 | 257.2 | 248.9 | 257.2 | 50 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `b9e57a998e69-dirty`, 5 samples across 1 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 7 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_client.odin#L786-L805) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **642** | 668 ± 50.6 | 7.6% | 1.3M | 1.6M | 33 | 738 | 752 | 634 | 755 | 500 |
| [#3](bench_client.odin#L823-L838) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **394** | 397 ± 8.0 | 2.0% | 2.4M | 2.6M | 0 | 408 | 410 | 391 | 411 | 500 |
| [#4](bench_client.odin#L840-L854) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **114** | 117 ± 8.2 | 7.0% | 7.9M | 9.2M | 14 | 126 | 127 | 109 | 127 | 500 |
| [#5](bench_client.odin#L856-L870) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **121** | 123 ± 5.7 | 4.6% | 7.5M | 8.4M | 2 | 131 | 133 | 119 | 133 | 500 |
| [#6](bench_client.odin#L872-L884) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **7** | 7 ± 0.0 | 0.0% | 143M | 143M | 0 | 7 | 7 | 7 | 7 | 1K |
| [#7](bench_client.odin#L886-L900) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **282** | 286 ± 16.9 | 5.9% | 3.2M | 3.7M | 26 | 307 | 309 | 270 | 309 | 1K |
| [#17](bench_client.odin#L1125-L1145) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **551** | 563 ± 35.7 | 6.3% | 1.6M | 1.9M | 9 | 611 | 623 | 540 | 626 | 100 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 19 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#2](bench_client.odin#L807-L821) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **1.02** | 1.02 ± 0.02 | 2.2% | 953K | 1.0M | 0.04 | 1.05 | 1.05 | 1.00 | 1.05 | 500 |
| [#8](bench_client.odin#L902-L921) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.64** | 1.67 ± 0.05 | 2.7% | 574K | 610K | 0.06 | 1.73 | 1.74 | 1.64 | 1.74 | 200 |
| [#9](bench_client.odin#L923-L946) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **1.46** | 1.50 ± 0.06 | 4.0% | 627K | 688K | 0.06 | 1.58 | 1.59 | 1.45 | 1.60 | 200 |
| [#10](bench_client.odin#L948-L969) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **35.4** | 35.4 ± 0.41 | 1.2% | 27.7K | 28.6K | 0.18 | 36.0 | 36.0 | 34.9 | 36.1 | 50 |
| [#11](bench_client.odin#L971-L986) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **2.69** | 2.73 ± 0.11 | 4.2% | 346K | 386K | 0.09 | 2.87 | 2.89 | 2.59 | 2.89 | 200 |
| [#12](bench_client.odin#L988-L1005) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **6.54** | 6.52 ± 0.33 | 5.1% | 146K | 164K | 0.51 | 6.86 | 6.87 | 6.08 | 6.87 | 100 |
| [#13](bench_client.odin#L1007-L1021) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **181.8** | 185.7 ± 11.6 | 6.2% | 5.0K | 5.8K | 12.4 | 199.6 | 200.9 | 171.5 | 201.2 | 1 |
| [#14](bench_client.odin#L1023-L1045) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **3.78** | 3.74 ± 0.15 | 3.9% | 254K | 279K | 0.18 | 3.91 | 3.94 | 3.59 | 3.94 | 100 |
| [#15](bench_client.odin#L1047-L1072) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **5.34** | 5.33 ± 0.23 | 4.2% | 178K | 196K | 0.35 | 5.60 | 5.62 | 5.11 | 5.63 | 50 |
| [#16](bench_client.odin#L1074-L1101) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **4.30** | 4.73 ± 1.07 | 22.5% | 154K | 253K | 0.96 | 6.19 | 6.44 | 3.96 | 6.50 | 100 |
| [#18](bench_client.odin#L1147-L1160) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **68.6** | 70.1 ± 2.73 | 3.9% | 13.5K | 14.8K | 3.27 | 73.7 | 74.1 | 67.8 | 74.2 | 50 |
| [#19](bench_client.odin#L1179-L1192) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **182.4** | 182.3 ± 0.17 | 0.1% | 5.48K | 5.49K | 0.29 | 182.5 | 182.5 | 182.1 | 182.5 | 50 |
| [#20](bench_client.odin#L1194-L1214) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **19.2** | 19.5 ± 1.14 | 5.9% | 46.5K | 53.8K | 0.38 | 21.1 | 21.4 | 18.6 | 21.5 | 20 |
| [#21](bench_client.odin#L1216-L1231) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **2.69** | 2.68 ± 0.02 | 0.9% | 369K | 377K | 0.04 | 2.70 | 2.71 | 2.65 | 2.71 | 200 |
| [#22](bench_client.odin#L1233-L1254) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **25.2** | 28.4 ± 5.15 | 18.1% | 27.3K | 40.1K | 5.27 | 35.4 | 36.4 | 24.9 | 36.7 | 50 |
| [#23](bench_client.odin#L1256-L1275) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **500.9** | 499.0 ± 23.3 | 4.7% | 1.9K | 2.1K | 32.9 | 526.3 | 529.3 | 474.1 | 530.0 | 50 |
| [#24](bench_client.odin#L1277-L1296) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **52.5** | 55.9 ± 6.49 | 11.6% | 14.9K | 19.5K | 4.00 | 64.9 | 66.6 | 51.3 | 67.0 | 50 |
| [#25](bench_client.odin#L1298-L1334) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **1.57** | 1.65 ± 0.25 | 15.3% | 478K | 669K | 0.09 | 1.99 | 2.07 | 1.50 | 2.09 | 100 |
| [#26](bench_client.odin#L1336-L1364) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **179.2** | 176.2 ± 10.8 | 6.2% | 5.3K | 6.3K | 8.18 | 186.3 | 187.2 | 159.0 | 187.5 | 50 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `b9e57a998e69-dirty`)

#### 3.1 Sub-Microsecond Fast Path (Elixir `< 1 µs`, 5 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **1.62x** | 394 | **638** | `13.0` ★ | 397 ± 8.0 | 2.0% | 657 ± 44.0 | 6.7% |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **4.13x** | 114 | **471** | `6.8` ★ | 117 ± 8.2 | 7.0% | 471 ± 116 | 24.7% |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **3.60x** | 121 | **436** | `7.4` ★ | 123 ± 5.7 | 4.6% | 500 ± 113 | 22.7% |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **28.57x** | 7 | **200** | `10.6` ★ | 7 ± 0.0 | 0.0% | 206 ± 41.8 | 20.3% |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **3.00x** | 282 | **846** | `40.5` ★ | 286 ± 16.9 | 5.9% | 836 ± 25.2 | 3.0% |


#### 3.2 Multi-Microsecond Client Operations (Elixir `≥ 1 µs`, 21 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **3.79x** | 0.64 | **2.43** | `15.8` ★ | 0.67 ± 0.05 | 7.6% | 2.59 ± 0.27 | 10.3% |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **2.44x** | 1.02 | **2.49** | `16.3` ★ | 1.02 ± 0.02 | 2.2% | 2.50 ± 0.20 | 8.0% |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **2.02x** | 1.64 | **3.32** | `21.4` ★ | 1.67 ± 0.05 | 2.7% | 3.38 ± 0.17 | 5.1% |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **3.13x** | 1.46 | **4.58** | `36.5` ★ | 1.50 ± 0.06 | 4.0% | 4.62 ± 0.18 | 3.9% |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **2.32x** | 35.4 | **82.1** | `117.7` ★ | 35.4 ± 0.41 | 1.2% | 81.9 ± 0.78 | 1.0% |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **2.18x** | 2.69 | **5.85** | `33.3` ★ | 2.73 ± 0.11 | 4.2% | 5.94 ± 0.18 | 3.1% |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **2.03x** | 6.54 | **13.3** | `18.5` ★ | 6.52 ± 0.33 | 5.1% | 13.5 ± 0.78 | 5.8% |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **2.40x** | 181.8 | **436.8** | `21.2` ★ | 185.7 ± 11.6 | 6.2% | 435.1 ± 23.7 | 5.4% |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **3.15x** | 3.78 | **11.9** | `48.4` ★ | 3.74 ± 0.15 | 3.9% | 12.0 ± 0.35 | 2.9% |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **1.69x** | 5.34 | **9.01** | `6.7` ★ | 5.33 ± 0.23 | 4.2% | 9.59 ± 1.41 | 14.7% |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **1.75x** | 4.30 | **7.53** | `4.1` ★ | 4.73 ± 1.07 | 22.5% | 8.37 ± 1.66 | 19.9% |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **4.35x** | 0.55 | **2.40** | `42.2` ★ | 0.56 ± 0.04 | 6.3% | 2.45 ± 0.09 | 3.8% |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **0.69x** | 68.6 | **47.1** | `9.9` ★ | 70.1 ± 2.73 | 3.9% | 48.8 ± 3.96 | 8.1% |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **1.89x** | 182.4 | **344.4** | `29.3` ★ | 182.3 ± 0.17 | 0.1% | 348.5 ± 12.7 | 3.6% |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **1.47x** | 19.2 | **28.3** | `4.7` ★ | 19.5 ± 1.14 | 5.9% | 29.4 ± 4.48 | 15.3% |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **2.41x** | 2.69 | **6.47** | `79.6` ★ | 2.68 ± 0.02 | 0.9% | 6.41 ± 0.10 | 1.6% |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **1.90x** | 25.2 | **47.8** | `8.3` ★ | 28.4 ± 5.15 | 18.1% | 48.7 ± 1.72 | 3.5% |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **1.19x** | 500.9 | **593.9** | `6.6` ★ | 499.0 ± 23.3 | 4.7% | 600.0 ± 25.1 | 4.2% |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **1.11x** | 52.5 | **58.2** | `0.8` ~ | 55.9 ± 6.49 | 11.6% | 58.3 ± 0.36 | 0.6% |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **4.89x** | 1.57 | **7.65** | `10.0` ★ | 1.65 ± 0.25 | 15.3% | 7.10 ± 1.19 | 16.7% |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **1.42x** | 179.2 | **254.0** | `15.3` ★ | 176.2 ± 10.8 | 6.2% | 253.7 ± 3.24 | 1.3% |

### 4. Commit-vs-Commit Progression


#### 4.1 Elixir Client Wrapper (`7cce79853656` → `a6ad2e15d006`)

| # | Benchmark | `7cce79853656` Med | `a6ad2e15d006` Med | Δ% | Speedup | Welch `z` | `7cce79853656` Mean ± σ | `a6ad2e15d006` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 2.30 µs | **2.46 µs** | +7.1% | **0.93x** | `13.2` ★ | 2.31 µs ± 23 ns | 2.47 µs ± 12 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 2.16 µs | **2.13 µs** | -1.4% | **1.01x** | `1.4` ~ | 2.16 µs ± 6 ns | 2.14 µs ± 38 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 612 ns | **626 ns** | +2.3% | **0.98x** | `2.4` ★ | 616 ns ± 9 ns | 629 ns ± 8 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 375 ns | **376 ns** | +0.3% | **1.00x** | `1.0` ~ | 379 ns ± 8 ns | 375 ns ± 6 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 402 ns | **418 ns** | +4.0% | **0.96x** | `1.8` ~ | 404 ns ± 6 ns | 433 ns ± 36 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 167 ns | **165 ns** | -1.2% | **1.01x** | `0.8` ~ | 168 ns ± 4 ns | 175 ns ± 19 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 738 ns | **808 ns** | +9.5% | **0.91x** | `5.1` ★ | 744 ns ± 28 ns | 813 ns ± 13 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 3.93 µs | **3.52 µs** | -10.6% | **1.12x** | `1.7` ~ | 4.31 µs ± 1.00 µs | 3.55 µs ± 68 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 4.95 µs | **4.76 µs** | -3.9% | **1.04x** | `1.4` ~ | 5.55 µs ± 1.31 µs | 4.76 µs ± 45 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 82.2 µs | **78.8 µs** | -4.2% | **1.04x** | `2.7` ★ | 84.3 µs ± 4.58 µs | 78.9 µs ± 442 ns |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 6.42 µs | **6.09 µs** | -5.1% | **1.05x** | `1.1` ~ | 7.11 µs ± 1.95 µs | 6.16 µs ± 202 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 13.7 µs | **14.1 µs** | +3.4% | **0.97x** | `0.3` ~ | 14.2 µs ± 1.04 µs | 14.4 µs ± 575 ns |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 404.2 µs | **414.5 µs** | +2.6% | **0.98x** | `0.3` ~ | 415.3 µs ± 27.1 µs | 411.5 µs ± 11.6 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 13.0 µs | **12.6 µs** | -2.8% | **1.03x** | `0.6` ~ | 13.5 µs ± 1.58 µs | 13.0 µs ± 928 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 11.4 µs | **11.4 µs** | -0.3% | **1.00x** | `1.2` ~ | 11.5 µs ± 171 ns | 11.4 µs ± 134 ns |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 9.25 µs | **7.77 µs** | -16.1% | **1.19x** | `1.4` ~ | 8.85 µs ± 782 ns | 8.12 µs ± 840 ns |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 4.14 µs | **2.40 µs** | -41.8% | **1.72x** | `17.2` ★ | 4.04 µs ± 209 ns | 2.40 µs ± 36 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 207.8 µs | **208.3 µs** | +0.2% | **1.00x** | `1.1` ~ | 216.0 µs ± 15.1 µs | 208.7 µs ± 3.34 µs |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 320.2 µs | **328.8 µs** | +2.7% | **0.97x** | `31.3` ★ | 320.1 µs ± 389 ns | 328.8 µs ± 483 ns |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 31.4 µs | **25.2 µs** | -19.7% | **1.25x** | `3.0` ★ | 31.0 µs ± 4.33 µs | 25.1 µs ± 496 ns |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 6.56 µs | **6.33 µs** | -3.6% | **1.04x** | `1.9` ~ | 6.50 µs ± 180 ns | 6.34 µs ± 49 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 46.2 µs | **46.4 µs** | +0.5% | **1.00x** | `1.3` ~ | 46.2 µs ± 142 ns | 46.6 µs ± 589 ns |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 568.2 µs | **557.1 µs** | -2.0% | **1.02x** | `13.8` ★ | 569.3 µs ± 1.95 µs | 556.9 µs ± 525 ns |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 61.3 µs | **59.5 µs** | -2.9% | **1.03x** | `2.0` ★ | 60.9 µs ± 1.56 µs | 59.5 µs ± 423 ns |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 4.60 µs | **4.66 µs** | +1.3% | **0.99x** | `0.1` ~ | 4.64 µs ± 123 ns | 4.65 µs ± 77 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 253.9 µs | **260.6 µs** | +2.6% | **0.97x** | `3.9` ★ | 254.2 µs ± 702 ns | 259.3 µs ± 2.80 µs |



#### 4.2 Raw Odin Baseline (`7cce79853656` → `a6ad2e15d006`)

| # | Benchmark | `7cce79853656` Med | `a6ad2e15d006` Med | Δ% | Speedup | Welch `z` | `7cce79853656` Mean ± σ | `a6ad2e15d006` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 650 ns | **606 ns** | -6.8% | **1.07x** | `0.2` ~ | 643 ns ± 15 ns | 638 ns ± 62 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 1.05 µs | **1.01 µs** | -2.9% | **1.03x** | `4.0` ★ | 1.06 µs ± 21 ns | 1.01 µs ± 11 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 377 ns | **380 ns** | +0.8% | **0.99x** | `0.5` ~ | 383 ns ± 10 ns | 388 ns ± 19 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 109 ns | **106 ns** | -2.8% | **1.03x** | `0.5` ~ | 109 ns ± 0 ns | 112 ns ± 15 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 122 ns | **118 ns** | -3.3% | **1.03x** | `4.4` ★ | 122 ns ± 1 ns | 118 ns ± 1 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 8 ns | **6 ns** | -25.0% | **1.33x** | `9.0` ★ | 8 ns ± 0 ns | 6 ns ± 0 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 262 ns | **262 ns** | +0.0% | **1.00x** | `0.9` ~ | 264 ns ± 4 ns | 268 ns ± 8 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 1.61 µs | **1.61 µs** | +0.2% | **1.00x** | `0.8` ~ | 1.62 µs ± 21 ns | 1.63 µs ± 29 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 1.45 µs | **1.46 µs** | +1.0% | **0.99x** | `0.3` ~ | 1.47 µs ± 39 ns | 1.47 µs ± 30 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 35.0 µs | **35.3 µs** | +0.7% | **0.99x** | `0.8` ~ | 35.1 µs ± 266 ns | 35.2 µs ± 160 ns |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 2.71 µs | **2.64 µs** | -2.3% | **1.02x** | `1.1` ~ | 2.72 µs ± 88 ns | 2.67 µs ± 41 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 12.5 µs | **6.29 µs** | -49.7% | **1.99x** | `65.5` ★ | 12.6 µs ± 124 ns | 6.31 µs ± 173 ns |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 461.2 µs | **182.0 µs** | -60.6% | **2.53x** | `105.9` ★ | 459.9 µs ± 4.06 µs | 183.3 µs ± 4.21 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 3.59 µs | **3.71 µs** | +3.3% | **0.97x** | `1.9` ~ | 3.61 µs ± 89 ns | 3.74 µs ± 119 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 5.30 µs | **5.27 µs** | -0.5% | **1.01x** | `0.4` ~ | 5.34 µs ± 187 ns | 5.31 µs ± 59 ns |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 3.85 µs | **3.74 µs** | -2.8% | **1.03x** | `1.7` ~ | 3.88 µs ± 69 ns | 3.76 µs ± 136 ns |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 544 ns | **543 ns** | -0.2% | **1.00x** | `0.3` ~ | 546 ns ± 6 ns | 545 ns ± 3 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 69.2 µs | **69.9 µs** | +1.0% | **0.99x** | `5.7` ★ | 69.1 µs ± 273 ns | 69.9 µs ± 99 ns |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 188.7 µs | **177.4 µs** | -6.0% | **1.06x** | `5.6` ★ | 187.8 µs ± 4.05 µs | 177.5 µs ± 631 ns |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 21.7 µs | **18.9 µs** | -12.7% | **1.15x** | `4.6` ★ | 21.3 µs ± 1.19 µs | 18.7 µs ± 324 ns |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 2.97 µs | **2.67 µs** | -9.9% | **1.11x** | `13.8` ★ | 2.97 µs ± 45 ns | 2.68 µs ± 16 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 26.5 µs | **25.0 µs** | -5.7% | **1.06x** | `2.5` ★ | 26.8 µs ± 796 ns | 25.4 µs ± 966 ns |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 465.0 µs | **464.9 µs** | -0.0% | **1.00x** | `0.1` ~ | 470.4 µs ± 22.2 µs | 469.0 µs ± 18.9 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 52.8 µs | **51.7 µs** | -2.2% | **1.02x** | `2.0` ★ | 53.5 µs ± 1.79 µs | 51.8 µs ± 461 ns |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 1.52 µs | **1.52 µs** | -0.4% | **1.00x** | `0.8` ~ | 1.54 µs ± 34 ns | 1.62 µs ± 231 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 166.0 µs | **154.3 µs** | -7.0% | **1.08x** | `0.7` ~ | 165.5 µs ± 2.29 µs | 161.4 µs ± 12.9 µs |



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
