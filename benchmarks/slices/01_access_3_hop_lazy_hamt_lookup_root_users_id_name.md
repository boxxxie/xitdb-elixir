# #1: `Access: 3-hop lazy HAMT lookup (root[users][id][name])`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `access` — #1–#5, #28, #32 (Lazy Access Navigation, Point Lookups, Batched Key Fetch & Pre-Tokenized DSL Select)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 854.0 ns (854.0 ns) | 385.0 ns (385.0 ns) | **`2.22x`** NIF Ratio |
| **Mean ± σ (CV)** | 861.0 ns ± 13.3 ns (1.5%) | 386.2 ns ± 5.6 ns (1.5%) | Welch `z` = `73.58` |
| **p95 / Max (`ns/op`)** | 878.4 ns / 881.0 ns | 393.8 ns / 396.0 ns | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L235-L242`](../bench_elixir.exs#L235-L242))

```elixir
      {1, "Access: 3-hop lazy HAMT lookup (root[users][id][name])", 500,
       fn ->
         for i <- 0..499 do
           _ = root["users"]["u#{i}"]["name"]
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L948-L967`](../bench_client.odin#L948-L967))

```odin
	// #1: 3-hop lazy HAMT lookup
	if r1 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for i in 0 ..< 500 {
				uid := fmt.tprintf("u%d", i)
				u_cur, _ := xitdb.hash_map_get_cursor(m0_map, "users")
				um, _ := xitdb.read_hash_map_init(u_cur.?)
				id_cur, _ := xitdb.hash_map_get_cursor(um, uid)
				idm, _ := xitdb.read_hash_map_init(id_cur.?)
				n_cur, _ := xitdb.hash_map_get_cursor(idm, "name")
				_, _ = xitdb.cursor_read_string(n_cur.?, 0, context.temp_allocator)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(1, "Access: 3-hop lazy HAMT lookup (root[users][id][name])", 500, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>fetch</code> — <a href="../../lib/xitdb/cursor.ex#L207-L269">lib/xitdb/cursor.ex#L207-L269</a></summary>

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
<summary>Elixir <code>nif_slot_get</code> — <a href="../../lib/xitdb/cursor.ex#L409-L417">lib/xitdb/cursor.ex#L409-L417</a></summary>

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
<summary>NIF <code>odin_nif_slot_get_key</code> — <a href="../../native/xitdb_nif.odin#L1331-L1413">native/xitdb_nif.odin#L1331-L1413</a></summary>

```odin
odin_nif_slot_get_key :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}
	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	tag_int: i64 = 0
	val_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	key_str, ok_k := get_string_from_binary(env, argv[3])
	if !ok_k {
		return make_err(env, "badarg")
	}

	slot, is_root, is_empty, r_err, err_reason := resolve_slot_arg(handle, tag_int, val_int)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty || (is_root && key_str == "__tx") {
		return ATOM_ERROR
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	child_slot_maybe: Maybe(xitdb.Slot) = nil
	err: xitdb.Error = nil

	#partial switch slot.tag {
	case .Hash_Map:
		m: xitdb.Read_Hash_Map
		m, err = xitdb.read_hash_map_init(cur)
		if err == nil {
			child_slot_maybe, err = xitdb.hash_map_get_slot(m, key_str)
		}
	case .Counted_Hash_Map:
		cm: xitdb.Read_Counted_Hash_Map
		cm, err = xitdb.read_counted_hash_map_init(cur)
		if err == nil {
			child_slot_maybe, err = xitdb.hash_map_get_slot(cm.read_hash_map, key_str)
		}
	case .Sorted_Map:
		sm_col: xitdb.Read_Sorted_Map
		sm_col, err = xitdb.read_sorted_map_init(cur)
		if err == nil {
			child_slot_maybe, err = xitdb.sorted_map_get_slot(sm_col, key_str)
		}
	case:
		return ATOM_ERROR
	}

	if err != nil {
		return make_xitdb_err(env, err)
	}
	child_slot, has_child := child_slot_maybe.?
	if !has_child || (child_slot.tag == .None && !child_slot.full) {
		return ATOM_ERROR
	}

	codec_err := ""
	term, t_err := slot_to_term(env, &handle.db, child_slot, false, &codec_err)
	if t_err != nil {
		if len(codec_err) > 0 {
			return make_err(env, codec_err)
		}
		return make_xitdb_err(env, t_err)
	}
	return make_ok(env, term)
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
<summary>NIF <code>validate_bytes_slot_bounds</code> — <a href="../../native/xitdb_nif.odin#L350-L367">native/xitdb_nif.odin#L350-L367</a></summary>

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
<summary>NIF <code>decode_cz_to_term</code> — <a href="../../native/xitdb_nif.odin#L409-L447">native/xitdb_nif.odin#L409-L447</a></summary>

```odin
decode_cz_to_term :: proc(
	env: ErlNifEnv,
	payload: []u8,
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES,
) -> (term: ERL_NIF_TERM, err_atom: string) {
	if len(payload) < 5 {
		return ATOM_NIL, "corrupt_compressed_payload"
	}
	if (payload[0] & 0xFE) != 0x10 {
		return ATOM_NIL, "corrupt_compressed_payload"
	}
	raw_len := u64(payload[1]) | (u64(payload[2]) << 8) | (u64(payload[3]) << 16) | (u64(payload[4]) << 24)
	if raw_len > max_bytes {
		return ATOM_NIL, "decompressed_size_exceeded"
	}
	comp := payload[5:]
	if len(comp) == 0 {
		return ATOM_NIL, "corrupt_compressed_payload"
	}
	if raw_len == 0 {
		zero_buf: [1]u8
		dest_len := zlib.uLongf(len(zero_buf))
		rc := zlib.uncompress(&zero_buf[0], &dest_len, raw_data(comp), zlib.uLong(len(comp)))
		if rc != zlib.OK || dest_len != 0 {
			return ATOM_NIL, "corrupt_compressed_payload"
		}
		return nif_make_binary_slice(env, nil, 0), ""
	}
	dst := nif_alloc_binary_term(env, c.size_t(raw_len), &term)
	if dst == nil {
		return ATOM_NIL, "alloc_failed"
	}
	dest_len := zlib.uLongf(raw_len)
	rc := zlib.uncompress(dst, &dest_len, raw_data(comp), zlib.uLong(len(comp)))
	if rc != zlib.OK || u64(dest_len) != raw_len {
		return ATOM_NIL, "corrupt_compressed_payload"
	}
	return term, ""
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
<summary><code>xitdb.read_hash_map_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L246-L254">collections.odin#L246-L254</a></summary>

```odin
read_hash_map_init :: proc(cursor: Read_Cursor) -> (res: Read_Hash_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Hash_Map, .Hash_Set:
		return Read_Hash_Map{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
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
<summary><code>xitdb.hash_map_get_slot</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L336-L340">collections.odin#L336-L340</a></summary>

```odin
hash_map_get_slot :: proc(m: Read_Hash_Map, key: string) -> (Maybe(Slot), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(m.cursor.db, key, buf[:])
	return hash_map_get_slot_by_hash(m, hash)
}
```

</details>

<details>
<summary><code>xitdb.read_counted_hash_map_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L263-L271">collections.odin#L263-L271</a></summary>

```odin
read_counted_hash_map_init :: proc(cursor: Read_Cursor) -> (res: Read_Counted_Hash_Map, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Counted_Hash_Map, .Counted_Hash_Set:
		return Read_Counted_Hash_Map{read_hash_map = Read_Hash_Map{cursor = cursor}}, nil
	case:
		return {}, .Unexpected_Tag
	}
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
<summary><code>xitdb.sorted_map_get_slot</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L793-L795">collections.odin#L793-L795</a></summary>

```odin
sorted_map_get_slot :: proc(m: Read_Sorted_Map, key: string) -> (Maybe(Slot), Error) {
	return sorted_map_get_slot_by_bytes(m, transmute([]u8)key)
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
