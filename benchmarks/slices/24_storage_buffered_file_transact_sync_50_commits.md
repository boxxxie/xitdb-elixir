# #24: `Storage: Buffered_File transact + sync (50 commits)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `queries` — #21–#27 (Pull Projections, Datalog Engine, Buffered Sync, Search & Indexer)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 80.20 µs (80200.0 ns) | 79.26 µs (79259.0 ns) | **`1.01x`** NIF Ratio |
| **Mean ± σ (CV)** | 82.23 µs ± 5.95 µs (7.2%) | 78.85 µs ± 1.64 µs (2.1%) | Welch `z` = `1.22` |
| **p95 / Max (`ns/op`)** | 90.38 µs / 92.67 µs | 80.59 µs / 80.75 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L470-L486`](../bench_elixir.exs#L470-L486))

```elixir
      {24, "Storage: Buffered_File transact + sync (50 commits)", 50,
       fn ->
         tmp_path = "/tmp/xitdb_bench_elixir_#{System.unique_integer([:positive])}.xit"
         {:ok, d} = Xitdb.open(backend: :buffered_file, path: tmp_path)
         t0 = System.monotonic_time(:nanosecond)

         for i <- 0..49 do
           {:ok, _} = Xitdb.transact(d, %{"events" => %{"e#{i}" => i}})
         end

         :ok = Xitdb.sync(d)
         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         File.rm(tmp_path)
         {elapsed, sz}
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1366-L1385`](../bench_client.odin#L1366-L1385))

```odin
	// #24: Storage: Buffered_File transact + sync (50 commits)
	run_bench(24, "Storage: Buffered_File transact + sync (50 commits)", 50, proc() -> (time.Duration, i64) {
		tmp_path := fmt.tprintf("/tmp/xitdb_bench_odin_%d.xit", time.to_unix_nanoseconds(time.now()))
		defer os.remove(tmp_path)
		c, _ := xitdb.core_buffered_file_open(tmp_path)
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		t0 := time.now()
		for i in 0 ..< 50 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			_ = xitdb.tx_put(&tx, fmt.tprintf(".events.e%d", i), u64(i))
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		_ = xitdb.core_sync(&c)
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		return dur, sz
	})
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>open</code> — <a href="../../lib/xitdb.ex#L183-L201">lib/xitdb.ex#L183-L201</a></summary>

```elixir
  def open(opts \\ []) do
    with {:ok, validated} <- validate_opts(opts, @open_schema) do
      backend = validated[:backend]
      path = validated[:path]
      hash = validated[:hash]

      if backend in [:file, :buffered_file] and path == "" do
        {:error, %Error{reason: :missing_path, details: %{backend: backend}}}
      else
        case NIF.nif_open(backend, path, hash) do
          {:ok, db_ref} ->
            {:ok, %__MODULE__{db_ref: db_ref, backend: backend, path: path, hash: hash}}

          {:error, reason} ->
            {:error, %Error{reason: reason}}
        end
      end
    end
  end
```

</details>

<details>
<summary>Elixir <code>transact</code> — <a href="../../lib/xitdb.ex#L329-L352">lib/xitdb.ex#L329-L352</a></summary>

```elixir
  def transact(db, map_or_fun, opts \\ [])

  def transact(%__MODULE__{db_ref: db_ref} = db, map, [])
      when is_map(map) and not is_struct(map) do
    ops = TxCompiler.compile_moment_map(map)
    do_transact_ops_default(db, db_ref, ops)
  end

  def transact(%__MODULE__{} = db, map, opts) when is_map(map) and not is_struct(map) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      ops = TxCompiler.compile_moment_map(map)
      do_transact_ops(db, ops, validated)
    end
  end

  def transact(%__MODULE__{db_ref: db_ref} = db, fun, []) when is_function(fun, 1) do
    run_transact_fun(db, db_ref, fun, -1, :default)
  end

  def transact(%__MODULE__{db_ref: db_ref} = db, fun, opts) when is_function(fun, 1) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      run_transact_fun(db, db_ref, fun, validated[:base_moment], validated)
    end
  end
```

</details>

<details>
<summary>Elixir <code>sync</code> — <a href="../../lib/xitdb.ex#L215-L217">lib/xitdb.ex#L215-L217</a></summary>

```elixir
  def sync(%__MODULE__{db_ref: db_ref}) do
    db_ref |> NIF.nif_sync() |> Error.wrap()
  end
```

</details>

<details>
<summary>Elixir <code>info!</code> — <a href="../../lib/xitdb.ex#L227-L227">lib/xitdb.ex#L227-L227</a></summary>

```elixir
  def info!(%__MODULE__{} = db), do: db |> info() |> Error.unwrap!()
```

</details>

<details>
<summary>Elixir <code>close</code> — <a href="../../lib/xitdb.ex#L209-L211">lib/xitdb.ex#L209-L211</a></summary>

```elixir
  def close(%__MODULE__{db_ref: db_ref}) do
    NIF.nif_close(db_ref)
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_open</code> — <a href="../../native/xitdb_nif.odin#L754-L829">native/xitdb_nif.odin#L754-L829</a></summary>

```odin
odin_nif_open :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 {
		return make_err(env, "badarg")
	}

	atom_buf: [64]u8 = ---
	backend_str, ok_b := get_atom_string(env, argv[0], atom_buf[:])
	if !ok_b {
		return make_err(env, "invalid_backend")
	}

	path_str, ok_p := get_string_from_binary(env, argv[1])
	if !ok_p {
		return make_err(env, "invalid_path")
	}

	hash_buf: [64]u8 = ---
	hash_str, ok_h := get_atom_string(env, argv[2], hash_buf[:])
	if !ok_h {
		return make_err(env, "invalid_hash")
	}

	hasher := xitdb.sha256_hasher() if hash_str == "sha256" else xitdb.sha1_hasher()

	raw_res := nif_alloc_db_resource(c.size_t(size_of(Db_Handle)))
	if raw_res == nil {
		return make_err(env, "alloc_failed")
	}
	handle := (^Db_Handle)(raw_res)
	handle^ = {}

	open_err: xitdb.Error = nil
	switch backend_str {
	case "memory":
		handle.core = xitdb.core_memory_init(context.allocator)
		handle.backend = 0
	case "file":
		handle.core, open_err = xitdb.core_file_open(path_str, os.File_Flags{.Read, .Write, .Create}, true)
		handle.backend = 1
	case "buffered_file":
		handle.core, open_err = xitdb.core_buffered_file_open(path_str, xitdb.DEFAULT_BUFFER_SIZE, os.File_Flags{.Read, .Write, .Create}, true, context.allocator)
		handle.backend = 2
	case:
		handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_err(env, "unknown_backend")
	}

	if open_err != nil {
		handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_xitdb_err(env, open_err)
	}

	init_err: xitdb.Error = nil
	handle.db, init_err = xitdb.database_init(&handle.core, hasher)
	if init_err != nil {
		_ = xitdb.core_destroy(&handle.core, close_file = true)
		handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_xitdb_err(env, init_err)
	}

	handle.rwlock = nif_rwlock_create("xitdb_rwlock")
	if handle.rwlock == nil {
		_ = xitdb.core_destroy(&handle.core, close_file = true)
		handle.is_closed = true
		_ = nif_make_db_resource(env, raw_res)
		return make_err(env, "alloc_failed")
	}
	res_term := nif_make_db_resource(env, raw_res)
	return make_ok(env, res_term)
}
```

</details>

<details>
<summary>NIF <code>odin_nif_transact</code> — <a href="../../native/xitdb_nif.odin#L5239-L5326">native/xitdb_nif.odin#L5239-L5326</a></summary>

```odin
odin_nif_transact :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 4 {
		return make_err(env, "badarg")
	}

	base_moment: i64 = -1
	if nif_get_int64(env, argv[1], &base_moment) == 0 {
		return make_err(env, "badarg")
	}
	doc_str := ""
	if argv[3] != ATOM_NIL {
		var_doc, ok_doc := get_string_from_binary(env, argv[3])
		if !ok_doc {
			return make_err(env, "badarg")
		}
		doc_str = var_doc
	}
	if nif_is_list(env, argv[2]) == 0 {
		return make_err(env, "invalid_ops_list")
	}

	handle, ok := acquire_wlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_rwunlock(handle.rwlock)

	tx := xitdb.tx_init(&handle.db, base_moment = base_moment, track_changes = false, allocator = context.temp_allocator)
	defer xitdb.tx_destroy(&tx)

	if len(doc_str) > 0 {
		xitdb.tx_doc(&tx, doc_str)
	}

	validation_err := ""
	has_deferred := false
	parse_reason, parse_xerr := parse_tx_ops(env, argv[2], &tx, &validation_err, &has_deferred)
	if parse_reason != "" || parse_xerr != nil {
		if has_deferred {
			if deferred_err := validate_deferred_tx_ops(&tx); deferred_err != "" {
				return make_err(env, deferred_err)
			}
		}
		if parse_reason != "" {
			return make_err(env, parse_reason)
		}
		return make_xitdb_err(env, parse_xerr)
	}

	pre_header, pre_hdr_err := xitdb.database_read_root_header(&handle.db)
	pre_len, pre_len_err := xitdb.core_length(handle.db.core)
	file_size_start := xitdb.database_file_size_start(handle.db.header.version)
	pre_fs_bytes: [8]u8 = ---
	pre_fs_err := xitdb.core_read_exact_at(handle.db.core, file_size_start, pre_fs_bytes[:])

	rep: xitdb.Tx_Report
	c_err: xitdb.Error
	for attempt := 0; attempt < 2; attempt += 1 {
		rep, c_err = xitdb.tx_commit(&tx)
		if c_err == nil {
			break
		}
		if rb_err := rollback_failed_tx(&handle.db, pre_header, pre_hdr_err, pre_len, pre_len_err, pre_fs_bytes, pre_fs_err); rb_err != nil {
			return make_xitdb_err(env, rb_err)
		}
		if attempt == 0 && c_err == .Unexpected_Tag && len(validation_err) == 0 && adapt_tx_ops_for_base_moment(handle, &tx) {
			continue
		}
		break
	}
	if c_err != nil {
		if len(validation_err) == 0 && has_deferred {
			if deferred_err := validate_deferred_tx_ops(&tx); deferred_err != "" {
				return make_err(env, deferred_err)
			}
		}
		if len(validation_err) > 0 {
			return make_err(env, validation_err)
		}
		return make_xitdb_err(env, c_err)
	}
	moment_idx := rep.moment_index
	xitdb.tx_report_destroy(&rep, context.temp_allocator)
	return make_ok(env, nif_make_int64(env, moment_idx))
}
```

</details>

<details>
<summary>NIF <code>odin_nif_sync</code> — <a href="../../native/xitdb_nif.odin#L855-L872">native/xitdb_nif.odin#L855-L872</a></summary>

```odin
odin_nif_sync :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 1 {
		return make_err(env, "badarg")
	}
	handle, ok := acquire_wlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_rwunlock(handle.rwlock)

	if err := xitdb.core_sync(&handle.core); err != nil {
		return make_xitdb_err(env, err)
	}
	return ATOM_OK
}
```

</details>

<details>
<summary>NIF <code>odin_nif_info</code> — <a href="../../native/xitdb_nif.odin#L875-L910">native/xitdb_nif.odin#L875-L910</a></summary>

```odin
odin_nif_info :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 1 {
		return make_err(env, "badarg")
	}
	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	rc := xitdb.database_root_cursor(&handle.db).read_cursor
	moment_count: i64 = 0
	if hist, err := xitdb.read_array_list_init(rc); err == nil {
		if cnt, c_err := xitdb.array_list_count(hist); c_err == nil {
			moment_count = cnt
		}
	}
	file_size, fs_err := xitdb.core_length(&handle.core)
	if fs_err != nil {
		return make_xitdb_err(env, fs_err)
	}

	keys := [2]ERL_NIF_TERM{
		ATOM_MOMENT_COUNT,
		ATOM_FILE_SIZE,
	}
	vals := [2]ERL_NIF_TERM{
		nif_make_int64(env, moment_count),
		nif_make_int64(env, file_size),
	}
	m := make_map_safe(env, keys[:], vals[:])
	return make_ok(env, m)
}
```

</details>

<details>
<summary>NIF <code>odin_nif_close</code> — <a href="../../native/xitdb_nif.odin#L832-L852">native/xitdb_nif.odin#L832-L852</a></summary>

```odin
odin_nif_close :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	ptr: rawptr = nil
	if argc != 1 || nif_get_db_resource(env, argv[0], &ptr) == 0 || ptr == nil {
		return ATOM_OK
	}
	handle := (^Db_Handle)(ptr)
	if handle.rwlock == nil {
		return ATOM_OK
	}
	nif_rwlock_rwlock(handle.rwlock)
	defer nif_rwlock_rwunlock(handle.rwlock)

	if !handle.is_closed {
		_ = xitdb.core_destroy(&handle.core, close_file = true)
		handle.is_closed = true
	}
	return ATOM_OK
}
```

</details>

<details>
<summary>NIF <code>parse_tx_ops</code> — <a href="../../native/xitdb_nif.odin#L4942-L5236">native/xitdb_nif.odin#L4942-L5236</a></summary>

```odin
parse_tx_ops :: proc(
	env: ErlNifEnv,
	ops_term: ERL_NIF_TERM,
	tx: ^xitdb.Tx,
	validation_err: ^string,
	has_deferred: ^bool,
) -> (err_reason: string, xerr: xitdb.Error) {
	head: ERL_NIF_TERM
	tail := ops_term
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return "invalid_ops_list", nil
		}
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, head, &arity, &elems) == 0 || arity < 1 {
			return "invalid_op_tuple", nil
		}

		op_atom := elems[0]

		switch op_atom {
		case ATOM_PUT:
			if arity != 3 {
				return "invalid_put_op", nil
			}
			steps, s_err, ok_p := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_p {
				return "invalid_put_op", nil
			}
			if s_err != "" {
				return s_err, nil
			}
			if val, ok_v := decode_writeable_value(env, elems[2]); ok_v {
				if len(steps) == 0 {
					return "", .Invalid_Range
				}
				append(&tx.ops, xitdb.Tx_Op{kind = .Put, steps = steps, val = val})
			} else if is_structured_write_candidate(env, elems[2]) {
				if len(steps) == 0 {
					if !validate_write_term_cold(env, elems[2]) {
						return "invalid_put_op", nil
					}
					return "", .Invalid_Range
				}
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{
					kind = .Put,
					steps = steps,
					env = env,
					term = elems[2],
					validation_err = validation_err,
					err_reason = "invalid_put_op",
				}
				xitdb.tx_with_cursor(tx, structured_op_callback, sc)
				has_deferred^ = true
			} else {
				return "invalid_put_op", nil
			}

		case ATOM_APPEND:
			if arity != 3 {
				return "invalid_append_op", nil
			}
			steps, s_err, ok_p := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_p {
				return "invalid_append_op", nil
			}
			if s_err != "" {
				return s_err, nil
			}
			if len(steps) == 0 {
				return "invalid_append_op", nil
			}
			if val, ok_v := decode_writeable_value(env, elems[2]); ok_v {
				append(&tx.ops, xitdb.Tx_Op{kind = .Append, steps = steps, val = val})
			} else if is_structured_write_candidate(env, elems[2]) {
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{
					kind = .Append,
					steps = steps,
					env = env,
					term = elems[2],
					validation_err = validation_err,
					err_reason = "invalid_append_op",
				}
				xitdb.tx_with_cursor(tx, structured_op_callback, sc)
				has_deferred^ = true
			} else {
				return "invalid_append_op", nil
			}

		case ATOM_INSERT:
			if arity != 4 {
				return "invalid_insert_op", nil
			}
			idx_val: i64 = 0
			ok_i := nif_get_int64(env, elems[2], &idx_val) != 0
			steps, s_err, ok_p := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_p || !ok_i {
				return "invalid_insert_op", nil
			}
			if s_err != "" {
				return s_err, nil
			}
			if len(steps) == 0 {
				return "invalid_insert_op", nil
			}
			if val, ok_v := decode_writeable_value(env, elems[3]); ok_v {
				ic := new(Insert_Op_Ctx, tx.allocator)
				ic^ = Insert_Op_Ctx{steps = steps, index = idx_val, val = val}
				xitdb.tx_with_cursor(tx, insert_op_callback, ic)
			} else if is_structured_write_candidate(env, elems[3]) {
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{
					kind = .Insert,
					steps = steps,
					index = idx_val,
					env = env,
					term = elems[3],
					validation_err = validation_err,
					err_reason = "invalid_insert_op",
				}
				xitdb.tx_with_cursor(tx, structured_op_callback, sc)
				has_deferred^ = true
			} else {
				return "invalid_insert_op", nil
			}

		case ATOM_RM:
			if arity != 2 {
				return "invalid_rm_op", nil
			}
			steps, s_err, ok_p := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_p {
				return "invalid_rm_op", nil
			}
			if s_err != "" {
				return s_err, nil
			}
			append(&tx.ops, xitdb.Tx_Op{kind = .Remove, steps = steps})

		case ATOM_RM_IF_EXISTS:
			if arity != 2 {
				return "invalid_rm_op", nil
			}
			steps, s_err, ok_p := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_p {
				return "invalid_rm_op", nil
			}
			if s_err != "" {
				return s_err, nil
			}
			rc := new(Rm_If_Exists_Ctx, tx.allocator)
			rc^ = Rm_If_Exists_Ctx{steps = steps, tx = tx}
			xitdb.tx_with_cursor(tx, rm_if_exists_callback, rc)

		case ATOM_SLICE:
			if arity != 4 {
				return "invalid_slice_op", nil
			}
			offset_val: i64 = 0
			size_val: i64 = 0
			ok_o := nif_get_int64(env, elems[2], &offset_val) != 0
			ok_s := nif_get_int64(env, elems[3], &size_val) != 0
			steps, s_err, ok_p := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_p || !ok_o || !ok_s {
				return "invalid_slice_op", nil
			}
			if offset_val < 0 || size_val < 0 {
				return "", .Invalid_Range
			}
			if s_err != "" {
				return s_err, nil
			}
			if len(steps) == 0 {
				return "", .Invalid_Range
			}
			sc := new(Slice_Op_Ctx, tx.allocator)
			sc^ = Slice_Op_Ctx{steps = steps, offset = offset_val, size = size_val}
			xitdb.tx_with_cursor(tx, slice_op_callback, sc)

		case ATOM_FORK:
			if arity != 3 {
				return "invalid_fork_op", nil
			}
			from_steps, f_err, ok_f := decode_steps_term(env, elems[1], tx.allocator)
			to_steps, t_err, ok_t := decode_steps_term(env, elems[2], tx.allocator)
			if !ok_f || !ok_t {
				return "invalid_fork_op", nil
			}
			if f_err != "" {
				return f_err, nil
			}
			if t_err != "" {
				return t_err, nil
			}
			if len(from_steps) == 0 || len(to_steps) == 0 {
				return "", .Invalid_Range
			}
			append(&tx.ops, xitdb.Tx_Op{kind = .Fork, from_steps = from_steps, steps = to_steps})
			if nif_is_empty_list(env, tail) == 0 {
				xitdb.tx_savepoint(tx)
			}

		case ATOM_INDEX_ON:
			if arity != 4 {
				return "invalid_index_on_op", nil
			}
			src_map, ok_1 := get_string_from_binary(env, elems[1])
			field_key, ok_2 := get_string_from_binary(env, elems[2])
			idx_map, ok_3 := get_string_from_binary(env, elems[3])
			if !ok_1 || !ok_2 || !ok_3 {
				return "invalid_index_on_op", nil
			}
			xitdb.tx_index_on(tx, src_map, field_key, idx_map)

		case ATOM_INSTANT:
			if arity != 2 {
				return "invalid_instant_op", nil
			}
			inst_val: i64 = 0
			if nif_get_int64(env, elems[1], &inst_val) == 0 {
				return "invalid_instant_op", nil
			}
			xitdb.tx_instant(tx, inst_val)

		case ATOM_META:
			if arity != 3 {
				return "invalid_meta_op", nil
			}
			key_str, ok_k := get_string_from_binary(env, elems[1])
			if !ok_k {
				return "invalid_meta_op", nil
			}
			if key_str == "tx_instant" {
				inst_val: i64 = 0
				if nif_get_int64(env, elems[2], &inst_val) == 0 {
					return "invalid_meta_op", nil
				}
				xitdb.tx_instant(tx, inst_val)
			} else {
				val, ok_v := decode_writeable_value(env, elems[2])
				if !ok_v {
					return "invalid_meta_op", nil
				}
				xitdb.tx_meta(tx, key_str, val)
			}

		case ATOM_SAVEPOINT:
			if arity != 1 {
				return "invalid_savepoint_op", nil
			}
			xitdb.tx_savepoint(tx)

		case ATOM_INIT_COL, ATOM_RESET_COL:
			if arity != 3 {
				return "invalid_init_col_op", nil
			}
			kind_str, ok_k := get_string_from_binary(env, elems[2])
			steps, s_err, ok_p := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_p || !ok_k || !is_supported_col_kind(kind_str) {
				return "invalid_init_col_op", nil
			}
			if s_err != "" {
				return s_err, nil
			}
			ic := new(Init_Col_Ctx, tx.allocator)
			ic.steps = steps
			ic.kind = kind_str
			ic.reset = (op_atom == ATOM_RESET_COL)
			xitdb.tx_with_cursor(tx, init_col_callback, ic)

		case ATOM_MERGE_MAP:
			if arity != 2 {
				return "invalid_merge_map_op", nil
			}
			st: ERL_NIF_TERM = 0
			if nif_is_map(env, elems[1]) == 0 || nif_get_map_value(env, elems[1], ATOM_STRUCT, &st) != 0 {
				return "invalid_put_op", nil
			}
			mc := new(Merge_Map_Ctx, tx.allocator)
			mc.env = env
			mc.map_term = elems[1]
			mc.tx = tx
			mc.validation_err = validation_err
			xitdb.tx_with_cursor(tx, merge_map_callback, mc)
			has_deferred^ = true

		case:
			return "unknown_tx_op", nil
		}
	}
	return "", nil
}
```

</details>

<details>
<summary>NIF <code>validate_deferred_tx_ops</code> — <a href="../../native/xitdb_nif.odin#L4922-L4940">native/xitdb_nif.odin#L4922-L4940</a></summary>

```odin
validate_deferred_tx_ops :: proc(tx: ^xitdb.Tx) -> string {
	for &op in tx.ops {
		if op.kind != .Callback || op.user_data == nil {
			continue
		}
		if op.callback == structured_op_callback {
			sc := (^Structured_Op_Ctx)(op.user_data)
			if !validate_write_term_cold(sc.env, sc.term) {
				return sc.err_reason
			}
		} else if op.callback == merge_map_callback {
			mc := (^Merge_Map_Ctx)(op.user_data)
			if !validate_write_term_cold(mc.env, mc.map_term) {
				return "invalid_put_op"
			}
		}
	}
	return ""
}
```

</details>

<details>
<summary>NIF <code>rollback_failed_tx</code> — <a href="../../native/xitdb_nif.odin#L4725-L4763">native/xitdb_nif.odin#L4725-L4763</a></summary>

```odin
rollback_failed_tx :: proc(
	db: ^xitdb.Database,
	pre_header: xitdb.Root_Header,
	pre_hdr_err: xitdb.Error,
	pre_len: i64,
	pre_len_err: xitdb.Error,
	pre_fs_bytes: [8]u8,
	pre_fs_err: xitdb.Error,
) -> xitdb.Error {
	has_target_len := pre_hdr_err == nil || pre_len_err == nil
	target_len := pre_header.file_size if pre_hdr_err == nil else pre_len
	len_changed := false
	if has_target_len {
		cur_len, cur_len_err := xitdb.core_length(db.core)
		if cur_len_err != nil || cur_len != target_len {
			len_changed = true
			xitdb.core_set_length(db.core, target_len) or_return
			after_len := xitdb.core_length(db.core) or_return
			if after_len != target_len {
				return .Truncated_Database
			}
		}
	}

	file_size_start := xitdb.database_file_size_start(db.header.version)
	cur_fs_bytes: [8]u8 = ---
	cur_fs_err := xitdb.core_read_exact_at(db.core, file_size_start, cur_fs_bytes[:])
	hdr_changed := pre_fs_err == nil && (cur_fs_err != nil || cur_fs_bytes != pre_fs_bytes)
	if hdr_changed {
		fs_bytes := pre_fs_bytes
		xitdb.core_seek_to(db.core, file_size_start) or_return
		xitdb.core_write_all(db.core, fs_bytes[:]) or_return
		xitdb.core_flush(db.core) or_return
		xitdb.core_sync(db.core) or_return
	} else if len_changed {
		xitdb.core_flush(db.core) or_return
	}
	return nil
}
```

</details>

## Reachable `xitdb` Core Procedures

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
<summary><code>xitdb.database_init</code> — <a href="../../native/xitdb-odin/xitdb/database.odin#L182-L247">database.odin#L182-L247</a></summary>

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
<summary><code>xitdb.sha1_hasher</code> — <a href="../../native/xitdb-odin/xitdb/types.odin#L828-L837">types.odin#L828-L837</a></summary>

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
<summary><code>xitdb.tx_put</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L993-L997">dsl.odin#L993-L997</a></summary>

```odin
tx_put :: proc(tx: ^Tx, path_str: string, val: Writeable_Data) -> Error {
	steps := _tx_parse_steps(tx, path_str) or_return
	append(&tx.ops, Tx_Op{kind = .Put, steps = steps, val = val})
	return nil
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
<summary><code>xitdb.tx_report_destroy</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L950-L953">dsl.odin#L950-L953</a></summary>

```odin
tx_report_destroy :: proc(report: ^Tx_Report, allocator := context.allocator) {
	diff_changes_destroy(report.changes, allocator)
	report.changes = nil
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
<summary><code>xitdb.sha256_hasher</code> — <a href="../../native/xitdb-odin/xitdb/types.odin#L840-L849">types.odin#L840-L849</a></summary>

```odin
sha256_hasher :: proc(id: u32 = 0, file_id: u64 = 0) -> Hasher {
	return Hasher{
		hash_proc = proc(data: []u8, out_hash: []u8, _: rawptr) {
			sha256_sum_into(data, out_hash)
		},
		hash_size = 32,
		id        = id,
		file_id   = file_id,
	}
}
```

</details>
