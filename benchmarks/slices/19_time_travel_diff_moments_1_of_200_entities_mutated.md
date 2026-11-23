# #19: `Time-Travel: diff_moments (1 of 200 entities mutated)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `time_travel` — #17–#20 (Historical as_of, history_of, diff_moments & Compaction)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 118.70 µs (118696.0 ns) | 100.76 µs (100759.0 ns) | **`1.18x`** NIF Ratio |
| **Mean ± σ (CV)** | 118.71 µs ± 3.97 µs (3.3%) | 105.21 µs ± 7.43 µs (7.1%) | Welch `z` = `3.58` |
| **p95 / Max (`ns/op`)** | 123.69 µs / 124.76 µs | 113.96 µs / 114.42 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L437-L444`](../bench_elixir.exs#L437-L444))

```elixir
      {19, "Time-Travel: diff_moments (1 of 200 entities mutated)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _} = Xitdb.diff_moments(diff_db, 0, 1)
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1341-L1354`](../bench_client.odin#L1341-L1354))

```odin
	// #19: diff_moments (1 of 200 entities mutated)
	if r19 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				_, _ = xitdb.diff_moments(&diff_db, 0, 1, false, context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(19, "Time-Travel: diff_moments (1 of 200 entities mutated)", 50, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>diff_moments</code> — <a href="../../lib/xitdb.ex#L1198-L1221">lib/xitdb.ex#L1198-L1221</a></summary>

```elixir
  def diff_moments(%__MODULE__{db_ref: db_ref}, moment_a, moment_b, opts \\ [])
      when is_integer(moment_a) and is_integer(moment_b) and is_list(opts) do
    raw_tagged? = Keyword.get(opts, :raw_tagged, false)
    include_internal? = Keyword.get(opts, :include_internal, false)

    with {:ok, max_bytes} <- fetch_max_decompressed_bytes(opts),
         {:ok, raw_diffs} <-
           db_ref
           |> NIF.nif_diff_moments(moment_a, moment_b, raw_tagged?, max_bytes)
           |> Error.wrap() do
      filtered =
        if include_internal? do
          raw_diffs
        else
          Enum.reject(raw_diffs, &internal_diff_path?(&1.path))
        end

      if raw_tagged? do
        {:ok, filtered}
      else
        resolve_diff_entries(filtered, db_ref, moment_a, moment_b, opts)
      end
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_diff_moments</code> — <a href="../../native/xitdb_nif.odin#L7382-L7477">native/xitdb_nif.odin#L7382-L7477</a></summary>

```odin
odin_nif_diff_moments :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 && argc != 4 && argc != 5 {
		return make_err(env, "badarg")
	}
	raw_tagged := false
	if argc >= 4 {
		bt, ok_rt := parse_bool_arg(argv[3])
		if !ok_rt {
			return make_err(env, "badarg")
		}
		raw_tagged = bt
	}
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES
	if argc == 5 {
		mb, ok_mb := parse_max_bytes_arg(env, argv[4])
		if !ok_mb {
			return make_err(env, "badarg")
		}
		max_bytes = mb
	}
	moment_a, moment_b: i64
	if nif_get_int64(env, argv[1], &moment_a) == 0 || nif_get_int64(env, argv[2], &moment_b) == 0 {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	changes, err := xitdb.diff_moments(&handle.db, moment_a, moment_b, false, context.temp_allocator)
	if err != nil {
		return make_xitdb_err(env, err)
	}

	keys := [4]ERL_NIF_TERM{
		ATOM_OP,
		ATOM_PATH,
		ATOM_OLD_VALUE,
		ATOM_NEW_VALUE,
	}
	items := make([dynamic]ERL_NIF_TERM, 0, len(changes), context.temp_allocator)
	codec_err := ""
	iter_pool := nif_iter_pool_init(context.temp_allocator)
	for chg in changes {
		op_atom: ERL_NIF_TERM
		switch chg.op {
		case .Put:
			op_atom = ATOM_PUT
		case .Append:
			op_atom = ATOM_APPEND
		case .Insert:
			op_atom = ATOM_INSERT
		case .Remove:
			op_atom = ATOM_REMOVE
		case .Slice:
			op_atom = ATOM_SLICE
		case .Fork:
			op_atom = ATOM_FORK
		case .Savepoint, .Callback:
			op_atom = ATOM_PUT
		}

		old_val, o_err := materialize_slot(env, &handle.db, chg.old_slot, false, raw_tagged, &codec_err, max_bytes, &iter_pool)
		if o_err != nil {
			if len(codec_err) > 0 {
				return make_err(env, codec_err)
			}
			return make_xitdb_err(env, o_err)
		}
		new_val, n_err := materialize_slot(env, &handle.db, chg.new_slot, false, raw_tagged, &codec_err, max_bytes, &iter_pool)
		if n_err != nil {
			if len(codec_err) > 0 {
				return make_err(env, codec_err)
			}
			return make_xitdb_err(env, n_err)
		}

		vals := [4]ERL_NIF_TERM{
			op_atom,
			make_binary(env, chg.path_str),
			old_val,
			new_val,
		}
		append(&items, make_map_safe(env, keys[:], vals[:]))
	}

	if len(items) == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}
	return make_ok(env, nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))))
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
<summary>NIF <code>materialize_slot</code> — <a href="../../native/xitdb_nif.odin#L732-L829">native/xitdb_nif.odin#L732-L829</a></summary>

```odin
materialize_slot :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	slot: xitdb.Slot,
	is_root: bool = false,
	raw_tagged: bool = false,
	codec_err: ^string = nil,
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES,
	pool: ^Nif_Iter_Pool = nil,
) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
	if !is_container_tag(slot.tag) {
		return slot_to_term(env, db, slot, raw_tagged, codec_err, max_bytes)
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		item_buf: [16]ERL_NIF_TERM = ---
		item_len := 0
		item_dyn: [dynamic]ERL_NIF_TERM
		using_dyn := false
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			elem_slot := xitdb.cursor_slot(elem_cur) or_return
			term := materialize_slot(env, db, elem_slot, false, raw_tagged, codec_err, max_bytes, pool) or_return
			push_nif_term(item_buf[:], &item_len, &item_dyn, &using_dyn, term, context.temp_allocator)
		}
		items := item_dyn[:] if using_dyn else item_buf[:item_len]
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), nil
		}
		return nif_make_list_from_array(env, raw_data(items), c.uint(len(items))), nil

	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		item_buf: [16]ERL_NIF_TERM = ---
		item_len := 0
		item_dyn: [dynamic]ERL_NIF_TERM
		using_dyn := false
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			term := slot_to_term(env, db, key_cur.slot_ptr.slot, raw_tagged, codec_err, max_bytes) or_return
			push_nif_term(item_buf[:], &item_len, &item_dyn, &using_dyn, term, context.temp_allocator)
		}
		items := item_dyn[:] if using_dyn else item_buf[:item_len]
		return make_mapset_term(env, items), nil

	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		key_buf: [16]ERL_NIF_TERM = ---
		val_buf: [16]ERL_NIF_TERM = ---
		key_len, val_len := 0, 0
		key_dyn, val_dyn: [dynamic]ERL_NIF_TERM
		using_key_dyn, using_val_dyn := false, false
		sb_buf: [128]u8 = ---
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
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
			v_term := materialize_slot(env, db, val_cur.slot_ptr.slot, false, raw_tagged, codec_err, max_bytes, pool) or_return
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
<summary>NIF <code>slot_to_term</code> — <a href="../../native/xitdb_nif.odin#L467-L565">native/xitdb_nif.odin#L467-L565</a></summary>

```odin
slot_to_term :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	slot: xitdb.Slot,
	raw_tagged: bool = false,
	codec_err: ^string = nil,
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES,
) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
	if slot.tag == .None && !slot.full {
		return ATOM_NIL, nil
	}
	if is_container_tag(slot.tag) {
		tag_u8 := u8(slot.tag)
		// Return compact {:cursor, tag_id, slot_val}
		return nif_make_tuple3(
			env,
			ATOM_CURSOR,
			nif_make_int64(env, i64(tag_u8)),
			nif_make_int64(env, slot.value),
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
		val_size: i64 = 0
		if slot.tag == .Bytes {
			val_size = validate_bytes_slot_bounds(db, slot) or_return
		}
		if slot.full {
			obj: xitdb.Bytes
			if slot.tag == .Short_Bytes || val_size <= 128 {
				stack_buf: [128]u8 = ---
				buf_obj, buf_err := xitdb.cursor_read_bytes_buf(cur, stack_buf[:])
				if buf_err == nil {
					obj = buf_obj
				} else if buf_err != xitdb.Xitdb_Error.Stream_Too_Long {
					return ATOM_NIL, buf_err
				} else {
					obj = xitdb.cursor_read_bytes_object(cur, 0, context.temp_allocator) or_return
				}
			} else {
				obj = xitdb.cursor_read_bytes_object(cur, 0, context.temp_allocator) or_return
			}
			if len(obj.format_tag) == 2 && obj.format_tag[0] == 'b' && obj.format_tag[1] == 'l' {
				if len(obj.value) == 1 && obj.value[0] == '1' {
					return ATOM_TRUE, nil
				}
				return ATOM_FALSE, nil
			}
			if !raw_tagged && len(obj.format_tag) == 2 && obj.format_tag[0] == 'c' && obj.format_tag[1] == 'z' {
				decoded_term, cz_err := decode_cz_to_term(env, obj.value, max_bytes)
				if cz_err != "" {
					if codec_err != nil && len(codec_err^) == 0 {
						codec_err^ = cz_err
					}
					return ATOM_NIL, .Unexpected_Tag
				}
				return decoded_term, nil
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
		if val_size == 0 {
			return nif_make_binary_slice(env, nil, 0), nil
		}
		term: ERL_NIF_TERM
		dst := nif_alloc_binary_term(env, c.size_t(val_size), &term)
		if dst == nil {
			return ATOM_NIL, xitdb.Xitdb_Error.Invalid_Offset
		}
		xitdb.core_read_exact_at(db.core, slot.value + 8, dst[:int(val_size)]) or_return
		return term, nil
	}

	return ATOM_NIL, nil
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
<summary>NIF <code>push_nif_term</code> — <a href="../../native/xitdb_nif.odin#L627-L646">native/xitdb_nif.odin#L627-L646</a></summary>

```odin
push_nif_term :: proc(
	buf: []ERL_NIF_TERM,
	buf_len: ^int,
	dyn: ^[dynamic]ERL_NIF_TERM,
	using_dyn: ^bool,
	term: ERL_NIF_TERM,
	allocator: runtime.Allocator,
) {
	if !using_dyn^ {
		if buf_len^ < len(buf) {
			buf[buf_len^] = term
			buf_len^ += 1
			return
		}
		dyn^ = make([dynamic]ERL_NIF_TERM, buf_len^, max(buf_len^ * 2, 64), allocator)
		copy(dyn^[:], buf[:buf_len^])
		using_dyn^ = true
	}
	append(dyn, term)
}
```

</details>

<details>
<summary>NIF <code>make_mapset_term</code> — <a href="../../native/xitdb_nif.odin#L664-L689">native/xitdb_nif.odin#L664-L689</a></summary>

```odin
make_mapset_term :: proc(env: ErlNifEnv, elems: []ERL_NIF_TERM) -> ERL_NIF_TERM {
	inner_map: ERL_NIF_TERM
	if len(elems) == 0 {
		inner_map = nif_make_new_map(env)
	} else {
		empty_list := nif_make_list_from_array(env, nil, 0)
		val_buf: [16]ERL_NIF_TERM = ---
		vals: []ERL_NIF_TERM
		if len(elems) <= len(val_buf) {
			for i in 0 ..< len(elems) {
				val_buf[i] = empty_list
			}
			vals = val_buf[:len(elems)]
		} else {
			dyn_vals := make([]ERL_NIF_TERM, len(elems), context.temp_allocator)
			for i in 0 ..< len(elems) {
				dyn_vals[i] = empty_list
			}
			vals = dyn_vals
		}
		inner_map = make_map_safe(env, elems, vals)
	}
	ms_keys := [2]ERL_NIF_TERM{ATOM_STRUCT, ATOM_MAP}
	ms_vals := [2]ERL_NIF_TERM{ATOM_MAPSET_MOD, inner_map}
	return make_map_safe(env, ms_keys[:], ms_vals[:])
}
```

</details>

## Reachable `xitdb` Core Procedures

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
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L64-L67">cursor.odin#L64-L67</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
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
<summary><code>xitdb.cursor_read_uint</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L207-L216">cursor.odin#L207-L216</a></summary>

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
<summary><code>xitdb.cursor_read_int</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L218-L224">cursor.odin#L218-L224</a></summary>

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
<summary><code>xitdb.cursor_read_float</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L226-L232">cursor.odin#L226-L232</a></summary>

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
<summary><code>xitdb.cursor_read_bytes_buf</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L314-L390">cursor.odin#L314-L390</a></summary>

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
		if slot_ptr.slot.value < 0 {
			return {}, .Expected_Unsigned_Long
		}
		value_size := core_read_long_at(c.db.core, slot_ptr.slot.value) or_return
		if value_size < 0 {
			return {}, .Expected_Unsigned_Long
		}
		if value_size > i64(len(buffer)) {
			return {}, .Stream_Too_Long
		}
		extra: i64 = 10 if slot_ptr.slot.full else 8
		core_len := core_length(c.db.core) or_return
		if slot_ptr.slot.value > core_len || extra > core_len - slot_ptr.slot.value || value_size > core_len - slot_ptr.slot.value - extra {
			return {}, Xitdb_Error.Unexpected_EOF
		}
		if slot_ptr.slot.full {
			if value_size <= i64(len(buffer)) - 2 {
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
<summary><code>xitdb.cursor_read_bytes_object</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L247-L312">cursor.odin#L247-L312</a></summary>

```odin
cursor_read_bytes_object :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: Bytes, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .None:
		return Bytes{value = make([]u8, 0, allocator)}, nil

	case .Bytes:
		if slot_ptr.slot.value < 0 {
			return {}, .Expected_Unsigned_Long
		}
		value_size := core_read_long_at(c.db.core, slot_ptr.slot.value) or_return
		if value_size < 0 {
			return {}, .Expected_Unsigned_Long
		}
		if max_size > 0 && value_size > max_size {
			return {}, .Stream_Too_Long
		}
		extra: i64 = 10 if slot_ptr.slot.full else 8
		core_len := core_length(c.db.core) or_return
		if slot_ptr.slot.value > core_len || extra > core_len - slot_ptr.slot.value || value_size > core_len - slot_ptr.slot.value - extra {
			return {}, Xitdb_Error.Unexpected_EOF
		}
		value := make([]u8, int(value_size), allocator)
		err = core_read_exact_at(c.db.core, slot_ptr.slot.value + 8, value)
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
<summary><code>xitdb.core_read_exact_at</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L710-L755">core.odin#L710-L755</a></summary>

```odin
core_read_exact_at :: proc(c: ^Core, pos: i64, p: []u8) -> Error {
	if pos < 0 {
		return Xitdb_Error.Expected_Unsigned_Long
	}
	if len(p) == 0 {
		return nil
	}
	#partial switch &v in c {
	case Core_Memory:
		buf_len := i64(len(v.buf))
		if pos > buf_len || i64(len(p)) > buf_len - pos {
			return Xitdb_Error.Unexpected_EOF
		}
		end_pos := pos + i64(len(p))
		copy(p, v.buf[int(pos):int(end_pos)])
		return nil
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && pos >= v.memory_pos && pos <= v.memory_pos + buf_len && i64(len(p)) <= (v.memory_pos + buf_len) - pos {
			mem_off := int(pos - v.memory_pos)
			copy(p, v.memory.buf[mem_off : mem_off + len(p)])
			return nil
		}
	}
	total := 0
	for total < len(p) {
		if pos > max(i64) - i64(total) {
			return Xitdb_Error.Unexpected_EOF
		}
		n, err := core_read_at(c, pos + i64(total), p[total:])
		total += n
		if err != nil {
			if err == io.Error.EOF {
				if total == len(p) {
					return nil
				}
				return Xitdb_Error.Unexpected_EOF
			}
			return err
		}
		if n == 0 {
			return Xitdb_Error.Unexpected_EOF
		}
	}
	return nil
}
```

</details>

<details>
<summary><code>xitdb._reset_cursor_iterator</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1032-L1038">cursor.odin#L1032-L1038</a></summary>

```odin
_reset_cursor_iterator :: proc(res: ^Cursor_Iterator) {
	assert(res != nil)
	res.cursor = {}
	res.size = 0
	res.index = 0
	res.stack_len = 0
}
```

</details>

<details>
<summary><code>xitdb.cursor_resolved_cursor</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L59-L62">cursor.odin#L59-L62</a></summary>

```odin
cursor_resolved_cursor :: proc(c: Read_Cursor) -> (res: Read_Cursor, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return Read_Cursor{slot_ptr = slot_ptr, db = c.db, frozen_at = c.frozen_at}, nil
}
```

</details>
