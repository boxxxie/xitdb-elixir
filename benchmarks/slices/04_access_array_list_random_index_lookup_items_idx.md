# #4: `Access: Array_List random index lookup (items[idx])`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `access` — #1–#5 (Lazy Access Navigation & Point Lookups)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 376.0 ns (376.0 ns) | 106.0 ns (106.0 ns) | **`3.55x`** NIF Ratio |
| **Mean ± σ (CV)** | 375.0 ns ± 6.0 ns (1.6%) | 112.4 ns ± 14.9 ns (13.2%) | Welch `z` = `36.61` |
| **p95 / Max (`ns/op`)** | 381.2 ns / 382.0 ns | 132.4 ns / 139.0 ns | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L227-L234`](../bench_elixir.exs#L227-L234))

```elixir
      {4, "Access: Array_List random index lookup (items[idx])", 500,
       fn ->
         for i <- 0..499 do
           _ = items_cur[rem(i * 37, 500)]
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L840-L854`](../bench_client.odin#L840-L854))

```odin
	// #4: Array_List random index lookup
	if r4 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for i in 0 ..< 500 {
				ec, _ := xitdb.array_list_get_cursor(items_al, i64((i * 37) % 500))
				_, _ = xitdb.cursor_read_string(ec.?, 0, context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(4, "Access: Array_List random index lookup (items[idx])", 500, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>fetch</code> — <a href="../../lib/xitdb/cursor.ex#L100-L152">lib/xitdb/cursor.ex#L100-L152</a></summary>

```elixir
  def fetch(%__MODULE__{} = cursor, key) when is_atom(key) do
    fetch(cursor, Atom.to_string(key))
  end

  def fetch(%__MODULE__{tx_mode: false} = cursor, key)
      when is_integer(key) or is_binary(key) do
    case nif_slot_get(cursor, key) do
      {:ok, {:cursor, _, _, _, _} = tuple} ->
        {:ok, from_nif_tuple(cursor.db_ref, tuple, cursor.moment)}

      {:ok, scalar} ->
        {:ok, scalar}

      :error ->
        :error

      {:error, reason} ->
        raise Xitdb.Error, reason: reason
    end
  end

  def fetch(%__MODULE__{tx_mode: true} = raw_cursor, key)
      when is_integer(key) or is_binary(key) do
    cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
    resolved_key = resolve_list_key(cursor, key)
    child_key = if is_integer(resolved_key), do: resolved_key, else: to_string(resolved_key)
    child_steps = [{cursor.tag, child_key} | cursor.path_steps]

    case lookup_staged(cursor, child_steps) do
      {:staged, val} ->
        {:ok, val}

      :deleted ->
        :error

      :miss ->
        if cursor.value == 0 and pointer_container_tag?(cursor.tag) do
          maybe_fetch_staged_descendant(cursor, child_steps)
        else
          case nif_slot_get(cursor, key) do
            {:ok, raw} ->
              val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
              {:ok, inherit_staged(val, cursor)}

            :error ->
              maybe_fetch_staged_descendant(cursor, child_steps)

            {:error, reason} ->
              raise Xitdb.Error, reason: reason
          end
        end
    end
  end
```

</details>

<details>
<summary>Elixir <code>nif_slot_get</code> — <a href="../../lib/xitdb/cursor.ex#L154-L162">lib/xitdb/cursor.ex#L154-L162</a></summary>

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
<summary>NIF <code>odin_nif_slot_get_index</code> — <a href="../../native/xitdb_nif.odin#L948-L1035">native/xitdb_nif.odin#L948-L1035</a></summary>

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

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.array_list_get_cursor</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L41-L43">collections.odin#L41-L43</a></summary>

```odin
array_list_get_cursor :: proc(a: Read_Array_List, index: i64) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(a.cursor, []Path_Part{Array_List_Get{index = index}})
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
