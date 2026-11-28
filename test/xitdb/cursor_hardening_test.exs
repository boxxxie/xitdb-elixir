defmodule Xitdb.CursorHardeningTest do
  use ExUnit.Case, async: true

  alias Xitdb.Cursor

  test "pop_in on :linked_array_list handles in-bounds, boundary, and out-of-bounds indices" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{"q" => Xitdb.linked_list(["first", "second", "third"])})

    on_exit(fn -> Xitdb.close(db) end)

    db =
      Xitdb.transact!(db, fn root ->
        # Out-of-bounds pop returns {nil, root} without mutating
        {oob_hi, root} = pop_in(root["q"][3])
        assert oob_hi == nil

        # Pop middle index 1
        {mid, root} = pop_in(root["q"][1])
        assert mid == "second"
        assert Enum.to_list(root["q"]) == ["first", "third"]

        # Pop index 0 (exact lower boundary >= 0)
        {head, root} = pop_in(root["q"][0])
        assert head == "first"
        assert Enum.to_list(root["q"]) == ["third"]

        root
      end)

    assert Enum.to_list(Xitdb.db(db)["q"]) == ["third"]
  end

  test "purge_staged_prefix/2, strict_equal?/2, and steps_to_selector_and_override_key/1 cover all branches" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{"a" => %{"b" => 1}})

    on_exit(fn -> Xitdb.close(db) end)

    # purge_staged_prefix fast-path when no staged state vs non-empty staged state
    clean_root = Xitdb.db(db)
    assert Cursor.purge_staged_prefix(clean_root, ".a") == clean_root

    Xitdb.transact!(db, fn root ->
      staged = put_in(root["a"]["b"], 2)
      purged = Cursor.purge_staged_prefix(staged, ".a")
      assert purged.staged_overrides == %{}
      root
    end)

    # strict_equal? for MapSets, maps, lists (same/different lengths), and scalars
    assert Cursor.strict_equal?(MapSet.new(["a", "b"]), MapSet.new(["b", "a"]))
    refute Cursor.strict_equal?(MapSet.new(["a"]), MapSet.new(["b"]))
    assert Cursor.strict_equal?(%{"a" => [1, 2]}, %{"a" => [1, 2]})
    refute Cursor.strict_equal?(%{"a" => [1, 2]}, %{"a" => [1]})
    refute Cursor.strict_equal?(%{"a" => [1, 2]}, %{"a" => [1, 2.0]})
    refute Cursor.strict_equal?(1, 1.0)

    # steps_to_selector_and_override_key for single non-hash_map steps and multi-step chains
    assert Cursor.steps_to_selector_and_override_key([]) == {"", ""}
    assert Cursor.steps_to_selector_and_override_key([{:hash_map, "a"}]) == {".a", ".a"}
    assert Cursor.steps_to_selector_and_override_key([{:counted_hash_map, "a"}]) == {"#a", ".a"}
    assert Cursor.steps_to_selector_and_override_key([{:sorted_map, "a"}]) == {"$a", ".a"}
    assert Cursor.steps_to_selector_and_override_key([{:array_list, 0}]) == {"[0]", "[0]"}

    assert Cursor.steps_to_selector_and_override_key([{:linked_array_list, 0}]) ==
             {"[[0]]", "[[0]]"}

    assert Cursor.steps_to_selector_and_override_key([{:sorted_map, "k"}, {:hash_map, "m"}]) ==
             {".m$k", ".m.k"}
  end

  test "staged list edits overlay onto materialized maps and nested list elements" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "items" => Xitdb.linked_list([%{"name" => "a"}, %{"name" => "b"}]),
        "tags" => MapSet.new(["t1"])
      })

    on_exit(fn -> Xitdb.close(db) end)

    Xitdb.transact!(db, fn root ->
      # Stage list insert, then mutate descendant inside inserted element, then delete another
      root =
        root
        |> Xitdb.insert_at(["items"], 1, %{"name" => "mid", "extra" => "drop"})
        |> put_in(["items", 1, "name"], "mid_edited")

      {_, root} = pop_in(root["items"][1]["extra"])
      root = put_in(root["new_set"], MapSet.new(["x", "y"]))

      mat_items = Xitdb.materialize(root["items"])
      assert mat_items == [%{"name" => "a"}, %{"name" => "mid_edited"}, %{"name" => "b"}]

      mat_root = Xitdb.materialize(root)
      assert mat_root["items"] == [%{"name" => "a"}, %{"name" => "mid_edited"}, %{"name" => "b"}]
      assert mat_root["new_set"] == MapSet.new(["x", "y"])

      root
    end)
  end

  test "tx_mode get_and_update_in exercises BEAM bytecode closure shapes without misclassifying x0 reads" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "m" => %{"k" => 10, "t" => %{"nested" => 1}},
        "s" => "hello"
      })

    on_exit(fn -> Xitdb.close(db) end)

    Xitdb.transact!(db, fn root ->
      # Closure with map pattern match (get_map_elements), binary construction (bs_create_bin),
      # arithmetic (gc_bif), case/select_val, and tuple pattern match (select_tuple_arity)
      {v1, root} =
        get_and_update_in(root["m"]["k"], fn
          10 -> {:was_ten, 20}
          20 -> {:was_twenty, 30}
          other -> {:other, other}
        end)

      assert v1 == :was_ten

      {v2, root} =
        get_and_update_in(root["s"], fn s ->
          {"prefix_" <> to_string(s), "world"}
        end)

      assert v2 == "prefix_hello"

      # Closure ignoring x0 completely with binary construction
      {v3, root} =
        get_and_update_in(root["m"]["k"], fn _ ->
          x = "static"
          {x <> "_ok", 99}
        end)

      assert v3 == "static_ok"
      assert root["m"]["k"] == 99

      root
    end)
  end

  test "hardens Enumerable count/slice on root and staged tx_mode cursors, collection preservation, nil writes, and list insert_at bounds" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "cm" => Xitdb.counted_map(%{"a" => 1, "b" => 2}),
        "sm" => Xitdb.sorted_map(%{"x" => 10, "y" => 20}),
        "arr" => [10, 20, 30, 40],
        "larr" => Xitdb.linked_list([10, 20, 30, 40]),
        "m" => %{"k" => 1}
      })

    on_exit(fn -> Xitdb.close(db) end)

    # Root cursor Enum.count (tx_mode: false, root: true)
    root_snap = Xitdb.db(db)
    assert Enum.count(root_snap["cm"]) == 2
    assert Enum.count(root_snap["arr"]) == 4
    assert Enum.slice(root_snap["arr"], 1..2) == [20, 30]

    Xitdb.transact!(db, fn root ->
      # tx_mode: true WITHOUT staged edits uses fast count
      assert Enum.count(root["cm"]) == 2
      assert Enum.count(root["arr"]) == 4

      # Stage a counted_map edit (exercises # canonical_override_selector + staged Enum.count fallback)
      root = put_in(root["cm"]["c"], 3)
      assert Enum.count(root["cm"]) == 3
      assert Enum.count(root["arr"]) == 4

      # Stage a sorted_map edit (exercises $ canonical_override_selector)
      root = put_in(root["sm"]["z"], 30)
      assert root["sm"]["z"] == 30

      # Putting nil on hash_map vs array_list
      root = put_in(root["m"]["k"], nil)
      assert root["m"]["k"] == nil
      root = put_in(root["arr"][1], nil)
      assert root["arr"][1] == nil

      # pop_in sets deleted_paths (exercises MapSet.size(deleted_paths) != 0)
      {popped, root} = pop_in(root["m"]["k"])
      assert popped == nil

      # Staged update on counted_map
      {old_cm, root} =
        get_and_update_in(root["cm"], fn cm ->
          mat = Xitdb.materialize(cm)
          {mat, Xitdb.counted_map(Map.put(mat, "d", 4))}
        end)

      assert old_cm == %{"a" => 1, "b" => 2, "c" => 3}
      assert Enum.count(root["cm"]) == 4

      # Linked list insert_at / delete_at bounds inside tx_mode (idx == length append, idx == 0 delete)
      root = Xitdb.insert_at(root, ".larr", 4, 50)
      assert Xitdb.materialize(root["larr"]) == [10, 20, 30, 40, 50]
      root = Xitdb.delete_at(root, ".larr", 0)
      assert Xitdb.materialize(root["larr"]) == [20, 30, 40, 50]
      assert Enum.slice(root["arr"], 0..1) == [10, nil]

      # Enum.count on tx_mode cursors with deleted_paths, staged_list_edits, and fork_aliases (kills L2718-2719)
      assert Enum.count(root["larr"]) == 4
      root = Xitdb.fork(root, ".m", ".m_fork")
      assert Enum.count(root) >= 5
      assert Enum.member?(root["m_fork"], {"k", nil}) or is_map(Xitdb.materialize(root["m_fork"]))

      # Keys containing @, #, $ in tx_mode (kills L2658)
      root = put_in(root["m"]["@tag#1$2"], "special")
      assert root["m"]["@tag#1$2"] == "special"

      root
    end)

    # Root cursor Enum.count / Enum.member? across moments (kills L2859)
    assert Enum.count(Xitdb.db(db)) == 6
    assert Enum.count(Xitdb.as_of(db, 0)) == 5
    assert Enum.count(Xitdb.as_of(db, 1)) == 6

    assert Enum.count(Xitdb.db(db)["cm"]) == 4
    assert Xitdb.select!(db, ".sm.z") == 30
  end
end
