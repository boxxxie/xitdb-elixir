# #20: `Lifecycle: compact/1 100-moment database deduplication`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `time_travel` — #17–#20 (Historical as_of, history_of, diff_moments & Compaction)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 38.70 µs (38703.0 ns) | 18.57 µs (18574.0 ns) | **`2.08x`** NIF Ratio |
| **Mean ± σ (CV)** | 35.98 µs ± 6.53 µs (18.2%) | 18.50 µs ± 326.2 ns (1.8%) | Welch `z` = `5.98` |
| **p95 / Max (`ns/op`)** | 42.47 µs / 43.07 µs | 18.82 µs / 18.86 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L402-L413`](../bench_elixir.exs#L402-L413))

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

### Raw Odin Harness ([`bench_client.odin#L1166-L1186`](../bench_client.odin#L1166-L1186))

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
<summary>Elixir <code>compact</code> — <a href="../../lib/xitdb.ex#L682-L699">lib/xitdb.ex#L682-L699</a></summary>

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

  @doc "Same as `compact/2`, but raises `Xitdb.Error` on failure."
  @spec compact!(t(), keyword()) :: t()
  def compact!(%__MODULE__{} = db, opts \\ []), do: db |> compact(opts) |> Error.unwrap!()
```

</details>

<details>
<summary>NIF <code>odin_nif_compact</code> — <a href="../../native/xitdb_nif.odin#L5464-L5529">native/xitdb_nif.odin#L5464-L5529</a></summary>

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
	comp_handle.db, comp_err = xitdb.database_compact(&handle.db, &comp_handle.core)
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
<summary><code>xitdb.database_compact</code> — <a href="../../native/xitdb-odin/xitdb/compact_replicate.odin#L720-L797">compact_replicate.odin#L720-L797</a></summary>

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
<summary><code>xitdb.core_length</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L407-L429">core.odin#L407-L429</a></summary>

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
<summary><code>xitdb.core_destroy</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L347-L376">core.odin#L347-L376</a></summary>

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
<summary><code>xitdb.core_sync</code> — <a href="../../native/xitdb-odin/xitdb/core.odin#L481-L500">core.odin#L481-L500</a></summary>

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

<details>
<summary><code>xitdb.memory_offset_map_init</code> — <a href="../../native/xitdb-odin/xitdb/compact_replicate.odin#L31-L33">compact_replicate.odin#L31-L33</a></summary>

```odin
memory_offset_map_init :: proc(allocator := context.allocator) -> Memory_Offset_Map {
	return Memory_Offset_Map{allocator = allocator}
}
```

</details>

<details>
<summary><code>xitdb.offset_map_destroy</code> — <a href="../../native/xitdb-odin/xitdb/compact_replicate.odin#L172-L177">compact_replicate.odin#L172-L177</a></summary>

```odin
offset_map_destroy :: proc(om: ^Offset_Map) {
	#partial switch &m in om {
	case Memory_Offset_Map:
		memory_offset_map_destroy(&m)
	}
}
```

</details>

<details>
<summary><code>xitdb.offset_map_reset</code> — <a href="../../native/xitdb-odin/xitdb/compact_replicate.odin#L89-L104">compact_replicate.odin#L89-L104</a></summary>

```odin
offset_map_reset :: proc(om: ^Offset_Map) -> Error {
	switch &m in om {
	case Memory_Offset_Map:
		if len(m.entries) > 0 && m.count > 0 {
			intrinsics.mem_zero(raw_data(m.entries), len(m.entries) * size_of(Memory_Offset_Entry))
		}
		m.count = 0
		return nil
	case File_Offset_Map:
		cursor := m.m.write_cursor
		cursor_write(&cursor, nil) or_return
		m.m = write_hash_map_init(cursor) or_return
		return nil
	}
	return nil
}
```

</details>

<details>
<summary><code>xitdb.database_init</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L182-L234">database.odin#L182-L234</a></summary>

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
	db.transaction = nil

	core_seek_to(core, 0) or_return
	length := core_length(core) or_return

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
		header_write(db.header, core) or_return
		rh_bytes := root_header_to_bytes(Root_Header{file_size = 0, root = Slot{}})
		core_write_all(core, rh_bytes[:]) or_return
		database_commit_root(&db, Slot{}, 0) or_return
		core_sync(core) or_return
	} else {
		db.header = database_read_and_validate_header(&db) or_return
		_ = database_committed_size(&db) or_return
	}

	db.tx_start = nil
	return db, nil
}
```

</details>

<details>
<summary><code>xitdb.database_read_root_slot</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L374-L377">database.odin#L374-L377</a></summary>

```odin
database_read_root_slot :: proc(db: ^Database) -> (res: Slot, err: Error) {
	header := database_read_root_header(db) or_return
	return header.root, nil
}
```

</details>

<details>
<summary><code>xitdb.slot_empty</code> — <a href="../../native/xitdb-odin/xitdb/types.odin#L856-L858">types.odin#L856-L858</a></summary>

```odin
slot_empty :: proc(s: Slot) -> bool {
	return s.tag == .None && !s.full
}
```

</details>
