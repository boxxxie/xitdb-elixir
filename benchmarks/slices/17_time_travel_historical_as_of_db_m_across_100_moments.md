# #17: `Time-Travel: Historical as_of(db, m) across 100 moments`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `time_travel` — #17–#20 (Historical as_of, history_of, diff_moments & Compaction)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 1.56 µs (1559.0 ns) | 365.0 ns (365.0 ns) | **`4.27x`** NIF Ratio |
| **Mean ± σ (CV)** | 1.51 µs ± 88.5 ns (5.9%) | 363.0 ns ± 7.1 ns (1.9%) | Welch `z` = `28.91` |
| **p95 / Max (`ns/op`)** | 1.59 µs / 1.59 µs | 370.2 ns / 371.0 ns | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L420-L428`](../bench_elixir.exs#L420-L428))

```elixir
      {17, "Time-Travel: Historical as_of(db, m) across 100 moments", 100,
       fn ->
         for m <- 0..99 do
           snap = Xitdb.as_of(hist_db, m)
           _ = snap["users"]["alice"]["score"]
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1287-L1307`](../bench_client.odin#L1287-L1307))

```odin
	// #17: Time-Travel as_of(db, moment) across 100 distinct historical moments
	if r17 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for m in 0 ..< 100 {
				mc, _ := xitdb.array_list_get_cursor(hist_al, i64(m))
				mm, _ := xitdb.read_hash_map_init(mc.?)
				uc, _ := xitdb.hash_map_get_cursor(mm, "users")
				um, _ := xitdb.read_hash_map_init(uc.?)
				ac, _ := xitdb.hash_map_get_cursor(um, "alice")
				am, _ := xitdb.read_hash_map_init(ac.?)
				sc, _ := xitdb.hash_map_get_cursor(am, "score")
				_, _ = xitdb.cursor_read_uint(sc.?)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 100.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(17, "Time-Travel: Historical as_of(db, m) across 100 moments", 100, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>as_of</code> — <a href="../../lib/xitdb.ex#L287-L308">lib/xitdb.ex#L287-L308</a></summary>

```elixir
  def as_of(%__MODULE__{db_ref: db_ref}, moment_index)
      when is_integer(moment_index) and moment_index >= 0 do
    %Cursor{
      db_ref: db_ref,
      tag: :hash_map,
      tag_id: -1,
      value: moment_index,
      moment: moment_index,
      root: true
    }
  end

  def as_of(%__MODULE__{db_ref: db_ref}, moment_index) when is_integer(moment_index) do
    case NIF.nif_moment_slot(db_ref, moment_index, true) do
      {:ok, tuple, resolved_moment} ->
        cursor = Cursor.from_nif_tuple(db_ref, tuple, resolved_moment)
        %Cursor{cursor | root: true}

      {:error, reason} ->
        raise Error, reason: reason, details: %{moment_index: moment_index}
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_moment_slot</code> — <a href="../../native/xitdb_nif.odin#L1260-L1324">native/xitdb_nif.odin#L1260-L1324</a></summary>

```odin
odin_nif_moment_slot :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 2 && argc != 3 {
		return make_err(env, "badarg")
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}
	with_index := argc == 3

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, -1, moment_idx)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	resolved_idx: i64 = -1
	if with_index && !is_empty {
		if moment_idx >= 0 {
			resolved_idx = moment_idx
		} else {
			rc := xitdb.database_root_cursor(&handle.db).read_cursor
			hist, h_err := xitdb.read_array_list_init(rc)
			if h_err != nil {
				return make_xitdb_err(env, h_err)
			}
			cnt, c_err := xitdb.array_list_count(hist)
			if c_err != nil {
				return make_xitdb_err(env, c_err)
			}
			resolved_idx = cnt + moment_idx
		}
	}
	if is_empty {
		empty_term := nif_make_tuple3(
			env,
			ATOM_CURSOR,
			nif_make_int64(env, i64(u8(xitdb.Tag.Hash_Map))),
			nif_make_int64(env, 0),
		)
		if with_index {
			return nif_make_tuple3(env, ATOM_OK, empty_term, nif_make_int64(env, -1))
		}
		return make_ok(env, empty_term)
	}

	term, t_err := slot_to_term(env, &handle.db, slot)
	if t_err != nil {
		return make_xitdb_err(env, t_err)
	}
	if with_index {
		return nif_make_tuple3(env, ATOM_OK, term, nif_make_int64(env, resolved_idx))
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
<summary><code>xitdb.array_list_get_cursor</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L41-L43">collections.odin#L41-L43</a></summary>

```odin
array_list_get_cursor :: proc(a: Read_Array_List, index: i64) -> (Maybe(Read_Cursor), Error) {
	return cursor_read_path(a.cursor, []Path_Part{Array_List_Get{index = index}})
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
<summary><code>xitdb.database_root_cursor</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L327-L342">database.odin#L327-L342</a></summary>

```odin
database_root_cursor :: proc(db: ^Database) -> Write_Cursor {
	root, err := database_read_root_slot(db)
	if err != nil {
		root = Slot{}
	}
	return Write_Cursor{
		read_cursor = Read_Cursor{
			slot_ptr = Slot_Pointer{
				position = i64(ROOT_HEADER_START),
				slot     = root,
			},
			db        = db,
			frozen_at = 0,
		},
	}
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
