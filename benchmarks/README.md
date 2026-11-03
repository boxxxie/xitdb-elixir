# Xitdb Elixir Client Benchmarks

This directory contains the 1v1 statistical benchmark suite for `Xitdb`, measuring **client-boundary overhead** and throughput ($\text{ops/sec}$), median/mean latency ($\text{ns/op}$), variance ($\pm\sigma$, $\text{CV}\%$, $\text{IQR}$, $\text{p95}$, $\text{p99}$, $\text{min..max}$), and resulting database byte footprint between the **Elixir NIF Wrapper (`lang: "elixir"`)** and **Raw Odin (`lang: "odin"`)**.

Unlike the upstream `odin-xitdb` benchmark suite (which benchmarks low-level HAMT/B+Tree node splits, hashers, and raw byte streams), this suite focuses exclusively on **24 orthogonal, zero-redundancy client-facing workloads** across five groups:
1. **`access` (`#1–#5`)**: 3-hop lazy `Access` HAMT navigation (`root["users"][id]["name"]`), single-call selector traversal (`Xitdb.select!/2`), `Sorted_Map` B+Tree binary-search key lookup (`sorted[key]`), `Array_List` 16-way Radix Trie indexing (`items[idx]`), and `Linked_Array_List` count-augmented B-Tree indexing (`linked[idx]`).
2. **`enumerable & stream` (`#6–#11`)**: $O(1)$ `Enum.count/1` on `Counted_Hash_Map`, $O(1)$ `Enum.member?/2` on `Counted_Hash_Set`, $O(\log N)$ `Enum.slice/2` on `Array_List`, bounded `Stream.take/2` early-halt on `Sorted_Map`, full `Enum.to_list/1` on `Array_List`, and `Xitdb.materialize/1` subtree conversion.
3. **`transactions` (`#12–#16`)**: Single-entity `Xitdb.transact/2` map commits, bulk 100-entity batch commits, incremental `put_in/3` cursor transactions, $O(\log N)$ mid-list `Xitdb.insert_at/4` + `Xitdb.delete_at/3` on `Linked_Array_List`, and $O(1)$ zero-copy subtree `Xitdb.fork/3`.
4. **`time-travel & lifecycle` (`#17–#20`)**: `Xitdb.as_of/2` historical snapshot resolution across 100 moments, `Xitdb.history_of/2` attribute lineage scan across 100 moments, $O(\Delta)$ `Xitdb.diff_moments/3` structural diffs, and `Xitdb.compact/1` 100-moment database deduplication.
5. **`queries & storage` (`#21–#24`)**: Datomic-style `Xitdb.pull/2` nested projections, Datalog B+Tree secondary index prefix seek + join (`Xitdb.query/2`), Datalog grouped aggregations (`count`, `sum`), and on-disk `Buffered_File` transactional commits + `Xitdb.sync/1`.

---

## Running the Benchmarks

Run both the Raw Odin baseline and the Elixir NIF wrapper back-to-back with unified Git commit/run tagging and Welch's $z$-score comparison:

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
### 1. Elixir Client Wrapper Results (`mix run + priv/xitdb_nif.so -o:speed`, Commit `unknown`, 20 samples across 4 run(s))

#### 1.1 Sub-Microsecond Fast Path (`< 1 µs`, 8 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | `Access: Array_List random index lookup (cursor[idx])` | **240** | 1,063 ± 1,222 | 114.9% | 306K | 4.6M | 2,238 | 2,993 | 3,210 | 218 | 3,264 | 500 |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **374** | 373 ± 8.5 | 2.3% | 2.6M | 2.8M | 12 | 387 | 391 | 361 | 392 | 500 |
| 4 | `Access: Array_List random index lookup (items[idx])` | **212** | 212 ± 4.2 | 2.0% | 4.5M | 4.9M | 4 | 218 | 221 | 203 | 222 | 500 |
| 4 | `Access: Linked_Array_List random index lookup (cursor[idx])` | **254** | 1,053 ± 1,192 | 113.2% | 294K | 4.2M | 2,199 | 2,763 | 3,278 | 237 | 3,407 | 500 |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **228** | 229 ± 6.9 | 3.0% | 4.0M | 4.5M | 5 | 242 | 248 | 222 | 250 | 500 |
| 5 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **121** | 128 ± 16.6 | 13.0% | 5.9M | 8.8M | 9 | 167 | 169 | 113 | 169 | 1K |
| 6 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **438** | 491 ± 105 | 21.5% | 1.2M | 2.4M | 83 | 697 | 809 | 423 | 828 | 1K |
| 8 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **124** | 129 ± 30.8 | 23.8% | 4.9M | 11.6M | 36 | 184 | 198 | 86 | 203 | 500 |


#### 1.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 22 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **1.33** | 1.35 ± 0.10 | 7.6% | 562K | 767K | 0.02 | 1.45 | 1.71 | 1.30 | 1.78 | 500 |
| 1 | `Access: 3-hop lazy nested lookup (db[users][id][name])` | **1.85** | 5.93 ± 6.28 | 105.8% | 64.9K | 741K | 12.7 | 14.8 | 15.3 | 1.35 | 15.4 | 500 |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **1.45** | 1.69 ± 0.51 | 30.2% | 299K | 713K | 0.23 | 2.99 | 3.28 | 1.40 | 3.35 | 500 |
| 7 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **2.19** | 2.20 ± 0.19 | 8.4% | 314K | 484K | 0.13 | 2.31 | 2.91 | 2.07 | 3.19 | 200 |
| 9 | `Materialize: Eager subtree materialize/1 (user profile)` | **2.30** | 2.40 ± 0.35 | 14.6% | 257K | 455K | 0.10 | 2.91 | 3.80 | 2.20 | 3.90 | 200 |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **4.27** | 4.22 ± 1.07 | 25.4% | 188K | 322K | 2.08 | 5.32 | 5.33 | 3.11 | 5.33 | 200 |
| 10 | `Tx: Single nested entity transact commit (6 attributes)` | **29.1** | 31.1 ± 3.66 | 11.8% | 24.6K | 35.5K | 5.47 | 38.1 | 40.1 | 28.2 | 40.7 | 100 |
| 11 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **11.9** | 12.2 ± 1.14 | 9.3% | 64.5K | 91.4K | 1.47 | 14.3 | 15.2 | 10.9 | 15.5 | 100 |
| 12 | `Tx: Incremental put_in nested attribute commit` | **21.9** | 20.4 ± 6.14 | 30.1% | 30.7K | 94.5K | 10.1 | 28.7 | 32.5 | 10.6 | 32.6 | 100 |
| 13 | `Time-Travel: Historical as_of(moment) pinned read` | **1.55** | 5.88 ± 6.33 | 107.7% | 65.8K | 674K | 12.2 | 15.0 | 15.2 | 1.48 | 15.2 | 500 |
| 14 | `Query: Datomic pull projection (4 attrs + nested slice)` | **3.61** | 4.49 ± 1.73 | 38.5% | 115K | 285K | 0.57 | 8.53 | 8.66 | 3.51 | 8.73 | 200 |
| 15 | `Query: diff_moments (1 of 200 entities mutated)` | **224.1** | 224.1 ± 15.8 | 7.0% | 3.8K | 5.1K | 12.6 | 246.8 | 261.3 | 197.7 | 264.9 | 50 |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **10.1** | 13.8 ± 7.55 | 54.8% | 29.4K | 111K | 4.69 | 25.3 | 32.3 | 8.99 | 34.0 | 50 |
| 16 | `Query: Datalog index prefix + join (N=200)` | **30.7** | 30.7 ± 0.79 | 2.6% | 31.0K | 33.8K | 1.16 | 31.9 | 32.2 | 29.6 | 32.3 | 50 |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **9.02** | 71.0 ± 109.4 | 154.1% | 3.8K | 163K | 71.2 | 257.9 | 259.8 | 6.15 | 260.3 | 100 |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **1.35** | 2.09 ± 2.21 | 106.0% | 117K | 769K | 0.06 | 8.52 | 8.57 | 1.30 | 8.58 | 100 |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **141.5** | 141.5 ± 10.1 | 7.2% | 6.5K | 7.7K | 20.1 | 152.3 | 152.8 | 130.3 | 152.9 | 50 |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **201.1** | 203.6 ± 5.92 | 2.9% | 4.5K | 5.0K | 6.91 | 214.2 | 219.3 | 198.3 | 220.5 | 50 |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **5.80** | 5.89 ± 1.23 | 20.8% | 116K | 226K | 2.11 | 7.86 | 8.45 | 4.43 | 8.60 | 20 |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **28.8** | 28.8 ± 0.50 | 1.7% | 32.5K | 35.4K | 0.31 | 29.2 | 30.4 | 28.2 | 30.7 | 50 |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **345.5** | 346.5 ± 6.05 | 1.7% | 2.8K | 2.9K | 11.0 | 354.5 | 355.9 | 339.2 | 356.2 | 50 |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **12.2** | 14.0 ± 3.16 | 22.5% | 49.2K | 86.4K | 4.18 | 19.5 | 20.2 | 11.6 | 20.3 | 50 |


### 2. Raw Odin Baseline Results (`odin run benchmarks -o:speed -microarch:native`, Commit `unknown`, 20 samples across 4 run(s))

#### 2.1 Sub-Microsecond Fast Path (`< 1 µs`, 14 tests)

| # | Benchmark | Med (`ns`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **404** | 414 ± 40.2 | 9.7% | 1.9M | 2.7M | 43 | 511 | 520 | 377 | 522 | 500 |
| 1 | `Access: 3-hop lazy nested lookup (db[users][id][name])` | **472** | 489 ± 93.2 | 19.1% | 1.5M | 2.7M | 121 | 635 | 675 | 377 | 685 | 500 |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **594** | 621 ± 63.9 | 10.3% | 1.3M | 1.8M | 53 | 747 | 763 | 560 | 767 | 500 |
| 3 | `Access: Array_List random index lookup (cursor[idx])` | **90** | 103 ± 40.0 | 38.7% | 5.3M | 13.7M | 24 | 187 | 188 | 73 | 188 | 500 |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **253** | 258 ± 16.5 | 6.4% | 3.1M | 4.1M | 15 | 271 | 309 | 243 | 319 | 500 |
| 4 | `Access: Array_List random index lookup (items[idx])` | **74** | 75 ± 2.8 | 3.8% | 12.7M | 14.1M | 5 | 79 | 79 | 71 | 79 | 500 |
| 4 | `Access: Linked_Array_List random index lookup (cursor[idx])` | **79** | 88 ± 14.0 | 15.9% | 8.1M | 13.2M | 22 | 107 | 121 | 76 | 124 | 500 |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **79** | 80 ± 3.0 | 3.8% | 11.6M | 13.0M | 4 | 86 | 86 | 77 | 86 | 500 |
| 5 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **5** | 5 ± 1.1 | 21.2% | 100M | 250M | 0 | 7 | 9 | 4 | 10 | 1K |
| 6 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **168** | 177 ± 18.7 | 10.6% | 4.3M | 6.4M | 19 | 212 | 227 | 157 | 231 | 1K |
| 8 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **48** | 49 ± 5.2 | 10.6% | 14.5M | 22.7M | 3 | 60 | 66 | 44 | 69 | 500 |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **991** | 986 ± 46.7 | 4.7% | 935K | 1.1M | 63 | 1,043 | 1,064 | 913 | 1,069 | 200 |
| 13 | `Time-Travel: Historical as_of(moment) pinned read` | **523** | 557 ± 125 | 22.5% | 1.1M | 2.1M | 68 | 808 | 858 | 471 | 871 | 500 |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **352** | 370 ± 38.9 | 10.5% | 2.3M | 3.0M | 69 | 434 | 440 | 329 | 442 | 100 |


#### 2.2 Multi-Microsecond Client Operations (`≥ 1 µs`, 16 tests)

| # | Benchmark | Med (`µs`) | Mean ± σ | CV | Min `ops/s` | Max `ops/s` | IQR | `p95` | `p99` | Min | Max | Ops |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 7 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **1.09** | 1.11 ± 0.08 | 6.9% | 752K | 973K | 0.07 | 1.26 | 1.33 | 1.03 | 1.33 | 200 |
| 9 | `Materialize: Eager subtree materialize/1 (user profile)` | **1.75** | 1.77 ± 0.12 | 6.7% | 464K | 630K | 0.14 | 1.96 | 2.12 | 1.59 | 2.15 | 200 |
| 10 | `Tx: Single nested entity transact commit (6 attributes)` | **8.37** | 8.58 ± 1.20 | 13.9% | 73.6K | 134K | 0.48 | 10.8 | 13.1 | 7.44 | 13.6 | 100 |
| 11 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **3.21** | 3.17 ± 0.21 | 6.6% | 252K | 342K | 0.28 | 3.42 | 3.78 | 2.93 | 3.96 | 100 |
| 12 | `Tx: Incremental put_in nested attribute commit` | **2.23** | 2.23 ± 0.13 | 5.8% | 410K | 505K | 0.17 | 2.42 | 2.44 | 1.98 | 2.44 | 100 |
| 14 | `Query: Datomic pull projection (4 attrs + nested slice)` | **1.73** | 1.79 ± 0.12 | 6.8% | 465K | 595K | 0.21 | 2.00 | 2.11 | 1.68 | 2.15 | 200 |
| 15 | `Query: diff_moments (1 of 200 entities mutated)` | **123.6** | 123.6 ± 5.56 | 4.5% | 7.5K | 8.8K | 7.54 | 130.7 | 132.9 | 113.6 | 133.5 | 50 |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **3.20** | 3.25 ± 0.12 | 3.6% | 284K | 320K | 0.18 | 3.44 | 3.51 | 3.13 | 3.53 | 50 |
| 16 | `Query: Datalog index prefix + join (N=200)` | **14.9** | 15.1 ± 0.96 | 6.3% | 57.7K | 71.2K | 0.94 | 16.8 | 17.2 | 14.0 | 17.3 | 50 |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **2.46** | 2.63 ± 0.38 | 14.3% | 265K | 438K | 0.45 | 3.19 | 3.66 | 2.28 | 3.78 | 100 |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **42.2** | 42.4 ± 1.41 | 3.3% | 22.3K | 25.0K | 1.82 | 44.6 | 44.8 | 40.0 | 44.8 | 50 |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **119.7** | 122.4 ± 5.59 | 4.6% | 7.4K | 8.5K | 2.27 | 134.1 | 134.3 | 118.1 | 134.4 | 50 |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **1.76** | 1.77 ± 0.04 | 2.2% | 533K | 581K | 0.04 | 1.85 | 1.87 | 1.72 | 1.88 | 20 |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **14.7** | 15.6 ± 2.83 | 18.1% | 41.6K | 73.0K | 0.49 | 23.7 | 24.0 | 13.7 | 24.0 | 50 |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **276.3** | 278.8 ± 6.66 | 2.4% | 3.4K | 3.7K | 8.41 | 291.9 | 292.4 | 270.7 | 292.6 | 50 |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **5.32** | 5.51 ± 0.50 | 9.1% | 140K | 194K | 0.18 | 6.53 | 7.03 | 5.16 | 7.16 | 50 |

### 3. 1v1 Client Boundary Comparison (Elixir NIF Wrapper vs. Raw Odin, Commit `unknown`)

#### 3.1 Sub-Microsecond Fast Path (`ns`, 8 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`ns`) | Elixir Med (`ns`) | Welch $z$ | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 3 | `Access: Array_List random index lookup (cursor[idx])` | **2.67x** | 90 | **240** | `3.0` ★ | 103 ± 40.0 | 38.7% | 1,063 ± 1,222 | 114.9% |
| 3 | `Access: Sorted_Map B+Tree key lookup (sorted[key])` | **1.48x** | 253 | **374** | `27.7` ★ | 258 ± 16.5 | 6.4% | 373 ± 8.5 | 2.3% |
| 4 | `Access: Array_List random index lookup (items[idx])` | **2.86x** | 74 | **212** | `120.2` ★ | 75 ± 2.8 | 3.8% | 212 ± 4.2 | 2.0% |
| 4 | `Access: Linked_Array_List random index lookup (cursor[idx])` | **3.22x** | 79 | **254** | `3.1` ★ | 88 ± 14.0 | 15.9% | 1,053 ± 1,192 | 113.2% |
| 5 | `Access: Linked_Array_List random index lookup (linked[idx])` | **2.89x** | 79 | **228** | `88.9` ★ | 80 ± 3.0 | 3.8% | 229 ± 6.9 | 3.0% |
| 5 | `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)` | **24.20x** | 5 | **121** | `43.6` ★ | 5 ± 1.1 | 21.2% | 128 ± 16.6 | 13.0% |
| 6 | `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)` | **2.61x** | 168 | **438** | `17.4` ★ | 177 ± 18.7 | 10.6% | 491 ± 105 | 21.5% |
| 8 | `Enum: Full Enum.to_list/1 stream over Array_List (N=500)` | **2.58x** | 48 | **124** | `15.3` ★ | 49 ± 5.2 | 10.6% | 129 ± 30.8 | 23.8% |


#### 3.2 Multi-Microsecond Client Operations (`µs`, 22 tests)

| # | Benchmark | NIF Ratio | Raw Odin Med (`µs`) | Elixir Med (`µs`) | Welch $z$ | Odin Mean ± σ | Odin CV | Elixir Mean ± σ | Elixir CV |
| ---: | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | `Access: 3-hop lazy HAMT lookup (root[users][id][name])` | **3.29x** | 0.40 | **1.33** | `37.8` ★ | 0.41 ± 0.04 | 9.7% | 1.35 ± 0.10 | 7.6% |
| 1 | `Access: 3-hop lazy nested lookup (db[users][id][name])` | **3.92x** | 0.47 | **1.85** | `3.4` ★ | 0.49 ± 0.09 | 19.1% | 5.93 ± 6.28 | 105.8% |
| 2 | `Access: Single-call selector select(.users.<id>.name)` | **2.45x** | 0.59 | **1.45** | `12.3` ★ | 0.62 ± 0.06 | 10.3% | 1.69 ± 0.51 | 30.2% |
| 7 | `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)` | **2.02x** | 1.09 | **2.19** | `32.0` ★ | 1.11 ± 0.08 | 6.9% | 2.20 ± 0.19 | 8.4% |
| 9 | `Materialize: Eager subtree materialize/1 (user profile)` | **1.31x** | 1.75 | **2.30** | `10.1` ★ | 1.77 ± 0.12 | 6.7% | 2.40 ± 0.35 | 14.6% |
| 9 | `Stream: Lazy Stream.take(10) early-halt on Sorted_Map` | **4.31x** | 0.99 | **4.27** | `13.5` ★ | 0.99 ± 0.05 | 4.7% | 4.22 ± 1.07 | 25.4% |
| 10 | `Tx: Single nested entity transact commit (6 attributes)` | **3.47x** | 8.37 | **29.1** | `34.5` ★ | 8.58 ± 1.20 | 13.9% | 31.1 ± 3.66 | 11.8% |
| 11 | `Tx: Bulk batch transact (100 entities in 1 commit)` | **3.71x** | 3.21 | **11.9** | `46.3` ★ | 3.17 ± 0.21 | 6.6% | 12.2 ± 1.14 | 9.3% |
| 12 | `Tx: Incremental put_in nested attribute commit` | **9.83x** | 2.23 | **21.9** | `17.5` ★ | 2.23 ± 0.13 | 5.8% | 20.4 ± 6.14 | 30.1% |
| 13 | `Time-Travel: Historical as_of(moment) pinned read` | **2.96x** | 0.52 | **1.55** | `3.3` ★ | 0.56 ± 0.13 | 22.5% | 5.88 ± 6.33 | 107.7% |
| 14 | `Query: Datomic pull projection (4 attrs + nested slice)` | **2.08x** | 1.73 | **3.61** | `9.2` ★ | 1.79 ± 0.12 | 6.8% | 4.49 ± 1.73 | 38.5% |
| 15 | `Query: diff_moments (1 of 200 entities mutated)` | **1.81x** | 123.6 | **224.1** | `23.3` ★ | 123.6 ± 5.56 | 4.5% | 224.1 ± 15.8 | 7.0% |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | **3.16x** | 3.20 | **10.1** | `6.2` ★ | 3.25 ± 0.12 | 3.6% | 13.8 ± 7.55 | 54.8% |
| 16 | `Query: Datalog index prefix + join (N=200)` | **2.05x** | 14.9 | **30.7** | `48.3` ★ | 15.1 ± 0.96 | 6.3% | 30.7 ± 0.79 | 2.6% |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | **3.66x** | 2.46 | **9.02** | `2.8` ★ | 2.63 ± 0.38 | 14.3% | 71.0 ± 109.4 | 154.1% |
| 17 | `Time-Travel: Historical as_of(db, m) across 100 moments` | **3.83x** | 0.35 | **1.35** | `3.5` ★ | 0.37 ± 0.04 | 10.5% | 2.09 ± 2.21 | 106.0% |
| 18 | `Time-Travel: history_of(db, selector) (100 moments)` | **3.35x** | 42.2 | **141.5** | `43.3` ★ | 42.4 ± 1.41 | 3.3% | 141.5 ± 10.1 | 7.2% |
| 19 | `Time-Travel: diff_moments (1 of 200 entities mutated)` | **1.68x** | 119.7 | **201.1** | `44.6` ★ | 122.4 ± 5.59 | 4.6% | 203.6 ± 5.92 | 2.9% |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | **3.29x** | 1.76 | **5.80** | `15.0` ★ | 1.77 ± 0.04 | 2.2% | 5.89 ± 1.23 | 20.8% |
| 22 | `Query: Datalog B+Tree index prefix + join (N=200)` | **1.95x** | 14.7 | **28.8** | `20.5` ★ | 15.6 ± 2.83 | 18.1% | 28.8 ± 0.50 | 1.7% |
| 23 | `Query: Datalog grouped aggregation (count + sum, N=200)` | **1.25x** | 276.3 | **345.5** | `33.6` ★ | 278.8 ± 6.66 | 2.4% | 346.5 ± 6.05 | 1.7% |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | **2.29x** | 5.32 | **12.2** | `11.9` ★ | 5.51 ± 0.50 | 9.1% | 14.0 ± 3.16 | 22.5% |

### 4. Database Storage Footprint (`bytes_used > 0`)

| # | Benchmark | Ops | Raw Odin Size | Elixir Wrapper Size |
| ---: | :--- | ---: | ---: | ---: |
| 10 | `Tx: Single nested entity transact commit (6 attributes)` | 100 | 128.3 KB | 128.3 KB |
| 11 | `Tx: Bulk batch transact (100 entities in 1 commit)` | 100 | 33.5 KB | 33.5 KB |
| 12 | `Tx: Incremental put_in nested attribute commit` | 100 | 85.3 KB | 85.3 KB |
| 15 | `Tx: Linked_Array_List O(log N) mid-list insert + delete` | 50 | 69.7 KB | 69.7 KB |
| 16 | `Tx: O(1) zero-copy subtree fork (500 entities)` | 100 | 737.3 KB | 731.5 KB |
| 20 | `Lifecycle: compact/1 100-moment database deduplication` | 20 | 1.0 KB | 1.0 KB |
| 24 | `Storage: Buffered_File transact + sync (50 commits)` | 50 | 38.5 KB | 38.5 KB |
<!-- END_BENCHMARK_TABLE -->
