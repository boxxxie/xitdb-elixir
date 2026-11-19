# Implementation Plan: Parquet-Style Columnar & Transparent Blob Compression for `xitdb`

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `parquet_email_body_compression_20261119`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (Red-first 4-layer ATDD loop, Odin NIF `temp_allocator` hygiene, `odin check`, and `mix precommit` verification gates).

---

## Phase 1: Wire-Safe Value Codecs, Shared Dictionaries & Content-Addressed Interning

- [ ] Task: Design & implement `Xitdb.Compression` codec framing and bounds validation (TDD)
    - [ ] Write failing unit & `StreamData` property tests verifying lossless round-trips for UTF-8 strings, arbitrary binary blobs, empty binaries, small strings below `min_bytes` (staying uncompressed), incompressible random bytes (falling back to uncompressed), and corrupt/oversized header rejection (`max_decompressed_bytes`), mirroring negative tests in `/home/pauli/projects/odin/hugi/tests/codec_test.odin`
    - [ ] Implement `Xitdb.Compression` (`lib/xitdb/compression.ex`) using OTP 28+ built-in `:zstd` (with `cdict`/`ddict` dictionary support when `Code.ensure_loaded?(:zstd)`) & `:zlib`, plus Odin `vendor:zlib` / `core:compress/zlib` codec framing (modeled on `/home/pauli/projects/odin/hugi/store/codec.odin` `compress_bytes_zlib`/`decompress_bytes_zlib` shrink-only + `raw_len` bounds guards) for `"cz"` (`:zlib`), `"zs"` (`:zstd`), and `"zd"` (dictionary-assisted)
    - [ ] Implement `Xitdb.Compression.Dictionary` (`train_dictionary/2`, `__dicts/<name>` immutable persistence and lookup caching)
- [ ] Task: Wire transparent encoding/decoding into `mix.exs`, `native/nif_entry.c`, `native/xitdb_nif.odin`, `Xitdb.TxCompiler`, `Xitdb.Cursor`, `Xitdb.Pull`, and `Xitdb.Selector` (TDD)
    - [ ] Write failing 4-layer ATDD scenarios (`test/features/compression_spec.exs`) testing `Access` (`db["emails"][id]["body"]`), `Xitdb.select/2`, `Xitdb.pull/3`, `Xitdb.materialize/1`, and `raw_tagged: true` inspection
    - [ ] Update `Mix.Tasks.Compile.OdinNif` (`mix.exs`, linking `-lz` if using `vendor:zlib`), `native/xitdb_nif.odin` (`slot_to_term`, `pull_value_to_term`, `term_to_tx_value`), and Elixir cursor/compiler paths to encode/decode `"cz"` / `"zs"` / `"zd"` / `"bp"` tags transparently with `defer free_all(context.temp_allocator)`, strict buffer bounds checks, and `ERL_NIF_DIRTY_JOB_CPU_BOUND` scheduler hygiene (`native/nif_entry.c`)
- [ ] Task: Implement content-addressed blob interning (`__blobs` + `"bp"` tag) for exact-duplicate payloads (TDD)
    - [ ] Write failing tests verifying identical `HeaderProperties` / boilerplate email bodies across 1,000+ rows store a single entry in `__blobs` and deduplicate disk usage across transactions
    - [ ] Implement batched `__blobs` resolution in `Xitdb.TxCompiler` / `transact_ops` and transparent dereferencing on read
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Transparent Value Codecs & Blob Interning' (Protocol in workflow.md)

---

## Phase 2: Parquet-Style Row-Group Columnar Chunks (`Xitdb.Columnar`)

- [ ] Task: Design & implement immutable Row-Group Column Page format (`Xitdb.Columnar.Page`) (TDD)
    - [ ] Write failing unit & property tests covering `:plain_block`, `:dict_rle` (dictionary + run-length encoding for low/medium-cardinality columns like `HeaderProperties` and `Preview`), and `:dict_block` (cross-row compressed HTML `Body` / `HtmlEditBody` pages of `row_group_size` rows)
    - [ ] Implement `Xitdb.Columnar.Page` (`encode_page/2`, `decode_row/3`, `decode_page/2`) using varint/zigzag offset tables, `_Symbol_Table`-style string interning (`/home/pauli/projects/odin/hugi/store/catalog.odin`), and `CZCH\x02`/Parquet-style cold column chunk packing (`/home/pauli/projects/odin/hugi/store/format.odin`, `/home/pauli/projects/odin/hugi/store/parquet.odin`) for fast single-row slicing and bounded memory usage
- [ ] Task: Integrate `Xitdb.Columnar` chunk writes, single-page random reads, and LRU read caching (TDD)
    - [ ] Write failing 4-layer ATDD scenarios verifying bulk chunk ingestion (`Xitdb.Columnar.put_rows/4`), random single-row lookup (`db["activities"][id]["body"]` decompresses only 1 page), projection omitting compressed columns (0 page reads/decompressions), and single-row update immutability (`as_of/2` preserves original row-group page)
    - [ ] Implement `Xitdb.Columnar` (`lib/xitdb/columnar.ex`) storing pages under `<collection>.__col_pages/<field>/<page_id>`, writing compact `"pg"` page-slot pointers in row maps, and adding an optional bounded ETS/process page cache for sequential scans
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Parquet-Style Row-Group Columnar Chunks' (Protocol in workflow.md)

---

## Phase 3: `Xitdb.Ash.DataLayer`, BM25 Search, `diff_moments/3` & `compact/2` Integration

- [ ] Task: Add declarative compression configuration to `Xitdb.Ash.Dsl`, `Mutator`, `Query`, and `Search` (TDD)
    - [ ] Write failing Ash DataLayer tests for a resource with `compress [:body, :html_edit_body, :header_properties], mode: :row_group, row_group_size: 128, dictionary: :email_html` covering `Ash.create!`, `Ash.bulk_create!`, `Ash.update!`, `Ash.get!`, `Ash.read!` with `select:` omitting compressed fields, and `Xitdb.Ash.Search` BM25 queries over compressed bodies
    - [ ] Extend `Xitdb.Ash.Dsl` Spark schema & `BuildIndexPlan`, wire compression into `Xitdb.Ash.Mutator` (`create`, `bulk_create`, `update`) after BM25 tokenization, and wire lazy column decoding into `Xitdb.Ash.Query`
- [ ] Task: Support compression in `Xitdb.diff_moments/3` and garbage-collecting `Xitdb.compact/2` (TDD)
    - [ ] Write failing tests verifying `diff_moments/3` compares logical values cleanly (fast-skipping identical compressed/interned slots) and `compact/2` retains only reachable `__blobs`, `__dicts`, and `__col_pages` for kept moments without re-inflating compressed payloads
    - [ ] Update `Xitdb.diff_moments/3` and `Xitdb.compact/2` (and `compact_replicate.odin` if needed) to preserve `format_tag` compression and prune unreachable columnar/blob artifacts
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Ash DataLayer, Search, Diff & Compaction' (Protocol in workflow.md)

---

## Phase 4: Benchmarks, Fuzzing, Documentation & Quality Gate

- [ ] Task: Add realistic email-corpus compression & throughput benchmark (`benchmarks/bench_compression.exs`)
    - [ ] Benchmark 50k+ simulated CRM email rows (HTML templates, signatures, `HeaderProperties`, `Preview`, `Body`, `HtmlEditBody`) comparing raw `Tag.Bytes` vs `:zlib` vs `:dict` vs `:row_group` (`>= 4x–10x` file size reduction, bulk ingest throughput, point-read p95, and zero-cost metadata `select`)
    - [ ] Run `./benchmarks/compare_1v1.py --runs 5 --warmup 1` to verify zero regression on uncompressed core operations
- [ ] Task: Add `ExFuzz` corrupt-compression-tag & truncated-page fuzz tests (if `ex_fuzz` track is active) and `docs/` documentation
    - [ ] Document `Xitdb.Compression`, `Xitdb.Columnar`, and Ash `compress` options in `docs/time-travel-and-storage.md`, `docs/ash-and-spark.md`, and `usage-rules.md`
    - [ ] Run `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb` and `mix precommit`, confirming 0 warnings and 0 failures
- [ ] Task: Conductor - User Manual Verification 'Phase 4: Benchmarks, Documentation & Quality Gate' (Protocol in workflow.md)
