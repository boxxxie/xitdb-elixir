# #14: `Tx: Incremental put_in nested attribute commit`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `transactions` — #12–#16, #29–#30 (Transactions, Incremental Put, Bulk NIF Ops, List Edit & Zero-Copy Fork)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 7.86 µs (7857.0 ns) | 2.27 µs (2273.0 ns) | **`3.46x`** NIF Ratio |
| **Mean ± σ (CV)** | 7.95 µs ± 212.4 ns (2.7%) | 2.29 µs ± 39.7 ns (1.7%) | Welch `z` = `58.54` |
| **p95 / Max (`ns/op`)** | 8.19 µs / 8.19 µs | 2.34 µs / 2.35 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L366-L380`](../bench_elixir.exs#L366-L380))

```elixir
      {14, "Tx: Incremental put_in nested attribute commit", 100,
       fn ->
         {:ok, d} = Xitdb.open(backend: :memory)
         {:ok, d} = Xitdb.transact(d, %{"users" => %{"alice" => %{"score" => 0}}})
         t0 = System.monotonic_time(:nanosecond)

         for i <- 1..100 do
           {:ok, _} = Xitdb.transact(d, fn r -> put_in(r["users"]["alice"]["score"], i) end)
         end

         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         {elapsed, sz}
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1185-L1207`](../bench_client.odin#L1185-L1207))

```odin
	// #14: Incremental put_in nested attribute commit
	run_bench(14, "Tx: Incremental put_in nested attribute commit", 100, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		tx0 := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
		_ = xitdb.tx_put(&tx0, ".users.alice.score", u64(0))
		r0, _ := xitdb.tx_commit(&tx0)
		xitdb.tx_report_destroy(&r0, context.temp_allocator)
		xitdb.tx_destroy(&tx0)

		t0 := time.now()
		for i in 1 ..= 100 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			_ = xitdb.tx_put(&tx, ".users.alice.score", u64(i))
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
<summary>Elixir <code>transact</code> — <a href="../../lib/xitdb.ex#L362-L414">lib/xitdb.ex#L362-L414</a></summary>

```elixir
  def transact(db, map_or_fun, opts \\ [])

  def transact(%__MODULE__{db_ref: db_ref} = db, map, [])
      when is_map(map) and not is_struct(map) do
    encoded_map = TxCompiler.encode_value(map)

    if Compression.needs_prepare?(encoded_map, false) do
      {:ok, prepared_map, blob_ops} = Compression.prepare_write(db, encoded_map, false)
      ops = blob_ops ++ TxCompiler.compile_moment_map(prepared_map)
      do_transact_ops_default(db, db_ref, ops)
    else
      ops = TxCompiler.compile_moment_map(encoded_map)
      do_transact_ops_default(db, db_ref, ops)
    end
  rescue
    e in Protocol.UndefinedError ->
      {:error, %Error{reason: :transaction_exception, details: %{exception: e}}}
  end

  def transact(%__MODULE__{} = db, map, opts) when is_map(map) and not is_struct(map) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      try do
        compress_opt = validated[:compress]
        encoded_map = TxCompiler.encode_value(map)

        if Compression.needs_prepare?(encoded_map, compress_opt) do
          target = if validated[:base_moment] == -1, do: db, else: {db, validated[:base_moment]}

          {:ok, prepared_map, blob_ops} =
            Compression.prepare_write(target, encoded_map, compress_opt)

          ops = blob_ops ++ TxCompiler.compile_moment_map(prepared_map)
          do_transact_ops(db, ops, Keyword.put(validated, :compress, false))
        else
          ops = TxCompiler.compile_moment_map(encoded_map)
          do_transact_ops(db, ops, validated)
        end
      rescue
        e in Protocol.UndefinedError ->
          {:error, %Error{reason: :transaction_exception, details: %{exception: e}}}
      end
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
<summary>Elixir <code>get_and_update</code> — <a href="../../lib/xitdb/cursor.ex#L853-L958">lib/xitdb/cursor.ex#L853-L958</a></summary>

```elixir
  def get_and_update(%__MODULE__{} = raw_cursor, raw_key, fun) do
    key = if is_atom(raw_key), do: Atom.to_string(raw_key), else: raw_key
    %__MODULE__{} = cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
    validate_access_key!(cursor, key)
    resolved_key = resolve_list_key(cursor, key)
    child_key = if is_integer(resolved_key), do: resolved_key, else: to_string(resolved_key)
    child_steps = [{cursor.tag, child_key} | cursor.path_steps]

    callback_result =
      case lookup_staged(cursor, child_steps) do
        {:staged, current} ->
          invoke_with_current(cursor, child_steps, current, fun)

        :deleted ->
          invoke_with_current(cursor, child_steps, nil, fun)

        :miss ->
          if cursor.tx_mode and is_binary(key) and
               cursor.tag in [:hash_map, :counted_hash_map, :sorted_map] and
               (cursor.value != 0 or cursor.tag_id == -1 or cursor.fork_aliases != []) do
            case classify_access_fun(fun) do
              :blind_write ->
                fun.(nil)

              :traverse ->
                virtual_child = virtual_staged_cursor(cursor, child_steps, :hash_map, -2)
                invoke_virtual_or_fallback(cursor, resolved_key, child_steps, virtual_child, fun)

              :needs_current ->
                current = fetch_or_nil(cursor, resolved_key)
                invoke_with_current(cursor, child_steps, current, fun)
            end
          else
            current = fetch_or_nil(cursor, resolved_key)
            invoke_with_current(cursor, child_steps, current, fun)
          end
      end

    case callback_result do
      {:__xitdb_pop__, current} ->
        do_pop(cursor, resolved_key, current)

      :pop ->
        pop(cursor, resolved_key)

      {get_val, %__MODULE__{tx_mode: true, path_steps: ^child_steps} = updated_child} ->
        {get_val, merge_child_staged(cursor, updated_child)}

      {_get_val, %__MODULE__{}} ->
        raise ArgumentError,
              "cannot assign a %Xitdb.Cursor{} directly as a value inside put_in/update_in; use Xitdb.fork/3 to clone a subtree or Xitdb.materialize/1 to copy its data"

      {get_val, nil} when cursor.tag not in [:array_list, :linked_array_list] ->
        stage_rm_override(cursor, child_steps, get_val)

      {get_val, new_val} ->
        encoded_val = TxCompiler.encode_value(new_val)

        if is_nil(encoded_val) and cursor.tag not in [:array_list, :linked_array_list] do
          stage_rm_override(cursor, child_steps, get_val)
        else
          {selector, ov_key} = steps_to_selector_and_override_key(child_steps)

          new_ops =
            cond do
              is_nil(encoded_val) and cursor.tag in [:array_list, :linked_array_list] ->
                [{:put, selector, nil}]

              is_binary(encoded_val) or is_number(encoded_val) or is_boolean(encoded_val) or
                match?({:tagged, <<_, _>>, bin} when is_binary(bin), encoded_val) or
                match?({:compressed, bin} when is_binary(bin), encoded_val) or
                  match?({:compressed, bin, o} when is_binary(bin) and is_list(o), encoded_val) ->
                [{:put, selector, encoded_val}]

              true ->
                TxCompiler.compile_node(selector, encoded_val, true)
            end

          updated_overrides =
            cursor.staged_overrides
            |> purge_prefix_from_map(ov_key)
            |> Map.put(ov_key, encoded_val)

          updated_deleted =
            if MapSet.size(cursor.deleted_paths) == 0 do
              cursor.deleted_paths
            else
              cursor.deleted_paths
              |> purge_prefix_from_set(ov_key)
              |> MapSet.delete(ov_key)
            end

          updated_cursor = %__MODULE__{
            cursor
            | tx_mode: true,
              staged_ops: :lists.reverse(new_ops, cursor.staged_ops),
              staged_overrides: updated_overrides,
              deleted_paths: updated_deleted,
              staged_list_edits: purge_prefix_from_map(cursor.staged_list_edits, ov_key),
              fork_aliases: purge_fork_aliases(cursor.fork_aliases, ov_key)
          }

          {get_val, updated_cursor}
        end
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_transact</code> — <a href="../../native/xitdb_nif.odin#L6566-L6674">native/xitdb_nif.odin#L6566-L6674</a></summary>

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

	if handle.read_only {
		return make_err(env, "read_only")
	}

	tx := xitdb.tx_init(&handle.db, base_moment = base_moment, track_changes = false, allocator = context.temp_allocator)
	defer xitdb.tx_destroy(&tx)

	base_slot, _, base_empty, base_err, _ := resolve_slot_arg(handle, -1, base_moment)
	if base_err == nil && !base_empty && base_slot.tag == .Hash_Map {
		base_cur := xitdb.Read_Cursor{
			slot_ptr = xitdb.Slot_Pointer{position = nil, slot = base_slot},
			db       = &handle.db,
		}
		if base_map, bm_err := xitdb.read_hash_map_init(base_cur); bm_err == nil {
			if tx_cur_maybe, tc_err := xitdb.hash_map_get_cursor(base_map, "__tx"); tc_err == nil {
				if _, has_tx := tx_cur_maybe.?; has_tx {
					clear_steps := make([]xitdb.Path_Step, 1, tx.allocator)
					clear_steps[0] = xitdb.hm("__tx")
					append(&tx.ops, xitdb.Tx_Op{kind = .Remove, steps = clear_steps})
				}
			}
		}
	}

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
<summary>NIF <code>parse_tx_ops</code> — <a href="../../native/xitdb_nif.odin#L6201-L6563">native/xitdb_nif.odin#L6201-L6563</a></summary>

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

		case ATOM_BULK_PUT_MAPS:
			if arity != 3 {
				return "invalid_put_op", nil
			}
			steps, er, ok_steps := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_steps || er != "" || len(steps) == 0 {
				return er if er != "" else "invalid_put_op", nil
			}
			if nif_is_list(env, elems[2]) == 0 {
				return "invalid_put_op", nil
			}
			bc := new(Bulk_Put_Maps_Ctx, tx.allocator)
			bc.steps = steps
			bc.env = env
			bc.entries_term = elems[2]
			bc.validation_err = validation_err
			xitdb.tx_with_cursor(tx, bulk_put_maps_callback, bc)
			has_deferred^ = true

		case ATOM_BULK_PUT_NESTED_MAPS:
			if arity != 3 {
				return "invalid_put_op", nil
			}
			steps, er, ok_steps := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_steps || er != "" || len(steps) == 0 {
				return er if er != "" else "invalid_put_op", nil
			}
			if nif_is_list(env, elems[2]) == 0 {
				return "invalid_put_op", nil
			}
			bc := new(Bulk_Put_Nested_Maps_Ctx, tx.allocator)
			bc.steps = steps
			bc.env = env
			bc.entries_term = elems[2]
			bc.validation_err = validation_err
			xitdb.tx_with_cursor(tx, bulk_put_nested_maps_callback, bc)
			has_deferred^ = true

		case ATOM_BULK_INDEX_PUTS:
			if arity != 4 {
				return "invalid_put_op", nil
			}
			steps, er, ok_steps := decode_steps_term(env, elems[1], tx.allocator)
			if !ok_steps || er != "" || len(steps) == 0 {
				return er if er != "" else "invalid_put_op", nil
			}
			mode: Bulk_Index_Mode
			if elems[2] == ATOM_UNIQUE {
				mode = .Unique
			} else if elems[2] == ATOM_COUNTED_SET_ADD {
				mode = .Counted_Set_Add
			} else if elems[2] == ATOM_HASH_MAP_MERGE {
				mode = .Hash_Map_Merge
			} else {
				return "invalid_put_op", nil
			}
			if nif_is_list(env, elems[3]) == 0 {
				return "invalid_put_op", nil
			}
			bc := new(Bulk_Index_Puts_Ctx, tx.allocator)
			bc.steps = steps
			bc.mode = mode
			bc.env = env
			bc.entries_term = elems[3]
			bc.validation_err = validation_err
			xitdb.tx_with_cursor(tx, bulk_index_puts_callback, bc)
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
<summary>NIF <code>validate_deferred_tx_ops</code> — <a href="../../native/xitdb_nif.odin#L6166-L6199">native/xitdb_nif.odin#L6166-L6199</a></summary>

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
		} else if op.callback == bulk_put_maps_callback {
			bc := (^Bulk_Put_Maps_Ctx)(op.user_data)
			if !validate_bulk_put_maps_cold(bc.env, bc.entries_term) {
				return "invalid_put_op"
			}
		} else if op.callback == bulk_put_nested_maps_callback {
			bc := (^Bulk_Put_Nested_Maps_Ctx)(op.user_data)
			if !validate_bulk_put_nested_maps_cold(bc.env, bc.entries_term) {
				return "invalid_put_op"
			}
		} else if op.callback == bulk_index_puts_callback {
			bc := (^Bulk_Index_Puts_Ctx)(op.user_data)
			if !validate_bulk_index_puts_cold(bc.env, bc.mode, bc.entries_term) {
				return "invalid_put_op"
			}
		}
	}
	return ""
}
```

</details>

<details>
<summary>NIF <code>rollback_failed_tx</code> — <a href="../../native/xitdb_nif.odin#L5834-L5872">native/xitdb_nif.odin#L5834-L5872</a></summary>

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

<details>
<summary>NIF <code>adapt_tx_ops_for_base_moment</code> — <a href="../../native/xitdb_nif.odin#L5626-L5832">native/xitdb_nif.odin#L5626-L5832</a></summary>

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
			ensure_ancestor_pending_tags(op.steps, &pending_tags)
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
			if op.kind == .Append || op.kind == .Insert {
				ensure_ancestor_pending_tags(op.steps, &pending_tags)
				k := pending_path_key(op.steps)
				if pt, has_pt := pending_tags[k]; has_pt && pt == .None {
					pending_tags[k] = .Linked_Array_List if op.kind == .Insert else .Array_List
				}
			}
		case .Fork:
			if len(op.from_steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, op.from_steps, pending_tags, fork_aliases) {
				adapted = true
			}
			if len(op.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, op.steps, pending_tags, fork_aliases) {
				adapted = true
			}
			dst_key := pending_path_key(op.steps)
			src_key := pending_path_key(op.from_steps)
			src_tag, has_src := resolve_live_tag(base_cur, base_empty, op.from_steps, pending_tags, fork_aliases)
			base_origin, has_base_origin := resolve_fork_base_origin(base_cur, base_empty, op.from_steps, pending_tags, fork_aliases, context.temp_allocator)
			// Snapshot matching pending_tags and fork_aliases before purging dst_key.
			Pending_Copy :: struct {
				key: string,
				tag: xitdb.Tag,
			}
			Alias_Copy :: struct {
				key:   string,
				steps: []xitdb.Path_Step,
			}
			copies := make([dynamic]Pending_Copy, 0, 8, context.temp_allocator)
			for pk, ptag in pending_tags {
				if pk != src_key && pending_has_prefix(pk, src_key) {
					suffix := pk[len(src_key):]
					append(&copies, Pending_Copy{key = fmt.tprintf("%s%s", dst_key, suffix), tag = ptag})
				}
			}
			alias_copies := make([dynamic]Alias_Copy, 0, 4, context.temp_allocator)
			for ak, asteps in fork_aliases {
				if ak != src_key && len(asteps) > 0 && pending_has_prefix(ak, src_key) {
					suffix := ak[len(src_key):]
					append(&alias_copies, Alias_Copy{key = fmt.tprintf("%s%s", dst_key, suffix), steps = asteps})
				}
			}
			purge_pending_prefix(&pending_tags, dst_key)
			purge_fork_aliases_prefix(&fork_aliases, dst_key)
			ensure_ancestor_pending_tags(op.steps, &pending_tags)
			for cp in copies {
				pending_tags[cp.key] = cp.tag
			}
			for ac in alias_copies {
				fork_aliases[ac.key] = ac.steps
			}
			if has_src {
				pending_tags[dst_key] = src_tag
			}
			if has_base_origin {
				fork_aliases[dst_key] = base_origin
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
					ensure_ancestor_pending_tags(sc.steps, &pending_tags)
					record_term_pending_tags(sc.env, k, sc.term, &pending_tags)
				} else if sc.kind == .Append || sc.kind == .Insert {
					ensure_ancestor_pending_tags(sc.steps, &pending_tags)
					k := pending_path_key(sc.steps)
					if pt, has_pt := pending_tags[k]; has_pt && pt == .None {
						pending_tags[k] = .Linked_Array_List if sc.kind == .Insert else .Array_List
					}
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
			} else if op.callback == insert_op_callback && op.user_data != nil {
				ic := (^Insert_Op_Ctx)(op.user_data)
				if len(ic.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, ic.steps, pending_tags, fork_aliases) {
					adapted = true
				}
				ensure_ancestor_pending_tags(ic.steps, &pending_tags)
				k := pending_path_key(ic.steps)
				if pt, has_pt := pending_tags[k]; has_pt && pt == .None {
					pending_tags[k] = .Linked_Array_List
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
						ensure_ancestor_pending_tags(ic.steps, &pending_tags)
						pending_tags[k] = new_tag
					} else if _, exists := resolve_live_tag(base_cur, base_empty, ic.steps, pending_tags, fork_aliases); !exists {
						ensure_ancestor_pending_tags(ic.steps, &pending_tags)
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
			} else if op.callback == bulk_put_maps_callback && op.user_data != nil {
				bc := (^Bulk_Put_Maps_Ctx)(op.user_data)
				if nif_is_empty_list(bc.env, bc.entries_term) != 0 {
					continue
				}
				if len(bc.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, bc.steps, pending_tags, fork_aliases) {
					adapted = true
				}
				if !bc.adapt_containers {
					bc.adapt_containers = true
					adapted = true
				}
				ensure_ancestor_pending_tags(bc.steps, &pending_tags)
				record_bulk_put_maps_pending_tags(bc.env, base_cur, base_empty, bc.steps, bc.entries_term, &pending_tags, &fork_aliases)
			} else if op.callback == bulk_put_nested_maps_callback && op.user_data != nil {
				bc := (^Bulk_Put_Nested_Maps_Ctx)(op.user_data)
				if nif_is_empty_list(bc.env, bc.entries_term) != 0 {
					continue
				}
				if len(bc.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, bc.steps, pending_tags, fork_aliases) {
					adapted = true
				}
				if !bc.adapt_containers {
					bc.adapt_containers = true
					adapted = true
				}
				ensure_ancestor_pending_tags(bc.steps, &pending_tags)
				record_bulk_put_nested_maps_pending_tags(bc.env, base_cur, base_empty, bc.steps, bc.entries_term, &pending_tags, &fork_aliases)
			} else if op.callback == bulk_index_puts_callback && op.user_data != nil {
				bc := (^Bulk_Index_Puts_Ctx)(op.user_data)
				if nif_is_empty_list(bc.env, bc.entries_term) != 0 {
					continue
				}
				if len(bc.steps) >= 1 && adapt_steps_for_base_moment(base_cur, base_empty, bc.steps, pending_tags, fork_aliases) {
					adapted = true
				}
				if !bc.adapt_containers {
					bc.adapt_containers = true
					adapted = true
				}
				ensure_ancestor_pending_tags(bc.steps, &pending_tags)
				record_bulk_index_puts_pending_tags(bc.env, base_cur, base_empty, bc.steps, bc.mode, bc.entries_term, &pending_tags, &fork_aliases)
			}
		}
	}
	return adapted
}
```

</details>

<details>
<summary>NIF <code>decode_steps_term</code> — <a href="../../native/xitdb_nif.odin#L2699-L2715">native/xitdb_nif.odin#L2699-L2715</a></summary>

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
<summary>NIF <code>decode_writeable_value</code> — <a href="../../native/xitdb_nif.odin#L2864-L2914">native/xitdb_nif.odin#L2864-L2914</a></summary>

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
<summary>NIF <code>is_structured_write_candidate</code> — <a href="../../native/xitdb_nif.odin#L2968-L2985">native/xitdb_nif.odin#L2968-L2985</a></summary>

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
