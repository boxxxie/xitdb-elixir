defmodule Xitdb.Cursor do
  @moduledoc """
  Lazy, immutable view into a collection or moment inside a `Xitdb` database.

  Navigating into nested containers (`db["users"]["alice"]`) returns a lightweight
  `%Xitdb.Cursor{}` without eagerly loading child entries onto the BEAM heap, while
  navigating to a scalar returns the native Elixir value directly.

  - Implements `Access` (`cursor["key"]`, `cursor[0]`, `get_in/2`, `put_in/3`, `update_in/3`, `pop_in/2`).
  - Implements `Enumerable` (`Enum.count/1`, `Enum.member?/2`, `Enum.slice/2`, `Enum.to_list/1`, `Stream.*`).
  - Implements `Inspect` with a safe, bounded preview.
  - Because cursors are pure immutable Elixir values referencing immutable database
    moments, you can pass them freely across `Task`s, `GenServer`s, ETS, and LiveView assigns.

  See [Reading & Updating with Access & Enum](docs/access-and-enumerable.md) and
  [Architecture, Internals & Performance](docs/architecture-and-internals.md) for details.
  """

  @behaviour Access
  @on_load :register_beam_tracer

  defmodule BeamTracer do
    @moduledoc false
    def trace({:on_module, bytecode, _}, %Macro.Env{module: mod}) when is_binary(bytecode) do
      if :binary.match(bytecode, "Elixir.Access") != :nomatch do
        :persistent_term.put({Xitdb.Cursor, :bytecode, mod}, bytecode)
      end

      :ok
    end

    def trace(_event, _env), do: :ok

    def register do
      :global.trans({__MODULE__, :register_tracer}, fn ->
        tracers = Code.get_compiler_option(:tracers)

        if __MODULE__ not in tracers do
          Code.put_compiler_option(:tracers, [__MODULE__ | tracers])
        end

        :ok
      end)
    end
  end

  BeamTracer.register()

  @doc false
  def register_beam_tracer, do: BeamTracer.register()

  @compile {:inline,
            tag_atom_for: 1,
            tag_id_for: 1,
            from_compact_slot: 4,
            from_compact_slot: 5,
            from_nif_tuple: 3,
            from_nif_tuple: 4,
            handle_fetch_result: 2,
            format_step_fast: 2}

  alias Xitdb.{NIF, Selector, TxCompiler}

  @enforce_keys [:db_ref, :tag, :tag_id, :value]
  defstruct [
    :db_ref,
    :tag,
    :tag_id,
    :value,
    full: false,
    moment: -1,
    root: false,
    tx_mode: false,
    path_steps: [],
    staged_ops: [],
    staged_overrides: %{},
    deleted_paths: MapSet.new(),
    staged_list_edits: %{},
    fork_aliases: []
  ]

  @type t :: %__MODULE__{
          db_ref: reference(),
          tag: atom(),
          tag_id: integer(),
          value: integer(),
          full: boolean(),
          moment: integer(),
          root: boolean(),
          tx_mode: boolean(),
          path_steps: [{atom(), String.t() | integer()}],
          staged_ops: list(),
          staged_overrides: map(),
          deleted_paths: MapSet.t(),
          staged_list_edits: map(),
          fork_aliases: [{String.t(), String.t()}]
        }

  defmodule PreviewTag do
    @moduledoc false
    defstruct [:tag]

    defimpl Inspect do
      def inspect(%PreviewTag{tag: tag}, _opts), do: "<#{tag}>"
    end
  end

  @doc false
  @spec empty_root(reference()) :: t()
  def empty_root(db_ref) when is_reference(db_ref) do
    %__MODULE__{db_ref: db_ref, tag: :none, tag_id: 0, value: 0, moment: -1, root: true}
  end

  @doc false
  def from_nif_tuple(db_ref, tuple, moment, path_steps \\ [])

  def from_nif_tuple(db_ref, {:cursor, tag_id, val}, moment, path_steps)
      when is_integer(tag_id) and is_integer(val) do
    from_compact_slot(db_ref, tag_id, val, moment, path_steps)
  end

  def from_nif_tuple(db_ref, {:cursor, tag_atom, tag_id, val, full_int}, moment, path_steps) do
    %__MODULE__{
      db_ref: db_ref,
      tag: tag_atom,
      tag_id: tag_id,
      value: val,
      full: full_int != 0,
      moment: moment,
      path_steps: path_steps
    }
  end

  @doc false
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

  @doc false
  def unwrap_nif_value(db_ref, raw, moment, path_steps \\ [])

  def unwrap_nif_value(db_ref, {:cursor, tag_id, val}, moment, path_steps)
      when is_integer(tag_id) and is_integer(val) do
    from_compact_slot(db_ref, tag_id, val, moment, path_steps)
  end

  def unwrap_nif_value(db_ref, {:cursor, _, _, _, _} = tuple, moment, path_steps) do
    from_nif_tuple(db_ref, tuple, moment, path_steps)
  end

  def unwrap_nif_value(_db_ref, {:__xitdb_set__, list}, _moment, _path_steps) do
    MapSet.new(list)
  end

  def unwrap_nif_value(db_ref, list, moment, path_steps) when is_list(list) do
    Enum.map(list, &unwrap_nif_value(db_ref, &1, moment, path_steps))
  end

  def unwrap_nif_value(db_ref, map, moment, path_steps) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {k, unwrap_nif_value(db_ref, v, moment, path_steps)} end)
  end

  def unwrap_nif_value(db_ref, {:tagged, tag, payload}, moment, _path_steps)
      when tag in ["cz", "zs", "zd", "bp", "pg"] and is_binary(payload) do
    Xitdb.Compression.resolve_tagged!(tag, payload, db_ref, moment)
  end

  def unwrap_nif_value(_db_ref, scalar, _moment, _path_steps), do: scalar

  @doc false
  def unwrap_nif_entries(db_ref, entries, moment) when is_list(entries) do
    if entries_need_unwrap?(entries) do
      Enum.map(entries, fn
        {k, v} ->
          {unwrap_nif_value(db_ref, k, moment, []), unwrap_nif_value(db_ref, v, moment, [])}

        item ->
          unwrap_nif_value(db_ref, item, moment, [])
      end)
    else
      entries
    end
  end

  defp entries_need_unwrap?([]), do: false

  defp entries_need_unwrap?([item | rest])
       when is_binary(item) or is_number(item) or is_boolean(item) or is_nil(item) do
    entries_need_unwrap?(rest)
  end

  defp entries_need_unwrap?([{k, v} | rest])
       when is_binary(k) and (is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v)) do
    entries_need_unwrap?(rest)
  end

  defp entries_need_unwrap?(_), do: true

  # ============================================================================
  # Access Behaviour (`cursor["key"]`, `cursor[idx]`, `get_in`, `put_in`, `pop_in`)
  # ============================================================================

  @impl Access
  def fetch(%__MODULE__{} = cursor, key) when is_atom(key) do
    fetch(cursor, Atom.to_string(key))
  end

  def fetch(%__MODULE__{tx_mode: false, tag: :none}, _key), do: :error

  def fetch(%__MODULE__{tx_mode: false} = cursor, key) when is_binary(key) do
    cursor.db_ref
    |> NIF.nif_slot_get_key(cursor.tag_id, cursor.value, key)
    |> handle_fetch_result(cursor)
  end

  def fetch(%__MODULE__{tx_mode: false} = cursor, key) when is_integer(key) do
    cursor
    |> nif_slot_get(key)
    |> handle_fetch_result(cursor)
  end

  def fetch(%__MODULE__{tx_mode: true} = raw_cursor, key)
      when is_integer(key) or is_binary(key) do
    cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor

    if mismatched_access_key?(cursor, key) do
      :error
    else
      resolved_key = resolve_list_key(cursor, key)
      child_key = if is_integer(resolved_key), do: resolved_key, else: to_string(resolved_key)
      child_steps = [{cursor.tag, child_key} | cursor.path_steps]

      case lookup_staged(cursor, child_steps) do
        {:staged, val} ->
          {:ok, val}

        :deleted ->
          :error

        :miss ->
          self_sel = steps_to_override_key(cursor.path_steps)
          child_sel = steps_to_override_key(child_steps)

          cond do
            is_integer(resolved_key) and Map.has_key?(cursor.staged_list_edits, self_sel) ->
              list = fetch_edited_list(cursor, self_sel)

              if resolved_key >= 0 and resolved_key < length(list) do
                {:ok, wrap_staged_val(cursor, child_steps, Enum.at(list, resolved_key))}
              else
                :error
              end

            cursor.fork_aliases != [] ->
              case resolve_fork_alias(cursor.fork_aliases, child_sel) do
                {:ok, alias_sel} ->
                  fetch_aliased_disk(cursor, child_steps, alias_sel)

                :none ->
                  fetch_disk_tx_miss(cursor, resolved_key, child_steps)
              end

            true ->
              fetch_disk_tx_miss(cursor, resolved_key, child_steps)
          end
      end
    end
  end

  defp fetch_disk_tx_miss(cursor, resolved_key, child_steps) do
    cond do
      cursor.value == -2 ->
        fetch_virtual_disk(cursor, child_steps)

      cursor.value == 0 and cursor.tag_id != -1 and pointer_container_tag?(cursor.tag) ->
        maybe_fetch_staged_descendant(cursor, child_steps)

      true ->
        case nif_slot_get(cursor, resolved_key) do
          {:ok, raw} ->
            val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
            {:ok, inherit_staged(val, cursor)}

          :error ->
            maybe_fetch_staged_descendant(cursor, child_steps)

          {:error, reason} ->
            raise Xitdb.Error, reason: reason
        end
    end
  end

  defp fetch_aliased_disk(cursor, child_steps, alias_sel) do
    case NIF.nif_select(cursor.db_ref, cursor.moment, alias_sel) do
      {:ok, nil} ->
        maybe_fetch_staged_descendant(cursor, child_steps)

      {:ok, raw} ->
        val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
        {:ok, inherit_staged(val, cursor)}

      {:error, reason} ->
        raise Xitdb.Error, reason: reason
    end
  end

  defp mismatched_access_key?(%__MODULE__{tag: tag}, key)
       when is_integer(key) and tag not in [:array_list, :linked_array_list],
       do: true

  defp mismatched_access_key?(%__MODULE__{tag: tag}, key)
       when is_binary(key) and tag in [:array_list, :linked_array_list],
       do: true

  defp mismatched_access_key?(_cursor, _key), do: false

  defp validate_access_key!(%__MODULE__{} = cursor, key) do
    if mismatched_access_key?(cursor, key) do
      raise Xitdb.Error,
        reason: :unexpected_tag,
        details: %{
          tag: cursor.tag,
          key: key,
          selector: steps_to_selector(cursor.path_steps),
          virtual_probe: cursor.value == -2
        }
    end
  end

  defp handle_fetch_result({:ok, {:cursor, tag_id, val}}, cursor) do
    {:ok, from_compact_slot(cursor.db_ref, tag_id, val, cursor.moment)}
  end

  defp handle_fetch_result({:ok, {:cursor, _, _, _, _} = tuple}, cursor) do
    {:ok, from_nif_tuple(cursor.db_ref, tuple, cursor.moment)}
  end

  defp handle_fetch_result({:ok, {:tagged, tag, payload}}, cursor)
       when tag in ["cz", "zs", "zd", "bp", "pg"] and is_binary(payload) do
    {:ok, Xitdb.Compression.resolve_tagged!(tag, payload, cursor.db_ref, cursor.moment)}
  end

  defp handle_fetch_result({:ok, scalar}, _cursor), do: {:ok, scalar}
  defp handle_fetch_result(:error, _cursor), do: :error
  defp handle_fetch_result({:error, reason}, _cursor), do: raise(Xitdb.Error, reason: reason)

  defp fetch_virtual_disk(cursor, child_steps) do
    child_sel = steps_to_selector(child_steps)

    {query_sel, resolve_sel} =
      case resolve_fork_alias(cursor.fork_aliases, steps_to_override_key(child_steps)) do
        {:ok, alias_sel} ->
          {:ok, parent_alias} =
            case resolve_fork_alias(cursor.fork_aliases, steps_to_override_key(cursor.path_steps)) do
              {:ok, p} -> {:ok, p}
              :none -> {:ok, steps_to_selector(cursor.path_steps)}
            end

          {alias_sel, parent_alias}

        :none ->
          {child_sel, steps_to_selector(cursor.path_steps)}
      end

    case NIF.nif_select(cursor.db_ref, cursor.moment, query_sel) do
      {:ok, nil} ->
        verify_virtual_parent_tag!(cursor, resolve_sel, child_steps)
        maybe_fetch_staged_descendant(cursor, child_steps)

      {:ok, raw} ->
        val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
        {:ok, inherit_staged(val, cursor)}

      {:error, reason} ->
        raise Xitdb.Error, reason: reason
    end
  end

  defp verify_virtual_parent_tag!(cursor, parent_sel, [{_kind, child_key} | _]) do
    case NIF.nif_select(cursor.db_ref, cursor.moment, parent_sel) do
      {:ok, nil} ->
        :ok

      {:ok, raw} ->
        case unwrap_nif_value(cursor.db_ref, raw, cursor.moment, cursor.path_steps) do
          %__MODULE__{} = resolved ->
            validate_access_key!(%{resolved | value: 0}, child_key)

            if resolved.tag in [:hash_set, :counted_hash_set, :sorted_set] do
              raise Xitdb.Error,
                reason: :unexpected_tag,
                details: %{tag: resolved.tag, key: child_key, selector: parent_sel}
            end

            :ok

          _scalar ->
            raise Xitdb.Error,
              reason: :unexpected_tag,
              details: %{key: child_key, selector: parent_sel}
        end

      {:error, reason} ->
        raise Xitdb.Error, reason: reason
    end
  end

  defp nif_slot_get(%__MODULE__{} = cursor, idx) when is_integer(idx) do
    %__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val} = ensure_resolved(cursor)
    NIF.nif_slot_get_index(db_ref, tag_id, val, idx)
  end

  defp nif_slot_get(%__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val}, key)
       when is_binary(key) do
    NIF.nif_slot_get_key(db_ref, tag_id, val, key)
  end

  defp pointer_container_tag?(tag) do
    tag in [
      :array_list,
      :linked_array_list,
      :hash_map,
      :counted_hash_map,
      :sorted_map,
      :hash_set,
      :counted_hash_set,
      :sorted_set
    ]
  end

  @doc false
  def tag_id_for(:none), do: 0
  def tag_id_for(:array_list), do: 2
  def tag_id_for(:linked_array_list), do: 3
  def tag_id_for(:hash_map), do: 4
  def tag_id_for(:hash_set), do: 11
  def tag_id_for(:counted_hash_map), do: 12
  def tag_id_for(:counted_hash_set), do: 13
  def tag_id_for(:sorted_map), do: 14
  def tag_id_for(:sorted_set), do: 15

  @doc false
  def tag_atom_for(0), do: :none
  def tag_atom_for(2), do: :array_list
  def tag_atom_for(3), do: :linked_array_list
  def tag_atom_for(4), do: :hash_map
  def tag_atom_for(11), do: :hash_set
  def tag_atom_for(12), do: :counted_hash_map
  def tag_atom_for(13), do: :counted_hash_set
  def tag_atom_for(14), do: :sorted_map
  def tag_atom_for(15), do: :sorted_set

  defp resolve_list_key(%__MODULE__{tag: tag} = cursor, idx)
       when tag in [:array_list, :linked_array_list] and is_integer(idx) and idx < 0 do
    case staged_or_nif_count(cursor) do
      {:ok, cnt} when cnt + idx >= 0 -> cnt + idx
      {:ok, _cnt} -> idx
      :uncounted -> idx
    end
  end

  defp resolve_list_key(_cursor, key), do: key

  defp staged_or_nif_count(%__MODULE__{} = cursor) do
    self_sel = steps_to_override_key(cursor.path_steps)

    base_res =
      cond do
        MapSet.member?(cursor.deleted_paths, self_sel) ->
          {:ok, 0}

        Map.has_key?(cursor.staged_overrides, self_sel) ->
          case unwrap_staged_collection(Map.fetch!(cursor.staged_overrides, self_sel)) do
            list when is_list(list) -> {:ok, length(list)}
            _ -> :uncounted
          end

        true ->
          case lookup_staged_ancestor(
                 cursor.staged_overrides,
                 cursor.deleted_paths,
                 cursor.path_steps
               ) do
            {:staged, val} ->
              case unwrap_staged_collection(val) do
                list when is_list(list) -> {:ok, length(list)}
                _ -> :uncounted
              end

            :deleted ->
              {:ok, 0}

            :miss ->
              case resolve_fork_alias(cursor.fork_aliases, self_sel) do
                {:ok, alias_sel} ->
                  case NIF.nif_select(cursor.db_ref, cursor.moment, alias_sel) do
                    {:ok, nil} ->
                      {:ok, 0}

                    {:ok, raw} ->
                      case unwrap_nif_value(cursor.db_ref, raw, cursor.moment, cursor.path_steps) do
                        %__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val} ->
                          case NIF.nif_slot_count(db_ref, tag_id, val) do
                            {:ok, cnt} -> {:ok, cnt}
                            {:error, :uncounted} -> :uncounted
                            {:error, reason} -> raise Xitdb.Error, reason: reason
                          end

                        _ ->
                          :uncounted
                      end

                    {:error, reason} ->
                      raise Xitdb.Error, reason: reason
                  end

                :none ->
                  if cursor.value == 0 and cursor.tag_id != -1 and
                       pointer_container_tag?(cursor.tag) do
                    {:ok, 0}
                  else
                    %__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val} =
                      ensure_resolved(cursor)

                    case NIF.nif_slot_count(db_ref, tag_id, val) do
                      {:ok, cnt} -> {:ok, cnt}
                      {:error, :uncounted} -> :uncounted
                      {:error, reason} -> raise Xitdb.Error, reason: reason
                    end
                  end
              end
          end
      end

    case base_res do
      {:ok, base_cnt} ->
        with_child_idx =
          if map_size(cursor.staged_overrides) == 0 do
            base_cnt
          else
            base_depth = length(cursor.path_steps)

            Enum.reduce(cursor.staged_overrides, base_cnt, fn {sel, _v}, acc ->
              if sel != self_sel and selector_prefix?(sel, self_sel) do
                case Enum.drop(parse_selector_steps_simple(sel), base_depth) do
                  [{_kind, idx}] when is_integer(idx) and idx >= acc -> idx + 1
                  [{_kind, idx} | _] when is_integer(idx) and idx >= acc -> idx + 1
                  _ -> acc
                end
              else
                acc
              end
            end)
          end

        final_cnt =
          case Map.fetch(cursor.staged_list_edits, self_sel) do
            {:ok, rev_edits} ->
              rev_edits
              |> Enum.reverse()
              |> Enum.reduce(with_child_idx, fn
                {:insert, _idx, _val}, c -> c + 1
                {:delete, _idx}, c when c > 0 -> c - 1
                {:delete, _idx}, c -> c
              end)

            :error ->
              with_child_idx
          end

        {:ok, final_cnt}

      :uncounted ->
        :uncounted
    end
  end

  defp lookup_staged(
         %__MODULE__{staged_overrides: overrides, deleted_paths: deleted} = cursor,
         child_steps
       ) do
    if map_size(overrides) == 0 and MapSet.size(deleted) == 0 do
      :miss
    else
      selector = steps_to_override_key(child_steps)

      cond do
        MapSet.member?(deleted, selector) ->
          :deleted

        Map.has_key?(overrides, selector) ->
          val = Map.fetch!(overrides, selector)
          {:staged, wrap_staged_val(cursor, child_steps, val)}

        true ->
          case lookup_staged_ancestor(overrides, deleted, child_steps) do
            {:staged, sub_val} ->
              {:staged, wrap_staged_val(cursor, child_steps, sub_val)}

            :deleted ->
              if not MapSet.member?(deleted, selector) and
                   not ancestor_deleted?(deleted, selector) do
                case staged_descendant_tag(overrides, selector, child_steps) do
                  {:ok, desc_tag} ->
                    {:staged, virtual_staged_cursor(cursor, child_steps, desc_tag)}

                  :none ->
                    :deleted
                end
              else
                :deleted
              end

            other ->
              other
          end
      end
    end
  end

  defp maybe_fetch_staged_descendant(
         %__MODULE__{staged_overrides: overrides} = cursor,
         child_steps
       ) do
    if map_size(overrides) == 0 do
      :error
    else
      selector = steps_to_override_key(child_steps)

      case staged_descendant_tag(overrides, selector, child_steps) do
        {:ok, desc_tag} -> {:ok, virtual_staged_cursor(cursor, child_steps, desc_tag)}
        :none -> :error
      end
    end
  end

  defp staged_descendant_tag(overrides, selector, child_steps) do
    depth = length(child_steps)

    Enum.find_value(overrides, :none, fn {k, _v} ->
      if k != selector and selector_prefix?(k, selector) do
        next_tag =
          k
          |> parse_selector_steps_simple()
          |> Enum.drop(depth)
          |> case do
            [{tag, _} | _] -> tag
            _ -> :hash_map
          end

        {:ok, next_tag}
      else
        nil
      end
    end)
  end

  defp ancestor_deleted?(deleted, selector) do
    Enum.any?(deleted, fn del_sel -> selector_prefix?(selector, del_sel) end)
  end

  defp lookup_staged_ancestor(overrides, deleted, child_steps) do
    forward = :lists.reverse(child_steps)
    total = length(forward)

    if total <= 1 do
      :miss
    else
      Enum.reduce_while((total - 1)..1//-1, :miss, fn prefix_len, _acc ->
        anc_forward = Enum.take(forward, prefix_len)

        anc_sel =
          Enum.map_join(anc_forward, "", fn {kind, k} ->
            Selector.format_step(canonical_override_kind(kind), k)
          end)

        cond do
          MapSet.member?(deleted, anc_sel) ->
            {:halt, :deleted}

          Map.has_key?(overrides, anc_sel) ->
            tail = Enum.drop(forward, prefix_len)

            case navigate_staged(Map.fetch!(overrides, anc_sel), tail) do
              {:ok, sub_val} -> {:halt, {:staged, sub_val}}
              :error -> {:halt, :deleted}
            end

          true ->
            {:cont, :miss}
        end
      end)
    end
  end

  defp navigate_staged(val, []), do: {:ok, val}

  defp navigate_staged(container, [{kind, step_key} | rest]) do
    case unwrap_staged_collection(container) do
      map
      when is_map(map) and not is_struct(map) and
             kind in [:hash_map, :counted_hash_map, :sorted_map] ->
        k_str = to_string(step_key)

        case find_map_entry(map, k_str) do
          {:ok, v} when not is_nil(v) -> navigate_staged(v, rest)
          _ -> :error
        end

      list
      when is_list(list) and kind in [:array_list, :linked_array_list] and
             is_integer(step_key) ->
        resolved = if step_key < 0, do: length(list) + step_key, else: step_key

        if resolved >= 0 and resolved < length(list) do
          navigate_staged(Enum.at(list, resolved), rest)
        else
          :error
        end

      %MapSet{} = set when kind in [:hash_set, :counted_hash_set, :sorted_set] and rest == [] ->
        if MapSet.member?(set, to_string(step_key)), do: {:ok, to_string(step_key)}, else: :error

      _ ->
        :error
    end
  end

  defp find_map_entry(map, target_str) do
    Enum.find_value(map, :error, fn {k, v} ->
      if to_string(k) == target_str, do: {:ok, v}, else: nil
    end)
  end

  defp unwrap_staged_collection(%Xitdb.Collection{kind: kind, data: data})
       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    Map.new(data, fn {k, v} -> {to_string(k), v} end)
  end

  defp unwrap_staged_collection(%Xitdb.Collection{kind: kind, data: list})
       when kind in [:array_list, :linked_array_list] and is_list(list) do
    list
  end

  defp unwrap_staged_collection(%Xitdb.Collection{kind: kind, data: members})
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    MapSet.new(members, &to_string/1)
  end

  defp unwrap_staged_collection(other), do: other

  defp wrap_staged_val(cursor, child_steps, %Xitdb.Collection{kind: kind}) do
    virtual_staged_cursor(cursor, child_steps, kind)
  end

  defp wrap_staged_val(cursor, child_steps, %MapSet{}) do
    virtual_staged_cursor(cursor, child_steps, :counted_hash_set)
  end

  defp wrap_staged_val(cursor, child_steps, map) when is_map(map) and not is_struct(map) do
    virtual_staged_cursor(cursor, child_steps, :hash_map)
  end

  defp wrap_staged_val(cursor, child_steps, list) when is_list(list) do
    virtual_staged_cursor(cursor, child_steps, :array_list)
  end

  defp wrap_staged_val(_cursor, _child_steps, {:compressed, bin}) when is_binary(bin), do: bin

  defp wrap_staged_val(_cursor, _child_steps, {:compressed, bin, _opts}) when is_binary(bin),
    do: bin

  defp wrap_staged_val(_cursor, _child_steps, scalar), do: scalar

  defp virtual_staged_cursor(cursor, child_steps, tag, value \\ 0) do
    %__MODULE__{
      db_ref: cursor.db_ref,
      tag: tag,
      tag_id: tag_id_for(tag),
      value: value,
      moment: cursor.moment,
      tx_mode: true,
      path_steps: child_steps,
      staged_ops: cursor.staged_ops,
      staged_overrides: cursor.staged_overrides,
      deleted_paths: cursor.deleted_paths,
      staged_list_edits: cursor.staged_list_edits,
      fork_aliases: cursor.fork_aliases
    }
  end

  @doc false
  def ensure_resolved(%__MODULE__{tag_id: -1, moment: moment} = cursor) do
    do_ensure_resolved(cursor, moment)
  end

  def ensure_resolved(%__MODULE__{value: -2, moment: moment} = cursor) do
    do_ensure_resolved(cursor, moment)
  end

  def ensure_resolved(cursor), do: cursor

  defp do_ensure_resolved(cursor, moment) do
    case try_resolve(cursor) do
      {:ok, resolved} -> resolved
      {:error, reason} -> raise Xitdb.Error, reason: reason, details: %{moment_index: moment}
    end
  end

  @doc false
  def try_resolve(%__MODULE__{tag_id: -1, db_ref: db_ref, moment: moment} = cursor) do
    case NIF.nif_moment_slot(db_ref, moment, true) do
      {:ok, {:cursor, tag_id, val}, resolved_moment} ->
        {:ok,
         %{
           cursor
           | tag: tag_atom_for(tag_id),
             tag_id: tag_id,
             value: val,
             moment: resolved_moment,
             full: false
         }}

      {:ok, {:cursor, tag_atom, tag_id, val, full_int}, resolved_moment} ->
        {:ok,
         %{
           cursor
           | tag: tag_atom,
             tag_id: tag_id,
             value: val,
             moment: resolved_moment,
             full: full_int != 0
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def try_resolve(
        %__MODULE__{value: -2, db_ref: db_ref, moment: moment, path_steps: path_steps} = cursor
      ) do
    case NIF.nif_select(db_ref, moment, steps_to_selector(path_steps)) do
      {:ok, {:cursor, tag_id, val}} ->
        {:ok,
         %__MODULE__{cursor | tag: tag_atom_for(tag_id), tag_id: tag_id, value: val, full: false}}

      {:ok, {:cursor, tag_atom, tag_id, val, full_int}} ->
        {:ok,
         %__MODULE__{cursor | tag: tag_atom, tag_id: tag_id, value: val, full: full_int != 0}}

      {:ok, nil} ->
        {:ok, %__MODULE__{cursor | value: 0}}

      {:ok, _scalar} ->
        {:error, :unexpected_tag}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def try_resolve(%__MODULE__{} = cursor), do: {:ok, cursor}

  @impl Access
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

  defp stage_rm_override(%__MODULE__{} = cursor, child_steps, get_val) do
    {selector, ov_key} = steps_to_selector_and_override_key(child_steps)

    updated_cursor = %__MODULE__{
      cursor
      | tx_mode: true,
        staged_ops: [{:rm_if_exists, selector} | cursor.staged_ops],
        staged_overrides: purge_prefix_from_map(cursor.staged_overrides, ov_key),
        deleted_paths:
          cursor.deleted_paths
          |> purge_prefix_from_set(ov_key)
          |> MapSet.put(ov_key),
        staged_list_edits: purge_prefix_from_map(cursor.staged_list_edits, ov_key),
        fork_aliases: purge_fork_aliases(cursor.fork_aliases, ov_key)
    }

    {get_val, updated_cursor}
  end

  defp fetch_or_nil(cursor, resolved_key) do
    case fetch(cursor, resolved_key) do
      {:ok, val} -> val
      :error -> nil
    end
  end

  defp invoke_with_current(%__MODULE__{} = cursor, child_steps, nil, fun) do
    try do
      fun.(nil)
    rescue
      e in ArgumentError ->
        if String.contains?(e.message, "nil value") do
          ov_key = steps_to_override_key(child_steps)

          vivified_base =
            if MapSet.member?(cursor.deleted_paths, ov_key) do
              %__MODULE__{
                cursor
                | staged_overrides: Map.put(cursor.staged_overrides, ov_key, %{}),
                  deleted_paths: MapSet.delete(cursor.deleted_paths, ov_key)
              }
            else
              cursor
            end

          vivified = virtual_staged_cursor(vivified_base, child_steps, :hash_map, 0)
          fun.(vivified)
        else
          reraise e, __STACKTRACE__
        end
    end
  end

  defp invoke_with_current(_cursor, _child_steps, current, fun), do: fun.(current)

  defp invoke_virtual_or_fallback(cursor, resolved_key, child_steps, virtual_child, fun) do
    result =
      try do
        fun.(virtual_child)
      rescue
        e in Xitdb.Error ->
          if is_map(e.details) and Map.get(e.details, :virtual_probe) == true do
            :__fallback__
          else
            reraise e, __STACKTRACE__
          end
      end

    case result do
      :pop ->
        :pop

      {get_val, %__MODULE__{path_steps: ^child_steps} = updated} ->
        if contains_virtual_cursor?(get_val) or
             contains_virtual_cursor?(updated.staged_overrides) do
          current = fetch_or_nil(cursor, resolved_key)

          case invoke_with_current(cursor, child_steps, current, fun) do
            :pop -> {:__xitdb_pop__, current}
            other -> other
          end
        else
          result
        end

      _ ->
        current = fetch_or_nil(cursor, resolved_key)

        case invoke_with_current(cursor, child_steps, current, fun) do
          :pop -> {:__xitdb_pop__, current}
          other -> other
        end
    end
  end

  defp classify_access_fun(fun) do
    {:module, mod} = :erlang.fun_info(fun, :module)

    if mod == :erl_eval do
      classify_erl_eval_access_fun(fun)
    else
      {:name, name} = :erlang.fun_info(fun, :name)

      case :persistent_term.get({__MODULE__, :fun_class, mod, name}, nil) do
        nil -> classify_and_cache_access_fun(mod, name, fun)
        :kernel_next_key -> classify_kernel_next_key_fun(fun)
        class -> class
      end
    end
  end

  defp classify_and_cache_access_fun(Kernel, name, fun) do
    name_str = Atom.to_string(name)

    class =
      cond do
        String.starts_with?(name_str, "-put_in/3-") -> :blind_write
        String.starts_with?(name_str, "-update_in/3-") -> :needs_current
        String.starts_with?(name_str, "-get_and_update_in/3-") -> :kernel_next_key
        String.starts_with?(name_str, "-pop_in_data/") -> :kernel_next_key
        true -> :needs_current
      end

    :persistent_term.put({__MODULE__, :fun_class, Kernel, name}, class)

    if class == :kernel_next_key do
      classify_kernel_next_key_fun(fun)
    else
      class
    end
  end

  defp classify_and_cache_access_fun(mod, name, fun) do
    if :erlang.fun_info(fun, :type) == {:type, :local} and
         String.starts_with?(Atom.to_string(name), "-") do
      fun_map = build_fun_map(mod)

      Enum.each(fun_map, fn {fname, fclass} ->
        :persistent_term.put({__MODULE__, :fun_class, mod, fname}, fclass)
      end)

      case Map.fetch(fun_map, name) do
        {:ok, class} ->
          class

        :error ->
          :persistent_term.put({__MODULE__, :fun_class, mod, name}, :needs_current)
          :needs_current
      end
    else
      :persistent_term.put({__MODULE__, :fun_class, mod, name}, :needs_current)
      :needs_current
    end
  end

  defp classify_kernel_next_key_fun(fun) do
    case :erlang.fun_info(fun, :env) do
      {:env, [_inner, [next_k | _]]}
      when is_binary(next_k) or is_atom(next_k) or is_integer(next_k) ->
        :traverse

      {:env, [[next_k | _]]}
      when is_binary(next_k) or is_atom(next_k) or is_integer(next_k) ->
        :traverse

      _ ->
        :needs_current
    end
  end

  defp classify_erl_eval_access_fun(fun) do
    with {:env, [env_tuple]} when is_tuple(env_tuple) and tuple_size(env_tuple) >= 1 <-
           :erlang.fun_info(fun, :env),
         clauses when is_list(clauses) <- elem(env_tuple, tuple_size(env_tuple) - 1) do
      classify_erl_eval_clauses(clauses)
    else
      _ -> :needs_current
    end
  end

  defp classify_erl_eval_clauses([{:clause, _, [{:var, _, :_}], [], _body}]), do: :blind_write

  defp classify_erl_eval_clauses([
         {:clause, _, [{:var, _, arg_var}], [],
          [
            {:call, _, {:remote, _, {:atom, _, Access}, {:atom, _, :get_and_update}},
             [{:var, _, arg_var}, key_ast, inner_fun]}
          ]}
       ])
       when is_atom(arg_var) do
    if erl_eval_uses_var?(key_ast, arg_var) or erl_eval_uses_var?(inner_fun, arg_var) do
      :needs_current
    else
      :traverse
    end
  end

  defp classify_erl_eval_clauses([
         {:clause, _, [{:var, _, arg_var}], [],
          [
            {:case, _, {:var, _, arg_var},
             [
               {:clause, _, [{:atom, _, nil}], [], [{:atom, _, :pop}]},
               {:clause, _, [{:var, _, h_var}], [],
                [
                  {:call, _, {:remote, _, {:atom, _, Access}, {:atom, _, :pop}},
                   [{:var, _, h_var}, key_ast]}
                ]}
             ]}
          ]}
       ])
       when is_atom(arg_var) and is_atom(h_var) do
    if erl_eval_uses_var?(key_ast, arg_var) or erl_eval_uses_var?(key_ast, h_var) do
      :needs_current
    else
      :traverse
    end
  end

  defp classify_erl_eval_clauses([{:clause, _, [{:var, _, arg_var}], [], body}])
       when is_atom(arg_var) do
    if erl_eval_uses_var?(body, arg_var), do: :needs_current, else: :blind_write
  end

  defp classify_erl_eval_clauses(_clauses), do: :needs_current

  defp erl_eval_uses_var?({:var, _line, name}, target), do: name == target

  defp erl_eval_uses_var?({:clause, _line, head_patterns, guards, body}, target) do
    if erl_eval_uses_var?(head_patterns, target) do
      false
    else
      erl_eval_uses_var?(guards, target) or erl_eval_uses_var?(body, target)
    end
  end

  defp erl_eval_uses_var?(tuple, target) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&erl_eval_uses_var?(&1, target))
  end

  defp erl_eval_uses_var?(list, target) when is_list(list) do
    Enum.any?(list, &erl_eval_uses_var?(&1, target))
  end

  defp erl_eval_uses_var?(_other, _target), do: false

  @doc false
  def disassemble_fun_map(bin) when is_binary(bin) do
    {:beam_file, _, _, _, _, funcs} = :beam_disasm.file(bin)

    for {:function, fname, _arity, _entry, instrs} <- funcs,
        String.starts_with?(Atom.to_string(fname), "-"),
        into: %{} do
      {fname, classify_fun_instrs(instrs)}
    end
  end

  defp build_fun_map(mod) do
    case :persistent_term.get({__MODULE__, :fun_map, mod}, nil) do
      %{} = cached ->
        cached

      nil ->
        bin =
          case :persistent_term.get({__MODULE__, :bytecode, mod}, nil) do
            b when is_binary(b) ->
              :persistent_term.erase({__MODULE__, :bytecode, mod})
              b

            nil ->
              case :code.get_object_code(mod) do
                {^mod, b, _} when is_binary(b) -> b
                _ -> nil
              end
          end

        if is_binary(bin) do
          fun_map = disassemble_fun_map(bin)
          :persistent_term.put({__MODULE__, :fun_map, mod}, fun_map)
          fun_map
        else
          %{}
        end
    end
  end

  defp classify_fun_instrs(instrs) do
    after_entry =
      instrs
      |> Enum.drop_while(&(not match?({:func_info, _, _, _}, &1)))
      |> Enum.drop(1)

    cond do
      intermediate_get_and_update?(after_entry) -> :traverse
      intermediate_pop?(after_entry) -> :traverse
      not x0_read_before_kill?(after_entry) -> :blind_write
      true -> :needs_current
    end
  end

  defp intermediate_get_and_update?(instrs) do
    Enum.any?(instrs, &match?({:call_ext_only, 3, {:extfunc, Access, :get_and_update, 3}}, &1)) and
      Enum.all?(instrs, fn
        {:label, _} -> true
        {:line, _} -> true
        {:test_heap, _, _} -> true
        {:make_fun3, _, _, _, {:x, 2}, {:list, env}} -> not uses_x0?(env)
        {:move, src, dst} when dst in [{:x, 1}, {:x, 2}] -> not uses_x0?(src)
        {:bs_create_bin, {:f, 0}, _, _, _, {:x, 1}, {:list, segs}} -> not uses_x0?(segs)
        {:call_ext_only, 3, {:extfunc, Access, :get_and_update, 3}} -> true
        _ -> false
      end)
  end

  defp intermediate_pop?(instrs) do
    no_lines =
      instrs
      |> Enum.reject(&match?({:line, _}, &1))
      |> Enum.drop_while(&match?({:label, _}, &1))

    case no_lines do
      [
        {:test, :is_eq_exact, {:f, fail_lbl}, [x: 0, atom: nil]},
        {:move, {:atom, :pop}, {:x, 0}},
        :return,
        {:label, fail_lbl} | tail
      ] ->
        valid_pop_tail?(tail)

      _ ->
        false
    end
  end

  defp valid_pop_tail?([{:call_ext_only, 2, {:extfunc, Access, :pop, 2}}]), do: true

  defp valid_pop_tail?([{:label, _} | rest]), do: valid_pop_tail?(rest)
  defp valid_pop_tail?([{:test_heap, _, _} | rest]), do: valid_pop_tail?(rest)

  defp valid_pop_tail?([{:move, src, {:x, 1}} | rest]) do
    not uses_x0?(src) and valid_pop_tail?(rest)
  end

  defp valid_pop_tail?([{:bs_create_bin, {:f, 0}, _, _, _, {:x, 1}, {:list, segs}} | rest]) do
    not uses_x0?(segs) and valid_pop_tail?(rest)
  end

  defp valid_pop_tail?(_other), do: false

  defp x0_read_before_kill?(instrs) do
    labels = build_label_map(instrs, [])
    check_stream(instrs, labels, MapSet.new())
  end

  defp build_label_map([], acc), do: Map.new(acc)

  defp build_label_map([{:label, lbl} | rest], acc) do
    build_label_map(rest, [{lbl, rest} | acc])
  end

  defp build_label_map([_ | rest], acc), do: build_label_map(rest, acc)

  defp check_stream([], _labels, _visited), do: false

  defp check_stream([instr | rest], labels, visited) do
    case instr do
      {:label, lbl} ->
        if MapSet.member?(visited, lbl) do
          false
        else
          check_stream(rest, labels, MapSet.put(visited, lbl))
        end

      {:line, _} ->
        check_stream(rest, labels, visited)

      {:allocate, _, 0} ->
        false

      {:allocate_heap, _, _, 0} ->
        false

      {:test_heap, _, 0} ->
        false

      {:allocate, _, _} ->
        check_stream(rest, labels, visited)

      {:allocate_heap, _, _, _} ->
        check_stream(rest, labels, visited)

      {:test_heap, _, _} ->
        check_stream(rest, labels, visited)

      {:init_yregs, _} ->
        check_stream(rest, labels, visited)

      {:move, src, dst} ->
        cond do
          uses_x0?(src) -> true
          dst == {:x, 0} -> false
          true -> check_stream(rest, labels, visited)
        end

      {:put_tuple2, dst, {:list, elems}} ->
        cond do
          uses_x0?(elems) -> true
          dst == {:x, 0} -> false
          true -> check_stream(rest, labels, visited)
        end

      {:put_list, hd_src, tl_src, dst} ->
        cond do
          uses_x0?(hd_src) or uses_x0?(tl_src) -> true
          dst == {:x, 0} -> false
          true -> check_stream(rest, labels, visited)
        end

      {:put_map_assoc, {:f, fail}, map_src, dst, _live, {:list, pairs}} ->
        check_map_write_op(fail, map_src, pairs, dst, rest, labels, visited)

      {:put_map_exact, {:f, fail}, map_src, dst, _live, {:list, pairs}} ->
        check_map_write_op(fail, map_src, pairs, dst, rest, labels, visited)

      {:get_map_elements, {:f, fail}, map_src, {:list, pairs}} ->
        if uses_x0?(map_src) or map_get_reads_x0?(pairs) do
          true
        else
          check_label(fail, labels, visited) or
            (not map_get_writes_x0?(pairs) and check_stream(rest, labels, visited))
        end

      {:get_tuple_element, src, _idx, dst} ->
        cond do
          uses_x0?(src) -> true
          dst == {:x, 0} -> false
          true -> check_stream(rest, labels, visited)
        end

      {:get_hd, src, dst} ->
        cond do
          uses_x0?(src) -> true
          dst == {:x, 0} -> false
          true -> check_stream(rest, labels, visited)
        end

      {:get_tl, src, dst} ->
        cond do
          uses_x0?(src) -> true
          dst == {:x, 0} -> false
          true -> check_stream(rest, labels, visited)
        end

      {:bs_create_bin, {:f, fail}, _alloc, _live, _unit, dst, {:list, segs}} ->
        if uses_x0?(segs) do
          true
        else
          check_label(fail, labels, visited) or
            (dst != {:x, 0} and check_stream(rest, labels, visited))
        end

      {:bif, _op, :nofail, args, dst} ->
        cond do
          uses_x0?(args) -> true
          dst == {:x, 0} -> false
          true -> check_stream(rest, labels, visited)
        end

      {:bif, _op, {:f, fail}, args, dst} ->
        if uses_x0?(args) do
          true
        else
          check_label(fail, labels, visited) or
            (dst != {:x, 0} and check_stream(rest, labels, visited))
        end

      {:gc_bif, _op, {:f, fail}, _live, args, dst} ->
        if uses_x0?(args) do
          true
        else
          check_label(fail, labels, visited) or
            (dst != {:x, 0} and check_stream(rest, labels, visited))
        end

      {:make_fun3, _, _, _, dst, {:list, env}} ->
        cond do
          uses_x0?(env) -> true
          dst == {:x, 0} -> false
          true -> check_stream(rest, labels, visited)
        end

      {:test, _op, {:f, fail}, args} ->
        if uses_x0?(args) do
          true
        else
          check_label(fail, labels, visited) or check_stream(rest, labels, visited)
        end

      {:test, _op, {:f, fail}, _live, args, dst} ->
        if uses_x0?(args) do
          true
        else
          check_label(fail, labels, visited) or
            (dst != {:x, 0} and check_stream(rest, labels, visited))
        end

      {:select_val, src, {:f, fail}, {:list, pairs}} ->
        if uses_x0?(src) do
          true
        else
          check_label(fail, labels, visited) or check_select_pairs(pairs, labels, visited)
        end

      {:select_tuple_arity, src, {:f, fail}, {:list, pairs}} ->
        if uses_x0?(src) do
          true
        else
          check_label(fail, labels, visited) or check_select_pairs(pairs, labels, visited)
        end

      {:jump, {:f, lbl}} ->
        check_label(lbl, labels, visited)

      {:call, arity, _} ->
        arity > 0

      {:call_only, arity, _} ->
        arity > 0

      {:call_last, arity, _, _} ->
        arity > 0

      {:call_ext, arity, _} ->
        arity > 0

      {:call_ext_only, arity, _} ->
        arity > 0

      {:call_ext_last, arity, _, _} ->
        arity > 0

      :return ->
        true

      _ ->
        true
    end
  end

  defp check_map_write_op(fail, map_src, pairs, dst, rest, labels, visited) do
    if uses_x0?(map_src) or uses_x0?(pairs) do
      true
    else
      check_label(fail, labels, visited) or
        (dst != {:x, 0} and check_stream(rest, labels, visited))
    end
  end

  defp check_select_pairs([], _labels, _visited), do: false

  defp check_select_pairs([_val, {:f, lbl} | rest], labels, visited) do
    check_label(lbl, labels, visited) or check_select_pairs(rest, labels, visited)
  end

  defp check_select_pairs(_other, _labels, _visited), do: true

  defp map_get_reads_x0?([]), do: false
  defp map_get_reads_x0?([k, _dst | rest]), do: uses_x0?(k) or map_get_reads_x0?(rest)
  defp map_get_reads_x0?(_), do: true

  defp map_get_writes_x0?([]), do: false
  defp map_get_writes_x0?([_k, {:x, 0} | _rest]), do: true
  defp map_get_writes_x0?([_k, _dst | rest]), do: map_get_writes_x0?(rest)
  defp map_get_writes_x0?(_), do: false

  defp check_label(0, _labels, _visited), do: false

  defp check_label(lbl, labels, visited) do
    if MapSet.member?(visited, lbl) do
      false
    else
      case Map.fetch(labels, lbl) do
        {:ok, stream} -> check_stream(stream, labels, MapSet.put(visited, lbl))
        :error -> true
      end
    end
  end

  defp uses_x0?({:x, 0}), do: true
  defp uses_x0?({:tr, {:x, 0}, _}), do: true
  defp uses_x0?(list) when is_list(list), do: Enum.any?(list, &uses_x0?/1)

  defp uses_x0?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&uses_x0?/1)
  end

  defp uses_x0?(_), do: false

  defp contains_virtual_cursor?(term)
       when is_nil(term) or is_binary(term) or is_number(term) or is_boolean(term) or
              is_atom(term),
       do: false

  defp contains_virtual_cursor?(%__MODULE__{value: -2}), do: true
  defp contains_virtual_cursor?(%__MODULE__{}), do: false

  defp contains_virtual_cursor?(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.any?(fn {_k, v} -> contains_virtual_cursor?(v) end)
  end

  defp contains_virtual_cursor?([h | t]) do
    contains_virtual_cursor?(h) or contains_virtual_cursor?(t)
  end

  defp contains_virtual_cursor?(map) when is_map(map) do
    Enum.any?(map, fn {k, v} -> contains_virtual_cursor?(k) or contains_virtual_cursor?(v) end)
  end

  defp contains_virtual_cursor?(tuple) when is_tuple(tuple) do
    tuple_contains_virtual_cursor?(tuple, tuple_size(tuple))
  end

  defp contains_virtual_cursor?(_term), do: false

  defp tuple_contains_virtual_cursor?(_tuple, 0), do: false

  defp tuple_contains_virtual_cursor?(tuple, idx) do
    contains_virtual_cursor?(:erlang.element(idx, tuple)) or
      tuple_contains_virtual_cursor?(tuple, idx - 1)
  end

  @impl Access
  def pop(%__MODULE__{} = raw_cursor, raw_key) do
    key = if is_atom(raw_key), do: Atom.to_string(raw_key), else: raw_key
    %__MODULE__{} = cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
    validate_access_key!(cursor, key)
    resolved_key = resolve_list_key(cursor, key)

    current =
      case fetch(cursor, resolved_key) do
        {:ok, val} -> val
        :error -> nil
      end

    do_pop(cursor, resolved_key, current)
  end

  defp do_pop(%__MODULE__{} = cursor, resolved_key, current) do
    child_key = if is_integer(resolved_key), do: resolved_key, else: to_string(resolved_key)
    child_steps = [{cursor.tag, child_key} | cursor.path_steps]
    {selector, ov_key} = steps_to_selector_and_override_key(child_steps)
    {parent_sel, parent_ov_key} = steps_to_selector_and_override_key(cursor.path_steps)

    cond do
      cursor.tag == :array_list ->
        cnt =
          case staged_or_nif_count(cursor) do
            {:ok, n} -> n
            :uncounted -> 0
          end

        cond do
          not is_integer(resolved_key) or resolved_key < 0 or resolved_key >= cnt ->
            {nil, cursor}

          resolved_key == cnt - 1 ->
            staged_list = materialize_current_list(cursor, cnt)
            sliced_list = Enum.take(staged_list, cnt - 1)

            updated_cursor = %__MODULE__{
              cursor
              | tx_mode: true,
                staged_ops: [{:slice, parent_sel, 0, cnt - 1} | cursor.staged_ops],
                staged_overrides:
                  cursor.staged_overrides
                  |> purge_prefix_from_map(parent_ov_key)
                  |> Map.put(parent_ov_key, sliced_list),
                deleted_paths: purge_prefix_from_set(cursor.deleted_paths, parent_ov_key),
                staged_list_edits: purge_prefix_from_map(cursor.staged_list_edits, parent_ov_key),
                fork_aliases: purge_fork_aliases(cursor.fork_aliases, parent_ov_key)
            }

            {current, updated_cursor}

          true ->
            raise ArgumentError,
                  "cannot pop middle index #{resolved_key} from :array_list (#{inspect(parent_sel)}); :array_list only supports tail popping — use Xitdb.linked_list/1 for O(log N) arbitrary index removal"
        end

      cursor.tag == :linked_array_list ->
        cnt =
          case staged_or_nif_count(cursor) do
            {:ok, n} -> n
            :uncounted -> 0
          end

        if is_integer(resolved_key) and resolved_key >= 0 and resolved_key < cnt do
          staged_list = materialize_current_list(cursor, cnt)
          shifted_list = List.delete_at(staged_list, resolved_key)

          updated_cursor = %__MODULE__{
            cursor
            | tx_mode: true,
              staged_ops: [{:rm, selector} | cursor.staged_ops],
              staged_overrides:
                cursor.staged_overrides
                |> purge_prefix_from_map(parent_ov_key)
                |> Map.put(parent_ov_key, %Xitdb.Collection{
                  kind: :linked_array_list,
                  data: shifted_list
                }),
              deleted_paths: purge_prefix_from_set(cursor.deleted_paths, parent_ov_key),
              staged_list_edits: purge_prefix_from_map(cursor.staged_list_edits, parent_ov_key),
              fork_aliases: purge_fork_aliases(cursor.fork_aliases, parent_ov_key)
          }

          {current, updated_cursor}
        else
          {nil, cursor}
        end

      true ->
        updated_cursor = %__MODULE__{
          cursor
          | tx_mode: true,
            staged_ops: [{:rm_if_exists, selector} | cursor.staged_ops],
            staged_overrides: purge_prefix_from_map(cursor.staged_overrides, ov_key),
            deleted_paths:
              cursor.deleted_paths
              |> purge_prefix_from_set(ov_key)
              |> MapSet.put(ov_key),
            staged_list_edits: purge_prefix_from_map(cursor.staged_list_edits, ov_key),
            fork_aliases: purge_fork_aliases(cursor.fork_aliases, ov_key)
        }

        {current, updated_cursor}
    end
  end

  defp materialize_current_list(cursor, cnt) do
    for idx <- 0..(cnt - 1)//1 do
      case fetch(%{cursor | tx_mode: true}, idx) do
        {:ok, %__MODULE__{} = child_cur} -> materialize_preserving_collections(child_cur)
        {:ok, val} -> val
        :error -> nil
      end
    end
  end

  defp materialize_preserving_collections(%__MODULE__{} = cur) do
    has_staged =
      cur.tx_mode and
        (map_size(cur.staged_overrides) > 0 or MapSet.size(cur.deleted_paths) > 0 or
           map_size(cur.staged_list_edits) > 0 or cur.fork_aliases != [])

    if has_staged do
      val = Xitdb.materialize(cur)
      wrap_collection_if_needed(cur.tag, val)
    else
      case cur.tag do
        kind when kind in [:hash_map, :counted_hash_map, :sorted_map] ->
          data =
            cur
            |> Enum.map(fn
              {k, %__MODULE__{} = v} -> {k, materialize_preserving_collections(v)}
              {k, v} -> {k, v}
            end)
            |> Map.new()

          wrap_collection_if_needed(kind, data)

        kind when kind in [:array_list, :linked_array_list] ->
          data =
            Enum.map(cur, fn
              %__MODULE__{} = v -> materialize_preserving_collections(v)
              v -> v
            end)

          wrap_collection_if_needed(kind, data)

        kind when kind in [:hash_set, :counted_hash_set, :sorted_set] ->
          %Xitdb.Collection{kind: kind, data: Enum.to_list(cur)}

        _ ->
          Xitdb.materialize(cur)
      end
    end
  end

  defp wrap_collection_if_needed(:hash_map, data), do: data
  defp wrap_collection_if_needed(:array_list, data), do: data

  defp wrap_collection_if_needed(kind, data)
       when kind in [
              :counted_hash_map,
              :sorted_map,
              :linked_array_list,
              :hash_set,
              :counted_hash_set,
              :sorted_set
            ] do
    %Xitdb.Collection{kind: kind, data: data}
  end

  defp wrap_collection_if_needed(_kind, data), do: data

  @doc false
  def purge_staged_prefix(%__MODULE__{} = cursor, selector)
      when is_binary(selector) or is_list(selector) do
    if map_size(cursor.staged_overrides) == 0 and MapSet.size(cursor.deleted_paths) == 0 and
         map_size(cursor.staged_list_edits) == 0 and cursor.fork_aliases == [] do
      cursor
    else
      formatted = canonical_override_selector(selector)

      %__MODULE__{
        cursor
        | staged_overrides: purge_prefix_from_map(cursor.staged_overrides, formatted),
          deleted_paths: purge_prefix_from_set(cursor.deleted_paths, formatted),
          staged_list_edits: purge_prefix_from_map(cursor.staged_list_edits, formatted),
          fork_aliases: purge_fork_aliases(cursor.fork_aliases, formatted)
      }
    end
  end

  @doc false
  def stage_list_insert(%__MODULE__{} = cursor, selector, index, value)
      when (is_binary(selector) or is_list(selector)) and is_integer(index) do
    stage_list_edit(cursor, selector, {:insert, index, value})
  end

  @doc false
  def stage_list_delete(%__MODULE__{} = cursor, selector, index)
      when (is_binary(selector) or is_list(selector)) and is_integer(index) do
    stage_list_edit(cursor, selector, {:delete, index})
  end

  defp stage_list_edit(%__MODULE__{} = cursor, selector, edit) do
    ov_key = canonical_override_selector(selector)

    cond do
      Map.has_key?(cursor.staged_overrides, ov_key) ->
        existing = Map.fetch!(cursor.staged_overrides, ov_key)
        updated = apply_single_list_edit_to_staged(existing, edit)

        %__MODULE__{
          cursor
          | staged_overrides: Map.put(cursor.staged_overrides, ov_key, updated),
            deleted_paths: MapSet.delete(cursor.deleted_paths, ov_key)
        }

      has_descendant_keys?(cursor.staged_overrides, ov_key) or
        has_descendant_set?(cursor.deleted_paths, ov_key) or
        has_descendant_keys?(cursor.staged_list_edits, ov_key) or
          has_descendant_aliases?(cursor.fork_aliases, ov_key) ->
        rev_steps = ov_key |> parse_selector_steps_simple() |> :lists.reverse()

        {resolved_tag, resolved_tag_id, resolved_val, resolved_full} =
          case NIF.nif_select(cursor.db_ref, cursor.moment, ov_key) do
            {:ok, raw} when not is_nil(raw) ->
              case unwrap_nif_value(cursor.db_ref, raw, cursor.moment, rev_steps) do
                %__MODULE__{tag: t, tag_id: tid, value: v, full: f} -> {t, tid, v, f}
                _ -> {:linked_array_list, 3, 0, false}
              end

            _ ->
              {:linked_array_list, 3, 0, false}
          end

        target_cur = %__MODULE__{
          cursor
          | tx_mode: true,
            path_steps: rev_steps,
            tag: resolved_tag,
            tag_id: resolved_tag_id,
            value: resolved_val,
            full: resolved_full
        }

        cnt =
          case staged_or_nif_count(target_cur) do
            {:ok, n} -> n
            :uncounted -> 0
          end

        base_list = materialize_current_list(target_cur, cnt)
        updated_list = apply_single_list_edit(base_list, edit)

        %__MODULE__{
          cursor
          | staged_overrides:
              cursor.staged_overrides
              |> purge_prefix_from_map(ov_key)
              |> Map.put(ov_key, %Xitdb.Collection{kind: :linked_array_list, data: updated_list}),
            deleted_paths: purge_prefix_from_set(cursor.deleted_paths, ov_key),
            staged_list_edits: purge_prefix_from_map(cursor.staged_list_edits, ov_key),
            fork_aliases: purge_strict_descendant_aliases(cursor.fork_aliases, ov_key)
        }

      true ->
        cleared_list_edits =
          cursor.staged_list_edits
          |> purge_strict_descendant_map(ov_key)
          |> Map.update(ov_key, [edit], &[edit | &1])

        %__MODULE__{
          cursor
          | deleted_paths: MapSet.delete(cursor.deleted_paths, ov_key),
            staged_list_edits: cleared_list_edits,
            fork_aliases: purge_strict_descendant_aliases(cursor.fork_aliases, ov_key)
        }
    end
  end

  defp apply_single_list_edit_to_staged(%Xitdb.Collection{kind: kind, data: list} = col, edit)
       when is_list(list) do
    %Xitdb.Collection{col | kind: kind, data: apply_single_list_edit(list, edit)}
  end

  defp apply_single_list_edit_to_staged(list, edit) when is_list(list) do
    apply_single_list_edit(list, edit)
  end

  defp apply_single_list_edit_to_staged(_other, {:insert, _idx, val}), do: [val]
  defp apply_single_list_edit_to_staged(_other, {:delete, _idx}), do: []

  defp apply_single_list_edit(list, {:insert, idx, val}) do
    if idx >= 0 and idx <= length(list), do: List.insert_at(list, idx, val), else: list
  end

  defp apply_single_list_edit(list, {:delete, idx}) do
    if idx >= 0 and idx < length(list), do: List.delete_at(list, idx), else: list
  end

  defp has_descendant_keys?(map, prefix) do
    Enum.any?(map, fn {k, _v} -> k != prefix and selector_prefix?(k, prefix) end)
  end

  defp has_descendant_set?(set, prefix) do
    Enum.any?(set, fn k -> k != prefix and selector_prefix?(k, prefix) end)
  end

  defp has_descendant_aliases?(aliases, prefix) do
    Enum.any?(aliases, fn {to_k, _from_k} -> to_k != prefix and selector_prefix?(to_k, prefix) end)
  end

  defp purge_strict_descendant_map(map, _prefix) when map_size(map) == 0, do: map

  defp purge_strict_descendant_map(map, prefix) do
    :maps.filter(fn k, _v -> k == prefix or not selector_prefix?(k, prefix) end, map)
  end

  defp purge_strict_descendant_aliases([], _prefix), do: []

  defp purge_strict_descendant_aliases(aliases, prefix) do
    Enum.reject(aliases, fn {to_k, _from_k} ->
      to_k != prefix and selector_prefix?(to_k, prefix)
    end)
  end

  @doc false
  def fork_staged_prefix(%__MODULE__{} = cursor, from_selector, to_selector)
      when (is_binary(from_selector) or is_list(from_selector)) and
             (is_binary(to_selector) or is_list(to_selector)) do
    from_ov = canonical_override_selector(from_selector)
    to_ov = canonical_override_selector(to_selector)

    eff_from_ov =
      case resolve_fork_alias(cursor.fork_aliases, from_ov) do
        {:ok, resolved} -> resolved
        :none -> from_ov
      end

    copied_nested_aliases =
      cursor.fork_aliases
      |> Enum.filter(fn {sub_to, _sub_from} ->
        sub_to != from_ov and selector_prefix?(sub_to, from_ov)
      end)
      |> Enum.uniq_by(fn {sub_to, _sub_from} -> sub_to end)
      |> Enum.map(fn {sub_to, sub_from} ->
        suffix = binary_part(sub_to, byte_size(from_ov), byte_size(sub_to) - byte_size(from_ov))

        resolved_sub_from =
          case resolve_fork_alias(cursor.fork_aliases, sub_to) do
            {:ok, resolved} -> resolved
            :none -> sub_from
          end

        {to_ov <> suffix, resolved_sub_from}
      end)

    cleared_overrides = purge_prefix_from_map(cursor.staged_overrides, to_ov)
    cleared_deleted = purge_prefix_from_set(cursor.deleted_paths, to_ov)
    cleared_list_edits = purge_prefix_from_map(cursor.staged_list_edits, to_ov)

    cleared_aliases =
      cursor.fork_aliases
      |> purge_fork_aliases(to_ov)
      |> Enum.map(fn {other_to, other_from} ->
        if selector_prefix?(other_from, to_ov) do
          case resolve_fork_alias(cursor.fork_aliases, other_from) do
            {:ok, resolved} -> {other_to, resolved}
            :none -> {other_to, other_from}
          end
        else
          {other_to, other_from}
        end
      end)

    copied_overrides =
      Enum.reduce(cursor.staged_overrides, cleared_overrides, fn {k, v}, acc ->
        if selector_prefix?(k, from_ov) do
          suffix = binary_part(k, byte_size(from_ov), byte_size(k) - byte_size(from_ov))
          Map.put(acc, to_ov <> suffix, v)
        else
          acc
        end
      end)

    copied_deleted =
      Enum.reduce(cursor.deleted_paths, cleared_deleted, fn k, acc ->
        if selector_prefix?(k, from_ov) do
          suffix = binary_part(k, byte_size(from_ov), byte_size(k) - byte_size(from_ov))
          MapSet.put(acc, to_ov <> suffix)
        else
          acc
        end
      end)

    copied_list_edits =
      Enum.reduce(cursor.staged_list_edits, cleared_list_edits, fn {k, v}, acc ->
        if selector_prefix?(k, from_ov) do
          suffix = binary_part(k, byte_size(from_ov), byte_size(k) - byte_size(from_ov))
          Map.put(acc, to_ov <> suffix, v)
        else
          acc
        end
      end)

    %__MODULE__{
      cursor
      | staged_overrides: copied_overrides,
        deleted_paths: copied_deleted,
        staged_list_edits: copied_list_edits,
        fork_aliases: copied_nested_aliases ++ [{to_ov, eff_from_ov} | cleared_aliases]
    }
  end

  @doc false
  def resolve_fork_disk_base(%__MODULE__{fork_aliases: []}), do: nil

  def resolve_fork_disk_base(%__MODULE__{} = cursor) do
    self_sel = steps_to_override_key(cursor.path_steps)

    case resolve_fork_alias(cursor.fork_aliases, self_sel) do
      {:ok, alias_sel} ->
        case NIF.nif_select(cursor.db_ref, cursor.moment, alias_sel) do
          {:ok, nil} ->
            nil

          {:ok, raw} ->
            case unwrap_nif_value(cursor.db_ref, raw, cursor.moment, []) do
              %__MODULE__{} = aliased_cur -> Xitdb.materialize(aliased_cur)
              scalar -> scalar
            end

          {:error, reason} ->
            raise Xitdb.Error, reason: reason
        end

      :none ->
        nil
    end
  end

  defp resolve_fork_alias([], _sel), do: :none

  defp resolve_fork_alias([{to_ov, from_ov} | rest], sel) do
    if selector_prefix?(sel, to_ov) do
      suffix = binary_part(sel, byte_size(to_ov), byte_size(sel) - byte_size(to_ov))
      mapped = from_ov <> suffix

      case resolve_fork_alias(rest, mapped) do
        {:ok, deeper} -> {:ok, deeper}
        :none -> {:ok, mapped}
      end
    else
      resolve_fork_alias(rest, sel)
    end
  end

  defp purge_fork_aliases([], _prefix), do: []
  defp purge_fork_aliases(_aliases, ""), do: []

  defp purge_fork_aliases(aliases, prefix) do
    Enum.reject(aliases, fn {to_ov, _from_ov} -> selector_prefix?(to_ov, prefix) end)
  end

  @doc false
  def apply_staged_overlay(%__MODULE__{tx_mode: false}, base), do: base

  def apply_staged_overlay(%__MODULE__{} = cursor, base) do
    if map_size(cursor.staged_overrides) == 0 and MapSet.size(cursor.deleted_paths) == 0 and
         map_size(cursor.staged_list_edits) == 0 and cursor.fork_aliases == [] do
      base
    else
      base_sel = steps_to_override_key(cursor.path_steps)
      base_fwd = :lists.reverse(cursor.path_steps)

      seeded_base =
        if cursor.path_steps == [] do
          base
        else
          case lookup_staged_ancestor(
                 cursor.staged_overrides,
                 cursor.deleted_paths,
                 cursor.path_steps
               ) do
            {:staged, sub_val} -> materialize_staged_val(sub_val)
            :deleted -> nil
            :miss -> base
          end
        end

      with_forks =
        if cursor.fork_aliases == [] do
          seeded_base
        else
          cursor.fork_aliases
          |> Enum.reverse()
          |> Enum.reduce(seeded_base, fn {to_ov, _from_ov}, acc ->
            if to_ov != base_sel and selector_prefix?(to_ov, base_sel) and
                 not Map.has_key?(cursor.staged_overrides, to_ov) and
                 not MapSet.member?(cursor.deleted_paths, to_ov) do
              case resolve_fork_alias(cursor.fork_aliases, to_ov) do
                {:ok, alias_sel} ->
                  fork_val =
                    case NIF.nif_select(cursor.db_ref, cursor.moment, alias_sel) do
                      {:ok, nil} ->
                        nil

                      {:ok, raw} ->
                        case unwrap_nif_value(cursor.db_ref, raw, cursor.moment, []) do
                          %__MODULE__{} = ac -> Xitdb.materialize(ac)
                          scalar -> scalar
                        end

                      {:error, reason} ->
                        raise Xitdb.Error, reason: reason
                    end

                  rel_steps = Enum.drop(parse_selector_steps_simple(to_ov), length(base_fwd))
                  put_overlay_steps(acc, rel_steps, fork_val)

                :none ->
                  acc
              end
            else
              acc
            end
          end)
        end

      matching_overrides =
        cursor.staged_overrides
        |> Enum.filter(fn {sel, _} -> selector_prefix?(sel, base_sel) end)
        |> Enum.map(fn {sel, v} ->
          rel_steps = Enum.drop(parse_selector_steps_simple(sel), length(base_fwd))
          {sel, rel_steps, materialize_staged_val(v)}
        end)
        |> Enum.sort_by(fn {_sel, rel_steps, _} -> length(rel_steps) end)

      {list_descendant_overrides, pre_list_overrides} =
        if map_size(cursor.staged_list_edits) == 0 do
          {[], matching_overrides}
        else
          Enum.split_with(matching_overrides, fn {sel, _rel_steps, _val} ->
            Enum.any?(cursor.staged_list_edits, fn {list_sel, _} ->
              sel != list_sel and selector_prefix?(sel, list_sel)
            end)
          end)
        end

      with_pre_overrides =
        Enum.reduce(pre_list_overrides, with_forks, fn {_sel, rel_steps, val}, acc ->
          put_overlay_steps(acc, rel_steps, val)
        end)

      with_list_edits =
        apply_staged_list_edits_overlay(cursor, with_pre_overrides, base_sel, base_fwd)

      with_overrides =
        Enum.reduce(list_descendant_overrides, with_list_edits, fn {_sel, rel_steps, val}, acc ->
          put_overlay_steps(acc, rel_steps, val)
        end)

      matching_deletes =
        cursor.deleted_paths
        |> Enum.filter(&selector_prefix?(&1, base_sel))
        |> Enum.map(fn sel -> Enum.drop(parse_selector_steps_simple(sel), length(base_fwd)) end)
        |> Enum.sort_by(&length/1)

      Enum.reduce(matching_deletes, with_overrides, fn rel_steps, acc ->
        delete_overlay_steps(acc, rel_steps)
      end)
    end
  end

  defp apply_staged_list_edits_overlay(
         %__MODULE__{staged_list_edits: edits},
         base,
         _base_sel,
         _base_fwd
       )
       when map_size(edits) == 0,
       do: base

  defp apply_staged_list_edits_overlay(cursor, base, base_sel, base_fwd) do
    cursor.staged_list_edits
    |> Enum.filter(fn {sel, _} -> selector_prefix?(sel, base_sel) end)
    |> Enum.sort_by(fn {sel, _} -> byte_size(sel) end)
    |> Enum.reduce(base, fn {sel, rev_edits}, acc ->
      rel_steps = Enum.drop(parse_selector_steps_simple(sel), length(base_fwd))
      edits = Enum.reverse(rev_edits)

      if rel_steps == [] do
        list = if is_list(acc), do: acc, else: []
        Enum.reduce(edits, list, &apply_single_list_edit(&2, materialize_staged_val_edit(&1)))
      else
        cur_list =
          case get_in_overlay(acc, rel_steps) do
            list when is_list(list) -> list
            _ -> []
          end

        updated_list =
          Enum.reduce(
            edits,
            cur_list,
            &apply_single_list_edit(&2, materialize_staged_val_edit(&1))
          )

        put_overlay_steps(acc, rel_steps, updated_list)
      end
    end)
  end

  defp materialize_staged_val_edit({:insert, idx, val}),
    do: {:insert, idx, materialize_staged_val(val)}

  defp materialize_staged_val_edit({:delete, idx}), do: {:delete, idx}

  defp get_in_overlay(acc, []), do: acc

  defp get_in_overlay(acc, [{kind, k} | rest])
       when kind in [:hash_map, :counted_hash_map, :sorted_map] and is_map(acc) and
              not is_struct(acc) do
    get_in_overlay(Map.get(acc, to_string(k)), rest)
  end

  defp get_in_overlay(acc, [{kind, idx} | rest])
       when kind in [:array_list, :linked_array_list] and is_list(acc) and is_integer(idx) do
    if idx >= 0 and idx < length(acc), do: get_in_overlay(Enum.at(acc, idx), rest), else: nil
  end

  defp get_in_overlay(_acc, _steps), do: nil

  defp fetch_edited_list(cursor, self_sel) do
    base_list =
      case resolve_fork_alias(cursor.fork_aliases, self_sel) do
        {:ok, alias_sel} ->
          case NIF.nif_select(cursor.db_ref, cursor.moment, alias_sel) do
            {:ok, raw} when not is_nil(raw) ->
              case unwrap_nif_value(cursor.db_ref, raw, cursor.moment, []) do
                %__MODULE__{} = ac -> Xitdb.materialize(ac)
                other when is_list(other) -> other
                _ -> []
              end

            _ ->
              []
          end

        :none ->
          if cursor.value == 0 and cursor.tag_id != -1 do
            []
          else
            %__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val, full: full} =
              ensure_resolved(cursor)

            full_int = if full, do: 1, else: 0

            case NIF.nif_slot_materialize(db_ref, tag_id, val, full_int) do
              {:ok, raw} -> raw
              {:error, reason} -> raise Xitdb.Error, reason: reason
            end
          end
      end

    edits = cursor.staged_list_edits |> Map.get(self_sel, []) |> Enum.reverse()

    Enum.reduce(
      edits,
      if(is_list(base_list), do: base_list, else: []),
      &apply_single_list_edit(&2, materialize_staged_val_edit(&1))
    )
  end

  defp materialize_staged_val(%Xitdb.Collection{kind: kind, data: data})
       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    data
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), materialize_staged_val(v)} end)
  end

  defp materialize_staged_val(%Xitdb.Collection{kind: kind, data: list})
       when kind in [:array_list, :linked_array_list] do
    Enum.map(list, &materialize_staged_val/1)
  end

  defp materialize_staged_val(%Xitdb.Collection{kind: kind, data: members})
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    MapSet.new(members, &to_string/1)
  end

  defp materialize_staged_val(%MapSet{} = set), do: MapSet.new(set, &to_string/1)

  defp materialize_staged_val(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), materialize_staged_val(v)} end)
  end

  defp materialize_staged_val(list) when is_list(list) do
    Enum.map(list, &materialize_staged_val/1)
  end

  defp materialize_staged_val({:compressed, bin}) when is_binary(bin), do: bin

  defp materialize_staged_val({:compressed, bin, _opts}) when is_binary(bin), do: bin

  defp materialize_staged_val(other), do: other

  defp put_overlay_steps(_acc, [], val), do: val

  defp put_overlay_steps(acc, [{kind, k} | rest], val)
       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    map = if is_map(acc) and not is_struct(acc), do: acc, else: %{}
    k_str = to_string(k)
    Map.put(map, k_str, put_overlay_steps(Map.get(map, k_str), rest, val))
  end

  defp put_overlay_steps(acc, [{kind, idx} | rest], val)
       when kind in [:array_list, :linked_array_list] and is_integer(idx) do
    list = if is_list(acc), do: acc, else: []

    cond do
      idx >= 0 and idx < length(list) ->
        List.replace_at(list, idx, put_overlay_steps(Enum.at(list, idx), rest, val))

      idx == length(list) ->
        list ++ [put_overlay_steps(nil, rest, val)]

      true ->
        list
    end
  end

  defp put_overlay_steps(acc, _steps, val), do: if(is_nil(acc), do: val, else: acc)

  defp delete_overlay_steps(_acc, []), do: nil

  defp delete_overlay_steps(acc, [{kind, k}])
       when kind in [:hash_map, :counted_hash_map, :sorted_map] and is_map(acc) and
              not is_struct(acc) do
    Map.delete(acc, to_string(k))
  end

  defp delete_overlay_steps(acc, [{kind, idx}])
       when kind in [:array_list, :linked_array_list] and is_list(acc) and is_integer(idx) do
    List.delete_at(acc, idx)
  end

  defp delete_overlay_steps(acc, [{kind, k} | rest])
       when kind in [:hash_map, :counted_hash_map, :sorted_map] and is_map(acc) and
              not is_struct(acc) do
    k_str = to_string(k)

    if Map.has_key?(acc, k_str) do
      Map.put(acc, k_str, delete_overlay_steps(Map.fetch!(acc, k_str), rest))
    else
      acc
    end
  end

  defp delete_overlay_steps(acc, [{kind, idx} | rest])
       when kind in [:array_list, :linked_array_list] and is_list(acc) and is_integer(idx) do
    if idx >= 0 and idx < length(acc) do
      List.replace_at(acc, idx, delete_overlay_steps(Enum.at(acc, idx), rest))
    else
      acc
    end
  end

  defp delete_overlay_steps(acc, _), do: acc

  defp purge_prefix_from_map(map, _prefix) when map_size(map) == 0, do: map
  defp purge_prefix_from_map(_map, ""), do: %{}

  defp purge_prefix_from_map(map, prefix) do
    :maps.filter(fn k, _v -> not selector_prefix?(k, prefix) end, map)
  end

  defp purge_prefix_from_set(set, prefix) do
    cond do
      MapSet.size(set) == 0 -> set
      prefix == "" -> MapSet.new()
      true -> set |> Enum.reject(&selector_prefix?(&1, prefix)) |> MapSet.new()
    end
  end

  defp selector_prefix?(sel, ""), do: is_binary(sel)
  defp selector_prefix?(sel, sel), do: true

  defp selector_prefix?(sel, prefix) do
    p_len = byte_size(prefix)

    byte_size(sel) > p_len and binary_part(sel, 0, p_len) == prefix and
      :binary.at(sel, p_len) in [?., ?#, ?$, ?[, ?%, ?^]
  end

  defp parse_selector_steps_simple(sel), do: do_parse_steps_simple(sel, [])

  defp do_parse_steps_simple(<<>>, acc), do: :lists.reverse(acc)

  defp do_parse_steps_simple(<<?#, ?%, rest::binary>>, acc) do
    {k, tail} = parse_key_simple(rest)
    do_parse_steps_simple(tail, [{:counted_hash_set, k} | acc])
  end

  defp do_parse_steps_simple(<<?., rest::binary>>, acc) do
    {k, tail} = parse_key_simple(rest)
    do_parse_steps_simple(tail, [{:hash_map, k} | acc])
  end

  defp do_parse_steps_simple(<<?#, rest::binary>>, acc) do
    {k, tail} = parse_key_simple(rest)
    do_parse_steps_simple(tail, [{:counted_hash_map, k} | acc])
  end

  defp do_parse_steps_simple(<<?$, rest::binary>>, acc) do
    {k, tail} = parse_key_simple(rest)
    do_parse_steps_simple(tail, [{:sorted_map, k} | acc])
  end

  defp do_parse_steps_simple(<<?%, rest::binary>>, acc) do
    {k, tail} = parse_key_simple(rest)
    do_parse_steps_simple(tail, [{:hash_set, k} | acc])
  end

  defp do_parse_steps_simple(<<?^, rest::binary>>, acc) do
    {k, tail} = parse_key_simple(rest)
    do_parse_steps_simple(tail, [{:sorted_set, k} | acc])
  end

  defp do_parse_steps_simple(<<?[, ?[, rest::binary>>, acc) do
    [int_str, tail] = String.split(rest, "]]", parts: 2)
    do_parse_steps_simple(tail, [{:linked_array_list, String.to_integer(int_str)} | acc])
  end

  defp do_parse_steps_simple(<<?[, q, rest::binary>>, acc) when q in [?", ?'] do
    {k, <<?], tail::binary>>} = unquote_bracket_str(rest, q, [])
    do_parse_steps_simple(tail, [{:hash_map, k} | acc])
  end

  defp do_parse_steps_simple(<<?[, rest::binary>>, acc) do
    [int_str, tail] = String.split(rest, "]", parts: 2)
    do_parse_steps_simple(tail, [{:array_list, String.to_integer(int_str)} | acc])
  end

  defp parse_key_simple(<<?[, q, rest::binary>>) when q in [?", ?'] do
    {k, <<?], tail::binary>>} = unquote_bracket_str(rest, q, [])
    {k, tail}
  end

  defp parse_key_simple(bin), do: take_bare_key(bin, 0, bin)

  defp take_bare_key(<<>>, len, orig), do: {binary_part(orig, 0, len), <<>>}

  defp take_bare_key(<<b, _::binary>> = tail, len, orig)
       when b in [?., ?#, ?$, ?[, ?%, ?^],
       do: {binary_part(orig, 0, len), tail}

  defp take_bare_key(<<_, rest::binary>>, len, orig), do: take_bare_key(rest, len + 1, orig)

  defp unquote_bracket_str(<<q, rest::binary>>, q, acc),
    do: {IO.iodata_to_binary(:lists.reverse(acc)), rest}

  defp unquote_bracket_str(<<?\\, ?\\, rest::binary>>, q, acc),
    do: unquote_bracket_str(rest, q, [?\\ | acc])

  defp unquote_bracket_str(<<?\\, ?", rest::binary>>, q, acc),
    do: unquote_bracket_str(rest, q, [?" | acc])

  defp unquote_bracket_str(<<?\\, ?', rest::binary>>, q, acc),
    do: unquote_bracket_str(rest, q, [?' | acc])

  defp unquote_bracket_str(<<?\\, ?n, rest::binary>>, q, acc),
    do: unquote_bracket_str(rest, q, [?\n | acc])

  defp unquote_bracket_str(<<?\\, ?r, rest::binary>>, q, acc),
    do: unquote_bracket_str(rest, q, [?\r | acc])

  defp unquote_bracket_str(<<?\\, ?t, rest::binary>>, q, acc),
    do: unquote_bracket_str(rest, q, [?\t | acc])

  defp unquote_bracket_str(<<b, rest::binary>>, q, acc),
    do: unquote_bracket_str(rest, q, [b | acc])

  @doc false
  def strict_equal?(%MapSet{} = a, %MapSet{} = b), do: MapSet.equal?(a, b)

  def strict_equal?(a, b)
      when is_map(a) and not is_struct(a) and is_map(b) and not is_struct(b) do
    map_size(a) == map_size(b) and
      Enum.all?(a, fn {k, v} -> Map.has_key?(b, k) and strict_equal?(v, Map.fetch!(b, k)) end)
  end

  def strict_equal?(a, b) when is_list(a) and is_list(b) do
    length(a) == length(b) and Enum.zip_with(a, b, &strict_equal?/2) |> Enum.all?(& &1)
  end

  def strict_equal?(a, b), do: a === b

  @doc false
  def steps_to_selector([]), do: ""

  def steps_to_selector([{:hash_map, k}]), do: format_step_fast(:hash_map, k)

  def steps_to_selector([{:hash_map, k2}, {:hash_map, k1}]) do
    if Selector.bare_key?(k1) and Selector.bare_key?(k2) do
      <<?., k1::binary, ?., k2::binary>>
    else
      format_rev_steps([{:hash_map, k2}, {:hash_map, k1}], "")
    end
  end

  def steps_to_selector([{:hash_map, k3}, {:hash_map, k2}, {:hash_map, k1}]) do
    if Selector.bare_key?(k1) and Selector.bare_key?(k2) and Selector.bare_key?(k3) do
      <<?., k1::binary, ?., k2::binary, ?., k3::binary>>
    else
      format_rev_steps([{:hash_map, k3}, {:hash_map, k2}, {:hash_map, k1}], "")
    end
  end

  def steps_to_selector([{kind, key_or_idx}]), do: Selector.format_step(kind, key_or_idx)
  def steps_to_selector(rev_steps), do: format_rev_steps(rev_steps, "")

  defp format_rev_steps([], acc), do: acc

  defp format_rev_steps([{kind, key_or_idx} | rest], acc) do
    step = format_step_fast(kind, key_or_idx)
    format_rev_steps(rest, <<step::binary, acc::binary>>)
  end

  @doc false
  def steps_to_override_key([]), do: ""

  def steps_to_override_key([{kind, k}])
      when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    format_step_fast(:hash_map, k)
  end

  def steps_to_override_key([{k_kind2, k2}, {k_kind1, k1}])
      when k_kind1 in [:hash_map, :counted_hash_map, :sorted_map] and
             k_kind2 in [:hash_map, :counted_hash_map, :sorted_map] do
    if Selector.bare_key?(k1) and Selector.bare_key?(k2) do
      <<?., k1::binary, ?., k2::binary>>
    else
      format_rev_override_steps([{:hash_map, k2}, {:hash_map, k1}], "")
    end
  end

  def steps_to_override_key([{k_kind3, k3}, {k_kind2, k2}, {k_kind1, k1}])
      when k_kind1 in [:hash_map, :counted_hash_map, :sorted_map] and
             k_kind2 in [:hash_map, :counted_hash_map, :sorted_map] and
             k_kind3 in [:hash_map, :counted_hash_map, :sorted_map] do
    if Selector.bare_key?(k1) and Selector.bare_key?(k2) and Selector.bare_key?(k3) do
      <<?., k1::binary, ?., k2::binary, ?., k3::binary>>
    else
      format_rev_override_steps([{:hash_map, k3}, {:hash_map, k2}, {:hash_map, k1}], "")
    end
  end

  def steps_to_override_key([{kind, key_or_idx}]) do
    Selector.format_step(canonical_override_kind(kind), key_or_idx)
  end

  def steps_to_override_key(rev_steps), do: format_rev_override_steps(rev_steps, "")

  defp format_rev_override_steps([], acc), do: acc

  defp format_rev_override_steps([{kind, key_or_idx} | rest], acc) do
    step = format_step_fast(canonical_override_kind(kind), key_or_idx)
    format_rev_override_steps(rest, <<step::binary, acc::binary>>)
  end

  @doc false
  def steps_to_selector_and_override_key([]), do: {"", ""}

  def steps_to_selector_and_override_key([{:hash_map, _}] = steps) do
    sel = steps_to_selector(steps)
    {sel, sel}
  end

  def steps_to_selector_and_override_key([{:hash_map, _}, {:hash_map, _}] = steps) do
    sel = steps_to_selector(steps)
    {sel, sel}
  end

  def steps_to_selector_and_override_key([{:hash_map, _}, {:hash_map, _}, {:hash_map, _}] = steps) do
    sel = steps_to_selector(steps)
    {sel, sel}
  end

  def steps_to_selector_and_override_key([{kind, key_or_idx}]) do
    sel = Selector.format_step(kind, key_or_idx)
    ov_kind = canonical_override_kind(kind)
    ov = if ov_kind == kind, do: sel, else: Selector.format_step(ov_kind, key_or_idx)
    {sel, ov}
  end

  def steps_to_selector_and_override_key(rev_steps) do
    format_rev_selector_and_override(rev_steps, "", "", false)
  end

  defp format_rev_selector_and_override([], sel_acc, ov_acc, diff?) do
    if diff?, do: {sel_acc, ov_acc}, else: {sel_acc, sel_acc}
  end

  defp format_rev_selector_and_override([{kind, key_or_idx} | rest], sel_acc, ov_acc, diff?) do
    sel_step = format_step_fast(kind, key_or_idx)
    ov_kind = canonical_override_kind(kind)

    if ov_kind == kind do
      format_rev_selector_and_override(
        rest,
        <<sel_step::binary, sel_acc::binary>>,
        <<sel_step::binary, ov_acc::binary>>,
        diff?
      )
    else
      ov_step = format_step_fast(ov_kind, key_or_idx)

      format_rev_selector_and_override(
        rest,
        <<sel_step::binary, sel_acc::binary>>,
        <<ov_step::binary, ov_acc::binary>>,
        true
      )
    end
  end

  defp format_step_fast(:hash_map, key) when is_binary(key) do
    if Selector.bare_key?(key),
      do: <<?., key::binary>>,
      else: Selector.format_step(:hash_map, key)
  end

  defp format_step_fast(kind, key_or_idx), do: Selector.format_step(kind, key_or_idx)

  defp canonical_override_selector(selector) do
    formatted = Selector.format_path_steps(selector)

    if not String.starts_with?(formatted, "@") and String.contains?(formatted, ["#", "$"]) do
      formatted
      |> parse_selector_steps_simple()
      |> :lists.reverse()
      |> steps_to_override_key()
    else
      formatted
    end
  end

  defp canonical_override_kind(kind) when kind in [:counted_hash_map, :sorted_map], do: :hash_map
  defp canonical_override_kind(kind), do: kind

  @doc false
  def inherit_staged(%__MODULE__{} = child, parent) do
    %{
      child
      | tx_mode: true,
        staged_ops: parent.staged_ops,
        staged_overrides: parent.staged_overrides,
        deleted_paths: parent.deleted_paths,
        staged_list_edits: parent.staged_list_edits,
        fork_aliases: parent.fork_aliases
    }
  end

  def inherit_staged(scalar, _parent), do: scalar

  defp merge_child_staged(parent, %__MODULE__{} = child) do
    %{
      parent
      | tx_mode: true,
        staged_ops: child.staged_ops,
        staged_overrides: child.staged_overrides,
        deleted_paths: child.deleted_paths,
        staged_list_edits: child.staged_list_edits,
        fork_aliases: child.fork_aliases
    }
  end
end

defimpl Enumerable, for: Xitdb.Cursor do
  alias Xitdb.{Cursor, NIF}

  @initial_chunk_size 16
  @chunk_size 256

  @impl Enumerable
  def count(%Cursor{tx_mode: false, tag: :none}), do: {:ok, 0}

  def count(%Cursor{tx_mode: false, root: false, tag_id: tag_id, db_ref: db_ref, value: val})
      when tag_id > 0 do
    case NIF.nif_slot_count(db_ref, tag_id, val) do
      {:ok, n} when is_integer(n) -> {:ok, n}
      {:error, reason} when reason in [:uncounted, :unsupported] -> {:error, __MODULE__}
      {:error, reason} -> raise Xitdb.Error, reason: reason
    end
  end

  def count(%Cursor{} = cursor) do
    if cursor.tx_mode and
         (map_size(cursor.staged_overrides) > 0 or MapSet.size(cursor.deleted_paths) > 0 or
            map_size(cursor.staged_list_edits) > 0 or cursor.fork_aliases != []) do
      {:error, __MODULE__}
    else
      %Cursor{db_ref: db_ref, tag_id: tag_id, value: val, root: root, moment: moment} =
        Cursor.ensure_resolved(cursor)

      {nid, nval} =
        cond do
          root and tag_id != -1 and val == 0 -> {tag_id, 0}
          root -> {-1, moment}
          true -> {tag_id, val}
        end

      case NIF.nif_slot_count(db_ref, nid, nval) do
        {:ok, n} when is_integer(n) -> {:ok, n}
        {:error, reason} when reason in [:uncounted, :unsupported] -> {:error, __MODULE__}
        {:error, reason} -> raise Xitdb.Error, reason: reason
      end
    end
  end

  @impl Enumerable
  def member?(%Cursor{tx_mode: false, tag: :none}, _candidate), do: {:ok, false}

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

  @impl Enumerable
  def slice(%Cursor{tx_mode: false, tag: :none}),
    do: {:ok, 0, fn _start, _len, _step -> [] end}

  def slice(%Cursor{} = raw_cursor) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0 or
            map_size(raw_cursor.staged_list_edits) > 0 or
            raw_cursor.fork_aliases != []) do
      {:error, __MODULE__}
    else
      case Cursor.ensure_resolved(raw_cursor) do
        %Cursor{
          db_ref: db_ref,
          tag: tag,
          tag_id: tag_id,
          value: val,
          moment: moment,
          root: root
        } = cursor
        when tag in [:array_list, :linked_array_list, :sorted_map, :sorted_set] ->
          {nid, nval} =
            cond do
              root and tag_id != -1 and val == 0 -> {tag_id, 0}
              root -> {-1, moment}
              true -> {tag_id, val}
            end

          case NIF.nif_slot_count(db_ref, nid, nval) do
            {:ok, size} ->
              {:ok, size,
               fn
                 _start, length, _step when length <= 0 ->
                   []

                 start, length, step ->
                   span = (length - 1) * step + 1

                   case NIF.nif_slot_slice(db_ref, nid, nval, start, span) do
                     {:ok, raw_list} ->
                       selected =
                         if step == 1, do: raw_list, else: Enum.take_every(raw_list, step)

                       selected
                       |> Enum.with_index()
                       |> Enum.map(fn {entry, pos} ->
                         unwrap_entry(cursor, entry, start + pos * step)
                       end)

                     {:error, reason} ->
                       raise Xitdb.Error, reason: reason
                   end
               end}

            {:error, reason} when reason in [:uncounted, :unsupported] ->
              {:error, __MODULE__}

            {:error, reason} ->
              raise Xitdb.Error, reason: reason
          end

        _ ->
          {:error, __MODULE__}
      end
    end
  end

  @impl Enumerable
  def reduce(%Cursor{tx_mode: false, tag: :none}, {:halt, acc}, _fun), do: {:halted, acc}

  def reduce(%Cursor{tx_mode: false, tag: :none} = c, {:suspend, acc}, fun),
    do: {:suspended, acc, &reduce(c, &1, fun)}

  def reduce(%Cursor{tx_mode: false, tag: :none}, {:cont, acc}, _fun), do: {:done, acc}

  def reduce(%Cursor{} = raw_cursor, acc, fun) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0 or
            map_size(raw_cursor.staged_list_edits) > 0 or
            raw_cursor.fork_aliases != []) do
      enumerable =
        case {raw_cursor.tag, Xitdb.materialize(raw_cursor)} do
          {:sorted_map, map} when is_map(map) and not is_struct(map) ->
            Enum.sort_by(map, &elem(&1, 0))

          {:sorted_set, %MapSet{} = set} ->
            Enum.sort(set)

          {_tag, other} ->
            other
        end

      Enumerable.reduce(enumerable, acc, fun)
    else
      %Cursor{} = resolved = Cursor.ensure_resolved(raw_cursor)

      stream_cursor =
        cond do
          resolved.root and resolved.tag_id != -1 and resolved.value == 0 ->
            %Cursor{resolved | value: 0}

          resolved.root and resolved.tag != :none ->
            %Cursor{resolved | tag_id: -1, value: resolved.moment}

          true ->
            resolved
        end

      do_reduce(stream_cursor, 0, 0, @initial_chunk_size, [], acc, fun)
    end
  end

  defp do_reduce(_cursor, _elem_idx, _offset, _chunk_size, _buf, {:halt, acc}, _fun),
    do: {:halted, acc}

  defp do_reduce(cursor, elem_idx, offset, chunk_size, buf, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(cursor, elem_idx, offset, chunk_size, buf, &1, fun)}
  end

  defp do_reduce(cursor, elem_idx, offset, chunk_size, [raw_head | raw_tail], {:cont, acc}, fun) do
    item = unwrap_entry(cursor, raw_head, elem_idx)
    do_reduce(cursor, elem_idx + 1, offset, chunk_size, raw_tail, fun.(item, acc), fun)
  end

  defp do_reduce(_cursor, _elem_idx, _offset, 0, [], {:cont, acc}, _fun), do: {:done, acc}

  defp do_reduce(
         %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = cursor,
         elem_idx,
         offset,
         chunk_size,
         [],
         {:cont, acc},
         fun
       ) do
    case NIF.nif_slot_entries(db_ref, tag_id, val, offset, chunk_size) do
      {:ok, []} ->
        {:done, acc}

      {:ok, raw_chunk} ->
        chunk_len = length(raw_chunk)
        next_size = if chunk_len < chunk_size, do: 0, else: next_chunk_size(chunk_size)

        do_reduce(
          cursor,
          elem_idx,
          offset + chunk_len,
          next_size,
          raw_chunk,
          {:cont, acc},
          fun
        )

      {:error, reason} ->
        raise Xitdb.Error, reason: reason
    end
  end

  defp next_chunk_size(16), do: 64
  defp next_chunk_size(_), do: @chunk_size

  defp unwrap_entry(
         %Cursor{
           db_ref: db_ref,
           moment: moment,
           path_steps: path_steps,
           tx_mode: tx_mode,
           tag: tag
         } =
           parent,
         {raw_k, raw_val},
         _elem_idx
       )
       when tag in [:hash_map, :counted_hash_map, :sorted_map] do
    k = Cursor.unwrap_nif_value(db_ref, raw_k, moment, [])

    if tx_mode and is_binary(k) do
      child_steps = [{tag, k} | path_steps]
      unwrapped = Cursor.unwrap_nif_value(db_ref, raw_val, moment, child_steps)
      {k, Cursor.inherit_staged(unwrapped, parent)}
    else
      {k, Cursor.unwrap_nif_value(db_ref, raw_val, moment, [])}
    end
  end

  defp unwrap_entry(
         %Cursor{
           db_ref: db_ref,
           moment: moment,
           path_steps: path_steps,
           tx_mode: tx_mode,
           tag: tag
         } =
           parent,
         raw_val,
         elem_idx
       ) do
    child_steps =
      if tx_mode and tag in [:array_list, :linked_array_list],
        do: [{tag, elem_idx} | path_steps],
        else: []

    unwrapped = Cursor.unwrap_nif_value(db_ref, raw_val, moment, child_steps)
    if tx_mode, do: Cursor.inherit_staged(unwrapped, parent), else: unwrapped
  end
end

defimpl Inspect, for: Xitdb.Cursor do
  import Inspect.Algebra
  alias Xitdb.Cursor.PreviewTag

  def inspect(%Xitdb.Cursor{} = raw_cursor, opts) do
    try do
      case Xitdb.Cursor.try_resolve(raw_cursor) do
        {:ok, %Xitdb.Cursor{tag: tag, value: val} = cursor} ->
          preview =
            cursor
            |> Stream.take(5)
            |> Enum.map(fn
              {k, %Xitdb.Cursor{tag: child_tag}} -> {k, %PreviewTag{tag: child_tag}}
              {k, v} -> {k, v}
              %Xitdb.Cursor{tag: child_tag} -> %PreviewTag{tag: child_tag}
              v -> v
            end)

          count_part =
            case Enumerable.count(cursor) do
              {:ok, n} -> " count: #{n},"
              {:error, _} -> ""
            end

          concat([
            "#Xitdb.Cursor<",
            to_string(tag),
            count_part,
            " offset: ",
            to_string(val),
            ", preview: ",
            to_doc(preview, opts),
            ">"
          ])

        {:error, reason} ->
          concat(["#Xitdb.Cursor<unresolved (", inspect(reason), ")>"])
      end
    rescue
      e in Xitdb.Error ->
        concat(["#Xitdb.Cursor<unresolved (", inspect(e.reason), ")>"])
    end
  end
end
