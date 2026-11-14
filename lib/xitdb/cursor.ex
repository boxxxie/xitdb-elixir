defmodule Xitdb.Cursor do
  @moduledoc """
  Clojure/Datomic-style lazy cursor representing a 9-byte `Slot` (`tag` + `value`)
  in an immutable `xitdb` store.

  Because `%Xitdb.Cursor{}` holds only the NIF database resource reference and the
  9-byte slot coordinates (`tag`, `tag_id`, `value`), it is a **pure Elixir value**:
  - Can be passed across BEAM processes (`Task.async/1`, GenServers, ETS, LiveView assigns)
    with zero mutexes or dangling pointer hazards.
  - Implements `Access` (`cursor["key"]`, `cursor[0]`, `get_in/2`, `put_in/3`, `update_in/3`, `pop_in/2`).
  - Implements `Enumerable` (`Enum.count/1` in $O(1)$ on counted collections,
    `Enum.member?/2` in $O(1)$ / $O(\\log N)$ via HAMT/B+Tree lookup,
    `Enum.slice/2` in $O(\\log N)$ via index seek, and `Enum.to_list/1` / `Stream.*`).
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
    tx_mode: false,
    path_steps: [],
    staged_ops: [],
    staged_overrides: %{},
    deleted_paths: MapSet.new()
  ]

  @type t :: %__MODULE__{
          db_ref: reference(),
          tag: atom(),
          tag_id: non_neg_integer(),
          value: integer(),
          full: boolean(),
          moment: integer(),
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

  def fetch(%__MODULE__{tx_mode: false} = raw_cursor, key)
      when is_integer(key) or is_binary(key) do
    cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor

    case nif_slot_get(cursor, key) do
      {:ok, {:cursor, _, _, _, _} = tuple} ->
        {:ok, from_nif_tuple(cursor.db_ref, tuple, cursor.moment)}

      {:ok, scalar} ->
        {:ok, scalar}

      :error ->
        :error
    end
  end

  def fetch(%__MODULE__{tx_mode: true} = raw_cursor, key)
      when is_integer(key) or is_binary(key) do
    cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
    child_steps = [{cursor.tag, key} | cursor.path_steps]

    case lookup_staged(cursor, child_steps) do
      {:staged, val} ->
        {:ok, val}

      :deleted ->
        :error

      :miss ->
        case nif_slot_get(cursor, key) do
          {:ok, raw} ->
            val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
            {:ok, inherit_staged(val, cursor)}

          :error ->
            :error
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

  defp lookup_staged(
         %__MODULE__{staged_overrides: overrides, deleted_paths: deleted},
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
          {:staged, Map.fetch!(overrides, selector)}

        true ->
          :miss
      end
    end
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
  def get_and_update(%__MODULE__{} = cursor, key, fun) do
    current =
      case fetch(cursor, key) do
        {:ok, val} -> val
        :error -> nil
      end

    case fun.(current) do
      {get_val, %__MODULE__{} = updated_child} ->
        {get_val, merge_child_staged(cursor, updated_child)}

      {get_val, new_val} ->
        child_key = if is_integer(key), do: key, else: to_string(key)
        child_steps = [{cursor.tag, child_key} | cursor.path_steps]
        selector = steps_to_selector(child_steps)
        new_ops = TxCompiler.compile_node(selector, new_val, true)

        updated_cursor = %__MODULE__{
          cursor
          | tx_mode: true,
            staged_ops: :lists.reverse(new_ops, cursor.staged_ops),
            staged_overrides: Map.put(cursor.staged_overrides, selector, new_val),
            deleted_paths: MapSet.delete(cursor.deleted_paths, selector)
        }

        {get_val, updated_cursor}

      :pop ->
        pop(cursor, key)
    end
  end

  @impl Access
  def pop(%__MODULE__{} = cursor, key) do
    current =
      case fetch(cursor, key) do
        {:ok, val} -> val
        :error -> nil
      end

    child_key = if is_integer(key), do: key, else: to_string(key)
    child_steps = [{cursor.tag, child_key} | cursor.path_steps]
    selector = steps_to_selector(child_steps)

    updated_cursor = %__MODULE__{
      cursor
      | tx_mode: true,
        staged_ops: [{:rm, selector} | cursor.staged_ops],
        staged_overrides: Map.delete(cursor.staged_overrides, selector),
        deleted_paths: MapSet.put(cursor.deleted_paths, selector)
    }

    {current, updated_cursor}
  end

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
    %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = Cursor.ensure_resolved(cursor)

    case NIF.nif_slot_count(db_ref, tag_id, val) do
      {:ok, n} when is_integer(n) -> {:ok, n}
      _ -> {:error, __MODULE__}
    end
  end

  @impl Enumerable
  def member?(%Cursor{db_ref: db_ref, tag: tag, tag_id: tag_id, value: val} = cursor, candidate) do
    cond do
      tag in [:hash_set, :counted_hash_set, :sorted_set] and is_binary(candidate) ->
        case NIF.nif_slot_contains(db_ref, tag_id, val, candidate) do
          {:ok, bool} -> {:ok, bool}
          _ -> {:error, __MODULE__}
        end

      tag in [:hash_map, :counted_hash_map, :sorted_map] and is_tuple(candidate) and
          tuple_size(candidate) == 2 ->
        {k, expected_v} = candidate

        case Cursor.fetch(cursor, to_string(k)) do
          {:ok, %Cursor{} = child_cur} ->
            {:ok, Xitdb.materialize(child_cur) == expected_v}

          {:ok, actual_v} ->
            {:ok, actual_v == expected_v}

          :error ->
            {:ok, false}
        end

      true ->
        {:error, __MODULE__}
    end
  end

  @impl Enumerable
  def slice(
        %Cursor{db_ref: db_ref, tag: tag, tag_id: tag_id, value: val, moment: moment} = cursor
      )
      when tag in [:array_list, :linked_array_list, :sorted_map, :sorted_set] do
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
                 selected = if step == 1, do: raw_list, else: Enum.take_every(raw_list, step)
                 Enum.map(selected, &unwrap_entry(db_ref, &1, moment, cursor.path_steps))

               {:error, reason} ->
                 raise Xitdb.Error, reason: reason
             end
         end}

      _ ->
        {:error, __MODULE__}
    end
  end

  def slice(_cursor), do: {:error, __MODULE__}

  @impl Enumerable
  def reduce(%Cursor{} = cursor, acc, fun) do
    do_reduce(Cursor.ensure_resolved(cursor), 0, [], acc, fun)
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
