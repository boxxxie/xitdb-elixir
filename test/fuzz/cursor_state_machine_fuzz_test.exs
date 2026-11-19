defmodule Xitdb.Fuzz.CursorStateMachineFuzzTest do
  use ExUnit.Case, async: true
  use ExFuzz

  alias Xitdb
  alias Xitdb.Selector

  @moduletag timeout: 2000

  @top_keys ["users", "alice", "bob", "a.b", "x@y", "k\\1", "q\"2", "items"]
  @sub_keys ["alice", "bob", "a.b", "x@y", "k\\1", "q\"2", "score", "meta"]

  fuzz "bytecode-driven stateful Cursor and Tx operations match Elixir reference oracle across moments",
       data <- binary(),
       seeds: [
         <<0, 0, 1, 1, 0, 1, 3, 2, 3, 4, 0, 0, 4, 1, 0, 5, 0, 0, 6, 0, 0>>,
         <<3, 4, 5, 0, 5, 6, 2, 4, 5, 4, 2, 1, 5, 0, 0, 6, 0, 0>>,
         <<0, 3, 4, 0, 4, 5, 1, 3, 4, 2, 4, 5, 5, 0, 0>>
       ] do
    instructions = decode_instructions(data)
    {:ok, db} = Xitdb.open(backend: :memory)

    try do
      {final_db, final_oracle} =
        Enum.reduce(instructions, {db, %{current: %{}, moments: []}}, &execute_step/2)

      assert_final_state(final_db, final_oracle)
    after
      Xitdb.close(db)
    end
  end

  defp decode_instructions(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.chunk_every(3, 3, [0, 0])
    |> Enum.take(20)
    |> Enum.map(fn [op, a, b] -> {rem(op, 7), a, b} end)
  end

  defp execute_step({0, a, b}, {db, oracle}) do
    k1 = pick(@top_keys, a)
    k2 = pick(@sub_keys, b)
    val = scalar_from(a, b)

    {:ok, next_db} =
      Xitdb.transact(db, fn root ->
        put_in(root[k1][k2], val)
      end)

    next_current =
      Map.update(oracle.current, k1, %{k2 => val}, fn
        existing when is_map(existing) -> Map.put(existing, k2, val)
        _other -> %{k2 => val}
      end)

    {next_db, %{current: next_current, moments: oracle.moments ++ [next_current]}}
  end

  defp execute_step({1, a, b}, {db, oracle}) do
    k1 = pick(@top_keys, a)
    k2 = pick(@sub_keys, b)

    if is_map(Map.get(oracle.current, k1)) do
      {:ok, next_db} =
        Xitdb.transact(db, fn root ->
          update_in(root[k1][k2], fn
            n when is_integer(n) -> n + 1
            _other -> 1
          end)
        end)

      next_current =
        Map.update!(oracle.current, k1, fn sub ->
          Map.update(sub, k2, 1, fn
            n when is_integer(n) -> n + 1
            _other -> 1
          end)
        end)

      {next_db, %{current: next_current, moments: oracle.moments ++ [next_current]}}
    else
      execute_step({0, a, b}, {db, oracle})
    end
  end

  defp execute_step({2, a, b}, {db, oracle}) do
    k1 = pick(@top_keys, a)
    k2 = pick(@sub_keys, b)

    case Map.get(oracle.current, k1) do
      sub when is_map(sub) and is_map_key(sub, k2) ->
        {:ok, next_db} =
          Xitdb.transact(db, fn root ->
            {_popped, next_root} = pop_in(root[k1][k2])
            next_root
          end)

        next_current = Map.put(oracle.current, k1, Map.delete(sub, k2))
        {next_db, %{current: next_current, moments: oracle.moments ++ [next_current]}}

      _ ->
        {db, oracle}
    end
  end

  defp execute_step({3, a, b}, {db, oracle}) do
    k1 = pick(@top_keys, a)
    k2 = pick(@sub_keys, b)
    s1 = scalar_from(a, b)
    s2 = scalar_from(b, a)
    incoming = %{k1 => %{k2 => s1, "_list" => [s1, s2]}}

    {:ok, next_db} = Xitdb.transact(db, incoming)

    merged_sub =
      case Map.get(oracle.current, k1) do
        existing when is_map(existing) ->
          existing |> Map.put(k2, s1) |> Map.put("_list", [s1, s2])

        _ ->
          %{k2 => s1, "_list" => [s1, s2]}
      end

    next_current = Map.put(oracle.current, k1, merged_sub)
    {next_db, %{current: next_current, moments: oracle.moments ++ [next_current]}}
  end

  defp execute_step({4, a, b}, {db, oracle}) do
    val = scalar_from(a, b)

    case get_in(oracle.current, ["_lists", "q"]) do
      nil ->
        {:ok, next_db} = Xitdb.transact(db, %{"_lists" => %{"q" => Xitdb.linked_list([val])}})
        next_current = Map.put(oracle.current, "_lists", %{"q" => [val]})
        {next_db, %{current: next_current, moments: oracle.moments ++ [next_current]}}

      list when is_list(list) ->
        if rem(a, 2) == 0 or list == [] do
          idx = rem(b, length(list) + 1)

          {:ok, next_db} =
            Xitdb.transact(db, fn root ->
              Xitdb.insert_at(root, ["_lists", "q"], idx, val)
            end)

          next_list = List.insert_at(list, idx, val)
          next_current = put_in(oracle.current, ["_lists", "q"], next_list)
          {next_db, %{current: next_current, moments: oracle.moments ++ [next_current]}}
        else
          idx = rem(b, length(list))

          {:ok, next_db} =
            Xitdb.transact(db, fn root ->
              Xitdb.delete_at(root, ["_lists", "q"], idx)
            end)

          next_list = List.delete_at(list, idx)
          next_current = put_in(oracle.current, ["_lists", "q"], next_list)
          {next_db, %{current: next_current, moments: oracle.moments ++ [next_current]}}
        end
    end
  end

  defp execute_step({5, a, b}, {db, %{moments: moments} = oracle}) when moments != [] do
    count = length(moments)
    m1 = rem(a, count)
    m2 = rem(b, count)

    assert Xitdb.materialize(Xitdb.as_of(db, m1)) == Enum.at(moments, m1)
    assert {:ok, diff} = Xitdb.diff_moments(db, m1, m2)
    assert is_list(diff)
    {db, oracle}
  end

  defp execute_step({6, _a, _b}, {db, %{moments: moments} = oracle}) when moments != [] do
    {:ok, compacted} = Xitdb.compact(db)

    try do
      assert Xitdb.materialize(compacted) == oracle.current
    after
      Xitdb.close(compacted)
    end

    {db, oracle}
  end

  defp execute_step(_op, state), do: state

  defp assert_final_state(db, %{current: current}) do
    assert Xitdb.materialize(db) == current

    for {k1, sub} <- current do
      assert Xitdb.materialize(db[k1]) == sub
    end

    if current != %{} do
      assert Xitdb.pull(db, "*") == {:ok, current}
    end

    for {k1, sub} <- current, is_map(sub) do
      for {k2, leaf} <- sub, not is_map(leaf) and not is_list(leaf) do
        assert Xitdb.select(db, Selector.format_path_steps([k1, k2])) == {:ok, leaf}
        assert Xitdb.select(db, [k1, k2]) == {:ok, leaf}
      end
    end
  end

  defp pick(list, byte), do: Enum.at(list, rem(byte, length(list)))

  defp scalar_from(a, b) do
    case rem(a, 5) do
      0 -> b - 128
      1 -> (b - 128) / 4.0 + 0.0
      2 -> rem(b, 2) == 0
      3 -> ""
      4 -> Enum.at(["v1", "a.b", "x\\y\n", "k\"q", "utf8-✓"], rem(b, 5))
    end
  end
end
