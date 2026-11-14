defmodule Xitdb.TxCompiler do
  @moduledoc false

  alias Xitdb.{Collection, Selector}

  # Retained for Xitdb.Ash.Indexer.Storage and Xitdb.Ash.Mutator.Sequences
  defdelegate format_step(kind, key), to: Selector
  defdelegate format_key(key), to: Selector

  @doc """
  Compiles a nested Elixir map or `Xitdb.Collection` into a flat list of
  coarse-grained NIF transaction tuples (`{:put, path, val}`, `{:init_col, path, kind}`, etc.).
  """
  def compile_moment_map(map, opts \\ []) when is_map(map) do
    acc =
      case Keyword.get(opts, :index_rules, []) do
        [] ->
          []

        rules ->
          Enum.reduce(rules, [], fn {:index_on, src, field, idx}, acc ->
            [{:index_on, to_string(src), to_string(field), to_string(idx)} | acc]
          end)
      end

    acc =
      :maps.fold(
        fn k, v, a ->
          compile_node_acc(Selector.format_step(:hash_map, k), v, false, a)
        end,
        acc,
        map
      )

    :lists.reverse(acc)
  end

  def compile_node(prefix, node, reset?) do
    :lists.reverse(compile_node_acc(prefix, node, reset?, []))
  end

  defp kind_str(:hash_map), do: "hash_map"
  defp kind_str(:counted_hash_map), do: "counted_hash_map"
  defp kind_str(:sorted_map), do: "sorted_map"
  defp kind_str(:array_list), do: "array_list"
  defp kind_str(:linked_array_list), do: "linked_array_list"
  defp kind_str(:hash_set), do: "hash_set"
  defp kind_str(:counted_hash_set), do: "counted_hash_set"
  defp kind_str(:sorted_set), do: "sorted_set"

  defp compile_node_acc(prefix, map, reset?, acc) when is_map(map) and not is_struct(map) do
    compile_kv_collection(prefix, :hash_map, map, reset?, acc)
  end

  defp compile_node_acc(prefix, list, _reset?, acc) when is_list(list) do
    acc = [{:reset_col, prefix, "array_list"} | acc]
    compile_list_elems(list, prefix, :array_list, 0, acc)
  end

  defp compile_node_acc(prefix, %Collection{kind: kind, data: data}, reset?, acc)
       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
    compile_kv_collection(prefix, kind, data, reset?, acc)
  end

  defp compile_node_acc(prefix, %Collection{kind: kind, data: list}, reset?, acc)
       when kind in [:array_list, :linked_array_list] and is_list(list) do
    k_str = kind_str(kind)
    op = if reset?, do: {:reset_col, prefix, k_str}, else: {:init_col, prefix, k_str}
    compile_list_elems(list, prefix, kind, 0, [op | acc])
  end

  defp compile_node_acc(prefix, %Collection{kind: kind, data: members}, reset?, acc)
       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
    k_str = kind_str(kind)
    member_list = Enum.to_list(members)

    if member_list == [] do
      op = if reset?, do: {:reset_col, prefix, k_str}, else: {:init_col, prefix, k_str}
      [op | acc]
    else
      acc = if reset?, do: [{:reset_col, prefix, k_str} | acc], else: acc

      Enum.reduce(member_list, acc, fn m, a ->
        member_str = to_string(m)
        [{:put, prefix <> Selector.format_step(kind, member_str), member_str} | a]
      end)
    end
  end

  defp compile_node_acc(prefix, %MapSet{} = set, reset?, acc) do
    compile_node_acc(
      prefix,
      %Collection{kind: :counted_hash_set, data: MapSet.to_list(set)},
      reset?,
      acc
    )
  end

  defp compile_node_acc(prefix, nil, _reset?, acc) do
    [{:rm, prefix} | acc]
  end

  defp compile_node_acc(prefix, scalar, _reset?, acc) do
    [{:put, prefix, scalar} | acc]
  end

  defp compile_kv_collection(prefix, kind, map, reset?, acc)
       when is_map(map) and not is_struct(map) do
    k_str = kind_str(kind)

    if map_size(map) == 0 do
      op = if reset?, do: {:reset_col, prefix, k_str}, else: {:init_col, prefix, k_str}
      [op | acc]
    else
      acc = if reset?, do: [{:reset_col, prefix, k_str} | acc], else: acc

      :maps.fold(
        fn k, v, a ->
          compile_node_acc(prefix <> Selector.format_step(kind, k), v, false, a)
        end,
        acc,
        map
      )
    end
  end

  defp compile_kv_collection(prefix, kind, enumerable, reset?, acc) do
    k_str = kind_str(kind)
    entries = Enum.to_list(enumerable)

    if entries == [] do
      op = if reset?, do: {:reset_col, prefix, k_str}, else: {:init_col, prefix, k_str}
      [op | acc]
    else
      acc = if reset?, do: [{:reset_col, prefix, k_str} | acc], else: acc

      Enum.reduce(entries, acc, fn {k, v}, a ->
        compile_node_acc(prefix <> Selector.format_step(kind, k), v, false, a)
      end)
    end
  end

  defp compile_list_elems([], _prefix, _kind, _idx, acc), do: acc

  defp compile_list_elems([elem | rest], prefix, kind, idx, acc) do
    acc = compile_node_acc(prefix <> Selector.format_step(kind, idx), elem, false, acc)
    compile_list_elems(rest, prefix, kind, idx + 1, acc)
  end
end
