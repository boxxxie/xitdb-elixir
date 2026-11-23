# #28: `DSL: Pre-tokenized path_steps select(path_steps(users[id].name))`

[← Back to Benchmarks Overview](../README.md) · [All Slices](README.md)

**Group:** `access` — #1–#5, #28, #32 (Lazy Access Navigation, Point Lookups, Batched Key Fetch & Pre-Tokenized DSL Select)

## Latest 1v1 Metrics

| Metric | Elixir NIF Wrapper | Raw Odin Baseline | Comparison |
| :--- | ---: | ---: | ---: |
| **Median (`ns/op`)** | 698.0 ns (698.0 ns) | 549.0 ns (549.0 ns) | **`1.27x`** NIF Ratio |
| **Mean ± σ (CV)** | 698.4 ns ± 6.8 ns (1.0%) | 550.4 ns ± 4.4 ns (0.8%) | Welch `z` = `40.86` |
| **p95 / Max (`ns/op`)** | 706.4 ns / 708.0 ns | 556.4 ns / 558.0 ns | `5` vs `5` pooled samples |

## Benchmark Harnesses (Elixir vs. Raw Odin)

### Elixir Harness ([`bench_elixir.exs#L547-L555`](../bench_elixir.exs#L547-L555))

```elixir
      {28, "DSL: Pre-tokenized path_steps select(path_steps(users[id].name))", 500,
       fn ->
         for i <- 0..499 do
           uid = "u#{i}"
           _ = Xitdb.select!(db, path_steps(users[uid].name))
         end

         0
       end},
```

### Raw Odin Harness ([`bench_client.odin#L1627-L1656`](../bench_client.odin#L1627-L1656))

```odin
	// #28: DSL: Pre-tokenized path_steps select(path_steps(users[id].name))
	if r28 {
		acc: u64 = 0
		for r in 0 ..< (g_warmup + g_runs) {
			t0 := time.now()
			for i in 0 ..< 500 {
				uid := fmt.tprintf("u%d", i)
				steps := [3]xitdb.Path_Step{
					{kind = .Hash_Map_Key, key = "users"},
					{kind = .Hash_Map_Key, key = uid},
					{kind = .Hash_Map_Key, key = "name"},
				}
				rc := xitdb.database_root_cursor(&db).read_cursor
				hist_cur, _ := xitdb.read_array_list_init(rc)
				mc_maybe, _ := xitdb.array_list_get_cursor(hist_cur, -1)
				c_maybe, _ := xitdb.read_steps_cursor(mc_maybe.?, steps[:])
				s, _ := xitdb.cursor_read_string(c_maybe.?, 0, context.temp_allocator)
				acc += u64(len(s))
				if len(s) > 0 {
					acc += u64(s[0])
				}
			}
			if r >= g_warmup {
				samples[r - g_warmup] = f64(time.duration_nanoseconds(time.since(t0))) / 500.0
			}
			free_all(context.temp_allocator)
		}
		intrinsics.volatile_store(&g_bench_sink, g_bench_sink + acc)
		record_samples(28, "DSL: Pre-tokenized path_steps select(path_steps(users[id].name))", 500, samples)
	}
```

## Elixir Wrapper & NIF Bridge

<details>
<summary>Elixir <code>path_steps</code> — <a href="../../lib/xitdb/dsl.ex#L86-L88">lib/xitdb/dsl.ex#L86-L88</a></summary>

```elixir
  defmacro path_steps(expr) do
    PathCompiler.compile_steps(expr)
  end
```

</details>

<details>
<summary>Elixir <code>compile_steps</code> — <a href="../../lib/xitdb/dsl/path_compiler.ex#L25-L29">lib/xitdb/dsl/path_compiler.ex#L25-L29</a></summary>

```elixir
  def compile_steps(ast) do
    ast
    |> extract_segments(:steps)
    |> segments_to_quoted_steps()
  end
```

</details>

<details>
<summary>Elixir <code>select!</code> — <a href="../../lib/xitdb.ex#L1057-L1074">lib/xitdb.ex#L1057-L1074</a></summary>

```elixir
  def select!(target, selector, opts \\ [])

  def select!(%__MODULE__{db_ref: db_ref}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    do_select!(db_ref, -1, selector, opts)
  end

  def select!(%Cursor{root: true, tx_mode: false, db_ref: db_ref, moment: moment}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    do_select!(db_ref, moment, selector, opts)
  end

  def select!(%Cursor{tag: tag, tx_mode: tx_mode}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    raise Error,
      reason: :non_root_cursor,
      details: %{tag: tag, tx_mode: tx_mode, selector: selector}
  end
```

</details>

<details>
<summary>Elixir <code>do_select</code> — <a href="../../lib/xitdb.ex#L957-L991">lib/xitdb.ex#L957-L991</a></summary>

```elixir
  defp do_select(db_ref, moment, selector, opts) do
    raw_tagged? = Keyword.get(opts, :raw_tagged, false)

    with {:ok, max_bytes} <- fetch_max_decompressed_bytes(opts) do
      case NIF.nif_select(db_ref, moment, selector, raw_tagged?, max_bytes) do
        {:ok, raw} when is_binary(raw) or is_number(raw) or is_boolean(raw) or is_nil(raw) ->
          {:ok, raw}

        {:ok, raw} ->
          if raw_tagged? do
            case raw do
              {:tagged, _, _} -> {:ok, raw}
              _ -> {:ok, wrap_selected(db_ref, raw, moment, selector)}
            end
          else
            eff_moment = effective_moment(moment, selector)

            case raw do
              {:tagged, tag, payload} when is_binary(payload) ->
                if Compression.compression_tag?(tag) do
                  Compression.resolve_tagged(tag, payload, db_ref, eff_moment, opts)
                else
                  {:ok, raw}
                end

              _ ->
                {:ok, wrap_selected(db_ref, raw, moment, selector)}
            end
          end

        {:error, reason} ->
          {:error, %Error{reason: reason, details: %{selector: selector}}}
      end
    end
  end
```

</details>

<details>
<summary>Elixir <code>do_select!</code> — <a href="../../lib/xitdb.ex#L1076-L1081">lib/xitdb.ex#L1076-L1081</a></summary>

```elixir
  defp do_select!(db_ref, moment, selector, opts) do
    case do_select(db_ref, moment, selector, opts) do
      {:ok, val} -> val
      {:error, %Error{} = err} -> raise err
    end
  end
```

</details>

<details>
<summary>NIF <code>odin_nif_select</code> — <a href="../../native/xitdb_nif.odin#L6681-L6781">native/xitdb_nif.odin#L6681-L6781</a></summary>

```odin
odin_nif_select :: proc "c" (env: ErlNifEnv, argc: c.int, argv: [^]ERL_NIF_TERM) -> ERL_NIF_TERM {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	if argc != 3 && argc != 4 && argc != 5 {
		return make_err(env, "badarg")
	}
	raw_tagged := false
	if argc >= 4 {
		bt, ok_rt := parse_bool_arg(argv[3])
		if !ok_rt {
			return make_err(env, "badarg")
		}
		raw_tagged = bt
	}
	max_bytes: u64 = MAX_NIF_DECOMPRESSED_BYTES
	if argc == 5 {
		mb, ok_mb := parse_max_bytes_arg(env, argv[4])
		if !ok_mb {
			return make_err(env, "badarg")
		}
		max_bytes = mb
	}
	moment_idx: i64 = -1
	if nif_get_int64(env, argv[1], &moment_idx) == 0 {
		return make_err(env, "badarg")
	}
	step_buf: [16]xitdb.Path_Step = ---
	parsed, p_err, ok_s := decode_selector_term_buf(env, argv[2], step_buf[:], context.temp_allocator)
	if !ok_s {
		return make_err(env, "badarg")
	}
	if p_err != "" {
		return make_err(env, p_err)
	}
	effective_moment := parsed.moment_index if parsed.has_moment else moment_idx

	handle, ok := acquire_rlock(env, argv[0])
	if !ok {
		return make_err(env, "closed")
	}
	defer nif_rwlock_runlock(handle.rwlock)

	m_slot, _, is_empty, r_err, err_reason := resolve_slot_arg(handle, -1, effective_moment)
	if r_err != nil {
		return make_xitdb_err(env, r_err)
	}
	if err_reason != "" {
		return make_err(env, err_reason)
	}
	if is_empty {
		if len(parsed.steps) > 0 {
			return make_ok(env, ATOM_NIL)
		}
		return make_ok(
			env,
			nif_make_tuple3(
				env,
				ATOM_CURSOR,
				nif_make_int64(env, i64(u8(xitdb.Tag.Hash_Map))),
				nif_make_int64(env, 0),
			),
		)
	}

	m_cur := xitdb.Read_Cursor{
		slot_ptr = xitdb.Slot_Pointer{position = nil, slot = m_slot},
		db       = &handle.db,
	}
	cur := m_cur
	if len(parsed.steps) > 0 {
		hit_scalar := false
		cur_maybe, err := xitdb.read_steps_cursor(m_cur, parsed.steps)
		if err != nil {
			if err == .Unexpected_Tag {
				cur_maybe, hit_scalar, err = read_steps_cursor_adaptive(m_cur, parsed.steps)
			}
			if err != nil {
				if err == .Unexpected_Tag && !hit_scalar {
					return make_ok(env, ATOM_NIL)
				}
				return make_xitdb_err(env, err)
			}
		}
		found_cur, found := cur_maybe.?
		if !found {
			return make_ok(env, ATOM_NIL)
		}
		cur = found_cur
	}

	codec_err := ""
	term, t_err := slot_to_term(env, &handle.db, cur.slot_ptr.slot, raw_tagged, &codec_err, max_bytes)
	if t_err != nil {
		if len(codec_err) > 0 {
			return make_err(env, codec_err)
		}
		return make_xitdb_err(env, t_err)
	}
	return make_ok(env, term)
}
```

</details>

<details>
<summary>NIF <code>decode_selector_term_buf</code> — <a href="../../native/xitdb_nif.odin#L2717-L2813">native/xitdb_nif.odin#L2717-L2813</a></summary>

```odin
decode_selector_term_buf :: proc(
	env: ErlNifEnv,
	term: ERL_NIF_TERM,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: xitdb.Parsed_Selector, err_reason: string, term_ok: bool) {
	if nif_is_binary(env, term) != 0 {
		sel_str, ok_s := get_string_from_binary(env, term)
		if !ok_s {
			return {}, "", false
		}
		parsed, er := parse_escaped_selector_buf(sel_str, buf, allocator)
		return parsed, er, true
	}
	if nif_is_list(env, term) != 0 {
		raw_buf: [17]Nif_Raw_Step = ---
		raw_count: c.int = 0
		rc := nif_unpack_step_list(env, term, &raw_buf[0], 17, &raw_count)
		if rc == -3 {
			return {}, "invalid_selector", true
		}
		if rc == 0 {
			raw_slice := raw_buf[:int(raw_count)]
			if len(raw_slice) == 0 {
				return xitdb.Parsed_Selector{}, "", true
			}
			is_at_moment := (raw_slice[0].kind_code >= 3 && raw_slice[0].kind_code <= 5) && raw_slice[0].tag_term == ATOM_AT_MOMENT
			if is_at_moment {
				if raw_slice[0].kind_code != 4 {
					return {}, "invalid_selector", true
				}
				sub := raw_slice[1:]
				if len(sub) <= len(buf) {
					steps, er := convert_raw_steps_buf(env, sub, buf, allocator)
					if er != "" {
						return {}, er, true
					}
					return xitdb.Parsed_Selector{
						has_moment   = true,
						moment_index = raw_slice[0].index_val,
						steps        = steps,
					}, "", true
				}
			} else if len(raw_slice) <= len(buf) {
				steps, er := convert_raw_steps_buf(env, raw_slice, buf, allocator)
				if er != "" {
					return {}, er, true
				}
				return xitdb.Parsed_Selector{steps = steps}, "", true
			}
		}

		head: ERL_NIF_TERM = 0
		tail: ERL_NIF_TERM = 0
		if nif_get_list_cell(env, term, &head, &tail) == 0 {
			if nif_is_empty_list(env, term) != 0 {
				return xitdb.Parsed_Selector{}, "", true
			}
			return {}, "invalid_selector", true
		}

		parsed := xitdb.Parsed_Selector{}
		arity: c.int = 0
		elems: [^]ERL_NIF_TERM = nil
		if nif_get_tuple(env, head, &arity, &elems) != 0 && arity == 2 && elems[0] == ATOM_AT_MOMENT {
			m_idx: i64 = 0
			if nif_get_int64(env, elems[1], &m_idx) == 0 {
				return {}, "invalid_selector", true
			}
			parsed.has_moment = true
			parsed.moment_index = m_idx
			steps, er := decode_steps_list_buf(env, tail, buf, allocator)
			if er != "" {
				return {}, er, true
			}
			parsed.steps = steps
			return parsed, "", true
		}

		first_step, s_err := decode_one_step_term(env, head, allocator)
		if s_err != "" {
			return {}, s_err, true
		}
		buf_len := 0
		dyn: [dynamic]xitdb.Path_Step
		using_dyn := false
		push_path_step(buf, &buf_len, &dyn, &using_dyn, first_step, allocator)

		steps, er := decode_steps_list_tail_buf(env, tail, buf, buf_len, &dyn, using_dyn, allocator)
		if er != "" {
			return {}, er, true
		}
		parsed.steps = steps
		return parsed, "", true
	}
	return {}, "", false
}
```

</details>

<details>
<summary>NIF <code>decode_steps_term_buf</code> — <a href="../../native/xitdb_nif.odin#L2668-L2697">native/xitdb_nif.odin#L2668-L2697</a></summary>

```odin
decode_steps_term_buf :: proc(
	env: ErlNifEnv,
	term: ERL_NIF_TERM,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: []xitdb.Path_Step, err_reason: string, term_ok: bool) {
	if nif_is_binary(env, term) != 0 {
		path_str, ok_p := get_string_from_binary(env, term)
		if !ok_p {
			return nil, "", false
		}
		steps, er := parse_escaped_steps_buf(path_str, buf, allocator)
		return steps, er, true
	}
	if nif_is_list(env, term) != 0 {
		raw_buf: [16]Nif_Raw_Step = ---
		raw_count: c.int = 0
		rc := nif_unpack_step_list(env, term, &raw_buf[0], 16, &raw_count)
		if rc == -3 {
			return nil, "invalid_selector", true
		}
		if rc == 0 && int(raw_count) <= len(buf) {
			steps, er := convert_raw_steps_buf(env, raw_buf[:int(raw_count)], buf, allocator)
			return steps, er, true
		}
		steps, er := decode_steps_list_buf(env, term, buf, allocator)
		return steps, er, true
	}
	return nil, "", false
}
```

</details>

<details>
<summary>NIF <code>read_steps_cursor_adaptive</code> — <a href="../../native/xitdb_nif.odin#L4776-L4835">native/xitdb_nif.odin#L4776-L4835</a></summary>

```odin
read_steps_cursor_adaptive :: proc(root: xitdb.Read_Cursor, steps: []xitdb.Path_Step) -> (res: Maybe(xitdb.Read_Cursor), hit_scalar: bool, err: xitdb.Error) {
	cur := root
	for i := 0; i < len(steps); i += 1 {
		step := steps[i]
		sp := xitdb.cursor_resolved(cur) or_return
		if sp.slot.tag == .None {
			return nil, false, nil
		}
		if !is_container_tag(sp.slot.tag) {
			return nil, true, .Unexpected_Tag
		}
		next_maybe: Maybe(xitdb.Read_Cursor)
		if step.kind == .Hash_Map_Key {
			#partial switch sp.slot.tag {
			case .Hash_Map:
				hm := xitdb.read_hash_map_init(cur) or_return
				next_maybe = xitdb.hash_map_get_cursor(hm, step.key) or_return
			case .Counted_Hash_Map:
				chm := xitdb.read_counted_hash_map_init(cur) or_return
				next_maybe = xitdb.hash_map_get_cursor(chm.read_hash_map, step.key) or_return
			case .Sorted_Map:
				sm := xitdb.read_sorted_map_init(cur) or_return
				next_maybe = xitdb.sorted_map_get_cursor(sm, step.key) or_return
			case .Hash_Set:
				hs := xitdb.read_hash_set_init(cur) or_return
				next_maybe = xitdb.hash_set_get_cursor(hs, step.key) or_return
			case .Counted_Hash_Set:
				cs := xitdb.read_counted_hash_set_init(cur) or_return
				next_maybe = xitdb.hash_set_get_cursor(cs.read_hash_set, step.key) or_return
			case .Sorted_Set:
				ss := xitdb.read_sorted_set_init(cur) or_return
				next_maybe = xitdb.cursor_read_path(
					ss.cursor,
					[]xitdb.Path_Part{xitdb.Sorted_Map_Get{target = xitdb.Sorted_Map_Get_Key{key = transmute([]u8)step.key}}},
				) or_return
			case:
				return nil, false, .Unexpected_Tag
			}
		} else if step.kind == .Array_List_Idx {
			#partial switch sp.slot.tag {
			case .Array_List:
				al := xitdb.read_array_list_init(cur) or_return
				next_maybe = xitdb.array_list_get_cursor(al, step.index) or_return
			case .Linked_Array_List:
				ll := xitdb.read_linked_array_list_init(cur) or_return
				next_maybe = xitdb.linked_array_list_get_cursor(ll, step.index) or_return
			case:
				return nil, false, .Unexpected_Tag
			}
		} else {
			next_maybe = xitdb.read_steps_cursor(cur, steps[i:i + 1]) or_return
		}
		next_cur, found := next_maybe.?
		if !found {
			return nil, false, nil
		}
		cur = next_cur
	}
	return cur, false, nil
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
<summary>NIF <code>parse_escaped_selector_buf</code> — <a href="../../native/xitdb_nif.odin#L2393-L2428">native/xitdb_nif.odin#L2393-L2428</a></summary>

```odin
parse_escaped_selector_buf :: proc(
	sel_str: string,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: xitdb.Parsed_Selector, err_reason: string) {
	s := strings.trim_space(sel_str)
	if len(s) == 0 {
		return {}, ""
	}
	i := 0
	if s[i] == '@' {
		i += 1
		start := i
		if i < len(s) && s[i] == '-' {
			i += 1
		}
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i += 1
		}
		if i == start || (i == start + 1 && s[start] == '-') {
			return {}, "invalid_selector"
		}
		m_idx, ok := strconv.parse_i64(s[start:i])
		if !ok {
			return {}, "invalid_selector"
		}
		res.has_moment = true
		res.moment_index = m_idx
	}
	steps, er := parse_escaped_steps_buf(s[i:], buf, allocator)
	if er != "" {
		return {}, er
	}
	res.steps = steps
	return res, ""
}
```

</details>

<details>
<summary>NIF <code>convert_raw_steps_buf</code> — <a href="../../native/xitdb_nif.odin#L2574-L2620">native/xitdb_nif.odin#L2574-L2620</a></summary>

```odin
convert_raw_steps_buf :: proc(
	env: ErlNifEnv,
	raw_steps: []Nif_Raw_Step,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: []xitdb.Path_Step, err_reason: string) {
	if len(raw_steps) == 0 {
		return nil, ""
	}
	if len(raw_steps) > len(buf) {
		return nil, "invalid_selector"
	}
	for i in 0 ..< len(raw_steps) {
		r := raw_steps[i]
		switch r.kind_code {
		case 0:
			k := "" if r.key_len == 0 else string(r.key_ptr[:r.key_len])
			buf[i] = xitdb.Path_Step{kind = .Hash_Map_Key, key = k}
		case 1:
			buf[i] = xitdb.Path_Step{kind = .Array_List_Idx, index = r.index_val}
		case 2:
			buf[i] = xitdb.Path_Step{kind = .Linked_List_Idx, index = r.index_val}
		case 3:
			kind, ok_k := map_tag_term_to_key_step_kind(r.tag_term)
			if !ok_k {
				return nil, "invalid_selector"
			}
			k := "" if r.key_len == 0 else string(r.key_ptr[:r.key_len])
			buf[i] = xitdb.Path_Step{kind = kind, key = k}
		case 4:
			kind, ok_i := map_tag_term_to_idx_step_kind(r.tag_term)
			if !ok_i {
				return nil, "invalid_selector"
			}
			buf[i] = xitdb.Path_Step{kind = kind, index = r.index_val}
		case 5:
			step, er := decode_tagged_step_term(env, r.tag_term, r.val_term, allocator)
			if er != "" {
				return nil, er
			}
			buf[i] = step
		case:
			return nil, "invalid_selector"
		}
	}
	return buf[:len(raw_steps)], ""
}
```

</details>

<details>
<summary>NIF <code>decode_steps_list_buf</code> — <a href="../../native/xitdb_nif.odin#L2622-L2630">native/xitdb_nif.odin#L2622-L2630</a></summary>

```odin
decode_steps_list_buf :: proc(
	env: ErlNifEnv,
	list_term: ERL_NIF_TERM,
	buf: []xitdb.Path_Step,
	allocator := context.temp_allocator,
) -> (res: []xitdb.Path_Step, err_reason: string) {
	dyn: [dynamic]xitdb.Path_Step
	return decode_steps_list_tail_buf(env, list_term, buf, 0, &dyn, false, allocator)
}
```

</details>

## Reachable `xitdb` Core Procedures

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
<summary><code>xitdb.read_steps_cursor</code> — <a href="../../native/xitdb-odin/xitdb/dsl.odin#L467-L557">dsl.odin#L467-L557</a></summary>

```odin
read_steps_cursor :: proc(start: Read_Cursor, steps: []Path_Step) -> (res: Maybe(Read_Cursor), err: Error) {
	cur := start
	for step in steps {
		switch step.kind {
		case .Hash_Map_Key:
			m := read_hash_map_init(cur) or_return
			next_maybe := hash_map_get_cursor(m, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Counted_Hash_Map_Key:
			cm := read_counted_hash_map_init(cur) or_return
			next_maybe := hash_map_get_cursor(cm.read_hash_map, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Sorted_Map_Key:
			if slot_ptr := cursor_resolved(cur) or_return; slot_ptr.slot.tag == .Hash_Map || slot_ptr.slot.tag == .Counted_Hash_Map {
				m := read_hash_map_init(cur) or_return
				next_maybe := hash_map_get_cursor(m, step.key) or_return
				next_cur, ok := next_maybe.?
				if !ok {
					return nil, nil
				}
				cur = next_cur
			} else {
				sm_col := read_sorted_map_init(cur) or_return
				next_maybe := sorted_map_get_cursor(sm_col, step.key) or_return
				next_cur, ok := next_maybe.?
				if !ok {
					return nil, nil
				}
				cur = next_cur
			}

		case .Array_List_Idx:
			al_col := read_array_list_init(cur) or_return
			next_maybe := array_list_get_cursor(al_col, step.index) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Linked_List_Idx:
			ll_col := read_linked_array_list_init(cur) or_return
			next_maybe := linked_array_list_get_cursor(ll_col, step.index) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Hash_Set_Member:
			hs_col := read_hash_set_init(cur) or_return
			next_maybe := hash_set_get_cursor(hs_col, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Counted_Set_Member:
			cs_col := read_counted_hash_set_init(cur) or_return
			next_maybe := hash_set_get_cursor(cs_col.read_hash_set, step.key) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur

		case .Sorted_Set_Member:
			ss_col := read_sorted_set_init(cur) or_return
			next_maybe := cursor_read_path(ss_col.cursor, []Path_Part{
				Sorted_Map_Get{target = Sorted_Map_Get_Key{key = transmute([]u8)step.key}},
			}) or_return
			next_cur, ok := next_maybe.?
			if !ok {
				return nil, nil
			}
			cur = next_cur
		}
	}
	return cur, nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_read_string</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L242-L245">cursor.odin#L242-L245</a></summary>

```odin
cursor_read_string :: proc(c: Read_Cursor, max_size: i64 = 0, allocator := context.allocator) -> (res: string, err: Error) {
	b := cursor_read_bytes(c, max_size, allocator) or_return
	return string(b), nil
}
```

</details>

<details>
<summary><code>xitdb.cursor_resolved</code> — <a href="../../native/xitdb-odin/xitdb/cursor.odin#L50-L57">cursor.odin#L50-L57</a></summary>

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
<summary><code>xitdb.sorted_map_get_cursor</code> — <a href="../../native/xitdb-odin/xitdb/collections.odin#L789-L791">collections.odin#L789-L791</a></summary>

```odin
sorted_map_get_cursor :: proc(m: Read_Sorted_Map, key: string) -> (Maybe(Read_Cursor), Error) {
	return sorted_map_get_cursor_by_bytes(m, transmute([]u8)key)
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
