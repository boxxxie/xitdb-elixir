# #7: `Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `enumerable` — #6–#11 (Enumerable Protocol & Subtree Materialization)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 810.0 ns (810.0 ns) | 264.0 ns (264.0 ns) | **`3.07x`** NIF Ratio |
| **Mean ± σ (CV)** | 859.0 ns ± 139.5 ns (16.2%) | 278.2 ns ± 31.5 ns (11.3%) | Welch `z` = `9.08` |
| **p95 / Max (`ns/op`)** | 1.05 µs / 1.10 µs | 321.6 ns / 334.0 ns | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L272-L279`](../bench_elixir.exs#L272-L279))

```elixir
      {7, "Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)", 1000,
       fn ->
         for i <- 0..999 do
           _ = Enum.member?(cset_cur, "u#{rem(i, 500)}")
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L975-L989`](../bench_client.odin#L975-L989))

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
<summary>Elixir <code>member?</code> — <a href="../../lib/xitdb/cursor.ex#L2686-L2775">lib/xitdb/cursor.ex#L2686-L2775</a></summary>

```elixir
  def member?(
        %Cursor{tx_mode: false, root: false, tag_id: tag_id, db_ref: db_ref, value: val},
        candidate
      )
      when tag_id in [11, 13, 15] and is_binary(candidate) do
    case NIF.nif_slot_contains(db_ref, tag_id, val, candidate) do
      {:ok, bool} -> {:ok, bool}
      {:error, reason} when reason in [:uncounted, :unsupported] -> {:error, __MODULE__}
      {:error, reason} -> raise Xitdb.Error, reason: reason
    end
  end

  def member?(
        %Cursor{tx_mode: false, root: false, tag_id: tag_id, db_ref: db_ref},
        candidate
      )
      when tag_id in [11, 13, 15] and not is_binary(candidate) do
    case NIF.nif_info(db_ref) do
      {:ok, _} -> {:ok, false}
      {:error, reason} -> raise Xitdb.Error, reason: reason
    end
  end

  def member?(%Cursor{} = raw_cursor, candidate) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0 or
            map_size(raw_cursor.staged_list_edits) > 0 or
            raw_cursor.fork_aliases != []) do
      {:error, __MODULE__}
    else
      %Cursor{db_ref: db_ref, tag: tag, tag_id: tag_id, value: val, root: root, moment: moment} =
        cursor = Cursor.ensure_resolved(raw_cursor)

      cond do
        root and match?({"__tx", _}, candidate) ->
          case NIF.nif_info(db_ref) do
            {:ok, _} -> {:ok, false}
            {:error, reason} -> raise Xitdb.Error, reason: reason
          end

        tag in [:hash_set, :counted_hash_set, :sorted_set] ->
          if is_binary(candidate) do
            {nid, nval} =
              cond do
                root and tag_id != -1 and val == 0 -> {tag_id, 0}
                root -> {-1, moment}
                true -> {tag_id, val}
              end

            case NIF.nif_slot_contains(db_ref, nid, nval, candidate) do
              {:ok, bool} -> {:ok, bool}
              {:error, reason} when reason in [:uncounted, :unsupported] -> {:error, __MODULE__}
              {:error, reason} -> raise Xitdb.Error, reason: reason
            end
          else
            case NIF.nif_info(db_ref) do
              {:ok, _} -> {:ok, false}
              {:error, reason} -> raise Xitdb.Error, reason: reason
            end
          end

        tag in [:hash_map, :counted_hash_map, :sorted_map] ->
          case candidate do
            {k, expected_v} when is_binary(k) ->
              fetch_cur = if root, do: raw_cursor, else: cursor

              case Cursor.fetch(fetch_cur, k) do
                {:ok, %Cursor{} = child_cur} ->
                  {:ok, Cursor.strict_equal?(Xitdb.materialize(child_cur), expected_v)}

                {:ok, actual_v} ->
                  {:ok, Cursor.strict_equal?(actual_v, expected_v)}

                :error ->
                  {:ok, false}
              end

            _ ->
              case NIF.nif_info(db_ref) do
                {:ok, _} -> {:ok, false}
                {:error, reason} -> raise Xitdb.Error, reason: reason
              end
          end

        true ->
          {:error, __MODULE__}
      end
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_slot_contains</code> — <a href="../../native/xitdb_nif.odin#L1321-L1419">native/xitdb_nif.odin#L1321-L1419</a></summary>

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

	found := false
	err: xitdb.Error = nil
	slot_maybe: Maybe(xitdb.Slot) = nil

	#partial switch slot.tag {
	case .Hash_Set:
		hs: xitdb.Read_Hash_Set
		hs, err = xitdb.read_hash_set_init(cur)
		if err == nil {
			slot_maybe, err = xitdb.hash_set_get_slot(hs, key_str)
		}
	case .Counted_Hash_Set:
		chs: xitdb.Read_Counted_Hash_Set
		chs, err = xitdb.read_counted_hash_set_init(cur)
		if err == nil {
			slot_maybe, err = xitdb.hash_set_get_slot(chs.read_hash_set, key_str)
		}
	case .Sorted_Set:
		ss: xitdb.Read_Sorted_Set
		ss, err = xitdb.read_sorted_set_init(cur)
		if err == nil {
			found, err = xitdb.sorted_set_contains(ss, key_str)
		}
	case .Hash_Map:
		hm: xitdb.Read_Hash_Map
		hm, err = xitdb.read_hash_map_init(cur)
		if err == nil {
			slot_maybe, err = xitdb.hash_map_get_slot(hm, key_str)
		}
	case .Counted_Hash_Map:
		chm: xitdb.Read_Counted_Hash_Map
		chm, err = xitdb.read_counted_hash_map_init(cur)
		if err == nil {
			slot_maybe, err = xitdb.hash_map_get_slot(chm.read_hash_map, key_str)
		}
	case .Sorted_Map:
		sm: xitdb.Read_Sorted_Map
		sm, err = xitdb.read_sorted_map_init(cur)
		if err == nil {
			slot_maybe, err = xitdb.sorted_map_get_slot(sm, key_str)
		}
	case:
		return make_err(env, "unsupported")
	}

	if err == .Key_Not_Found {
		return make_ok(env, ATOM_FALSE)
	}
	if err != nil {
		return make_xitdb_err(env, err)
	}
	if slot.tag == .Sorted_Set {
		return make_ok(env, ATOM_TRUE if found else ATOM_FALSE)
	}
	s, has_slot := slot_maybe.?
	return make_ok(env, ATOM_TRUE if (has_slot && (s.tag != .None || s.full)) else ATOM_FALSE)
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
<summary><code>xitdb.read_hash_set_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L520-L528">collections.odin#L520-L528</a></summary>

```odin
read_hash_set_init :: proc(cursor: Read_Cursor) -> (res: Read_Hash_Set, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Hash_Map, .Hash_Set:
		return Read_Hash_Set{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.read_counted_hash_set_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L537-L545">collections.odin#L537-L545</a></summary>

```odin
read_counted_hash_set_init :: proc(cursor: Read_Cursor) -> (res: Read_Counted_Hash_Set, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Counted_Hash_Map, .Counted_Hash_Set:
		return Read_Counted_Hash_Set{read_hash_set = Read_Hash_Set{cursor = cursor}}, nil
	case:
		return {}, .Unexpected_Tag
	}
}
```

</details>

<details>
<summary><code>xitdb.read_sorted_set_init</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L842-L850">collections.odin#L842-L850</a></summary>

```odin
read_sorted_set_init :: proc(cursor: Read_Cursor) -> (res: Read_Sorted_Set, err: Error) {
	slot_ptr := cursor_resolved(cursor) or_return
	#partial switch slot_ptr.slot.tag {
	case .None, .Sorted_Map, .Sorted_Set:
		return Read_Sorted_Set{cursor = cursor}, nil
	case:
		return {}, .Unexpected_Tag
	}
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
<summary><code>xitdb.database_digest_string_buf</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L280-L282">database.odin#L280-L282</a></summary>

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
