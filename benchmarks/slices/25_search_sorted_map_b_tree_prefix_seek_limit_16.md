# #25: `Search: Sorted_Map B+Tree prefix seek (limit=16)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#27 (Pull Projections, Datalog Engine, Buffered Sync, Search & Indexer)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 4.62 µs (4623.0 ns) | 1.65 µs (1653.0 ns) | **`2.80x`** NIF Ratio |
| **Mean ± σ (CV)** | 4.63 µs ± 103.3 ns (2.2%) | 1.67 µs ± 24.6 ns (1.5%) | Welch `z` = `62.36` |
| **p95 / Max (`ns/op`)** | 4.73 µs / 4.74 µs | 1.70 µs / 1.71 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L487-L501`](../bench_elixir.exs#L487-L501))

```elixir
      {25, "Search: Sorted_Map B+Tree prefix seek (limit=16)", 100,
       fn ->
         for _ <- 1..100 do
           {:ok, _entries, _next} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               sorted_cur.tag_id,
               sorted_cur.value,
               "u4",
               16
             )
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1380-L1421`](../bench_client.odin#L1380-L1421))

```odin
	// #25: Search: Sorted_Map B+Tree prefix seek (limit=16)
	if r25 {
		sb_seek: [128]u8 = ---
		val_buf: [128]u8 = ---
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 100 {
				it, _ := xitdb.sorted_map_iterator_from_string(sorted_map, "u4")
				cnt := 0
				for {
					nm, _ := xitdb.cursor_iterator_next(&it)
					ec, hn := nm.?
					if !hn {
						break
					}
					key_cur, val_cur, _ := xitdb.cursor_read_kv_pair_slots(ec)
					ks: string
					if bo, b_err := xitdb.cursor_read_bytes_buf(key_cur, sb_seek[:]); b_err == nil {
						ks = string(bo.value)
					} else {
						ks, _ = xitdb.cursor_read_string(key_cur, 0, context.temp_allocator)
					}
					if !strings.has_prefix(ks, "u4") {
						break
					}
					if cnt == 16 {
						_ = ks
						break
					}
					if _, v_err := xitdb.cursor_read_bytes_buf(val_cur, val_buf[:]); v_err != nil {
						_, _ = xitdb.cursor_read_string(val_cur, 0, context.temp_allocator)
					}
					cnt += 1
				}
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 100.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(25, "Search: Sorted_Map B+Tree prefix seek (limit=16)", 100, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>nif_sorted_map_seek</code> — <a href="../../lib/xitdb/nif.ex#L62-L63">lib/xitdb/nif.ex#L62-L63</a></summary>

```elixir
  def nif_sorted_map_seek(_db_ref, _slot_tag_id, _slot_val_int, _prefix_bin, _limit_int),
    do: :erlang.nif_error(:nif_not_loaded)
```

</details>

<details>
<summary>Elixir <code>scan_prefix_cursors</code> — <a href="../../lib/xitdb/ash/search.ex#L713-L749">lib/xitdb/ash/search.ex#L713-L749</a></summary>

```elixir
    def scan_prefix_cursors(db, collection, prefix, limit) do
      case get_in_search(db, collection, "terms") do
        %Xitdb.Cursor{
          db_ref: db_ref,
          tag: :sorted_map,
          tag_id: tag_id,
          value: val,
          moment: moment
        }
        when tag_id > 0 ->
          case Xitdb.NIF.nif_sorted_map_seek(db_ref, tag_id, val, prefix, limit) do
            {:ok, entries, next_cursor} ->
              cursors =
                Enum.flat_map(entries, fn
                  {term, p_tag_id, p_val} when is_integer(p_tag_id) and is_integer(p_val) ->
                    [{term, Xitdb.Cursor.from_compact_slot(db_ref, p_tag_id, p_val, moment)}]

                  {term, {:cursor, _, _} = slot_tuple} ->
                    [{term, Xitdb.Cursor.from_nif_tuple(db_ref, slot_tuple, moment)}]

                  {term, {:cursor, _, _, _, _} = slot_tuple} ->
                    [{term, Xitdb.Cursor.from_nif_tuple(db_ref, slot_tuple, moment)}]

                  {_term, _scalar_or_nil} ->
                    []
                end)

              {cursors, next_cursor}

            {:error, reason} ->
              raise Xitdb.Error, reason: reason
          end

        _ ->
          {[], nil}
      end
    end
```

</details>

<details>
<summary>NIF <code>odin_nif_sorted_map_seek</code> — <a href="../../native/xitdb_nif.odin#L8353-L8527">native/xitdb_nif.odin#L8353-L8527</a></summary>

```odin
odin_nif_sorted_map_seek :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	arena_alloc := context.temp_allocator
	context.allocator = arena_alloc

	if argc != 5 && argc != 6 && argc != 7 {
		return make_err(env, "badarg")
	}

	prefix_only := true
	if argc >= 6 {
		if argv[5] == ATOM_TRUE {
			prefix_only = true
		} else if argv[5] == ATOM_FALSE {
			prefix_only = false
		} else {
			return make_err(env, "badarg")
		}
	}

	decode_children := false
	if argc == 7 {
		if argv[6] == ATOM_TRUE {
			decode_children = true
		} else if argv[6] == ATOM_FALSE {
			decode_children = false
		} else {
			return make_err(env, "badarg")
		}
	}

	tag_int: i64 = 0
	val_int: i64 = 0
	limit_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[4], &limit_int) == 0 {
		return make_err(env, "badarg")
	}

	prefix, ok_p := get_string_from_binary(env, argv[3])
	if !ok_p {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}

	if slot.tag != .Sorted_Map && slot.tag != .None {
		return make_err(env, "unsupported")
	}

	if is_empty || slot.tag == .None || limit_int <= 0 {
		empty_list := nif_make_list_from_array(env, nil, 0)
		return nif_make_tuple3(env, ATOM_OK, empty_list, ATOM_NIL)
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	sm_col, sm_err := xitdb.read_sorted_map_init(cur)
	if sm_err != nil {
		return make_xitdb_err(env, sm_err)
	}

	it, it_err := xitdb.sorted_map_iterator_from_string(sm_col, prefix)
	if it_err != nil {
		return make_xitdb_err(env, it_err)
	}

	item_buf: [64]ERL_NIF_TERM = ---
	item_len := 0
	item_dyn: [dynamic]ERL_NIF_TERM
	using_dyn := false
	defer if using_dyn {
		delete(item_dyn)
	}
	next_cursor_term: ERL_NIF_TERM = ATOM_NIL
	emitted: i64 = 0
	total_fused: i64 = 0
	sb_buf: [128]u8 = ---

	for {
		next_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			return make_xitdb_err(env, n_err)
		}
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}

		key_cur, val_cur, kv_err := xitdb.cursor_read_kv_pair_slots(elem_cur)
		if kv_err != nil {
			return make_xitdb_err(env, kv_err)
		}
		k_str, k_err := read_key_cursor_string(key_cur, sb_buf[:])
		if k_err != nil {
			return make_xitdb_err(env, k_err)
		}
		if prefix_only && !strings.has_prefix(k_str, prefix) {
			break
		}

		if emitted == limit_int {
			next_cursor_term = make_binary(env, k_str)
			break
		}

		val_slot := val_cur.slot_ptr.slot
		entry_term: ERL_NIF_TERM
		if is_container_tag(val_slot.tag) {
			fused := false
			if decode_children && total_fused < MAX_FUSED_TOTAL_ENTRIES {
				budget := min(i64(MAX_FUSED_CHILD_ENTRIES), i64(MAX_FUSED_TOTAL_ENTRIES) - total_fused)
				children_term, child_cnt, exceeded, c_err := decode_child_container_entries_term(
					env,
					&handle.db,
					val_slot,
					budget,
					arena_alloc,
				)
				if c_err != nil {
					return make_xitdb_err(env, c_err)
				}
				if !exceeded {
					total_fused += child_cnt
					entry_term = nif_make_tuple2(env, make_binary(env, k_str), children_term)
					fused = true
				}
			}
			if !fused {
				entry_term = nif_make_tuple3(
					env,
					make_binary(env, k_str),
					nif_make_int64(env, i64(u8(val_slot.tag))),
					nif_make_int64(env, val_slot.value),
				)
			}
		} else {
			val_term, vt_err := slot_to_term(env, &handle.db, val_slot)
			if vt_err != nil {
				return make_xitdb_err(env, vt_err)
			}
			entry_term = nif_make_tuple2(env, make_binary(env, k_str), val_term)
		}

		push_nif_term(
			item_buf[:],
			&item_len,
			&item_dyn,
			&using_dyn,
			entry_term,
			arena_alloc,
		)
		emitted += 1
	}

	list_term := make_list_from_term_buf(env, item_buf[:], item_len, item_dyn, using_dyn)
	return nif_make_tuple3(env, ATOM_OK, list_term, next_cursor_term)
}
```

</details>

<details>
<summary>NIF <code>read_key_cursor_string</code> — <a href="../../native/xitdb_nif.odin#L435-L463">native/xitdb_nif.odin#L435-L463</a></summary>

```odin
read_key_cursor_string :: proc(cur: xitdb.Read_Cursor, sb_buf: []u8) -> (s: string, err: xitdb.Error) {
	slot := cur.slot_ptr.slot
	if slot.tag == .Bytes {
		val_size := validate_bytes_slot_bounds(cur.db, slot) or_return
		if !slot.full {
			if val_size == 0 {
				return "", nil
			}
			if val_size <= i64(len(sb_buf)) {
				dst := sb_buf[:int(val_size)]
				xitdb.core_read_exact_at(cur.db.core, slot.value + 8, dst) or_return
				return string(dst), nil
			}
			dst := make([]u8, int(val_size), context.temp_allocator)
			xitdb.core_read_exact_at(cur.db.core, slot.value + 8, dst) or_return
			return string(dst), nil
		}
	}
	if !slot.full && slot.tag == .Short_Bytes {
		if len(sb_buf) >= 8 {
			b_obj := xitdb.cursor_read_bytes_buf(cur, sb_buf) or_return
			return string(b_obj.value), nil
		}
		tmp_buf: [8]u8 = ---
		b_obj := xitdb.cursor_read_bytes_buf(cur, tmp_buf[:]) or_return
		return strings.clone(string(b_obj.value), context.temp_allocator), nil
	}
	return safe_cursor_read_string(cur, context.temp_allocator)
}
```

</details>

<details>
<summary>NIF <code>decode_child_container_entries_term</code> — <a href="../../native/xitdb_nif.odin#L8265-L8346">native/xitdb_nif.odin#L8265-L8346</a></summary>

```odin
decode_child_container_entries_term :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	slot: xitdb.Slot,
	max_entries: i64,
	arena_alloc: mem.Allocator,
) -> (res: ERL_NIF_TERM, count: i64, exceeded: bool, err: xitdb.Error) {
	if slot.tag == .None || slot.value == 0 {
		return nif_make_list_from_array(env, nil, 0), 0, false, nil
	}
	if max_entries <= 0 {
		return ATOM_NIL, 0, true, nil
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List, .Counted_Hash_Map, .Counted_Hash_Set, .Sorted_Map, .Sorted_Set:
		cnt, c_err := xitdb.cursor_count(cur)
		if c_err != nil {
			return ATOM_NIL, 0, false, c_err
		}
		if cnt > max_entries {
			return ATOM_NIL, 0, true, nil
		}
	}

	it := xitdb.cursor_iterator(cur) or_return

	is_map := slot.tag == .Hash_Map || slot.tag == .Counted_Hash_Map || slot.tag == .Sorted_Map
	is_set := slot.tag == .Hash_Set || slot.tag == .Counted_Hash_Set || slot.tag == .Sorted_Set

	stack_buf: [32]ERL_NIF_TERM = ---
	dyn_items: [dynamic]ERL_NIF_TERM
	buf_len := 0
	using_dyn := false
	defer if using_dyn {
		delete(dyn_items)
	}
	sb_buf: [128]u8 = ---
	emitted: i64 = 0

	for {
		next_maybe := xitdb.cursor_iterator_next(&it) or_return
		elem_cur, has_e := next_maybe.?
		if !has_e {
			break
		}
		if emitted >= max_entries {
			return ATOM_NIL, 0, true, nil
		}

		if is_map {
			key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			key_slot := key_cur.slot_ptr.slot
			k_term: ERL_NIF_TERM
			if !key_slot.full && (key_slot.tag == .Short_Bytes || key_slot.tag == .Bytes) {
				k_str := read_key_cursor_string(key_cur, sb_buf[:]) or_return
				k_term = make_binary(env, k_str)
			} else {
				k_term = slot_to_term(env, db, key_slot) or_return
			}
			val_term := slot_to_term(env, db, val_cur.slot_ptr.slot) or_return
			pair := nif_make_tuple2(env, k_term, val_term)
			push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, pair, arena_alloc)
		} else if is_set {
			key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			elem_term := slot_to_term(env, db, key_cur.slot_ptr.slot) or_return
			push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, elem_term, arena_alloc)
		} else {
			elem_slot := xitdb.cursor_slot(elem_cur) or_return
			elem_term := slot_to_term(env, db, elem_slot) or_return
			push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, elem_term, arena_alloc)
		}
		emitted += 1
	}

	return make_list_from_term_buf(env, stack_buf[:], buf_len, dyn_items, using_dyn), emitted, false, nil
}
```

</details>

<details>
<summary>NIF <code>slot_to_term</code> — <a href="../../native/xitdb_nif.odin#L354-L429">native/xitdb_nif.odin#L354-L429</a></summary>

```odin
slot_to_term :: proc(env: ErlNifEnv, db: ^xitdb.Database, slot: xitdb.Slot) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
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
			stack_buf: [128]u8 = ---
			obj, buf_err := xitdb.cursor_read_bytes_buf(cur, stack_buf[:])
			if buf_err != nil {
				if buf_err != xitdb.Xitdb_Error.Stream_Too_Long {
					return ATOM_NIL, buf_err
				}
				obj = xitdb.cursor_read_bytes_object(cur, 0, context.temp_allocator) or_return
			}
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
<summary>NIF <code>push_nif_term</code> — <a href="../../native/xitdb_nif.odin#L491-L510">native/xitdb_nif.odin#L491-L510</a></summary>

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
<summary>NIF <code>make_list_from_term_buf</code> — <a href="../../native/xitdb_nif.odin#L512-L526">native/xitdb_nif.odin#L512-L526</a></summary>

```odin
make_list_from_term_buf :: proc(
	env: ErlNifEnv,
	buf: []ERL_NIF_TERM,
	buf_len: int,
	dyn: [dynamic]ERL_NIF_TERM,
	using_dyn: bool,
) -> ERL_NIF_TERM {
	if using_dyn {
		return nif_make_list_from_array(env, raw_data(dyn[:]), c.uint(len(dyn)))
	}
	if buf_len == 0 {
		return nif_make_list_from_array(env, nil, 0)
	}
	return nif_make_list_from_array(env, raw_data(buf[:buf_len]), c.uint(buf_len))
}
```

</details>

<details>
<summary>NIF <code>validate_bytes_slot_bounds</code> — <a href="../../native/xitdb_nif.odin#L335-L352">native/xitdb_nif.odin#L335-L352</a></summary>

```odin
validate_bytes_slot_bounds :: proc(db: ^xitdb.Database, slot: xitdb.Slot) -> (val_size: i64, err: xitdb.Error) {
	if slot.value < xitdb.HEADER_LENGTH {
		return 0, xitdb.Xitdb_Error.Invalid_Offset
	}
	core_len := xitdb.core_length(db.core) or_return
	if slot.value > core_len - 8 {
		return 0, xitdb.Xitdb_Error.Unexpected_EOF
	}
	val_size = xitdb.core_read_long_at(db.core, slot.value) or_return
	if val_size < 0 {
		return 0, xitdb.Xitdb_Error.Invalid_Offset
	}
	extra: i64 = 2 if slot.full else 0
	if slot.value + 8 > core_len - extra || val_size > core_len - (slot.value + 8 + extra) || val_size > i64(max(int)) {
		return 0, xitdb.Xitdb_Error.Unexpected_EOF
	}
	return val_size, nil
}
```

</details>

<details>
<summary>NIF <code>safe_cursor_read_string</code> — <a href="../../native/xitdb_nif.odin#L465-L471">native/xitdb_nif.odin#L465-L471</a></summary>

```odin
safe_cursor_read_string :: proc(cur: xitdb.Read_Cursor, allocator: mem.Allocator) -> (s: string, err: xitdb.Error) {
	slot_ptr := xitdb.cursor_resolved(cur) or_return
	if slot_ptr.slot.tag == .Bytes {
		_ = validate_bytes_slot_bounds(cur.db, slot_ptr.slot) or_return
	}
	return xitdb.cursor_read_string(cur, 0, allocator)
}
```

</details>

## Reachable `xitdb` Core Procedures

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
<summary><code>xitdb.cursor_read_string</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L233-L236">cursor.odin#L233-L236</a></summary>

```odin
cursor_read_string :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: string, err: Error) {
	b := cursor_read_bytes(c, max_size, allocator) or_return
	return string(b), nil
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
<summary><code>xitdb.core_read_exact_at</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L705-L746">core.odin#L705-L746</a></summary>

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
		end_pos := pos + i64(len(p))
		if end_pos > i64(len(v.buf)) {
			return Xitdb_Error.Unexpected_EOF
		}
		copy(p, v.buf[int(pos):int(end_pos)])
		return nil
	case Core_Buffered_File:
		buf_len := i64(len(v.memory.buf))
		if buf_len > 0 && pos >= v.memory_pos && pos + i64(len(p)) <= v.memory_pos + buf_len {
			mem_off := int(pos - v.memory_pos)
			copy(p, v.memory.buf[mem_off : mem_off + len(p)])
			return nil
		}
	}
	total := 0
	for total < len(p) {
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
<summary><code>xitdb.cursor_count</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L413-L447">cursor.odin#L413-L447</a></summary>

```odin
cursor_count :: proc(c: Read_Cursor) -> (res: i64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .None:
		return 0, nil
	case .Array_List:
		hb: [ARRAY_LIST_HEADER_LENGTH]u8
		core_read_exact_at(c.db.core, slot_ptr.slot.value, hb[:]) or_return
		header := array_list_header_from_bytes(hb) or_return
		return header.size, nil
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(c.db.core, slot_ptr.slot.value, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		return header.size, nil
	case .Bytes:
		return core_read_long_at(c.db.core, slot_ptr.slot.value)
	case .Short_Bytes:
		buf: [8]u8
		endian.unchecked_put_u64be(buf[:], u64(slot_ptr.slot.value))
		total_size := 6 if slot_ptr.slot.full else 8
		size := 0
		for b in buf {
			if b == 0 || size == total_size {
				break
			}
			size += 1
		}
		return i64(size), nil
	case .Counted_Hash_Map, .Counted_Hash_Set:
		return core_read_long_at(c.db.core, slot_ptr.slot.value)
	case:
		return 0, .Unexpected_Tag
	}
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
