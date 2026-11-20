# #18: `Time-Travel: history_of(db, selector) (100 moments)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `time_travel` — #17–#20 (Historical as_of, history_of, diff_moments & Compaction)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 54.75 µs (54750.0 ns) | 31.20 µs (31200.0 ns) | **`1.75x`** NIF Ratio |
| **Mean ± σ (CV)** | 56.23 µs ± 8.24 µs (14.6%) | 31.26 µs ± 192.0 ns (0.6%) | Welch `z` = `6.78` |
| **p95 / Max (`ns/op`)** | 66.55 µs / 68.08 µs | 31.52 µs / 31.59 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L418-L425`](../bench_elixir.exs#L418-L425))

```elixir
      {18, "Time-Travel: history_of(db, selector) (100 moments)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _} = Xitdb.history_of(hist_db, ".users.alice.score")
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1236-L1249`](../bench_client.odin#L1236-L1249))

```odin
	// #18: Time-Travel history_of(db, selector) lineage across 100 moments
	if r18 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				_, _ = xitdb.history_of(&hist_db, ".users.alice.score", context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(18, "Time-Travel: history_of(db, selector) (100 moments)", 50, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>history_of</code> — <a href="../../lib/xitdb.ex#L835-L838">lib/xitdb.ex#L835-L838</a></summary>

```elixir
  def history_of(%__MODULE__{db_ref: db_ref}, selector)
      when is_binary(selector) or is_list(selector) do
    db_ref |> NIF.nif_history_of(selector) |> Error.wrap(%{selector: selector})
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_history_of</code> — <a href="../../native/xitdb_nif.odin#L6046-L6212">native/xitdb_nif.odin#L6046-L6212</a></summary>

```odin
odin_nif_history_of :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 2 {
		return make_err(env, "badarg")
	}

	step_buf: [16]xitdb.Path_Step = ---
	parsed, p_err, ok_s := decode_selector_term_buf(env, argv[1], step_buf[:], context.temp_allocator)
	if !ok_s {
		return make_err(env, "badarg")
	}
	if p_err != "" || parsed.has_moment || len(parsed.steps) == 0 {
		return make_err(env, "invalid_selector")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	rc := xitdb.database_root_cursor(&handle.db).read_cursor
	root_slot, rs_err := xitdb.cursor_slot(rc)
	if rs_err != nil {
		return make_xitdb_err(env, rs_err)
	}
	if root_slot.tag == .None || root_slot.value == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}

	history, h_err := xitdb.read_array_list_init(rc)
	if h_err != nil {
		return make_xitdb_err(env, h_err)
	}
	it, it_err := xitdb.cursor_iterator(history.cursor)
	if it_err != nil {
		return make_xitdb_err(env, it_err)
	}

	tx_hash_buf: [64]u8 = ---
	doc_hash_buf: [64]u8 = ---
	inst_hash_buf: [64]u8 = ---
	tx_hash := xitdb.database_digest_string_buf(&handle.db, "__tx", tx_hash_buf[:])
	doc_hash := xitdb.database_digest_string_buf(&handle.db, "doc", doc_hash_buf[:])
	inst_hash := xitdb.database_digest_string_buf(&handle.db, "tx_instant", inst_hash_buf[:])

	inline_hash_bufs: [16][64]u8 = ---
	inline_hashes: [16][]u8 = ---
	step_hash_bufs: [][64]u8
	step_hashes: [][]u8
	if len(parsed.steps) <= len(inline_hash_bufs) {
		step_hash_bufs = inline_hash_bufs[:len(parsed.steps)]
		step_hashes = inline_hashes[:len(parsed.steps)]
	} else {
		step_hash_bufs = make([][64]u8, len(parsed.steps), context.temp_allocator)
		step_hashes = make([][]u8, len(parsed.steps), context.temp_allocator)
	}
	xitdb.precompute_step_hashes(&handle.db, parsed.steps, step_hash_bufs, step_hashes)

	keys := [4]ERL_NIF_TERM{
		ATOM_MOMENT_INDEX,
		ATOM_VALUE,
		ATOM_DOC,
		ATOM_INSTANT,
	}
	empty_doc_term := make_binary(env, "")
	zero_inst_term := nif_make_int64(env, 0)
	items := make([dynamic]ERL_NIF_TERM, 0, 8, context.temp_allocator)
	prev_slot := xitdb.Slot{}

	for {
		mc_maybe, next_err := xitdb.cursor_iterator_next(&it)
		if next_err != nil {
			return make_xitdb_err(env, next_err)
		}
		mc, has_mc := mc_maybe.?
		if !has_mc {
			break
		}
		m_idx := it.index - 1

		cur_slot, s_err := xitdb.read_prehashed_steps_slot(mc, parsed.steps, step_hashes, true)
		if s_err != nil {
			if s_err == .Unexpected_Tag {
				cur_slot = xitdb.Slot{}
			} else {
				return make_xitdb_err(env, s_err)
			}
		}

		if cur_slot != prev_slot {
			doc_term := empty_doc_term
			inst_term := zero_inst_term
			m_map, mm_err := xitdb.read_hash_map_init(mc)
			if mm_err != nil {
				return make_xitdb_err(env, mm_err)
			}
			tx_maybe, tx_err := xitdb.hash_map_get_cursor_by_hash(m_map, tx_hash)
			if tx_err != nil {
				return make_xitdb_err(env, tx_err)
			}
			if tx_cur, has_tx := tx_maybe.?; has_tx {
				tx_map, tm_err := xitdb.read_hash_map_init(tx_cur)
				if tm_err != nil {
					return make_xitdb_err(env, tm_err)
				}
				d_maybe, d_err := xitdb.hash_map_get_cursor_by_hash(tx_map, doc_hash)
				if d_err != nil {
					return make_xitdb_err(env, d_err)
				}
				if d_cur, has_d := d_maybe.?; has_d {
					ds, ds_err := xitdb.cursor_read_string(d_cur, 0, context.temp_allocator)
					if ds_err != nil {
						return make_xitdb_err(env, ds_err)
					}
					if len(ds) > 0 {
						doc_term = make_binary(env, ds)
					}
				}
				i_maybe, i_err := xitdb.hash_map_get_cursor_by_hash(tx_map, inst_hash)
				if i_err != nil {
					return make_xitdb_err(env, i_err)
				}
				if i_cur, has_i := i_maybe.?; has_i {
					islot := i_cur.slot_ptr.slot
					if islot.tag == .Int {
						iv, iv_err := xitdb.cursor_read_int(i_cur)
						if iv_err != nil {
							return make_xitdb_err(env, iv_err)
						}
						if iv != 0 {
							inst_term = nif_make_int64(env, iv)
						}
					} else if islot.tag == .Uint {
						uv, uv_err := xitdb.cursor_read_uint(i_cur)
						if uv_err != nil {
							return make_xitdb_err(env, uv_err)
						}
						if uv != 0 {
							inst_term = nif_make_int64(env, i64(uv))
						}
					}
				}
			}

			val_term, m_err := materialize_slot(env, &handle.db, cur_slot, false)
			if m_err != nil {
				return make_xitdb_err(env, m_err)
			}
			vals := [4]ERL_NIF_TERM{
				nif_make_int64(env, m_idx),
				val_term,
				doc_term,
				inst_term,
			}
			append(&items, make_map_safe(env, keys[:], vals[:]))
			prev_slot = cur_slot
		}
	}

	if len(items) == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))))
}
```

</details>

<details>
<summary>NIF <code>decode_selector_term_buf</code> — <a href="../../native/xitdb_nif.odin#L2276-L2372">native/xitdb_nif.odin#L2276-L2372</a></summary>

```odin
decode_selector_term_buf :: proc(
	env: ErlNifEnv,
	term: ERL_NIF_TERM,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: xitdb.Parsed_Selector, err_reason: string, term_ok: bool) {
	if nif_is_binary(env, term) != 0 {
		sel_str, ok_s := get_string_from_binary(env, term)
		if !ok_s {
			return {}, "", false
		}
		parsed, er := parse_escaped_selector_buf(sel_str, buf, allocator)
		return parsed, er, true
	}
	if nif_is_list(env, term) != 0 {
		raw_buf: [17]Nif_Raw_Step = ---
		raw_count: c.int = 0
		rc := nif_unpack_step_list(env, term, &raw_buf[0], 17, &raw_count)
		if rc == -3 {
			return {}, "invalid_selector", true
		}
		if rc == 0 {
			raw_slice := raw_buf[:int(raw_count)]
			if len(raw_slice) == 0 {
				return xitdb.Parsed_Selector{}, "", true
			}
			is_at_moment := (raw_slice[0].kind_code >= 3 && raw_slice[0].kind_code <= 5) && raw_slice[0].tag_term == ATOM_AT_MOMENT
			if is_at_moment {
				if raw_slice[0].kind_code != 4 {
					return {}, "invalid_selector", true
				}
				sub := raw_slice[1:]
				if len(sub) <= len(buf) {
					steps, er := convert_raw_steps_buf(env, sub, buf, allocator)
					if er != "" {
						return {}, er, true
					}
					return xitdb.Parsed_Selector{
						has_moment   = true,
						moment_index = raw_slice[0].index_val,
						steps        = steps,
					}, "", true
				}
			} else if len(raw_slice) <= len(buf) {
				steps, er := convert_raw_steps_buf(env, raw_slice, buf, allocator)
				if er != "" {
					return {}, er, true
				}
				return xitdb.Parsed_Selector{steps = steps}, "", true
			}
		}

		head: ERL_NIF_TERM = 0
		tail: ERL_NIF_TERM = 0
		if nif_get_list_cell(env, term, &head, &tail) == 0 {
			if nif_is_empty_list(env, term) != 0 {
				return xitdb.Parsed_Selector{}, "", true
			}
			return {}, "invalid_selector", true
		}

		parsed := xitdb.Parsed_Selector{}
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, head, &arity, &elems) != 0 && arity == 2 && elems[0] == ATOM_AT_MOMENT {
			m_idx: i64 = 0
			if nif_get_int64(env, elems[1], &m_idx) == 0 {
				return {}, "invalid_selector", true
			}
			parsed.has_moment = true
			parsed.moment_index = m_idx
			steps, er := decode_steps_list_buf(env, tail, buf, allocator)
			if er != "" {
				return {}, er, true
			}
			parsed.steps = steps
			return parsed, "", true
		}

		first_step, s_err := decode_one_step_term(env, head, allocator)
		if s_err != "" {
			return {}, s_err, true
		}
		buf_len := 0
		dyn: [dynamic]xitdb.Path_Step
		using_dyn := false
		push_path_step(buf, &buf_len, &dyn, &using_dyn, first_step, allocator)

		steps, er := decode_steps_list_tail_buf(env, tail, buf, buf_len, &dyn, using_dyn, allocator)
		if er != "" {
			return {}, er, true
		}
		parsed.steps = steps
		return parsed, "", true
	}
	return {}, "", false
}
```

</details>

<details>
<summary>NIF <code>materialize_slot</code> — <a href="../../native/xitdb_nif.odin#L560-L642">native/xitdb_nif.odin#L560-L642</a></summary>

```odin
materialize_slot :: proc(env: ErlNifEnv, db: ^xitdb.Database, slot: xitdb.Slot, is_root: bool = false) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
	if !is_container_tag(slot.tag) {
		return slot_to_term(env, db, slot)
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List:
		it := xitdb.cursor_iterator(cur) or_return
		item_buf: [16]ERL_NIF_TERM = ---
		item_len := 0
		item_dyn: [dynamic]ERL_NIF_TERM
		using_dyn := false
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			elem_slot := xitdb.cursor_slot(elem_cur) or_return
			term := materialize_slot(env, db, elem_slot, false) or_return
			push_nif_term(item_buf[:], &item_len, &item_dyn, &using_dyn, term, context.temp_allocator)
		}
		items := item_dyn[:] if using_dyn else item_buf[:item_len]
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), nil
		}
		return nif_make_list_from_array(env, raw_data(items), c.uint(len(items))), nil

	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		it := xitdb.cursor_iterator(cur) or_return
		item_buf: [16]ERL_NIF_TERM = ---
		item_len := 0
		item_dyn: [dynamic]ERL_NIF_TERM
		using_dyn := false
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			term := slot_to_term(env, db, key_cur.slot_ptr.slot) or_return
			push_nif_term(item_buf[:], &item_len, &item_dyn, &using_dyn, term, context.temp_allocator)
		}
		items := item_dyn[:] if using_dyn else item_buf[:item_len]
		return make_mapset_term(env, items), nil

	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := xitdb.cursor_iterator(cur) or_return
		key_buf: [16]ERL_NIF_TERM = ---
		val_buf: [16]ERL_NIF_TERM = ---
		key_len, val_len := 0, 0
		key_dyn, val_dyn: [dynamic]ERL_NIF_TERM
		using_key_dyn, using_val_dyn := false, false
		sb_buf: [128]u8 = ---
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			key_str := read_key_cursor_string(key_cur, sb_buf[:]) or_return
			if is_root && key_str == "__tx" {
				continue
			}
			k_term := make_binary(env, key_str)
			v_term := materialize_slot(env, db, val_cur.slot_ptr.slot, false) or_return
			push_nif_term(key_buf[:], &key_len, &key_dyn, &using_key_dyn, k_term, context.temp_allocator)
			push_nif_term(val_buf[:], &val_len, &val_dyn, &using_val_dyn, v_term, context.temp_allocator)
		}
		keys := key_dyn[:] if using_key_dyn else key_buf[:key_len]
		vals := val_dyn[:] if using_val_dyn else val_buf[:val_len]
		return make_map_safe(env, keys, vals), nil
	}

	return ATOM_NIL, nil
}
```

</details>

<details>
<summary>NIF <code>parse_escaped_selector_buf</code> — <a href="../../native/xitdb_nif.odin#L1952-L1987">native/xitdb_nif.odin#L1952-L1987</a></summary>

```odin
parse_escaped_selector_buf :: proc(
	sel_str: string,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: xitdb.Parsed_Selector, err_reason: string) {
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
	steps, er := parse_escaped_steps_buf(s[i:], buf, allocator)
	if er != "" {
		return {}, er
	}
	res.steps = steps
	return res, ""
}
```

</details>

<details>
<summary>NIF <code>convert_raw_steps_buf</code> — <a href="../../native/xitdb_nif.odin#L2133-L2179">native/xitdb_nif.odin#L2133-L2179</a></summary>

```odin
convert_raw_steps_buf :: proc(
	env: ErlNifEnv,
	raw_steps: []Nif_Raw_Step,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: []xitdb.Path_Step, err_reason: string) {
	if len(raw_steps) == 0 {
		return nil, ""
	}
	if len(raw_steps) > len(buf) {
		return nil, "invalid_selector"
	}
	for i in 0 ..< len(raw_steps) {
		r := raw_steps[i]
		switch r.kind_code {
		case 0:
			k := "" if r.key_len == 0 else string(r.key_ptr[:r.key_len])
			buf[i] = xitdb.Path_Step{kind = .Hash_Map_Key, key = k}
		case 1:
			buf[i] = xitdb.Path_Step{kind = .Array_List_Idx, index = r.index_val}
		case 2:
			buf[i] = xitdb.Path_Step{kind = .Linked_List_Idx, index = r.index_val}
		case 3:
			kind, ok_k := map_tag_term_to_key_step_kind(r.tag_term)
			if !ok_k {
				return nil, "invalid_selector"
			}
			k := "" if r.key_len == 0 else string(r.key_ptr[:r.key_len])
			buf[i] = xitdb.Path_Step{kind = kind, key = k}
		case 4:
			kind, ok_i := map_tag_term_to_idx_step_kind(r.tag_term)
			if !ok_i {
				return nil, "invalid_selector"
			}
			buf[i] = xitdb.Path_Step{kind = kind, index = r.index_val}
		case 5:
			step, er := decode_tagged_step_term(env, r.tag_term, r.val_term, allocator)
			if er != "" {
				return nil, er
			}
			buf[i] = step
		case:
			return nil, "invalid_selector"
		}
	}
	return buf[:len(raw_steps)], ""
}
```

</details>

<details>
<summary>NIF <code>decode_steps_list_buf</code> — <a href="../../native/xitdb_nif.odin#L2181-L2189">native/xitdb_nif.odin#L2181-L2189</a></summary>

```odin
decode_steps_list_buf :: proc(
	env: ErlNifEnv,
	list_term: ERL_NIF_TERM,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: []xitdb.Path_Step, err_reason: string) {
	dyn: [dynamic]xitdb.Path_Step
	return decode_steps_list_tail_buf(env, list_term, buf, 0, &dyn, false, allocator)
}
```

</details>

<details>
<summary>NIF <code>decode_one_step_term</code> — <a href="../../native/xitdb_nif.odin#L2022-L2068">native/xitdb_nif.odin#L2022-L2068</a></summary>

```odin
decode_one_step_term :: proc(
	env: ErlNifEnv,
	term: ERL_NIF_TERM,
	allocator := context.temp_allocator,
) -> (step: xitdb.Path_Step, err_reason: string) {
	if nif_is_binary(env, term) != 0 {
		key, ok_k := get_string_from_binary(env, term)
		if !ok_k {
			return {}, "invalid_selector"
		}
		return xitdb.Path_Step{kind = .Hash_Map_Key, key = key}, ""
	}

	idx: i64 = 0
	if nif_get_int64(env, term, &idx) != 0 {
		return xitdb.Path_Step{kind = .Array_List_Idx, index = idx}, ""
	}

	if nif_is_atom(env, term) != 0 {
		key, ok_k := decode_step_key_term(env, term, allocator)
		if !ok_k {
			return {}, "invalid_selector"
		}
		return xitdb.Path_Step{kind = .Hash_Map_Key, key = key}, ""
	}

	if nif_is_list(env, term) != 0 {
		head: ERL_NIF_TERM = 0
		tail: ERL_NIF_TERM = 0
		if nif_get_list_cell(env, term, &head, &tail) == 0 || nif_is_empty_list(env, tail) == 0 {
			return {}, "invalid_selector"
		}
		lidx: i64 = 0
		if nif_get_int64(env, head, &lidx) == 0 {
			return {}, "invalid_selector"
		}
		return xitdb.Path_Step{kind = .Linked_List_Idx, index = lidx}, ""
	}

	arity: c.int = 0
	elems: [^]ERL_NIF_TERM = nil
	if nif_get_tuple(env, term, &arity, &elems) != 0 && arity == 2 {
		return decode_tagged_step_term(env, elems[0], elems[1], allocator)
	}

	return {}, "invalid_selector"
}
```

</details>

<details>
<summary>NIF <code>push_path_step</code> — <a href="../../native/xitdb_nif.odin#L1786-L1805">native/xitdb_nif.odin#L1786-L1805</a></summary>

```odin
push_path_step :: proc(
	buf: []xitdb.Path_Step,
	buf_len: ^int,
	dyn: ^[dynamic]xitdb.Path_Step,
	using_dyn: ^bool,
	step: xitdb.Path_Step,
	allocator: runtime.Allocator,
) {
	if !using_dyn^ {
		if buf_len^ < len(buf) {
			buf[buf_len^] = step
			buf_len^ += 1
			return
		}
		dyn^ = make([dynamic]xitdb.Path_Step, buf_len^, max(buf_len^ * 2, 16), allocator)
		copy(dyn^[:], buf[:buf_len^])
		using_dyn^ = true
	}
	append(dyn, step)
}
```

</details>

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.database_root_cursor</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L324-L339">database.odin#L324-L339</a></summary>

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
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L62-L65">cursor.odin#L62-L65</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
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
<summary><code>xitdb.cursor_iterator</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L891-L935">cursor.odin#L891-L935</a></summary>

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
<summary><code>xitdb.database_digest_string_buf</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L280-L282">database.odin#L280-L282</a></summary>

```odin
database_digest_string_buf :: proc(db: ^Database, s: string, buf: []u8) -> []u8 {
	return database_digest_buf(db, transmute([]u8)s, buf)
}
```

</details>

<details>
<summary><code>xitdb.precompute_step_hashes</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L560-L569">dsl.odin#L560-L569</a></summary>

```odin
precompute_step_hashes :: proc(db: ^Database, steps: []Path_Step, hash_bufs: [][64]u8, step_hashes: [][]u8) {
	for step, i in steps {
		#partial switch step.kind {
		case .Hash_Map_Key, .Counted_Hash_Map_Key, .Sorted_Map_Key, .Hash_Set_Member, .Counted_Set_Member:
			step_hashes[i] = database_digest_string_buf(db, step.key, hash_bufs[i][:])
		case:
			step_hashes[i] = nil
		}
	}
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_next</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1614-L1635">cursor.odin#L1614-L1635</a></summary>

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
<summary><code>xitdb.read_prehashed_steps_slot</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L670-L682">dsl.odin#L670-L682</a></summary>

```odin
read_prehashed_steps_slot :: proc(
	start_cur: Read_Cursor,
	steps: []Path_Step,
	step_hashes: [][]u8,
	strict_sigils := false,
) -> (res: Slot, err: Error) {
	tc_maybe := read_prehashed_steps_cursor(start_cur, steps, step_hashes, strict_sigils) or_return
	tc, has_tc := tc_maybe.?
	if !has_tc {
		return Slot{}, nil
	}
	return cursor_slot(tc)
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
<summary><code>xitdb.hash_map_get_cursor_by_hash</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L304-L306">collections.odin#L304-L306</a></summary>

```odin
hash_map_get_cursor_by_hash :: proc(m: Read_Hash_Map, hash: []u8) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(m.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Value{hash = hash}}})
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
