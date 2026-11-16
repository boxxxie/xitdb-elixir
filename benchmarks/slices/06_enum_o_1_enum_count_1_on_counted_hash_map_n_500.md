# #6: `Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `enumerable` — #6–#11 (Enumerable Protocol & Subtree Materialization)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 156.0 ns (156.0 ns) | 7.0 ns (7.0 ns) | **`22.29x`** NIF Ratio |
| **Mean ± σ (CV)** | 160.6 ns ± 9.9 ns (6.1%) | 9.4 ns ± 3.3 ns (35.0%) | Welch `z` = `32.52` |
| **p95 / Max (`ns/op`)** | 174.2 ns / 178.0 ns | 13.0 ns / 13.0 ns | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L264-L271`](../bench_elixir.exs#L264-L271))

```elixir
      {6, "Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)", 1000,
       fn ->
         for _ <- 1..1000 do
           _ = Enum.count(cusers_cur)
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L954-L966`](../bench_client.odin#L954-L966))

```odin
	// #6: O(1) Counted_Hash_Map count
	if r6 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 1000 {
				_, _ = xitdb.counted_hash_map_count(cusers_chm)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 1000.0
			}
		}
		record_samples(6, "Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)", 1000, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>count</code> — <a href="../../lib/xitdb/cursor.ex#L2564-L2595">lib/xitdb/cursor.ex#L2564-L2595</a></summary>

```elixir
  def count(%Cursor{tx_mode: false, root: false, tag_id: tag_id, db_ref: db_ref, value: val})
      when tag_id > 0 do
    case NIF.nif_slot_count(db_ref, tag_id, val) do
      {:ok, n} when is_integer(n) -> {:ok, n}
      {:error, reason} when reason in [:uncounted, :unsupported] -> {:error, __MODULE__}
      {:error, reason} -> raise Xitdb.Error, reason: reason
    end
  end

  def count(%Cursor{} = cursor) do
    if cursor.tx_mode and
         (map_size(cursor.staged_overrides) > 0 or MapSet.size(cursor.deleted_paths) > 0 or
            map_size(cursor.staged_list_edits) > 0 or cursor.fork_aliases != []) do
      {:error, __MODULE__}
    else
      %Cursor{db_ref: db_ref, tag_id: tag_id, value: val, root: root, moment: moment} =
        Cursor.ensure_resolved(cursor)

      {nid, nval} =
        cond do
          root and tag_id != -1 and val == 0 -> {tag_id, 0}
          root -> {-1, moment}
          true -> {tag_id, val}
        end

      case NIF.nif_slot_count(db_ref, nid, nval) do
        {:ok, n} when is_integer(n) -> {:ok, n}
        {:error, reason} when reason in [:uncounted, :unsupported] -> {:error, __MODULE__}
        {:error, reason} -> raise Xitdb.Error, reason: reason
      end
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_slot_count</code> — <a href="../../native/xitdb_nif.odin#L1208-L1279">native/xitdb_nif.odin#L1208-L1279</a></summary>

```odin
odin_nif_slot_count :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
		return make_err(env, "badarg")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
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

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List, .Counted_Hash_Map, .Counted_Hash_Set, .Sorted_Map, .Sorted_Set:
		if is_empty {
			return make_ok(env, nif_make_int64(env, 0))
		}
		cur := xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
			db       = &handle.db,
		}
		cnt, err := xitdb.cursor_count(cur)
		if err != nil {
			return make_xitdb_err(env, err)
		}
		if is_root && cnt > 0 {
			if slot.tag == .Counted_Hash_Map {
				if cm, cm_err := xitdb.read_counted_hash_map_init(cur); cm_err == nil {
					if tx_s, tx_err := xitdb.hash_map_get_slot(cm.read_hash_map, "__tx"); tx_err == nil {
						if s, found := tx_s.?; found && (s.tag != .None || s.full) {
							cnt -= 1
						}
					} else if tx_err != .Key_Not_Found {
						return make_xitdb_err(env, tx_err)
					}
				} else {
					return make_xitdb_err(env, cm_err)
				}
			} else if slot.tag == .Sorted_Map {
				if sm, sm_err := xitdb.read_sorted_map_init(cur); sm_err == nil {
					if tx_s, tx_err := xitdb.sorted_map_get_slot(sm, "__tx"); tx_err == nil {
						if s, found := tx_s.?; found && (s.tag != .None || s.full) {
							cnt -= 1
						}
					} else if tx_err != .Key_Not_Found {
						return make_xitdb_err(env, tx_err)
					}
				} else {
					return make_xitdb_err(env, sm_err)
				}
			}
		}
		return make_ok(env, nif_make_int64(env, cnt))
	}

	return make_err(env, "uncounted")
}
```

</details>

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.counted_hash_map_count</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L300-L302">collections.odin#L300-L302</a></summary>

```odin
counted_hash_map_count :: proc(m: Read_Counted_Hash_Map) -> (res: i64, err: Error) {
	return cursor_count(m.cursor)
}
```

</details>

<details>
<summary><code>xitdb.cursor_count</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L413-L447">cursor.odin#L413-L447</a></summary>

```odin
cursor_count :: proc(c: Read_Cursor) -> (res: i64, err: Error) {
	slot_ptr := cursor_resolved(c) or_return
	#partial switch slot_ptr.slot.tag {
	case .None:
		return 0, nil
	case .Array_List:
		hb: [ARRAY_LIST_HEADER_LENGTH]u8
		core_read_exact_at(c.db.core, slot_ptr.slot.value, hb[:]) or_return
		header := array_list_header_from_bytes(hb) or_return
		return header.size, nil
	case .Linked_Array_List, .Sorted_Map, .Sorted_Set:
		hb: [BTREE_HEADER_LENGTH]u8
		core_read_exact_at(c.db.core, slot_ptr.slot.value, hb[:]) or_return
		header := btree_header_from_bytes(hb) or_return
		return header.size, nil
	case .Bytes:
		return core_read_long_at(c.db.core, slot_ptr.slot.value)
	case .Short_Bytes:
		buf: [8]u8
		endian.unchecked_put_u64be(buf[:], u64(slot_ptr.slot.value))
		total_size := 6 if slot_ptr.slot.full else 8
		size := 0
		for b in buf {
			if b == 0 || size == total_size {
				break
			}
			size += 1
		}
		return i64(size), nil
	case .Counted_Hash_Map, .Counted_Hash_Set:
		return core_read_long_at(c.db.core, slot_ptr.slot.value)
	case:
		return 0, .Unexpected_Tag
	}
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
<summary><code>xitdb.database_digest_string_buf</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L267-L269">database.odin#L267-L269</a></summary>

```odin
database_digest_string_buf :: proc(db: ^Database, s: string, buf: []u8) -> []u8 {
	return database_digest_buf(db, transmute([]u8)s, buf)
}
```

</details>

<details>
<summary><code>xitdb.hash_map_get_slot_by_hash</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L308-L310">collections.odin#L308-L310</a></summary>

```odin
hash_map_get_slot_by_hash :: proc(m: Read_Hash_Map, hash: []u8) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(m.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Value{hash = hash}}})
}
```

</details>

<details>
<summary><code>xitdb.sorted_map_get_slot_by_bytes</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L754-L756">collections.odin#L754-L756</a></summary>

```odin
sorted_map_get_slot_by_bytes :: proc(m: Read_Sorted_Map, key: []u8) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(m.cursor, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_Value{key = key}}})
}
```

</details>

<details>
<summary><code>xitdb.is_root</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L411-L416">database.odin#L411-L416</a></summary>

```odin
is_root :: proc(slot_ptr: Slot_Pointer) -> bool {
	if pos, ok := slot_ptr.position.?; ok {
		return pos == ROOT_HEADER_START
	}
	return false
}
```

</details>
