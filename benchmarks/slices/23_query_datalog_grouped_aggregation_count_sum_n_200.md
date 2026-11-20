# #23: `Query: Datalog grouped aggregation (count + sum, N=200)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#27 (Pull Projections, Datalog Engine, Buffered Sync, Search & Indexer)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 2.00 ms (2000326.0 ns) | 580.56 µs (580557.0 ns) | **`3.45x`** NIF Ratio |
| **Mean ± σ (CV)** | 2.72 ms ± 2.12 ms (77.8%) | 575.76 µs ± 108.41 µs (18.8%) | Welch `z` = `2.26` |
| **p95 / Max (`ns/op`)** | 5.62 ms / 6.29 ms | 714.58 µs / 746.74 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L462-L469`](../bench_elixir.exs#L462-L469))

```elixir
      {23, "Query: Datalog grouped aggregation (count + sum, N=200)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _} = Xitdb.query(diff_db, datalog_agg_q)
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1345-L1364`](../bench_client.odin#L1345-L1364))

```odin
	// #23: Datalog grouped aggregation (count + sum, N=200)
	if r23 {
		q_agg := `
			find ?dept, count(?id), sum(?age)
			where
				.users[?id].dept = ?dept
				.users[?id].age = ?age
		`
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				_, _ = xitdb.query_datalog(&diff_db, q_agg, -1, context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(23, "Query: Datalog grouped aggregation (count + sum, N=200)", 50, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>query</code> — <a href="../../lib/xitdb.ex#L848-L863">lib/xitdb.ex#L848-L863</a></summary>

```elixir
  def query(target, query_str, opts \\ [])

  def query(%__MODULE__{db_ref: db_ref}, query_str, opts) when is_binary(query_str) do
    with {:ok, validated} <- validate_opts(opts, @query_schema) do
      moment = Keyword.get(validated, :moment, -1)
      do_query(db_ref, moment, query_str)
    end
  end

  def query(%Cursor{db_ref: db_ref, moment: cursor_moment}, query_str, opts)
      when is_binary(query_str) do
    with {:ok, validated} <- validate_opts(opts, @query_schema) do
      moment = Keyword.get(validated, :moment, cursor_moment)
      do_query(db_ref, moment, query_str)
    end
  end
```

</details>

<details>
<summary>Elixir <code>do_query</code> — <a href="../../lib/xitdb.ex#L865-L867">lib/xitdb.ex#L865-L867</a></summary>

```elixir
  defp do_query(db_ref, moment, query_str) do
    db_ref |> NIF.nif_query_datalog(moment, query_str) |> Error.wrap()
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_query_datalog</code> — <a href="../../native/xitdb_nif.odin#L8017-L8093">native/xitdb_nif.odin#L8017-L8093</a></summary>

```odin
odin_nif_query_datalog :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
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

	q_val, q_err := nif_dl_parse_query(query_str, context.temp_allocator)
	if q_err != "" {
		return make_err(env, q_err)
	}
	q := new(NIF_Datalog_Query, context.temp_allocator)
	q^ = q_val

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	raw_rows := make([dynamic][]xitdb.Pull_Value, 0, 8, context.temp_allocator)
	matched_envs := make([dynamic]NIF_Datalog_Env, 0, 8, context.temp_allocator)
	dl_env := new(NIF_Datalog_Env, context.temp_allocator)

	_, exec_err := nif_dl_eval_clauses(&handle.db, q, 0, moment_idx, dl_env, &raw_rows, &matched_envs, false, context.temp_allocator)
	if exec_err != nil {
		return make_xitdb_err(env, exec_err)
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

	rows_terms := make([]ERL_NIF_TERM, len(final_rows), context.temp_allocator)
	for row, r_idx in final_rows {
		cols := make([]ERL_NIF_TERM, len(row), context.temp_allocator)
		for cell, c_idx in row {
			cols[c_idx] = pull_value_to_term(env, cell)
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
<summary>NIF <code>nif_dl_parse_query</code> — <a href="../../native/xitdb_nif.odin#L7105-L7154">native/xitdb_nif.odin#L7105-L7154</a></summary>

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
<summary>NIF <code>nif_dl_eval_clauses</code> — <a href="../../native/xitdb_nif.odin#L7839-L7898">native/xitdb_nif.odin#L7839-L7898</a></summary>

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
<summary>NIF <code>nif_dl_compute_aggregations</code> — <a href="../../native/xitdb_nif.odin#L7900-L8014">native/xitdb_nif.odin#L7900-L8014</a></summary>

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
<summary>NIF <code>pull_value_to_term</code> — <a href="../../native/xitdb_nif.odin#L644-L692">native/xitdb_nif.odin#L644-L692</a></summary>

```odin
pull_value_to_term :: proc(env: ErlNifEnv, pv: xitdb.Pull_Value) -> ERL_NIF_TERM {
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
			items[idx] = pull_value_to_term(env, elem)
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
			vals[idx] = pull_value_to_term(env, entry.val)
		}
		return make_map_safe(env, keys, vals)
	}
	return ATOM_NIL
}
```

</details>

<details>
<summary>NIF <code>nif_dl_is_ws</code> — <a href="../../native/xitdb_nif.odin#L6295-L6297">native/xitdb_nif.odin#L6295-L6297</a></summary>

```odin
nif_dl_is_ws :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
}
```

</details>

<details>
<summary>NIF <code>nif_dl_find_where_keyword</code> — <a href="../../native/xitdb_nif.odin#L6299-L6332">native/xitdb_nif.odin#L6299-L6332</a></summary>

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

<details>
<summary>NIF <code>nif_dl_parse_find_item</code> — <a href="../../native/xitdb_nif.odin#L7068-L7103">native/xitdb_nif.odin#L7068-L7103</a></summary>

```odin
nif_dl_parse_find_item :: proc(q: ^NIF_Datalog_Query, token: string) -> (item: xitdb.Datalog_Find_Item, err_reason: string) {
	aggs := [?]struct {
		prefix: string,
		kind:   xitdb.Datalog_Agg_Kind,
	}{
		{"count(", .Count},
		{"sum(",   .Sum},
		{"min(",   .Min},
		{"max(",   .Max},
	}

	for a in aggs {
		if strings.has_prefix(token, a.prefix) && strings.has_suffix(token, ")") {
			inner := strings.trim_space(token[len(a.prefix) : len(token) - 1])
			v_idx, verr := nif_dl_intern_var(q, inner)
			if verr != "" {
				return {}, verr
			}
			return xitdb.Datalog_Find_Item{
				agg     = a.kind,
				var_idx = v_idx,
				label   = token,
			}, ""
		}
	}

	v_idx, verr := nif_dl_intern_var(q, token)
	if verr != "" {
		return {}, verr
	}
	return xitdb.Datalog_Find_Item{
		agg     = .None,
		var_idx = v_idx,
		label   = token,
	}, ""
}
```

</details>

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.query_datalog</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L3615-L3619">dsl.odin#L3615-L3619</a></summary>

```odin
query_datalog :: proc(db: ^Database, query_str: string, default_moment: i64 = -1, allocator := context.temp_allocator) -> (res: Datalog_Result, err: Error) {
	q := parse_datalog(query_str, allocator) or_return
	defer datalog_query_destroy(&q)
	return datalog_execute(db, &q, default_moment, allocator)
}
```

</details>

<details>
<summary><code>xitdb.datalog_execute</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L3621-L3650">dsl.odin#L3621-L3650</a></summary>

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

	_eval_datalog_clauses(db, q, 0, default_moment, env, &raw_rows, &matched_envs, false, allocator) or_return

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
<summary><code>xitdb._eval_datalog_clauses</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L3811-L3863">dsl.odin#L3811-L3863</a></summary>

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
		return _eval_datalog_clauses(db, q, clause_idx + 1, default_moment, next_env, out_rows, out_envs, stop_after_first, allocator)

	case .Not_Pattern:
		neg_clause := clause
		neg_clause.kind = .Pattern
		has_match := _eval_pattern_moment(db, q, neg_clause, -1, default_moment, env, out_rows, out_envs, true, allocator) or_return
		if has_match {
			return false, nil
		}
		return _eval_datalog_clauses(db, q, clause_idx + 1, default_moment, env, out_rows, out_envs, stop_after_first, allocator)

	case .Reach:
		return _eval_reach_clause(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, allocator)

	case .Pattern:
		return _eval_pattern_moment(db, q, clause, clause_idx, default_moment, env, out_rows, out_envs, stop_after_first, allocator)
	}

	return false, nil
}
```

</details>

<details>
<summary><code>xitdb._compute_datalog_aggregations</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L3692-L3808">dsl.odin#L3692-L3808</a></summary>

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
