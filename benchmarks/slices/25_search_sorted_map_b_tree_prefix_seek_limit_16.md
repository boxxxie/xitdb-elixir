# #25: `Search: Sorted_Map B+Tree prefix seek (limit=16)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#26 (Pull Projections, Datalog Engine, Buffered Sync & Search)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 4.87 µs (4867.0 ns) | 1.54 µs (1538.0 ns) | **`3.16x`** NIF Ratio |
| **Mean ± σ (CV)** | 5.00 µs ± 401.8 ns (8.0%) | 1.55 µs ± 17.1 ns (1.1%) | Welch `z` = `19.18` |
| **p95 / Max (`ns/op`)** | 5.54 µs / 5.67 µs | 1.57 µs / 1.58 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L456-L470`](../bench_elixir.exs#L456-L470))

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

### Raw Odin Harness ([`bench_client.odin#L1270-L1306`](../bench_client.odin#L1270-L1306))

```odin
	// #25: Search: Sorted_Map B+Tree prefix seek (limit=16)
	if r25 {
		sb_seek: [8]u8 = ---
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 100 {
				it, _ := xitdb.sorted_map_iterator_from_string(sorted_map, "u4")
				cnt := 0
				for cnt < 16 {
					nm, _ := xitdb.cursor_iterator_next(&it)
					ec, hn := nm.?
					if !hn {
						break
					}
					kv, _ := xitdb.cursor_read_kv_pair(ec, context.temp_allocator)
					sp, _ := xitdb.cursor_resolved(kv.key_cursor)
					ks: string
					if sp.slot.tag == .Short_Bytes && !sp.slot.full {
						bo, _ := xitdb.cursor_read_bytes_buf(kv.key_cursor, sb_seek[:])
						ks = string(bo.value)
					} else {
						ks, _ = xitdb.cursor_read_string(kv.key_cursor, 0, context.temp_allocator)
					}
					if !strings.has_prefix(ks, "u4") {
						break
					}
					_, _ = xitdb.cursor_slot(kv.value_cursor)
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
<summary>Elixir <code>nif_sorted_map_seek</code> — <a href="../../lib/xitdb/nif.ex#L38-L61">lib/xitdb/nif.ex#L38-L61</a></summary>

```elixir
  def nif_sorted_map_seek(_db_ref, _slot_tag_id, _slot_val_int, _prefix_bin, _limit_int),
    do: :erlang.nif_error(:nif_not_loaded)

  def nif_sorted_map_seek(
        _db_ref,
        _slot_tag_id,
        _slot_val_int,
        _start_key_bin,
        _limit_int,
        _prefix_only
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def nif_bm25_search(
        _db_ref,
        _root_tag_id,
        _root_val_int,
        _collection_bin,
        _query_terms,
        _limit_int,
        _opts_map
      ),
      do: :erlang.nif_error(:nif_not_loaded)
end
```

</details>

<details>
<summary>Elixir <code>scan_prefix_cursors</code> — <a href="../../lib/xitdb/ash/search.ex#L713-L733">lib/xitdb/ash/search.ex#L713-L733</a></summary>

```elixir
    def scan_prefix_cursors(db, collection, prefix, limit) do
      case get_in_search(db, collection, "terms") do
        %Xitdb.Cursor{db_ref: db_ref, tag_id: tag_id, value: val, moment: moment}
        when tag_id > 0 ->
          case Xitdb.NIF.nif_sorted_map_seek(db_ref, tag_id, val, prefix, limit) do
            {:ok, entries, next_cursor} ->
              cursors =
                Enum.map(entries, fn {term, slot_tuple} ->
                  {term, Xitdb.Cursor.from_nif_tuple(db_ref, slot_tuple, moment)}
                end)

              {cursors, next_cursor}

            _ ->
              {[], nil}
          end

        _ ->
          {[], nil}
      end
    end
```

</details>

<details>
<summary>NIF <code>odin_nif_sorted_map_seek</code> — <a href="../../native/xitdb_nif.odin#L5809-L5942">native/xitdb_nif.odin#L5809-L5942</a></summary>

```odin
odin_nif_sorted_map_seek :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	arena_alloc := context.temp_allocator
	context.allocator = arena_alloc

	if argc != 5 && argc != 6 {
		return make_err(env, "badarg")
	}

	prefix_only := true
	if argc == 6 {
		if argv[5] == ATOM_TRUE {
			prefix_only = true
		} else if argv[5] == ATOM_FALSE {
			prefix_only = false
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

	if tag_int < 0 || tag_int > i64(xitdb.MAX_TAG_VALUE) {
		return make_err(env, "invalid_slot")
	}
	tag := xitdb.Tag(u8(tag_int))
	if tag != .Sorted_Map && tag != .None {
		return make_err(env, "unsupported")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	if val_int == 0 || tag == .None || limit_int <= 0 {
		if val_int < 0 {
			return make_err(env, "invalid_slot")
		}
		empty_list := nif_make_list_from_array(env, nil, 0)
		return nif_make_tuple3(env, ATOM_OK, empty_list, ATOM_NIL)
	}

	slot, _, _, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
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

	cap_hint := int(min(limit_int, 256))
	items := make([dynamic]ERL_NIF_TERM, 0, cap_hint, arena_alloc)
	next_cursor_term: ERL_NIF_TERM = ATOM_NIL
	emitted: i64 = 0
	sb_buf: [8]u8 = ---

	for {
		next_maybe, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			return make_xitdb_err(env, n_err)
		}
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}

		kv, kv_err := xitdb.cursor_read_kv_pair(elem_cur, arena_alloc)
		if kv_err != nil {
			return make_xitdb_err(env, kv_err)
		}
		k_str, k_err := read_key_cursor_string(kv.key_cursor, sb_buf[:])
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

		val_slot, vs_err := xitdb.cursor_slot(kv.value_cursor)
		if vs_err != nil {
			return make_xitdb_err(env, vs_err)
		}
		val_term, vt_err := slot_to_term(env, &handle.db, val_slot)
		if vt_err != nil {
			return make_xitdb_err(env, vt_err)
		}

		append(&items, nif_make_tuple2(env, make_binary(env, k_str), val_term))
		emitted += 1
	}

	list_term: ERL_NIF_TERM
	if len(items) == 0 {
		list_term = nif_make_list_from_array(env, nil, 0)
	} else {
		list_term = nif_make_list_from_array(env, raw_data(items[:]), c.uint(len(items)))
	}
	return nif_make_tuple3(env, ATOM_OK, list_term, next_cursor_term)
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
<summary><code>xitdb.cursor_resolved</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L48-L55">cursor.odin#L48-L55</a></summary>

```odin
cursor_resolved :: proc(c: Read_Cursor) -> (res: Slot_Pointer, err: Error) {
	if is_root(c.slot_ptr) {
		header := database_read_root_header(c.db) or_return
		position := header.file_size - ROOT_TRAILER_LENGTH
		return Slot_Pointer{position = position, slot = header.root}, nil
	}
	return c.slot_ptr, nil
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
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L62-L65">cursor.odin#L62-L65</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
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
