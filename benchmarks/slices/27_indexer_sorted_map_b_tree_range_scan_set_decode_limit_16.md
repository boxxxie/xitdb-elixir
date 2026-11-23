# #27: `Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#27, #31 (Pull Projections, Datalog Engine, Buffered Sync, Search & Indexer)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 5.70 µs (5704.0 ns) | 4.33 µs (4330.0 ns) | **`1.32x`** NIF Ratio |
| **Mean ± σ (CV)** | 5.90 µs ± 468.0 ns (7.9%) | 4.37 µs ± 78.2 ns (1.8%) | Welch `z` = `7.22` |
| **p95 / Max (`ns/op`)** | 6.48 µs / 6.53 µs | 4.47 µs / 4.50 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L530-L546`](../bench_elixir.exs#L530-L546))

```elixir
      {27, "Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _entries, _next} =
             Xitdb.NIF.nif_sorted_map_seek(
               idx_db.db_ref,
               idx_btree.tag_id,
               idx_btree.value,
               "k10",
               16,
               false,
               true
             )
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1547-L1625`](../bench_client.odin#L1547-L1625))

```odin
	// #27: Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)
	idx_core: xitdb.Core
	idx_db: xitdb.Database
	defer if need_idx_db {
		xitdb.core_destroy(&idx_core)
	}
	if need_idx_db {
		idx_core = xitdb.core_memory_init()
		idx_db, _ = xitdb.database_init(&idx_core, xitdb.sha1_hasher())
		seed_idx_fixture_db(&idx_db, 64)
	}
	if r27 {
		i_rc := xitdb.database_root_cursor(&idx_db).read_cursor
		i_hist, _ := xitdb.read_array_list_init(i_rc)
		i_m0_cur, _ := xitdb.array_list_get_cursor(i_hist, 0)
		i_m0_map, _ := xitdb.read_hash_map_init(i_m0_cur.?)
		idx_c_maybe, _ := xitdb.hash_map_get_cursor(i_m0_map, "idx_btree")
		idx_cur := idx_c_maybe.?
		sb_k: [128]u8 = ---
		sb_m: [128]u8 = ---
		acc: u64 = 0
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 50 {
				idx_sm, _ := xitdb.read_sorted_map_init(idx_cur)
				it, _ := xitdb.sorted_map_iterator_from_string(idx_sm, "k10")
				cnt := 0
				for {
					nm, _ := xitdb.cursor_iterator_next(&it)
					ec, hn := nm.?
					if !hn {
						break
					}
					key_cur, val_cur, _ := xitdb.cursor_read_kv_pair_slots(ec)
					ks: string
					if bo, b_err := xitdb.cursor_read_bytes_buf(key_cur, sb_k[:]); b_err == nil {
						ks = string(bo.value)
					} else {
						ks, _ = xitdb.cursor_read_string(key_cur, 0, context.temp_allocator)
					}
					acc += u64(len(ks))
					if len(ks) > 0 {
						acc += u64(ks[0])
					}
					if cnt == 16 {
						break
					}
					mit, _ := xitdb.cursor_iterator(val_cur)
					for {
						mnm, _ := xitdb.cursor_iterator_next(&mit)
						mec, mhn := mnm.?
						if !mhn {
							break
						}
						mkey_cur, _, _ := xitdb.cursor_read_kv_pair_slots(mec)
						if mbo, m_err := xitdb.cursor_read_bytes_buf(mkey_cur, sb_m[:]); m_err == nil {
							acc += u64(len(mbo.value))
							if len(mbo.value) > 0 {
								acc += u64(mbo.value[0])
							}
						} else {
							ms, _ := xitdb.cursor_read_string(mkey_cur, 0, context.temp_allocator)
							acc += u64(len(ms))
							if len(ms) > 0 {
								acc += u64(ms[0])
							}
						}
					}
					cnt += 1
				}
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 50.0
			}
			free_all(context.temp_allocator)
		}
		intrinsics.volatile_store(&g_bench_sink, g_bench_sink + acc)
		record_samples(27, "Indexer: Sorted_Map B+Tree range scan + set decode (limit=16)", 50, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>nif_sorted_map_seek</code> — <a href="../../lib/xitdb/nif.ex#L120-L121">lib/xitdb/nif.ex#L120-L121</a></summary>

```elixir
  def nif_sorted_map_seek(_db_ref, _slot_tag_id, _slot_val_int, _prefix_bin, _limit_int),
    do: :erlang.nif_error(:nif_not_loaded)
```

</details>

<details>
<summary>Elixir <code>scan_prefix</code> — <a href="../../lib/xitdb/ash/search.ex#L1744-L1799">lib/xitdb/ash/search.ex#L1744-L1799</a></summary>

```elixir
    def scan_prefix(db, collection, prefix, limit, backend \\ :auto)

    def scan_prefix(db, collection, prefix, limit, :elixir) do
      case get_in_search(db, collection, "terms") do
        %Xitdb.Cursor{tx_mode: false, tag: :sorted_map} = terms ->
          scan_prefix_via_slot_entries_cursor(terms, prefix, limit)

        other ->
          scan_prefix_from_map_or_cursor(other, prefix, limit)
      end
    end

    def scan_prefix(db, collection, prefix, limit, _backend) do
      case get_in_search(db, collection, "terms") do
        %Xitdb.Cursor{
          db_ref: db_ref,
          tag: :sorted_map,
          tag_id: tag_id,
          value: val,
          moment: moment,
          tx_mode: false
        } ->
          if tag_id > 0 do
            case Xitdb.NIF.nif_sorted_map_seek(db_ref, tag_id, val, prefix, limit, true, true) do
              {:ok, entries, _next} ->
                Enum.map(entries, fn
                  {term, postings} when is_list(postings) ->
                    {term, Xitdb.Cursor.unwrap_nif_entries(db_ref, postings, moment)}

                  {term, p_tag_id, p_val} when is_integer(p_tag_id) and is_integer(p_val) ->
                    {term,
                     db_ref
                     |> Xitdb.Cursor.from_compact_slot(p_tag_id, p_val, moment)
                     |> Enum.to_list()}

                  {term, {:cursor, _, _} = slot_tuple} ->
                    {term,
                     db_ref
                     |> Xitdb.Cursor.from_nif_tuple(slot_tuple, moment)
                     |> Enum.to_list()}

                  {term, _other} ->
                    {term, []}
                end)

              {:error, reason} ->
                raise Xitdb.Error, reason: reason
            end
          else
            []
          end

        other ->
          scan_prefix_from_map_or_cursor(other, prefix, limit)
      end
    end
```

</details>

<details>
<summary>Elixir <code>stream_btree_from_key</code> — <a href="../../lib/xitdb/ash/indexer.ex#L2280-L2322">lib/xitdb/ash/indexer.ex#L2280-L2322</a></summary>

```elixir
    defp stream_btree_from_key(btree, start_hex) do
      Stream.unfold({start_hex, 16}, fn
        {nil, _limit} ->
          nil

        {cursor_key, page_limit} ->
          case Xitdb.NIF.nif_sorted_map_seek(
                 btree.db_ref,
                 btree.tag_id,
                 btree.value,
                 cursor_key,
                 page_limit,
                 false,
                 false
               ) do
            {:ok, [], _next} ->
              nil

            {:ok, chunk, next_cursor} ->
              {chunk, {next_cursor, 64}}

            {:error, reason} ->
              raise Xitdb.Error, reason: reason
          end
      end)
      |> Stream.flat_map(& &1)
      |> Stream.map(fn
        {hex_key, set_tag_id, set_val} when is_integer(set_tag_id) and is_integer(set_val) ->
          {decode_btree_key(hex_key),
           Xitdb.Cursor.from_compact_slot(btree.db_ref, set_tag_id, set_val, btree.moment)}

        {hex_key, {:cursor, _, _} = slot_tuple} ->
          {decode_btree_key(hex_key),
           Xitdb.Cursor.from_nif_tuple(btree.db_ref, slot_tuple, btree.moment)}

        {hex_key, ids} when is_list(ids) ->
          {decode_btree_key(hex_key),
           Xitdb.Cursor.unwrap_nif_entries(btree.db_ref, ids, btree.moment)}

        {hex_key, _other} ->
          {decode_btree_key(hex_key), []}
      end)
    end
```

</details>

<details>
<summary>Elixir <code>from_compact_slot</code> — <a href="../../lib/xitdb/cursor.ex#L129-L140">lib/xitdb/cursor.ex#L129-L140</a></summary>

```elixir
  def from_compact_slot(db_ref, tag_id, val, moment, path_steps \\ [])
      when is_integer(tag_id) and is_integer(val) do
    %__MODULE__{
      db_ref: db_ref,
      tag: tag_atom_for(tag_id),
      tag_id: tag_id,
      value: val,
      full: false,
      moment: moment,
      path_steps: path_steps
    }
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_sorted_map_seek</code> — <a href="../../native/xitdb_nif.odin#L10966-L11160">native/xitdb_nif.odin#L10966-L11160</a></summary>

```odin
odin_nif_sorted_map_seek :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	arena_alloc := context.temp_allocator
	context.allocator = arena_alloc

	if argc != 5 && argc != 6 && argc != 7 {
		return make_err(env, "badarg")
	}

	prefix_only := true
	if argc >= 6 {
		if argv[5] == ATOM_TRUE {
			prefix_only = true
		} else if argv[5] == ATOM_FALSE {
			prefix_only = false
		} else {
			return make_err(env, "badarg")
		}
	}

	decode_children := false
	if argc == 7 {
		if argv[6] == ATOM_TRUE {
			decode_children = true
		} else if argv[6] == ATOM_FALSE {
			decode_children = false
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

	if slot.tag != .Sorted_Map && slot.tag != .None {
		return make_err(env, "unsupported")
	}

	if is_empty || slot.tag == .None || limit_int <= 0 {
		empty_list := nif_make_list_from_array(env, nil, 0)
		return nif_make_tuple3(env, ATOM_OK, empty_list, ATOM_NIL)
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = &handle.db,
	}

	sm_col, sm_err := xitdb.read_sorted_map_init(cur)
	if sm_err != nil {
		return make_xitdb_err(env, sm_err)
	}

	it, it_alloc_err := nif_alloc_cursor_iterator(arena_alloc)
	if it_alloc_err != nil {
		return make_xitdb_err(env, it_alloc_err)
	}
	if it_err := xitdb.cursor_iterator_sorted_from_key_init(it, sm_col.cursor, transmute([]u8)prefix); it_err != nil {
		return make_xitdb_err(env, it_err)
	}
	child_it: ^xitdb.Cursor_Iterator = nil
	if decode_children {
		child_alloc_err: xitdb.Error
		child_it, child_alloc_err = nif_alloc_cursor_iterator(arena_alloc)
		if child_alloc_err != nil {
			return make_xitdb_err(env, child_alloc_err)
		}
	}

	item_buf: [64]ERL_NIF_TERM = ---
	item_len := 0
	item_dyn: [dynamic]ERL_NIF_TERM
	using_dyn := false
	defer if using_dyn {
		delete(item_dyn)
	}
	next_cursor_term: ERL_NIF_TERM = ATOM_NIL
	emitted: i64 = 0
	total_fused: i64 = 0
	sb_buf: [128]u8 = ---
	codec_err := ""

	for {
		next_maybe, n_err := xitdb.cursor_iterator_next(it)
		if n_err != nil {
			return make_xitdb_err(env, n_err)
		}
		elem_cur, has_next := next_maybe.?
		if !has_next {
			break
		}

		key_cur, val_cur, kv_err := xitdb.cursor_read_kv_pair_slots(elem_cur)
		if kv_err != nil {
			return make_xitdb_err(env, kv_err)
		}
		k_str, k_err := read_key_cursor_string(key_cur, sb_buf[:])
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

		val_slot := val_cur.slot_ptr.slot
		entry_term: ERL_NIF_TERM
		if is_container_tag(val_slot.tag) {
			fused := false
			if decode_children && total_fused < MAX_FUSED_TOTAL_ENTRIES {
				budget := min(i64(MAX_FUSED_CHILD_ENTRIES), i64(MAX_FUSED_TOTAL_ENTRIES) - total_fused)
				children_term, child_cnt, exceeded, c_err := decode_child_container_entries_term(
					env,
					&handle.db,
					val_slot,
					budget,
					arena_alloc,
					&codec_err,
					child_it,
				)
				if c_err != nil {
					if len(codec_err) > 0 {
						return make_err(env, codec_err)
					}
					return make_xitdb_err(env, c_err)
				}
				total_fused += child_cnt
				if !exceeded {
					entry_term = nif_make_tuple2(env, make_binary(env, k_str), children_term)
					fused = true
				}
			}
			if !fused {
				entry_term = nif_make_tuple3(
					env,
					make_binary(env, k_str),
					nif_make_int64(env, i64(u8(val_slot.tag))),
					nif_make_int64(env, val_slot.value),
				)
			}
		} else {
			val_term, vt_err := slot_to_term(env, &handle.db, val_slot, false, &codec_err)
			if vt_err != nil {
				if len(codec_err) > 0 {
					return make_err(env, codec_err)
				}
				return make_xitdb_err(env, vt_err)
			}
			entry_term = nif_make_tuple2(env, make_binary(env, k_str), val_term)
		}

		push_nif_term(
			item_buf[:],
			&item_len,
			&item_dyn,
			&using_dyn,
			entry_term,
			arena_alloc,
		)
		emitted += 1
	}

	list_term := make_list_from_term_buf(env, item_buf[:], item_len, item_dyn, using_dyn)
	return nif_make_tuple3(env, ATOM_OK, list_term, next_cursor_term)
}
```

</details>

<details>
<summary>NIF <code>decode_child_container_entries_term</code> — <a href="../../native/xitdb_nif.odin#L10872-L10959">native/xitdb_nif.odin#L10872-L10959</a></summary>

```odin
decode_child_container_entries_term :: proc(
	env: ErlNifEnv,
	db: ^xitdb.Database,
	slot: xitdb.Slot,
	max_entries: i64,
	arena_alloc: mem.Allocator,
	codec_err: ^string = nil,
	reusable_it: ^xitdb.Cursor_Iterator = nil,
) -> (res: ERL_NIF_TERM, count: i64, exceeded: bool, err: xitdb.Error) {
	if slot.tag == .None || slot.value == 0 {
		return nif_make_list_from_array(env, nil, 0), 0, false, nil
	}
	if max_entries <= 0 {
		return ATOM_NIL, 0, true, nil
	}

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List, .Counted_Hash_Map, .Counted_Hash_Set, .Sorted_Map, .Sorted_Set:
		cnt, c_err := xitdb.cursor_count(cur)
		if c_err != nil {
			return ATOM_NIL, 0, false, c_err
		}
		if cnt > max_entries {
			return ATOM_NIL, 0, true, nil
		}
	}

	it := reusable_it
	if it == nil {
		it = nif_alloc_cursor_iterator(arena_alloc) or_return
	}
	xitdb.cursor_iterator_init(it, cur) or_return

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
	emitted: i64 = 0

	for {
		next_maybe := xitdb.cursor_iterator_next(it) or_return
		elem_cur, has_e := next_maybe.?
		if !has_e {
			break
		}
		if emitted >= max_entries {
			return ATOM_NIL, emitted, true, nil
		}

		if is_map {
			key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			key_slot := key_cur.slot_ptr.slot
			k_term: ERL_NIF_TERM
			if !key_slot.full && (key_slot.tag == .Short_Bytes || key_slot.tag == .Bytes) {
				k_str := read_key_cursor_string(key_cur, sb_buf[:]) or_return
				k_term = make_binary(env, k_str)
			} else {
				k_term = slot_to_term(env, db, key_slot, false, codec_err) or_return
			}
			val_term := slot_to_term(env, db, val_cur.slot_ptr.slot, false, codec_err) or_return
			pair := nif_make_tuple2(env, k_term, val_term)
			push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, pair, arena_alloc)
		} else if is_set {
			key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			elem_term := slot_to_term(env, db, key_cur.slot_ptr.slot, false, codec_err) or_return
			push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, elem_term, arena_alloc)
		} else {
			elem_slot := xitdb.cursor_slot(elem_cur) or_return
			elem_term := slot_to_term(env, db, elem_slot, false, codec_err) or_return
			push_nif_term(stack_buf[:], &buf_len, &dyn_items, &using_dyn, elem_term, arena_alloc)
		}
		emitted += 1
	}

	return make_list_from_term_buf(env, stack_buf[:], buf_len, dyn_items, using_dyn), emitted, false, nil
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

## Reachable `xitdb` Core Procedures

<details>
<summary><code>xitdb.core_destroy</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L351-L380">core.odin#L351-L380</a></summary>

```odin
core_destroy :: proc(c: ^Core, close_file := false) -> Error {
	switch &v in c {
	case Core_Memory:
		_memory_destroy(&v)
	case Core_File:
		if close_file && v.file != nil {
			os.close(v.file) or_return
			v.file = nil
		}
	case Core_Buffered_File:
		_ = _buffered_flush(&v)
		if v.memory.vmem_reserved > 0 {
			if raw_data(v.memory.buf) != nil {
				vmem.release(raw_data(v.memory.buf), uint(v.memory.vmem_reserved))
			}
			v.memory.buf = nil
			v.memory.vmem_reserved = 0
		} else {
			delete(v.memory.buf)
			v.memory.buf = nil
		}
		if close_file && v.file.file != nil {
			os.close(v.file.file) or_return
			v.file.file = nil
		}
	case Core_Overlay:
		_overlay_destroy(&v)
	}
	return nil
}
```

</details>

<details>
<summary><code>xitdb.core_memory_init</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L85-L112">core.odin#L85-L112</a></summary>

```odin
core_memory_init :: proc(allocator := context.allocator, reserve_size: int = DEFAULT_VMEM_RESERVE_SIZE) -> Core {
	if reserve_size > 0 {
		aligned_reserve := _vmem_align_page(reserve_size)
		if reserved_slice, r_err := vmem.reserve(uint(aligned_reserve)); r_err == .None && raw_data(reserved_slice) != nil {
			initial_commit := min(_vmem_align_page(4096), aligned_reserve)
			if c_err := vmem.commit(raw_data(reserved_slice), uint(initial_commit)); c_err == .None {
				raw_arr := runtime.Raw_Dynamic_Array{
					data      = raw_data(reserved_slice),
					len       = 0,
					cap       = initial_commit,
					allocator = runtime.nil_allocator(),
				}
				return Core_Memory{
					buf           = transmute([dynamic]u8)raw_arr,
					pos           = 0,
					allocator     = allocator,
					vmem_reserved = aligned_reserve,
				}
			}
			vmem.release(raw_data(reserved_slice), uint(aligned_reserve))
		}
	}
	return Core_Memory{
		buf       = make([dynamic]u8, 0, 1024, allocator),
		pos       = 0,
		allocator = allocator,
	}
}
```

</details>

<details>
<summary><code>xitdb.database_init</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L184-L250">database.odin#L184-L250</a></summary>

```odin
database_init :: proc(core: ^Core, hasher := Hasher{}) -> (db: Database, err: Error) {
	h := hasher
	if h.hash_proc == nil && h.hash_size == 0 {
		h = sha1_hasher()
	}

	// If buffered file, clear any stale buffer bytes before opening.
	#partial switch &bf in core {
	case Core_Buffered_File:
		clear(&bf.memory.buf)
		bf.memory_pos = 0
		bf.pos = 0
		bf.file_len = nil
	}

	db.core = core
	db.hasher = h
	db.tx_start = nil
	db.tx_seq = 0
	db.transaction = nil

	core_seek_to(core, 0) or_return
	length := core_length(core) or_return

	// A database whose first commit never finished holds nothing. If it is no
	// bigger than a new database, it was interrupted while being created, so
	// it is created again. Otherwise it is a full copy that was interrupted
	// (see `database_apply_replicated`), which is left for the next sync to replace.
	has_commit := false
	if length > 0 {
		db.header = database_read_and_validate_header(&db) or_return
		fsize := database_read_file_size(&db) or_return
		has_commit = fsize > 0
		new_size := database_file_size_start(db.header.version) + 8 + ROOT_TRAILER_LENGTH
		if !has_commit && length <= new_size {
			core_set_length(core, 0) or_return
			length = 0
		}
	}

	if length == 0 {
		file_id := h.file_id
		if file_id == 0 {
			file_id = _random_u64()
		}
		digest_len := h.hash_size
		if digest_len == 0 {
			digest_len = 20
		}
		db.header = Header{
			file_id      = file_id,
			hash_id      = h.id,
			hash_size    = digest_len,
			version      = VERSION,
			padding      = 0,
			magic_number = MAGIC_NUMBER,
		}
		database_write_headers(&db) or_return
		database_commit_root(&db, Slot{}, 0) or_return
		core_sync(core) or_return
	} else if has_commit {
		_ = database_committed_size(&db) or_return
	}

	db.tx_start = nil
	return db, nil
}
```

</details>

<details>
<summary><code>xitdb.sha1_hasher</code> — <a href="../../native/xitdb-odin/xitdb/types.odin#L357-L366">types.odin#L357-L366</a></summary>

```odin
sha1_hasher :: proc(id: u32 = 0, file_id: u64 = 0) -> Hasher {
	return Hasher{
		hash_proc = proc(data: []u8, out_hash: []u8, _: rawptr) {
			sha1_sum_into(data, out_hash)
		},
		hash_size = 20,
		id        = id,
		file_id   = file_id,
	}
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
<summary><code>xitdb.sorted_map_iterator_from_string</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L726-L728">collections.odin#L726-L728</a></summary>

```odin
sorted_map_iterator_from_string :: proc(m: Read_Sorted_Map, start_key: string) -> (res: Cursor_Iterator, err: Error) {
	return cursor_iterator_sorted_from_key(m.cursor, transmute([]u8)start_key)
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
