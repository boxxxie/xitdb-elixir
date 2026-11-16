# #21: `Query: Datomic pull projection (4 attrs + nested slice)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#27 (Pull Projections, Datalog Engine, Buffered Sync, Search & Indexer)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 6.51 µs (6507.0 ns) | 2.72 µs (2721.0 ns) | **`2.39x`** NIF Ratio |
| **Mean ± σ (CV)** | 6.51 µs ± 144.2 ns (2.2%) | 2.73 µs ± 40.5 ns (1.5%) | Welch `z` = `56.49` |
| **p95 / Max (`ns/op`)** | 6.66 µs / 6.67 µs | 2.77 µs / 2.77 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L446-L453`](../bench_elixir.exs#L446-L453))

```elixir
      {21, "Query: Datomic pull projection (4 attrs + nested slice)", 200,
       fn ->
         for i <- 0..199 do
           _ = Xitdb.pull!(elem(u_cursors, i), "{name, age, roles[0..2], profile{city}}")
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1298-L1313`](../bench_client.odin#L1298-L1313))

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
<summary>Elixir <code>pull!</code> — <a href="../../lib/xitdb.ex#L778-L778">lib/xitdb.ex#L778-L778</a></summary>

```elixir
  def pull!(target, pattern), do: target |> pull(pattern) |> Error.unwrap!()
```

</details>

<details>
<summary>Elixir <code>pull</code> — <a href="../../lib/xitdb.ex#L725-L753">lib/xitdb.ex#L725-L753</a></summary>

```elixir
  def pull(%__MODULE__{db_ref: db_ref}, pattern) do
    pull(
      %Cursor{db_ref: db_ref, tag: :hash_map, tag_id: -1, value: -1, moment: -1, root: true},
      pattern
    )
  end

  def pull(%Cursor{} = cursor, pattern) when is_binary(pattern) do
    if :binary.match(pattern, "*") == :nomatch do
      do_nif_pull(cursor, pattern)
    else
      case Pull.split_wildcard_plan(pattern) do
        {:single, single_pat} ->
          do_nif_pull(cursor, single_pat)

        {:merge_top, wild_pat, spec_pat} ->
          with {:ok, wild_res} <- do_nif_pull(cursor, wild_pat),
               {:ok, spec_res} <- pull(cursor, spec_pat) do
            {:ok, Pull.merge_wildcard_results(wild_res, spec_res)}
          end
      end
    end
  end

  def pull(%Cursor{} = cursor, pattern) when is_list(pattern) do
    with {:ok, compiled} <- Pull.compile(pattern) do
      pull(cursor, compiled)
    end
  end
```

</details>

<details>
<summary>Elixir <code>do_nif_pull</code> — <a href="../../lib/xitdb.ex#L755-L774">lib/xitdb.ex#L755-L774</a></summary>

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
         pattern
       )
       when tag != :none do
    {nid, nval} = if tag_id != -1 and val == 0, do: {tag_id, 0}, else: {-1, moment}
    db_ref |> NIF.nif_pull(nid, nval, pattern) |> Error.wrap(%{pattern: pattern})
  end

  defp do_nif_pull(%Cursor{} = cursor, pattern) do
    %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = Cursor.ensure_resolved(cursor)
    db_ref |> NIF.nif_pull(tag_id, val, pattern) |> Error.wrap(%{pattern: pattern})
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_pull</code> — <a href="../../native/xitdb_nif.odin#L5605-L5659">native/xitdb_nif.odin#L5605-L5659</a></summary>

```odin
odin_nif_pull :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
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
	res_term, p_reason, p_err := nif_pull_cursor(env, &handle.db, cur, pattern_str, is_root, &visited)
	if p_err != nil {
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
<summary>NIF <code>nif_pull_cursor</code> — <a href="../../native/xitdb_nif.odin#L5404-L5599">native/xitdb_nif.odin#L5404-L5599</a></summary>

```odin
nif_pull_cursor :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	cur: xitdb.Read_Cursor,
	pattern: string,
	is_root: bool,
	visited: ^map[i64]bool,
) -> (res: ERL_NIF_TERM, err_reason: string, err: xitdb.Error) {
	p := strings.trim_space(pattern)
	if len(p) == 0 || p == "*" {
		return nif_pull_wildcard(env, db, cur, is_root, visited)
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
				it := xitdb.cursor_iterator(cur) or_return
				for {
					next_maybe := xitdb.cursor_iterator_next(&it) or_return
					elem_cur, ok := next_maybe.?
					if !ok {
						break
					}
					key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
					k_str := xitdb.cursor_read_string(key_cur, 0, context.temp_allocator) or_return
					if is_root && k_str == "__tx" {
						continue
					}
					v, v_reason, v_err := nif_pull_wildcard(env, db, val_cur, false, visited)
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
				pr, pr_reason, pr_err := nif_pull_range(env, db, target_cur, range_start, range_end, sub_pattern, visited)
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
					pulled = slot_to_term(env, db, t_slot) or_return
				} else {
					pc, pc_reason, pc_err := nif_pull_cursor(env, db, target_cur, sub_pattern, false, visited)
					if pc_err != nil {
						return 0, "", pc_err
					}
					if pc_reason != "" {
						return 0, pc_reason, nil
					}
					pulled = pc
				}
			} else {
				pc, pc_reason, pc_err := nif_pull_cursor(env, db, target_cur, sub_pattern, false, visited)
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
<summary>NIF <code>nif_pull_wildcard</code> — <a href="../../native/xitdb_nif.odin#L5234-L5326">native/xitdb_nif.odin#L5234-L5326</a></summary>

```odin
nif_pull_wildcard :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	cur: xitdb.Read_Cursor,
	is_root: bool,
	visited: ^map[i64]bool,
) -> (res: ERL_NIF_TERM, err_reason: string, err: xitdb.Error) {
	slot := xitdb.cursor_slot(cur) or_return
	if !is_container_tag(slot.tag) {
		term := slot_to_term(env, db, slot) or_return
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
		it := xitdb.cursor_iterator(cur) or_return
		items := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			v, v_reason, v_err := nif_pull_wildcard(env, db, elem_cur, false, visited)
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
		it := xitdb.cursor_iterator(cur) or_return
		items := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			v := slot_to_term(env, db, key_cur.slot_ptr.slot) or_return
			append(&items, v)
		}
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), "", nil
		}
		return nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))), "", nil

	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := xitdb.cursor_iterator(cur) or_return
		keys := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		vals := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			k_str := xitdb.cursor_read_string(key_cur, 0, context.temp_allocator) or_return
			if is_root && k_str == "__tx" {
				continue
			}
			v, v_reason, v_err := nif_pull_wildcard(env, db, val_cur, false, visited)
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
<summary>NIF <code>split_top_level_pull_specs</code> — <a href="../../native/xitdb_nif.odin#L5122-L5164">native/xitdb_nif.odin#L5122-L5164</a></summary>

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
<summary>NIF <code>find_top_level_pull_brace</code> — <a href="../../native/xitdb_nif.odin#L5174-L5205">native/xitdb_nif.odin#L5174-L5205</a></summary>

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

<details>
<summary>NIF <code>find_last_unquoted_lbracket</code> — <a href="../../native/xitdb_nif.odin#L5207-L5230">native/xitdb_nif.odin#L5207-L5230</a></summary>

```odin
find_last_unquoted_lbracket :: proc(s: string) -> int {
	in_quote: u8 = 0
	last_idx := -1
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
		if ch == '"' || ch == '\'' {
			in_quote = ch
		} else if ch == '[' {
			last_idx = i
		}
		i += 1
	}
```

</details>

<details>
<summary>NIF <code>is_simple_hash_map_ident</code> — <a href="../../native/xitdb_nif.odin#L5328-L5342">native/xitdb_nif.odin#L5328-L5342</a></summary>

```odin
is_simple_hash_map_ident :: proc(s: string) -> (string, bool) {
	p := s
	if len(p) > 0 && p[0] == '.' {
		p = p[1:]
	}
	if len(p) == 0 {
		return "", false
	}
	for i := 0; i < len(p); i += 1 {
		ch := p[i]
		if ch == '.' || ch == '[' || ch == ']' || ch == '#' || ch == '$' || ch == '%' || ch == '^' ||
		   ch == '"' || ch == '\'' || ch == '\\' || ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
			return "", false
		}
	}
```

</details>

<details>
<summary>NIF <code>parse_escaped_steps</code> — <a href="../../native/xitdb_nif.odin#L1893-L1905">native/xitdb_nif.odin#L1893-L1905</a></summary>

```odin
parse_escaped_steps :: proc(path_str: string, allocator := context.temp_allocator) -> (res: []xitdb.Path_Step, err_reason: string) {
	stack_buf: [16]xitdb.Path_Step = ---
	steps, er := parse_escaped_steps_buf(path_str, stack_buf[:], allocator)
	if er != "" || len(steps) == 0 {
		return steps, er
	}
	if raw_data(steps) == raw_data(stack_buf[:]) {
		out := make([]xitdb.Path_Step, len(steps), allocator)
		copy(out, steps)
		return out, ""
	}
	return steps, ""
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
<summary><code>xitdb.pull</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L1714-L1724">dsl.odin#L1714-L1724</a></summary>

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
	return _pull_with_visited(cursor, pattern, &visited, allocator)
}
```

</details>

<details>
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L62-L65">cursor.odin#L62-L65</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L842-L886">cursor.odin#L842-L886</a></summary>

```odin
cursor_iterator :: proc(unresolved_cursor: Read_Cursor) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor

	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		res.size = 0
		res.index = 0
	case .Array_List:
		position := cursor.slot_ptr.slot.value
		hb: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
		core_read_exact_at(cursor.db.core, position, hb[:]) or_return
		header := array_list_header_from_bytes(hb) or_return
		res.size = header.size
		res.index = 0
		if header.size > 0 {
			_init_iter_level(cursor, header.ptr, &res.stack[0]) or_return
			res.stack_len = 1
		}
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		position := cursor.slot_ptr.slot.value
		hb: [BTREE_HEADER_LENGTH]u8 = ---
		core_read_exact_at(cursor.db.core, position, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		res.size = header.size
		res.index = 0
		if header.size > 0 {
			_init_btree_iter_level(cursor, header.root_ptr, &res.stack[0]) or_return
			res.stack_len = 1
		}
	case .Hash_Map, .Hash_Set:
		res.size = 0
		res.index = 0
		_init_iter_level(cursor, cursor.slot_ptr.slot.value, &res.stack[0]) or_return
		res.stack_len = 1
	case .Counted_Hash_Map, .Counted_Hash_Set:
		res.size = 0
		res.index = 0
		_init_iter_level(cursor, cursor.slot_ptr.slot.value + 8, &res.stack[0]) or_return
		res.stack_len = 1
	case:
		return {}, .Unexpected_Tag
	}
	return res, nil
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

<details>
<summary><code>xitdb.cursor_read_kv_pair_slots</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L381-L402">cursor.odin#L381-L402</a></summary>

```odin
cursor_read_kv_pair_slots :: proc(c: Read_Cursor) -> (key_cursor: Read_Cursor, value_cursor: Read_Cursor, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if is_key_only_entry(slot_ptr.slot) {
		return Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = slot_ptr.slot}, db = c.db, frozen_at = c.frozen_at},
			Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = Slot{}}, db = c.db, frozen_at = c.frozen_at},
			nil
	}
	if slot_ptr.slot.tag != .KV_Pair && slot_ptr.slot.tag != .Sorted_KV_Pair {
		return {}, {}, .Unexpected_Tag
	}
	key_pos := slot_ptr.slot.value + database_kv_key_offset(c.db, slot_ptr.slot.tag)
	val_pos := key_pos + SLOT_LENGTH
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
<summary><code>xitdb.cursor_read_string</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L233-L236">cursor.odin#L233-L236</a></summary>

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
<summary><code>xitdb.read_steps_cursor</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L317-L407">dsl.odin#L317-L407</a></summary>

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
<summary><code>xitdb.database_digest_string_buf</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L267-L269">database.odin#L267-L269</a></summary>

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
