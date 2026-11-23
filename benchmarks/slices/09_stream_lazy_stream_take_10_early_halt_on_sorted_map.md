# #9: `Stream: Lazy Stream.take(10) early-halt on Sorted_Map`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `enumerable` — #6–#11 (Enumerable Protocol & Subtree Materialization)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 2.72 µs (2717.0 ns) | 1.26 µs (1259.0 ns) | **`2.16x`** NIF Ratio |
| **Mean ± σ (CV)** | 2.71 µs ± 19.3 ns (0.7%) | 1.26 µs ± 7.7 ns (0.6%) | Welch `z` = `155.87` |
| **p95 / Max (`ns/op`)** | 2.73 µs / 2.73 µs | 1.27 µs / 1.27 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L299-L306`](../bench_elixir.exs#L299-L306))

```elixir
      {9, "Stream: Lazy Stream.take(10) early-halt on Sorted_Map", 200,
       fn ->
         for _ <- 1..200 do
           _ = sorted_cur |> Stream.take(10) |> Enum.to_list()
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1085-L1108`](../bench_client.odin#L1085-L1108))

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
<summary>Elixir <code>reduce</code> — <a href="../../lib/xitdb/cursor.ex#L2875-L2911">lib/xitdb/cursor.ex#L2875-L2911</a></summary>

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
<summary>Elixir <code>do_reduce</code> — <a href="../../lib/xitdb/cursor.ex#L2913-L2957">lib/xitdb/cursor.ex#L2913-L2957</a></summary>

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
<summary>NIF <code>odin_nif_slot_entries</code> — <a href="../../native/xitdb_nif.odin#L1992-L2048">native/xitdb_nif.odin#L1992-L2048</a></summary>

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

	codec_err := ""
	list_term, dec_err := decode_container_entries_term(
		env,
		&handle.db,
		slot,
		offset,
		limit,
		is_root,
		context.temp_allocator,
		&codec_err,
	)
	if dec_err != nil {
		if len(codec_err) > 0 {
			return make_err(env, codec_err)
		}
		return make_xitdb_err(env, dec_err)
	}
	return make_ok(env, list_term)
}
```

</details>

<details>
<summary>NIF <code>decode_container_entries_term</code> — <a href="../../native/xitdb_nif.odin#L10751-L10867">native/xitdb_nif.odin#L10751-L10867</a></summary>

```odin
decode_container_entries_term :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	slot: xitdb.Slot,
	offset: i64,
	limit: i64,
	skip_tx: bool,
	arena_alloc: mem.Allocator,
	codec_err: ^string = nil,
) -> (res: ERL_NIF_TERM, err: xitdb.Error) {
	if slot.tag == .None || (is_container_tag(slot.tag) && slot.value == 0) || limit == 0 {
		return nif_make_list_from_array(env, nil, 0), nil
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	it := nif_alloc_cursor_iterator(arena_alloc) or_return
	direct_seek := false
	if offset > 0 {
		#partial switch slot.tag {
		case .Array_List:
			xitdb.cursor_iterator_array_list_from_index_init(it, cur, offset) or_return
			direct_seek = true
		case .Linked_Array_List:
			xitdb.cursor_iterator_linked_array_list_from_index_init(it, cur, offset) or_return
			direct_seek = true
		case .Sorted_Map, .Sorted_Set:
			seek_offset := offset
			if skip_tx && slot.tag == .Sorted_Map && offset > 0 {
				has_tx, tx_rank := sorted_map_tx_rank(cur, it) or_return
				if has_tx && offset >= tx_rank {
					seek_offset = offset + 1
				}
			}
			xitdb.cursor_iterator_sorted_from_index_init(it, cur, seek_offset) or_return
			direct_seek = true
		case:
			xitdb.cursor_iterator_init(it, cur) or_return
		}
	} else {
		xitdb.cursor_iterator_init(it, cur) or_return
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
		next_maybe := xitdb.cursor_iterator_next(it) or_return
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
				k_term = slot_to_term(env, db, key_slot, false, codec_err) or_return
			}
			val_term := slot_to_term(env, db, val_cur.slot_ptr.slot, false, codec_err) or_return
			pair := nif_make_tuple2(env, k_term, val_term)
			push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, pair, arena_alloc)
			emitted += 1
			seen += 1
		} else if is_set {
			if seen >= offset {
				key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
				elem_term := slot_to_term(env, db, key_cur.slot_ptr.slot, false, codec_err) or_return
				push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, elem_term, arena_alloc)
				emitted += 1
			}
			seen += 1
		} else {
			if seen >= offset {
				elem_slot := xitdb.cursor_slot(elem_cur) or_return
				elem_term := slot_to_term(env, db, elem_slot, false, codec_err) or_return
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
<summary>NIF <code>nif_alloc_cursor_iterator</code> — <a href="../../native/xitdb_nif.odin#L704-L710">native/xitdb_nif.odin#L704-L710</a></summary>

```odin
nif_alloc_cursor_iterator :: proc(alloc := context.temp_allocator) -> (it: ^xitdb.Cursor_Iterator, err: xitdb.Error) {
	ptr, alloc_err := new(xitdb.Cursor_Iterator, alloc)
	if alloc_err != nil || ptr == nil {
		return nil, .Write_Failed
	}
	return ptr, nil
}
```

</details>

<details>
<summary>NIF <code>sorted_map_tx_rank</code> — <a href="../../native/xitdb_nif.odin#L1819-L1837">native/xitdb_nif.odin#L1819-L1837</a></summary>

```odin
sorted_map_tx_rank :: proc(cur: xitdb.Read_Cursor, tx_it: ^xitdb.Cursor_Iterator = nil) -> (has_tx: bool, rank: i64, err: xitdb.Error) {
	it := tx_it
	if it == nil {
		it = nif_alloc_cursor_iterator(context.temp_allocator) or_return
	}
	tx_key := "__tx"
	xitdb.cursor_iterator_sorted_from_key_init(it, cur, transmute([]u8)tx_key) or_return
	tx_rank := it.index
	next_maybe := xitdb.cursor_iterator_next(it) or_return
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
<summary>NIF <code>read_key_cursor_string</code> — <a href="../../native/xitdb_nif.odin#L571-L599">native/xitdb_nif.odin#L571-L599</a></summary>

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
<summary>NIF <code>make_list_from_term_buf</code> — <a href="../../native/xitdb_nif.odin#L648-L662">native/xitdb_nif.odin#L648-L662</a></summary>

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
<summary><code>xitdb.sorted_map_iterator</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L718-L720">collections.odin#L718-L720</a></summary>

```odin
sorted_map_iterator :: proc(m: Read_Sorted_Map) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator(m.cursor)
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
<summary><code>xitdb.cursor_read_kv_pair</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L392-L410">cursor.odin#L392-L410</a></summary>

```odin
cursor_read_kv_pair :: proc(c: Read_Cursor, allocator := context.temp_allocator) -> (res: Read_KV_Pair_Cursor, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	if is_key_only_entry(slot_ptr.slot) {
		// A key-only entry is its own key slot, so its key is where the entry is.
		return Read_KV_Pair_Cursor{
			value_cursor = Read_Cursor{slot_ptr = Slot_Pointer{position = nil, slot = Slot{}}, db = c.db, frozen_at = c.frozen_at},
			key_cursor   = Read_Cursor{slot_ptr = Slot_Pointer{position = slot_ptr.position, slot = slot_ptr.slot}, db = c.db, frozen_at = c.frozen_at},
			hash         = nil,
		}, nil
	}
	kv_pair := decode_kv_pair_at(c.db.core, slot_ptr.slot.value, slot_ptr.slot.tag, int(c.db.header.hash_size), allocator) or_return
	key_slot_pos := database_kv_key_position(c.db, slot_ptr.slot) or_return
	value_slot_pos := database_kv_value_position(c.db, slot_ptr.slot) or_return
	return Read_KV_Pair_Cursor{
		value_cursor = Read_Cursor{slot_ptr = Slot_Pointer{position = value_slot_pos, slot = kv_pair.value_slot}, db = c.db, frozen_at = c.frozen_at},
		key_cursor   = Read_Cursor{slot_ptr = Slot_Pointer{position = key_slot_pos, slot = kv_pair.key_slot}, db = c.db, frozen_at = c.frozen_at},
		hash         = kv_pair.hash,
	}, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_string</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L242-L245">cursor.odin#L242-L245</a></summary>

```odin
cursor_read_string :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: string, err: Error) {
	b := cursor_read_bytes(c, max_size, allocator) or_return
	return string(b), nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_array_list_from_index_init</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1419-L1447">cursor.odin#L1419-L1447</a></summary>

```odin
cursor_iterator_array_list_from_index_init :: proc(res: ^Cursor_Iterator, unresolved_cursor: Read_Cursor, start_index: i64) -> (err: Error) {
	_reset_cursor_iterator(res)
	defer if err != nil {
		mem.zero_item(res)
	}
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		res.cursor = cursor
		return nil
	case .Array_List:
		res.cursor = cursor
	case:
		return .Unexpected_Tag
	}
	hb: [ARRAY_LIST_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	header := array_list_header_from_bytes(hb) or_return
	idx, ok := _resolve_start_index(start_index, header.size)
	if !ok {
		res.size = header.size
		res.index = header.size
		return nil
	}
	_init_array_list_stack(res, cursor, header, idx, false) or_return
	res.size = header.size
	res.index = idx
	return nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_linked_array_list_from_index_init</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1455-L1483">cursor.odin#L1455-L1483</a></summary>

```odin
cursor_iterator_linked_array_list_from_index_init :: proc(res: ^Cursor_Iterator, unresolved_cursor: Read_Cursor, start_index: i64) -> (err: Error) {
	_reset_cursor_iterator(res)
	defer if err != nil {
		mem.zero_item(res)
	}
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		res.cursor = cursor
		return nil
	case .Linked_Array_List:
		res.cursor = cursor
	case:
		return .Unexpected_Tag
	}
	hb: [BTREE_HEADER_LENGTH]u8 = ---
	core_read_exact_at(cursor.db.core, cursor.slot_ptr.slot.value, hb[:]) or_return
	header := btree_header_from_bytes(hb) or_return
	idx, ok := _resolve_start_index(start_index, header.size)
	if !ok {
		res.size = header.size
		res.index = header.size
		return nil
	}
	_init_btree_stack_from_index(res, cursor, header, idx, false, false) or_return
	res.size = header.size
	res.index = idx
	return nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_sorted_from_index_init</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1296-L1323">cursor.odin#L1296-L1323</a></summary>

```odin
cursor_iterator_sorted_from_index_init :: proc(res: ^Cursor_Iterator, unresolved_cursor: Read_Cursor, start_index: i64) -> (err: Error) {
	_reset_cursor_iterator(res)
	defer if err != nil {
		mem.zero_item(res)
	}
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		res.cursor = cursor
		return nil
	case .Sorted_Map, .Sorted_Set:
		res.cursor = cursor
	case:
		return .Unexpected_Tag
	}
	header := _sorted_header(cursor) or_return
	total := header.size
	idx, ok := _resolve_start_index(start_index, total)
	if !ok {
		res.size = total
		res.index = total
		return nil
	}
	_init_btree_stack_from_index(res, cursor, header, idx, true, false) or_return
	res.size = total
	res.index = idx
	return nil
}
```

</details>

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
<summary><code>xitdb.cursor_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L64-L67">cursor.odin#L64-L67</a></summary>

```odin
cursor_slot :: proc(c: Read_Cursor) -> (res: Slot, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	return slot_ptr.slot, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_iterator_sorted_from_key_init</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L1331-L1411">cursor.odin#L1331-L1411</a></summary>

```odin
cursor_iterator_sorted_from_key_init :: proc(res: ^Cursor_Iterator, unresolved_cursor: Read_Cursor, start_key: []u8) -> (err: Error) {
	_reset_cursor_iterator(res)
	defer if err != nil {
		mem.zero_item(res)
	}
	cursor := cursor_resolved_cursor(unresolved_cursor) or_return
	#partial switch cursor.slot_ptr.slot.tag {
	case .None:
		res.cursor = cursor
		return nil
	case .Sorted_Map, .Sorted_Set:
		res.cursor = cursor
	case:
		return .Unexpected_Tag
	}
	header := _sorted_header(cursor) or_return
	total := header.size
	if total == 0 {
		res.size = 0
		res.index = 0
		return nil
	}
	node_ptr := header.root_ptr
	expected := total
	before: i64 = 0
	for {
		if res.stack_len >= ITERATOR_STACK_SIZE {
			return .Invalid_BTree_Node
		}
		position, pos_ok := _checked_add_i64(node_ptr, BTREE_NODE_HEADER_SIZE)
		if !pos_ok {
			return Xitdb_Error.Unexpected_EOF
		}
		node := read_sorted_node(cursor.db, node_ptr) or_return
		level := &res.stack[res.stack_len]
		switch node.kind {
		case .Leaf:
			if i64(node.num) != expected {
				return .Invalid_BTree_Node
			}
			lo, _ := sorted_leaf_search(cursor.db, &node, start_key) or_return
			next_before, b_ok := _checked_add_i64(before, i64(lo))
			if !b_ok || next_before > total {
				return .Invalid_BTree_Node
			}
			before = next_before
			copy(level.block[:node.num], node.entries[:node.num])
			level.position = position
			level.index = u8(lo)
			level.count = u8(node.num)
			level.shift = 0
			level.kind = .BTree_Leaf
			res.stack_len += 1
			_assign_btree_heights(res)
			res.size = total
			res.index = before
			return nil
		case .Branch:
			if sorted_node_subtree_count(node) != expected {
				return .Invalid_BTree_Node
			}
			i := sorted_branch_search(cursor.db, &node, start_key) or_return
			for k in 0 ..< i {
				b_ok: bool
				before, b_ok = _checked_add_i64(before, node.counts[k])
				if !b_ok {
					return .Invalid_BTree_Node
				}
			}
			copy(level.block[:node.num], node.children[:node.num])
			level.position = position
			level.index = u8(i)
			level.count = u8(node.num)
			level.shift = 0
			level.kind = .BTree_Branch
			res.stack_len += 1
			expected = node.counts[i]
			node_ptr = node.children[i].value
		}
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
