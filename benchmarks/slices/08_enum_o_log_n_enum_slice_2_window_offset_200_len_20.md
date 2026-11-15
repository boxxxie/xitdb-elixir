# #8: `Enum: O(log N) Enum.slice/2 window (offset 200, len 20)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `enumerable` — #6–#11 (Enumerable Protocol & Subtree Materialization)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 3.32 µs (3323.0 ns) | 1.64 µs (1643.0 ns) | **`2.02x`** NIF Ratio |
| **Mean ± σ (CV)** | 3.38 µs ± 172.2 ns (5.1%) | 1.67 µs ± 45.4 ns (2.7%) | Welch `z` = `21.42` |
| **p95 / Max (`ns/op`)** | 3.61 µs / 3.67 µs | 1.73 µs / 1.74 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L259-L266`](../bench_elixir.exs#L259-L266))

```elixir
      {8, "Enum: O(log N) Enum.slice/2 window (offset 200, len 20)", 200,
       fn ->
         for _ <- 1..200 do
           _ = Enum.slice(items_cur, 200, 20)
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L902-L921`](../bench_client.odin#L902-L921))

```odin
	// #8: O(log N) Enum.slice window
	if r8 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 200 {
				it, _ := xitdb.cursor_iterator_array_list_from_index(items_al.cursor, 200)
				for _ in 0 ..< 20 {
					nm, _ := xitdb.cursor_iterator_next(&it)
					if ec, ok := nm.?; ok {
						_, _ = xitdb.cursor_read_string(ec, 0, context.temp_allocator)
					}
				}
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 200.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(8, "Enum: O(log N) Enum.slice/2 window (offset 200, len 20)", 200, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>slice</code> — <a href="../../lib/xitdb/cursor.ex#L1100-L1139">lib/xitdb/cursor.ex#L1100-L1139</a></summary>

```elixir
  def slice(%Cursor{} = raw_cursor) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0) do
      {:error, __MODULE__}
    else
      case Cursor.ensure_resolved(raw_cursor) do
        %Cursor{db_ref: db_ref, tag: tag, tag_id: tag_id, value: val, moment: moment} = cursor
        when tag in [:array_list, :linked_array_list, :sorted_map, :sorted_set] ->
          case NIF.nif_slot_count(db_ref, tag_id, val) do
            {:ok, size} ->
              {:ok, size,
               fn
                 _start, length, _step when length <= 0 ->
                   []

                 start, length, step ->
                   span = (length - 1) * step + 1

                   case NIF.nif_slot_slice(db_ref, tag_id, val, start, span) do
                     {:ok, raw_list} ->
                       selected =
                         if step == 1, do: raw_list, else: Enum.take_every(raw_list, step)

                       Enum.map(selected, &unwrap_entry(db_ref, &1, moment, cursor.path_steps))

                     {:error, reason} ->
                       raise Xitdb.Error, reason: reason
                   end
               end}

            _ ->
              {:error, __MODULE__}
          end

        _ ->
          {:error, __MODULE__}
      end
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_slot_slice</code> — <a href="../../native/xitdb_nif.odin#L1239-L1358">native/xitdb_nif.odin#L1239-L1358</a></summary>

```odin
odin_nif_slot_slice :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 5 {
		return make_err(env, "badarg")
	}
	tag_int, val_int, start_idx, length: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &start_idx) == 0 ||
	   nif_get_int64(env, argv[4], &length) == 0 {
		return make_err(env, "badarg")
	}
	if start_idx < 0 {
		return make_xitdb_err(env, .Invalid_Range)
	}
	if length <= 0 {
		return make_ok(env, nif_make_list_from_array(env, nil, 0))
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
	if is_empty {
		#partial switch slot.tag {
		case .Array_List, .Linked_Array_List, .Sorted_Map, .Sorted_Set:
			return make_ok(env, nif_make_list_from_array(env, nil, 0))
		case:
			return make_err(env, "unsupported")
		}
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	it: xitdb.Cursor_Iterator
	err: xitdb.Error = nil

	#partial switch slot.tag {
	case .Array_List:
		it, err = xitdb.cursor_iterator_array_list_from_index(cur, start_idx)
	case .Linked_Array_List:
		it, err = xitdb.cursor_iterator_linked_array_list_from_index(cur, start_idx)
	case .Sorted_Map, .Sorted_Set:
		it, err = xitdb.cursor_iterator_sorted_from_index(cur, start_idx)
	case:
		return make_err(env, "unsupported")
	}

	if err != nil {
		return make_xitdb_err(env, err)
	}

	item_buf: [64]ERL_NIF_TERM = ---
	item_len := 0
	item_dyn: [dynamic]ERL_NIF_TERM
	using_dyn := false
	sb_buf: [8]u8 = ---
	for i: i64 = 0; i < length; i += 1 {
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
			s, s_err := xitdb.cursor_slot(elem_cur)
			if s_err != nil {
				return make_xitdb_err(env, s_err)
			}
			t, t_err := slot_to_term(env, &handle.db, s)
			if t_err != nil {
				return make_xitdb_err(env, t_err)
			}
			push_nif_term(item_buf[:], &item_len, &item_dyn, &using_dyn, t, context.temp_allocator)
		case .Sorted_Set:
			key_cur, _, kv_err := xitdb.cursor_read_kv_pair_slots(elem_cur)
			if kv_err != nil {
				return make_xitdb_err(env, kv_err)
			}
			t, t_err := slot_to_term(env, &handle.db, key_cur.slot_ptr.slot)
			if t_err != nil {
				return make_xitdb_err(env, t_err)
			}
			push_nif_term(item_buf[:], &item_len, &item_dyn, &using_dyn, t, context.temp_allocator)
		case .Sorted_Map:
			key_cur, val_cur, kv_err := xitdb.cursor_read_kv_pair_slots(elem_cur)
			if kv_err != nil {
				return make_xitdb_err(env, kv_err)
			}
			k_str, k_err := read_key_cursor_string(key_cur, sb_buf[:])
			if k_err != nil {
				return make_xitdb_err(env, k_err)
			}
			vt, vt_err := slot_to_term(env, &handle.db, val_cur.slot_ptr.slot)
			if vt_err != nil {
				return make_xitdb_err(env, vt_err)
			}
			push_nif_term(item_buf[:], &item_len, &item_dyn, &using_dyn, nif_make_tuple2(env, make_binary(env, k_str), vt), context.temp_allocator)
		}
	}

	return make_ok(env, make_list_from_term_buf(env, item_buf[:], item_len, item_dyn, using_dyn))
}
```

</details>

<details>
<summary>NIF <code>slot_to_term</code> — <a href="../../native/xitdb_nif.odin#L317-L375">native/xitdb_nif.odin#L317-L375</a></summary>

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
<summary>NIF <code>push_nif_term</code> — <a href="../../native/xitdb_nif.odin#L403-L422">native/xitdb_nif.odin#L403-L422</a></summary>

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
<summary>NIF <code>read_key_cursor_string</code> — <a href="../../native/xitdb_nif.odin#L377-L383">native/xitdb_nif.odin#L377-L383</a></summary>

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

<details>
<summary>NIF <code>make_list_from_term_buf</code> — <a href="../../native/xitdb_nif.odin#L424-L438">native/xitdb_nif.odin#L424-L438</a></summary>

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

## Reachable `xitdb` Core Procedures

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
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L62-L65">cursor.odin#L62-L65</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
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
