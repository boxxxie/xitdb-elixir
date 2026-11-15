# #26: `Search: BM25 corpus search (N=200, 2-term prefix, limit=10)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#26 (Pull Projections, Datalog Engine, Buffered Sync & Search)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 252.40 µs (252401.0 ns) | 161.11 µs (161109.0 ns) | **`1.57x`** NIF Ratio |
| **Mean ± σ (CV)** | 253.51 µs ± 2.79 µs (1.1%) | 161.60 µs ± 1.28 µs (0.8%) | Welch `z` = `66.96` |
| **p95 / Max (`ns/op`)** | 257.29 µs / 258.04 µs | 163.33 µs / 163.88 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L471-L487`](../bench_elixir.exs#L471-L487))

```elixir
      {26, "Search: BM25 corpus search (N=200, 2-term prefix, limit=10)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _hits} =
             Xitdb.NIF.nif_bm25_search(
               search_db.db_ref,
               search_root.tag_id,
               search_root.value,
               "articles",
               ["nord", "cap"],
               10,
               bm25_opts
             )
         end

         0
       end}
```

### Raw Odin Harness ([`bench_client.odin#L1308-L1336`](../bench_client.odin#L1308-L1336))

```odin
	// #26: Search: BM25 corpus search (N=200, 2-term prefix, limit=10)
	search_core: xitdb.Core
	search_db: xitdb.Database
	defer if need_search_db {
		xitdb.core_destroy(&search_core)
	}
	if need_search_db {
		search_core = xitdb.core_memory_init()
		search_db, _ = xitdb.database_init(&search_core, xitdb.sha1_hasher())
		seed_bm25_fixture_db(&search_db, 200)
	}
	if r26 {
		s_rc := xitdb.database_root_cursor(&search_db).read_cursor
		s_hist, _ := xitdb.read_array_list_init(s_rc)
		s_m0_cur, _ := xitdb.array_list_get_cursor(s_hist, 0)
		s_m0_map, _ := xitdb.read_hash_map_init(s_m0_cur.?)
		bm25_q := [2]string{"nord", "cap"}
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				_ = bench_raw_bm25_search(s_m0_map, "articles", bm25_q[:], 10)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(26, "Search: BM25 corpus search (N=200, 2-term prefix, limit=10)", 50, samples)
	}
```

<details>
<summary>Raw Odin BM25 Helper <code>bench_raw_bm25_search</code> (<a href="../bench_client.odin#L540-L675">bench_client.odin#L540-L675</a>)</summary>

```odin
bench_raw_bm25_search :: proc(root_map: xitdb.Read_Hash_Map, collection: string, query_terms: []string, k_limit: int, allocator := context.temp_allocator) -> []Bench_BM25_Hit {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(
		&arena,
		block_allocator = runtime.default_allocator(),
		array_allocator = runtime.default_allocator(),
	)
	defer mem.dynamic_arena_destroy(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)

	idx_c, _ := xitdb.hash_map_get_cursor(root_map, "idx")
	idx_m, _ := xitdb.read_hash_map_init(idx_c.?)
	search_c, _ := xitdb.hash_map_get_cursor(idx_m, "search")
	search_m, _ := xitdb.read_hash_map_init(search_c.?)
	col_c, _ := xitdb.hash_map_get_cursor(search_m, collection)
	col_m, _ := xitdb.read_hash_map_init(col_c.?)

	meta_c, _ := xitdb.hash_map_get_cursor(col_m, "meta")
	meta_m, _ := xitdb.read_hash_map_init(meta_c.?)
	doc_count := bench_read_nonneg_int(meta_m, "doc_count")
	total_len := bench_read_nonneg_int(meta_m, "total_len")

	docs_c, _ := xitdb.hash_map_get_cursor(col_m, "docs")
	docs_m, _ := xitdb.read_hash_map_init(docs_c.?)
	terms_c, _ := xitdb.hash_map_get_cursor(col_m, "terms")
	terms_sm, _ := xitdb.read_sorted_map_init(terms_c.?)

	num_tokens := len(query_terms)
	token_postings := make([]map[string]f64, num_tokens, alloc)
	idfs := make([]f64, num_tokens, alloc)
	sb_buf: [8]u8 = ---

	for q_tok, tok_idx in query_terms {
		merged := make(map[string]f64, 32, alloc)
		if utf8.rune_count_in_string(q_tok) >= 3 {
			it, _ := xitdb.sorted_map_iterator_from_string(terms_sm, q_tok)
			scanned := 0
			for scanned < 64 {
				nm, _ := xitdb.cursor_iterator_next(&it)
				elem_c, has_next := nm.?
				if !has_next {
					break
				}
				kv, _ := xitdb.cursor_read_kv_pair(elem_c, alloc)
				matched := bench_read_arena_string(kv.key_cursor, alloc)
				if !strings.has_prefix(matched, q_tok) {
					break
				}
				mult := 1.25 if matched == q_tok else 1.0
				pit, _ := xitdb.cursor_iterator(kv.value_cursor)
				for {
					pnm, _ := xitdb.cursor_iterator_next(&pit)
					pelem, ph := pnm.?
					if !ph {
						break
					}
					pkv, _ := xitdb.cursor_read_kv_pair(pelem, alloc)
					dk := bench_read_arena_string(pkv.key_cursor, alloc)
					if dk == "__tx" {
						continue
					}
					vsp, _ := xitdb.cursor_resolved(pkv.value_cursor)
					raw_tf: i64 = 0
					if vsp.slot.tag == .Uint {
						u, _ := xitdb.cursor_read_uint(pkv.value_cursor)
						raw_tf = i64(u)
					} else if vsp.slot.tag == .Int {
						iv, _ := xitdb.cursor_read_int(pkv.value_cursor)
						raw_tf = iv
					}
					if raw_tf > 0 {
						tf := (f64(raw_tf) / BENCH_BM25_WEIGHT_SCALE) * mult
						merged[dk] = merged[dk] + tf
					}
				}
				scanned += 1
			}
		} else {
			_ = sb_buf
		}
		df := f64(len(merged))
		idfs[tok_idx] = math.ln(1.0 + (f64(doc_count) - df + 0.5) / (df + 0.5))
		token_postings[tok_idx] = merged
	}

	candidates := make([dynamic]string, 0, 64, alloc)
	smallest_idx := 0
	for i in 1 ..< num_tokens {
		if len(token_postings[i]) < len(token_postings[smallest_idx]) {
			smallest_idx = i
		}
	}
	for dk in token_postings[smallest_idx] {
		in_all := true
		for i in 0 ..< num_tokens {
			if i != smallest_idx && dk not_in token_postings[i] {
				in_all = false
				break
			}
		}
		if in_all {
			append(&candidates, dk)
		}
	}

	avg_dl := max((f64(total_len) / BENCH_BM25_WEIGHT_SCALE) / f64(doc_count), 1.0e-6)
	top_heap := make([dynamic]Bench_BM25_Hit, 0, min(len(candidates), k_limit), alloc)
	for dk in candidates {
		dm, _ := xitdb.hash_map_get_cursor(docs_m, dk)
		raw_len: i64 = 0
		if dc, hd := dm.?; hd {
			dem, _ := xitdb.read_hash_map_init(dc)
			raw_len = bench_read_nonneg_int(dem, "len")
		}
		dl := f64(raw_len) / BENCH_BM25_WEIGHT_SCALE
		norm := 1.2 * (1.0 - 0.75 + 0.75 * (dl / avg_dl))
		score: f64 = 0.0
		for i in 0 ..< num_tokens {
			if tf, ok_tf := token_postings[i][dk]; ok_tf && tf > 0.0 {
				score += idfs[i] * (tf * 2.2) / (tf + norm)
			}
		}
		if score > 0.0 {
			bench_bm25_heap_push(&top_heap, Bench_BM25_Hit{doc_key = dk, score = score}, k_limit)
		}
	}
	slice.sort_by(top_heap[:], bench_bm25_hit_better)
	out := make([]Bench_BM25_Hit, len(top_heap), allocator)
	for hit, idx in top_heap {
		out[idx] = Bench_BM25_Hit{
			doc_key = strings.clone(hit.doc_key, allocator),
			score   = hit.score,
		}
	}
	return out
}
```

</details>

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>score_collection_nif</code> — <a href="../../lib/xitdb/ash/search.ex#L348-L390">lib/xitdb/ash/search.ex#L348-L390</a></summary>

```elixir
    defp score_collection_nif(db, collection, tokens, opts, resource) do
      case Storage.root_cursor(db) do
        %Xitdb.Cursor{tag: :none} ->
          []

        %Xitdb.Cursor{tx_mode: false, db_ref: db_ref, tag_id: root_tag_id, value: root_val_int} ->
          nif_opts = %{
            match: opts[:match],
            prefix: opts[:prefix?],
            min_prefix_length: opts[:min_prefix_length],
            max_prefix_expansions: opts[:max_prefix_expansions],
            k1: opts[:k1] * 1.0,
            b: opts[:b] * 1.0,
            exact_boost: opts[:exact_boost] * 1.0,
            prefix_weight: opts[:prefix_weight] * 1.0
          }

          case Xitdb.NIF.nif_bm25_search(
                 db_ref,
                 root_tag_id,
                 root_val_int,
                 collection,
                 tokens,
                 opts[:limit],
                 nif_opts
               ) do
            {:ok, raw_hits} ->
              Enum.map(raw_hits, fn {doc_key, score} ->
                {decode_doc_key(resource, doc_key), score}
              end)

            {:error, :invalid_moment} ->
              []

            {:error, reason} ->
              raise Xitdb.Error, reason: reason, details: %{collection: collection}
          end

        _ ->
          raise ArgumentError,
                "backend: :nif requires a committed Xitdb handle or snapshot cursor"
      end
    end
```

</details>

<details>
<summary>NIF <code>odin_nif_bm25_search</code> — <a href="../../native/xitdb_nif.odin#L5947-L6275">native/xitdb_nif.odin#L5947-L6275</a></summary>

```odin
odin_nif_bm25_search :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	arena_alloc := context.temp_allocator
	context.allocator = arena_alloc

	if argc != 7 {
		return make_err(env, "badarg")
	}

	root_tag_id: i64 = 0
	root_val_int: i64 = 0
	limit_int: i64 = 0
	if nif_get_int64(env, argv[1], &root_tag_id) == 0 ||
	   nif_get_int64(env, argv[2], &root_val_int) == 0 ||
	   nif_get_int64(env, argv[5], &limit_int) == 0 {
		return make_err(env, "badarg")
	}

	collection, ok_col := get_string_from_binary(env, argv[3])
	if !ok_col {
		return make_err(env, "badarg")
	}

	if nif_is_list(env, argv[4]) == 0 {
		return make_err(env, "badarg")
	}

	opts, ok_opts := parse_bm25_opts(env, argv[6])
	if !ok_opts {
		return make_err(env, "badarg")
	}

	query_terms := make([dynamic]string, 0, 8, arena_alloc)
	seen_query_terms := make(map[string]bool, 8, arena_alloc)
	head: ERL_NIF_TERM
	tail := argv[4]
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return make_err(env, "badarg")
		}
		tok, ok_tok := get_string_from_binary(env, head)
		if !ok_tok {
			return make_err(env, "badarg")
		}
		if len(tok) == 0 || seen_query_terms[tok] {
			continue
		}
		seen_query_terms[tok] = true
		append(&query_terms, tok)
	}

	empty_list := nif_make_list_from_array(env, nil, 0)
	if len(query_terms) == 0 || limit_int <= 0 || len(collection) == 0 {
		return make_ok(env, empty_list)
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	root_cur, has_root, err_reason, root_err := resolve_snapshot_root_cursor(handle, root_tag_id, root_val_int)
	if root_err != nil {
		return make_xitdb_err(env, root_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if !has_root {
		return make_ok(env, empty_list)
	}

	// Traverse root["idx"]["search"][collection]
	root_hm, rhm_err := xitdb.read_hash_map_init(root_cur)
	if rhm_err != nil {
		return make_xitdb_err(env, rhm_err)
	}
	idx_maybe, idx_err := xitdb.hash_map_get_cursor(root_hm, "idx")
	if idx_err != nil {
		return make_xitdb_err(env, idx_err)
	}
	idx_cur, has_idx := idx_maybe.?
	if !has_idx {
		return make_ok(env, empty_list)
	}

	idx_hm, ihm_err := xitdb.read_hash_map_init(idx_cur)
	if ihm_err != nil {
		return make_xitdb_err(env, ihm_err)
	}
	search_maybe, s_err := xitdb.hash_map_get_cursor(idx_hm, "search")
	if s_err != nil {
		return make_xitdb_err(env, s_err)
	}
	search_cur, has_search := search_maybe.?
	if !has_search {
		return make_ok(env, empty_list)
	}

	search_hm, shm_err := xitdb.read_hash_map_init(search_cur)
	if shm_err != nil {
		return make_xitdb_err(env, shm_err)
	}
	col_maybe, c_err := xitdb.hash_map_get_cursor(search_hm, collection)
	if c_err != nil {
		return make_xitdb_err(env, c_err)
	}
	col_cur, has_col := col_maybe.?
	if !has_col {
		return make_ok(env, empty_list)
	}

	col_hm, chm_err := xitdb.read_hash_map_init(col_cur)
	if chm_err != nil {
		return make_xitdb_err(env, chm_err)
	}

	// 1. Read corpus stats from `meta` (`doc_count` & `total_len`)
	meta_maybe, m_err := xitdb.hash_map_get_cursor(col_hm, "meta")
	if m_err != nil {
		return make_xitdb_err(env, m_err)
	}
	meta_cur, has_meta := meta_maybe.?
	if !has_meta {
		return make_ok(env, empty_list)
	}
	meta_hm, mhm_err := xitdb.read_hash_map_init(meta_cur)
	if mhm_err != nil {
		return make_xitdb_err(env, mhm_err)
	}

	doc_count, dc_err := read_hash_map_nonneg_int(meta_hm, "doc_count")
	if dc_err != nil {
		return make_xitdb_err(env, dc_err)
	}
	total_len, tl_err := read_hash_map_nonneg_int(meta_hm, "total_len")
	if tl_err != nil {
		return make_xitdb_err(env, tl_err)
	}

	if doc_count <= 0 || total_len <= 0 {
		return make_ok(env, empty_list)
	}

	docs_maybe, d_err := xitdb.hash_map_get_cursor(col_hm, "docs")
	if d_err != nil {
		return make_xitdb_err(env, d_err)
	}
	docs_cur, has_docs := docs_maybe.?
	if !has_docs {
		return make_ok(env, empty_list)
	}
	docs_hm, dhm_err := xitdb.read_hash_map_init(docs_cur)
	if dhm_err != nil {
		return make_xitdb_err(env, dhm_err)
	}

	terms_maybe, t_err := xitdb.hash_map_get_cursor(col_hm, "terms")
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	terms_cur, has_terms := terms_maybe.?
	if !has_terms {
		return make_ok(env, empty_list)
	}
	terms_sm, tsm_err := xitdb.read_sorted_map_init(terms_cur)
	if tsm_err != nil {
		return make_xitdb_err(env, tsm_err)
	}

	// 2. Collect virtual-token posting maps (exact + bounded B+Tree prefix expansion)
	num_tokens := len(query_terms)
	token_postings := make([]map[string]f64, num_tokens, arena_alloc)
	idfs := make([]f64, num_tokens, arena_alloc)
	sb_buf: [8]u8 = ---

	for q_tok, tok_idx in query_terms {
		merged := make(map[string]f64, 32, arena_alloc)
		use_prefix := opts.prefix_enabled && utf8.rune_count_in_string(q_tok) >= opts.min_prefix_length

		if use_prefix {
			it, it_err := xitdb.sorted_map_iterator_from_string(terms_sm, q_tok)
			if it_err != nil {
				return make_xitdb_err(env, it_err)
			}
			scanned := 0
			for scanned < opts.max_prefix_expansions {
				next_maybe, n_err := xitdb.cursor_iterator_next(&it)
				if n_err != nil {
					return make_xitdb_err(env, n_err)
				}
				elem_cur, has_next := next_maybe.?
				if !has_next {
					break
				}
				kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, arena_alloc)
				if kv_err != nil {
					return make_xitdb_err(env, kv_err)
				}
				matched_term, kt_err := read_key_cursor_string(kv.key_cursor, sb_buf[:])
				if kt_err != nil {
					return make_xitdb_err(env, kt_err)
				}
				if !strings.has_prefix(matched_term, q_tok) {
					break
				}
				mult := opts.exact_boost if matched_term == q_tok else opts.prefix_weight
				if cp_err := collect_postings_into_map(kv.value_cursor, mult, &merged, arena_alloc); cp_err != nil {
					return make_xitdb_err(env, cp_err)
				}
				scanned += 1
			}
		} else {
			p_maybe, p_err := xitdb.sorted_map_get_cursor(terms_sm, q_tok)
			if p_err != nil {
				return make_xitdb_err(env, p_err)
			}
			if p_cur, has_p := p_maybe.?; has_p {
				if cp_err := collect_postings_into_map(p_cur, opts.exact_boost, &merged, arena_alloc); cp_err != nil {
					return make_xitdb_err(env, cp_err)
				}
			}
		}

		if opts.match_mode == .All && len(merged) == 0 {
			return make_ok(env, empty_list)
		}

		df := f64(len(merged))
		idfs[tok_idx] = math.ln(1.0 + (f64(doc_count) - df + 0.5) / (df + 0.5))
		token_postings[tok_idx] = merged
	}

	// 3. Resolve candidate document keys (`:all` smallest-posting intersection vs `:any` union)
	candidates := make([dynamic]string, 0, 64, arena_alloc)
	if opts.match_mode == .All {
		smallest_idx := 0
		for i in 1 ..< num_tokens {
			if len(token_postings[i]) < len(token_postings[smallest_idx]) {
				smallest_idx = i
			}
		}
		for doc_key in token_postings[smallest_idx] {
			in_all := true
			for i in 0 ..< num_tokens {
				if i == smallest_idx {
					continue
				}
				if doc_key not_in token_postings[i] {
					in_all = false
					break
				}
			}
			if in_all {
				append(&candidates, doc_key)
			}
		}
	} else {
		seen_docs := make(map[string]bool, 64, arena_alloc)
		for i in 0 ..< num_tokens {
			for doc_key in token_postings[i] {
				if !seen_docs[doc_key] {
					seen_docs[doc_key] = true
					append(&candidates, doc_key)
				}
			}
		}
	}

	if len(candidates) == 0 {
		return make_ok(env, empty_list)
	}

	// 4. Score candidates in IEEE-754 f64 & maintain bounded Top-K min-heap
	avg_dl := max((f64(total_len) / BM25_WEIGHT_SCALE) / f64(doc_count), 1.0e-6)
	k_limit := int(limit_int)
	top_heap := make([dynamic]BM25_Hit, 0, min(len(candidates), k_limit), arena_alloc)

	for doc_key in candidates {
		raw_doc_len: i64 = 0
		doc_maybe, dm_err := xitdb.hash_map_get_cursor(docs_hm, doc_key)
		if dm_err != nil {
			return make_xitdb_err(env, dm_err)
		}
		if doc_cur, has_doc := doc_maybe.?; has_doc {
			doc_entry_hm, de_err := xitdb.read_hash_map_init(doc_cur)
			if de_err != nil {
				return make_xitdb_err(env, de_err)
			}
			dl_val, dl_err := read_hash_map_nonneg_int(doc_entry_hm, "len")
			if dl_err != nil {
				return make_xitdb_err(env, dl_err)
			}
			raw_doc_len = dl_val
		}

		doc_len := f64(raw_doc_len) / BM25_WEIGHT_SCALE
		norm := opts.k1 * (1.0 - opts.b + opts.b * (doc_len / avg_dl))

		score: f64 = 0.0
		for i in 0 ..< num_tokens {
			if tf, ok_tf := token_postings[i][doc_key]; ok_tf && tf > 0.0 {
				score += idfs[i] * (tf * (opts.k1 + 1.0)) / (tf + norm)
			}
		}

		if score > 0.0 {
			bm25_heap_push(&top_heap, BM25_Hit{doc_key = doc_key, score = score}, k_limit)
		}
	}

	if len(top_heap) == 0 {
		return make_ok(env, empty_list)
	}

	slice.sort_by(top_heap[:], bm25_hit_better)

	hit_terms := make([]ERL_NIF_TERM, len(top_heap), arena_alloc)
	for hit, idx in top_heap {
		hit_terms[idx] = nif_make_tuple2(
			env,
			make_binary(env, hit.doc_key),
			nif_make_double(env, hit.score),
		)
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(hit_terms), c.uint(len(hit_terms))))
}
```

</details>

<details>
<summary>NIF <code>parse_bm25_opts</code> — <a href="../../native/xitdb_nif.odin#L5685-L5771">native/xitdb_nif.odin#L5685-L5771</a></summary>

```odin
parse_bm25_opts :: proc(env: ErlNifEnv, opts_term: ERL_NIF_TERM) -> (opts: BM25_Opts, ok: bool) {
	opts = BM25_Opts{
		match_mode            = .All,
		prefix_enabled        = true,
		min_prefix_length     = 3,
		max_prefix_expansions = 64,
		k1                    = 1.2,
		b                     = 0.75,
		exact_boost           = 1.25,
		prefix_weight         = 1.0,
	}

	if nif_is_map(env, opts_term) == 0 {
		return opts, false
	}

	v: ERL_NIF_TERM
	if nif_get_map_value(env, opts_term, ATOM_MATCH, &v) != 0 {
		if v == ATOM_ALL {
			opts.match_mode = .All
		} else if v == ATOM_ANY {
			opts.match_mode = .Any
		} else {
			return opts, false
		}
	}

	if nif_get_map_value(env, opts_term, ATOM_PREFIX, &v) != 0 {
		if v == ATOM_TRUE {
			opts.prefix_enabled = true
		} else if v == ATOM_FALSE {
			opts.prefix_enabled = false
		} else {
			return opts, false
		}
	}

	if nif_get_map_value(env, opts_term, ATOM_MIN_PREFIX_LENGTH, &v) != 0 {
		iv: i64 = 0
		if nif_get_int64(env, v, &iv) == 0 || iv < 1 {
			return opts, false
		}
		opts.min_prefix_length = int(iv)
	}

	if nif_get_map_value(env, opts_term, ATOM_MAX_PREFIX_EXPANSIONS, &v) != 0 {
		iv: i64 = 0
		if nif_get_int64(env, v, &iv) == 0 || iv < 1 {
			return opts, false
		}
		opts.max_prefix_expansions = int(iv)
	}

	if nif_get_map_value(env, opts_term, ATOM_K1, &v) != 0 {
		fv, fok := get_term_float(env, v)
		if !fok || fv < 0.0 {
			return opts, false
		}
		opts.k1 = fv
	}

	if nif_get_map_value(env, opts_term, ATOM_B, &v) != 0 {
		fv, fok := get_term_float(env, v)
		if !fok || fv < 0.0 || fv > 1.0 {
			return opts, false
		}
		opts.b = fv
	}

	if nif_get_map_value(env, opts_term, ATOM_EXACT_BOOST, &v) != 0 {
		fv, fok := get_term_float(env, v)
		if !fok || fv < 0.0 {
			return opts, false
		}
		opts.exact_boost = fv
	}

	if nif_get_map_value(env, opts_term, ATOM_PREFIX_WEIGHT, &v) != 0 {
		fv, fok := get_term_float(env, v)
		if !fok || fv < 0.0 {
			return opts, false
		}
		opts.prefix_weight = fv
	}

	return opts, true
}
```

</details>

<details>
<summary>NIF <code>resolve_snapshot_root_cursor</code> — <a href="../../native/xitdb_nif.odin#L5652-L5671">native/xitdb_nif.odin#L5652-L5671</a></summary>

```odin
resolve_snapshot_root_cursor :: proc(
	handle: ^Db_Handle,
	root_tag_id: i64,
	root_val_int: i64,
) -> (root_cur: xitdb.Read_Cursor, has_data: bool, err_reason: string, err: xitdb.Error) {
	slot, _, is_empty, r_err, reason := resolve_slot_arg(handle, root_tag_id, root_val_int)
	if r_err != nil {
		return {}, false, "", r_err
	}
	if reason != "" {
		return {}, false, reason, nil
	}
	if is_empty || slot.tag == .None || slot.value == 0 {
		return {}, false, "", nil
	}
	return xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}, true, "", nil
}
```

</details>

<details>
<summary>NIF <code>read_hash_map_nonneg_int</code> — <a href="../../native/xitdb_nif.odin#L5638-L5649">native/xitdb_nif.odin#L5638-L5649</a></summary>

```odin
read_hash_map_nonneg_int :: proc(hm: xitdb.Read_Hash_Map, key: string) -> (val: i64, err: xitdb.Error) {
	cur_maybe := xitdb.hash_map_get_cursor(hm, key) or_return
	cur, has_cur := cur_maybe.?
	if !has_cur {
		return 0, nil
	}
	v, ok := read_cursor_nonneg_int(cur) or_return
	if !ok {
		return 0, nil
	}
	return v, nil
}
```

</details>

<details>
<summary>NIF <code>read_key_cursor_string</code> — <a href="../../native/xitdb_nif.odin#L349-L355">native/xitdb_nif.odin#L349-L355</a></summary>

```odin
read_key_cursor_string :: proc(cur: xitdb.Read_Cursor, sb_buf: []u8) -> (s: string, err: xitdb.Error) {
	if cur.slot_ptr.slot.tag == .Short_Bytes && !cur.slot_ptr.slot.full {
		b_obj := xitdb.cursor_read_bytes_buf(cur, sb_buf) or_return
		return string(b_obj.value), nil
	}
	return xitdb.cursor_read_string(cur, 0, context.temp_allocator)
}
```

</details>

<details>
<summary>NIF <code>collect_postings_into_map</code> — <a href="../../native/xitdb_nif.odin#L5773-L5803">native/xitdb_nif.odin#L5773-L5803</a></summary>

```odin
collect_postings_into_map :: proc(
	postings_cur: xitdb.Read_Cursor,
	multiplier: f64,
	dest: ^map[string]f64,
	arena_alloc: mem.Allocator,
) -> xitdb.Error {
	it := xitdb.cursor_iterator(postings_cur) or_return
	for {
		next_maybe := xitdb.cursor_iterator_next(&it) or_return
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}
		kv := xitdb.cursor_read_kv_pair(elem_cur, arena_alloc) or_return
		doc_key := read_arena_string(kv.key_cursor, arena_alloc) or_return
		if doc_key == "__tx" {
			continue
		}
		scaled_tf, ok_tf := read_cursor_nonneg_int(kv.value_cursor) or_return
		if !ok_tf || scaled_tf <= 0 {
			continue
		}
		tf := (f64(scaled_tf) / BM25_WEIGHT_SCALE) * multiplier
		if existing, found := dest[doc_key]; found {
			dest[doc_key] = existing + tf
		} else {
			dest[doc_key] = tf
		}
	}
	return nil
}
```

</details>

<details>
<summary>NIF <code>bm25_heap_push</code> — <a href="../../native/xitdb_nif.odin#L5571-L5608">native/xitdb_nif.odin#L5571-L5608</a></summary>

```odin
bm25_heap_push :: proc(heap: ^[dynamic]BM25_Hit, item: BM25_Hit, k: int) {
	if len(heap^) < k {
		append(heap, item)
		idx := len(heap^) - 1
		for idx > 0 {
			parent := (idx - 1) / 2
			if bm25_hit_worse(heap[idx], heap[parent]) {
				heap[idx], heap[parent] = heap[parent], heap[idx]
				idx = parent
			} else {
				break
			}
		}
		return
	}

	if k > 0 && bm25_hit_better(item, heap[0]) {
		heap[0] = item
		n := len(heap^)
		idx := 0
		for {
			left := 2*idx + 1
			right := 2*idx + 2
			worst := idx
			if left < n && bm25_hit_worse(heap[left], heap[worst]) {
				worst = left
			}
			if right < n && bm25_hit_worse(heap[right], heap[worst]) {
				worst = right
			}
			if worst == idx {
				break
			}
			heap[idx], heap[worst] = heap[worst], heap[idx]
			idx = worst
		}
	}
}
```

</details>

<details>
<summary>NIF <code>read_cursor_nonneg_int</code> — <a href="../../native/xitdb_nif.odin#L5622-L5636">native/xitdb_nif.odin#L5622-L5636</a></summary>

```odin
read_cursor_nonneg_int :: proc(cur: xitdb.Read_Cursor) -> (val: i64, ok: bool, err: xitdb.Error) {
	slot_ptr := xitdb.cursor_resolved(cur) or_return
	#partial switch slot_ptr.slot.tag {
	case .Uint:
		u := xitdb.cursor_read_uint(cur) or_return
		return i64(u), true, nil
	case .Int:
		i := xitdb.cursor_read_int(cur) or_return
		if i < 0 {
			return 0, true, nil
		}
		return i, true, nil
	}
	return 0, false, nil
}
```

</details>

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.core_destroy</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L347-L376">core.odin#L347-L376</a></summary>

```odin
core_destroy :: proc(c: ^Core, close_file := false) -> Error {
	switch &v in c {
	case Core_Memory:
		_memory_destroy(&v)
	case Core_File:
		if close_file && v.file != nil {
			os.close(v.file) or_return
			v.file = nil
		}
	case Core_Buffered_File:
		_ = _buffered_flush(&v)
		if v.memory.vmem_reserved > 0 {
			if raw_data(v.memory.buf) != nil {
				vmem.release(raw_data(v.memory.buf), uint(v.memory.vmem_reserved))
			}
			v.memory.buf = nil
			v.memory.vmem_reserved = 0
		} else {
			delete(v.memory.buf)
			v.memory.buf = nil
		}
		if close_file && v.file.file != nil {
			os.close(v.file.file) or_return
			v.file.file = nil
		}
	case Core_Overlay:
		_overlay_destroy(&v)
	}
	return nil
}
```

</details>

<details>
<summary><code>xitdb.core_memory_init</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L85-L112">core.odin#L85-L112</a></summary>

```odin
core_memory_init :: proc(allocator := context.allocator, reserve_size: int = DEFAULT_VMEM_RESERVE_SIZE) -> Core {
	if reserve_size > 0 {
		aligned_reserve := _vmem_align_page(reserve_size)
		if reserved_slice, r_err := vmem.reserve(uint(aligned_reserve)); r_err == .None && raw_data(reserved_slice) != nil {
			initial_commit := min(_vmem_align_page(4096), aligned_reserve)
			if c_err := vmem.commit(raw_data(reserved_slice), uint(initial_commit)); c_err == .None {
				raw_arr := runtime.Raw_Dynamic_Array{
					data      = raw_data(reserved_slice),
					len       = 0,
					cap       = initial_commit,
					allocator = runtime.nil_allocator(),
				}
				return Core_Memory{
					buf           = transmute([dynamic]u8)raw_arr,
					pos           = 0,
					allocator     = allocator,
					vmem_reserved = aligned_reserve,
				}
			}
			vmem.release(raw_data(reserved_slice), uint(aligned_reserve))
		}
	}
	return Core_Memory{
		buf       = make([dynamic]u8, 0, 1024, allocator),
		pos       = 0,
		allocator = allocator,
	}
}
```

</details>

<details>
<summary><code>xitdb.database_init</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L182-L234">database.odin#L182-L234</a></summary>

```odin
database_init :: proc(core: ^Core, hasher := Hasher{}) -> (db: Database, err: Error) {
	h := hasher
	if h.hash_proc == nil && h.hash_size == 0 {
		h = sha1_hasher()
	}

	// If buffered file, clear any stale buffer bytes before opening.
	#partial switch &bf in core {
	case Core_Buffered_File:
		clear(&bf.memory.buf)
		bf.memory_pos = 0
		bf.pos = 0
		bf.file_len = nil
	}

	db.core = core
	db.hasher = h
	db.tx_start = nil
	db.transaction = nil

	core_seek_to(core, 0) or_return
	length := core_length(core) or_return

	if length == 0 {
		file_id := h.file_id
		if file_id == 0 {
			file_id = _random_u64()
		}
		digest_len := h.hash_size
		if digest_len == 0 {
			digest_len = 20
		}
		db.header = Header{
			file_id      = file_id,
			hash_id      = h.id,
			hash_size    = digest_len,
			version      = VERSION,
			padding      = 0,
			magic_number = MAGIC_NUMBER,
		}
		header_write(db.header, core) or_return
		rh_bytes := root_header_to_bytes(Root_Header{file_size = 0, root = Slot{}})
		core_write_all(core, rh_bytes[:]) or_return
		database_commit_root(&db, Slot{}, 0) or_return
		core_sync(core) or_return
	} else {
		db.header = database_read_and_validate_header(&db) or_return
		_ = database_committed_size(&db) or_return
	}

	db.tx_start = nil
	return db, nil
}
```

</details>

<details>
<summary><code>xitdb.sha1_hasher</code> — <a href="../../native/xitdb-odin/xitdb/types.odin#L826-L835">types.odin#L826-L835</a></summary>

```odin
sha1_hasher :: proc(id: u32 = 0, file_id: u64 = 0) -> Hasher {
	return Hasher{
		hash_proc = proc(data: []u8, out_hash: []u8, _: rawptr) {
			sha1_sum_into(data, out_hash)
		},
		hash_size = 20,
		id        = id,
		file_id   = file_id,
	}
}
```

</details>

<details>
<summary><code>xitdb.database_root_cursor</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L281-L296">database.odin#L281-L296</a></summary>

```odin
database_root_cursor :: proc(db: ^Database) -> Write_Cursor {
	root, err := database_read_root_slot(db)
	if err != nil {
		root = Slot{}
	}
	return Write_Cursor{
		read_cursor = Read_Cursor{
			slot_ptr = Slot_Pointer{
				position = i64(ROOT_HEADER_START),
				slot     = root,
			},
			db        = db,
			frozen_at = 0,
		},
	}
}
```

</details>

<details>
<summary><code>xitdb.read_array_list_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L16-L24">collections.odin#L16-L24</a></summary>

```odin
read_array_list_init :: proc(cursor: Read_Cursor) -> (res: Read_Array_List, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Array_List:
		return Read_Array_List{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.array_list_get_cursor</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L41-L43">collections.odin#L41-L43</a></summary>

```odin
array_list_get_cursor :: proc(a: Read_Array_List, index: i64) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(a.cursor, []Path_Part{Array_List_Get{index = index}})
}
```

</details>

<details>
<summary><code>xitdb.read_hash_map_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L246-L254">collections.odin#L246-L254</a></summary>

```odin
read_hash_map_init :: proc(cursor: Read_Cursor) -> (res: Read_Hash_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Hash_Map, .Hash_Set:
		return Read_Hash_Map{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.hash_map_get_cursor</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L330-L334">collections.odin#L330-L334</a></summary>

```odin
hash_map_get_cursor :: proc(m: Read_Hash_Map, key: string) -> (Maybe(Read_Cursor), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_get_cursor_by_hash(m, hash)
}
```

</details>

<details>
<summary><code>xitdb.read_sorted_map_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L693-L701">collections.odin#L693-L701</a></summary>

```odin
read_sorted_map_init :: proc(cursor: Read_Cursor) -> (res: Read_Sorted_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Sorted_Map, .Sorted_Set:
		return Read_Sorted_Map{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.sorted_map_iterator_from_string</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L726-L728">collections.odin#L726-L728</a></summary>

```odin
sorted_map_iterator_from_string :: proc(m: Read_Sorted_Map, start_key: string) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_from_key(m.cursor, transmute([]u8)start_key)
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_next</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1535-L1556">cursor.odin#L1535-L1556</a></summary>

```odin
cursor_iterator_next :: proc(it: ^Cursor_Iterator) -> (res: Maybe(Read_Cursor), err: Error) {
	#partial switch it.cursor.slot_ptr.slot.tag {
	case .None:
		return nil, nil
	case .Array_List:
		if it.index == it.size {
			return nil, nil
		}
		it.index += 1
		return _iterator_next_internal(it, 0)
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		if it.index == it.size {
			return nil, nil
		}
		it.index += 1
		return _iterator_next_internal(it, BTREE_NODE_HEADER_SIZE)
	case .Hash_Map, .Hash_Set, .Counted_Hash_Map, .Counted_Hash_Set:
		return _iterator_next_internal(it, 0)
	case:
		return nil, .Unexpected_Tag
	}
}
```

</details>
