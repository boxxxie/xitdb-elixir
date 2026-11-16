# #10: `Enum: Full Enum.to_list/1 stream over Array_List (N=500)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `enumerable` — #6–#11 (Enumerable Protocol & Subtree Materialization)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 63.97 µs (63965.0 ns) | 40.20 µs (40197.0 ns) | **`1.59x`** NIF Ratio |
| **Mean ± σ (CV)** | 63.90 µs ± 786.1 ns (1.2%) | 39.67 µs ± 4.65 µs (11.7%) | Welch `z` = `11.48` |
| **p95 / Max (`ns/op`)** | 64.74 µs / 64.80 µs | 44.23 µs / 44.27 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L296-L303`](../bench_elixir.exs#L296-L303))

```elixir
      {10, "Enum: Full Enum.to_list/1 stream over Array_List (N=500)", 50,
       fn ->
         for _ <- 1..50 do
           _ = Enum.to_list(items_cur)
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1030-L1051`](../bench_client.odin#L1030-L1051))

```odin
	// #10: Full Enum.to_list stream over Array_List (N=500)
	if r10 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				it, _ := xitdb.array_list_iterator(items_al)
				for {
					nm, _ := xitdb.cursor_iterator_next(&it)
					ec, ok := nm.?
					if !ok {
						break
					}
					_, _ = xitdb.cursor_read_string(ec, 0, context.temp_allocator)
				}
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(10, "Enum: Full Enum.to_list/1 stream over Array_List (N=500)", 50, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>reduce</code> — <a href="../../lib/xitdb/cursor.ex#L2755-L2791">lib/xitdb/cursor.ex#L2755-L2791</a></summary>

```elixir
  def reduce(%Cursor{} = raw_cursor, acc, fun) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0 or
            map_size(raw_cursor.staged_list_edits) > 0 or
            raw_cursor.fork_aliases != []) do
      enumerable =
        case {raw_cursor.tag, Xitdb.materialize(raw_cursor)} do
          {:sorted_map, map} when is_map(map) and not is_struct(map) ->
            Enum.sort_by(map, &elem(&1, 0))

          {:sorted_set, %MapSet{} = set} ->
            Enum.sort(set)

          {_tag, other} ->
            other
        end

      Enumerable.reduce(enumerable, acc, fun)
    else
      %Cursor{} = resolved = Cursor.ensure_resolved(raw_cursor)

      stream_cursor =
        cond do
          resolved.root and resolved.tag_id != -1 and resolved.value == 0 ->
            %Cursor{resolved | value: 0}

          resolved.root and resolved.tag != :none ->
            %Cursor{resolved | tag_id: -1, value: resolved.moment}

          true ->
            resolved
        end

      do_reduce(stream_cursor, 0, 0, @initial_chunk_size, [], acc, fun)
    end
  end
```

</details>

<details>
<summary>Elixir <code>do_reduce</code> — <a href="../../lib/xitdb/cursor.ex#L2793-L2837">lib/xitdb/cursor.ex#L2793-L2837</a></summary>

```elixir
  defp do_reduce(_cursor, _elem_idx, _offset, _chunk_size, _buf, {:halt, acc}, _fun),
    do: {:halted, acc}

  defp do_reduce(cursor, elem_idx, offset, chunk_size, buf, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(cursor, elem_idx, offset, chunk_size, buf, &1, fun)}
  end

  defp do_reduce(cursor, elem_idx, offset, chunk_size, [raw_head | raw_tail], {:cont, acc}, fun) do
    item = unwrap_entry(cursor, raw_head, elem_idx)
    do_reduce(cursor, elem_idx + 1, offset, chunk_size, raw_tail, fun.(item, acc), fun)
  end

  defp do_reduce(_cursor, _elem_idx, _offset, 0, [], {:cont, acc}, _fun), do: {:done, acc}

  defp do_reduce(
         %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = cursor,
         elem_idx,
         offset,
         chunk_size,
         [],
         {:cont, acc},
         fun
       ) do
    case NIF.nif_slot_entries(db_ref, tag_id, val, offset, chunk_size) do
      {:ok, []} ->
        {:done, acc}

      {:ok, raw_chunk} ->
        chunk_len = length(raw_chunk)
        next_size = if chunk_len < chunk_size, do: 0, else: next_chunk_size(chunk_size)

        do_reduce(
          cursor,
          elem_idx,
          offset + chunk_len,
          next_size,
          raw_chunk,
          {:cont, acc},
          fun
        )

      {:error, reason} ->
        raise Xitdb.Error, reason: reason
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_slot_entries</code> — <a href="../../native/xitdb_nif.odin#L1532-L1583">native/xitdb_nif.odin#L1532-L1583</a></summary>

```odin
odin_nif_slot_entries :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 5 {
		return make_err(env, "badarg")
	}
	tag_int, val_int, offset, limit: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &offset) == 0 ||
	   nif_get_int64(env, argv[4], &limit) == 0 {
		return make_err(env, "badarg")
	}
	if offset < 0 {
		return make_xitdb_err(env, .Invalid_Range)
	}
	if limit == 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
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
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
	}

	list_term, dec_err := decode_container_entries_term(
		env,
		&handle.db,
		slot,
		offset,
		limit,
		is_root,
		context.temp_allocator,
	)
	if dec_err != nil {
		return make_xitdb_err(env, dec_err)
	}
	return make_ok(env, list_term)
}
```

</details>

<details>
<summary>NIF <code>decode_container_entries_term</code> — <a href="../../native/xitdb_nif.odin#L8145-L8260">native/xitdb_nif.odin#L8145-L8260</a></summary>

```odin
decode_container_entries_term :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	slot: xitdb.Slot,
	offset: i64,
	limit: i64,
	skip_tx: bool,
	arena_alloc: mem.Allocator,
) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
	if slot.tag == .None || (is_container_tag(slot.tag) && slot.value == 0) || limit == 0 {
		return nif_make_list_from_array(env, nil, 0), nil
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	it: xitdb.Cursor_Iterator
	direct_seek := false
	if offset > 0 {
		#partial switch slot.tag {
		case .Array_List:
			it = xitdb.cursor_iterator_array_list_from_index(cur, offset) or_return
			direct_seek = true
		case .Linked_Array_List:
			it = xitdb.cursor_iterator_linked_array_list_from_index(cur, offset) or_return
			direct_seek = true
		case .Sorted_Map, .Sorted_Set:
			seek_offset := offset
			if skip_tx && slot.tag == .Sorted_Map && offset > 0 {
				has_tx, tx_rank, _ := sorted_map_tx_rank(cur)
				if has_tx && offset >= tx_rank {
					seek_offset = offset + 1
				}
			}
			it = xitdb.cursor_iterator_sorted_from_index(cur, seek_offset) or_return
			direct_seek = true
		case:
			it = xitdb.cursor_iterator(cur) or_return
		}
	} else {
		it = xitdb.cursor_iterator(cur) or_return
	}

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
	seen: i64 = offset if direct_seek else 0
	emitted: i64 = 0

	for {
		if limit > 0 && emitted >= limit {
			break
		}
		next_maybe := xitdb.cursor_iterator_next(&it) or_return
		elem_cur, has_e := next_maybe.?
		if !has_e {
			break
		}

		if is_map {
			key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			key_slot := key_cur.slot_ptr.slot
			k_term: ERL_NIF_TERM
			if !key_slot.full && (key_slot.tag == .Short_Bytes || key_slot.tag == .Bytes) {
				k_str := read_key_cursor_string(key_cur, sb_buf[:]) or_return
				if skip_tx && k_str == "__tx" {
					continue
				}
				if seen < offset {
					seen += 1
					continue
				}
				k_term = make_binary(env, k_str)
			} else {
				if seen < offset {
					seen += 1
					continue
				}
				k_term = slot_to_term(env, db, key_slot) or_return
			}
			val_term := slot_to_term(env, db, val_cur.slot_ptr.slot) or_return
			pair := nif_make_tuple2(env, k_term, val_term)
			push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, pair, arena_alloc)
			emitted += 1
			seen += 1
		} else if is_set {
			if seen >= offset {
				key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
				elem_term := slot_to_term(env, db, key_cur.slot_ptr.slot) or_return
				push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, elem_term, arena_alloc)
				emitted += 1
			}
			seen += 1
		} else {
			if seen >= offset {
				elem_slot := xitdb.cursor_slot(elem_cur) or_return
				elem_term := slot_to_term(env, db, elem_slot) or_return
				push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, elem_term, arena_alloc)
				emitted += 1
			}
			seen += 1
		}
	}

	return make_list_from_term_buf(env, stack_buf[:], buf_len, dyn_items, using_dyn), nil
}
```

</details>

<details>
<summary>NIF <code>sorted_map_tx_rank</code> — <a href="../../native/xitdb_nif.odin#L1376-L1390">native/xitdb_nif.odin#L1376-L1390</a></summary>

```odin
sorted_map_tx_rank :: proc(cur: xitdb.Read_Cursor) -> (has_tx: bool, rank: i64, err: xitdb.Error) {
	tx_key := "__tx"
	tx_it := xitdb.cursor_iterator_sorted_from_key(cur, transmute([]u8)tx_key) or_return
	tx_rank := tx_it.index
	next_maybe := xitdb.cursor_iterator_next(&tx_it) or_return
	if elem_cur, ok := next_maybe.?; ok {
		key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
		sb_buf: [16]u8 = ---
		k_str := read_key_cursor_string(key_cur, sb_buf[:]) or_return
		if k_str == tx_key {
			return true, tx_rank, nil
		}
	}
	return false, 0, nil
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

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.array_list_iterator</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L49-L51">collections.odin#L49-L51</a></summary>

```odin
array_list_iterator :: proc(a: Read_Array_List) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(a.cursor)
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
<summary><code>xitdb.cursor_read_string</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L233-L236">cursor.odin#L233-L236</a></summary>

```odin
cursor_read_string :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: string, err: Error) {
	b := cursor_read_bytes(c, max_size, allocator) or_return
	return string(b), nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_array_list_from_index</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1102-L1136">cursor.odin#L1102-L1136</a></summary>

```odin
cursor_iterator_array_list_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Array_List:
	case:
		return {}, .Unexpected_Tag
	}
	hb: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	header := array_list_header_from_bytes(hb) or_return
	idx, ok := _resolve_start_index(start_index, header.size)
	if !ok {
		return res, nil
	}
	shift := radix_shift(header.size - 1)
	pos := header.ptr
	sh := shift
	for {
		i := int((idx >> (u64(sh) * BIT_COUNT)) & i64(MASK))
		level := &res.stack[res.stack_len]
		_fill_slot_block_from(cursor, pos, i, SLOT_COUNT, level) or_return
		res.stack_len += 1
		if sh == 0 {
			break
		}
		pos = level.block[i].value
		sh -= 1
	}
	res.size = header.size
	res.index = idx
	return res, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_linked_array_list_from_index</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1138-L1198">cursor.odin#L1138-L1198</a></summary>

```odin
cursor_iterator_linked_array_list_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Linked_Array_List:
	case:
		return {}, .Unexpected_Tag
	}
	hb: [BTREE_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	header := btree_header_from_bytes(hb) or_return
	idx, ok := _resolve_start_index(start_index, header.size)
	if !ok {
		return res, nil
	}
	node_ptr := header.root_ptr
	rem := idx
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			r := int(rem)
			if r < 0 || r >= num {
				return {}, .Invalid_BTree_Node
			}
			_fill_slot_block_from(cursor, position, r, num, level) or_return
			res.stack_len += 1
			break
		}
		counts_pos := position + SLOT_LENGTH * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		_fill_slot_block_from(cursor, position, i, num, level) or_return
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = header.size
	res.index = idx
	return res, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_sorted_from_index</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L949-L1008">cursor.odin#L949-L1008</a></summary>

```odin
cursor_iterator_sorted_from_index :: proc(unresolved_cursor: Read_Cursor, start_index: i64) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Sorted_Map, .Sorted_Set:
	case:
		return {}, .Unexpected_Tag
	}
	header := _sorted_header(cursor) or_return
	total := header.size
	idx, ok := _resolve_start_index(start_index, total)
	if !ok {
		return res, nil
	}
	node_ptr := header.root_ptr
	rem := idx
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			r := int(rem)
			if r < 0 || r >= num {
				return {}, .Invalid_BTree_Node
			}
			_fill_slot_block_from(cursor, position, r, num, level) or_return
			res.stack_len += 1
			break
		}
		counts_pos := position + SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		counts_buf: [8 * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, counts_pos, counts_buf[:num * 8]) or_return
		i := 0
		for i + 1 < num {
			cnt := i64(endian.unchecked_get_u64be(counts_buf[i * 8 : i * 8 + 8]))
			if rem < cnt {
				break
			}
			rem -= cnt
			i += 1
		}
		_fill_slot_block_from(cursor, position, i, num, level) or_return
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = total
	res.index = idx
	return res, nil
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
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L62-L65">cursor.odin#L62-L65</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_sorted_from_key</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1010-L1100">cursor.odin#L1010-L1100</a></summary>

```odin
cursor_iterator_sorted_from_key :: proc(unresolved_cursor: Read_Cursor, start_key: []u8) -> (res: Cursor_Iterator, err: Error) {
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	res.cursor = cursor
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		return res, nil
	case .Sorted_Map, .Sorted_Set:
	case:
		return {}, .Unexpected_Tag
	}
	header := _sorted_header(cursor) or_return
	total := header.size
	node_ptr := header.root_ptr
	before: i64 = 0
	for {
		header_bytes: [BTREE_NODE_HEADER_SIZE]u8 = ---
		core_read_exact_at(cursor.db.core, node_ptr, header_bytes[:]) or_return
		kind_int := header_bytes[0]
		if kind_int > u8(BTree_Node_Kind.Branch) {
			return {}, .Invalid_BTree_Node_Kind
		}
		num := int(header_bytes[1])
		if num > BTREE_SLOT_COUNT {
			return {}, .Invalid_BTree_Node
		}
		position := node_ptr + BTREE_NODE_HEADER_SIZE
		level := &res.stack[res.stack_len]
		if BTree_Node_Kind(kind_int) == .Leaf {
			if num > 0 {
				index_block_bytes: [INDEX_BLOCK_SIZE]u8 = ---
				core_read_exact_at(cursor.db.core, position, index_block_bytes[:num * SLOT_LENGTH]) or_return
				for j in 0 ..< num {
					level.block[j] = slot_from_slice(index_block_bytes[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
				}
			}
			lo := 0
			hi := num
			for lo < hi {
				mid := int(uint(lo + hi) >> 1)
				entry_slot := level.block[mid]
				key_slot := sorted_entry_key_slot(cursor.db, entry_slot) or_return
				cmp := compare_key(cursor.db, key_slot, start_key) or_return
				if cmp == 0 {
					lo = mid
					break
				} else if cmp < 0 {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			before += i64(lo)
			level.position = position
			level.index = u8(lo)
			level.count = u8(num)
			res.stack_len += 1
			break
		}
		branch_buf: [(SLOT_LENGTH * 2 + 8) * BTREE_SLOT_COUNT]u8 = ---
		core_read_exact_at(cursor.db.core, position, branch_buf[:SLOT_LENGTH * 2 * BTREE_SLOT_COUNT + num * 8]) or_return
		lo := 1
		hi := num
		sep_off := SLOT_LENGTH * BTREE_SLOT_COUNT
		for lo < hi {
			mid := int(uint(lo + hi) >> 1)
			sep_slot := slot_from_slice(branch_buf[sep_off + mid * SLOT_LENGTH : sep_off + (mid + 1) * SLOT_LENGTH]) or_return
			c := compare_key(cursor.db, sep_slot, start_key) or_return
			if c <= 0 {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		i := lo - 1
		counts_off := SLOT_LENGTH * 2 * BTREE_SLOT_COUNT
		for k in 0 ..< i {
			before += i64(endian.unchecked_get_u64be(branch_buf[counts_off + k * 8 : counts_off + (k + 1) * 8]))
		}
		for j in i ..< num {
			level.block[j] = slot_from_slice(branch_buf[j * SLOT_LENGTH : (j + 1) * SLOT_LENGTH]) or_return
		}
		level.position = position
		level.index = u8(i)
		level.count = u8(num)
		res.stack_len += 1
		node_ptr = level.block[i].value
	}
	res.size = total
	res.index = before
	return res, nil
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
