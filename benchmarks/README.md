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
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `0421fe5300ba`, 5 samples across 1 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 5 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **636** | 638 ± 5.8 | 0.9% | 1.5M | 1.6M | 5 | 646 | 647 | 632 | 647 | 500 |
| 4 | `Access: Array_List random index lookup (items[idx])` | **331** | 333 ± 9.7 | 2.9% | 2.9M | 3.1M | 8 | 346 | 348 | 325 | 349 | 500 |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **365** | 375 ± 18.4 | 4.9% | 2.5M | 2.8M | 13 | 400 | 405 | 363 | 406 | 500 |
| 6 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **195** | 205 ± 18.3 | 8.9% | 4.2M | 5.2M | 9 | 230 | 236 | 194 | 237 | 1K |
| 7 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **698** | 697 ± 11.8 | 1.7% | 1.4M | 1.5M | 18 | 711 | 712 | 684 | 712 | 1K |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 21 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **2.52** | 2.51 ± 0.16 | 6.4% | 364K | 425K | 0.18 | 2.71 | 2.74 | 2.35 | 2.75 | 500 |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **2.44** | 2.45 ± 0.04 | 1.6% | 396K | 412K | 0.01 | 2.51 | 2.52 | 2.43 | 2.52 | 500 |
| 8 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **3.36** | 3.38 ± 0.07 | 2.0% | 288K | 304K | 0.03 | 3.46 | 3.47 | 3.29 | 3.48 | 200 |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **4.68** | 4.66 ± 0.09 | 2.0% | 211K | 223K | 0.00 | 4.72 | 4.73 | 4.49 | 4.74 | 200 |
| 10 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **81.4** | 81.6 ± 0.76 | 0.9% | 12.1K | 12.4K | 1.10 | 82.6 | 82.7 | 81.0 | 82.7 | 50 |
| 11 | `Materialize: Eager subtree materialize/1 (user profile)` | **3.34** | 3.38 ± 0.09 | 2.7% | 283K | 302K | 0.05 | 3.50 | 3.53 | 3.31 | 3.53 | 200 |
| 12 | `Tx: Single nested entity transact commit (6 attributes)` | **53.7** | 54.9 ± 2.65 | 4.8% | 17.0K | 19.1K | 2.84 | 58.3 | 58.8 | 52.3 | 58.9 | 100 |
| 13 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **2062.8** | 2123.6 ± 107.7 | 5.1% | 433 | 486 | 73.9 | 2272.6 | 2300.8 | 2057.2 | 2307.8 | 1 |
| 14 | `Tx: Incremental put_in nested attribute commit` | **22.5** | 23.2 ± 1.88 | 8.1% | 37.7K | 45.2K | 0.51 | 25.8 | 26.4 | 22.1 | 26.5 | 100 |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **19.7** | 19.9 ± 0.58 | 2.9% | 47.9K | 51.5K | 0.35 | 20.7 | 20.8 | 19.4 | 20.9 | 50 |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **12.0** | 12.4 ± 2.21 | 17.9% | 62.5K | 95.2K | 1.87 | 15.3 | 15.9 | 10.5 | 16.0 | 100 |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **2.59** | 2.58 ± 0.16 | 6.2% | 356K | 417K | 0.17 | 2.77 | 2.80 | 2.40 | 2.81 | 100 |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **207.8** | 210.0 ± 5.20 | 2.5% | 4.6K | 4.8K | 0.40 | 217.0 | 218.8 | 207.5 | 219.3 | 50 |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **329.5** | 333.8 ± 14.6 | 4.4% | 2.8K | 3.1K | 10.6 | 353.0 | 356.2 | 318.5 | 357.0 | 50 |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **28.7** | 28.2 ± 1.09 | 3.9% | 34.5K | 37.9K | 0.85 | 29.0 | 29.0 | 26.4 | 29.0 | 20 |
| 21 | `Query: Datomic pull projection (4 attrs + nested slice)` | **5.77** | 5.83 ± 0.13 | 2.2% | 166K | 175K | 0.14 | 6.00 | 6.02 | 5.71 | 6.03 | 200 |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **48.3** | 48.3 ± 0.21 | 0.4% | 20.6K | 20.8K | 0.35 | 48.6 | 48.6 | 48.1 | 48.6 | 50 |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **579.1** | 579.4 ± 2.63 | 0.5% | 1.71K | 1.73K | 1.77 | 582.8 | 583.5 | 576.7 | 583.6 | 50 |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **80.0** | 77.1 ± 8.36 | 10.9% | 11.8K | 14.7K | 16.2 | 84.6 | 84.6 | 68.1 | 84.6 | 50 |
| 25 | `Search: Sorted_Map B+Tree prefix seek (limit=16)` | **5.62** | 5.65 ± 0.07 | 1.2% | 174K | 178K | 0.07 | 5.74 | 5.76 | 5.60 | 5.76 | 100 |
| 26 | `Search: BM25 corpus search (N=200, 2-term prefix, limit=10)` | **257.0** | 263.7 ± 15.3 | 5.8% | 3.4K | 3.9K | 1.66 | 284.4 | 289.7 | 256.2 | 291.0 | 50 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `0421fe5300ba`, 5 samples across 1 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 7 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **631** | 665 ± 83.3 | 12.5% | 1.2M | 1.6M | 14 | 778 | 806 | 617 | 813 | 500 |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **405** | 425 ± 43.8 | 10.3% | 2.0M | 2.5M | 19 | 485 | 498 | 394 | 501 | 500 |
| 4 | `Access: Array_List random index lookup (items[idx])` | **160** | 160 ± 4.5 | 2.8% | 6.0M | 6.5M | 4 | 165 | 166 | 154 | 166 | 500 |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **193** | 192 ± 6.7 | 3.5% | 5.0M | 5.5M | 8 | 198 | 199 | 182 | 199 | 500 |
| 6 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **12** | 12 ± 0.0 | 0.0% | 83.3M | 83.3M | 0 | 12 | 12 | 12 | 12 | 1K |
| 7 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **410** | 399 ± 57.9 | 14.5% | 2.2M | 3.2M | 71 | 453 | 455 | 313 | 455 | 1K |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **552** | 552 ± 2.5 | 0.5% | 1.81M | 1.82M | 3 | 554 | 554 | 548 | 554 | 100 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 19 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **1.09** | 1.22 ± 0.23 | 18.5% | 674K | 981K | 0.39 | 1.47 | 1.48 | 1.02 | 1.48 | 500 |
| 8 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **1.66** | 1.68 ± 0.10 | 5.7% | 544K | 624K | 0.09 | 1.81 | 1.83 | 1.60 | 1.84 | 200 |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **1.44** | 1.44 ± 0.02 | 1.3% | 677K | 698K | 0.01 | 1.47 | 1.48 | 1.43 | 1.48 | 200 |
| 10 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **36.4** | 36.8 ± 1.19 | 3.2% | 26.1K | 28.1K | 1.81 | 38.2 | 38.3 | 35.6 | 38.4 | 50 |
| 11 | `Materialize: Eager subtree materialize/1 (user profile)` | **2.69** | 2.73 ± 0.10 | 3.8% | 343K | 374K | 0.04 | 2.88 | 2.91 | 2.67 | 2.92 | 200 |
| 12 | `Tx: Single nested entity transact commit (6 attributes)` | **13.6** | 14.0 ± 1.09 | 7.7% | 64.4K | 76.8K | 1.59 | 15.4 | 15.5 | 13.0 | 15.5 | 100 |
| 13 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **486.3** | 495.6 ± 16.9 | 3.4% | 1.9K | 2.1K | 28.0 | 515.8 | 516.8 | 481.5 | 517.1 | 1 |
| 14 | `Tx: Incremental put_in nested attribute commit` | **3.90** | 3.86 ± 0.14 | 3.6% | 251K | 275K | 0.12 | 3.98 | 3.98 | 3.63 | 3.98 | 100 |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **5.46** | 5.61 ± 0.47 | 8.3% | 156K | 189K | 0.29 | 6.25 | 6.38 | 5.29 | 6.41 | 50 |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **4.18** | 4.13 ± 0.15 | 3.6% | 233K | 253K | 0.23 | 4.28 | 4.29 | 3.95 | 4.30 | 100 |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **73.0** | 77.7 ± 12.4 | 15.9% | 10.4K | 15.0K | 16.8 | 93.6 | 95.3 | 66.9 | 95.8 | 50 |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **183.3** | 184.7 ± 6.38 | 3.5% | 5.1K | 5.6K | 4.56 | 193.4 | 195.1 | 180.0 | 195.5 | 50 |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **18.4** | 18.6 ± 0.71 | 3.8% | 50.4K | 55.4K | 0.24 | 19.6 | 19.8 | 18.1 | 19.9 | 20 |
| 21 | `Query: Datomic pull projection (4 attrs + nested slice)` | **2.82** | 2.81 ± 0.16 | 5.5% | 329K | 377K | 0.17 | 3.00 | 3.03 | 2.65 | 3.04 | 200 |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **25.7** | 25.8 ± 0.85 | 3.3% | 37.2K | 40.2K | 1.30 | 26.8 | 26.9 | 24.9 | 26.9 | 50 |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **485.7** | 491.6 ± 15.0 | 3.1% | 2.0K | 2.1K | 22.1 | 510.4 | 512.1 | 477.8 | 512.5 | 50 |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **50.9** | 51.2 ± 0.67 | 1.3% | 19.2K | 19.8K | 1.04 | 52.0 | 52.1 | 50.6 | 52.1 | 50 |
| 25 | `Search: Sorted_Map B+Tree prefix seek (limit=16)` | **1.50** | 1.53 ± 0.07 | 4.6% | 606K | 670K | 0.00 | 1.62 | 1.64 | 1.49 | 1.65 | 100 |
| 26 | `Search: BM25 corpus search (N=200, 2-term prefix, limit=10)` | **182.1** | 188.3 ± 27.0 | 14.3% | 4.3K | 5.9K | 11.2 | 224.8 | 233.2 | 169.1 | 235.2 | 50 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `0421fe5300ba`)

#### 3.1 Sub-Microsecond Fast Path (`ns`, 5 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **1.57x** | 405 | **636** | `10.8` ★ | 425 ± 43.8 | 10.3% | 638 ± 5.8 | 0.9% |
| 4 | `Access: Array_List random index lookup (items[idx])` | **2.07x** | 160 | **331** | `36.3` ★ | 160 ± 4.5 | 2.8% | 333 ± 9.7 | 2.9% |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **1.89x** | 193 | **365** | `20.9` ★ | 192 ± 6.7 | 3.5% | 375 ± 18.4 | 4.9% |
| 6 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **16.25x** | 12 | **195** | `23.5` ★ | 12 ± 0.0 | 0.0% | 205 ± 18.3 | 8.9% |
| 7 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **1.70x** | 410 | **698** | `11.3` ★ | 399 ± 57.9 | 14.5% | 697 ± 11.8 | 1.7% |


#### 3.2 Multi-Microsecond Client Operations (`µs`, 21 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch `z` | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **4.00x** | 0.63 | **2.52** | `22.7` ★ | 0.66 ± 0.08 | 12.5% | 2.51 ± 0.16 | 6.4% |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **2.24x** | 1.09 | **2.44** | `12.1` ★ | 1.22 ± 0.23 | 18.5% | 2.45 ± 0.04 | 1.6% |
| 8 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **2.03x** | 1.66 | **3.36** | `32.2` ★ | 1.68 ± 0.10 | 5.7% | 3.38 ± 0.07 | 2.0% |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **3.26x** | 1.44 | **4.68** | `74.4` ★ | 1.44 ± 0.02 | 1.3% | 4.66 ± 0.09 | 2.0% |
| 10 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **2.24x** | 36.4 | **81.4** | `71.1` ★ | 36.8 ± 1.19 | 3.2% | 81.6 ± 0.76 | 0.9% |
| 11 | `Materialize: Eager subtree materialize/1 (user profile)` | **1.24x** | 2.69 | **3.34** | `10.4` ★ | 2.73 ± 0.10 | 3.8% | 3.38 ± 0.09 | 2.7% |
| 12 | `Tx: Single nested entity transact commit (6 attributes)` | **3.95x** | 13.6 | **53.7** | `31.9` ★ | 14.0 ± 1.09 | 7.7% | 54.9 ± 2.65 | 4.8% |
| 13 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **4.24x** | 486.3 | **2062.8** | `33.4` ★ | 495.6 ± 16.9 | 3.4% | 2123.6 ± 107.7 | 5.1% |
| 14 | `Tx: Incremental put_in nested attribute commit` | **5.77x** | 3.90 | **22.5** | `22.9` ★ | 3.86 ± 0.14 | 3.6% | 23.2 ± 1.88 | 8.1% |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **3.62x** | 5.46 | **19.7** | `43.0` ★ | 5.61 ± 0.47 | 8.3% | 19.9 ± 0.58 | 2.9% |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **2.86x** | 4.18 | **12.0** | `8.3` ★ | 4.13 ± 0.15 | 3.6% | 12.4 ± 2.21 | 17.9% |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **4.68x** | 0.55 | **2.59** | `28.2` ★ | 0.55 ± 0.00 | 0.5% | 2.58 ± 0.16 | 6.2% |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **2.85x** | 73.0 | **207.8** | `22.1` ★ | 77.7 ± 12.4 | 15.9% | 210.0 ± 5.20 | 2.5% |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **1.80x** | 183.3 | **329.5** | `20.9` ★ | 184.7 ± 6.38 | 3.5% | 333.8 ± 14.6 | 4.4% |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **1.56x** | 18.4 | **28.7** | `16.5` ★ | 18.6 ± 0.71 | 3.8% | 28.2 ± 1.09 | 3.9% |
| 21 | `Query: Datomic pull projection (4 attrs + nested slice)` | **2.05x** | 2.82 | **5.77** | `33.2` ★ | 2.81 ± 0.16 | 5.5% | 5.83 ± 0.13 | 2.2% |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **1.88x** | 25.7 | **48.3** | `57.3` ★ | 25.8 ± 0.85 | 3.3% | 48.3 ± 0.21 | 0.4% |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **1.19x** | 485.7 | **579.1** | `12.9` ★ | 491.6 ± 15.0 | 3.1% | 579.4 ± 2.63 | 0.5% |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **1.57x** | 50.9 | **80.0** | `6.9` ★ | 51.2 ± 0.67 | 1.3% | 77.1 ± 8.36 | 10.9% |
| 25 | `Search: Sorted_Map B+Tree prefix seek (limit=16)` | **3.75x** | 1.50 | **5.62** | `96.2` ★ | 1.53 ± 0.07 | 4.6% | 5.65 ± 0.07 | 1.2% |
| 26 | `Search: BM25 corpus search (N=200, 2-term prefix, limit=10)` | **1.41x** | 182.1 | **257.0** | `5.4` ★ | 188.3 ± 27.0 | 14.3% | 263.7 ± 15.3 | 5.8% |

### 4. Database Storage Footprint (`bytes_used > 0`)

| # | Benchmark | Ops | Raw Odin Size | Elixir Wrapper Size |
| ---: | :--- | ---: | ---: | ---: |
| 12 | `Tx: Single nested entity transact commit (6 attributes)` | 100 | 128.3 KB | 128.3 KB |
| 13 | `Tx: Bulk batch transact (100 entities in 1 commit)` | 1 | 33.5 KB | 33.5 KB |
| 14 | `Tx: Incremental put_in nested attribute commit` | 100 | 85.3 KB | 85.3 KB |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | 50 | 69.7 KB | 69.7 KB |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | 100 | 737.3 KB | 730.5 KB |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | 20 | 1.0 KB | 1.0 KB |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | 50 | 38.5 KB | 38.5 KB |
<!-- END_BENCHMARK_TABLE -->
