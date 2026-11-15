# #2: `Access: Single-call selector select(.users.<id>.name)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `access` — #1–#5 (Lazy Access Navigation & Point Lookups)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 2.25 µs (2254.0 ns) | 1.06 µs (1061.0 ns) | **`2.12x`** NIF Ratio |
| **Mean ± σ (CV)** | 2.25 µs ± 22.5 ns (1.0%) | 1.06 µs ± 10.8 ns (1.0%) | Welch `z` = `106.80` |
| **p95 / Max (`ns/op`)** | 2.28 µs / 2.29 µs | 1.07 µs / 1.07 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L200-L207`](../bench_elixir.exs#L200-L207))

```elixir
      {2, "Access: Single-call selector select(.users.<id>.name)", 500,
       fn ->
         for i <- 0..499 do
           _ = Xitdb.select!(db, ".users.u#{i}.name")
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L769-L783`](../bench_client.odin#L769-L783))

```odin
	// #2: Single-call selector
	if r2 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for i in 0 ..< 500 {
				sel := fmt.tprintf("@-1.users.u%d.name", i)
				_, _ = xitdb.get_string(&db, sel, context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(2, "Access: Single-call selector select(.users.<id>.name)", 500, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>select</code> — <a href="../../lib/xitdb.ex#L542-L557">lib/xitdb.ex#L542-L557</a></summary>

```elixir
  def select(%__MODULE__{db_ref: db_ref}, selector) when is_binary(selector) do
    do_select(db_ref, -1, selector)
  end

  def select(%Cursor{root: true, tx_mode: false, db_ref: db_ref, moment: moment}, selector)
      when is_binary(selector) do
    do_select(db_ref, moment, selector)
  end

  def select(%Cursor{tag: tag, tx_mode: tx_mode}, selector) when is_binary(selector) do
    {:error,
     %Error{
       reason: :non_root_cursor,
       details: %{tag: tag, tx_mode: tx_mode, selector: selector}
     }}
  end
```

</details>

<details>
<summary>Elixir <code>do_select</code> — <a href="../../lib/xitdb.ex#L559-L564">lib/xitdb.ex#L559-L564</a></summary>

```elixir
  defp do_select(db_ref, moment, selector) do
    case NIF.nif_select(db_ref, moment, selector) do
      {:ok, raw} -> {:ok, Cursor.unwrap_nif_value(db_ref, raw, moment, [])}
      {:error, reason} -> {:error, %Error{reason: reason, details: %{selector: selector}}}
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_select</code> — <a href="../../native/xitdb_nif.odin#L2864-L2942">native/xitdb_nif.odin#L2864-L2942</a></summary>

```odin
odin_nif_select :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
		return make_err(env, "badarg")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}
	sel_str, ok_s := get_string_from_binary(env, argv[2])
	if !ok_s {
		return make_err(env, "badarg")
	}

	parsed, p_err := parse_escaped_selector(sel_str, context.temp_allocator)
	if p_err != "" {
		return make_err(env, p_err)
	}
	effective_moment := parsed.moment_index if parsed.has_moment else moment_idx

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	m_slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, -1, effective_moment)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		if len(parsed.steps) > 0 {
			return make_ok(env, ATOM_NIL)
		}
		return make_ok(env, nif_make_tuple5(
			env,
			ATOM_CURSOR,
			TAG_ATOMS[u8(xitdb.Tag.Hash_Map)],
			nif_make_int64(env, i64(u8(xitdb.Tag.Hash_Map))),
			nif_make_int64(env, 0),
			nif_make_int64(env, 0),
		))
	}

	m_cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = m_slot},
		db       = &handle.db,
	}
	cur := m_cur
	if len(parsed.steps) > 0 {
		cur_maybe, err := xitdb.read_steps_cursor(m_cur, parsed.steps)
		if err != nil {
			if err == .Unexpected_Tag {
				return make_ok(env, ATOM_NIL)
			}
			return make_xitdb_err(env, err)
		}
		found_cur, found := cur_maybe.?
		if !found {
			return make_ok(env, ATOM_NIL)
		}
		cur = found_cur
	}

	slot, s_err := xitdb.cursor_slot(cur)
	if s_err != nil {
		return make_xitdb_err(env, s_err)
	}
	term, t_err := slot_to_term(env, &handle.db, slot)
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	return make_ok(env, term)
}
```

</details>

<details>
<summary>NIF <code>parse_escaped_selector</code> — <a href="../../native/xitdb_nif.odin#L1739-L1770">native/xitdb_nif.odin#L1739-L1770</a></summary>

```odin
parse_escaped_selector :: proc(sel_str: string, allocator := context.temp_allocator) -> (res: xitdb.Parsed_Selector, err_reason: string) {
	s := strings.trim_space(sel_str)
	if len(s) == 0 {
		return {}, ""
	}
	i := 0
	if s[i] == '@' {
		i += 1
		start := i
		if i < len(s) && s[i] == '-' {
			i += 1
		}
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i += 1
		}
		if i == start || (i == start + 1 && s[start] == '-') {
			return {}, "invalid_selector"
		}
		m_idx, ok := strconv.parse_i64(s[start:i])
		if !ok {
			return {}, "invalid_selector"
		}
		res.has_moment = true
		res.moment_index = m_idx
	}
	steps, er := parse_escaped_steps(s[i:], allocator)
	if er != "" {
		return {}, er
	}
	res.steps = steps
	return res, ""
}
```

</details>

<details>
<summary>NIF <code>slot_to_term</code> — <a href="../../native/xitdb_nif.odin#L289-L347">native/xitdb_nif.odin#L289-L347</a></summary>

```odin
slot_to_term :: proc(env: ErlNifEnv, db: ^xitdb.Database, slot: xitdb.Slot) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
	if slot.tag == .None && !slot.full {
		return ATOM_NIL, nil
	}
	if is_container_tag(slot.tag) {
		tag_u8 := u8(slot.tag)
		// Return {:cursor, tag_atom, tag_int, slot_value, full_int}
		return nif_make_tuple5(
			env,
			ATOM_CURSOR,
			TAG_ATOMS[tag_u8],
			nif_make_int64(env, i64(tag_u8)),
			nif_make_int64(env, slot.value),
			nif_make_int64(env, 1 if slot.full else 0),
		), nil
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	#partial switch slot.tag {
	case .Uint:
		u := xitdb.cursor_read_uint(cur) or_return
		return nif_make_uint64(env, u), nil
	case .Int:
		i := xitdb.cursor_read_int(cur) or_return
		return nif_make_int64(env, i), nil
	case .Float:
		f := xitdb.cursor_read_float(cur) or_return
		return nif_make_double(env, f), nil
	case .Short_Bytes, .Bytes:
		if slot.full {
			obj := xitdb.cursor_read_bytes_object(cur, 0, context.temp_allocator) or_return
			if len(obj.format_tag) == 2 && obj.format_tag[0] == 'b' && obj.format_tag[1] == 'l' {
				if len(obj.value) == 1 && obj.value[0] == '1' {
					return ATOM_TRUE, nil
				}
				return ATOM_FALSE, nil
			}
			return nif_make_tuple3(
				env,
				ATOM_TAGGED,
				make_bytes_binary(env, obj.format_tag),
				make_bytes_binary(env, obj.value),
			), nil
		}
		if slot.tag == .Short_Bytes {
			sb_buf: [8]u8 = ---
			b_obj := xitdb.cursor_read_bytes_buf(cur, sb_buf[:]) or_return
			return make_bytes_binary(env, b_obj.value), nil
		}
		b := xitdb.cursor_read_bytes(cur, 0, context.temp_allocator) or_return
		return make_bytes_binary(env, b), nil
	}

	return ATOM_NIL, nil
}
```

</details>

<details>
<summary>NIF <code>parse_escaped_steps</code> — <a href="../../native/xitdb_nif.odin#L1613-L1734">native/xitdb_nif.odin#L1613-L1734</a></summary>

```odin
parse_escaped_steps :: proc(path_str: string, allocator := context.temp_allocator) -> (res: []xitdb.Path_Step, err_reason: string) {
	s := strings.trim_space(path_str)
	if len(s) == 0 {
		return nil, ""
	}
	steps := make([dynamic]xitdb.Path_Step, 0, 8, allocator)
	i := 0

	for i < len(s) {
		ch := s[i]
		switch ch {
		case '.':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Map_Key, key = key})
			i = next_i

		case '#':
			i += 1
			kind := xitdb.Step_Kind.Counted_Hash_Map_Key
			if i < len(s) && s[i] == '%' {
				kind = .Counted_Set_Member
				i += 1
			}
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = kind, key = key})
			i = next_i

		case '$':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Sorted_Map_Key, key = key})
			i = next_i

		case '%':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Set_Member, key = key})
			i = next_i

		case '^':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Sorted_Set_Member, key = key})
			i = next_i

		case '[':
			if i + 1 < len(s) && s[i + 1] == '[' {
				i += 2
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i + 1 >= len(s) || s[i] != ']' || s[i + 1] != ']' {
					return nil, "invalid_selector"
				}
				idx_str := strings.trim_space(s[start:i])
				idx, ok := strconv.parse_i64(idx_str)
				if !ok {
					return nil, "invalid_selector"
				}
				append(&steps, xitdb.Path_Step{kind = .Linked_List_Idx, index = idx})
				i += 2
			} else if i + 1 < len(s) && (s[i + 1] == '"' || s[i + 1] == '\'') {
				key, next_i, er := parse_escaped_bracketed_string(s, i, allocator)
				if er != "" {
					return nil, er
				}
				step_kind := xitdb.Step_Kind.Hash_Map_Key
				if len(steps) == 1 {
					if steps[0].kind == .Counted_Hash_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Counted_Hash_Map_Key
					} else if steps[0].kind == .Sorted_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Sorted_Map_Key
					}
				}
				append(&steps, xitdb.Path_Step{kind = step_kind, key = key})
				i = next_i
			} else {
				i += 1
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i >= len(s) || s[i] != ']' {
					return nil, "invalid_selector"
				}
				idx_str := strings.trim_space(s[start:i])
				idx, ok := strconv.parse_i64(idx_str)
				if !ok {
					return nil, "invalid_selector"
				}
				append(&steps, xitdb.Path_Step{kind = .Array_List_Idx, index = idx})
				i += 1
			}

		case:
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Map_Key, key = key})
			i = next_i
		}
	}
```

</details>

<details>
<summary>NIF <code>parse_escaped_ident_or_bracket</code> — <a href="../../native/xitdb_nif.odin#L1589-L1598">native/xitdb_nif.odin#L1589-L1598</a></summary>

```odin
parse_escaped_ident_or_bracket :: proc(s: string, start_i: int, allocator: runtime.Allocator) -> (key: string, next_i: int, err_reason: string) {
	if start_i >= len(s) {
		return "", start_i, "invalid_selector"
	}
	if s[start_i] == '[' {
		return parse_escaped_bracketed_string(s, start_i, allocator)
	}
	if s[start_i] == '"' || s[start_i] == '\'' {
		return parse_escaped_quoted(s, start_i, allocator)
	}
```

</details>

<details>
<summary>NIF <code>parse_escaped_bracketed_string</code> — <a href="../../native/xitdb_nif.odin#L1571-L1578">native/xitdb_nif.odin#L1571-L1578</a></summary>

```odin
parse_escaped_bracketed_string :: proc(s: string, start_i: int, allocator: runtime.Allocator) -> (key: string, next_i: int, err_reason: string) {
	if start_i + 2 >= len(s) || s[start_i] != '[' {
		return "", 0, "invalid_selector"
	}
	quote := s[start_i + 1]
	if quote != '"' && quote != '\'' {
		return "", 0, "invalid_selector"
	}
```

</details>

<details>
<summary>NIF <code>parse_escaped_quoted</code> — <a href="../../native/xitdb_nif.odin#L1512-L1519">native/xitdb_nif.odin#L1512-L1519</a></summary>

```odin
parse_escaped_quoted :: proc(s: string, quote_i: int, allocator: runtime.Allocator) -> (key: string, next_i: int, err_reason: string) {
	if quote_i >= len(s) {
		return "", 0, "invalid_selector"
	}
	quote := s[quote_i]
	if quote != '"' && quote != '\'' {
		return "", 0, "invalid_selector"
	}
```

</details>

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.get_string</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L426-L433">dsl.odin#L426-L433</a></summary>

```odin
get_string :: proc(db: ^Database, selector: string, allocator := context.temp_allocator) -> (res: string, err: Error) {
	cur_maybe := select_cursor(db, selector) or_return
	cur, ok := cur_maybe.?
	if !ok {
		return "", .Key_Not_Found
	}
	return cursor_read_string(cur, 0, allocator)
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
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L62-L65">cursor.odin#L62-L65</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_uint</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L198-L207">cursor.odin#L198-L207</a></summary>

```odin
cursor_read_uint :: proc(c: Read_Cursor) -> (res: u64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if slot_ptr.slot.tag != .Uint {
		return 0, .Unexpected_Tag
	}
	if slot_ptr.slot.value < 0 {
		return 0, .Expected_Unsigned_Long
	}
	return u64(slot_ptr.slot.value), nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_int</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L209-L215">cursor.odin#L209-L215</a></summary>

```odin
cursor_read_int :: proc(c: Read_Cursor) -> (res: i64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if slot_ptr.slot.tag != .Int {
		return 0, .Unexpected_Tag
	}
	return slot_ptr.slot.value, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_float</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L217-L223">cursor.odin#L217-L223</a></summary>

```odin
cursor_read_float :: proc(c: Read_Cursor) -> (res: f64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if slot_ptr.slot.tag != .Float {
		return 0, .Unexpected_Tag
	}
	return transmute(f64)slot_ptr.slot.value, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_bytes_object</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L238-L292">cursor.odin#L238-L292</a></summary>

```odin
cursor_read_bytes_object :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: Bytes, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .None:
		return Bytes{value = make([]u8, 0, allocator)}, nil

	case .Bytes:
		value_size := core_read_long_at(c.db.core, slot_ptr.slot.value) or_return
		if max_size > 0 && value_size > max_size {
			return {}, .Stream_Too_Long
		}
		value := make([]u8, int(value_size), allocator)
		err := core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, value)
		if err != nil {
			delete(value, allocator)
			return {}, err
		}
		format_tag: []u8
		if slot_ptr.slot.full {
			format_tag = make([]u8, 2, allocator)
			if ft_err := core_read_exact_at(c.db.core, slot_ptr.slot.value + 8 + value_size, format_tag); ft_err != nil {
				delete(value, allocator)
				delete(format_tag, allocator)
				return {}, ft_err
			}
		}
		return Bytes{value = value, format_tag = format_tag}, nil

	case .Short_Bytes:
		buf: [8]u8
		endian.unchecked_put_u64be(buf[:], u64(slot_ptr.slot.value))
		total_size: i64 = 6 if slot_ptr.slot.full else 8
		value_size: i64 = 0
		for b in buf {
			if b == 0 || value_size == total_size {
				break
			}
			value_size += 1
		}
		if max_size > 0 && value_size > max_size {
			return {}, .Stream_Too_Long
		}
		format_tag: []u8
		if slot_ptr.slot.full {
			format_tag = make([]u8, 2, allocator)
			copy(format_tag, buf[total_size : total_size + 2])
		}
		value := make([]u8, int(value_size), allocator)
		copy(value, buf[:value_size])
		return Bytes{value = value, format_tag = format_tag}, nil

	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_bytes_buf</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L294-L359">cursor.odin#L294-L359</a></summary>

```odin
cursor_read_bytes_buf :: proc(c: Read_Cursor, buffer: []u8) -> (res: Bytes, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .None:
		if len(buffer) == 0 {
			return Bytes{value = buffer}, nil
		}
		return {}, .End_Of_Stream

	case .Bytes:
		value_size := core_read_long_at(c.db.core, slot_ptr.slot.value) or_return
		if value_size > i64(len(buffer)) {
			return {}, .Stream_Too_Long
		}
		if slot_ptr.slot.full {
			if value_size + 2 <= i64(len(buffer)) {
				combined := buffer[:value_size + 2]
				core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, combined) or_return
				return Bytes{
					value      = combined[:value_size],
					format_tag = combined[value_size : value_size + 2],
				}, nil
			}
			value := buffer[:value_size]
			core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, value) or_return
			ft := make([]u8, 2, context.temp_allocator)
			core_read_exact_at(c.db.core, slot_ptr.slot.value + 8 + value_size, ft) or_return
			return Bytes{value = value, format_tag = ft}, nil
		}
		value := buffer[:value_size]
		core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, value) or_return
		return Bytes{value = value}, nil

	case .Short_Bytes:
		buf: [8]u8
		endian.unchecked_put_u64be(buf[:], u64(slot_ptr.slot.value))
		total_size: i64 = 6 if slot_ptr.slot.full else 8
		value_size: i64 = 0
		for b in buf {
			if b == 0 || value_size == total_size {
				break
			}
			value_size += 1
		}
		if value_size > i64(len(buffer)) {
			return {}, .Stream_Too_Long
		}
		copy(buffer[:value_size], buf[:value_size])
		format_tag: []u8
		if slot_ptr.slot.full {
			if value_size + 2 <= i64(len(buffer)) {
				buffer[value_size] = buf[total_size]
				buffer[value_size + 1] = buf[total_size + 1]
				format_tag = buffer[value_size : value_size + 2]
			} else {
				ft := make([]u8, 2, context.temp_allocator)
				copy(ft, buf[total_size : total_size + 2])
				format_tag = ft
			}
		}
		return Bytes{value = buffer[:value_size], format_tag = format_tag}, nil

	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_bytes</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L225-L231">cursor.odin#L225-L231</a></summary>

```odin
cursor_read_bytes :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: []u8, err: Error) {
	obj := cursor_read_bytes_object(c, max_size, allocator) or_return
	if obj.format_tag != nil {
		delete(obj.format_tag, allocator)
	}
	return obj.value, nil
}
```

</details>

<details>
<summary><code>xitdb.select_cursor</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L410-L424">dsl.odin#L410-L424</a></summary>

```odin
select_cursor :: proc(db: ^Database, selector: string) -> (res: Maybe(Read_Cursor), err: Error) {
	parsed := parse_selector(selector, context.temp_allocator) or_return
	rc := database_root_cursor(db).read_cursor
	start := rc
	if parsed.has_moment {
		history := read_array_list_init(rc) or_return
		mc_maybe := array_list_get_cursor(history, parsed.moment_index) or_return
		mc, ok := mc_maybe.?
		if !ok {
			return nil, nil
		}
		start = mc
	}
	return read_steps_cursor(start, parsed.steps)
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
