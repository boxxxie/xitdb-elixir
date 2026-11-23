# Xitdb Elixir Client Benchmarks

This directory contains the 1v1 statistical benchmark suite for `Xitdb`, measuring **client-boundary overhead** and throughput (`ops/sec`), median/mean latency (`ns/op`), variance (`±σ`, `CV%`, `IQR`, `p95`, `p99`, `min..max`), and resulting database byte footprint between the **Elixir NIF Wrapper (`lang: "elixir"`)** and **Raw Odin (`lang: "odin"`)**.

Unlike the upstream `odin-xitdb` benchmark suite (which benchmarks low-level HAMT/B+Tree node splits, hashers, and raw byte streams), this suite focuses exclusively on **32 orthogonal, zero-redundancy client-facing workloads** across five groups:
1. **`access` (`#1–#5`, `#28`, `#32`)**: 3-hop lazy `Access` HAMT navigation (`root["users"][id]["name"]`), single-call selector traversal (`Xitdb.select!/2`), pre-tokenized `path_steps/1` lookup (`#28`), batched `nif_slot_get_keys/4` multi-key fetch (`#32`), `Sorted_Map` B+Tree binary-search key lookup (`sorted[key]`), `Array_List` 16-way Radix Trie indexing (`items[idx]`), and `Linked_Array_List` count-augmented B-Tree indexing (`linked[idx]`).
2. **`enumerable & stream` (`#6–#11`)**: `O(1)` `Enum.count/1` on `Counted_Hash_Map`, `O(1)` `Enum.member?/2` on `Counted_Hash_Set`, `O(log N)` `Enum.slice/2` on `Array_List`, bounded `Stream.take/2` early-halt on `Sorted_Map`, full `Enum.to_list/1` on `Array_List`, and `Xitdb.materialize/1` subtree conversion.
3. **`transactions` (`#12–#16`, `#29–#30`)**: Single-entity `Xitdb.transact/2` map commits, bulk 100-entity `:merge_map` (`#13`) and coarse NIF `:bulk_put_maps` (`#29`) / `:bulk_put_nested_maps` (`#30`) batch commits, incremental `put_in/3` cursor transactions, `O(log N)` mid-list `Xitdb.insert_at/4` + `Xitdb.delete_at/3` on `Linked_Array_List`, and `O(1)` zero-copy subtree `Xitdb.fork/3`.
4. **`time-travel & lifecycle` (`#17–#20`)**: `Xitdb.as_of/2` historical snapshot resolution across 100 moments, `Xitdb.history_of/2` attribute lineage scan across 100 moments, `O(delta)` `Xitdb.diff_moments/3` structural diffs, and `Xitdb.compact/1` 100-moment database deduplication.
5. **`queries, storage & search` (`#21–#27`, `#31`)**: Datomic-style `Xitdb.pull/2` nested projections, Datalog B+Tree secondary index prefix seek + join (`Xitdb.query/2`), Datalog grouped aggregations (`count`, `sum`), on-disk `Buffered_File` transactional commits + `Xitdb.sync/1`, `Sorted_Map` B+Tree prefix seek (`limit=16`), BM25 corpus search (`N=200`, 2-term prefix, `limit=10`), `Indexer` B+Tree range scan + set decode (`#27`, `limit=16`), and coarse NIF `:bulk_index_puts` (`#31`, `:hash_map_merge`, 100 terms).

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

See [Benchmark Code Slices (`slices/README.md`)](slices/README.md) for side-by-side Elixir harness, Raw Odin baseline, Elixir/NIF wrapper, and reachable `xitdb` core engine call-graph views of `#1–#32`.

For Elixir-only Ash & Compression feature benchmarks, also see [`bench_ash_bulk.exs`](bench_ash_bulk.exs) (`MIX_ENV=test mix run benchmarks/bench_ash_bulk.exs`) and [`bench_compression.exs`](bench_compression.exs) (`mix run benchmarks/bench_compression.exs`).

To regenerate the slices and reference tables below from `benchmarks/odin.jsonl`, `benchmarks/elixir.jsonl`, and `benchmarks/history.jsonl`:

```bash
./benchmarks/update_readme.sh
```

---

## NIF Boundary Cost Model

Across the 32 orthogonal workloads, the BEAM ↔ Odin NIF boundary separates cleanly into four latency regimes:

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
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `a6ed18d57b4a`, 5 samples across 1 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 8 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_elixir.exs#L235-L242) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **854** | 861 ± 13.3 | 1.5% | 1.1M | 1.2M | 15 | 878 | 880 | 849 | 881 | 500 |
| [#2](bench_elixir.exs#L243-L250) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **701** | 700 ± 7.9 | 1.1% | 1.41M | 1.45M | 13 | 708 | 708 | 690 | 708 | 500 |
| [#3](bench_elixir.exs#L251-L258) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **570** | 571 ± 4.1 | 0.7% | 1.7M | 1.8M | 4 | 577 | 578 | 568 | 578 | 500 |
| [#4](bench_elixir.exs#L259-L266) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **215** | 216 ± 2.5 | 1.2% | 4.5M | 4.7M | 1 | 219 | 220 | 214 | 220 | 500 |
| [#5](bench_elixir.exs#L267-L274) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **410** | 410 ± 2.5 | 0.6% | 2.4M | 2.5M | 3 | 412 | 412 | 406 | 412 | 500 |
| [#6](bench_elixir.exs#L275-L282) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **106** | 109 ± 6.4 | 5.9% | 8.5M | 9.8M | 7 | 117 | 118 | 102 | 118 | 1K |
| [#7](bench_elixir.exs#L283-L290) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **278** | 280 ± 4.1 | 1.5% | 3.5M | 3.6M | 3 | 286 | 287 | 277 | 287 | 1K |
| [#28](bench_elixir.exs#L547-L555) | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **698** | 698 ± 6.8 | 1.0% | 1.4M | 1.5M | 3 | 706 | 708 | 689 | 708 | 500 |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 24 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#8](bench_elixir.exs#L291-L298) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.77** | 1.78 ± 0.02 | 0.9% | 555K | 568K | 0.01 | 1.80 | 1.80 | 1.76 | 1.80 | 200 |
| [#9](bench_elixir.exs#L299-L306) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **2.72** | 2.71 ± 0.02 | 0.7% | 366K | 372K | 0.03 | 2.73 | 2.73 | 2.69 | 2.73 | 200 |
| [#10](bench_elixir.exs#L307-L314) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **35.1** | 36.0 ± 1.87 | 5.2% | 25.5K | 28.7K | 0.82 | 38.6 | 39.1 | 34.9 | 39.3 | 50 |
| [#11](bench_elixir.exs#L315-L322) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **2.73** | 2.77 ± 0.11 | 4.0% | 345K | 377K | 0.18 | 2.89 | 2.90 | 2.65 | 2.90 | 200 |
| [#12](bench_elixir.exs#L323-L349) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **6.58** | 6.59 ± 0.10 | 1.5% | 148K | 154K | 0.08 | 6.73 | 6.75 | 6.50 | 6.76 | 100 |
| [#13](bench_elixir.exs#L350-L365) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **159.0** | 158.1 ± 2.82 | 1.8% | 6.2K | 6.5K | 2.04 | 161.1 | 161.6 | 154.1 | 161.7 | 1 |
| [#14](bench_elixir.exs#L366-L380) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **7.86** | 7.95 ± 0.21 | 2.7% | 122K | 129K | 0.36 | 8.19 | 8.19 | 7.74 | 8.19 | 100 |
| [#15](bench_elixir.exs#L381-L401) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **10.8** | 10.1 ± 1.55 | 15.4% | 86.4K | 121K | 2.62 | 11.5 | 11.6 | 8.24 | 11.6 | 50 |
| [#16](bench_elixir.exs#L402-L419) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **9.79** | 11.5 ± 4.63 | 40.2% | 54.5K | 131K | 6.34 | 17.5 | 18.2 | 7.61 | 18.3 | 100 |
| [#17](bench_elixir.exs#L420-L428) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **1.56** | 1.51 ± 0.09 | 5.9% | 627K | 725K | 0.10 | 1.59 | 1.59 | 1.38 | 1.59 | 100 |
| [#18](bench_elixir.exs#L429-L436) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **41.2** | 40.9 ± 1.54 | 3.8% | 23.3K | 25.5K | 2.40 | 42.7 | 42.8 | 39.2 | 42.8 | 50 |
| [#19](bench_elixir.exs#L437-L444) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **118.7** | 118.7 ± 3.97 | 3.3% | 8.0K | 8.8K | 2.81 | 123.7 | 124.5 | 114.1 | 124.8 | 50 |
| [#20](bench_elixir.exs#L445-L456) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **31.2** | 32.4 ± 2.49 | 7.7% | 27.6K | 32.9K | 2.94 | 35.7 | 36.1 | 30.4 | 36.2 | 20 |
| [#21](bench_elixir.exs#L457-L464) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **8.37** | 8.88 ± 1.12 | 12.6% | 94.8K | 129K | 1.20 | 10.3 | 10.5 | 7.77 | 10.5 | 200 |
| [#22](bench_elixir.exs#L465-L472) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **23.1** | 24.0 ± 1.57 | 6.6% | 37.4K | 43.4K | 0.75 | 26.1 | 26.6 | 23.0 | 26.7 | 50 |
| [#23](bench_elixir.exs#L473-L480) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **203.1** | 203.9 ± 1.64 | 0.8% | 4.8K | 4.9K | 1.30 | 206.0 | 206.4 | 202.2 | 206.4 | 50 |
| [#24](bench_elixir.exs#L481-L497) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **44.5** | 44.3 ± 1.32 | 3.0% | 21.9K | 23.5K | 2.03 | 45.6 | 45.6 | 42.5 | 45.6 | 50 |
| [#25](bench_elixir.exs#L498-L512) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **2.71** | 2.73 ± 0.05 | 1.7% | 358K | 373K | 0.06 | 2.79 | 2.79 | 2.68 | 2.79 | 100 |
| [#26](bench_elixir.exs#L513-L529) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **84.3** | 101.4 ± 27.4 | 27.1% | 7.5K | 12.6K | 50.1 | 132.0 | 132.4 | 79.6 | 132.5 | 50 |
| [#27](bench_elixir.exs#L530-L546) | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **5.70** | 5.90 ± 0.47 | 7.9% | 153K | 183K | 0.69 | 6.48 | 6.52 | 5.46 | 6.53 | 50 |
| [#29](bench_elixir.exs#L556-L576) | [`Tx: Bulk NIF :bulk_put_maps (100 entities in 1 commit)`](slices/29_tx_bulk_nif_bulk_put_maps_100_entities_in_1_commit.md) | **137.9** | 151.0 ± 22.0 | 14.5% | 5.5K | 7.5K | 31.9 | 178.8 | 181.1 | 133.5 | 181.7 | 10 |
| [#30](bench_elixir.exs#L577-L601) | [`Tx: Bulk NIF :bulk_put_nested_maps (100 nested entities)`](slices/30_tx_bulk_nif_bulk_put_nested_maps_100_nested_entities.md) | **167.9** | 168.1 ± 4.78 | 2.8% | 5.7K | 6.1K | 7.50 | 173.6 | 174.0 | 163.0 | 174.1 | 10 |
| [#31](bench_elixir.exs#L602-L626) | [`Indexer: Bulk NIF :bulk_index_puts (:hash_map_merge, 100 terms)`](slices/31_indexer_bulk_nif_bulk_index_puts_hash_map_merge_100_terms.md) | **163.5** | 166.5 ± 7.06 | 4.2% | 5.6K | 6.2K | 3.50 | 176.2 | 178.1 | 161.0 | 178.6 | 10 |
| [#32](bench_elixir.exs#L627-L640) | [`Access: Batched nif_slot_get_keys (100 keys in 1 NIF call)`](slices/32_access_batched_nif_slot_get_keys_100_keys_in_1_nif_call.md) | **18.8** | 18.6 ± 0.51 | 2.7% | 51.9K | 55.8K | 0.50 | 19.2 | 19.3 | 17.9 | 19.3 | 100 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `a6ed18d57b4a`, 5 samples across 1 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 9 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#1](bench_client.odin#L948-L967) | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **385** | 386 ± 5.6 | 1.5% | 2.5M | 2.6M | 2 | 394 | 396 | 382 | 396 | 500 |
| [#2](bench_client.odin#L969-L983) | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **648** | 648 ± 4.3 | 0.7% | 1.5M | 1.6M | 2 | 653 | 654 | 642 | 654 | 500 |
| [#3](bench_client.odin#L985-L1000) | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **441** | 441 ± 2.9 | 0.6% | 2.2M | 2.3M | 1 | 444 | 445 | 437 | 445 | 500 |
| [#4](bench_client.odin#L1002-L1016) | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **73** | 73 ± 0.0 | 0.0% | 13.7M | 13.7M | 0 | 73 | 73 | 73 | 73 | 500 |
| [#5](bench_client.odin#L1018-L1032) | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **239** | 240 ± 3.3 | 1.4% | 4.1M | 4.2M | 0 | 245 | 246 | 238 | 246 | 500 |
| [#6](bench_client.odin#L1034-L1046) | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **5** | 5 ± 0.0 | 0.0% | 200M | 200M | 0 | 5 | 5 | 5 | 5 | 1K |
| [#7](bench_client.odin#L1048-L1062) | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **168** | 168 ± 1.6 | 1.0% | 5.8M | 6.0M | 1 | 170 | 171 | 167 | 171 | 1K |
| [#17](bench_client.odin#L1287-L1307) | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **365** | 363 ± 7.1 | 1.9% | 2.7M | 2.8M | 8 | 370 | 371 | 353 | 371 | 100 |
| [#28](bench_client.odin#L1627-L1656) | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **549** | 550 ± 4.4 | 0.8% | 1.79M | 1.83M | 2 | 556 | 558 | 547 | 558 | 500 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 23 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| [#8](bench_client.odin#L1064-L1083) | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.07** | 1.08 ± 0.01 | 1.3% | 907K | 938K | 0.01 | 1.10 | 1.10 | 1.07 | 1.10 | 200 |
| [#9](bench_client.odin#L1085-L1108) | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **1.26** | 1.26 ± 0.01 | 0.6% | 786K | 799K | 0.01 | 1.27 | 1.27 | 1.25 | 1.27 | 200 |
| [#10](bench_client.odin#L1110-L1131) | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **26.6** | 26.7 ± 0.15 | 0.6% | 37.2K | 37.8K | 0.18 | 26.8 | 26.9 | 26.5 | 26.9 | 50 |
| [#11](bench_client.odin#L1133-L1148) | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **1.24** | 1.25 ± 0.01 | 1.0% | 792K | 808K | 0.02 | 1.26 | 1.26 | 1.24 | 1.26 | 200 |
| [#12](bench_client.odin#L1150-L1167) | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **4.08** | 4.11 ± 0.16 | 3.9% | 229K | 252K | 0.14 | 4.33 | 4.37 | 3.97 | 4.38 | 100 |
| [#13](bench_client.odin#L1169-L1183) | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **112.8** | 114.3 ± 3.16 | 2.8% | 8.4K | 9.0K | 2.17 | 118.6 | 119.3 | 111.5 | 119.5 | 1 |
| [#14](bench_client.odin#L1185-L1207) | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **2.27** | 2.29 ± 0.04 | 1.7% | 425K | 443K | 0.04 | 2.34 | 2.35 | 2.26 | 2.35 | 100 |
| [#15](bench_client.odin#L1209-L1234) | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **3.44** | 3.44 ± 0.03 | 1.0% | 286K | 293K | 0.03 | 3.49 | 3.49 | 3.41 | 3.50 | 50 |
| [#16](bench_client.odin#L1236-L1263) | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **2.52** | 2.51 ± 0.17 | 6.8% | 373K | 433K | 0.31 | 2.68 | 2.68 | 2.31 | 2.68 | 100 |
| [#18](bench_client.odin#L1309-L1322) | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **19.6** | 19.6 ± 0.15 | 0.8% | 50.4K | 51.4K | 0.01 | 19.8 | 19.8 | 19.4 | 19.9 | 50 |
| [#19](bench_client.odin#L1341-L1354) | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **100.8** | 105.2 ± 7.43 | 7.1% | 8.7K | 10.1K | 12.4 | 114.0 | 114.3 | 99.0 | 114.4 | 50 |
| [#20](bench_client.odin#L1356-L1376) | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **12.7** | 12.7 ± 0.56 | 4.4% | 74.9K | 83.5K | 0.71 | 13.3 | 13.4 | 12.0 | 13.4 | 20 |
| [#21](bench_client.odin#L1378-L1393) | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **1.70** | 1.70 ± 0.03 | 1.5% | 574K | 596K | 0.02 | 1.74 | 1.74 | 1.68 | 1.74 | 200 |
| [#22](bench_client.odin#L1395-L1416) | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **16.0** | 16.2 ± 0.49 | 3.0% | 58.7K | 62.9K | 0.25 | 16.9 | 17.0 | 15.9 | 17.0 | 50 |
| [#23](bench_client.odin#L1418-L1437) | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **246.3** | 248.2 ± 4.37 | 1.8% | 4.0K | 4.1K | 6.70 | 253.0 | 253.1 | 243.3 | 253.1 | 50 |
| [#24](bench_client.odin#L1439-L1458) | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **30.0** | 30.1 ± 0.23 | 0.8% | 32.9K | 33.5K | 0.28 | 30.4 | 30.4 | 29.9 | 30.4 | 50 |
| [#25](bench_client.odin#L1460-L1515) | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **1.19** | 1.21 ± 0.04 | 3.6% | 775K | 840K | 0.00 | 1.27 | 1.29 | 1.19 | 1.29 | 100 |
| [#26](bench_client.odin#L1517-L1545) | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **84.0** | 83.6 ± 0.63 | 0.8% | 11.9K | 12.1K | 1.11 | 84.2 | 84.2 | 82.9 | 84.2 | 50 |
| [#27](bench_client.odin#L1547-L1625) | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **4.33** | 4.37 ± 0.08 | 1.8% | 222K | 231K | 0.02 | 4.47 | 4.50 | 4.32 | 4.50 | 50 |
| [#29](bench_client.odin#L1658-L1675) | [`Tx: Bulk NIF :bulk_put_maps (100 entities in 1 commit)`](slices/29_tx_bulk_nif_bulk_put_maps_100_entities_in_1_commit.md) | **111.6** | 113.1 ± 2.59 | 2.3% | 8.6K | 9.0K | 4.64 | 116.0 | 116.1 | 110.9 | 116.1 | 10 |
| [#30](bench_client.odin#L1677-L1694) | [`Tx: Bulk NIF :bulk_put_nested_maps (100 nested entities)`](slices/30_tx_bulk_nif_bulk_put_nested_maps_100_nested_entities.md) | **136.7** | 136.3 ± 1.24 | 0.9% | 7.3K | 7.4K | 1.67 | 137.5 | 137.6 | 134.6 | 137.6 | 10 |
| [#31](bench_client.odin#L1696-L1713) | [`Indexer: Bulk NIF :bulk_index_puts (:hash_map_merge, 100 terms)`](slices/31_indexer_bulk_nif_bulk_index_puts_hash_map_merge_100_terms.md) | **121.8** | 121.9 ± 0.63 | 0.5% | 8.1K | 8.3K | 0.61 | 122.7 | 122.8 | 121.2 | 122.8 | 10 |
| [#32](bench_client.odin#L1715-L1741) | [`Access: Batched nif_slot_get_keys (100 keys in 1 NIF call)`](slices/32_access_batched_nif_slot_get_keys_100_keys_in_1_nif_call.md) | **8.46** | 8.45 ± 0.03 | 0.4% | 118K | 119K | 0.05 | 8.48 | 8.49 | 8.41 | 8.49 | 100 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `a6ed18d57b4a`)

#### 3.1 Sub-Microsecond Fast Path (Elixir `< 1 µs`, 8 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | **2.22x** | 385 | **854** | `73.6` ★ | 386 ± 5.6 | 1.5% | 861 ± 13.3 | 1.5% |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | **1.08x** | 648 | **701** | `12.8` ★ | 648 ± 4.3 | 0.7% | 700 ± 7.9 | 1.1% |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | **1.29x** | 441 | **570** | `57.9` ★ | 441 ± 2.9 | 0.6% | 571 ± 4.1 | 0.7% |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | **2.95x** | 73 | **215** | `127.0` ★ | 73 ± 0.0 | 0.0% | 216 ± 2.5 | 1.2% |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | **1.72x** | 239 | **410** | `92.3` ★ | 240 ± 3.3 | 1.4% | 410 ± 2.5 | 0.6% |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | **21.20x** | 5 | **106** | `36.3` ★ | 5 ± 0.0 | 0.0% | 109 ± 6.4 | 5.9% |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | **1.65x** | 168 | **278** | `56.9` ★ | 168 ± 1.6 | 1.0% | 280 ± 4.1 | 1.5% |
| 28 | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | **1.27x** | 549 | **698** | `40.9` ★ | 550 ± 4.4 | 0.8% | 698 ± 6.8 | 1.0% |


#### 3.2 Multi-Microsecond Client Operations (Elixir `≥ 1 µs`, 24 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | **1.65x** | 1.07 | **1.77** | `71.9` ★ | 1.08 ± 0.01 | 1.3% | 1.78 ± 0.02 | 0.9% |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | **2.16x** | 1.26 | **2.72** | `155.9` ★ | 1.26 ± 0.01 | 0.6% | 2.71 ± 0.02 | 0.7% |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | **1.32x** | 26.6 | **35.1** | `11.1` ★ | 26.7 ± 0.15 | 0.6% | 36.0 ± 1.87 | 5.2% |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | **2.20x** | 1.24 | **2.73** | `30.7` ★ | 1.25 ± 0.01 | 1.0% | 2.77 ± 0.11 | 4.0% |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | **1.61x** | 4.08 | **6.58** | `29.0` ★ | 4.11 ± 0.16 | 3.9% | 6.59 ± 0.10 | 1.5% |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | **1.41x** | 112.8 | **159.0** | `23.1` ★ | 114.3 ± 3.16 | 2.8% | 158.1 ± 2.82 | 1.8% |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | **3.46x** | 2.27 | **7.86** | `58.5` ★ | 2.29 ± 0.04 | 1.7% | 7.95 ± 0.21 | 2.7% |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | **3.15x** | 3.44 | **10.8** | `9.6` ★ | 3.44 ± 0.03 | 1.0% | 10.1 ± 1.55 | 15.4% |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | **3.88x** | 2.52 | **9.79** | `4.3` ★ | 2.51 ± 0.17 | 6.8% | 11.5 ± 4.63 | 40.2% |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | **4.27x** | 0.37 | **1.56** | `28.9` ★ | 0.36 ± 0.01 | 1.9% | 1.51 ± 0.09 | 5.9% |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | **2.10x** | 19.6 | **41.2** | `30.8` ★ | 19.6 ± 0.15 | 0.8% | 40.9 ± 1.54 | 3.8% |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | **1.18x** | 100.8 | **118.7** | `3.6` ★ | 105.2 ± 7.43 | 7.1% | 118.7 ± 3.97 | 3.3% |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | **2.47x** | 12.7 | **31.2** | `17.3` ★ | 12.7 ± 0.56 | 4.4% | 32.4 ± 2.49 | 7.7% |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | **4.94x** | 1.70 | **8.37** | `14.4` ★ | 1.70 ± 0.03 | 1.5% | 8.88 ± 1.12 | 12.6% |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | **1.45x** | 16.0 | **23.1** | `10.6` ★ | 16.2 ± 0.49 | 3.0% | 24.0 ± 1.57 | 6.6% |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | **0.82x** | 246.3 | **203.1** | `21.2` ★ | 248.2 ± 4.37 | 1.8% | 203.9 ± 1.64 | 0.8% |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | **1.48x** | 30.0 | **44.5** | `23.7` ★ | 30.1 ± 0.23 | 0.8% | 44.3 ± 1.32 | 3.0% |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | **2.27x** | 1.19 | **2.71** | `54.1` ★ | 1.21 ± 0.04 | 3.6% | 2.73 ± 0.05 | 1.7% |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | **1.00x** | 84.0 | **84.3** | `1.4` ~ | 83.6 ± 0.63 | 0.8% | 101.4 ± 27.4 | 27.1% |
| 27 | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | **1.32x** | 4.33 | **5.70** | `7.2` ★ | 4.37 ± 0.08 | 1.8% | 5.90 ± 0.47 | 7.9% |
| 29 | [`Tx: Bulk NIF :bulk_put_maps (100 entities in 1 commit)`](slices/29_tx_bulk_nif_bulk_put_maps_100_entities_in_1_commit.md) | **1.24x** | 111.6 | **137.9** | `3.8` ★ | 113.1 ± 2.59 | 2.3% | 151.0 ± 22.0 | 14.5% |
| 30 | [`Tx: Bulk NIF :bulk_put_nested_maps (100 nested entities)`](slices/30_tx_bulk_nif_bulk_put_nested_maps_100_nested_entities.md) | **1.23x** | 136.7 | **167.9** | `14.4` ★ | 136.3 ± 1.24 | 0.9% | 168.1 ± 4.78 | 2.8% |
| 31 | [`Indexer: Bulk NIF :bulk_index_puts (:hash_map_merge, 100 terms)`](slices/31_indexer_bulk_nif_bulk_index_puts_hash_map_merge_100_terms.md) | **1.34x** | 121.8 | **163.5** | `14.1` ★ | 121.9 ± 0.63 | 0.5% | 166.5 ± 7.06 | 4.2% |
| 32 | [`Access: Batched nif_slot_get_keys (100 keys in 1 NIF call)`](slices/32_access_batched_nif_slot_get_keys_100_keys_in_1_nif_call.md) | **2.22x** | 8.46 | **18.8** | `44.4` ★ | 8.45 ± 0.03 | 0.4% | 18.6 ± 0.51 | 2.7% |



### 4. Commit-vs-Commit Progression


#### 4.1 Elixir Client Wrapper (`efa5ac160b4d` → `a6ed18d57b4a`)

| # | Benchmark | `efa5ac160b4d` Med | `a6ed18d57b4a` Med | Δ% | Speedup | Welch `z` | `efa5ac160b4d` Mean ± σ | `a6ed18d57b4a` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 2.37 µs | **854 ns** | -64.0% | **2.77x** | `33.7` ★ | 2.39 µs ± 100 ns | 861 ns ± 13 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 2.20 µs | **701 ns** | -68.1% | **3.14x** | `26.2` ★ | 2.24 µs ± 131 ns | 700 ns ± 8 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 814 ns | **570 ns** | -30.0% | **1.43x** | `2.3` ★ | 743 ns ± 168 ns | 571 ns ± 4 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 348 ns | **215 ns** | -38.2% | **1.62x** | `20.2` ★ | 356 ns ± 15 ns | 216 ns ± 3 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 362 ns | **410 ns** | +13.3% | **0.88x** | `1.1` ~ | 388 ns ± 44 ns | 410 ns ± 2 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 163 ns | **106 ns** | -35.0% | **1.54x** | `11.2` ★ | 168 ns ± 10 ns | 109 ns ± 6 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 810 ns | **278 ns** | -65.7% | **2.91x** | `9.3` ★ | 859 ns ± 140 ns | 280 ns ± 4 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 3.05 µs | **1.77 µs** | -42.0% | **1.73x** | `54.3` ★ | 3.04 µs ± 49 ns | 1.78 µs ± 17 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 3.91 µs | **2.72 µs** | -30.6% | **1.44x** | `43.0` ★ | 3.95 µs ± 62 ns | 2.71 µs ± 19 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 63.9 µs | **35.1 µs** | -45.1% | **1.82x** | `25.8` ★ | 65.0 µs ± 1.67 µs | 36.0 µs ± 1.87 µs |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 4.65 µs | **2.73 µs** | -41.2% | **1.70x** | `16.2` ★ | 4.77 µs ± 254 ns | 2.77 µs ± 110 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 13.1 µs | **6.58 µs** | -49.6% | **1.98x** | `9.4` ★ | 14.1 µs ± 1.78 µs | 6.59 µs ± 101 ns |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 446.0 µs | **159.0 µs** | -64.4% | **2.81x** | `12.3` ★ | 438.3 µs ± 50.9 µs | 158.1 µs ± 2.82 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 14.3 µs | **7.86 µs** | -44.9% | **1.82x** | `55.3` ★ | 14.3 µs ± 143 ns | 7.95 µs ± 212 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 14.3 µs | **10.8 µs** | -24.3% | **1.32x** | `4.9` ★ | 14.9 µs ± 1.49 µs | 10.1 µs ± 1.55 µs |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 11.0 µs | **9.79 µs** | -10.9% | **1.12x** | `0.2` ~ | 11.0 µs ± 645 ns | 11.5 µs ± 4.63 µs |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 2.33 µs | **1.56 µs** | -33.0% | **1.49x** | `14.9` ★ | 2.39 µs ± 97 ns | 1.51 µs ± 88 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 54.8 µs | **41.2 µs** | -24.8% | **1.33x** | `4.1` ★ | 56.2 µs ± 8.24 µs | 40.9 µs ± 1.54 µs |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 325.2 µs | **118.7 µs** | -63.5% | **2.74x** | `3.9` ★ | 442.0 µs ± 183.9 µs | 118.7 µs ± 3.97 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 47.5 µs | **31.2 µs** | -34.4% | **1.52x** | `1.0` ~ | 456.5 µs ± 921.1 µs | 32.4 µs ± 2.49 µs |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 16.4 µs | **8.37 µs** | -48.9% | **1.96x** | `1.2` ~ | 36.4 µs ± 49.6 µs | 8.88 µs ± 1.12 µs |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 82.7 µs | **23.1 µs** | -72.0% | **3.57x** | `81.5` ★ | 82.7 µs ± 372 ns | 24.0 µs ± 1.57 µs |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 2.00 ms | **203.1 µs** | -89.8% | **9.85x** | `2.7` ★ | 2.72 ms ± 2.12 ms | 203.9 µs ± 1.64 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 80.2 µs | **44.5 µs** | -44.5% | **1.80x** | `13.9` ★ | 82.2 µs ± 5.95 µs | 44.3 µs ± 1.32 µs |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 11.5 µs | **2.71 µs** | -76.4% | **4.24x** | `12.0` ★ | 12.4 µs ± 1.79 µs | 2.73 µs ± 45 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 421.2 µs | **84.3 µs** | -80.0% | **4.99x** | `12.2` ★ | 397.0 µs ± 46.6 µs | 101.4 µs ± 27.4 µs |
| 27 | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | 18.4 µs | **5.70 µs** | -68.9% | **3.22x** | `28.4` ★ | 18.2 µs ± 847 ns | 5.90 µs ± 468 ns |
| 28 | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | 2.79 µs | **698 ns** | -75.0% | **3.99x** | `7.6` ★ | 2.99 µs ± 678 ns | 698 ns ± 7 ns |



#### 4.2 Raw Odin Baseline (`efa5ac160b4d` → `a6ed18d57b4a`)

| # | Benchmark | `efa5ac160b4d` Med | `a6ed18d57b4a` Med | Δ% | Speedup | Welch `z` | `efa5ac160b4d` Mean ± σ | `a6ed18d57b4a` Mean ± σ |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | [`Access: 3-hop lazy HAMT lookup (root[users][id][name])`](slices/01_access_3_hop_lazy_hamt_lookup_root_users_id_name.md) | 681 ns | **385 ns** | -43.5% | **1.77x** | `8.6` ★ | 707 ns ± 83 ns | 386 ns ± 6 ns |
| 2 | [`Access: Single-call selector select(.users.<id>.name)`](slices/02_access_single_call_selector_select_users_id_name.md) | 1.17 µs | **648 ns** | -44.8% | **1.81x** | `17.3` ★ | 1.16 µs ± 66 ns | 648 ns ± 4 ns |
| 3 | [`Access: Sorted_Map B+Tree key lookup (sorted[key])`](slices/03_access_sorted_map_b_tree_key_lookup_sorted_key.md) | 398 ns | **441 ns** | +10.8% | **0.90x** | `17.8` ★ | 397 ns ± 5 ns | 441 ns ± 3 ns |
| 4 | [`Access: Array_List random index lookup (items[idx])`](slices/04_access_array_list_random_index_lookup_items_idx.md) | 116 ns | **73 ns** | -37.1% | **1.59x** | `99.0` ★ | 116 ns ± 0 ns | 73 ns ± 0 ns |
| 5 | [`Access: Linked_Array_List random index lookup (linked[idx])`](slices/05_access_linked_array_list_random_index_lookup_linked_idx.md) | 130 ns | **239 ns** | +83.8% | **0.54x** | `44.4` ★ | 131 ns ± 4 ns | 240 ns ± 3 ns |
| 6 | [`Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`](slices/06_enum_o_1_enum_count_1_on_counted_hash_map_n_500.md) | 7 ns | **5 ns** | -28.6% | **1.40x** | `99.0` ★ | 7 ns ± 0 ns | 5 ns ± 0 ns |
| 7 | [`Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`](slices/07_enum_o_1_enum_member_2_on_counted_hash_set_n_500.md) | 264 ns | **168 ns** | -36.4% | **1.57x** | `7.8` ★ | 278 ns ± 32 ns | 168 ns ± 2 ns |
| 8 | [`Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`](slices/08_enum_o_log_n_enum_slice_2_window_offset_200_len_20.md) | 1.77 µs | **1.07 µs** | -39.4% | **1.65x** | `16.7` ★ | 1.83 µs ± 99 ns | 1.08 µs ± 14 ns |
| 9 | [`Stream: Lazy Stream.take(10) early-halt on Sorted_Map`](slices/09_stream_lazy_stream_take_10_early_halt_on_sorted_map.md) | 1.53 µs | **1.26 µs** | -17.8% | **1.22x** | `10.9` ★ | 1.57 µs ± 62 ns | 1.26 µs ± 8 ns |
| 10 | [`Enum: Full Enum.to_list/1 stream over Array_List (N=500)`](slices/10_enum_full_enum_to_list_1_stream_over_array_list_n_500.md) | 37.0 µs | **26.6 µs** | -28.1% | **1.39x** | `59.0` ★ | 37.0 µs ± 359 ns | 26.7 µs ± 153 ns |
| 11 | [`Materialize: Eager subtree materialize/1 (user profile)`](slices/11_materialize_eager_subtree_materialize_1_user_profile.md) | 3.31 µs | **1.24 µs** | -62.4% | **2.66x** | `9.6` ★ | 3.10 µs ± 431 ns | 1.25 µs ± 12 ns |
| 12 | [`Tx: Single nested entity transact commit (6 attributes)`](slices/12_tx_single_nested_entity_transact_commit_6_attributes.md) | 9.74 µs | **4.08 µs** | -58.2% | **2.39x** | `7.9` ★ | 9.29 µs ± 1.46 µs | 4.11 µs ± 162 ns |
| 13 | [`Tx: Bulk batch transact (100 entities in 1 commit)`](slices/13_tx_bulk_batch_transact_100_entities_in_1_commit.md) | 300.2 µs | **112.8 µs** | -62.4% | **2.66x** | `6.2` ★ | 326.4 µs ± 76.4 µs | 114.3 µs ± 3.16 µs |
| 14 | [`Tx: Incremental put_in nested attribute commit`](slices/14_tx_incremental_put_in_nested_attribute_commit.md) | 6.68 µs | **2.27 µs** | -66.0% | **2.94x** | `22.6` ★ | 6.92 µs ± 456 ns | 2.29 µs ± 40 ns |
| 15 | [`Tx: Linked_Array_List O(log N) mid-list insert + delete`](slices/15_tx_linked_array_list_o_log_n_mid_list_insert_delete.md) | 10.2 µs | **3.44 µs** | -66.4% | **2.97x** | `6.7` ★ | 10.5 µs ± 2.37 µs | 3.44 µs ± 34 ns |
| 16 | [`Tx: O(1) zero-copy subtree fork (500 entities)`](slices/16_tx_o_1_zero_copy_subtree_fork_500_entities.md) | 4.76 µs | **2.52 µs** | -47.0% | **1.89x** | `4.2` ★ | 5.46 µs ± 1.54 µs | 2.51 µs ± 171 ns |
| 17 | [`Time-Travel: Historical as_of(db, m) across 100 moments`](slices/17_time_travel_historical_as_of_db_m_across_100_moments.md) | 560 ns | **365 ns** | -34.8% | **1.53x** | `7.4` ★ | 587 ns ± 67 ns | 363 ns ± 7 ns |
| 18 | [`Time-Travel: history_of(db, selector) (100 moments)`](slices/18_time_travel_history_of_db_selector_100_moments.md) | 31.2 µs | **19.6 µs** | -37.3% | **1.59x** | `106.1` ★ | 31.3 µs ± 192 ns | 19.6 µs ± 153 ns |
| 19 | [`Time-Travel: diff_moments (1 of 200 entities mutated)`](slices/19_time_travel_diff_moments_1_of_200_entities_mutated.md) | 181.3 µs | **100.8 µs** | -44.4% | **1.80x** | `15.0` ★ | 184.2 µs ± 9.16 µs | 105.2 µs ± 7.43 µs |
| 20 | [`Lifecycle: compact/1 100-moment database deduplication`](slices/20_lifecycle_compact_1_100_moment_database_deduplication.md) | 28.7 µs | **12.7 µs** | -55.9% | **2.27x** | `23.8` ★ | 28.9 µs ± 1.41 µs | 12.7 µs ± 558 ns |
| 21 | [`Query: Datomic pull projection (4 attrs + nested slice)`](slices/21_query_datomic_pull_projection_4_attrs_nested_slice.md) | 3.28 µs | **1.70 µs** | -48.4% | **1.94x** | `15.9` ★ | 3.28 µs ± 220 ns | 1.70 µs ± 25 ns |
| 22 | [`Query: Datalog B+Tree index prefix + join (N=200)`](slices/22_query_datalog_b_tree_index_prefix_join_n_200.md) | 42.3 µs | **16.0 µs** | -62.1% | **2.64x** | `28.0` ★ | 42.9 µs ± 2.08 µs | 16.2 µs ± 488 ns |
| 23 | [`Query: Datalog grouped aggregation (count + sum, N=200)`](slices/23_query_datalog_grouped_aggregation_count_sum_n_200.md) | 580.6 µs | **246.3 µs** | -57.6% | **2.36x** | `6.8` ★ | 575.8 µs ± 108.4 µs | 248.2 µs ± 4.37 µs |
| 24 | [`Storage: Buffered_File transact + sync (50 commits)`](slices/24_storage_buffered_file_transact_sync_50_commits.md) | 79.3 µs | **30.0 µs** | -62.2% | **2.64x** | `65.7` ★ | 78.9 µs ± 1.64 µs | 30.1 µs ± 226 ns |
| 25 | [`Search: Sorted_Map B+Tree prefix seek (limit=16)`](slices/25_search_sorted_map_b_tree_prefix_seek_limit_16.md) | 2.86 µs | **1.19 µs** | -58.3% | **2.40x** | `26.1` ★ | 2.84 µs ± 133 ns | 1.21 µs ± 43 ns |
| 26 | [`Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`](slices/26_search_bm25_corpus_search_n_200_2_term_prefix_limit_10.md) | 197.2 µs | **84.0 µs** | -57.4% | **2.35x** | `10.1` ★ | 206.4 µs ± 27.2 µs | 83.6 µs ± 632 ns |
| 27 | [`Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`](slices/27_indexer_sorted_map_b_tree_range_scan_set_decode_limit_16.md) | 7.95 µs | **4.33 µs** | -45.5% | **1.83x** | `17.5` ★ | 8.23 µs ± 488 ns | 4.37 µs ± 78 ns |
| 28 | [`DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`](slices/28_dsl_pre_tokenized_path_steps_select_path_steps_users_id_name.md) | 913 ns | **549 ns** | -39.9% | **1.66x** | `13.9` ★ | 937 ns ± 62 ns | 550 ns ± 4 ns |



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
| 29 | [`Tx: Bulk NIF :bulk_put_maps (100 entities in 1 commit)`](slices/29_tx_bulk_nif_bulk_put_maps_100_entities_in_1_commit.md) | 10 | 332.8 KB | 332.8 KB |
| 30 | [`Tx: Bulk NIF :bulk_put_nested_maps (100 nested entities)`](slices/30_tx_bulk_nif_bulk_put_nested_maps_100_nested_entities.md) | 10 | 528.9 KB | 528.9 KB |
| 31 | [`Indexer: Bulk NIF :bulk_index_puts (:hash_map_merge, 100 terms)`](slices/31_indexer_bulk_nif_bulk_index_puts_hash_map_merge_100_terms.md) | 10 | 338.0 KB | 338.0 KB |
<!-- END_BENCHMARK_TABLE -->
