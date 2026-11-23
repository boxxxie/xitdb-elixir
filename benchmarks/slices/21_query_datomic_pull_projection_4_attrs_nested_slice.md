# #21: `Query: Datomic pull projection (4 attrs + nested slice)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#27, #31 (Pull Projections, Datalog Engine, Buffered Sync, Search & Indexer)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 8.37 µs (8365.0 ns) | 1.70 µs (1695.0 ns) | **`4.94x`** NIF Ratio |
| **Mean ± σ (CV)** | 8.88 µs ± 1.12 µs (12.6%) | 1.70 µs ± 25.0 ns (1.5%) | Welch `z` = `14.38` |
| **p95 / Max (`ns/op`)** | 10.33 µs / 10.54 µs | 1.74 µs / 1.74 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L457-L464`](../bench_elixir.exs#L457-L464))

```elixir
      {21, "Query: Datomic pull projection (4 attrs + nested slice)", 200,
       fn ->
         for i <- 0..199 do
           _ = Xitdb.pull!(elem(u_cursors, i), "{name, age, roles[0..2], profile{city}}")
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1378-L1393`](../bench_client.odin#L1378-L1393))

```odin
	// #21: Datomic pull projection
	if r21 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for i in 0 ..< 200 {
				uid := fmt.tprintf("u%d", i)
				uc, _ := xitdb.hash_map_get_cursor(users_map, uid)
				_, _ = xitdb.pull(uc.?, "{name, age, roles[0..2], profile{city}}", context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 200.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(21, "Query: Datomic pull projection (4 attrs + nested slice)", 200, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>pull!</code> — <a href="../../lib/xitdb.ex#L1186-L1186">lib/xitdb.ex#L1186-L1186</a></summary>

```elixir
  def pull!(target, pattern, opts \\ []), do: target |> pull(pattern, opts) |> Error.unwrap!()
```

</details>

<details>
<summary>Elixir <code>pull</code> — <a href="../../lib/xitdb.ex#L1094-L1121">lib/xitdb.ex#L1094-L1121</a></summary>

```elixir
  def pull(target, pattern, opts \\ [])

  def pull(%__MODULE__{db_ref: db_ref}, pattern, opts) when is_list(opts) do
    pull(
      %Cursor{db_ref: db_ref, tag: :hash_map, tag_id: -1, value: -1, moment: -1, root: true},
      pattern,
      opts
    )
  end

  def pull(%Cursor{} = cursor, pattern, opts) when is_binary(pattern) and is_list(opts) do
    raw_tagged? = Keyword.get(opts, :raw_tagged, false)

    with {:ok, max_bytes} <- fetch_max_decompressed_bytes(opts),
         {:ok, res} <- do_pull_pattern(cursor, pattern, raw_tagged?, max_bytes, opts) do
      if raw_tagged? do
        {:ok, res}
      else
        Compression.resolve_term(res, cursor.db_ref, cursor.moment, opts)
      end
    end
  end

  def pull(%Cursor{} = cursor, pattern, opts) when is_list(pattern) and is_list(opts) do
    with {:ok, compiled} <- Pull.compile(pattern) do
      pull(cursor, compiled, opts)
    end
  end
```

</details>

<details>
<summary>Elixir <code>do_nif_pull</code> — <a href="../../lib/xitdb.ex#L1155-L1182">lib/xitdb.ex#L1155-L1182</a></summary>

```elixir
  defp do_nif_pull(
         %Cursor{
           root: true,
           tag: tag,
           tag_id: tag_id,
           value: val,
           db_ref: db_ref,
           moment: moment
         },
         pattern,
         raw_tagged?,
         max_bytes
       )
       when tag != :none do
    {nid, nval} = if tag_id != -1 and val == 0, do: {tag_id, 0}, else: {-1, moment}

    db_ref
    |> NIF.nif_pull(nid, nval, pattern, raw_tagged?, max_bytes)
    |> Error.wrap(%{pattern: pattern})
  end

  defp do_nif_pull(%Cursor{} = cursor, pattern, raw_tagged?, max_bytes) do
    %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = Cursor.ensure_resolved(cursor)

    db_ref
    |> NIF.nif_pull(tag_id, val, pattern, raw_tagged?, max_bytes)
    |> Error.wrap(%{pattern: pattern})
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_pull</code> — <a href="../../native/xitdb_nif.odin#L7304-L7379">native/xitdb_nif.odin#L7304-L7379</a></summary>

```odin
odin_nif_pull :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 && argc != 5 && argc != 6 {
		return make_err(env, "badarg")
	}
	raw_tagged := false
	if argc >= 5 {
		bt, ok_rt := parse_bool_arg(argv[4])
		if !ok_rt {
			return make_err(env, "badarg")
		}
		raw_tagged = bt
	}
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES
	if argc == 6 {
		mb, ok_mb := parse_max_bytes_arg(env, argv[5])
		if !ok_mb {
			return make_err(env, "badarg")
		}
		max_bytes = mb
	}
	tag_int, val_int: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	pattern_str, ok_p := get_string_from_binary(env, argv[3])
	if !ok_p {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, is_root, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List, .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
			return make_ok(env, nif_make_list_from_array(env, nil, 0))
		case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
			return make_ok(env, nif_make_new_map(env))
		case:
			return make_ok(env, ATOM_NIL)
		}
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}
	visited: map[i64]bool
	visited.allocator = context.temp_allocator
	codec_err := ""
	iter_pool := nif_iter_pool_init(context.temp_allocator)
	res_term, p_reason, p_err := nif_pull_cursor(env, &handle.db, cur, pattern_str, is_root, &visited, raw_tagged, &codec_err, max_bytes, &iter_pool)
	if p_err != nil {
		if len(codec_err) > 0 {
			return make_err(env, codec_err)
		}
		return make_xitdb_err(env, p_err)
	}
	if p_reason != "" {
		return make_err(env, p_reason)
	}
	return make_ok(env, res_term)
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
<summary>NIF <code>nif_pull_cursor</code> — <a href="../../native/xitdb_nif.odin#L7094-L7298">native/xitdb_nif.odin#L7094-L7298</a></summary>

```odin
nif_pull_cursor :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	cur: xitdb.Read_Cursor,
	pattern: string,
	is_root: bool,
	visited: ^map[i64]bool,
	raw_tagged: bool = false,
	codec_err: ^string = nil,
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES,
	pool: ^Nif_Iter_Pool = nil,
) -> (res: ERL_NIF_TERM, err_reason: string, err: xitdb.Error) {
	p := strings.trim_space(pattern)
	if len(p) == 0 || p == "*" {
		return nif_pull_wildcard(env, db, cur, is_root, visited, raw_tagged, codec_err, max_bytes, pool)
	}

	if len(p) >= 2 && p[0] == '{' && p[len(p) - 1] == '}' {
		inner := strings.trim_space(p[1 : len(p) - 1])
		specs := split_top_level_pull_specs(inner, context.temp_allocator)
		keys := make([dynamic]ERL_NIF_TERM, 0, len(specs), context.temp_allocator)
		vals := make([dynamic]ERL_NIF_TERM, 0, len(specs), context.temp_allocator)

		cur_slot := xitdb.cursor_slot(cur) or_return

		// Pass 1: if wildcard `*` appears anywhere at top level, expand base entries first so explicit specs override
		has_star := false
		if strings.contains_rune(inner, '*') {
			for spec in specs {
				if strings.trim_space(spec) == "*" {
					has_star = true
					break
				}
			}
		}
		if has_star {
			#partial switch cur_slot.tag {
			case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
				it := nif_iter_pool_acquire(pool) or_return
				defer nif_iter_pool_release(pool, it)
				xitdb.cursor_iterator_init(it, cur) or_return
				for {
					next_maybe := xitdb.cursor_iterator_next(it) or_return
					elem_cur, ok := next_maybe.?
					if !ok {
						break
					}
					key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
					k_str := xitdb.cursor_read_string(key_cur, 0, context.temp_allocator) or_return
					if is_root && k_str == "__tx" {
						continue
					}
					v, v_reason, v_err := nif_pull_wildcard(env, db, val_cur, false, visited, raw_tagged, codec_err, max_bytes, pool)
					if v_err != nil {
						return 0, "", v_err
					}
					if v_reason != "" {
						return 0, v_reason, nil
					}
					append(&keys, make_binary(env, k_str))
					append(&vals, v)
				}
			}
		}

		cur_hm: xitdb.Read_Hash_Map
		has_cur_hm := false
		if cur_slot.tag == .Hash_Map {
			hm_init, hm_err := xitdb.read_hash_map_init(cur)
			if hm_err == nil {
				cur_hm = hm_init
				has_cur_hm = true
			}
		} else if cur_slot.tag == .Counted_Hash_Map {
			chm_init, chm_err := xitdb.read_counted_hash_map_init(cur)
			if chm_err == nil {
				cur_hm = chm_init.read_hash_map
				has_cur_hm = true
			}
		}

		// Pass 2: explicit field specs
		for raw_spec in specs {
			s := strings.trim_space(raw_spec)
			if len(s) == 0 || s == "*" {
				continue
			}

			brace_idx := find_top_level_pull_brace(s)
			sub_pattern := "*"
			path_part := s
			if brace_idx == 0 {
				return 0, "invalid_pull_pattern", nil
			}
			if brace_idx > 0 {
				path_part = strings.trim_space(s[:brace_idx])
				sub_pattern = strings.trim_space(s[brace_idx:])
			}

			range_start: i64 = 0
			range_end: i64 = -1
			has_range := false
			if bracket_idx := find_last_unquoted_lbracket(path_part); bracket_idx > 0 && strings.has_suffix(path_part, "]") {
				inside := path_part[bracket_idx + 1 : len(path_part) - 1]
				if len(inside) > 0 && inside[0] != '"' && inside[0] != '\'' {
					if dots_idx := strings.index(inside, ".."); dots_idx >= 0 {
						r_start, ok1 := strconv.parse_i64(strings.trim_space(inside[:dots_idx]))
						r_end, ok2 := strconv.parse_i64(strings.trim_space(inside[dots_idx + 2:]))
						if !ok1 || !ok2 {
							return 0, "", .Invalid_Range
						}
						range_start = r_start
						range_end = r_end
						has_range = true
						path_part = strings.trim_space(path_part[:bracket_idx])
					}
				}
			}

			target_cur: xitdb.Read_Cursor
			found_target := false
			label: string

			if single_key, is_simple := is_simple_hash_map_ident(path_part); is_simple && has_cur_hm {
				target_maybe, r_err := xitdb.hash_map_get_cursor(cur_hm, single_key)
				if r_err != nil {
					if r_err == .Unexpected_Tag {
						continue
					}
					return 0, "", r_err
				}
				if tc, ok := target_maybe.?; ok {
					target_cur = tc
					found_target = true
					label = single_key
				}
			} else {
				steps, p_err := parse_escaped_steps(path_part, context.temp_allocator)
				if p_err != "" {
					return 0, p_err, nil
				}
				if len(steps) == 0 {
					continue
				}
				target_maybe, r_err := xitdb.read_steps_cursor(cur, steps)
				if r_err == .Unexpected_Tag {
					target_maybe, _, r_err = read_steps_cursor_adaptive(cur, steps)
				}
				if r_err != nil {
					if r_err == .Unexpected_Tag {
						continue
					}
					return 0, "", r_err
				}
				if tc, ok := target_maybe.?; ok {
					target_cur = tc
					found_target = true
					label = steps[len(steps) - 1].key if len(steps[len(steps) - 1].key) > 0 else path_part
				}
			}

			if !found_target {
				continue
			}

			pulled: ERL_NIF_TERM
			if has_range {
				pr, pr_reason, pr_err := nif_pull_range(env, db, target_cur, range_start, range_end, sub_pattern, visited, raw_tagged, codec_err, max_bytes, pool)
				if pr_err != nil {
					return 0, "", pr_err
				}
				if pr_reason != "" {
					return 0, pr_reason, nil
				}
				pulled = pr
			} else if len(sub_pattern) == 0 || sub_pattern == "*" {
				t_slot := xitdb.cursor_slot(target_cur) or_return
				if !is_container_tag(t_slot.tag) {
					pulled = slot_to_term(env, db, t_slot, raw_tagged, codec_err, max_bytes) or_return
				} else {
					pc, pc_reason, pc_err := nif_pull_cursor(env, db, target_cur, sub_pattern, false, visited, raw_tagged, codec_err, max_bytes, pool)
					if pc_err != nil {
						return 0, "", pc_err
					}
					if pc_reason != "" {
						return 0, pc_reason, nil
					}
					pulled = pc
				}
			} else {
				pc, pc_reason, pc_err := nif_pull_cursor(env, db, target_cur, sub_pattern, false, visited, raw_tagged, codec_err, max_bytes, pool)
				if pc_err != nil {
					return 0, "", pc_err
				}
				if pc_reason != "" {
					return 0, pc_reason, nil
				}
				pulled = pc
			}
			append(&keys, make_binary(env, label))
			append(&vals, pulled)
		}

		return make_map_safe(env, keys[:], vals[:]), "", nil
	}
```

</details>

<details>
<summary>NIF <code>nif_pull_wildcard</code> — <a href="../../native/xitdb_nif.odin#L6909-L7011">native/xitdb_nif.odin#L6909-L7011</a></summary>

```odin
nif_pull_wildcard :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	cur: xitdb.Read_Cursor,
	is_root: bool,
	visited: ^map[i64]bool,
	raw_tagged: bool = false,
	codec_err: ^string = nil,
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES,
	pool: ^Nif_Iter_Pool = nil,
) -> (res: ERL_NIF_TERM, err_reason: string, err: xitdb.Error) {
	slot := xitdb.cursor_slot(cur) or_return
	if !is_container_tag(slot.tag) {
		term := slot_to_term(env, db, slot, raw_tagged, codec_err, max_bytes) or_return
		return term, "", nil
	}
	if slot.value > 0 {
		if visited[slot.value] {
			return ATOM_NIL, "", nil
		}
		visited[slot.value] = true
	}
	defer if slot.value > 0 {
		delete_key(visited, slot.value)
	}

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		items := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			v, v_reason, v_err := nif_pull_wildcard(env, db, elem_cur, false, visited, raw_tagged, codec_err, max_bytes, pool)
			if v_err != nil {
				return 0, "", v_err
			}
			if v_reason != "" {
				return 0, v_reason, nil
			}
			append(&items, v)
		}
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), "", nil
		}
		return nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))), "", nil

	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		items := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			v := slot_to_term(env, db, key_cur.slot_ptr.slot, raw_tagged, codec_err, max_bytes) or_return
			append(&items, v)
		}
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), "", nil
		}
		return nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))), "", nil

	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		keys := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		vals := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			k_str := xitdb.cursor_read_string(key_cur, 0, context.temp_allocator) or_return
			if is_root && k_str == "__tx" {
				continue
			}
			v, v_reason, v_err := nif_pull_wildcard(env, db, val_cur, false, visited, raw_tagged, codec_err, max_bytes, pool)
			if v_err != nil {
				return 0, "", v_err
			}
			if v_reason != "" {
				return 0, v_reason, nil
			}
			append(&keys, make_binary(env, k_str))
			append(&vals, v)
		}
		return make_map_safe(env, keys[:], vals[:]), "", nil
	}
	return ATOM_NIL, "", nil
}
```

</details>

<details>
<summary>NIF <code>split_top_level_pull_specs</code> — <a href="../../native/xitdb_nif.odin#L6785-L6831">native/xitdb_nif.odin#L6785-L6831</a></summary>

```odin
split_top_level_pull_specs :: proc(inner: string, allocator: runtime.Allocator) -> []string {
	specs := make([dynamic]string, 0, 8, allocator)
	brace_depth := 0
	bracket_depth := 0
	in_quote: u8 = 0
	start := 0
	i := 0
	for i < len(inner) {
		ch := inner[i]
		if in_quote != 0 {
			if ch == '\\' && i + 1 < len(inner) {
				i += 2
				continue
			}
			if ch == in_quote {
				in_quote = 0
			}
			i += 1
			continue
		}
		if ch == '\\' && i + 1 < len(inner) {
			i += 2
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '{' {
			brace_depth += 1
		} else if ch == '}' {
			if brace_depth > 0 {
				brace_depth -= 1
			}
		} else if ch == '[' {
			bracket_depth += 1
		} else if ch == ']' {
			if bracket_depth > 0 {
				bracket_depth -= 1
			}
		} else if (ch == ',' || ch == '\n') && brace_depth == 0 && bracket_depth == 0 {
			part := strings.trim_space(inner[start:i])
			if len(part) > 0 {
				append(&specs, part)
			}
			start = i + 1
		}
		i += 1
	}
```

</details>

<details>
<summary>NIF <code>nif_iter_pool_acquire</code> — <a href="../../native/xitdb_nif.odin#L713-L721">native/xitdb_nif.odin#L713-L721</a></summary>

```odin
nif_iter_pool_acquire :: proc(pool: ^Nif_Iter_Pool) -> (it: ^xitdb.Cursor_Iterator, err: xitdb.Error) {
	if pool == nil || pool.alloc.procedure == nil {
		return nif_alloc_cursor_iterator(context.temp_allocator)
	}
	if len(pool.free_list) > 0 {
		return pop(&pool.free_list), nil
	}
	return nif_alloc_cursor_iterator(pool.alloc)
}
```

</details>

<details>
<summary>NIF <code>nif_iter_pool_release</code> — <a href="../../native/xitdb_nif.odin#L723-L730">native/xitdb_nif.odin#L723-L730</a></summary>

```odin
nif_iter_pool_release :: proc(pool: ^Nif_Iter_Pool, it: ^xitdb.Cursor_Iterator) {
	if pool == nil || pool.alloc.procedure == nil || it == nil {
		return
	}
	if _, alloc_err := append(&pool.free_list, it); alloc_err != nil {
		free(it, pool.alloc)
	}
}
```

</details>

<details>
<summary>NIF <code>find_top_level_pull_brace</code> — <a href="../../native/xitdb_nif.odin#L6841-L6876">native/xitdb_nif.odin#L6841-L6876</a></summary>

```odin
find_top_level_pull_brace :: proc(s: string) -> int {
	in_quote: u8 = 0
	bracket_depth := 0
	i := 0
	for i < len(s) {
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
		if ch == '\\' && i + 1 < len(s) {
			i += 2
			continue
		}
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '[' {
			bracket_depth += 1
		} else if ch == ']' {
			if bracket_depth > 0 {
				bracket_depth -= 1
			}
		} else if ch == '{' && bracket_depth == 0 {
			return i
		}
		i += 1
	}
	return -1
}
```

</details>

## Reachable `xitdb` Core Procedures

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
<summary><code>xitdb.pull</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L2104-L2116">dsl.odin#L2104-L2116</a></summary>

```odin
pull :: proc(cursor: Read_Cursor, pattern: string, allocator := context.temp_allocator) -> (res: Pull_Value, err: Error) {
	p := strings.trim_space(pattern)
	if len(p) == 0 || p == "*" {
		slot := cursor_slot(cursor) or_return
		if !_is_collection_tag(slot.tag) {
			return _pull_scalar_slot(cursor, slot, allocator)
		}
	}
	visited := make(map[i64]bool, 16, context.temp_allocator)
	pool := _iter_pool_init(context.allocator)
	defer _iter_pool_destroy(&pool)
	return _pull_with_visited(cursor, pattern, &visited, &pool, allocator)
}
```

</details>

<details>
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L64-L67">cursor.odin#L64-L67</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_init</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1041-L1082">cursor.odin#L1041-L1082</a></summary>

```odin
cursor_iterator_init :: proc(res: ^Cursor_Iterator, unresolved_cursor: Read_Cursor) -> (err: Error) {
	_reset_cursor_iterator(res)
	defer if err != nil {
		mem.zero_item(res)
	}
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return

	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		res.cursor = cursor
	case .Array_List:
		res.cursor = cursor
		position := cursor.slot_ptr.slot.value
		hb: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
		core_read_exact_at(cursor.db.core, position, hb[:]) or_return
		header := array_list_header_from_bytes(hb) or_return
		res.size = header.size
		res.index = 0
		if header.size > 0 {
			_init_array_list_stack(res, cursor, header, 0, false) or_return
		}
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		res.cursor = cursor
		position := cursor.slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8 = ---
		core_read_exact_at(cursor.db.core, position, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		res.size = header.size
		res.index = 0
		_init_btree_stack(res, cursor, header, false) or_return
	case .Hash_Map, .Hash_Set:
		res.cursor = cursor
		_init_iter_level(cursor, cursor.slot_ptr.slot.value, &res.stack[0]) or_return
		res.stack_len = 1
	case .Counted_Hash_Map, .Counted_Hash_Set:
		res.cursor = cursor
		_init_counted_hash_iter(res, cursor, false) or_return
	case:
		return .Unexpected_Tag
	}
	return nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_next</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1799-L1838">cursor.odin#L1799-L1838</a></summary>

```odin
cursor_iterator_next :: proc(it: ^Cursor_Iterator) -> (res: Maybe(Read_Cursor), err: Error) {
	#partial switch it.cursor.slot_ptr.slot.tag {
	case .None:
		return nil, nil
	case .Array_List:
		if it.index == it.size {
			return nil, nil
		}
		item := _iterator_step_internal(it, false) or_return
		if item == nil {
			return nil, .Unexpected_Tag
		}
		it.index += 1
		return item, nil
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		if it.index == it.size {
			return nil, nil
		}
		item := _iterator_step_internal(it, false) or_return
		if item == nil {
			return nil, .Invalid_BTree_Node
		}
		it.index += 1
		return item, nil
	case .Counted_Hash_Map, .Counted_Hash_Set:
		if it.index == it.size {
			return nil, nil
		}
		item := _iterator_step_internal(it, false) or_return
		if item == nil {
			return nil, .Invalid_Database
		}
		it.index += 1
		return item, nil
	case .Hash_Map, .Hash_Set:
		return _iterator_step_internal(it, false)
	case:
		return nil, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_kv_pair_slots</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L413-L440">cursor.odin#L413-L440</a></summary>

```odin
cursor_read_kv_pair_slots :: proc(c: Read_Cursor) -> (key_cursor: Read_Cursor, value_cursor: Read_Cursor, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if is_key_only_entry(slot_ptr.slot) {
		return Read_Cursor{slot_ptr = Slot_Pointer{position = slot_ptr.position, slot = slot_ptr.slot}, db = c.db, frozen_at = c.frozen_at},
			Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = Slot{}}, db = c.db, frozen_at = c.frozen_at},
			nil
	}
	if slot_ptr.slot.tag != .KV_Pair && slot_ptr.slot.tag != .Sorted_KV_Pair {
		return {}, {}, .Unexpected_Tag
	}
	key_pos, k_ok := _checked_add_i64(slot_ptr.slot.value, database_kv_key_offset(c.db, slot_ptr.slot.tag))
	if !k_ok {
		return {}, {}, .End_Of_Stream
	}
	val_pos, v_ok := _checked_add_i64(key_pos, SLOT_LENGTH)
	if !v_ok {
		return {}, {}, .End_Of_Stream
	}
	b: [SLOT_LENGTH * 2]u8 = ---
	core_read_exact_at(c.db.core, key_pos, b[:]) or_return
	key_slot := slot_from_slice_raw(b[0:SLOT_LENGTH])
	tag_validate(key_slot.tag) or_return
	val_slot := slot_from_slice_raw(b[SLOT_LENGTH : SLOT_LENGTH * 2])
	tag_validate(val_slot.tag) or_return
	return Read_Cursor{slot_ptr = Slot_Pointer{position = key_pos, slot = key_slot}, db = c.db, frozen_at = c.frozen_at},
		Read_Cursor{slot_ptr = Slot_Pointer{position = val_pos, slot = val_slot}, db = c.db, frozen_at = c.frozen_at},
		nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_string</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L242-L245">cursor.odin#L242-L245</a></summary>

```odin
cursor_read_string :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: string, err: Error) {
	b := cursor_read_bytes(c, max_size, allocator) or_return
	return string(b), nil
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
<summary><code>xitdb.read_counted_hash_map_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L263-L271">collections.odin#L263-L271</a></summary>

```odin
read_counted_hash_map_init :: proc(cursor: Read_Cursor) -> (res: Read_Counted_Hash_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Counted_Hash_Map, .Counted_Hash_Set:
		return Read_Counted_Hash_Map{read_hash_map = Read_Hash_Map{cursor = cursor}}, nil
	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.read_steps_cursor</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L467-L557">dsl.odin#L467-L557</a></summary>

```odin
read_steps_cursor :: proc(start: Read_Cursor, steps: []Path_Step) -> (res: Maybe(Read_Cursor), err: Error) {
	cur := start
	for step in steps {
		switch step.kind {
		case .Hash_Map_Key:
			m := read_hash_map_init(cur) or_return
			next_maybe := hash_map_get_cursor(m, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Counted_Hash_Map_Key:
			cm := read_counted_hash_map_init(cur) or_return
			next_maybe := hash_map_get_cursor(cm.read_hash_map, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Sorted_Map_Key:
			if slot_ptr := cursor_resolved(cur) or_return; slot_ptr.slot.tag == .Hash_Map || slot_ptr.slot.tag == .Counted_Hash_Map {
				m := read_hash_map_init(cur) or_return
				next_maybe := hash_map_get_cursor(m, step.key) or_return
				next_cur, ok := next_maybe.?
				if !ok {
					return nil, nil
				}
				cur = next_cur
			} else {
				sm_col := read_sorted_map_init(cur) or_return
				next_maybe := sorted_map_get_cursor(sm_col, step.key) or_return
				next_cur, ok := next_maybe.?
				if !ok {
					return nil, nil
				}
				cur = next_cur
			}

		case .Array_List_Idx:
			al_col := read_array_list_init(cur) or_return
			next_maybe := array_list_get_cursor(al_col, step.index) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Linked_List_Idx:
			ll_col := read_linked_array_list_init(cur) or_return
			next_maybe := linked_array_list_get_cursor(ll_col, step.index) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Hash_Set_Member:
			hs_col := read_hash_set_init(cur) or_return
			next_maybe := hash_set_get_cursor(hs_col, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Counted_Set_Member:
			cs_col := read_counted_hash_set_init(cur) or_return
			next_maybe := hash_set_get_cursor(cs_col.read_hash_set, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Sorted_Set_Member:
			ss_col := read_sorted_set_init(cur) or_return
			next_maybe := cursor_read_path(ss_col.cursor, []Path_Part{
				Sorted_Map_Get{target = Sorted_Map_Get_Key{key = transmute([]u8)step.key}},
			}) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur
		}
	}
	return cur, nil
}
```

</details>

<details>
<summary><code>xitdb.database_digest_string_buf</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L283-L285">database.odin#L283-L285</a></summary>

```odin
database_digest_string_buf :: proc(db: ^Database, s: string, buf: []u8) -> []u8 {
	return database_digest_buf(db, transmute([]u8)s, buf)
}
```

</details>

<details>
<summary><code>xitdb.hash_map_get_cursor_by_hash</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L304-L306">collections.odin#L304-L306</a></summary>

```odin
hash_map_get_cursor_by_hash :: proc(m: Read_Hash_Map, hash: []u8) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(m.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Value{hash = hash}}})
}
```

</details>
