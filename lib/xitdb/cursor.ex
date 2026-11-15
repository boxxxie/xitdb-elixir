defmodule Xitdb.Cursor do
  @moduledoc """
  Clojure/Datomic-style lazy cursor representing a 9-byte `Slot` (`tag` + `value`)
  in an immutable `xitdb` store.

  Because `%Xitdb.Cursor{}` holds only the NIF database resource reference and the
  9-byte slot coordinates (`tag`, `tag_id`, `value`), it is a **pure Elixir value**:
  - Can be passed across BEAM processes (`Task.async/1`, GenServers, ETS, LiveView assigns)
    with zero mutexes or dangling pointer hazards.
  - Implements `Access` (`cursor["key"]`, `cursor[0]`, `get_in/2`, `put_in/3`, `update_in/3`, `pop_in/2`).
  - Implements `Enumerable` (`Enum.count/1` in `O(1)` on counted collections,
    `Enum.member?/2` in `O(1)` / `O(log N)` via HAMT/B+Tree lookup,
    `Enum.slice/2` in `O(log N)` via index seek, and `Enum.to_list/1` / `Stream.*`).
  - Implements `Inspect` with a safe, bounded preview.
  """

  @behaviour Access

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
    deleted_paths: MapSet.new()
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
          deleted_paths: MapSet.t()
        }

  defmodule PreviewTag do
    @moduledoc false
    defstruct [:tag]

    defimpl Inspect do
      def inspect(%PreviewTag{tag: tag}, _opts), do: "<#{tag}>"
    end
  end

  @doc false
  def from_nif_tuple(db_ref, {:cursor, tag_atom, tag_id, val, full_int}, moment, path_steps \\ []) do
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
  def unwrap_nif_value(db_ref, raw, moment, path_steps \\ [])

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

  def unwrap_nif_value(_db_ref, scalar, _moment, _path_steps), do: scalar

  # ============================================================================
  # Access Behaviour (`cursor["key"]`, `cursor[idx]`, `get_in`, `put_in`, `pop_in`)
  # ============================================================================

  @impl Access
  def fetch(%__MODULE__{} = cursor, key) when is_atom(key) do
    fetch(cursor, Atom.to_string(key))
  end

  def fetch(%__MODULE__{tx_mode: false} = cursor, key)
      when is_integer(key) or is_binary(key) do
    case nif_slot_get(cursor, key) do
      {:ok, {:cursor, _, _, _, _} = tuple} ->
        {:ok, from_nif_tuple(cursor.db_ref, tuple, cursor.moment)}

      {:ok, scalar} ->
        {:ok, scalar}

      :error ->
        :error

      {:error, reason} ->
        raise Xitdb.Error, reason: reason
    end
  end

  def fetch(%__MODULE__{tx_mode: true} = raw_cursor, key)
      when is_integer(key) or is_binary(key) do
    cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
    resolved_key = resolve_list_key(cursor, key)
    child_key = if is_integer(resolved_key), do: resolved_key, else: to_string(resolved_key)
    child_steps = [{cursor.tag, child_key} | cursor.path_steps]

    case lookup_staged(cursor, child_steps) do
      {:staged, val} ->
        {:ok, val}

      :deleted ->
        :error

      :miss ->
        if cursor.value == 0 and pointer_container_tag?(cursor.tag) do
          maybe_fetch_staged_descendant(cursor, child_steps)
        else
          case nif_slot_get(cursor, key) do
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
    self_sel = steps_to_selector(cursor.path_steps)

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
            if cursor.value == 0 and pointer_container_tag?(cursor.tag) do
              {:ok, 0}
            else
              %__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val} = ensure_resolved(cursor)

              case NIF.nif_slot_count(db_ref, tag_id, val) do
                {:ok, cnt} -> {:ok, cnt}
                {:error, :uncounted} -> :uncounted
                {:error, reason} -> raise Xitdb.Error, reason: reason
              end
            end
        end
    end
  end

  defp lookup_staged(
         %__MODULE__{staged_overrides: overrides, deleted_paths: deleted} = cursor,
         child_steps
       ) do
    if map_size(overrides) == 0 and MapSet.size(deleted) == 0 do
      :miss
    else
      selector = steps_to_selector(child_steps)

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
      selector = steps_to_selector(child_steps)

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
          Enum.map_join(anc_forward, "", fn {kind, k} -> Selector.format_step(kind, k) end)

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

  defp wrap_staged_val(_cursor, _child_steps, scalar), do: scalar

  defp virtual_staged_cursor(cursor, child_steps, tag) do
    %__MODULE__{
      db_ref: cursor.db_ref,
      tag: tag,
      tag_id: tag_id_for(tag),
      value: 0,
      moment: cursor.moment,
      tx_mode: true,
      path_steps: child_steps,
      staged_ops: cursor.staged_ops,
      staged_overrides: cursor.staged_overrides,
      deleted_paths: cursor.deleted_paths
    }
  end

  @doc false
  def ensure_resolved(%__MODULE__{tag_id: -1, moment: moment} = cursor) do
    case try_resolve(cursor) do
      {:ok, resolved} -> resolved
      {:error, reason} -> raise Xitdb.Error, reason: reason, details: %{moment_index: moment}
    end
  end

  def ensure_resolved(cursor), do: cursor

  @doc false
  def try_resolve(%__MODULE__{tag_id: -1, db_ref: db_ref, moment: moment} = cursor) do
    case NIF.nif_moment_slot(db_ref, moment) do
      {:ok, {:cursor, tag_atom, tag_id, val, full_int}} ->
        {:ok,
         %__MODULE__{cursor | tag: tag_atom, tag_id: tag_id, value: val, full: full_int != 0}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def try_resolve(%__MODULE__{} = cursor), do: {:ok, cursor}

  @impl Access
  def get_and_update(%__MODULE__{} = raw_cursor, raw_key, fun) do
    key = if is_atom(raw_key), do: Atom.to_string(raw_key), else: raw_key
    %__MODULE__{} = cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
    resolved_key = resolve_list_key(cursor, key)

    current =
      case fetch(cursor, resolved_key) do
        {:ok, val} -> val
        :error -> nil
      end

    child_key = if is_integer(resolved_key), do: resolved_key, else: to_string(resolved_key)
    child_steps = [{cursor.tag, child_key} | cursor.path_steps]

    callback_result =
      if is_nil(current) do
        try do
          fun.(nil)
        rescue
          e in ArgumentError ->
            if String.contains?(e.message, "nil value") do
              selector = steps_to_selector(child_steps)

              vivified_base =
                if MapSet.member?(cursor.deleted_paths, selector) do
                  %__MODULE__{
                    cursor
                    | staged_overrides: Map.put(cursor.staged_overrides, selector, %{}),
                      deleted_paths: MapSet.delete(cursor.deleted_paths, selector)
                  }
                else
                  cursor
                end

              vivified = virtual_staged_cursor(vivified_base, child_steps, :hash_map)
              fun.(vivified)
            else
              reraise e, __STACKTRACE__
            end
        end
      else
        fun.(current)
      end

    case callback_result do
      {get_val, %__MODULE__{} = updated_child} ->
        {get_val, merge_child_staged(cursor, updated_child)}

      {get_val, nil} when cursor.tag not in [:array_list, :linked_array_list] ->
        selector = steps_to_selector(child_steps)

        updated_cursor = %__MODULE__{
          cursor
          | tx_mode: true,
            staged_ops: [{:rm_if_exists, selector} | cursor.staged_ops],
            staged_overrides: purge_prefix_from_map(cursor.staged_overrides, selector),
            deleted_paths:
              cursor.deleted_paths
              |> purge_prefix_from_set(selector)
              |> MapSet.put(selector)
        }

        {get_val, updated_cursor}

      {get_val, new_val} ->
        selector = steps_to_selector(child_steps)

        new_ops =
          if is_nil(new_val) and cursor.tag in [:array_list, :linked_array_list] do
            [{:put, selector, nil}]
          else
            TxCompiler.compile_node(selector, new_val, true)
          end

        updated_overrides =
          cursor.staged_overrides
          |> purge_prefix_from_map(selector)
          |> Map.put(selector, new_val)

        updated_deleted =
          if MapSet.size(cursor.deleted_paths) == 0 do
            cursor.deleted_paths
          else
            cursor.deleted_paths
            |> purge_prefix_from_set(selector)
            |> MapSet.delete(selector)
          end

        updated_cursor = %__MODULE__{
          cursor
          | tx_mode: true,
            staged_ops: :lists.reverse(new_ops, cursor.staged_ops),
            staged_overrides: updated_overrides,
            deleted_paths: updated_deleted
        }

        {get_val, updated_cursor}

      :pop ->
        pop(cursor, resolved_key)
    end
  end

  @impl Access
  def pop(%__MODULE__{} = raw_cursor, raw_key) do
    key = if is_atom(raw_key), do: Atom.to_string(raw_key), else: raw_key
    %__MODULE__{} = cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
    resolved_key = resolve_list_key(cursor, key)

    current =
      case fetch(cursor, resolved_key) do
        {:ok, val} -> val
        :error -> nil
      end

    child_key = if is_integer(resolved_key), do: resolved_key, else: to_string(resolved_key)
    child_steps = [{cursor.tag, child_key} | cursor.path_steps]
    selector = steps_to_selector(child_steps)
    parent_sel = steps_to_selector(cursor.path_steps)

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
                  |> purge_prefix_from_map(parent_sel)
                  |> Map.put(parent_sel, sliced_list),
                deleted_paths: purge_prefix_from_set(cursor.deleted_paths, parent_sel)
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
                |> purge_prefix_from_map(parent_sel)
                |> Map.put(parent_sel, %Xitdb.Collection{
                  kind: :linked_array_list,
                  data: shifted_list
                }),
              deleted_paths: purge_prefix_from_set(cursor.deleted_paths, parent_sel)
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
            staged_overrides: purge_prefix_from_map(cursor.staged_overrides, selector),
            deleted_paths:
              cursor.deleted_paths
              |> purge_prefix_from_set(selector)
              |> MapSet.put(selector)
        }

        {current, updated_cursor}
    end
  end

  defp materialize_current_list(cursor, cnt) do
    for idx <- 0..(cnt - 1)//1 do
      case fetch(%{cursor | tx_mode: true}, idx) do
        {:ok, %__MODULE__{} = child_cur} -> Xitdb.materialize(child_cur)
        {:ok, val} -> val
        :error -> nil
      end
    end
  end

  @doc false
  def purge_staged_prefix(%__MODULE__{} = cursor, selector) when is_binary(selector) do
    %__MODULE__{
      cursor
      | staged_overrides: purge_prefix_from_map(cursor.staged_overrides, selector),
        deleted_paths: purge_prefix_from_set(cursor.deleted_paths, selector)
    }
  end

  @doc false
  def fork_staged_prefix(%__MODULE__{} = cursor, from_selector, to_selector) do
    if map_size(cursor.staged_overrides) == 0 and MapSet.size(cursor.deleted_paths) == 0 do
      cursor
    else
      cleared_overrides = purge_prefix_from_map(cursor.staged_overrides, to_selector)
      cleared_deleted = purge_prefix_from_set(cursor.deleted_paths, to_selector)

      copied_overrides =
        Enum.reduce(cursor.staged_overrides, cleared_overrides, fn {k, v}, acc ->
          if selector_prefix?(k, from_selector) do
            suffix =
              binary_part(k, byte_size(from_selector), byte_size(k) - byte_size(from_selector))

            Map.put(acc, to_selector <> suffix, v)
          else
            acc
          end
        end)

      copied_deleted =
        Enum.reduce(cursor.deleted_paths, cleared_deleted, fn k, acc ->
          if selector_prefix?(k, from_selector) do
            suffix =
              binary_part(k, byte_size(from_selector), byte_size(k) - byte_size(from_selector))

            MapSet.put(acc, to_selector <> suffix)
          else
            acc
          end
        end)

      %__MODULE__{cursor | staged_overrides: copied_overrides, deleted_paths: copied_deleted}
    end
  end

  @doc false
  def apply_staged_overlay(%__MODULE__{tx_mode: false}, base), do: base

  def apply_staged_overlay(%__MODULE__{} = cursor, base) do
    if map_size(cursor.staged_overrides) == 0 and MapSet.size(cursor.deleted_paths) == 0 do
      base
    else
      base_sel = steps_to_selector(cursor.path_steps)
      base_fwd = :lists.reverse(cursor.path_steps)

      matching_overrides =
        cursor.staged_overrides
        |> Enum.filter(fn {sel, _} -> selector_prefix?(sel, base_sel) end)
        |> Enum.map(fn {sel, v} ->
          rel_steps = Enum.drop(parse_selector_steps_simple(sel), length(base_fwd))
          {rel_steps, materialize_staged_val(v)}
        end)
        |> Enum.sort_by(fn {rel_steps, _} -> length(rel_steps) end)

      with_overrides =
        Enum.reduce(matching_overrides, base, fn {rel_steps, val}, acc ->
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

  defp materialize_staged_val(%Xitdb.Collection{kind: kind, data: data})
       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    Map.new(data, fn {k, v} -> {to_string(k), materialize_staged_val(v)} end)
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
  def steps_to_selector(rev_steps) do
    rev_steps
    |> :lists.reverse()
    |> Enum.map_join("", fn {kind, key_or_idx} ->
      Selector.format_step(kind, key_or_idx)
    end)
  end

  defp inherit_staged(%__MODULE__{} = child, parent) do
    %{
      child
      | tx_mode: true,
        staged_ops: parent.staged_ops,
        staged_overrides: parent.staged_overrides,
        deleted_paths: parent.deleted_paths
    }
  end

  defp inherit_staged(scalar, _parent), do: scalar

  defp merge_child_staged(parent, %__MODULE__{} = child) do
    %{
      parent
      | tx_mode: true,
        staged_ops: child.staged_ops,
        staged_overrides: child.staged_overrides,
        deleted_paths: child.deleted_paths
    }
  end
end

defimpl Enumerable, for: Xitdb.Cursor do
  alias Xitdb.{Cursor, NIF}

  @chunk_size 256

  @impl Enumerable
  def count(%Cursor{} = cursor) do
    if cursor.tx_mode and
         (map_size(cursor.staged_overrides) > 0 or MapSet.size(cursor.deleted_paths) > 0) do
      {:error, __MODULE__}
    else
      %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = Cursor.ensure_resolved(cursor)

      case NIF.nif_slot_count(db_ref, tag_id, val) do
        {:ok, n} when is_integer(n) -> {:ok, n}
        _ -> {:error, __MODULE__}
      end
    end
  end

  @impl Enumerable
  def member?(%Cursor{} = raw_cursor, candidate) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0) do
      {:error, __MODULE__}
    else
      %Cursor{db_ref: db_ref, tag: tag, tag_id: tag_id, value: val, root: root, moment: moment} =
        cursor = Cursor.ensure_resolved(raw_cursor)

      cond do
        root and match?({"__tx", _}, candidate) ->
          {:ok, false}

        tag in [:hash_set, :counted_hash_set, :sorted_set] ->
          if is_binary(candidate) do
            {nid, nval} = if root, do: {-1, moment}, else: {tag_id, val}

            case NIF.nif_slot_contains(db_ref, nid, nval, candidate) do
              {:ok, bool} -> {:ok, bool}
              _ -> {:error, __MODULE__}
            end
          else
            {:ok, false}
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
              {:ok, false}
          end

        true ->
          {:error, __MODULE__}
      end
    end
  end

  @impl Enumerable
  def slice(%Cursor{} = raw_cursor) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0) do
      {:error, __MODULE__}
    else
      case Cursor.ensure_resolved(raw_cursor) do
        %Cursor{db_ref: db_ref, tag: tag, tag_id: tag_id, value: val, moment: moment} = cursor
        when tag in [:array_list, :linked_array_list, :sorted_map, :sorted_set] ->
          case NIF.nif_slot_count(db_ref, tag_id, val) do
            {:ok, size} ->
              {:ok, size,
               fn
                 _start, length, _step when length <= 0 ->
                   []

                 start, length, step ->
                   span = (length - 1) * step + 1

                   case NIF.nif_slot_slice(db_ref, tag_id, val, start, span) do
                     {:ok, raw_list} ->
                       selected =
                         if step == 1, do: raw_list, else: Enum.take_every(raw_list, step)

                       Enum.map(selected, &unwrap_entry(db_ref, &1, moment, cursor.path_steps))

                     {:error, reason} ->
                       raise Xitdb.Error, reason: reason
                   end
               end}

            _ ->
              {:error, __MODULE__}
          end

        _ ->
          {:error, __MODULE__}
      end
    end
  end

  @impl Enumerable
  def reduce(%Cursor{} = raw_cursor, acc, fun) do
    if raw_cursor.tx_mode and
         (map_size(raw_cursor.staged_overrides) > 0 or
            MapSet.size(raw_cursor.deleted_paths) > 0) do
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
        if resolved.root and resolved.tag != :none do
          %Cursor{resolved | tag_id: -1, value: resolved.moment}
        else
          resolved
        end

      do_reduce(stream_cursor, 0, [], acc, fun)
    end
  end

  defp do_reduce(_cursor, _offset, _buf, {:halt, acc}, _fun), do: {:halted, acc}

  defp do_reduce(cursor, offset, buf, {:suspend, acc}, fun) do
    {:suspended, acc, &do_reduce(cursor, offset, buf, &1, fun)}
  end

  defp do_reduce(
         %Cursor{db_ref: db_ref, moment: moment, path_steps: path_steps} = cursor,
         offset,
         [raw_head | raw_tail],
         {:cont, acc},
         fun
       ) do
    item = unwrap_entry(db_ref, raw_head, moment, path_steps)
    do_reduce(cursor, offset, raw_tail, fun.(item, acc), fun)
  end

  defp do_reduce(
         %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = cursor,
         offset,
         [],
         {:cont, acc},
         fun
       ) do
    chunk_len =
      cond do
        offset == 0 -> 16
        offset == 16 -> 64
        true -> @chunk_size
      end

    case NIF.nif_slot_entries(db_ref, tag_id, val, offset, chunk_len) do
      {:ok, []} ->
        {:done, acc}

      {:ok, raw_chunk} ->
        do_reduce(cursor, offset + length(raw_chunk), raw_chunk, {:cont, acc}, fun)

      {:error, _} ->
        {:done, acc}
    end
  end

  defp unwrap_entry(db_ref, {k, raw_val}, moment, path_steps) when is_binary(k) do
    {k, Cursor.unwrap_nif_value(db_ref, raw_val, moment, path_steps)}
  end

  defp unwrap_entry(db_ref, raw_val, moment, path_steps) do
    Cursor.unwrap_nif_value(db_ref, raw_val, moment, path_steps)
  end
end

defimpl Inspect, for: Xitdb.Cursor do
  import Inspect.Algebra
  alias Xitdb.Cursor.PreviewTag

  def inspect(%Xitdb.Cursor{} = raw_cursor, opts) do
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
          case Xitdb.NIF.nif_slot_count(cursor.db_ref, cursor.tag_id, val) do
            {:ok, n} -> " count: #{n},"
            _ -> ""
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
  end
end
