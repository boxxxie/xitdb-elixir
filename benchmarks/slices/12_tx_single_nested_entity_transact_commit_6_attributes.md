# #12: `Tx: Single nested entity transact commit (6 attributes)`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `transactions` — #12–#16 (Transactions, Incremental Put, List Edit & Zero-Copy Fork)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 13.66 µs (13663.0 ns) | 12.51 µs (12511.0 ns) | **`1.09x`** NIF Ratio |
| **Mean ± σ (CV)** | 14.21 µs ± 1.04 µs (7.3%) | 12.55 µs ± 124.0 ns (1.0%) | Welch `z` = `3.54` |
| **p95 / Max (`ns/op`)** | 15.64 µs / 16.04 µs | 12.72 µs / 12.76 µs | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L291-L317`](../bench_elixir.exs#L291-L317))

```elixir
      {12, "Tx: Single nested entity transact commit (6 attributes)", 100,
       fn ->
         {:ok, d} = Xitdb.open(backend: :memory)
         t0 = System.monotonic_time(:nanosecond)

         for i <- 0..99 do
           uid = "u#{i}"

           {:ok, _} =
             Xitdb.transact(d, %{
               "users" => %{
                 uid => %{
                   "name" => "Alice",
                   "age" => 30,
                   "dept" => "eng",
                   "city" => "Montreal",
                   "roles" => ["admin", "staff"]
                 }
               }
             })
         end

         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         {elapsed, sz}
       end},
```

### Raw Odin Harness ([`bench_client.odin#L950-L972`](../bench_client.odin#L950-L972))

```odin
	// #12: Single nested entity transact commit
	run_bench(12, "Tx: Single nested entity transact commit (6 attributes)", 100, proc() -> (time.Duration, i64) {
		c := xitdb.core_memory_init()
		defer xitdb.core_destroy(&c)
		d, _ := xitdb.database_init(&c, xitdb.sha1_hasher())
		t0 := time.now()
		for i in 0 ..< 100 {
			tx := xitdb.tx_init(&d, base_moment = -1, track_changes = false, allocator = context.temp_allocator)
			uid := fmt.tprintf("u%d", i)
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.name", uid), "Alice")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.age", uid), u64(30))
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.dept", uid), "eng")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.city", uid), "Montreal")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.roles[0]", uid), "admin")
			_ = xitdb.tx_put(&tx, fmt.tprintf(".users.%s.roles[1]", uid), "staff")
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
<summary>Elixir <code>transact</code> — <a href="../../lib/xitdb.ex#L316-L362">lib/xitdb.ex#L316-L362</a></summary>

```elixir
  def transact(db, map_or_fun, opts \\ [])

  def transact(%__MODULE__{} = db, map, opts) when is_map(map) and not is_struct(map) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      ops = TxCompiler.compile_moment_map(map)
      do_transact_ops(db, ops, validated)
    end
  end

  def transact(%__MODULE__{db_ref: db_ref} = db, fun, opts) when is_function(fun, 1) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      base_moment = validated[:base_moment]

      root_cursor = %Cursor{
        db_ref: db_ref,
        tag: :hash_map,
        tag_id: -1,
        value: base_moment,
        moment: base_moment,
        root: true,
        tx_mode: true
      }

      try do
        case fun.(root_cursor) do
          %Cursor{staged_ops: ops} ->
            do_transact_ops(db, :lists.reverse(ops), validated)

          {:abort, reason} ->
            {:error, %Error{reason: reason}}

          other when is_map(other) and not is_struct(other) ->
            ops = TxCompiler.compile_moment_map(other)
            do_transact_ops(db, ops, validated)

          other ->
            {:error, %Error{reason: :invalid_transaction_return, details: %{value: other}}}
        end
      rescue
        e in Error ->
          {:error, e}

        e ->
          {:error, %Error{reason: :transaction_exception, details: %{exception: e}}}
      end
    end
  end
```

</details>

<details>
<summary>Elixir <code>compile_moment_map</code> — <a href="../../lib/xitdb/tx_compiler.ex#L15-L47">lib/xitdb/tx_compiler.ex#L15-L47</a></summary>

```elixir
  def compile_moment_map(map, opts \\ []) when is_map(map) do
    index_ops =
      case Keyword.get(opts, :index_rules, []) do
        [] ->
          []

        rules ->
          Enum.map(rules, fn {:index_on, src, field, idx} ->
            {:index_on, to_string(src), to_string(field), to_string(idx)}
          end)
      end

    if Keyword.get(opts, :flatten, false) do
      acc = Enum.reverse(index_ops)

      acc =
        :maps.fold(
          fn k, v, a ->
            compile_node_acc(Selector.format_step(:hash_map, k), v, false, a)
          end,
          acc,
          map
        )

      :lists.reverse(acc)
    else
      if map_size(map) == 0 do
        index_ops
      else
        index_ops ++ [{:merge_map, map}]
      end
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_transact</code> — <a href="../../native/xitdb_nif.odin#L3393-L3698">native/xitdb_nif.odin#L3393-L3698</a></summary>

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

	head: ERL_NIF_TERM
	tail := argv[2]
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return make_err(env, "invalid_ops_list")
		}
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, head, &arity, &elems) == 0 || arity < 1 {
			return make_err(env, "invalid_op_tuple")
		}

		op_atom := elems[0]

		switch op_atom {
		case ATOM_PUT:
			if arity != 3 {
				return make_err(env, "invalid_put_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_put_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			if val, ok_v := decode_writeable_value(env, elems[2]); ok_v {
				if len(steps) == 0 {
					return make_xitdb_err(env, .Invalid_Range)
				}
				append(&tx.ops, xitdb.Tx_Op{kind = .Put, steps = steps, val = val})
			} else if validate_write_term(env, elems[2]) {
				if len(steps) == 0 {
					return make_xitdb_err(env, .Invalid_Range)
				}
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{kind = .Put, steps = steps, env = env, term = elems[2]}
				xitdb.tx_with_cursor(&tx, structured_op_callback, sc)
			} else {
				return make_err(env, "invalid_put_op")
			}

		case ATOM_APPEND:
			if arity != 3 {
				return make_err(env, "invalid_append_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_append_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			if len(steps) == 0 {
				return make_err(env, "invalid_append_op")
			}
			if val, ok_v := decode_writeable_value(env, elems[2]); ok_v {
				append(&tx.ops, xitdb.Tx_Op{kind = .Append, steps = steps, val = val})
			} else if validate_write_term(env, elems[2]) {
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{kind = .Append, steps = steps, env = env, term = elems[2]}
				xitdb.tx_with_cursor(&tx, structured_op_callback, sc)
			} else {
				return make_err(env, "invalid_append_op")
			}

		case ATOM_INSERT:
			if arity != 4 {
				return make_err(env, "invalid_insert_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			idx_val: i64 = 0
			ok_i := nif_get_int64(env, elems[2], &idx_val) != 0
			if !ok_p || !ok_i {
				return make_err(env, "invalid_insert_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			if len(steps) == 0 {
				return make_err(env, "invalid_insert_op")
			}
			if val, ok_v := decode_writeable_value(env, elems[3]); ok_v {
				append(&tx.ops, xitdb.Tx_Op{kind = .Insert, steps = steps, offset = idx_val, val = val})
			} else if validate_write_term(env, elems[3]) {
				sc := new(Structured_Op_Ctx, tx.allocator)
				sc^ = Structured_Op_Ctx{kind = .Insert, steps = steps, index = idx_val, env = env, term = elems[3]}
				xitdb.tx_with_cursor(&tx, structured_op_callback, sc)
			} else {
				return make_err(env, "invalid_insert_op")
			}

		case ATOM_RM:
			if arity != 2 {
				return make_err(env, "invalid_rm_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_rm_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			append(&tx.ops, xitdb.Tx_Op{kind = .Remove, steps = steps})

		case ATOM_RM_IF_EXISTS:
			if arity != 2 {
				return make_err(env, "invalid_rm_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			if !ok_p {
				return make_err(env, "invalid_rm_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			rc := new(Rm_If_Exists_Ctx, tx.allocator)
			rc^ = Rm_If_Exists_Ctx{steps = steps, tx = &tx}
			xitdb.tx_with_cursor(&tx, rm_if_exists_callback, rc)

		case ATOM_SLICE:
			if arity != 4 {
				return make_err(env, "invalid_slice_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			offset_val: i64 = 0
			size_val: i64 = 0
			ok_o := nif_get_int64(env, elems[2], &offset_val) != 0
			ok_s := nif_get_int64(env, elems[3], &size_val) != 0
			if !ok_p || !ok_o || !ok_s {
				return make_err(env, "invalid_slice_op")
			}
			if offset_val < 0 || size_val < 0 {
				return make_xitdb_err(env, .Invalid_Range)
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			if len(steps) == 0 {
				return make_xitdb_err(env, .Invalid_Range)
			}
			sc := new(Slice_Op_Ctx, tx.allocator)
			sc^ = Slice_Op_Ctx{steps = steps, offset = offset_val, size = size_val}
			xitdb.tx_with_cursor(&tx, slice_op_callback, sc)

		case ATOM_FORK:
			if arity != 3 {
				return make_err(env, "invalid_fork_op")
			}
			from_str, ok_f := get_string_from_binary(env, elems[1])
			to_str, ok_t := get_string_from_binary(env, elems[2])
			if !ok_f || !ok_t {
				return make_err(env, "invalid_fork_op")
			}
			from_steps, f_err := parse_escaped_steps(from_str, tx.allocator)
			if f_err != "" {
				return make_err(env, f_err)
			}
			to_steps, t_err := parse_escaped_steps(to_str, tx.allocator)
			if t_err != "" {
				return make_err(env, t_err)
			}
			if len(from_steps) == 0 || len(to_steps) == 0 {
				return make_xitdb_err(env, .Invalid_Range)
			}
			append(&tx.ops, xitdb.Tx_Op{kind = .Fork, from_steps = from_steps, steps = to_steps})
			xitdb.tx_savepoint(&tx)

		case ATOM_INDEX_ON:
			if arity != 4 {
				return make_err(env, "invalid_index_on_op")
			}
			src_map, ok_1 := get_string_from_binary(env, elems[1])
			field_key, ok_2 := get_string_from_binary(env, elems[2])
			idx_map, ok_3 := get_string_from_binary(env, elems[3])
			if !ok_1 || !ok_2 || !ok_3 {
				return make_err(env, "invalid_index_on_op")
			}
			xitdb.tx_index_on(&tx, src_map, field_key, idx_map)

		case ATOM_INSTANT:
			if arity != 2 {
				return make_err(env, "invalid_instant_op")
			}
			inst_val: i64 = 0
			if nif_get_int64(env, elems[1], &inst_val) == 0 {
				return make_err(env, "invalid_instant_op")
			}
			xitdb.tx_instant(&tx, inst_val)

		case ATOM_META:
			if arity != 3 {
				return make_err(env, "invalid_meta_op")
			}
			key_str, ok_k := get_string_from_binary(env, elems[1])
			if !ok_k {
				return make_err(env, "invalid_meta_op")
			}
			if key_str == "tx_instant" {
				inst_val: i64 = 0
				if nif_get_int64(env, elems[2], &inst_val) == 0 {
					return make_err(env, "invalid_meta_op")
				}
				xitdb.tx_instant(&tx, inst_val)
			} else {
				val, ok_v := decode_writeable_value(env, elems[2])
				if !ok_v {
					return make_err(env, "invalid_meta_op")
				}
				xitdb.tx_meta(&tx, key_str, val)
			}

		case ATOM_SAVEPOINT:
			if arity != 1 {
				return make_err(env, "invalid_savepoint_op")
			}
			xitdb.tx_savepoint(&tx)

		case ATOM_INIT_COL, ATOM_RESET_COL:
			if arity != 3 {
				return make_err(env, "invalid_init_col_op")
			}
			path_str, ok_p := get_string_from_binary(env, elems[1])
			kind_str, ok_k := get_string_from_binary(env, elems[2])
			if !ok_p || !ok_k || !is_supported_col_kind(kind_str) {
				return make_err(env, "invalid_init_col_op")
			}
			steps, s_err := parse_escaped_steps(path_str, tx.allocator)
			if s_err != "" {
				return make_err(env, s_err)
			}
			ic := new(Init_Col_Ctx, tx.allocator)
			ic.steps = steps
			ic.kind = kind_str
			ic.reset = (op_atom == ATOM_RESET_COL)
			xitdb.tx_with_cursor(&tx, init_col_callback, ic)

		case ATOM_MERGE_MAP:
			if arity != 2 {
				return make_err(env, "invalid_merge_map_op")
			}
			if !validate_merge_map_term(env, elems[1], true) {
				return make_err(env, "invalid_put_op")
			}
			mc := new(Merge_Map_Ctx, tx.allocator)
			mc.env = env
			mc.map_term = elems[1]
			mc.tx = &tx
			xitdb.tx_with_cursor(&tx, merge_map_callback, mc)

		case:
			return make_err(env, "unknown_tx_op")
		}
	}

	rep, c_err := xitdb.tx_commit(&tx)
	if c_err != nil {
		return make_xitdb_err(env, c_err)
	}
	moment_idx := rep.moment_index
	xitdb.tx_report_destroy(&rep, context.temp_allocator)
	return make_ok(env, nif_make_int64(env, moment_idx))
}
```

</details>

<details>
<summary>NIF <code>parse_escaped_steps</code> — <a href="../../native/xitdb_nif.odin#L1617-L1738">native/xitdb_nif.odin#L1617-L1738</a></summary>

```odin
parse_escaped_steps :: proc(path_str: string, allocator := context.temp_allocator) -> (res: []xitdb.Path_Step, err_reason: string) {
	s := strings.trim_space(path_str)
	if len(s) == 0 {
		return nil, ""
	}
	steps := make([dynamic]xitdb.Path_Step, 0, 8, allocator)
	i := 0

	for i < len(s) {
		ch := s[i]
		switch ch {
		case '.':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Map_Key, key = key})
			i = next_i

		case '#':
			i += 1
			kind := xitdb.Step_Kind.Counted_Hash_Map_Key
			if i < len(s) && s[i] == '%' {
				kind = .Counted_Set_Member
				i += 1
			}
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = kind, key = key})
			i = next_i

		case '$':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Sorted_Map_Key, key = key})
			i = next_i

		case '%':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Set_Member, key = key})
			i = next_i

		case '^':
			i += 1
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Sorted_Set_Member, key = key})
			i = next_i

		case '[':
			if i + 1 < len(s) && s[i + 1] == '[' {
				i += 2
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i + 1 >= len(s) || s[i] != ']' || s[i + 1] != ']' {
					return nil, "invalid_selector"
				}
				idx_str := strings.trim_space(s[start:i])
				idx, ok := strconv.parse_i64(idx_str)
				if !ok {
					return nil, "invalid_selector"
				}
				append(&steps, xitdb.Path_Step{kind = .Linked_List_Idx, index = idx})
				i += 2
			} else if i + 1 < len(s) && (s[i + 1] == '"' || s[i + 1] == '\'') {
				key, next_i, er := parse_escaped_bracketed_string(s, i, allocator)
				if er != "" {
					return nil, er
				}
				step_kind := xitdb.Step_Kind.Hash_Map_Key
				if len(steps) == 1 {
					if steps[0].kind == .Counted_Hash_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Counted_Hash_Map_Key
					} else if steps[0].kind == .Sorted_Map_Key {
						steps[0].kind = .Hash_Map_Key
						step_kind = .Sorted_Map_Key
					}
				}
				append(&steps, xitdb.Path_Step{kind = step_kind, key = key})
				i = next_i
			} else {
				i += 1
				start := i
				for i < len(s) && s[i] != ']' {
					i += 1
				}
				if i >= len(s) || s[i] != ']' {
					return nil, "invalid_selector"
				}
				idx_str := strings.trim_space(s[start:i])
				idx, ok := strconv.parse_i64(idx_str)
				if !ok {
					return nil, "invalid_selector"
				}
				append(&steps, xitdb.Path_Step{kind = .Array_List_Idx, index = idx})
				i += 1
			}

		case:
			key, next_i, er := parse_escaped_ident_or_bracket(s, i, allocator)
			if er != "" {
				return nil, er
			}
			append(&steps, xitdb.Path_Step{kind = .Hash_Map_Key, key = key})
			i = next_i
		}
	}
```

</details>

<details>
<summary>NIF <code>decode_writeable_value</code> — <a href="../../native/xitdb_nif.odin#L1825-L1875">native/xitdb_nif.odin#L1825-L1875</a></summary>

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
<summary>NIF <code>validate_write_term</code> — <a href="../../native/xitdb_nif.odin#L1922-L2003">native/xitdb_nif.odin#L1922-L2003</a></summary>

```odin
validate_write_term :: proc(env: ErlNifEnv, term: ERL_NIF_TERM) -> bool {
	if _, ok := decode_writeable_value(env, term); ok {
		return true
	}
	if nif_is_tuple(env, term) != 0 {
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, term, &arity, &elems) == 0 {
			return false
		}
		if arity == 2 && elems[0] == ATOM_XITDB_SET {
			return validate_set_elements_term(env, elems[1])
		}
		if arity == 3 && elems[0] == ATOM_XITDB_COL {
			kind_str, ok_k := term_to_kind_string(env, elems[1])
			if !ok_k || !is_supported_col_kind(kind_str) {
				return false
			}
			return validate_collection_data_term(env, kind_str, elems[2])
		}
		return false
	}
	if nif_is_list(env, term) != 0 {
		head: ERL_NIF_TERM
		tail := term
		for nif_is_empty_list(env, tail) == 0 {
			if nif_get_list_cell(env, tail, &head, &tail) == 0 {
				return false
			}
			if !validate_write_term(env, head) {
				return false
			}
		}
		return true
	}
	if nif_is_map(env, term) != 0 {
		struct_term: ERL_NIF_TERM
		if nif_get_map_value(env, term, ATOM_STRUCT, &struct_term) != 0 {
			if struct_term == ATOM_XITDB_COLLECTION_MOD {
				kind_term, data_term: ERL_NIF_TERM
				if nif_get_map_value(env, term, ATOM_KIND, &kind_term) == 0 ||
				   nif_get_map_value(env, term, ATOM_DATA, &data_term) == 0 {
					return false
				}
				kind_str, ok_k := term_to_kind_string(env, kind_term)
				if !ok_k || !is_supported_col_kind(kind_str) {
					return false
				}
				return validate_collection_data_term(env, kind_str, data_term)
			}
			if struct_term == ATOM_MAPSET_MOD {
				ms_map: ERL_NIF_TERM
				if nif_get_map_value(env, term, ATOM_MAP, &ms_map) == 0 || nif_is_map(env, ms_map) == 0 {
					return false
				}
				kv_list: ERL_NIF_TERM
				if nif_map_to_kv_list(env, ms_map, &kv_list) == 0 {
					return false
				}
				head: ERL_NIF_TERM
				tail := kv_list
				for nif_is_empty_list(env, tail) == 0 {
					if nif_get_list_cell(env, tail, &head, &tail) == 0 {
						return false
					}
					arity: c.int = 0
					elems: [^]ERL_NIF_TERM = nil
					if nif_get_tuple(env, head, &arity, &elems) == 0 || arity != 2 {
						return false
					}
					if _, ok_s := term_to_key_string(env, elems[0]); !ok_s {
						return false
					}
				}
				return true
			}
			return false
		}
		return validate_kv_term(env, term)
	}
	return false
}
```

</details>

<details>
<summary>NIF <code>validate_merge_map_term</code> — <a href="../../native/xitdb_nif.odin#L2656-L2748">native/xitdb_nif.odin#L2656-L2748</a></summary>

```odin
validate_merge_map_term :: proc(env: ErlNifEnv, term: ERL_NIF_TERM, is_root: bool = true) -> bool {
	if !is_root {
		if _, ok := decode_writeable_value(env, term); ok {
			return true
		}
		if nif_is_tuple(env, term) != 0 {
			arity: c.int = 0
			elems: [^]ERL_NIF_TERM = nil
			if nif_get_tuple(env, term, &arity, &elems) == 0 {
				return false
			}
			if arity == 2 && elems[0] == ATOM_XITDB_SET {
				return validate_set_elements_term(env, elems[1])
			}
			if arity == 3 && elems[0] == ATOM_XITDB_COL {
				kind_str, ok_k := term_to_kind_string(env, elems[1])
				if !ok_k || !is_supported_col_kind(kind_str) {
					return false
				}
				return validate_collection_data_term(env, kind_str, elems[2])
			}
			return false
		}
		if nif_is_list(env, term) != 0 {
			head: ERL_NIF_TERM
			tail := term
			for nif_is_empty_list(env, tail) == 0 {
				if nif_get_list_cell(env, tail, &head, &tail) == 0 {
					return false
				}
				if !validate_merge_map_term(env, head, false) {
					return false
				}
			}
			return true
		}
	}

	if nif_is_map(env, term) == 0 {
		return false
	}
	struct_term: ERL_NIF_TERM
	if nif_get_map_value(env, term, ATOM_STRUCT, &struct_term) != 0 {
		if is_root {
			return false
		}
		if struct_term == ATOM_XITDB_COLLECTION_MOD {
			kind_term, data_term: ERL_NIF_TERM
			if nif_get_map_value(env, term, ATOM_KIND, &kind_term) == 0 ||
			   nif_get_map_value(env, term, ATOM_DATA, &data_term) == 0 {
				return false
			}
			kind_str, ok_k := term_to_kind_string(env, kind_term)
			if !ok_k || !is_supported_col_kind(kind_str) {
				return false
			}
			return validate_merge_collection_data(env, kind_str, data_term)
		}
		if struct_term == ATOM_MAPSET_MOD {
			ms_map: ERL_NIF_TERM
			if nif_get_map_value(env, term, ATOM_MAP, &ms_map) == 0 || nif_is_map(env, ms_map) == 0 {
				return false
			}
			sb: KV_Stack_Buf = ---
			keys, _, ok := extract_map_kvs(env, ms_map, &sb)
			if !ok {
				return false
			}
			for k in keys {
				if _, ok_s := term_to_key_string(env, k); !ok_s {
					return false
				}
			}
			return true
		}
		return false
	}

	sb: KV_Stack_Buf = ---
	keys, vals, ok := extract_map_kvs(env, term, &sb)
	if !ok {
		return false
	}
	for i in 0 ..< len(keys) {
		if _, ok_k := term_to_key_string(env, keys[i]); !ok_k {
			return false
		}
		if !validate_merge_map_term(env, vals[i], false) {
			return false
		}
	}
	return true
}
```

</details>

<details>
<summary>NIF <code>parse_escaped_ident_or_bracket</code> — <a href="../../native/xitdb_nif.odin#L1593-L1602">native/xitdb_nif.odin#L1593-L1602</a></summary>

```odin
parse_escaped_ident_or_bracket :: proc(s: string, start_i: int, allocator: runtime.Allocator) -> (key: string, next_i: int, err_reason: string) {
	if start_i >= len(s) {
		return "", start_i, "invalid_selector"
	}
	if s[start_i] == '[' {
		return parse_escaped_bracketed_string(s, start_i, allocator)
	}
	if s[start_i] == '"' || s[start_i] == '\'' {
		return parse_escaped_quoted(s, start_i, allocator)
	}
```

</details>

<details>
<summary>NIF <code>parse_escaped_bracketed_string</code> — <a href="../../native/xitdb_nif.odin#L1575-L1582">native/xitdb_nif.odin#L1575-L1582</a></summary>

```odin
parse_escaped_bracketed_string :: proc(s: string, start_i: int, allocator: runtime.Allocator) -> (key: string, next_i: int, err_reason: string) {
	if start_i + 2 >= len(s) || s[start_i] != '[' {
		return "", 0, "invalid_selector"
	}
	quote := s[start_i + 1]
	if quote != '"' && quote != '\'' {
		return "", 0, "invalid_selector"
	}
```

</details>

<details>
<summary>NIF <code>validate_set_elements_term</code> — <a href="../../native/xitdb_nif.odin#L2005-L2027">native/xitdb_nif.odin#L2005-L2027</a></summary>

```odin
validate_set_elements_term :: proc(env: ErlNifEnv, data_term: ERL_NIF_TERM) -> bool {
	if nif_is_map(env, data_term) != 0 {
		struct_term: ERL_NIF_TERM
		if nif_get_map_value(env, data_term, ATOM_STRUCT, &struct_term) != 0 && struct_term == ATOM_MAPSET_MOD {
			return validate_write_term(env, data_term)
		}
		return false
	}
	if nif_is_list(env, data_term) == 0 {
		return false
	}
	head: ERL_NIF_TERM
	tail := data_term
	for nif_is_empty_list(env, tail) == 0 {
		if nif_get_list_cell(env, tail, &head, &tail) == 0 {
			return false
		}
		if _, ok_s := term_to_key_string(env, head); !ok_s {
			return false
		}
	}
	return true
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
<summary><code>xitdb.tx_doc</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L672-L674">dsl.odin#L672-L674</a></summary>

```odin
tx_doc :: proc(tx: ^Tx, doc: string) {
	tx.doc = doc
}
```

</details>

<details>
<summary><code>xitdb.tx_with_cursor</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L754-L756">dsl.odin#L754-L756</a></summary>

```odin
tx_with_cursor :: proc(tx: ^Tx, fn: Context_Function, user_data: rawptr = nil) {
	append(&tx.ops, Tx_Op{kind = .Callback, callback = fn, user_data = user_data})
}
```

</details>
