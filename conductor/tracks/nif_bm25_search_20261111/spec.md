# Specification: Track 9 [Wave 3] — Native Odin NIF BM25 Pushdown & Direct B+Tree Prefix Seek (with Wave 3 Track 11B Nesting Integration)

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `nif_bm25_search_20261111`
> - **Wave:** `Wave 3 — Deferred Native Search Pushdown & Physical Document Nesting` ([`../../tracks.md`](../../tracks.md))
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules & Native Files:** `native/nif_entry.c`, `native/xitdb_nif.odin`, `lib/xitdb/nif.ex`, `lib/xitdb/ash/search.ex`, `test/xitdb/ash/search_nif_test.exs`
> - **Reference Implementation & Track 11B Execution Guide:** [`./reference.md`](./reference.md)
> - **Implementation Plan:** [`./plan.md`](./plan.md)
> - **Artifact Scope Note:** These Conductor track files constitute a **docs-only planning & reference specification**. No production source files under `lib/`, `native/`, `test/`, or `benchmarks/` are modified during planning; code changes execute during Wave 3 implementation.

---

## 1. Wave 3 Scope, Goal & Architectural Motivation

### 1.1 Wave 3 Dual-Track Composition (`Track 9` + `Track 11B`)

Per [`conductor/tracks.md`](../../tracks.md), **Wave 3** (`Deferred Native Search Pushdown & Physical Document Nesting`) executes immediately after the Wave 2 MVP `AshPostgres` + `Xitdb.Ash.DataLayer` cutover gate and comprises two post-cutover tracks:

1. **Track 9 (`nif_bm25_search_20261111` — This Directory):**
   Drop-in hot-path Odin NIF acceleration (`nif_sorted_map_seek/5` and `nif_bm25_search/7`) behind `Xitdb.Ash.Search`, requiring zero Ash resource DSL or storage-layout changes.
2. **Track 11B (`nested_in` Physical Subtree Nesting — Shared Track Directory):**
   Physical document-subtree storage (`root[parent_col][parent_id][path]`), `idx.<col>._parent` primary-key locators, `fetch_nested_cursor/6`, `nested_cursors_for_parent/3`, foreign-key reparenting, recursive child index purging (`purge_nested_children/4`, including `Xitdb.Ash.Search.remove_record/3`), `Xitdb.Ash.Store` implicit `nested_in` `:delete` reverse-FK synthesis, `Xitdb.Ash.Query` Stage 1 parent-jump planning, `Xitdb.Ash.Mutator` nested cascade checks, and nested `data_layer_test.exs` verification.
   Because split tracks `11A` (Wave 2 flat `Codec`/`Indexer`) and `11B` (Wave 3 physical nesting) share [`../ash_codec_and_indexer_20261111/`](../ash_codec_and_indexer_20261111/index.md) (and cross-reference [`../ash_store_and_test_sandbox_20261111/reference.md`](../ash_store_and_test_sandbox_20261111/reference.md), [`../ash_query_engine_20261111/reference.md`](../ash_query_engine_20261111/reference.md), [`../ash_mutator_and_cascades_20261111/reference.md`](../ash_mutator_and_cascades_20261111/reference.md), and [`../ash_datalayer_and_verification_suite_20261111/references/ash3_contract_fixes_and_verification_suite.md`](../ash_datalayer_and_verification_suite_20261111/references/ash3_contract_fixes_and_verification_suite.md)) to avoid duplicating shared track directories, [`./plan.md`](./plan.md) (Phase 4) and [`./reference.md`](./reference.md) (Section 6) provide the consolidated Wave 3 Track 11B execution checklist so nothing in Wave 3 is omitted.

### 1.2 Native Search Motivation & Accurate Backend Terminology

`Xitdb` always requires `priv/xitdb_nif.so` at runtime for Wave 0 database and slot primitives (`nif_open/3`, `nif_moment_slot/2`, `nif_slot_get_key/4`, `nif_slot_entries/5`, `nif_transact/4`); there is no "non-NIF Xitdb sandbox."

In the Wave 2 baseline (`lib/xitdb/ash/search.ex`), the `:elixir` search backend executes BM25 scoring in Elixir **atop Wave 0 cursor/slot NIF primitives**:
- Prefix expansion runs a binary search (`O(log V)` separate `NIF.nif_slot_entries/5` calls) over the `"terms"` `:sorted_map`, then materializes each matched posting map across the NIF boundary into BEAM heap terms.
- On large corpora (`100,000+` distinct terms and wide posting maps), copying posting maps and reading per-candidate document lengths from Elixir incurs significant Erlang term allocation and NIF boundary traffic.

Wave 3 Track 9 pushes B+Tree prefix seeking and BM25 candidate scoring into Odin (`native/xitdb_nif.odin`) on Dirty CPU schedulers while preserving the cursor-backed `:elixir` backend behind `backend: :auto | :nif | :elixir`:

1. **Direct B+Tree String Prefix Seek (`Xitdb.NIF.nif_sorted_map_seek/5`):**
   Wraps `xitdb.sorted_map_iterator_from_string` (`native/xitdb-odin/xitdb/collections.odin`), eliminating `O(log V)` rank binary-search round-trips over `nif_slot_entries/5` and returning lazy 9-byte cursor coordinates (`slot_tuple`) plus a pagination lookahead cursor (`next_cursor_or_nil`) without eagerly materializing multi-kilobyte posting maps.
2. **Snapshot-Isolated Native Odin BM25 Pushdown (`Xitdb.NIF.nif_bm25_search/7`):**
   Resolves the caller's exact MVCC snapshot root cursor `(root_tag_id, root_val_int)` (supporting `Xitdb.db/1`, `Xitdb.as_of/2`, and `Xitdb.Ash.TestSandbox` CoW handles), traverses `"idx" -> "search" -> collection`, aggregates exact and bounded prefix postings inside a scoped per-call `mem.Dynamic_Arena`, computes Robertson–Spärck Jones IDF and Okapi BM25 scores in `f64`, maintains a bounded `O(C log K)` Top-K binary min-heap, and emits only the Top-K `{doc_key_bin, score_float}` tuples to the BEAM.
3. **Selectable Backend & 1v1 Differential Verification (`backend: :auto | :nif | :elixir`):**
   Exposes `backend: :auto | :nif | :elixir` (default `:auto`) on `Xitdb.Ash.Search.query/3` and `Xitdb.Ash.Search.ids/3` so `StreamData` differential property tests and `1v1` benchmarks (`benchmarks/compare_1v1.py`) can execute `:elixir` and `:nif` side-by-side against the exact same `%Xitdb{}` snapshot in a single BEAM node.

---

## 2. NIF API Contracts & Snapshot Isolation

### 2.1 Direct B+Tree String Prefix Seek (`nif_sorted_map_seek/5`)

- **Elixir Stub (`lib/xitdb/nif.ex` — Arity 5):**
  ```elixir
  def nif_sorted_map_seek(_db_ref, _slot_tag_id, _slot_val_int, _prefix_bin, _limit_int),
    do: :erlang.nif_error(:nif_not_loaded)
  ```
- **C-ABI Registration (`native/nif_entry.c` — Arity 5, Dirty CPU):**
  ```c
  {"nif_sorted_map_seek", 5, odin_nif_sorted_map_seek, ERL_NIF_DIRTY_JOB_CPU_BOUND}
  ```
- **Odin Signature (`native/xitdb_nif.odin`):**
  ```odin
  @(export)
  odin_nif_sorted_map_seek :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM
  // argv[0]: db_ref       (ErlNifResource Db_Handle)
  // argv[1]: slot_tag_id  (i64; must be Tag.Sorted_Map == 14 or Tag.None == 0)
  // argv[2]: slot_val_int (i64; 9-byte B+Tree root slot offset)
  // argv[3]: prefix_bin   (UTF-8 binary inspected via enif_inspect_binary)
  // argv[4]: limit_int    (i64; maximum entries to return)
  ```
- **Return Contract:**
  ```elixir
  {:ok, [{term_bin :: binary(), slot_tuple :: tuple() | term()}, ...], next_cursor_or_nil :: binary() | nil}
  | {:error, reason :: atom() | binary()}
  ```
  - When `slot_val_int == 0`, `slot_tag_id == 0` (`Tag.None`), or `limit_int <= 0`, immediately returns `{:ok, [], nil}`.
  - For each matched B+Tree entry whose UTF-8 key `term_bin` satisfies `strings.has_prefix(term_str, prefix)` (up to `limit_int` entries), emits `{term_bin, slot_tuple}` where `slot_tuple` is produced by `slot_to_term(env, &handle.db, val_slot)` — i.e., `{:cursor, :hash_map, tag_id, slot_val, full_int}` for posting container maps. Wrapping `slot_tuple` into `%Xitdb.Cursor{}` via `Xitdb.Cursor.from_nif_tuple/3` on the Elixir side avoids copying multi-kilobyte posting maps across the NIF boundary unless inspected.
  - **Lookahead Continuation Cursor (`next_cursor_or_nil`):** After emitting `limit_int` entries, advances the iterator by one lookahead step. If the next key still satisfies `strings.has_prefix(next_key, prefix)`, returns `next_key` as a UTF-8 binary so callers can resume or detect prefix truncation; otherwise returns `nil` (`ATOM_NIL`).

### 2.2 Snapshot-Isolated Native BM25 Pushdown (`nif_bm25_search/7`)

- **Elixir Stub (`lib/xitdb/nif.ex` — Arity 7):**
  ```elixir
  def nif_bm25_search(
        _db_ref,
        _root_tag_id,
        _root_val_int,
        _collection_bin,
        _query_terms,
        _limit_int,
        _opts_map
      ),
      do: :erlang.nif_error(:nif_not_loaded)
  ```
- **C-ABI Registration (`native/nif_entry.c` — Arity 7, Dirty CPU):**
  ```c
  {"nif_bm25_search", 7, odin_nif_bm25_search, ERL_NIF_DIRTY_JOB_CPU_BOUND}
  ```
- **Odin Signature (`native/xitdb_nif.odin`):**
  ```odin
  @(export)
  odin_nif_bm25_search :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM
  // argv[0]: db_ref         (ErlNifResource Db_Handle)
  // argv[1]: root_tag_id    (i64; -1 for lazy moment index, or Tag.Hash_Map == 4 for resolved root slot)
  // argv[2]: root_val_int   (i64; moment index when root_tag_id == -1, or root slot offset)
  // argv[3]: collection_bin (UTF-8 binary collection name, e.g. "organizations")
  // argv[4]: query_terms    (list of deduplicated lowercase UTF-8 binary tokens)
  // argv[5]: limit_int      (i64; Top-K cap)
  // argv[6]: opts_map       (Erlang map decoded via enif_get_map_value)
  ```
- **MVCC Snapshot & `TestSandbox` Isolation:**
  Passing `(db_ref, root_tag_id, root_val_int)` directly from `%Xitdb.Cursor{db_ref: db_ref, tag_id: root_tag_id, value: root_val_int} = Storage.root_cursor(db)` ensures `nif_bm25_search/7` never reads the mutable head when evaluating `Xitdb.as_of(db, moment)` historical cursors, nested savepoints, or isolated `Xitdb.Ash.TestSandbox` CoW checkouts.
- **`opts_map` Keys & Defaults (Read via `enif_get_map_value`):**
  | Map Key (Atom) | Type | Default | Description |
  | :--- | :--- | :--- | :--- |
  | `:match` | `:all \| :any` | `:all` | Conjunctive (`:all`) vs. disjunctive (`:any`) candidate set resolution. |
  | `:prefix` | `boolean()` | `true` | Enables B+Tree prefix expansion for tokens with codepoint length `>= :min_prefix_length`. |
  | `:min_prefix_length` | `pos_integer()` | `3` | Minimum Unicode codepoint count (`utf8.rune_count_in_string`) required for prefix scan. |
  | `:max_prefix_expansions` | `pos_integer()` | `64` | Maximum B+Tree terms scanned per prefix-eligible query token. |
  | `:k1` | `float()` | `1.2` | Okapi BM25 term-frequency saturation parameter (`>= 0.0`). |
  | `:b` | `float()` | `0.75` | Robertson document-length normalization parameter (`0.0..1.0`). |
  | `:exact_boost` | `float()` | `1.25` | Term-frequency multiplier applied when `matched_term == query_token`. |
  | `:prefix_weight` | `float()` | `1.0` | Term-frequency multiplier applied when `matched_term != query_token` during prefix scan. |
- **Return Contract:**
  ```elixir
  {:ok, [{doc_key_bin :: binary(), score :: float()}, ...]} | {:error, reason :: atom() | binary()}
  ```
  `Xitdb.Ash.Search` decodes each `doc_key_bin` into `:integer` (`String.to_integer/1`) or `:string` according to the resource's primary-key attribute type.

---

## 3. Storage Layout & Exact BM25 Scoring Invariants

### 3.1 Canonical Slot Tree Layout (`root["idx"]["search"][collection]`)

All search state lives under top-level root map key `"idx"` -> `"search"` -> `collection_name` (selector syntax `".idx.search.<collection>"`; raw map keys have **no** leading dot), matching `Xitdb.Ash.Search.Storage` (`lib/xitdb/ash/search.ex`) 100%:

```text
root (:hash_map)
└── "idx" (:hash_map)
    └── "search" (:hash_map)
        └── <collection> (:hash_map, e.g. "organizations")
            ├── "meta"  (:hash_map)
            │   ├── "doc_count" => uint64 / int64  (N: count of indexed documents with len > 0)
            │   └── "total_len" => uint64 / int64  (sum of scaled document lengths, weight_scale = 100)
            ├── "docs"  (:hash_map)
            │   └── <doc_key> (:hash_map, UTF-8 string PK, e.g. "42" or UUID)
            │       ├── "len"   => uint64 / int64  (scaled document length dl * 100)
            │       └── "terms" => (:hash_map: <term> => scaled_weight, used for write-time diffing)
            └── "terms" (:sorted_map B+Tree)
                └── <term> (:hash_map, UTF-8 lowercase token)
                    └── <doc_key> => uint64 / int64 (scaled term frequency tf * 100)
```

- **Fixed-Point Weight Scale (`BM25_WEIGHT_SCALE = 100.0`):**
  `Xitdb.Ash.Search.extract_weighted_terms/3` encodes field boosts as integer weights `weight = max(1, round(boost * 100))`. Consequently, `"total_len"`, `docs[doc_key]["len"]`, and `terms[term][doc_key]` are all scaled by `100` and **must** be divided by `100.0` (`BM25_WEIGHT_SCALE`) before computing `tf` saturation `tf / (tf + norm)`.
- **Integer Slot Tag Compatibility (`Tag.Uint` & `Tag.Int`):**
  `odin_nif_transact` (`decode_writeable_value`) stores non-negative Elixir integers as `Tag.Uint`, whereas raw Odin callers may store `Tag.Int`. Odin readers must accept both `.Uint` and `.Int` slots.
- **Per-Document Length (`dl`) Source:**
  Per-document length is stored once per document at `root["idx"]["search"][collection]["docs"][doc_key]["len"]` (not duplicated inside postings). For each candidate `doc_key`, `dl` is fetched via `docs_hm[doc_key]["len"]` and unscaled as `dl = f64(raw_doc_len) / 100.0`.

### 3.2 Empty-Corpus Guards, Robertson–Spärck Jones IDF & Scoring Equations

1. **Immediate Empty-Result Guards:**
   Return `{:ok, []}` immediately (before dividing by `N`) whenever any of the following hold:
   - `query_terms == []` or `limit_int <= 0` or `collection == ""`
   - Snapshot root, `"idx"`, `"search"`, `collection`, `"meta"`, `"docs"`, or `"terms"` slot is absent
   - `N <= 0` (`doc_count <= 0`) or `total_len <= 0`
   - Under `match: :all`, any query token yields an empty merged posting map.
2. **Average Document Length (`avg_dl`):**
   `avg_dl = max((f64(total_len) / 100.0) / f64(N), 1.0e-6)`
   *(Guarded by both `N > 0 && total_len > 0` and `max(..., 1.0e-6)` to match `lib/xitdb/ash/search.ex` identically even when fractional field boosts `< 1.0` produce unscaled lengths `< 1.0`.)*
3. **Virtual-Token Posting Merge:**
   For each unique query token `q_i`:
   - When `prefix == true` and `utf8.rune_count_in_string(q_i) >= min_prefix_length`, iterate up to `max_prefix_expansions` entries `t` from `sorted_map_iterator_from_string(terms_sm, q_i)` while `strings.has_prefix(t, q_i)`. Because `q_i` is the lexicographically smallest string with prefix `q_i` in unsigned UTF-8 byte order, an exact entry `t == q_i` (if present) is visited first with multiplier `exact_boost`, while prefix expansions `t != q_i` use `prefix_weight`, summing `tf(q_i, d) += (f64(scaled_tf) / 100.0) * multiplier` into one virtual posting map `P_i` per query token (preventing morphological variants from double-counting IDF).
   - Otherwise, look up `q_i` directly via `sorted_map_get_cursor(terms_sm, q_i)` with multiplier `exact_boost`.
4. **Non-Negative Robertson–Spärck Jones IDF (`f64` `math.ln`):**
   With `df_i = f64(len(P_i))`:
   `idf_i = ln(1.0 + (f64(N) - df_i + 0.5) / (df_i + 0.5))`
5. **Okapi BM25 Score with Robertson Length Normalization:**
   For each candidate document `d` (`dl = f64(raw_doc_len) / 100.0`):
   `norm = k1 * (1.0 - b + b * (dl / avg_dl))`
   `score(d) = sum over i where P_i[d] > 0.0 of: idf_i * (P_i[d] * (k1 + 1.0)) / (P_i[d] + norm)`

### 3.3 Deterministic Total Order & Tie-Breaking

Top-K selection uses a bounded binary min-heap of capacity `K = limit_int` (`O(C log K)` time, `O(K)` space) followed by `slice.sort_by` on the `<= K` winners using a strict total order:
1. **Primary Key:** **Descending `score` (`f64`)** (`a.score > b.score`). Both Odin and Elixir accumulate token contributions in identical left-to-right query-token order in IEEE-754 double precision.
2. **Secondary Key:** **Ascending `doc_key` raw UTF-8 bytes** (`a.doc_key < b.doc_key` unsigned lexicographical byte comparison).
3. **Elixir Baseline Parity Alignment:** `Xitdb.Ash.Search` sorts `{doc_key, score}` by `{-score, doc_key}` **before** calling `decode_doc_key(doc_key, pk_kind)` so `:integer` primary keys (`"10"` vs `"2"`) tie-break identically across `backend: :elixir` and `backend: :nif`.

---

## 4. BEAM Scheduler, Concurrency & Odin Memory Hygiene

1. **Dirty CPU Scheduler Registration (`ERL_NIF_DIRTY_JOB_CPU_BOUND`):**
   Both `nif_sorted_map_seek/5` and `nif_bm25_search/7` are registered with `ERL_NIF_DIRTY_JOB_CPU_BOUND` in `native/nif_entry.c`'s `ErlNifFunc` table so scanning `100k+` postings and scoring candidates never stalls normal BEAM schedulers past their 1ms preemption slice.
2. **`ErlNifRWLock` Read Synchronization:**
   Both NIFs acquire `nif_rwlock_rlock(handle.rwlock)` and register `defer nif_rwlock_runlock(handle.rwlock)` before reading any `xitdb` cursor or slot, matching every other reader NIF in `native/xitdb_nif.odin` and preventing concurrent `odin_nif_close` / `odin_nif_transact` races.
3. **Scoped Per-Call `mem.Dynamic_Arena` (Zero Leaks & Valgrind TLS-Clean):**
   - *Why `context.temp_allocator` + default `make(map[...])` is insufficient:* Odin's `runtime.Default_Temp_Allocator` retains multi-megabyte backing blocks in `@(thread_local)` storage on each Dirty CPU OS thread across NIF invocations (flagged as retained heap memory under Valgrind), AND Odin's `make(map[...])` / `make([dynamic]...)` default to `context.allocator` (`malloc`), leaking permanently on early error returns unless explicitly freed.
   - *Mandatory Arena Pattern:* Each NIF initializes a stack-scoped `arena: mem.Dynamic_Arena` via `mem.dynamic_arena_init(&arena, block_allocator = runtime.default_allocator(), array_allocator = runtime.default_allocator())` with `defer mem.dynamic_arena_destroy(&arena)`, sets both `context.allocator = arena_alloc` and `context.temp_allocator = arena_alloc`, passes `arena_alloc` explicitly to every `make(map[...], arena_alloc)` and `make([dynamic]..., arena_alloc)`, and clones `.Short_Bytes` keys onto `arena_alloc` (`read_arena_string`) so stack scratch buffers (`sb_buf: [8]u8`) never alias map keys. On return, 100% of temporary blocks are freed directly back to the OS/heap.
4. **Strict UTF-8 Binary Marshaling (`enif_inspect_binary` & `enif_make_new_binary`):**
   `enif_get_string` is **strictly forbidden** (it expects Latin-1 charlists and fails or truncates UTF-8 binaries). Input binaries use zero-copy `enif_inspect_binary` (`nif_inspect_binary`), and output binaries use `enif_make_new_binary` + `memcpy` (`nif_make_binary_slice`).

---

## 5. Acceptance Criteria

1. `Xitdb.NIF.nif_sorted_map_seek/5` seeks directly via `xitdb.sorted_map_iterator_from_string` and returns `{:ok, [{term_bin, slot_tuple}, ...], next_cursor_or_nil}`, where each `slot_tuple` wraps cleanly into a lazy 9-byte `%Xitdb.Cursor{}` without eagerly materializing posting maps.
2. `Xitdb.NIF.nif_bm25_search/7` honors MVCC snapshot coordinates `(root_tag_id, root_val_int)` across `Xitdb.db/1`, `Xitdb.as_of/2`, and `Xitdb.Ash.TestSandbox`, producing identical document rank order (including raw UTF-8 `doc_key` tie-breaking) and scores within `< 1.0e-5` of `backend: :elixir` across `:all`/`:any` modes, exact/prefix boosts, prefix caps, and multibyte UTF-8 corpora.
3. `Xitdb.Ash.Search.query/3` and `Xitdb.Ash.Search.ids/3` support `backend: :auto | :nif | :elixir` (default `:auto`), enabling side-by-side differential `StreamData` property tests and `1v1` benchmarks in the same BEAM node.
4. Both NIFs execute on `ERL_NIF_DIRTY_JOB_CPU_BOUND` under `nif_rwlock_rlock` and release 100% of dynamic allocations via `mem.Dynamic_Arena` with zero leaks or retained TLS blocks under Valgrind.
5. Wave 3 Track 11B physical `nested_in` subtree storage, reparenting, parent-jump queries, and recursive child index purging (including nested child BM25 cleanup) pass all integration tests alongside Track 9, and `odin check native -no-entry-point -collection:xitdb=native/xitdb-odin/xitdb` + `mix precommit` pass with zero warnings.
