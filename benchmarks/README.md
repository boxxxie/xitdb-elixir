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

Or run either side individually:

```bash
# 1. Raw Odin client baseline
odin run benchmarks -collection:xitdb=native/xitdb-odin/xitdb -o:speed -microarch:native -- --runs 5 --warmup 1

# 2. Elixir NIF wrapper
mix run benchmarks/bench_elixir.exs -- --runs 5 --warmup 1
```

To regenerate the reference tables below from `benchmarks/odin.jsonl` and `benchmarks/elixir.jsonl`:

```bash
./benchmarks/update_readme.sh
```

---

## Reference Results (`Elixir NIF Wrapper` vs. `Raw Odin`, `Core_Memory`)

<!-- BEGIN_BENCHMARK_TABLE -->
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `1a603bf720c0`, 5 samples across 1 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 6 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **623** | 707 ± 147 | 20.8% | 1.1M | 1.7M | 194 | 899 | 921 | 596 | 926 | 500 |
| 4 | `Access: Array_List random index lookup (items[idx])` | **327** | 336 ± 26.5 | 7.9% | 2.6M | 3.2M | 26 | 372 | 378 | 315 | 379 | 500 |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **359** | 380 ± 43.1 | 11.4% | 2.2M | 2.8M | 22 | 439 | 452 | 354 | 455 | 500 |
| 6 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **197** | 216 ± 30.9 | 14.3% | 3.8M | 5.3M | 41 | 255 | 259 | 190 | 260 | 1K |
| 7 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **702** | 717 ± 23.3 | 3.3% | 1.3M | 1.4M | 43 | 743 | 743 | 699 | 743 | 1K |
| 10 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **190** | 181 ± 17.1 | 9.4% | 5.1M | 6.4M | 23 | 195 | 195 | 156 | 195 | 500 |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 20 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **2.46** | 2.53 ± 0.20 | 8.1% | 353K | 438K | 0.16 | 2.79 | 2.82 | 2.28 | 2.83 | 500 |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **2.56** | 2.71 ± 0.30 | 11.0% | 317K | 407K | 0.37 | 3.10 | 3.15 | 2.46 | 3.16 | 500 |
| 8 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **3.45** | 3.48 ± 0.25 | 7.1% | 257K | 306K | 0.14 | 3.81 | 3.88 | 3.27 | 3.89 | 200 |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **4.65** | 4.68 ± 0.08 | 1.8% | 207K | 217K | 0.04 | 4.79 | 4.82 | 4.61 | 4.82 | 200 |
| 11 | `Materialize: Eager subtree materialize/1 (user profile)` | **3.41** | 3.66 ± 0.52 | 14.3% | 219K | 300K | 0.26 | 4.38 | 4.53 | 3.33 | 4.57 | 200 |
| 12 | `Tx: Single nested entity transact commit (6 attributes)` | **56.4** | 56.6 ± 3.95 | 7.0% | 16.4K | 19.8K | 2.74 | 60.6 | 61.0 | 50.5 | 61.1 | 100 |
| 13 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **26.1** | 27.0 ± 6.93 | 25.7% | 26.5K | 48.7K | 7.36 | 36.0 | 37.4 | 20.5 | 37.8 | 100 |
| 14 | `Tx: Incremental put_in nested attribute commit` | **25.3** | 24.4 ± 2.23 | 9.1% | 37.8K | 46.0K | 3.90 | 26.4 | 26.4 | 21.7 | 26.5 | 100 |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **20.8** | 21.7 ± 3.86 | 17.8% | 36.1K | 57.9K | 2.26 | 26.7 | 27.5 | 17.3 | 27.7 | 50 |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **11.3** | 13.8 ± 4.98 | 36.2% | 46.9K | 108K | 5.58 | 20.3 | 21.1 | 9.26 | 21.3 | 100 |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **3.65** | 3.58 ± 0.46 | 12.7% | 247K | 322K | 0.88 | 4.04 | 4.04 | 3.11 | 4.05 | 100 |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **217.0** | 218.5 ± 7.74 | 3.5% | 4.4K | 4.8K | 9.43 | 227.7 | 228.5 | 209.1 | 228.8 | 50 |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **322.4** | 324.4 ± 10.8 | 3.3% | 2.9K | 3.2K | 4.53 | 338.9 | 342.2 | 315.7 | 343.0 | 50 |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **29.3** | 29.9 ± 2.81 | 9.4% | 29.9K | 37.3K | 4.25 | 33.2 | 33.4 | 26.8 | 33.5 | 20 |
| 21 | `Query: Datomic pull projection (4 attrs + nested slice)` | **6.00** | 5.97 ± 0.17 | 2.9% | 162K | 173K | 0.26 | 6.16 | 6.17 | 5.77 | 6.17 | 200 |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **47.0** | 46.9 ± 0.45 | 0.9% | 21.1K | 21.6K | 0.73 | 47.4 | 47.4 | 46.4 | 47.4 | 50 |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **820.5** | 800.2 ± 91.9 | 11.5% | 1.1K | 1.4K | 97.4 | 908.6 | 924.9 | 694.9 | 929.0 | 50 |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **91.4** | 92.0 ± 6.77 | 7.4% | 9.9K | 12.1K | 5.67 | 99.7 | 100.5 | 82.5 | 100.7 | 50 |
| 25 | `Search: Sorted_Map B+Tree prefix seek (limit=16)` | **13.0** | 14.9 ± 6.86 | 46.2% | 43.6K | 134K | 11.3 | 22.6 | 22.9 | 7.44 | 22.9 | 100 |
| 26 | `Search: BM25 corpus search (N=200, 2-term prefix, limit=10)` | **352.5** | 336.7 ± 25.9 | 7.7% | 2.8K | 3.3K | 36.2 | 358.5 | 359.7 | 301.5 | 360.0 | 50 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `1a603bf720c0`, 5 samples across 1 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 8 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **815** | 807 ± 126 | 15.6% | 1.1M | 1.5M | 231 | 932 | 933 | 662 | 933 | 500 |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **412** | 458 ± 81.3 | 17.7% | 1.8M | 2.6M | 136 | 548 | 550 | 380 | 550 | 500 |
| 4 | `Access: Array_List random index lookup (items[idx])` | **113** | 115 ± 4.7 | 4.1% | 8.1M | 8.9M | 2 | 121 | 123 | 112 | 123 | 500 |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **124** | 136 ± 24.1 | 17.7% | 5.6M | 8.3M | 18 | 169 | 175 | 120 | 177 | 500 |
| 6 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **12** | 12 ± 0.0 | 0.0% | 83.3M | 83.3M | 0 | 12 | 12 | 12 | 12 | 1K |
| 7 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **428** | 425 ± 39.2 | 9.2% | 2.1M | 2.7M | 11 | 468 | 475 | 367 | 477 | 1K |
| 10 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **91** | 103 ± 25.5 | 24.7% | 7.4M | 13.5M | 33 | 133 | 135 | 74 | 135 | 500 |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **665** | 661 ± 28.8 | 4.4% | 1.4M | 1.6M | 13 | 687 | 689 | 613 | 690 | 100 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 18 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **1.20** | 1.26 ± 0.16 | 12.5% | 686K | 895K | 0.27 | 1.44 | 1.46 | 1.12 | 1.46 | 500 |
| 8 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **1.79** | 1.80 ± 0.17 | 9.5% | 483K | 614K | 0.14 | 2.02 | 2.06 | 1.63 | 2.07 | 200 |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **1.43** | 1.43 ± 0.02 | 1.2% | 683K | 703K | 0.00 | 1.46 | 1.46 | 1.42 | 1.47 | 200 |
| 11 | `Materialize: Eager subtree materialize/1 (user profile)` | **3.27** | 3.26 ± 0.32 | 9.9% | 279K | 360K | 0.37 | 3.57 | 3.58 | 2.78 | 3.58 | 200 |
| 12 | `Tx: Single nested entity transact commit (6 attributes)` | **17.8** | 18.4 ± 1.27 | 6.9% | 49.1K | 58.1K | 1.29 | 20.1 | 20.3 | 17.2 | 20.4 | 100 |
| 13 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **6.35** | 6.24 ± 0.61 | 9.7% | 148K | 190K | 0.61 | 6.76 | 6.76 | 5.27 | 6.76 | 100 |
| 14 | `Tx: Incremental put_in nested attribute commit` | **4.71** | 4.65 ± 1.04 | 22.3% | 163K | 276K | 1.29 | 5.92 | 6.10 | 3.62 | 6.15 | 100 |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **7.13** | 7.25 ± 1.23 | 17.0% | 112K | 183K | 0.49 | 8.64 | 8.85 | 5.48 | 8.90 | 50 |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **5.21** | 5.03 ± 0.71 | 14.1% | 169K | 246K | 0.70 | 5.80 | 5.89 | 4.06 | 5.91 | 100 |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **74.6** | 75.1 ± 1.23 | 1.6% | 13.0K | 13.6K | 1.75 | 76.5 | 76.6 | 73.7 | 76.6 | 50 |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **203.7** | 201.2 ± 7.01 | 3.5% | 4.8K | 5.3K | 1.11 | 205.9 | 206.3 | 188.9 | 206.4 | 50 |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **21.7** | 21.8 ± 2.42 | 11.1% | 39.5K | 53.5K | 1.74 | 24.8 | 25.2 | 18.7 | 25.3 | 20 |
| 21 | `Query: Datomic pull projection (4 attrs + nested slice)` | **3.46** | 3.28 ± 0.44 | 13.4% | 262K | 367K | 0.53 | 3.74 | 3.80 | 2.72 | 3.81 | 200 |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **27.1** | 27.5 ± 1.95 | 7.1% | 33.8K | 39.9K | 2.93 | 29.6 | 29.6 | 25.1 | 29.6 | 50 |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **529.2** | 533.4 ± 25.3 | 4.7% | 1.8K | 2.0K | 31.0 | 558.8 | 559.3 | 497.6 | 559.5 | 50 |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **57.8** | 58.1 ± 2.88 | 4.9% | 16.4K | 18.5K | 3.72 | 60.9 | 61.0 | 54.0 | 61.0 | 50 |
| 25 | `Search: Sorted_Map B+Tree prefix seek (limit=16)` | **1.52** | 1.57 ± 0.14 | 8.8% | 549K | 666K | 0.01 | 1.76 | 1.81 | 1.50 | 1.82 | 100 |
| 26 | `Search: BM25 corpus search (N=200, 2-term prefix, limit=10)` | **174.6** | 172.7 ± 5.60 | 3.2% | 5.6K | 6.0K | 6.76 | 178.8 | 179.6 | 165.8 | 179.7 | 50 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `1a603bf720c0`)

#### 3.1 Sub-Microsecond Fast Path (`ns`, 6 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **1.51x** | 412 | **623** | `3.3` ★ | 458 ± 81.3 | 17.7% | 707 ± 147 | 20.8% |
| 4 | `Access: Array_List random index lookup (items[idx])` | **2.89x** | 113 | **327** | `18.4` ★ | 115 ± 4.7 | 4.1% | 336 ± 26.5 | 7.9% |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **2.90x** | 124 | **359** | `11.0` ★ | 136 ± 24.1 | 17.7% | 380 ± 43.1 | 11.4% |
| 6 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **16.42x** | 12 | **197** | `14.8` ★ | 12 ± 0.0 | 0.0% | 216 ± 30.9 | 14.3% |
| 7 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **1.64x** | 428 | **702** | `14.3` ★ | 425 ± 39.2 | 9.2% | 717 ± 23.3 | 3.3% |
| 10 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **2.09x** | 91 | **190** | `5.7` ★ | 103 ± 25.5 | 24.7% | 181 ± 17.1 | 9.4% |


#### 3.2 Multi-Microsecond Client Operations (`µs`, 20 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **3.02x** | 0.82 | **2.46** | `16.0` ★ | 0.81 ± 0.13 | 15.6% | 2.53 ± 0.20 | 8.1% |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **2.13x** | 1.20 | **2.56** | `9.6` ★ | 1.26 ± 0.16 | 12.5% | 2.71 ± 0.30 | 11.0% |
| 8 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **1.92x** | 1.79 | **3.45** | `12.4` ★ | 1.80 ± 0.17 | 9.5% | 3.48 ± 0.25 | 7.1% |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **3.26x** | 1.43 | **4.65** | `83.8` ★ | 1.43 ± 0.02 | 1.2% | 4.68 ± 0.08 | 1.8% |
| 11 | `Materialize: Eager subtree materialize/1 (user profile)` | **1.04x** | 3.27 | **3.41** | `1.4` ~ | 3.26 ± 0.32 | 9.9% | 3.66 ± 0.52 | 14.3% |
| 12 | `Tx: Single nested entity transact commit (6 attributes)` | **3.16x** | 17.8 | **56.4** | `20.6` ★ | 18.4 ± 1.27 | 6.9% | 56.6 ± 3.95 | 7.0% |
| 13 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **4.11x** | 6.35 | **26.1** | `6.7` ★ | 6.24 ± 0.61 | 9.7% | 27.0 ± 6.93 | 25.7% |
| 14 | `Tx: Incremental put_in nested attribute commit` | **5.38x** | 4.71 | **25.3** | `18.0` ★ | 4.65 ± 1.04 | 22.3% | 24.4 ± 2.23 | 9.1% |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **2.91x** | 7.13 | **20.8** | `8.0` ★ | 7.25 ± 1.23 | 17.0% | 21.7 ± 3.86 | 17.8% |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **2.17x** | 5.21 | **11.3** | `3.9` ★ | 5.03 ± 0.71 | 14.1% | 13.8 ± 4.98 | 36.2% |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **5.48x** | 0.67 | **3.65** | `14.3` ★ | 0.66 ± 0.03 | 4.4% | 3.58 ± 0.46 | 12.7% |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **2.91x** | 74.6 | **217.0** | `40.9` ★ | 75.1 ± 1.23 | 1.6% | 218.5 ± 7.74 | 3.5% |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **1.58x** | 203.7 | **322.4** | `21.3` ★ | 201.2 ± 7.01 | 3.5% | 324.4 ± 10.8 | 3.3% |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **1.35x** | 21.7 | **29.3** | `4.8` ★ | 21.8 ± 2.42 | 11.1% | 29.9 ± 2.81 | 9.4% |
| 21 | `Query: Datomic pull projection (4 attrs + nested slice)` | **1.74x** | 3.46 | **6.00** | `12.8` ★ | 3.28 ± 0.44 | 13.4% | 5.97 ± 0.17 | 2.9% |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **1.74x** | 27.1 | **47.0** | `21.7` ★ | 27.5 ± 1.95 | 7.1% | 46.9 ± 0.45 | 0.9% |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **1.55x** | 529.2 | **820.5** | `6.3` ★ | 533.4 ± 25.3 | 4.7% | 800.2 ± 91.9 | 11.5% |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **1.58x** | 57.8 | **91.4** | `10.3` ★ | 58.1 ± 2.88 | 4.9% | 92.0 ± 6.77 | 7.4% |
| 25 | `Search: Sorted_Map B+Tree prefix seek (limit=16)` | **8.61x** | 1.52 | **13.0** | `4.3` ★ | 1.57 ± 0.14 | 8.8% | 14.9 ± 6.86 | 46.2% |
| 26 | `Search: BM25 corpus search (N=200, 2-term prefix, limit=10)` | **2.02x** | 174.6 | **352.5** | `13.8` ★ | 172.7 ± 5.60 | 3.2% | 336.7 ± 25.9 | 7.7% |

### 4. Database Storage Footprint (`bytes_used > 0`)

| # | Benchmark | Ops | Raw Odin Size | Elixir Wrapper Size |
| ---: | :--- | ---: | ---: | ---: |
| 12 | `Tx: Single nested entity transact commit (6 attributes)` | 100 | 128.3 KB | 128.3 KB |
| 13 | `Tx: Bulk batch transact (100 entities in 1 commit)` | 100 | 33.5 KB | 33.5 KB |
| 14 | `Tx: Incremental put_in nested attribute commit` | 100 | 85.3 KB | 85.3 KB |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | 50 | 69.7 KB | 69.7 KB |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | 100 | 737.3 KB | 730.5 KB |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | 20 | 1.0 KB | 1.0 KB |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | 50 | 38.5 KB | 38.5 KB |
<!-- END_BENCHMARK_TABLE -->
