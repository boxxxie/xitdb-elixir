# #22: `Query: Datalog B+Tree index prefix + join (N=200)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#27, #31 (Pull Projections, Datalog Engine, Buffered Sync, Search & Indexer)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 23.14 µs (23141.0 ns) | 15.99 µs (15995.0 ns) | **`1.45x`** NIF Ratio |
| **Mean ± σ (CV)** | 23.96 µs ± 1.57 µs (6.6%) | 16.20 µs ± 487.7 ns (3.0%) | Welch `z` = `10.56` |
| **p95 / Max (`ns/op`)** | 26.14 µs / 26.71 µs | 16.87 µs / 17.05 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L465-L472`](../bench_elixir.exs#L465-L472))

```elixir
      {22, "Query: Datalog B+Tree index prefix + join (N=200)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _} = Xitdb.query(diff_db, datalog_prefix_q)
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1395-L1416`](../bench_client.odin#L1395-L1416))

```odin
	// #22: Datalog B+Tree index prefix + join
	if r22 {
		q_prefix := `
			find ?name, ?age
			where
				$username->id[?name] = ?id
				starts_with(?name, "user_001")
				.users[?id].age = ?age
				.users[?id].dept = "eng"
		`
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				_, _ = xitdb.query_datalog(&diff_db, q_prefix, -1, context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(22, "Query: Datalog B+Tree index prefix + join (N=200)", 50, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>query</code> — <a href="../../lib/xitdb.ex#L1257-L1272">lib/xitdb.ex#L1257-L1272</a></summary>

```elixir
  def query(target, query_str, opts \\ [])

  def query(%__MODULE__{db_ref: db_ref}, query_str, opts) when is_binary(query_str) do
    with {:ok, validated} <- validate_opts(opts, @query_schema) do
      moment = Keyword.get(validated, :moment, -1)
      do_query(db_ref, moment, query_str, validated)
    end
  end

  def query(%Cursor{db_ref: db_ref, moment: cursor_moment}, query_str, opts)
      when is_binary(query_str) do
    with {:ok, validated} <- validate_opts(opts, @query_schema) do
      moment = Keyword.get(validated, :moment, cursor_moment)
      do_query(db_ref, moment, query_str, validated)
    end
  end
```

</details>

<details>
<summary>Elixir <code>do_query</code> — <a href="../../lib/xitdb.ex#L1274-L1285">lib/xitdb.ex#L1274-L1285</a></summary>

```elixir
  defp do_query(db_ref, moment, query_str, validated) do
    raw_tagged = Keyword.get(validated, :raw_tagged, false)

    max_bytes =
      Keyword.get(
        validated,
        :max_decompressed_bytes,
        Compression.default_max_decompressed_bytes()
      )

    run_datalog_loop(db_ref, moment, query_str, raw_tagged, max_bytes, validated, %{}, 16)
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_query_datalog</code> — <a href="../../native/xitdb_nif.odin#L9721-L9869">native/xitdb_nif.odin#L9721-L9869</a></summary>

```odin
odin_nif_query_datalog :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 && argc != 6 {
		return make_err(env, "badarg")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}
	query_str, ok_q := get_string_from_binary(env, argv[2])
	if !ok_q {
		return make_err(env, "badarg")
	}

	raw_tagged := false
	allow_defer := argc == 6
	max_decompressed_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES
	predecoded := make(map[string]Maybe(string), 8, context.temp_allocator)

	if argc == 6 {
		rt_val, ok_rt := parse_bool_arg(argv[3])
		if !ok_rt {
			return make_err(env, "badarg")
		}
		raw_tagged = rt_val

		max_b_i64: i64 = 0
		if nif_get_int64(env, argv[4], &max_b_i64) == 0 || max_b_i64 <= 0 {
			return make_err(env, "badarg")
		}
		max_decompressed_bytes = u64(max_b_i64)

		if nif_is_map(env, argv[5]) == 0 {
			return make_err(env, "badarg")
		}
		it: Nif_Map_Iter
		if nif_map_iter_create(env, argv[5], &it) == 0 {
			return make_err(env, "badarg")
		}
		defer nif_map_iter_destroy(env, &it)
		k_term, v_term: ERL_NIF_TERM
		for nif_map_iter_get_and_next(env, &it, &k_term, &v_term) != 0 {
			k_str, ok_k := get_string_from_binary(env, k_term)
			if !ok_k {
				return make_err(env, "badarg")
			}
			if v_term == ATOM_NIL {
				predecoded[k_str] = Maybe(string)(nil)
			} else if v_str, ok_v := get_string_from_binary(env, v_term); ok_v {
				predecoded[k_str] = v_str
			} else {
				return make_err(env, "badarg")
			}
		}
	}

	q_val, q_err := nif_dl_parse_query(query_str, context.temp_allocator)
	if q_err != "" {
		return make_err(env, q_err)
	}
	dl_ctx := NIF_DL_Decode_Ctx{
		raw_tagged             = raw_tagged,
		allow_defer            = allow_defer,
		max_decompressed_bytes = max_decompressed_bytes,
		predecoded             = predecoded,
		missing_seen           = make(map[string]bool, 8, context.temp_allocator),
		missing                = make([dynamic]NIF_DL_Missing_Tag, 0, 8, context.temp_allocator),
	}
	q := new(NIF_Datalog_Query, context.temp_allocator)
	q^ = q_val
	q.dl_ctx = &dl_ctx
	q.iter_pool = nif_iter_pool_init(context.temp_allocator)

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	raw_rows := make([dynamic][]xitdb.Pull_Value, 0, 8, context.temp_allocator)
	matched_envs := make([dynamic]NIF_Datalog_Env, 0, 8, context.temp_allocator)
	dl_env := new(NIF_Datalog_Env, context.temp_allocator)

	_, exec_err := nif_dl_eval_clauses(&handle.db, q, 0, moment_idx, dl_env, &raw_rows, &matched_envs, false, context.temp_allocator)
	if len(dl_ctx.codec_err) > 0 {
		return make_err(env, dl_ctx.codec_err)
	}
	if exec_err != nil {
		return make_xitdb_err(env, exec_err)
	}
	if len(dl_ctx.missing) > 0 {
		missing_terms := make([]ERL_NIF_TERM, len(dl_ctx.missing), context.temp_allocator)
		for &m, idx in dl_ctx.missing {
			missing_terms[idx] = nif_make_tuple3(
				env,
				nif_make_int64(env, m.moment),
				make_bytes_binary(env, m.tag[:]),
				make_bytes_binary(env, m.payload),
			)
		}
		missing_list := nif_make_list_from_array(env, raw_data(missing_terms), c.uint(len(missing_terms)))
		return nif_make_tuple2(env, ATOM_NEED_DECODE, missing_list)
	}

	final_rows := raw_rows[:]
	if q.has_aggregates {
		final_rows = nif_dl_compute_aggregations(q, matched_envs[:], context.temp_allocator)
	}

	vars_terms := make([]ERL_NIF_TERM, len(q.find_items), context.temp_allocator)
	for item, idx in q.find_items {
		vars_terms[idx] = make_binary(env, item.label)
	}
	vars_list: ERL_NIF_TERM
	if len(vars_terms) == 0 {
		vars_list = nif_make_list_from_array(env, nil, 0)
	} else {
		vars_list = nif_make_list_from_array(env, raw_data(vars_terms), c.uint(len(vars_terms)))
	}

	codec_err := ""
	rows_terms := make([]ERL_NIF_TERM, len(final_rows), context.temp_allocator)
	for row, r_idx in final_rows {
		cols := make([]ERL_NIF_TERM, len(row), context.temp_allocator)
		for cell, c_idx in row {
			cols[c_idx] = pull_value_to_term(env, cell, raw_tagged, &codec_err, max_decompressed_bytes)
			if len(codec_err) > 0 {
				return make_err(env, codec_err)
			}
		}
		if len(cols) == 0 {
			rows_terms[r_idx] = nif_make_list_from_array(env, nil, 0)
		} else {
			rows_terms[r_idx] = nif_make_list_from_array(env, raw_data(cols), c.uint(len(cols)))
		}
	}
	rows_list: ERL_NIF_TERM
	if len(rows_terms) == 0 {
		rows_list = nif_make_list_from_array(env, nil, 0)
	} else {
		rows_list = nif_make_list_from_array(env, raw_data(rows_terms), c.uint(len(rows_terms)))
	}

	keys := [2]ERL_NIF_TERM{ATOM_VARS, ATOM_ROWS}
	vals := [2]ERL_NIF_TERM{vars_list, rows_list}
	return make_ok(env, make_map_safe(env, keys[:], vals[:]))
}
```

</details>

<details>
<summary>NIF <code>nif_dl_parse_query</code> — <a href="../../native/xitdb_nif.odin#L8581-L8630">native/xitdb_nif.odin#L8581-L8630</a></summary>

```odin
nif_dl_parse_query :: proc(query_str: string, allocator: runtime.Allocator) -> (q: NIF_Datalog_Query, err_reason: string) {
	q = NIF_Datalog_Query{
		find_items = make([dynamic]xitdb.Datalog_Find_Item, 0, 8, allocator),
		clauses    = make([dynamic]NIF_Datalog_Clause, 0, 8, allocator),
		allocator  = allocator,
	}
	s := strings.trim_space(query_str)
	if len(s) < 5 || s[:4] != "find" || !nif_dl_is_ws(s[4]) {
		return {}, "invalid_datalog_query"
	}
	where_idx := nif_dl_find_where_keyword(s)
	if where_idx < 0 {
		return {}, "invalid_datalog_query"
	}

	find_part := strings.trim_space(s[len("find") : where_idx])
	find_tokens := strings.split(find_part, ",", allocator)
	for tok in find_tokens {
		item_str := strings.trim_space(tok)
		if len(item_str) == 0 {
			continue
		}
		item, ierr := nif_dl_parse_find_item(&q, item_str)
		if ierr != "" {
			return {}, ierr
		}
		if item.agg != .None {
			q.has_aggregates = true
		}
		append(&q.find_items, item)
	}
	if len(q.find_items) == 0 {
		return {}, "invalid_datalog_query"
	}

	where_body := strings.trim_space(s[where_idx + len("where"):])
	clauses_raw := nif_dl_split_where_clauses(where_body, allocator)
	for raw_clause in clauses_raw {
		line := strings.trim_space(raw_clause)
		if len(line) == 0 || strings.has_prefix(line, "//") || strings.has_prefix(line, "--") {
			continue
		}
		clause, cerr := nif_dl_parse_clause(&q, line, allocator)
		if cerr != "" {
			return {}, cerr
		}
		append(&q.clauses, clause)
	}
	return q, ""
}
```

</details>

<details>
<summary>NIF <code>nif_iter_pool_init</code> — <a href="../../native/xitdb_nif.odin#L696-L701">native/xitdb_nif.odin#L696-L701</a></summary>

```odin
nif_iter_pool_init :: proc(alloc := context.temp_allocator) -> Nif_Iter_Pool {
	return Nif_Iter_Pool{
		free_list = make([dynamic]^xitdb.Cursor_Iterator, alloc),
		alloc     = alloc,
	}
}
```

</details>

<details>
<summary>NIF <code>nif_dl_eval_clauses</code> — <a href="../../native/xitdb_nif.odin#L9537-L9602">native/xitdb_nif.odin#L9537-L9602</a></summary>

```odin
nif_dl_eval_clauses :: proc(
	db: ^xitdb.Database,
	q: ^NIF_Datalog_Query,
	clause_idx: int,
	default_moment: i64,
	env: ^NIF_Datalog_Env,
	out_rows: ^[dynamic][]xitdb.Pull_Value,
	out_envs: ^[dynamic]NIF_Datalog_Env,
	stop_after_first: bool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: xitdb.Error) {
	if q.dl_ctx != nil && len(q.dl_ctx.codec_err) > 0 {
		return false, nil
	}
	if clause_idx >= len(q.clauses) {
		if !stop_after_first {
			if q.has_aggregates && out_envs != nil {
				append(out_envs, env^)
			} else {
				row := make([]xitdb.Pull_Value, len(q.find_items), allocator)
				for item, i in q.find_items {
					row[i] = env.vals[item.var_idx]
				}
				append(out_rows, row)
			}
		}
		return true, nil
	}

	clause := &q.clauses[clause_idx]
	switch clause.kind {
	case .Predicate:
		ok_pred, bound_var := nif_dl_eval_predicate(clause, env)
		if !ok_pred {
			return false, nil
		}
		res, rerr := nif_dl_eval_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, stop_after_first, allocator)
		if bound_var >= 0 {
			env.bound[bound_var] = false
			env.vals[bound_var] = nil
		}
		return res, rerr

	case .Not_Pattern:
		neg_clause := new(NIF_Datalog_Clause, allocator)
		neg_clause^ = clause^
		neg_clause.kind = .Pattern
		neg_env := new(NIF_Datalog_Env, allocator)
		neg_env^ = env^
		has_match := nif_dl_eval_pattern_moment(db, q, neg_clause, -1, default_moment, neg_env, out_rows, out_envs, true, allocator) or_return
		if q.dl_ctx != nil && len(q.dl_ctx.codec_err) > 0 {
			return false, nil
		}
		if has_match {
			return false, nil
		}
		return nif_dl_eval_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, stop_after_first, allocator)

	case .Reach:
		return nif_dl_eval_reach(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, allocator)

	case .Pattern:
		return nif_dl_eval_pattern_moment(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, allocator)
	}
	return false, nil
}
```

</details>

<details>
<summary>NIF <code>nif_dl_compute_aggregations</code> — <a href="../../native/xitdb_nif.odin#L9604-L9718">native/xitdb_nif.odin#L9604-L9718</a></summary>

```odin
nif_dl_compute_aggregations :: proc(q: ^NIF_Datalog_Query, envs: []NIF_Datalog_Env, allocator: runtime.Allocator) -> [][]xitdb.Pull_Value {
	buckets := make([dynamic]NIF_Datalog_Group_Bucket, 0, 8, allocator)
	has_group_keys := false
	for item in q.find_items {
		if item.agg == .None {
			has_group_keys = true
			break
		}
	}

	for env in envs {
		b_idx := -1
		for &b, i in buckets {
			same_group := true
			for item in q.find_items {
				if item.agg == .None {
					if !nif_dl_value_equals(b.key_env.vals[item.var_idx], env.vals[item.var_idx]) {
						same_group = false
						break
					}
				}
			}
			if same_group {
				b_idx = i
				break
			}
		}
		if b_idx < 0 {
			b_idx = len(buckets)
			append(&buckets, NIF_Datalog_Group_Bucket{key_env = env})
		}

		b := &buckets[b_idx]
		for item, col_i in q.find_items {
			if !env.bound[item.var_idx] {
				continue
			}
			val := env.vals[item.var_idx]
			switch item.agg {
			case .None:
			case .Count:
				b.counts[col_i] += 1
			case .Sum:
				#partial switch v in val {
				case u64:
					b.sum_u64[col_i] += v
				case i64:
					if b.sum_kind[col_i] < 1 {
						b.sum_kind[col_i] = 1
					}
					b.sum_i64[col_i] += v
				case f64:
					b.sum_kind[col_i] = 2
					b.sum_f64[col_i] += v
				}
			case .Min:
				if !b.has_minmax[col_i] {
					b.min_vals[col_i] = val
					b.max_vals[col_i] = val
					b.has_minmax[col_i] = true
				} else if cmp, ok := nif_dl_compare_values(val, b.min_vals[col_i]); ok && cmp < 0 {
					b.min_vals[col_i] = val
				}
			case .Max:
				if !b.has_minmax[col_i] {
					b.min_vals[col_i] = val
					b.max_vals[col_i] = val
					b.has_minmax[col_i] = true
				} else if cmp, ok := nif_dl_compare_values(val, b.max_vals[col_i]); ok && cmp > 0 {
					b.max_vals[col_i] = val
				}
			}
		}
	}

	if len(buckets) == 0 && !has_group_keys {
		only_count_or_sum := true
		for item in q.find_items {
			if item.agg != .Count && item.agg != .Sum {
				only_count_or_sum = false
				break
			}
		}
		if only_count_or_sum {
			append(&buckets, NIF_Datalog_Group_Bucket{})
		}
	}

	rows := make([][]xitdb.Pull_Value, len(buckets), allocator)
	for &b, r_idx in buckets {
		row := make([]xitdb.Pull_Value, len(q.find_items), allocator)
		for item, col_i in q.find_items {
			switch item.agg {
			case .None:
				row[col_i] = b.key_env.vals[item.var_idx]
			case .Count:
				row[col_i] = b.counts[col_i]
			case .Sum:
				if b.sum_kind[col_i] == 2 {
					row[col_i] = b.sum_f64[col_i] + f64(b.sum_i64[col_i]) + f64(b.sum_u64[col_i])
				} else if b.sum_kind[col_i] == 1 {
					row[col_i] = b.sum_i64[col_i] + i64(b.sum_u64[col_i])
				} else {
					row[col_i] = b.sum_u64[col_i]
				}
			case .Min:
				row[col_i] = b.min_vals[col_i]
			case .Max:
				row[col_i] = b.max_vals[col_i]
			}
		}
		rows[r_idx] = row
	}
	return rows
}
```

</details>

<details>
<summary>NIF <code>pull_value_to_term</code> — <a href="../../native/xitdb_nif.odin#L831-L895">native/xitdb_nif.odin#L831-L895</a></summary>

```odin
pull_value_to_term :: proc(
	env: ErlNifEnv,
	pv: xitdb.Pull_Value,
	raw_tagged: bool = false,
	codec_err: ^string = nil,
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES,
) -> ERL_NIF_TERM {
	switch v in pv {
	case u64:
		return nif_make_uint64(env, v)
	case i64:
		return nif_make_int64(env, v)
	case f64:
		return nif_make_double(env, v)
	case string:
		return make_binary(env, v)
	case xitdb.Bytes:
		if len(v.format_tag) == 2 && v.format_tag[0] == 'b' && v.format_tag[1] == 'l' {
			if len(v.value) == 1 && v.value[0] == '1' {
				return ATOM_TRUE
			}
			return ATOM_FALSE
		}
		if !raw_tagged && len(v.format_tag) == 2 && v.format_tag[0] == 'c' && v.format_tag[1] == 'z' {
			t, cz_err := decode_cz_to_term(env, v.value, max_bytes)
			if cz_err != "" {
				if codec_err != nil && len(codec_err^) == 0 {
					codec_err^ = cz_err
				}
				return ATOM_NIL
			}
			return t
		}
		if len(v.format_tag) > 0 {
			return nif_make_tuple3(
				env,
				ATOM_TAGGED,
				make_bytes_binary(env, v.format_tag),
				make_bytes_binary(env, v.value),
			)
		}
		return make_bytes_binary(env, v.value)
	case xitdb.Pull_List:
		if len(v) == 0 {
			return nif_make_list_from_array(env, nil, 0)
		}
		items := make([]ERL_NIF_TERM, len(v), context.temp_allocator)
		for elem, idx in v {
			items[idx] = pull_value_to_term(env, elem, raw_tagged, codec_err, max_bytes)
		}
		return nif_make_list_from_array(env, raw_data(items), c.uint(len(items)))
	case xitdb.Pull_Map:
		if len(v) == 0 {
			return nif_make_new_map(env)
		}
		keys := make([]ERL_NIF_TERM, len(v), context.temp_allocator)
		vals := make([]ERL_NIF_TERM, len(v), context.temp_allocator)
		for entry, idx in v {
			keys[idx] = make_binary(env, entry.key)
			vals[idx] = pull_value_to_term(env, entry.val, raw_tagged, codec_err, max_bytes)
		}
		return make_map_safe(env, keys, vals)
	}
	return ATOM_NIL
}
```

</details>

<details>
<summary>NIF <code>nif_dl_is_ws</code> — <a href="../../native/xitdb_nif.odin#L7771-L7773">native/xitdb_nif.odin#L7771-L7773</a></summary>

```odin
nif_dl_is_ws :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
}
```

</details>

<details>
<summary>NIF <code>nif_dl_find_where_keyword</code> — <a href="../../native/xitdb_nif.odin#L7775-L7808">native/xitdb_nif.odin#L7775-L7808</a></summary>

```odin
nif_dl_find_where_keyword :: proc(s: string) -> int {
	in_quote: u8 = 0
	depth := 0
	i := 0
	for i + 5 <= len(s) {
		ch := s[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(s) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '{' || ch == '[' || ch == '(' {
			depth += 1
		} else if ch == '}' || ch == ']' || ch == ')' {
			if depth > 0 {
				depth -= 1
			}
		} else if depth == 0 && s[i : i + 5] == "where" {
			left_ok := i == 0 || nif_dl_is_ws(s[i - 1])
			right_ok := i + 5 == len(s) || nif_dl_is_ws(s[i + 5])
			if left_ok && right_ok {
				return i
			}
		}
		i += 1
	}
```

</details>

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.query_datalog</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L3773-L3777">dsl.odin#L3773-L3777</a></summary>

```odin
query_datalog :: proc(db: ^Database, query_str: string, default_moment: i64 = -1, allocator := context.temp_allocator) -> (res: Datalog_Result, err: Error) {
	q := parse_datalog(query_str, allocator) or_return
	defer datalog_query_destroy(&q)
	return datalog_execute(db, &q, default_moment, allocator)
}
```

</details>

<details>
<summary><code>xitdb.datalog_execute</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L3779-L3810">dsl.odin#L3779-L3810</a></summary>

```odin
datalog_execute :: proc(db: ^Database, q: ^Datalog_Query, default_moment: i64 = -1, allocator := context.temp_allocator) -> (res: Datalog_Result, err: Error) {
	raw_rows := make([dynamic][]Pull_Value, 0, 8, allocator)
	matched_envs := make([dynamic]Datalog_Env, 0, 8, allocator)
	defer delete(matched_envs)
	defer if err != nil {
		for row in raw_rows {
			delete(row, allocator)
		}
		delete(raw_rows)
	}
	env := Datalog_Env{}
	pool := _iter_pool_init(context.allocator)
	defer _iter_pool_destroy(&pool)

	_eval_datalog_clauses(db, q, 0, default_moment, env, &raw_rows, &matched_envs, false, &pool, allocator) or_return

	vars := make([]string, len(q.find_items), allocator)
	for item, i in q.find_items {
		vars[i] = item.label
	}

	if !q.has_aggregates {
		return Datalog_Result{vars = vars, rows = raw_rows[:]}, nil
	}

	for row in raw_rows {
		delete(row, allocator)
	}
	delete(raw_rows)
	agg_rows := _compute_datalog_aggregations(q, matched_envs[:], allocator)
	return Datalog_Result{vars = vars, rows = agg_rows}, nil
}
```

</details>

<details>
<summary><code>xitdb._iter_pool_init</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L1854-L1859">dsl.odin#L1854-L1859</a></summary>

```odin
_iter_pool_init :: proc(alloc := context.allocator) -> _Iter_Pool {
	return _Iter_Pool{
		free_list = make([dynamic]^Cursor_Iterator, alloc),
		alloc     = alloc,
	}
}
```

</details>

<details>
<summary><code>xitdb._iter_pool_destroy</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L1862-L1867">dsl.odin#L1862-L1867</a></summary>

```odin
_iter_pool_destroy :: proc(pool: ^_Iter_Pool) {
	for it in pool.free_list {
		free(it, pool.alloc)
	}
	delete(pool.free_list)
}
```

</details>

<details>
<summary><code>xitdb._eval_datalog_clauses</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L3971-L4024">dsl.odin#L3971-L4024</a></summary>

```odin
_eval_datalog_clauses :: proc(
	db: ^Database,
	q: ^Datalog_Query,
	clause_idx: int,
	default_moment: i64,
	env: Datalog_Env,
	out_rows: ^[dynamic][]Pull_Value,
	out_envs: ^[dynamic]Datalog_Env,
	stop_after_first: bool,
	pool: ^_Iter_Pool,
	allocator: runtime.Allocator,
) -> (matched_any: bool, err: Error) {
	if clause_idx >= len(q.clauses) {
		if !stop_after_first {
			if q.has_aggregates && out_envs != nil {
				append(out_envs, env)
			} else {
				row := make([]Pull_Value, len(q.find_items), allocator)
				for item, i in q.find_items {
					row[i] = env.vals[item.var_idx]
				}
				append(out_rows, row)
			}
		}
		return true, nil
	}

	clause := q.clauses[clause_idx]
	switch clause.kind {
	case .Predicate:
		next_env := env
		if !_eval_datalog_predicate(clause, &next_env) {
			return false, nil
		}
		return _eval_datalog_clauses(db, q, clause_idx + 1, default_moment, next_env, out_rows, out_envs, stop_after_first, pool, allocator)

	case .Not_Pattern:
		neg_clause := clause
		neg_clause.kind = .Pattern
		has_match := _eval_pattern_moment(db, q, neg_clause, -1, default_moment, env, out_rows, out_envs, true, pool, allocator) or_return
		if has_match {
			return false, nil
		}
		return _eval_datalog_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, stop_after_first, pool, allocator)

	case .Reach:
		return _eval_reach_clause(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, pool, allocator)

	case .Pattern:
		return _eval_pattern_moment(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, pool, allocator)
	}

	return false, nil
}
```

</details>

<details>
<summary><code>xitdb._compute_datalog_aggregations</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L3852-L3968">dsl.odin#L3852-L3968</a></summary>

```odin
_compute_datalog_aggregations :: proc(q: ^Datalog_Query, envs: []Datalog_Env, allocator: runtime.Allocator) -> [][]Pull_Value {
	buckets := make([dynamic]_Datalog_Group_Bucket, 0, 8, allocator)
	defer delete(buckets)

	has_group_keys := false
	for item in q.find_items {
		if item.agg == .None {
			has_group_keys = true
			break
		}
	}

	for env in envs {
		b_idx := -1
		for &b, i in buckets {
			same_group := true
			for item in q.find_items {
				if item.agg == .None {
					if !_pull_value_equals(b.key_env.vals[item.var_idx], env.vals[item.var_idx]) {
						same_group = false
						break
					}
				}
			}
			if same_group {
				b_idx = i
				break
			}
		}

		if b_idx < 0 {
			b_idx = len(buckets)
			append(&buckets, _Datalog_Group_Bucket{key_env = env})
		}

		b := &buckets[b_idx]
		for item, col_i in q.find_items {
			if !env.bound[item.var_idx] {
				continue
			}
			val := env.vals[item.var_idx]
			switch item.agg {
			case .None:
			case .Count:
				b.counts[col_i] += 1
			case .Sum:
				#partial switch v in val {
				case u64:
					b.sum_u64[col_i] += v
				case i64:
					b.sum_kind[col_i] = 1
					b.sum_i64[col_i] += v
				case f64:
					b.sum_kind[col_i] = 2
					b.sum_f64[col_i] += v
				}
			case .Min:
				if !b.has_minmax[col_i] {
					b.min_vals[col_i] = val
					b.max_vals[col_i] = val
					b.has_minmax[col_i] = true
				} else if cmp, ok := _compare_pull_values(val, b.min_vals[col_i]); ok && cmp < 0 {
					b.min_vals[col_i] = val
				}
			case .Max:
				if !b.has_minmax[col_i] {
					b.min_vals[col_i] = val
					b.max_vals[col_i] = val
					b.has_minmax[col_i] = true
				} else if cmp, ok := _compare_pull_values(val, b.max_vals[col_i]); ok && cmp > 0 {
					b.max_vals[col_i] = val
				}
			}
		}
	}

	// If global aggregation (no group-by keys) matched 0 rows and only `count`/`sum` are requested, return 1 zeroed row
	if len(buckets) == 0 && !has_group_keys {
		only_count_or_sum := true
		for item in q.find_items {
			if item.agg != .Count && item.agg != .Sum {
				only_count_or_sum = false
				break
			}
		}
		if only_count_or_sum {
			append(&buckets, _Datalog_Group_Bucket{})
		}
	}

	rows := make([][]Pull_Value, len(buckets), allocator)
	for &b, r_idx in buckets {
		row := make([]Pull_Value, len(q.find_items), allocator)
		for item, col_i in q.find_items {
			switch item.agg {
			case .None:
				row[col_i] = b.key_env.vals[item.var_idx]
			case .Count:
				row[col_i] = b.counts[col_i]
			case .Sum:
				if b.sum_kind[col_i] == 2 {
					row[col_i] = b.sum_f64[col_i] + f64(b.sum_i64[col_i]) + f64(b.sum_u64[col_i])
				} else if b.sum_kind[col_i] == 1 {
					row[col_i] = b.sum_i64[col_i] + i64(b.sum_u64[col_i])
				} else {
					row[col_i] = b.sum_u64[col_i]
				}
			case .Min:
				row[col_i] = b.min_vals[col_i]
			case .Max:
				row[col_i] = b.max_vals[col_i]
			}
		}
		rows[r_idx] = row
	}
	return rows
}
```

</details>
