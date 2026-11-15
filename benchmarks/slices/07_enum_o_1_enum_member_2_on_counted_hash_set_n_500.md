# #7: `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `enumerable` — #6–#11 (Enumerable Protocol & Subtree Materialization)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 753.0 ns (753.0 ns) | 264.0 ns (264.0 ns) | **`2.85x`** NIF Ratio |
| **Mean ± σ (CV)** | 761.2 ns ± 23.8 ns (3.1%) | 265.0 ns ± 4.0 ns (1.5%) | Welch `z` = `45.94` |
| **p95 / Max (`ns/op`)** | 793.4 ns / 803.0 ns | 270.4 ns / 272.0 ns | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L240-L247`](../bench_elixir.exs#L240-L247))

```elixir
      {7, "Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)", 1000,
       fn ->
         for i <- 0..999 do
           _ = Enum.member?(cset_cur, "u#{rem(i, 500)}")
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L848-L862`](../bench_client.odin#L848-L862))

```odin
	// #7: O(1) Counted_Hash_Set membership check
	if r7 {
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for i in 0 ..< 1000 {
				uid := fmt.tprintf("u%d", i % 500)
				_, _ = xitdb.hash_set_get_slot(cset_chs.read_hash_set, uid)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 1000.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(7, "Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)", 1000, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>NIF <code>odin_nif_slot_contains</code> — <a href="../../native/xitdb_nif.odin#L1079-L1171">native/xitdb_nif.odin#L1079-L1171</a></summary>

```odin
odin_nif_slot_contains :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}
	tag_int: i64 = 0
	val_int: i64 = 0
	if nif_get_int64(env, argv[1], &tag_int) == 0 || nif_get_int64(env, argv[2], &val_int) == 0 {
		return make_err(env, "badarg")
	}
	key_str, ok_k := get_string_from_binary(env, argv[3])
	if !ok_k {
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
		return make_ok(env, ATOM_FALSE)
	}
	if is_root && key_str == "__tx" {
		return make_ok(env, ATOM_FALSE)
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	#partial switch slot.tag {
	case .Hash_Set, .Counted_Hash_Set:
		hs := xitdb.Read_Hash_Set{cursor = cur}
		slot_maybe, err := xitdb.hash_set_get_slot(hs, key_str)
		if err == .Key_Not_Found {
			return make_ok(env, ATOM_FALSE)
		}
		if err != nil {
			return make_xitdb_err(env, err)
		}
		_, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)

	case .Sorted_Set:
		ss := xitdb.Read_Sorted_Set{cursor = cur}
		found, err := xitdb.sorted_set_contains(ss, key_str)
		if err == .Key_Not_Found {
			return make_ok(env, ATOM_FALSE)
		}
		if err != nil {
			return make_xitdb_err(env, err)
		}
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)

	case .Hash_Map, .Counted_Hash_Map:
		hm := xitdb.Read_Hash_Map{cursor = cur}
		slot_maybe, err := xitdb.hash_map_get_slot(hm, key_str)
		if err == .Key_Not_Found {
			return make_ok(env, ATOM_FALSE)
		}
		if err != nil {
			return make_xitdb_err(env, err)
		}
		s, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if (found && (s.tag != .None || s.full)) else ATOM_FALSE)

	case .Sorted_Map:
		sm := xitdb.Read_Sorted_Map{cursor = cur}
		slot_maybe, err := xitdb.sorted_map_get_slot(sm, key_str)
		if err == .Key_Not_Found {
			return make_ok(env, ATOM_FALSE)
		}
		if err != nil {
			return make_xitdb_err(env, err)
		}
		s, found := slot_maybe.?
		return make_ok(env, ATOM_TRUE if (found && (s.tag != .None || s.full)) else ATOM_FALSE)
	}

	return make_err(env, "unsupported")
}
```

</details>

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.hash_set_get_slot</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L592-L596">collections.odin#L592-L596</a></summary>

```odin
hash_set_get_slot :: proc(s: Read_Hash_Set, key: string) -> (Maybe(Slot), Error) {
	buf: [64]u8 = ---
	hash := database_digest_string_buf(s.cursor.db, key, buf[:])
	return hash_set_get_slot_by_hash(s, hash)
}
```

</details>

<details>
<summary><code>xitdb.sorted_set_contains</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L915-L917">collections.odin#L915-L917</a></summary>

```odin
sorted_set_contains :: proc(s: Read_Sorted_Set, key: string) -> (res: bool, err: Error) {
	return sorted_set_contains_by_bytes(s, transmute([]u8)key)
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
<summary><code>xitdb.sorted_map_get_slot</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L793-L795">collections.odin#L793-L795</a></summary>

```odin
sorted_map_get_slot :: proc(m: Read_Sorted_Map, key: string) -> (Maybe(Slot), Error) {
	return sorted_map_get_slot_by_bytes(m, transmute([]u8)key)
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
<summary><code>xitdb.hash_set_get_slot_by_hash</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L582-L584">collections.odin#L582-L584</a></summary>

```odin
hash_set_get_slot_by_hash :: proc(s: Read_Hash_Set, hash: []u8) -> (Maybe(Slot), Error) {
	return cursor_read_path_slot(s.cursor, []Path_Part{Hash_Map_Get{target = Hash_Map_Get_Key{hash = hash}}})
}
```

</details>

<details>
<summary><code>xitdb.sorted_set_contains_by_bytes</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L909-L913">collections.odin#L909-L913</a></summary>

```odin
sorted_set_contains_by_bytes :: proc(s: Read_Sorted_Set, key: []u8) -> (res: bool, err: Error) {
	mc := cursor_read_path(s.cursor, []Path_Part{Sorted_Map_Get{target = Sorted_Map_Get_Key{key = key}}}) or_return
	_, ok := mc.?
	return ok, nil
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
<summary><code>xitdb.database_digest_buf</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L258-L265">database.odin#L258-L265</a></summary>

```odin
database_digest_buf :: proc(db: ^Database, data: []u8, buf: []u8) -> []u8 {
	hsize := int(db.header.hash_size)
	out := buf[:hsize] if hsize <= len(buf) else make([]u8, hsize, context.temp_allocator)
	if db.hasher.hash_proc != nil {
		db.hasher.hash_proc(data, out, db.hasher.user_data)
	}
	return out
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_path_slot</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L80-L94">cursor.odin#L80-L94</a></summary>

```odin
cursor_read_path_slot :: proc(c: Read_Cursor, path: []Path_Part) -> (res: Maybe(Slot), err: Error) {
	start := cursor_resolved(c) or_return
	slot_ptr: Slot_Pointer
	slot_ptr, err = read_slot_pointer(c.db, .Read_Only, path, 0, start, 0)
	if err != nil {
		if err == .Key_Not_Found {
			return nil, nil
		}
		return nil, err
	}
	if !slot_empty(slot_ptr.slot) {
		return slot_ptr.slot, nil
	}
	return nil, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_path</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L67-L78">cursor.odin#L67-L78</a></summary>

```odin
cursor_read_path :: proc(c: Read_Cursor, path: []Path_Part) -> (res: Maybe(Read_Cursor), err: Error) {
	start := cursor_resolved(c) or_return
	slot_ptr: Slot_Pointer
	slot_ptr, err = read_slot_pointer(c.db, .Read_Only, path, 0, start, 0)
	if err != nil {
		if err == .Key_Not_Found {
			return nil, nil
		}
		return nil, err
	}
	return Read_Cursor{slot_ptr = slot_ptr, db = c.db}, nil
}
```

</details>
