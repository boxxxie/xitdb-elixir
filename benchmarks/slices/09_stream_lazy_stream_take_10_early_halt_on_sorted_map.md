# #9: `Stream: Lazy Stream.take(10) early-halt on Sorted_Map`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `enumerable` — #6–#11 (Enumerable Protocol & Subtree Materialization)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 4.58 µs (4585.0 ns) | 1.48 µs (1479.0 ns) | **`3.10x`** NIF Ratio |
| **Mean ± σ (CV)** | 4.59 µs ± 20.0 ns (0.4%) | 1.49 µs ± 24.7 ns (1.7%) | Welch `z` = `217.38` |
| **p95 / Max (`ns/op`)** | 4.61 µs / 4.61 µs | 1.52 µs / 1.52 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L256-L263`](../bench_elixir.exs#L256-L263))

```elixir
      {9, "Stream: Lazy Stream.take(10) early-halt on Sorted_Map", 200,
       fn ->
         for _ <- 1..200 do
           _ = sorted_cur |> Stream.take(10) |> Enum.to_list()
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L885-L908`](../bench_client.odin#L885-L908))

```odin
	// #9: Lazy Stream.take(10) early-halt on Sorted_Map (N=500)
	if r9 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 200 {
				it, _ := xitdb.sorted_map_iterator(sorted_map)
				for _ in 0 ..< 10 {
					nm, _ := xitdb.cursor_iterator_next(&it)
					kv_cur, ok := nm.?
					if !ok {
						break
					}
					kv, _ := xitdb.cursor_read_kv_pair(kv_cur, context.temp_allocator)
					_, _ = xitdb.cursor_read_string(kv.key_cursor, 0, context.temp_allocator)
					_, _ = xitdb.cursor_read_string(kv.value_cursor, 0, context.temp_allocator)
				}
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 200.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(9, "Stream: Lazy Stream.take(10) early-halt on Sorted_Map", 200, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>reduce</code> — <a href="../../lib/xitdb/cursor.ex#L1131-L1160">lib/xitdb/cursor.ex#L1131-L1160</a></summary>

```elixir
  def reduce(%Cursor{} = raw_cursor, acc, fun) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0) do
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
        if resolved.root and resolved.tag != :none do
          %Cursor{resolved | tag_id: -1, value: resolved.moment}
        else
          resolved
        end

      do_reduce(stream_cursor, 0, [], acc, fun)
    end
  end
```

</details>

<details>
<summary>Elixir <code>do_reduce</code> — <a href="../../lib/xitdb/cursor.ex#L1162-L1203">lib/xitdb/cursor.ex#L1162-L1203</a></summary>

```elixir
  defp do_reduce(_cursor, _offset, _buf, {:halt, acc}, _fun), do: {:halted, acc}

  defp do_reduce(cursor, offset, buf, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(cursor, offset, buf, &1, fun)}
  end

  defp do_reduce(
         %Cursor{db_ref: db_ref, moment: moment, path_steps: path_steps} = cursor,
         offset,
         [raw_head | raw_tail],
         {:cont, acc},
         fun
       ) do
    item = unwrap_entry(db_ref, raw_head, moment, path_steps)
    do_reduce(cursor, offset, raw_tail, fun.(item, acc), fun)
  end

  defp do_reduce(
         %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = cursor,
         offset,
         [],
         {:cont, acc},
         fun
       ) do
    chunk_len =
      cond do
        offset == 0 -> 16
        offset == 16 -> 64
        true -> @chunk_size
      end

    case NIF.nif_slot_entries(db_ref, tag_id, val, offset, chunk_len) do
      {:ok, []} ->
        {:done, acc}

      {:ok, raw_chunk} ->
        do_reduce(cursor, offset + length(raw_chunk), raw_chunk, {:cont, acc}, fun)

      {:error, _} ->
        {:done, acc}
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_slot_entries</code> — <a href="../../native/xitdb_nif.odin#L1305-L1455">native/xitdb_nif.odin#L1305-L1455</a></summary>

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

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	it: xitdb.Cursor_Iterator
	err: xitdb.Error = nil
	direct_seek := false

	#partial switch slot.tag {
	case .Array_List:
		it, err = xitdb.cursor_iterator_array_list_from_index(cur, offset)
		direct_seek = true
	case .Linked_Array_List:
		it, err = xitdb.cursor_iterator_linked_array_list_from_index(cur, offset)
		direct_seek = true
	case .Sorted_Map, .Sorted_Set:
		it, err = xitdb.cursor_iterator_sorted_from_index(cur, offset)
		direct_seek = true
	case:
		it, err = xitdb.cursor_iterator(cur)
	}
	if err != nil {
		return make_xitdb_err(env, err)
	}

	cap_hint := min(int(limit), 256) if limit > 0 else 64
	items := make([dynamic]ERL_NIF_TERM, 0, cap_hint, context.temp_allocator)
	seen: i64 = offset if direct_seek else 0
	emitted: i64 = 0
	sb_buf: [8]u8 = ---

	for {
		if limit > 0 && emitted >= limit {
			break
		}
		next_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			return make_xitdb_err(env, n_err)
		}
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}

		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List:
			if seen >= offset {
				s, s_err := xitdb.cursor_slot(elem_cur)
				if s_err != nil {
					return make_xitdb_err(env, s_err)
				}
				t, t_err := slot_to_term(env, &handle.db, s)
				if t_err != nil {
					return make_xitdb_err(env, t_err)
				}
				append(&items, t)
				emitted += 1
			}
			seen += 1

		case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
			if seen >= offset {
				kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
				if kv_err != nil {
					return make_xitdb_err(env, kv_err)
				}
				ks, ks_err := xitdb.cursor_slot(kv.key_cursor)
				if ks_err != nil {
					return make_xitdb_err(env, ks_err)
				}
				t, t_err := slot_to_term(env, &handle.db, ks)
				if t_err != nil {
					return make_xitdb_err(env, t_err)
				}
				append(&items, t)
				emitted += 1
			}
			seen += 1

		case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
			kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator)
			if kv_err != nil {
				return make_xitdb_err(env, kv_err)
			}
			k_str, k_err := read_key_cursor_string(kv.key_cursor, sb_buf[:])
			if k_err != nil {
				return make_xitdb_err(env, k_err)
			}
			if is_root && k_str == "__tx" {
				continue
			}
			if seen >= offset {
				vs, vs_err := xitdb.cursor_slot(kv.value_cursor)
				if vs_err != nil {
					return make_xitdb_err(env, vs_err)
				}
				vt, vt_err := slot_to_term(env, &handle.db, vs)
				if vt_err != nil {
					return make_xitdb_err(env, vt_err)
				}
				append(&items, nif_make_tuple2(env, make_binary(env, k_str), vt))
				emitted += 1
			}
			seen += 1
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

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.sorted_map_iterator</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L718-L720">collections.odin#L718-L720</a></summary>

```odin
sorted_map_iterator :: proc(m: Read_Sorted_Map) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(m.cursor)
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
<summary><code>xitdb.cursor_read_kv_pair</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L361-L378">cursor.odin#L361-L378</a></summary>

```odin
cursor_read_kv_pair :: proc(c: Read_Cursor, allocator := context.temp_allocator) -> (res: Read_KV_Pair_Cursor, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if is_key_only_entry(slot_ptr.slot) {
		return Read_KV_Pair_Cursor{
			value_cursor = Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = Slot{}}, db = c.db, frozen_at = c.frozen_at},
			key_cursor   = Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = slot_ptr.slot}, db = c.db, frozen_at = c.frozen_at},
			hash         = nil,
		}, nil
	}
	kv_pair := decode_kv_pair_at(c.db.core, slot_ptr.slot.value, slot_ptr.slot.tag, int(c.db.header.hash_size), allocator) or_return
	key_slot_pos := database_kv_key_position(c.db, slot_ptr.slot)
	value_slot_pos := database_kv_value_position(c.db, slot_ptr.slot)
	return Read_KV_Pair_Cursor{
		value_cursor = Read_Cursor{slot_ptr = Slot_Pointer{position = value_slot_pos, slot = kv_pair.value_slot}, db = c.db, frozen_at = c.frozen_at},
		key_cursor   = Read_Cursor{slot_ptr = Slot_Pointer{position = key_slot_pos, slot = kv_pair.key_slot}, db = c.db, frozen_at = c.frozen_at},
		hash         = kv_pair.hash,
	}, nil
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
