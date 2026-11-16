# #5: `Access: Linked_Array_List random index lookup (linked[idx])`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `access` — #1–#5, #28 (Lazy Access Navigation, Point Lookups & Pre-Tokenized DSL Select)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 373.0 ns (373.0 ns) | 118.0 ns (118.0 ns) | **`3.16x`** NIF Ratio |
| **Mean ± σ (CV)** | 375.2 ns ± 9.0 ns (2.4%) | 118.8 ns ± 1.6 ns (1.4%) | Welch `z` = `62.59` |
| **p95 / Max (`ns/op`)** | 387.4 ns / 391.0 ns | 120.8 ns / 121.0 ns | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L256-L263`](../bench_elixir.exs#L256-L263))

```elixir
      {5, "Access: Linked_Array_List random index lookup (linked[idx])", 500,
       fn ->
         for i <- 0..499 do
           _ = linked_cur[rem(i * 37, 500)]
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L938-L952`](../bench_client.odin#L938-L952))

```odin
	// #5: Linked_Array_List random index lookup
	if r5 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for i in 0 ..< 500 {
				ec, _ := xitdb.linked_array_list_get_cursor(linked_ll, i64((i * 37) % 500))
				_, _ = xitdb.cursor_read_string(ec.?, 0, context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(5, "Access: Linked_Array_List random index lookup (linked[idx])", 500, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>fetch</code> — <a href="../../lib/xitdb/cursor.ex#L200-L262">lib/xitdb/cursor.ex#L200-L262</a></summary>

```elixir
  def fetch(%__MODULE__{} = cursor, key) when is_atom(key) do
    fetch(cursor, Atom.to_string(key))
  end

  def fetch(%__MODULE__{tx_mode: false} = cursor, key) when is_binary(key) do
    cursor.db_ref
    |> NIF.nif_slot_get_key(cursor.tag_id, cursor.value, key)
    |> handle_fetch_result(cursor)
  end

  def fetch(%__MODULE__{tx_mode: false} = cursor, key) when is_integer(key) do
    cursor
    |> nif_slot_get(key)
    |> handle_fetch_result(cursor)
  end

  def fetch(%__MODULE__{tx_mode: true} = raw_cursor, key)
      when is_integer(key) or is_binary(key) do
    cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor

    if mismatched_access_key?(cursor, key) do
      :error
    else
      resolved_key = resolve_list_key(cursor, key)
      child_key = if is_integer(resolved_key), do: resolved_key, else: to_string(resolved_key)
      child_steps = [{cursor.tag, child_key} | cursor.path_steps]

      case lookup_staged(cursor, child_steps) do
        {:staged, val} ->
          {:ok, val}

        :deleted ->
          :error

        :miss ->
          self_sel = steps_to_override_key(cursor.path_steps)
          child_sel = steps_to_override_key(child_steps)

          cond do
            is_integer(resolved_key) and Map.has_key?(cursor.staged_list_edits, self_sel) ->
              list = fetch_edited_list(cursor, self_sel)

              if resolved_key >= 0 and resolved_key < length(list) do
                {:ok, wrap_staged_val(cursor, child_steps, Enum.at(list, resolved_key))}
              else
                :error
              end

            cursor.fork_aliases != [] ->
              case resolve_fork_alias(cursor.fork_aliases, child_sel) do
                {:ok, alias_sel} ->
                  fetch_aliased_disk(cursor, child_steps, alias_sel)

                :none ->
                  fetch_disk_tx_miss(cursor, resolved_key, child_steps)
              end

            true ->
              fetch_disk_tx_miss(cursor, resolved_key, child_steps)
          end
      end
    end
  end
```

</details>

<details>
<summary>Elixir <code>nif_slot_get</code> — <a href="../../lib/xitdb/cursor.ex#L397-L405">lib/xitdb/cursor.ex#L397-L405</a></summary>

```elixir
  defp nif_slot_get(%__MODULE__{} = cursor, idx) when is_integer(idx) do
    %__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val} = ensure_resolved(cursor)
    NIF.nif_slot_get_index(db_ref, tag_id, val, idx)
  end

  defp nif_slot_get(%__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val}, key)
       when is_binary(key) do
    NIF.nif_slot_get_key(db_ref, tag_id, val, key)
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_slot_get_index</code> — <a href="../../native/xitdb_nif.odin#L1118-L1205">native/xitdb_nif.odin#L1118-L1205</a></summary>

```odin
odin_nif_slot_get_index :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	idx_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 ||
	   nif_get_int64(env, argv[2], &val_int) == 0 ||
	   nif_get_int64(env, argv[3], &idx_int) == 0 {
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
	if is_empty {
		return ATOM_ERROR
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	child_slot_maybe: Maybe(xitdb.Slot) = nil
	err: xitdb.Error = nil

	#partial switch slot.tag {
	case .Array_List:
		al_col: xitdb.Read_Array_List
		al_col, err = xitdb.read_array_list_init(cur)
		if err == nil {
			cnt: i64
			cnt, err = xitdb.array_list_count(al_col)
			if err == nil {
				resolved := idx_int if idx_int >= 0 else cnt + idx_int
				if resolved < 0 || resolved >= cnt {
					return ATOM_ERROR
				}
				child_slot_maybe, err = xitdb.array_list_get_slot(al_col, resolved)
			}
		}
	case .Linked_Array_List:
		ll_col: xitdb.Read_Linked_Array_List
		ll_col, err = xitdb.read_linked_array_list_init(cur)
		if err == nil {
			cnt: i64
			cnt, err = xitdb.linked_array_list_count(ll_col)
			if err == nil {
				resolved := idx_int if idx_int >= 0 else cnt + idx_int
				if resolved < 0 || resolved >= cnt {
					return ATOM_ERROR
				}
				child_slot_maybe, err = xitdb.linked_array_list_get_slot(ll_col, resolved)
			}
		}
	case:
		return ATOM_ERROR
	}

	if err != nil {
		return make_xitdb_err(env, err)
	}
	child_slot, has_child := child_slot_maybe.?
	if !has_child {
		return ATOM_ERROR
	}

	term, t_err := slot_to_term(env, &handle.db, child_slot)
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	return make_ok(env, term)
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
<summary><code>xitdb.linked_array_list_get_cursor</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L141-L143">collections.odin#L141-L143</a></summary>

```odin
linked_array_list_get_cursor :: proc(a: Read_Linked_Array_List, index: i64) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(a.cursor, []Path_Part{Linked_Array_List_Get{index = index}})
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
<summary><code>xitdb.array_list_count</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L37-L39">collections.odin#L37-L39</a></summary>

```odin
array_list_count :: proc(a: Read_Array_List) -> (res: i64, err: Error) {
	return cursor_count(a.cursor)
}
```

</details>

<details>
<summary><code>xitdb.array_list_get_slot</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L45-L47">collections.odin#L45-L47</a></summary>

```odin
array_list_get_slot :: proc(a: Read_Array_List, index: i64) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(a.cursor, []Path_Part{Array_List_Get{index = index}})
}
```

</details>

<details>
<summary><code>xitdb.read_linked_array_list_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L116-L124">collections.odin#L116-L124</a></summary>

```odin
read_linked_array_list_init :: proc(cursor: Read_Cursor) -> (res: Read_Linked_Array_List, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Linked_Array_List:
		return Read_Linked_Array_List{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.linked_array_list_count</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L137-L139">collections.odin#L137-L139</a></summary>

```odin
linked_array_list_count :: proc(a: Read_Linked_Array_List) -> (res: i64, err: Error) {
	return cursor_count(a.cursor)
}
```

</details>

<details>
<summary><code>xitdb.linked_array_list_get_slot</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L145-L147">collections.odin#L145-L147</a></summary>

```odin
linked_array_list_get_slot :: proc(a: Read_Linked_Array_List, index: i64) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(a.cursor, []Path_Part{Linked_Array_List_Get{index = index}})
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
