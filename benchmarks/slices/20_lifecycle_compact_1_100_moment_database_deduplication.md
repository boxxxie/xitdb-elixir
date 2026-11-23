# #20: `Lifecycle: compact/1 100-moment database deduplication`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `time_travel` — #17–#20 (Historical as_of, history_of, diff_moments & Compaction)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 31.21 µs (31206.0 ns) | 12.66 µs (12658.0 ns) | **`2.47x`** NIF Ratio |
| **Mean ± σ (CV)** | 32.43 µs ± 2.49 µs (7.7%) | 12.73 µs ± 557.9 ns (4.4%) | Welch `z` = `17.26` |
| **p95 / Max (`ns/op`)** | 35.73 µs / 36.24 µs | 13.33 µs / 13.36 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L445-L456`](../bench_elixir.exs#L445-L456))

```elixir
      {20, "Lifecycle: compact/1 100-moment database deduplication", 20,
       fn ->
         max_sz =
           Enum.reduce(1..20, 0, fn _, acc_sz ->
             {:ok, comp_db} = Xitdb.compact(hist_db)
             sz = Xitdb.info!(comp_db).file_size
             Xitdb.close(comp_db)
             max(acc_sz, sz)
           end)

         max_sz
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1356-L1376`](../bench_client.odin#L1356-L1376))

```odin
	// #20: compact/1 100-moment database deduplication
	if r20 {
		compact_bytes: i64 = 0
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for _ in 0 ..< 20 {
				target_core := xitdb.core_memory_init()
				_, _ = xitdb.database_compact(&hist_db, &target_core)
				sz, _ := xitdb.core_length(&target_core)
				if sz > compact_bytes {
					compact_bytes = sz
				}
				xitdb.core_destroy(&target_core)
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 20.0
			}
			free_all(context.temp_allocator)
		}
		record_samples(20, "Lifecycle: compact/1 100-moment database deduplication", 20, samples, compact_bytes)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>compact</code> — <a href="../../lib/xitdb.ex#L1407-L1420">lib/xitdb.ex#L1407-L1420</a></summary>

```elixir
  def compact(%__MODULE__{db_ref: db_ref, hash: hash}, opts \\ []) do
    with {:ok, validated} <- validate_opts(opts, @compact_schema) do
      target_path = validated[:path]
      backend = if target_path == "", do: :memory, else: :buffered_file

      case NIF.nif_compact(db_ref, target_path) do
        {:ok, new_ref} ->
          {:ok, %__MODULE__{db_ref: new_ref, backend: backend, path: target_path, hash: hash}}

        {:error, reason} ->
          {:error, %Error{reason: reason}}
      end
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_compact</code> — <a href="../../native/xitdb_nif.odin#L10347-L10464">native/xitdb_nif.odin#L10347-L10464</a></summary>

```odin
odin_nif_compact :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 2 {
		return make_err(env, "badarg")
	}
	target_path, ok_p := get_string_from_binary(env, argv[1])
	if !ok_p {
		return make_err(env, "badarg")
	}

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	dead_ops, has_comp_roots, gc_err := gc_collect_dead_compression_ops(handle, context.temp_allocator)
	if gc_err != nil {
		return make_xitdb_err(env, gc_err)
	}

	raw_res := nif_alloc_db_resource(c.size_t(size_of(Db_Handle)))
	if raw_res == nil {
		return make_err(env, "alloc_failed")
	}
	comp_handle := (^Db_Handle)(raw_res)
	comp_handle^ = {}

	open_err: xitdb.Error = nil
	if len(target_path) == 0 {
		comp_handle.core = xitdb.core_memory_init(context.allocator)
		comp_handle.backend = 0
	} else {
		comp_handle.core, open_err = xitdb.core_buffered_file_open(
			target_path,
			xitdb.DEFAULT_BUFFER_SIZE,
			os.File_Flags{.Read, .Write, .Create, .Trunc},
			true,
			context.allocator,
		)
		comp_handle.backend = 2
	}

	if open_err != nil {
		comp_handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_xitdb_err(env, open_err)
	}

	comp_err: xitdb.Error = nil
	if !has_comp_roots || len(dead_ops) == 0 {
		comp_handle.db, comp_err = xitdb.database_compact(&handle.db, &comp_handle.core)
	} else {
		base_sz, sz_err := xitdb.database_committed_size(&handle.db)
		if sz_err != nil {
			_ = xitdb.core_destroy(&comp_handle.core, close_file = true)
			comp_handle.is_closed = true
			_ = nif_make_db_resource(env, raw_res)
			return make_xitdb_err(env, sz_err)
		}

		stage_core, ov_err := xitdb.core_overlay_init(handle.db.core, base_sz, context.allocator)
		if ov_err != nil {
			_ = xitdb.core_destroy(&comp_handle.core, close_file = true)
			comp_handle.is_closed = true
			_ = nif_make_db_resource(env, raw_res)
			return make_xitdb_err(env, ov_err)
		}
		defer _ = xitdb.core_destroy(&stage_core, close_file = false)

		h := handle.db.hasher
		h.id = handle.db.header.hash_id
		h.hash_size = handle.db.header.hash_size
		h.file_id = 0
		stage_db, db_err := xitdb.database_init(&stage_core, h)
		if db_err != nil {
			_ = xitdb.core_destroy(&comp_handle.core, close_file = true)
			comp_handle.is_closed = true
			_ = nif_make_db_resource(env, raw_res)
			return make_xitdb_err(env, db_err)
		}

		tx := xitdb.tx_init(&stage_db, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		defer xitdb.tx_destroy(&tx)
		for op in dead_ops {
			append(&tx.ops, op)
		}
		_, tx_err := xitdb.tx_commit(&tx)
		if tx_err != nil {
			_ = xitdb.core_destroy(&comp_handle.core, close_file = true)
			comp_handle.is_closed = true
			_ = nif_make_db_resource(env, raw_res)
			return make_xitdb_err(env, tx_err)
		}

		comp_handle.db, comp_err = xitdb.database_compact(&stage_db, &comp_handle.core)
	}

	if comp_err != nil {
		_ = xitdb.core_destroy(&comp_handle.core, close_file = true)
		comp_handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_xitdb_err(env, comp_err)
	}

	_ = xitdb.core_sync(&comp_handle.core)
	comp_handle.rwlock = nif_rwlock_create("xitdb_rwlock")
	if comp_handle.rwlock == nil {
		_ = xitdb.core_destroy(&comp_handle.core, close_file = true)
		comp_handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_err(env, "alloc_failed")
	}
	res_term := nif_make_db_resource(env, raw_res)
	return make_ok(env, res_term)
}
```

</details>

<details>
<summary>NIF <code>gc_collect_dead_compression_ops</code> — <a href="../../native/xitdb_nif.odin#L10048-L10344">native/xitdb_nif.odin#L10048-L10344</a></summary>

```odin
gc_collect_dead_compression_ops :: proc(
	handle: ^Db_Handle,
	allocator: runtime.Allocator,
) -> (dead_ops: [dynamic]xitdb.Tx_Op, has_compression_roots: bool, err: xitdb.Error) {
	dead_ops = make([dynamic]xitdb.Tx_Op, 0, 8, allocator)

	db_root := xitdb.database_read_root_slot(&handle.db) or_return
	if db_root.tag != .Array_List {
		return dead_ops, false, nil
	}

	root_slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, -1, -1)
	if r_err != nil || err_reason != "" || is_empty {
		return dead_ops, false, r_err
	}
	if root_slot.tag != .Hash_Map {
		return dead_ops, false, nil
	}
	root_kind := map_key_step_kind(root_slot.tag)

	root_cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = root_slot},
		db       = &handle.db,
	}

	blobs_slot: Maybe(xitdb.Slot) = nil
	dicts_slot: Maybe(xitdb.Slot) = nil
	pages_slot: Maybe(xitdb.Slot) = nil

	pool := nif_iter_pool_init(allocator)
	sb_buf: [128]u8 = ---
	root_it := nif_iter_pool_acquire(&pool) or_return
	xitdb.cursor_iterator_init(root_it, root_cur) or_return
	user_slots := make([dynamic]xitdb.Slot, 0, 16, allocator)

	for {
		next_maybe := xitdb.cursor_iterator_next(root_it) or_return
		elem_cur, ok := next_maybe.?
		if !ok {
			break
		}
		key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
		key_str := read_key_cursor_string(key_cur, sb_buf[:]) or_return
		switch key_str {
		case "__tx":
			continue
		case "__blobs":
			blobs_slot = val_cur.slot_ptr.slot
			has_compression_roots = true
		case "__dicts":
			dicts_slot = val_cur.slot_ptr.slot
			has_compression_roots = true
		case "__col_pages":
			pages_slot = val_cur.slot_ptr.slot
			has_compression_roots = true
		case:
			append(&user_slots, val_cur.slot_ptr.slot)
		}
	}
	nif_iter_pool_release(&pool, root_it)

	if !has_compression_roots {
		return dead_ops, false, nil
	}

	state := GC_Ref_State{
		visited    = make(map[u64]bool, 64, allocator),
		live_blobs = make(map[string]bool, 32, allocator),
		live_dicts = make(map[string]bool, 8, allocator),
		live_pages = make(map[string]bool, 32, allocator),
	}

	for s in user_slots {
		gc_collect_slot(&handle.db, s, &state, &pool, allocator) or_return
	}

	// Inspect __blobs for dead entries and transitive live_dicts from live "zd" blobs
	if bs, has_blobs := blobs_slot.?; has_blobs && is_container_tag(bs.tag) {
		blobs_kind := map_key_step_kind(bs.tag)
		b_cur := xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = bs},
			db       = &handle.db,
		}
		b_it := nif_iter_pool_acquire(&pool) or_return
		defer nif_iter_pool_release(&pool, b_it)
		xitdb.cursor_iterator_init(b_it, b_cur) or_return
		dead_blob_keys := make([dynamic]string, 0, 8, allocator)
		live_blob_count := 0
		for {
			next_maybe := xitdb.cursor_iterator_next(b_it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			sha_key := read_key_cursor_string(key_cur, sb_buf[:]) or_return
			if sha_key in state.live_blobs {
				live_blob_count += 1
				v_slot := val_cur.slot_ptr.slot
				if (v_slot.tag == .Bytes || v_slot.tag == .Short_Bytes) && v_slot.full {
					v_obj := xitdb.cursor_read_bytes_object(val_cur, 0, allocator) or_return
					gc_mark_tagged_bytes(&state, v_obj, allocator)
				}
			} else {
				append(&dead_blob_keys, strings.clone(sha_key, allocator))
			}
		}
		if live_blob_count == 0 {
			append(&dead_ops, xitdb.Tx_Op{
				kind  = .Remove,
				steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__blobs"}),
			})
		} else {
			for k in dead_blob_keys {
				append(&dead_ops, xitdb.Tx_Op{
					kind  = .Remove,
					steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__blobs"}, GC_Rm_Segment{blobs_kind, k}),
				})
			}
		}
	}

	// Inspect __col_pages for dead pages and transitive live_dicts from "XCP1" headers
	if ps, has_pages := pages_slot.?; has_pages && is_container_tag(ps.tag) {
		pages_kind := map_key_step_kind(ps.tag)
		p_cur := xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = ps},
			db       = &handle.db,
		}
		col_it := nif_iter_pool_acquire(&pool) or_return
		defer nif_iter_pool_release(&pool, col_it)
		xitdb.cursor_iterator_init(col_it, p_cur) or_return
		dead_col_ops := make([dynamic]xitdb.Tx_Op, 0, 8, allocator)
		live_total_pages := 0

		for {
			col_next := xitdb.cursor_iterator_next(col_it) or_return
			col_elem, ok_c := col_next.?
			if !ok_c {
				break
			}
			col_key_cur, col_val_cur := xitdb.cursor_read_kv_pair_slots(col_elem) or_return
			col_name_raw := read_key_cursor_string(col_key_cur, sb_buf[:]) or_return
			col_name := strings.clone(col_name_raw, allocator)
			col_val_slot := col_val_cur.slot_ptr.slot
			if !is_container_tag(col_val_slot.tag) {
				append(&dead_col_ops, xitdb.Tx_Op{
					kind  = .Remove,
					steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__col_pages"}, GC_Rm_Segment{pages_kind, col_name}),
				})
				continue
			}

			col_kind := map_key_step_kind(col_val_slot.tag)
			field_it := nif_iter_pool_acquire(&pool) or_return
			defer nif_iter_pool_release(&pool, field_it)
			xitdb.cursor_iterator_init(field_it, col_val_cur) or_return
			dead_field_ops := make([dynamic]xitdb.Tx_Op, 0, 8, allocator)
			live_in_col := 0

			for {
				field_next := xitdb.cursor_iterator_next(field_it) or_return
				field_elem, ok_f := field_next.?
				if !ok_f {
					break
				}
				field_key_cur, field_val_cur := xitdb.cursor_read_kv_pair_slots(field_elem) or_return
				field_name_raw := read_key_cursor_string(field_key_cur, sb_buf[:]) or_return
				field_name := strings.clone(field_name_raw, allocator)
				field_val_slot := field_val_cur.slot_ptr.slot
				if !is_container_tag(field_val_slot.tag) {
					append(&dead_field_ops, xitdb.Tx_Op{
						kind  = .Remove,
						steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__col_pages"}, GC_Rm_Segment{pages_kind, col_name}, GC_Rm_Segment{col_kind, field_name}),
					})
					continue
				}

				field_kind := map_key_step_kind(field_val_slot.tag)
				page_it := nif_iter_pool_acquire(&pool) or_return
				defer nif_iter_pool_release(&pool, page_it)
				xitdb.cursor_iterator_init(page_it, field_val_cur) or_return
				dead_page_ids := make([dynamic]string, 0, 8, allocator)
				live_in_field := 0

				for {
					page_next := xitdb.cursor_iterator_next(page_it) or_return
					page_elem, ok_p := page_next.?
					if !ok_p {
						break
					}
					page_key_cur, page_val_cur := xitdb.cursor_read_kv_pair_slots(page_elem) or_return
					page_id_raw := read_key_cursor_string(page_key_cur, sb_buf[:]) or_return
					page_id := strings.clone(page_id_raw, allocator)
					lookup_key := fmt.tprintf("%s\x00%s\x00%s", col_name, field_name, page_id)
					if lookup_key in state.live_pages {
						live_in_field += 1
						pv_slot := page_val_cur.slot_ptr.slot
						if pv_slot.tag == .Bytes || pv_slot.tag == .Short_Bytes {
							p_obj := xitdb.cursor_read_bytes_object(page_val_cur, 0, allocator) or_return
							pv := p_obj.value
							if len(pv) >= 16 && pv[0] == 'X' && pv[1] == 'C' && pv[2] == 'P' && pv[3] == '1' {
								dlen := int(pv[15])
								if dlen > 0 && len(pv) >= 16 + dlen {
									state.live_dicts[strings.clone(string(pv[16:16 + dlen]), allocator)] = true
								}
							}
						}
					} else {
						append(&dead_page_ids, page_id)
					}
				}

				if live_in_field == 0 {
					append(&dead_field_ops, xitdb.Tx_Op{
						kind  = .Remove,
						steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__col_pages"}, GC_Rm_Segment{pages_kind, col_name}, GC_Rm_Segment{col_kind, field_name}),
					})
				} else {
					live_in_col += live_in_field
					for pid in dead_page_ids {
						append(&dead_field_ops, xitdb.Tx_Op{
							kind  = .Remove,
							steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__col_pages"}, GC_Rm_Segment{pages_kind, col_name}, GC_Rm_Segment{col_kind, field_name}, GC_Rm_Segment{field_kind, pid}),
						})
					}
				}
			}

			if live_in_col == 0 {
				append(&dead_col_ops, xitdb.Tx_Op{
					kind  = .Remove,
					steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__col_pages"}, GC_Rm_Segment{pages_kind, col_name}),
				})
			} else {
				live_total_pages += live_in_col
				for op in dead_field_ops {
					append(&dead_col_ops, op)
				}
			}
		}

		if live_total_pages == 0 {
			append(&dead_ops, xitdb.Tx_Op{
				kind  = .Remove,
				steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__col_pages"}),
			})
		} else {
			for op in dead_col_ops {
				append(&dead_ops, op)
			}
		}
	}

	// Inspect __dicts after transitive marks from __blobs and __col_pages
	if ds, has_dicts := dicts_slot.?; has_dicts && is_container_tag(ds.tag) {
		dicts_kind := map_key_step_kind(ds.tag)
		d_cur := xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = ds},
			db       = &handle.db,
		}
		d_it := nif_iter_pool_acquire(&pool) or_return
		defer nif_iter_pool_release(&pool, d_it)
		xitdb.cursor_iterator_init(d_it, d_cur) or_return
		dead_dict_keys := make([dynamic]string, 0, 8, allocator)
		live_dict_count := 0
		for {
			next_maybe := xitdb.cursor_iterator_next(d_it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			dname := read_key_cursor_string(key_cur, sb_buf[:]) or_return
			if dname in state.live_dicts {
				live_dict_count += 1
			} else {
				append(&dead_dict_keys, strings.clone(dname, allocator))
			}
		}
		if live_dict_count == 0 {
			append(&dead_ops, xitdb.Tx_Op{
				kind  = .Remove,
				steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__dicts"}),
			})
		} else {
			for k in dead_dict_keys {
				append(&dead_ops, xitdb.Tx_Op{
					kind  = .Remove,
					steps = gc_make_rm_steps(allocator, GC_Rm_Segment{root_kind, "__dicts"}, GC_Rm_Segment{dicts_kind, k}),
				})
			}
		}
	}

	return dead_ops, true, nil
}
```

</details>

<details>
<summary>NIF <code>nif_iter_pool_init</code> — <a href="../../native/xitdb_nif.odin#L696-L701">native/xitdb_nif.odin#L696-L701</a></summary>

```odin
nif_iter_pool_init :: proc(alloc := context.temp_allocator) -> Nif_Iter_Pool {
	return Nif_Iter_Pool{
		free_list = make([dynamic]^xitdb.Cursor_Iterator, alloc),
		alloc     = alloc,
	}
}
```

</details>

<details>
<summary>NIF <code>nif_iter_pool_acquire</code> — <a href="../../native/xitdb_nif.odin#L713-L721">native/xitdb_nif.odin#L713-L721</a></summary>

```odin
nif_iter_pool_acquire :: proc(pool: ^Nif_Iter_Pool) -> (it: ^xitdb.Cursor_Iterator, err: xitdb.Error) {
	if pool == nil || pool.alloc.procedure == nil {
		return nif_alloc_cursor_iterator(context.temp_allocator)
	}
	if len(pool.free_list) > 0 {
		return pop(&pool.free_list), nil
	}
	return nif_alloc_cursor_iterator(pool.alloc)
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
<summary>NIF <code>nif_iter_pool_release</code> — <a href="../../native/xitdb_nif.odin#L723-L730">native/xitdb_nif.odin#L723-L730</a></summary>

```odin
nif_iter_pool_release :: proc(pool: ^Nif_Iter_Pool, it: ^xitdb.Cursor_Iterator) {
	if pool == nil || pool.alloc.procedure == nil || it == nil {
		return
	}
	if _, alloc_err := append(&pool.free_list, it); alloc_err != nil {
		free(it, pool.alloc)
	}
}
```

</details>

<details>
<summary>NIF <code>gc_collect_slot</code> — <a href="../../native/xitdb_nif.odin#L9947-L10030">native/xitdb_nif.odin#L9947-L10030</a></summary>

```odin
gc_collect_slot :: proc(
	db: ^xitdb.Database,
	slot: xitdb.Slot,
	state: ^GC_Ref_State,
	pool: ^Nif_Iter_Pool,
	allocator: runtime.Allocator,
) -> xitdb.Error {
	if slot.tag == .Bytes || slot.tag == .Short_Bytes {
		if !slot.full {
			return nil
		}
		cur := xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
			db       = db,
		}
		if slot.tag == .Bytes {
			_ = validate_bytes_slot_bounds(db, slot) or_return
		}
		b_obj := xitdb.cursor_read_bytes_object(cur, 0, allocator) or_return
		gc_mark_tagged_bytes(state, b_obj, allocator)
		return nil
	}

	if !is_container_tag(slot.tag) {
		return nil
	}

	visit_key := (u64(u8(slot.tag)) << 56) | u64(slot.value)
	if visit_key in state.visited {
		return nil
	}
	state.visited[visit_key] = true

	cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = slot},
		db       = db,
	}

	#partial switch slot.tag {
	case .Array_List, .Linked_Array_List:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			elem_slot := xitdb.cursor_slot(elem_cur) or_return
			gc_collect_slot(db, elem_slot, state, pool, allocator) or_return
		}

	case .Hash_Set, .Counted_Hash_Set, .Sorted_Set:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			key_cur, _ := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			gc_collect_slot(db, key_cur.slot_ptr.slot, state, pool, allocator) or_return
		}

	case .Hash_Map, .Counted_Hash_Map, .Sorted_Map:
		it := nif_iter_pool_acquire(pool) or_return
		defer nif_iter_pool_release(pool, it)
		xitdb.cursor_iterator_init(it, cur) or_return
		for {
			next_maybe := xitdb.cursor_iterator_next(it) or_return
			elem_cur, ok := next_maybe.?
			if !ok {
				break
			}
			_, val_cur := xitdb.cursor_read_kv_pair_slots(elem_cur) or_return
			gc_collect_slot(db, val_cur.slot_ptr.slot, state, pool, allocator) or_return
		}
	}

	return nil
}
```

</details>

<details>
<summary>NIF <code>gc_mark_tagged_bytes</code> — <a href="../../native/xitdb_nif.odin#L9888-L9945">native/xitdb_nif.odin#L9888-L9945</a></summary>

```odin
gc_mark_tagged_bytes :: proc(state: ^GC_Ref_State, b_obj: xitdb.Bytes, allocator: runtime.Allocator) {
	if len(b_obj.format_tag) != 2 {
		return
	}
	t0 := b_obj.format_tag[0]
	t1 := b_obj.format_tag[1]
	val := b_obj.value

	if t0 == 'b' && t1 == 'p' {
		if len(val) == 33 && val[0] == 0x10 {
			sha_hex := gc_encode_sha256_hex(val[1:33], allocator)
			state.live_blobs[sha_hex] = true
		}
		return
	}

	if t0 == 'z' && t1 == 'd' {
		if len(val) >= 7 && (val[0] == 0x10 || val[0] == 0x12) {
			dlen := int(val[5])
			if dlen > 0 && len(val) >= 6 + dlen {
				dname := strings.clone(string(val[6:6 + dlen]), allocator)
				state.live_dicts[dname] = true
			}
		}
		return
	}

	if t0 == 'p' && t1 == 'g' {
		if len(val) >= 13 && val[0] == 0x10 {
			off := 1
			col_len := int(u16(val[off]) | (u16(val[off + 1]) << 8))
			off += 2
			if col_len <= 0 || off + col_len + 2 > len(val) {
				return
			}
			col := string(val[off:off + col_len])
			off += col_len

			field_len := int(u16(val[off]) | (u16(val[off + 1]) << 8))
			off += 2
			if field_len <= 0 || off + field_len + 1 > len(val) {
				return
			}
			field := string(val[off:off + field_len])
			off += field_len

			page_id_len := int(val[off])
			off += 1
			if page_id_len <= 0 || off + page_id_len + 4 != len(val) {
				return
			}
			page_id := string(val[off:off + page_id_len])

			state.live_pages[fmt.tprintf("%s\x00%s\x00%s", col, field, page_id)] = true
		}
		return
	}
}
```

</details>

## Reachable `xitdb` Core Procedures

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
<summary><code>xitdb.database_compact</code> — <a href="../../native/xitdb-odin/xitdb/compact_replicate.odin#L741-L818">compact_replicate.odin#L741-L818</a></summary>

```odin
database_compact :: proc(db: ^Database, target_core: ^Core, offset_map: ^Offset_Map = nil) -> (target: Database, err: Error) {
	local_map: Offset_Map
	om := offset_map
	if om == nil {
		local_map = memory_offset_map_init()
		om = &local_map
	}
	defer if offset_map == nil {
		offset_map_destroy(&local_map)
	}

	offset_map_reset(om) or_return

	h := db.hasher
	h.id = db.header.hash_id
	h.hash_size = db.header.hash_size
	h.file_id = 0
	target = database_init(target_core, h) or_return

	target_root := database_read_root_slot(&target) or_return
	if !slot_empty(target_root) {
		return {}, .Target_Not_Empty
	}

	source_root := database_read_root_slot(db) or_return
	if slot_empty(source_root) {
		return target, nil
	}

	#partial switch &dst in target_core {
	case Core_Memory:
		want_cap := 4096
		if source_root.tag != .Array_List {
			if src_len, lerr := core_length(db.core); lerr == nil && src_len > 4096 {
				want_cap = min(int(src_len), 65536)
			}
		}
		if max_sz, ok := dst.max_size.?; ok && i64(want_cap) > max_sz {
			want_cap = int(max(max_sz, 0))
		}
		if cap(dst.buf) < want_cap {
			_ = _memory_reserve(&dst, want_cap)
		}
	}

	compactor := _Compactor{
		source_core = db.core,
		target_core = target.core,
		hash_size   = db.header.hash_size,
		offset_map  = om,
	}

	#partial switch source_root.tag {
	case .Array_List:
		rc := database_root_cursor(db)
		last_moment_maybe := cursor_read_path_slot(rc.read_cursor, []Path_Part{Array_List_Get{index = -1}}) or_return
		if last_moment, ok := last_moment_maybe.?; ok && !slot_empty(last_moment) {
			ctx := _Remap_Ctx{compactor = &compactor, slot = last_moment}
			trc := database_root_cursor(&target)
			_, err = cursor_write_path(&trc, []Path_Part{
				Array_List_Init{},
				Array_List_Append{},
				Context{function = _remap_slot_cb, user_data = &ctx},
			})
			if err != nil {
				return {}, err
			}
		}
	case:
		ctx := _Remap_Ctx{compactor = &compactor, slot = source_root}
		err = database_run_context(&target, _remap_slot_cb, &ctx)
		if err != nil {
			return {}, err
		}
	}

	return target, nil
}
```

</details>

<details>
<summary><code>xitdb.core_length</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L411-L433">core.odin#L411-L433</a></summary>

```odin
core_length :: proc(c: ^Core) -> (length: i64, err: Error) {
	switch &v in c {
	case Core_Memory:
		return i64(len(v.buf)), nil
	case Core_File:
		return os.file_size(v.file)
	case Core_Buffered_File:
		flen: i64
		if fl, ok := v.file_len.?; ok {
			flen = fl
		} else {
			flen = os.file_size(v.file.file) or_return
		}
		buf_size := i64(len(v.memory.buf))
		if buf_size == 0 {
			return flen, nil
		}
		return max(v.memory_pos + buf_size, flen), nil
	case Core_Overlay:
		return _overlay_length(&v), nil
	}
	return 0, .Invalid_Database
}
```

</details>

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
<summary><code>xitdb.core_buffered_file_open</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L162-L165">core.odin#L162-L165</a></summary>

```odin
core_buffered_file_open :: proc(path: string, buffer_size: i64 = DEFAULT_BUFFER_SIZE, flags := os.File_Flags{.Read, .Write, .Create}, fsync := true, allocator := context.allocator) -> (c: Core, err: Error) {
	f := os.open(path, flags, os.Permissions_Default_File) or_return
	return core_buffered_file_init(f, buffer_size, fsync, allocator), nil
}
```

</details>

<details>
<summary><code>xitdb.database_committed_size</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L375-L378">database.odin#L375-L378</a></summary>

```odin
database_committed_size :: proc(db: ^Database) -> (res: i64, err: Error) {
	header := database_read_root_header(db) or_return
	return header.file_size, nil
}
```

</details>

<details>
<summary><code>xitdb.core_overlay_init</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L168-L192">core.odin#L168-L192</a></summary>

```odin
core_overlay_init :: proc(base: ^Core, base_size: i64, allocator := context.allocator) -> (c: Core, err: Error) {
	if base == nil || base_size < 0 {
		return nil, Xitdb_Error.Invalid_Offset
	}
	base_len := core_length(base) or_return
	if base_size > base_len {
		return nil, Xitdb_Error.Invalid_Offset
	}
	tail := core_memory_init(allocator)
	o := Core_Overlay{
		base      = base,
		base_size = base_size,
		pages     = make(map[i64][]u8, 4, allocator),
		tail      = tail.(Core_Memory),
		allocator = allocator,
	}
	// Snapshot the header page: the parent rewrites its root header in place on every commit.
	if base_size > 0 {
		if _, p_err := _overlay_page(&o, 0); p_err != nil {
			_overlay_destroy(&o)
			return nil, p_err
		}
	}
	return o, nil
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
<summary><code>xitdb.tx_init</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L905-L916">dsl.odin#L905-L916</a></summary>

```odin
tx_init :: proc(db: ^Database, base_moment: Maybe(i64) = -1, track_changes := false, allocator := context.temp_allocator) -> Tx {
	return Tx{
		db            = db,
		base_moment   = base_moment,
		track_changes = track_changes,
		meta          = make([dynamic]Tx_Meta_Entry, 0, 4, allocator),
		ops           = make([dynamic]Tx_Op, 0, 8, allocator),
		index_rules   = make([dynamic]Secondary_Index_Rule, 0, 2, allocator),
		owned_strs    = make([dynamic]string, 0, 0, allocator),
		allocator     = allocator,
	}
}
```

</details>

<details>
<summary><code>xitdb.tx_destroy</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L919-L935">dsl.odin#L919-L935</a></summary>

```odin
tx_destroy :: proc(tx: ^Tx) {
	for op in tx.ops {
		if op.steps != nil {
			delete(op.steps, tx.allocator)
		}
		if op.from_steps != nil {
			delete(op.from_steps, tx.allocator)
		}
	}
	for s in tx.owned_strs {
		delete(s, tx.allocator)
	}
	delete(tx.owned_strs)
	delete(tx.meta)
	delete(tx.ops)
	delete(tx.index_rules)
}
```

</details>

<details>
<summary><code>xitdb.tx_commit</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L1334-L1396">dsl.odin#L1334-L1396</a></summary>

```odin
tx_commit :: proc(tx: ^Tx) -> (report: Tx_Report, err: Error) {
	rc := database_root_cursor(tx.db)
	history := write_array_list_init(rc) or_return
	hist_count := array_list_count(history.read_array_list) or_return

	ectx := _Tx_Exec_Ctx{
		tx       = tx,
		recorded = make([dynamic]Tx_Change, 0, len(tx.ops) if tx.track_changes else 0, tx.allocator),
	}
	defer if err != nil {
		for chg in ectx.recorded {
			if len(chg.path_str) > 0 {
				delete(chg.path_str, tx.allocator)
			}
		}
		delete(ectx.recorded)
	}

	if bm, has_bm := tx.base_moment.?; has_bm && hist_count > 0 {
		resolved_idx := bm if bm >= 0 else hist_count + bm
		if resolved_idx < 0 || resolved_idx >= hist_count {
			return {}, .Key_Not_Found
		}
		slot_maybe := array_list_get_slot(history.read_array_list, resolved_idx) or_return
		if s, ok := slot_maybe.?; ok {
			ectx.base_slot = s
			ectx.has_parent = true
			ectx.resolved_parent = resolved_idx
		}
	}

	array_list_append_context(&history, ectx.base_slot, _execute_tx_cb, &ectx) or_return

	new_moment_idx := hist_count
	after_cur_maybe := array_list_get_cursor(history.read_array_list, new_moment_idx) or_return
	after_map := read_hash_map_init(after_cur_maybe.?) or_return

	before_map: Maybe(Read_Hash_Map)
	if ectx.has_parent {
		before_cur_maybe := array_list_get_cursor(history.read_array_list, ectx.resolved_parent) or_return
		if bc, ok := before_cur_maybe.?; ok {
			bm := read_hash_map_init(bc) or_return
			before_map = bm
		}
	}

	tx_meta_map: Maybe(Read_Hash_Map)
	tx_cur_maybe := hash_map_get_cursor(after_map, "__tx") or_return
	if tc, ok := tx_cur_maybe.?; ok {
		tm := read_hash_map_init(tc) or_return
		tx_meta_map = tm
	}

	committed := database_committed_size(tx.db) or_return
	return Tx_Report{
		moment_index = new_moment_idx,
		commit_size  = committed,
		before       = before_map,
		after        = after_map,
		tx_meta      = tx_meta_map,
		changes      = ectx.recorded[:],
	}, nil
}
```

</details>

<details>
<summary><code>xitdb.core_sync</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L485-L504">core.odin#L485-L504</a></summary>

```odin
core_sync :: proc(c: ^Core) -> Error {
	switch &v in c {
	case Core_Memory:
		return nil
	case Core_File:
		if !v.fsync {
			return nil
		}
		return os.sync(v.file)
	case Core_Buffered_File:
		_buffered_flush(&v) or_return
		if !v.file.fsync {
			return nil
		}
		return os.sync(v.file.file)
	case Core_Overlay:
		return nil
	}
	return .Invalid_Database
}
```

</details>
