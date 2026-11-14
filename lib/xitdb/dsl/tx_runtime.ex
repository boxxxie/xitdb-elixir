defmodule Xitdb.DSL.TxRuntime do
  @moduledoc false

  alias Xitdb.{Collection, Cursor, NIF, TxCompiler}

  @enforce_keys [:db, :opts]
  defstruct [:db, :opts, index_ops: [], ops: [], staged_log: nil]

  def init_state(db, opts, track_staged? \\ false) do
    with {:ok, validated} <- Xitdb.validate_transact_opts(opts) do
      tx_ref = make_ref()

      state = %__MODULE__{
        db: db,
        opts: validated,
        staged_log: if(track_staged?, do: [], else: nil)
      }

      Process.put(tx_ref, state)
      {:ok, tx_ref}
    end
  end

  def cleanup_state(tx_ref) do
    Process.delete(tx_ref)
    :ok
  end

  def commit_state(tx_ref) do
    %__MODULE__{db: db, opts: opts, index_ops: index_ops, ops: ops} = Process.get(tx_ref)
    all_ops = :lists.reverse(index_ops, :lists.reverse(ops))
    Xitdb.transact_ops(db, all_ops, opts)
  end

  def put(tx_ref, selector, value) when is_binary(selector) do
    %__MODULE__{} = state = Process.get(tx_ref)

    cond do
      is_nil(value) ->
        rm(tx_ref, selector)
        nil

      not is_map(value) and not is_list(value) ->
        op = {:put, selector, value}

        staged_log =
          append_staged(state.staged_log, {:put, parse_selector_steps(selector), value})

        Process.put(tx_ref, %__MODULE__{state | ops: [op | state.ops], staged_log: staged_log})
        value

      true ->
        compiled_ops = TxCompiler.compile_node(selector, value, true)

        staged_log =
          case state.staged_log do
            nil ->
              nil

            log ->
              [{:put, parse_selector_steps(selector), materialize_staged_value(value)} | log]
          end

        new_state = %__MODULE__{
          state
          | ops: :lists.reverse(compiled_ops, state.ops),
            staged_log: staged_log
        }

        Process.put(tx_ref, new_state)
        value
    end
  end

  def put_set_member(tx_ref, selector) when is_binary(selector) do
    %__MODULE__{} = state = Process.get(tx_ref)
    op = {:put, selector, ""}

    staged_log =
      append_staged(state.staged_log, {:put_set_member, parse_selector_steps(selector)})

    Process.put(tx_ref, %__MODULE__{state | ops: [op | state.ops], staged_log: staged_log})
    true
  end

  def update(tx_ref, selector, fun) when is_binary(selector) and is_function(fun, 1) do
    %__MODULE__{} = state = Process.get(tx_ref)
    current = read_current_value(state, selector)
    put(tx_ref, selector, fun.(current))
  end

  def update(tx_ref, selector, default, fun)
      when is_binary(selector) and is_function(fun, 1) do
    %__MODULE__{} = state = Process.get(tx_ref)
    current = read_current_value(state, selector)
    resolved = if is_nil(current), do: default, else: current
    put(tx_ref, selector, fun.(resolved))
  end

  def rm(tx_ref, selector) when is_binary(selector) do
    %__MODULE__{} = state = Process.get(tx_ref)
    staged_log = append_staged(state.staged_log, {:rm, parse_selector_steps(selector)})

    Process.put(tx_ref, %__MODULE__{
      state
      | ops: [{:rm, selector} | state.ops],
        staged_log: staged_log
    })

    :ok
  end

  def append(tx_ref, selector, value) when is_binary(selector) do
    %__MODULE__{} = state = Process.get(tx_ref)

    staged_log =
      case state.staged_log do
        nil ->
          nil

        log ->
          [{:append, parse_selector_steps(selector), materialize_staged_value(value)} | log]
      end

    Process.put(tx_ref, %__MODULE__{
      state
      | ops: [{:append, selector, value} | state.ops],
        staged_log: staged_log
    })

    value
  end

  def insert(tx_ref, selector, index, value)
      when is_binary(selector) and is_integer(index) do
    %__MODULE__{} = state = Process.get(tx_ref)

    staged_log =
      case state.staged_log do
        nil ->
          nil

        log ->
          [
            {:insert, parse_selector_steps(selector), index, materialize_staged_value(value)}
            | log
          ]
      end

    Process.put(tx_ref, %__MODULE__{
      state
      | ops: [{:insert, selector, index, value} | state.ops],
        staged_log: staged_log
    })

    value
  end

  def slice(tx_ref, selector, first.._last//1 = range) when is_binary(selector) do
    slice(tx_ref, selector, first, Range.size(range))
  end

  def slice(tx_ref, selector, offset, size)
      when is_binary(selector) and is_integer(offset) and is_integer(size) do
    %__MODULE__{} = state = Process.get(tx_ref)

    staged_log =
      append_staged(state.staged_log, {:slice, parse_selector_steps(selector), offset, size})

    Process.put(tx_ref, %__MODULE__{
      state
      | ops: [{:slice, selector, offset, size} | state.ops],
        staged_log: staged_log
    })

    :ok
  end

  def fork(tx_ref, from_selector, to_selector)
      when is_binary(from_selector) and is_binary(to_selector) do
    %__MODULE__{} = state = Process.get(tx_ref)

    staged_log =
      case state.staged_log do
        nil ->
          nil

        log ->
          cloned = read_current_value(state, from_selector)
          [{:put, parse_selector_steps(to_selector), cloned} | log]
      end

    Process.put(tx_ref, %__MODULE__{
      state
      | ops: [{:fork, from_selector, to_selector} | state.ops],
        staged_log: staged_log
    })

    :ok
  end

  def index_on(tx_ref, src_map, field_key, idx_map) do
    %__MODULE__{} = state = Process.get(tx_ref)
    op = {:index_on, to_string(src_map), to_string(field_key), to_string(idx_map)}
    Process.put(tx_ref, %__MODULE__{state | index_ops: [op | state.index_ops]})
    :ok
  end

  def init_col(tx_ref, selector, kind, reset?) when is_binary(selector) do
    %__MODULE__{} = state = Process.get(tx_ref)
    op_tag = if reset?, do: :reset_col, else: :init_col
    empty_val = empty_collection_value(kind)

    staged_log =
      append_staged(state.staged_log, {op_tag, parse_selector_steps(selector), empty_val})

    Process.put(tx_ref, %__MODULE__{
      state
      | ops: [{op_tag, selector, to_string(kind)} | state.ops],
        staged_log: staged_log
    })

    :ok
  end

  def meta(tx_ref, key, val) do
    %__MODULE__{} = state = Process.get(tx_ref)
    Process.put(tx_ref, %__MODULE__{state | ops: [{:meta, to_string(key), val} | state.ops]})
    val
  end

  def instant(tx_ref, epoch_ms) when is_integer(epoch_ms) do
    %__MODULE__{} = state = Process.get(tx_ref)
    Process.put(tx_ref, %__MODULE__{state | ops: [{:instant, epoch_ms} | state.ops]})
    epoch_ms
  end

  def savepoint(tx_ref) do
    %__MODULE__{} = state = Process.get(tx_ref)
    Process.put(tx_ref, %__MODULE__{state | ops: [{:savepoint, ""} | state.ops]})
    :ok
  end

  defp append_staged(nil, _entry), do: nil
  defp append_staged(log, entry), do: [entry | log]

  defp empty_collection_value(kind) when kind in [:hash_map, :counted_hash_map, :sorted_map],
    do: %{}

  defp empty_collection_value(kind) when kind in [:array_list, :linked_array_list], do: []

  defp empty_collection_value(kind) when kind in [:hash_set, :counted_hash_set, :sorted_set],
    do: MapSet.new()

  defp empty_collection_value(_), do: nil

  defp materialize_staged_value(%Collection{kind: kind, data: data})
       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    Map.new(data, fn {k, v} -> {to_string(k), materialize_staged_value(v)} end)
  end

  defp materialize_staged_value(%Collection{kind: kind, data: list})
       when kind in [:array_list, :linked_array_list] do
    Enum.map(list, &materialize_staged_value/1)
  end

  defp materialize_staged_value(%Collection{kind: kind, data: members})
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    MapSet.new(members, &to_string/1)
  end

  defp materialize_staged_value(%MapSet{} = set) do
    MapSet.new(set, &to_string/1)
  end

  defp materialize_staged_value(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), materialize_staged_value(v)} end)
  end

  defp materialize_staged_value(list) when is_list(list) do
    Enum.map(list, &materialize_staged_value/1)
  end

  defp materialize_staged_value(scalar), do: scalar

  defp read_current_value(%__MODULE__{staged_log: staged_log, db: db, opts: opts}, selector) do
    target_steps = parse_selector_steps(selector)
    chronological = :lists.reverse(staged_log || [])
    base_steps = effective_base_steps(chronological, target_steps)

    {start_base, entries_to_apply} =
      case split_at_last_overwrite(chronological, base_steps) do
        {:overwritten, remaining} ->
          {nil, remaining}

        :needs_db ->
          base_sel = format_steps_selector(base_steps)
          {read_committed_value(db, opts, base_sel), chronological}
      end

    resolved_base =
      Enum.reduce(entries_to_apply, start_base, fn entry, acc ->
        apply_staged_entry(entry, base_steps, acc)
      end)

    rel_tail = Enum.drop(target_steps, length(base_steps))
    get_at_steps(resolved_base, rel_tail)
  end

  defp effective_base_steps(chronological, target_steps) do
    Enum.reduce(chronological, target_steps, fn
      {:append, steps, _}, cur -> if prefix_steps?(steps, cur), do: steps, else: cur
      {:insert, steps, _, _}, cur -> if prefix_steps?(steps, cur), do: steps, else: cur
      {:slice, steps, _, _}, cur -> if prefix_steps?(steps, cur), do: steps, else: cur
      _, cur -> cur
    end)
  end

  defp split_at_last_overwrite(chronological, target_steps) do
    chronological
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {entry, idx}, last_idx ->
      if overwrites_target?(entry, target_steps), do: idx, else: last_idx
    end)
    |> case do
      nil -> :needs_db
      idx -> {:overwritten, Enum.drop(chronological, idx)}
    end
  end

  defp overwrites_target?({op, steps, _val}, target_steps) when op in [:put, :reset_col] do
    prefix_steps?(steps, target_steps)
  end

  defp overwrites_target?({:rm, steps}, target_steps) do
    prefix_steps?(steps, target_steps)
  end

  defp overwrites_target?({:put_set_member, steps}, target_steps) do
    steps == target_steps
  end

  defp overwrites_target?(_entry, _target_steps), do: false

  defp read_committed_value(db, opts, selector) do
    if Xitdb.moment_count(db) == 0 do
      nil
    else
      base_moment = Keyword.get(opts, :base_moment, -1)

      if selector == "" do
        Xitdb.materialize(Xitdb.as_of(db, base_moment))
      else
        case NIF.nif_select(db.db_ref, base_moment, selector) do
          {:ok, raw} ->
            case Cursor.unwrap_nif_value(db.db_ref, raw, base_moment, []) do
              %Cursor{} = cur -> Xitdb.materialize(cur)
              scalar -> scalar
            end

          {:error, _} ->
            nil
        end
      end
    end
  end

  defp apply_staged_entry({:put, steps, val}, target_steps, current) do
    case step_relation(steps, target_steps) do
      :exact -> val
      {:ancestor, rel_tail} -> get_at_steps(val, rel_tail)
      {:descendant, rel_tail} -> put_at_steps(current, rel_tail, val)
      :disjoint -> current
    end
  end

  defp apply_staged_entry({:put_set_member, steps}, target_steps, current) do
    case step_relation(steps, target_steps) do
      :exact -> true
      {:descendant, rel_tail} -> put_set_member_at_steps(current, rel_tail)
      _ -> current
    end
  end

  defp apply_staged_entry({:rm, steps}, target_steps, current) do
    case step_relation(steps, target_steps) do
      :exact -> nil
      {:ancestor, _rel_tail} -> nil
      {:descendant, rel_tail} -> rm_at_steps(current, rel_tail)
      :disjoint -> current
    end
  end

  defp apply_staged_entry({:reset_col, steps, empty_val}, target_steps, current) do
    case step_relation(steps, target_steps) do
      :exact -> empty_val
      {:ancestor, _rel_tail} -> nil
      {:descendant, rel_tail} -> put_at_steps(current, rel_tail, empty_val)
      :disjoint -> current
    end
  end

  defp apply_staged_entry({:init_col, steps, empty_val}, target_steps, current) do
    case step_relation(steps, target_steps) do
      :exact ->
        if is_nil(current), do: empty_val, else: current

      {:descendant, rel_tail} ->
        if is_nil(get_at_steps(current, rel_tail)) do
          put_at_steps(current, rel_tail, empty_val)
        else
          current
        end

      _ ->
        current
    end
  end

  defp apply_staged_entry({:append, steps, elem}, target_steps, current) do
    update_list_at_steps(steps, target_steps, current, fn list ->
      (list || []) ++ [elem]
    end)
  end

  defp apply_staged_entry({:insert, steps, idx, elem}, target_steps, current) do
    update_list_at_steps(steps, target_steps, current, fn list ->
      base = list || []
      resolved_idx = resolve_insert_index(base, idx)
      List.insert_at(base, resolved_idx, elem)
    end)
  end

  defp apply_staged_entry({:slice, steps, offset, size}, target_steps, current) do
    update_list_at_steps(steps, target_steps, current, fn
      list when is_list(list) ->
        if size <= 0, do: [], else: Enum.slice(list, offset, size)

      other ->
        other
    end)
  end

  defp update_list_at_steps(steps, target_steps, current, list_fun) do
    case step_relation(steps, target_steps) do
      :exact ->
        list_fun.(current)

      {:descendant, rel_tail} ->
        existing = get_at_steps(current, rel_tail)
        put_at_steps(current, rel_tail, list_fun.(existing))

      _ ->
        current
    end
  end

  defp resolve_insert_index(list, idx) when idx < 0, do: max(length(list) + idx, 0)
  defp resolve_insert_index(list, idx), do: min(idx, length(list))

  defp prefix_steps?(prefix, steps) do
    p_len = length(prefix)
    length(steps) >= p_len and Enum.take(steps, p_len) == prefix
  end

  defp step_relation(steps, target_steps) do
    cond do
      steps == target_steps -> :exact
      prefix_steps?(steps, target_steps) -> {:ancestor, Enum.drop(target_steps, length(steps))}
      prefix_steps?(target_steps, steps) -> {:descendant, Enum.drop(steps, length(target_steps))}
      true -> :disjoint
    end
  end

  defp get_at_steps(val, []), do: val
  defp get_at_steps(nil, _steps), do: nil

  defp get_at_steps(map, [{kind, key} | rest])
       when kind in [:hash_map, :counted_hash_map, :sorted_map] and is_map(map) and
              not is_struct(map) do
    get_at_steps(Map.get(map, key), rest)
  end

  defp get_at_steps(list, [{kind, idx} | rest])
       when kind in [:array_list, :linked_array_list] and is_list(list) do
    get_at_steps(Enum.at(list, idx), rest)
  end

  defp get_at_steps(%MapSet{} = set, [{kind, member}])
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    if MapSet.member?(set, member), do: true, else: nil
  end

  defp get_at_steps(_other, _steps), do: nil

  defp put_at_steps(_current, [], val), do: val

  defp put_at_steps(current, [{kind, key} | rest], val)
       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    base = if is_map(current) and not is_struct(current), do: current, else: %{}
    Map.put(base, key, put_at_steps(Map.get(base, key), rest, val))
  end

  defp put_at_steps(current, [{kind, idx} | rest], val)
       when kind in [:array_list, :linked_array_list] do
    base = if is_list(current), do: current, else: []
    resolved = if idx < 0, do: length(base) + idx, else: idx

    cond do
      resolved >= 0 and resolved < length(base) ->
        List.replace_at(base, resolved, put_at_steps(Enum.at(base, resolved), rest, val))

      resolved == length(base) ->
        base ++ [put_at_steps(nil, rest, val)]

      true ->
        base
    end
  end

  defp put_at_steps(%MapSet{} = set, [{kind, member}], _val)
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    MapSet.put(set, member)
  end

  defp put_at_steps(_current, [{kind, member}], _val)
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    MapSet.new([member])
  end

  defp put_set_member_at_steps(current, [{kind, member}])
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    base = if match?(%MapSet{}, current), do: current, else: MapSet.new()
    MapSet.put(base, member)
  end

  defp put_set_member_at_steps(current, [step | rest]) do
    put_at_steps(current, [step], put_set_member_at_steps(get_at_steps(current, [step]), rest))
  end

  defp rm_at_steps(nil, _steps), do: nil

  defp rm_at_steps(map, [{kind, key}])
       when kind in [:hash_map, :counted_hash_map, :sorted_map] and is_map(map) and
              not is_struct(map) do
    Map.delete(map, key)
  end

  defp rm_at_steps(list, [{:linked_array_list, idx}]) when is_list(list) do
    List.delete_at(list, idx)
  end

  defp rm_at_steps(%MapSet{} = set, [{kind, member}])
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    MapSet.delete(set, member)
  end

  defp rm_at_steps(current, [step | rest]) do
    case get_at_steps(current, [step]) do
      nil -> current
      child -> put_at_steps(current, [step], rm_at_steps(child, rest))
    end
  end

  defp format_steps_selector([]), do: ""

  defp format_steps_selector(steps) do
    Enum.map_join(steps, "", fn {kind, key_or_idx} ->
      Xitdb.Selector.format_step(kind, key_or_idx)
    end)
  end

  defp parse_selector_steps(selector) when is_binary(selector) do
    selector
    |> strip_leading_moment()
    |> do_parse_steps([])
  end

  defp strip_leading_moment(<<?@, rest::binary>>) do
    {_num, tail} = take_until_sigil(rest)
    tail
  end

  defp strip_leading_moment(bin), do: bin

  defp do_parse_steps(<<>>, acc), do: :lists.reverse(acc)

  defp do_parse_steps(<<?#, ?%, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:counted_hash_set, key} | acc])
  end

  defp do_parse_steps(<<?., rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:hash_map, key} | acc])
  end

  defp do_parse_steps(<<?#, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:counted_hash_map, key} | acc])
  end

  defp do_parse_steps(<<?$, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:sorted_map, key} | acc])
  end

  defp do_parse_steps(<<?%, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:hash_set, key} | acc])
  end

  defp do_parse_steps(<<?^, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:sorted_set, key} | acc])
  end

  defp do_parse_steps(<<?[, ?[, rest::binary>>, acc) do
    {int_str, <<?], ?], tail::binary>>} = take_until_byte(rest, ?])
    do_parse_steps(tail, [{:linked_array_list, String.to_integer(int_str)} | acc])
  end

  defp do_parse_steps(<<?[, ?", rest::binary>>, acc) do
    {unescaped, <<?], tail::binary>>} = parse_quoted_string(rest, [])
    do_parse_steps(tail, [{:hash_map, unescaped} | acc])
  end

  defp do_parse_steps(<<?[, rest::binary>>, acc) do
    {int_str, <<?], tail::binary>>} = take_until_byte(rest, ?])
    do_parse_steps(tail, [{:array_list, String.to_integer(int_str)} | acc])
  end

  defp do_parse_steps(bin, acc) do
    {key, tail} = parse_key_token(bin)
    do_parse_steps(tail, [{:hash_map, key} | acc])
  end

  defp parse_key_token(<<?[, ?", rest::binary>>) do
    {unescaped, <<?], tail::binary>>} = parse_quoted_string(rest, [])
    {unescaped, tail}
  end

  defp parse_key_token(bin), do: take_until_sigil(bin)

  defp take_until_sigil(bin), do: do_take_until_sigil(bin, 0, bin)

  defp do_take_until_sigil(<<>>, len, orig), do: {binary_part(orig, 0, len), <<>>}

  defp do_take_until_sigil(<<b, _::binary>> = tail, len, orig)
       when b in [?., ?#, ?$, ?[, ?%, ?^] do
    {binary_part(orig, 0, len), tail}
  end

  defp do_take_until_sigil(<<_, rest::binary>>, len, orig) do
    do_take_until_sigil(rest, len + 1, orig)
  end

  defp take_until_byte(bin, stop_byte), do: do_take_until_byte(bin, stop_byte, 0, bin)

  defp do_take_until_byte(<<b, _::binary>> = tail, b, len, orig) do
    {binary_part(orig, 0, len), tail}
  end

  defp do_take_until_byte(<<_, rest::binary>>, stop_byte, len, orig) do
    do_take_until_byte(rest, stop_byte, len + 1, orig)
  end

  defp parse_quoted_string(<<?", tail::binary>>, acc),
    do: {IO.iodata_to_binary(:lists.reverse(acc)), tail}

  defp parse_quoted_string(<<?\\, ?\\, rest::binary>>, acc),
    do: parse_quoted_string(rest, [?\\ | acc])

  defp parse_quoted_string(<<?\\, ?", rest::binary>>, acc),
    do: parse_quoted_string(rest, [?" | acc])

  defp parse_quoted_string(<<?\\, ?n, rest::binary>>, acc),
    do: parse_quoted_string(rest, [?\n | acc])

  defp parse_quoted_string(<<?\\, ?r, rest::binary>>, acc),
    do: parse_quoted_string(rest, [?\r | acc])

  defp parse_quoted_string(<<?\\, ?t, rest::binary>>, acc),
    do: parse_quoted_string(rest, [?\t | acc])

  defp parse_quoted_string(<<b, rest::binary>>, acc),
    do: parse_quoted_string(rest, [b | acc])
end
