# #11: `Materialize: Eager subtree materialize/1 (user profile)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `enumerable` — #6–#11 (Enumerable Protocol & Subtree Materialization)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 6.09 µs (6094.0 ns) | 2.64 µs (2644.0 ns) | **`2.30x`** NIF Ratio |
| **Mean ± σ (CV)** | 6.16 µs ± 201.8 ns (3.3%) | 2.67 µs ± 41.3 ns (1.5%) | Welch `z` = `37.86` |
| **p95 / Max (`ns/op`)** | 6.43 µs / 6.52 µs | 2.72 µs / 2.72 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L283-L290`](../bench_elixir.exs#L283-L290))

```elixir
      {11, "Materialize: Eager subtree materialize/1 (user profile)", 200,
       fn ->
         for _ <- 1..200 do
           _ = Xitdb.materialize(u0_cur)
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L971-L986`](../bench_client.odin#L971-L986))

```odin
	// #11: Subtree materialize (nested user profile)
	if r11 {
		u0_cur_maybe, _ := xitdb.hash_map_get_cursor(users_map, "u0")
		u0_cur := u0_cur_maybe.?
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 200 {
				_, _ = xitdb.pull(u0_cur, "*", context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 200.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(11, "Materialize: Eager subtree materialize/1 (user profile)", 200, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>materialize</code> — <a href="../../lib/xitdb.ex#L493-L527">lib/xitdb.ex#L493-L527</a></summary>

```elixir
  def materialize(%__MODULE__{} = db) do
    materialize(as_of(db, -1))
  end

  def materialize(%Cursor{} = cursor) do
    base =
      cond do
        cursor.root and cursor.tag == :none ->
          nil

        cursor.root ->
          case NIF.nif_slot_materialize(cursor.db_ref, -1, cursor.moment, 0) do
            {:ok, raw} -> Cursor.unwrap_nif_value(cursor.db_ref, raw, cursor.moment, [])
            {:error, reason} -> raise Error, reason: reason
          end

        cursor.tx_mode and cursor.value == 0 ->
          empty_cursor_default(cursor.tag)

        true ->
          %Cursor{db_ref: db_ref, tag_id: tag_id, value: val, full: full, moment: moment} =
            Cursor.ensure_resolved(cursor)

          full_int = if full, do: 1, else: 0

          case NIF.nif_slot_materialize(db_ref, tag_id, val, full_int) do
            {:ok, raw} -> Cursor.unwrap_nif_value(db_ref, raw, moment, [])
            {:error, reason} -> raise Error, reason: reason
          end
      end

    Cursor.apply_staged_overlay(cursor, base)
  end

  def materialize(scalar), do: scalar
```

</details>

<details>
<summary>NIF <code>odin_nif_slot_materialize</code> — <a href="../../native/xitdb_nif.odin#L1464-L1512">native/xitdb_nif.odin#L1464-L1512</a></summary>

```odin
odin_nif_slot_materialize :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}
	tag_int, val_int, full_int: i64
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &full_int) == 0 {
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
		case .Array_List, .Linked_Array_List:
			return make_ok(env, nif_make_list_from_array(env, nil, 0))
		case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
			return make_ok(env, nif_make_tuple2(env, ATOM_XITDB_SET, nif_make_list_from_array(env, nil, 0)))
		case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
			return make_ok(env, nif_make_new_map(env))
		case:
			return make_ok(env, ATOM_NIL)
		}
	}

	if !is_root {
		slot.full = (full_int != 0)
	}
	term, err := materialize_slot(env, &handle.db, slot, is_root)
	if err != nil {
		return make_xitdb_err(env, err)
	}
	return make_ok(env, term)
}
```

</details>

<details>
<summary>NIF <code>materialize_slot</code> — <a href="../../native/xitdb_nif.odin#L379-L456">native/xitdb_nif.odin#L379-L456</a></summary>

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
		items := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			elem_slot := xitdb.cursor_slot(elem_cur) or_return
			term := materialize_slot(env, db, elem_slot, false) or_return
			append(&items, term)
		}
		if len(items) == 0 {
			return nif_make_list_from_array(env, nil, 0), nil
		}
		return nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items))), nil

	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		it := xitdb.cursor_iterator(cur) or_return
		items := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			kv := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator) or_return
			key_slot := xitdb.cursor_slot(kv.key_cursor) or_return
			term := slot_to_term(env, db, key_slot) or_return
			append(&items, term)
		}
		list_term: ERL_NIF_TERM
		if len(items) == 0 {
			list_term = nif_make_list_from_array(env, nil, 0)
		} else {
			list_term = nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items)))
		}
		return nif_make_tuple2(env, ATOM_XITDB_SET, list_term), nil

	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := xitdb.cursor_iterator(cur) or_return
		keys := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		vals := make([dynamic]ERL_NIF_TERM, 0, 16, context.temp_allocator)
		sb_buf: [8]u8 = ---
		for {
			next_maybe := xitdb.cursor_iterator_next(&it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			kv := xitdb.cursor_read_kv_pair(elem_cur, context.temp_allocator) or_return
			key_str := read_key_cursor_string(kv.key_cursor, sb_buf[:]) or_return
			if is_root && key_str == "__tx" {
				continue
			}
			val_slot := xitdb.cursor_slot(kv.value_cursor) or_return
			k_term := make_binary(env, key_str)
			v_term := materialize_slot(env, db, val_slot, false) or_return
			append(&keys, k_term)
			append(&vals, v_term)
		}
		return make_map_safe(env, keys[:], vals[:]), nil
	}

	return ATOM_NIL, nil
}
```

</details>

<details>
<summary>NIF <code>slot_to_term</code> — <a href="../../native/xitdb_nif.odin#L293-L351">native/xitdb_nif.odin#L293-L351</a></summary>

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
<summary>NIF <code>read_key_cursor_string</code> — <a href="../../native/xitdb_nif.odin#L353-L359">native/xitdb_nif.odin#L353-L359</a></summary>

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
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L62-L65">cursor.odin#L62-L65</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
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
