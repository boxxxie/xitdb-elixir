# #15: `Tx: Linked_Array_List O(log N) mid-list insert + delete`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `transactions` — #12–#16 (Transactions, Incremental Put, List Edit & Zero-Copy Fork)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 13.78 µs (13782.0 ns) | 5.39 µs (5394.0 ns) | **`2.56x`** NIF Ratio |
| **Mean ± σ (CV)** | 13.67 µs ± 187.6 ns (1.4%) | 5.41 µs ± 235.4 ns (4.3%) | Welch `z` = `61.32` |
| **p95 / Max (`ns/op`)** | 13.81 µs / 13.82 µs | 5.69 µs / 5.73 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L370-L390`](../bench_elixir.exs#L370-L390))

```elixir
      {15, "Tx: Linked_Array_List O(log N) mid-list insert + delete", 50,
       fn ->
         {:ok, d} = Xitdb.open(backend: :memory)
         init_list = Enum.map(0..499, &"item_#{&1}")
         {:ok, d} = Xitdb.transact(d, %{"linked" => Xitdb.linked_list(init_list)})
         t0 = System.monotonic_time(:nanosecond)

         for i <- 0..49 do
           {:ok, _} =
             Xitdb.transact(d, fn r ->
               r
               |> Xitdb.insert_at(["linked"], 250, "mid_#{i}")
               |> Xitdb.delete_at(["linked"], 250)
             end)
         end

         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         {elapsed, sz}
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1129-L1154`](../bench_client.odin#L1129-L1154))

```odin
	// #15: Linked_Array_List O(log N) mid-list insert_at + delete_at
	run_bench(15, "Tx: Linked_Array_List O(log N) mid-list insert + delete", 50, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		tx0 := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		for i in 0 ..< 500 {
			_ = xitdb.tx_put(&tx0, fmt.tprintf(".linked[[%d]]", i), fmt.tprintf("item_%d", i))
		}
		r0, _ := xitdb.tx_commit(&tx0)
		xitdb.tx_report_destroy(&r0, context.temp_allocator)
		xitdb.tx_destroy(&tx0)

		t0 := time.now()
		for i in 0 ..< 50 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			_ = xitdb.tx_insert(&tx, ".linked", 250, fmt.tprintf("mid_%d", i))
			_ = xitdb.tx_rm(&tx, ".linked[[250]]")
			rep, _ := xitdb.tx_commit(&tx)
			xitdb.tx_report_destroy(&rep, context.temp_allocator)
			xitdb.tx_destroy(&tx)
		}
		dur := time.since(t0)
		sz, _ := xitdb.core_length(&c)
		return dur, sz
	})
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>transact</code> — <a href="../../lib/xitdb.ex#L316-L339">lib/xitdb.ex#L316-L339</a></summary>

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
<summary>Elixir <code>insert_at</code> — <a href="../../lib/xitdb.ex#L490-L499">lib/xitdb.ex#L490-L499</a></summary>

```elixir
  def insert_at(%Cursor{} = root, path_or_selector, index, value)
      when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
    updated = Cursor.stage_list_insert(root, path_or_selector, index, value)

    %Cursor{
      updated
      | tx_mode: true,
        staged_ops: [{:insert, path_or_selector, index, value} | updated.staged_ops]
    }
  end
```

</details>

<details>
<summary>Elixir <code>delete_at</code> — <a href="../../lib/xitdb.ex#L506-L522">lib/xitdb.ex#L506-L522</a></summary>

```elixir
  def delete_at(%Cursor{} = root, path_or_selector, index)
      when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
    selector =
      if is_binary(path_or_selector) do
        path_or_selector <> Selector.format_step(:linked_array_list, index)
      else
        path_or_selector ++ [[index]]
      end

    updated = Cursor.stage_list_delete(root, path_or_selector, index)

    %Cursor{
      updated
      | tx_mode: true,
        staged_ops: [{:rm, selector} | updated.staged_ops]
    }
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_transact</code> — <a href="../../native/xitdb_nif.odin#L4945-L5031">native/xitdb_nif.odin#L4945-L5031</a></summary>

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
	pre_rh_bytes: [xitdb.ROOT_HEADER_LENGTH]u8 = ---
	pre_rh_err := xitdb.core_read_exact_at(handle.db.core, xitdb.ROOT_HEADER_START, pre_rh_bytes[:])

	rep: xitdb.Tx_Report
	c_err: xitdb.Error
	for attempt := 0; attempt < 2; attempt += 1 {
		rep, c_err = xitdb.tx_commit(&tx)
		if c_err == nil {
			break
		}
		if rb_err := rollback_failed_tx(&handle.db, pre_header, pre_hdr_err, pre_len, pre_len_err, pre_rh_bytes, pre_rh_err); rb_err != nil {
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
<summary>NIF <code>parse_tx_ops</code> — <a href="../../native/xitdb_nif.odin#L4650-L4942">native/xitdb_nif.odin#L4650-L4942</a></summary>

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
				append(&tx.ops, xitdb.Tx_Op{kind = .Insert, steps = steps, offset = idx_val, val = val})
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
<summary>NIF <code>validate_deferred_tx_ops</code> — <a href="../../native/xitdb_nif.odin#L4630-L4648">native/xitdb_nif.odin#L4630-L4648</a></summary>

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
<summary>NIF <code>rollback_failed_tx</code> — <a href="../../native/xitdb_nif.odin#L4426-L4463">native/xitdb_nif.odin#L4426-L4463</a></summary>

```odin
rollback_failed_tx :: proc(
	db: ^xitdb.Database,
	pre_header: xitdb.Root_Header,
	pre_hdr_err: xitdb.Error,
	pre_len: i64,
	pre_len_err: xitdb.Error,
	pre_rh_bytes: [xitdb.ROOT_HEADER_LENGTH]u8,
	pre_rh_err: xitdb.Error,
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

	cur_rh_bytes: [xitdb.ROOT_HEADER_LENGTH]u8 = ---
	cur_rh_err := xitdb.core_read_exact_at(db.core, xitdb.ROOT_HEADER_START, cur_rh_bytes[:])
	hdr_changed := pre_rh_err == nil && (cur_rh_err != nil || cur_rh_bytes != pre_rh_bytes)
	if hdr_changed {
		rh_bytes := xitdb.root_header_to_bytes(pre_header) if pre_hdr_err == nil else pre_rh_bytes
		xitdb.core_seek_to(db.core, xitdb.ROOT_HEADER_START) or_return
		xitdb.core_write_all(db.core, rh_bytes[:]) or_return
		xitdb.core_flush(db.core) or_return
		xitdb.core_sync(db.core) or_return
	} else if len_changed {
		xitdb.core_flush(db.core) or_return
	}
	return nil
}
```

</details>

<details>
<summary>NIF <code>adapt_tx_ops_for_base_moment</code> — <a href="../../native/xitdb_nif.odin#L4302-L4424">native/xitdb_nif.odin#L4302-L4424</a></summary>

```odin
adapt_tx_ops_for_base_moment :: proc(handle: ^Db_Handle, tx: ^xitdb.Tx) -> bool {
	base_moment_idx := tx.base_moment.? or_else -1
	base_slot, _, base_empty, base_err, _ := resolve_slot_arg(handle, -1, base_moment_idx)
	if base_err != nil {
		return false
	}
	base_cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = xitdb.Slot{} if base_empty else base_slot},
		db       = &handle.db,
	}

	pending_tags := make(map[string]xitdb.Tag, 16, context.temp_allocator)
	fork_aliases := make(map[string][]xitdb.Path_Step, 4, context.temp_allocator)
	adapted := false
	for &op in tx.ops {
		switch op.kind {
		case .Put:
			if len(op.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, op.steps, pending_tags, fork_aliases) {
				adapted = true
			}
			k := pending_path_key(op.steps)
			purge_pending_prefix(&pending_tags, k)
			purge_fork_aliases_prefix(&fork_aliases, k)
		case .Remove:
			if len(op.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, op.steps, pending_tags, fork_aliases) {
				adapted = true
			}
			k := pending_path_key(op.steps)
			purge_pending_prefix(&pending_tags, k)
			purge_fork_aliases_prefix(&fork_aliases, k)
		case .Append, .Insert, .Slice:
			if len(op.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, op.steps, pending_tags, fork_aliases) {
				adapted = true
			}
		case .Fork:
			if len(op.from_steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, op.from_steps, pending_tags, fork_aliases) {
				adapted = true
			}
			if len(op.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, op.steps, pending_tags, fork_aliases) {
				adapted = true
			}
			dst_key := pending_path_key(op.steps)
			purge_pending_prefix(&pending_tags, dst_key)
			purge_fork_aliases_prefix(&fork_aliases, dst_key)
			src_key := pending_path_key(op.from_steps)
			copied_any := false
			// Snapshot matching pending_tags before inserting new entries
			Pending_Copy :: struct {
				key: string,
				tag: xitdb.Tag,
			}
			copies := make([dynamic]Pending_Copy, 0, 8, context.temp_allocator)
			for pk, ptag in pending_tags {
				if pending_has_prefix(pk, src_key) && ptag != .None {
					suffix := pk[len(src_key):]
					append(&copies, Pending_Copy{key = fmt.tprintf("%s%s", dst_key, suffix), tag = ptag})
					copied_any = true
				}
			}
			for cp in copies {
				pending_tags[cp.key] = cp.tag
			}
			if !copied_any && !base_empty {
				if src_tag, has_src := resolve_live_tag(base_cur, base_empty, op.from_steps, pending_tags); has_src {
					pending_tags[dst_key] = src_tag
				}
				fork_aliases[dst_key] = op.from_steps
			}
		case .Savepoint:
			// no steps
		case .Callback:
			if op.callback == structured_op_callback && op.user_data != nil {
				sc := (^Structured_Op_Ctx)(op.user_data)
				if len(sc.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, sc.steps, pending_tags, fork_aliases) {
					adapted = true
				}
				if sc.kind == .Put {
					k := pending_path_key(sc.steps)
					purge_pending_prefix(&pending_tags, k)
					purge_fork_aliases_prefix(&fork_aliases, k)
					record_term_pending_tags(sc.env, k, sc.term, &pending_tags)
				}
			} else if op.callback == rm_if_exists_callback && op.user_data != nil {
				rc := (^Rm_If_Exists_Ctx)(op.user_data)
				if len(rc.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, rc.steps, pending_tags, fork_aliases) {
					adapted = true
				}
				k := pending_path_key(rc.steps)
				purge_pending_prefix(&pending_tags, k)
				purge_fork_aliases_prefix(&fork_aliases, k)
			} else if op.callback == slice_op_callback && op.user_data != nil {
				sc := (^Slice_Op_Ctx)(op.user_data)
				if len(sc.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, sc.steps, pending_tags, fork_aliases) {
					adapted = true
				}
			} else if op.callback == init_col_callback && op.user_data != nil {
				ic := (^Init_Col_Ctx)(op.user_data)
				if len(ic.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, ic.steps, pending_tags, fork_aliases) {
					adapted = true
				}
				if new_tag, ok_t := tag_from_col_kind(ic.kind); ok_t {
					k := pending_path_key(ic.steps)
					if ic.reset {
						purge_pending_prefix(&pending_tags, k)
						purge_fork_aliases_prefix(&fork_aliases, k)
						pending_tags[k] = new_tag
					} else if _, exists := resolve_live_tag(base_cur, base_empty, ic.steps, pending_tags); !exists {
						pending_tags[k] = new_tag
					}
				}
			} else if op.callback == merge_map_callback && op.user_data != nil {
				mc := (^Merge_Map_Ctx)(op.user_data)
				if !mc.adapt_containers {
					mc.adapt_containers = true
					adapted = true
				}
				prefix_steps := make([dynamic]xitdb.Path_Step, 0, 4, context.temp_allocator)
				record_merge_map_pending_tags(mc.env, base_cur, base_empty, mc.map_term, &prefix_steps, &pending_tags, &fork_aliases)
			}
		}
	}
	return adapted
}
```

</details>

<details>
<summary>NIF <code>decode_steps_term</code> — <a href="../../native/xitdb_nif.odin#L2205-L2221">native/xitdb_nif.odin#L2205-L2221</a></summary>

```odin
decode_steps_term :: proc(
	env: ErlNifEnv,
	term: ERL_NIF_TERM,
	allocator := context.temp_allocator,
) -> (res: []xitdb.Path_Step, err_reason: string, term_ok: bool) {
	stack_buf: [16]xitdb.Path_Step = ---
	steps, er, ok_t := decode_steps_term_buf(env, term, stack_buf[:], allocator)
	if !ok_t || er != "" || len(steps) == 0 {
		return steps, er, ok_t
	}
	if raw_data(steps) == raw_data(stack_buf[:]) {
		out := make([]xitdb.Path_Step, len(steps), allocator)
		copy(out, steps)
		return out, "", true
	}
	return steps, "", true
}
```

</details>

<details>
<summary>NIF <code>decode_writeable_value</code> — <a href="../../native/xitdb_nif.odin#L2370-L2420">native/xitdb_nif.odin#L2370-L2420</a></summary>

```odin
decode_writeable_value :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> (xitdb.Writeable_Data, bool) {
	if nif_is_binary(env, term) != 0 {
		s, ok := get_string_from_binary(env, term)
		return s, ok
	}
	if nif_is_atom(env, term) != 0 {
		if term == ATOM_TRUE {
			return xitdb.Bytes{value = transmute([]u8)string("1"), format_tag = transmute([]u8)string("bl")}, true
		}
		if term == ATOM_FALSE {
			return xitdb.Bytes{value = transmute([]u8)string("0"), format_tag = transmute([]u8)string("bl")}, true
		}
		if term == ATOM_NIL {
			return xitdb.Slot{}, true
		}
		buf := make([]u8, 1024, context.temp_allocator)
		a_str, ok := get_atom_string(env, term, buf)
		if !ok {
			return nil, false
		}
		return a_str, true
	}
	if nif_is_tuple(env, term) != 0 {
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, term, &arity, &elems) != 0 && arity == 3 && elems[0] == ATOM_TAGGED {
			fmt_tag, ok_t := get_string_from_binary(env, elems[1])
			payload, ok_p := get_string_from_binary(env, elems[2])
			if ok_t && ok_p {
				return xitdb.Bytes{
					value      = transmute([]u8)payload,
					format_tag = transmute([]u8)fmt_tag,
				}, true
			}
		}
		return nil, false
	}

	i_val: i64 = 0
	if nif_get_int64(env, term, &i_val) != 0 {
		if i_val >= 0 {
			return u64(i_val), true
		}
		return i_val, true
	}
	f_val: f64 = 0
	if nif_get_double(env, term, &f_val) != 0 {
		return f_val, true
	}
	return nil, false
}
```

</details>

<details>
<summary>NIF <code>is_structured_write_candidate</code> — <a href="../../native/xitdb_nif.odin#L2474-L2491">native/xitdb_nif.odin#L2474-L2491</a></summary>

```odin
is_structured_write_candidate :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> bool {
	if nif_is_list(env, term) != 0 {
		return true
	}
	if nif_is_map(env, term) != 0 {
		struct_term: ERL_NIF_TERM
		if nif_get_map_value(env, term, ATOM_STRUCT, &struct_term) != 0 {
			return struct_term == ATOM_XITDB_COLLECTION_MOD || struct_term == ATOM_MAPSET_MOD
		}
		return true
	}
	arity: c.int = 0
	elems: [^]ERL_NIF_TERM = nil
	if nif_get_tuple(env, term, &arity, &elems) != 0 {
		return (arity == 2 && elems[0] == ATOM_XITDB_SET) || (arity == 3 && elems[0] == ATOM_XITDB_COL)
	}
	return false
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
<summary><code>xitdb.sha1_hasher</code> — <a href="../../native/xitdb-odin/xitdb/types.odin#L826-L835">types.odin#L826-L835</a></summary>

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
<summary><code>xitdb.tx_init</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L627-L637">dsl.odin#L627-L637</a></summary>

```odin
tx_init :: proc(db: ^Database, base_moment: Maybe(i64) = -1, track_changes := false, allocator := context.temp_allocator) -> Tx {
	return Tx{
		db            = db,
		base_moment   = base_moment,
		track_changes = track_changes,
		meta          = make([dynamic]Tx_Meta_Entry, 0, 4, allocator),
		ops           = make([dynamic]Tx_Op, 0, 8, allocator),
		index_rules   = make([dynamic]Secondary_Index_Rule, 0, 2, allocator),
		allocator     = allocator,
	}
}
```

</details>

<details>
<summary><code>xitdb.tx_put</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L698-L702">dsl.odin#L698-L702</a></summary>

```odin
tx_put :: proc(tx: ^Tx, path_str: string, val: Writeable_Data) -> Error {
	steps := parse_steps(path_str, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Put, steps = steps, val = val})
	return nil
}
```

</details>

<details>
<summary><code>xitdb.tx_commit</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L1035-L1092">dsl.odin#L1035-L1092</a></summary>

```odin
tx_commit :: proc(tx: ^Tx) -> (report: Tx_Report, err: Error) {
	rc := database_root_cursor(tx.db)
	history := write_array_list_init(rc) or_return
	hist_count := array_list_count(history.read_array_list) or_return

	ectx := _Tx_Exec_Ctx{
		tx       = tx,
		recorded = make([dynamic]Tx_Change, 0, len(tx.ops), tx.allocator),
	}
	defer if err != nil {
		diff_changes_destroy(ectx.recorded[:], tx.allocator)
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
<summary><code>xitdb.tx_report_destroy</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L667-L670">dsl.odin#L667-L670</a></summary>

```odin
tx_report_destroy :: proc(report: ^Tx_Report, allocator := context.allocator) {
	diff_changes_destroy(report.changes, allocator)
	report.changes = nil
}
```

</details>

<details>
<summary><code>xitdb.tx_destroy</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L640-L652">dsl.odin#L640-L652</a></summary>

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
	delete(tx.meta)
	delete(tx.ops)
	delete(tx.index_rules)
}
```

</details>

<details>
<summary><code>xitdb.tx_insert</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L716-L720">dsl.odin#L716-L720</a></summary>

```odin
tx_insert :: proc(tx: ^Tx, path_str: string, index: i64, val: Writeable_Data) -> Error {
	steps := parse_steps(path_str, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Insert, steps = steps, offset = index, val = val})
	return nil
}
```

</details>

<details>
<summary><code>xitdb.tx_rm</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L728-L732">dsl.odin#L728-L732</a></summary>

```odin
tx_rm :: proc(tx: ^Tx, path_str: string) -> Error {
	steps := parse_steps(path_str, tx.allocator) or_return
	append(&tx.ops, Tx_Op{kind = .Remove, steps = steps})
	return nil
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
