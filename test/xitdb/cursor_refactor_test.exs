defmodule Xitdb.CursorRefactorTest do
  use ExUnit.Case, async: true

  test "Access pipeline preserves op ordering and read-your-own-writes" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{
        "users" => %{
          "alice" => %{
            "age" => 30,
            "temp" => "secret",
            "roles" => Xitdb.linked_list(["staff"])
          }
        }
      })

    db =
      Xitdb.transact!(db, fn root ->
        {"secret", root} = pop_in(root["users"]["alice"]["temp"])
        assert root["users"]["alice"]["temp"] == nil

        root = put_in(root["users"]["alice"]["age"], 31)
        assert root["users"]["alice"]["age"] == 31

        root
        |> update_in(["users", "alice", "age"], &(&1 + 1))
        |> Xitdb.insert_at(["users", "alice", "roles"], 0, "owner")
        |> Xitdb.fork(".users.alice", ".backups.alice")
      end)

    assert db["users"]["alice"]["temp"] == nil
    assert db["users"]["alice"]["age"] == 32
    assert Enum.to_list(db["users"]["alice"]["roles"]) == ["owner", "staff"]
    assert db["backups"]["alice"]["age"] == 32
  end

  test "fetch/2 resolves tag_id: -1 before integer index lookup when tx_mode: false" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"items" => ["first", "second"]})

    assert Access.fetch(Xitdb.as_of(db, 0), 0) == :error
    assert Xitdb.as_of(db, 0)["items"][0] == "first"
  end

  test "Enum.slice handles stepped and empty ranges without overshooting collection bounds" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"items" => ["a", "b", "c", "d", "e"]})

    assert Enum.slice(db["items"], 0..4//2) == ["a", "c", "e"]
    assert Enum.slice(db["items"], 1..3//2) == ["b", "d"]
    assert Enum.slice(db["items"], 4..4//2) == ["e"]
    assert Enum.slice(db["items"], 3..1//1) == []
  end

  test "Inspect renders child cursors without quotes and handles unresolved cursors safely" do
    empty_db = Xitdb.open!(backend: :memory)
    assert inspect(Xitdb.as_of(empty_db, 0)) =~ "preview: []"

    db = Xitdb.transact!(empty_db, %{"users" => %{"alice" => %{"age" => 30}}})
    assert inspect(Xitdb.as_of(db, 99)) =~ "#Xitdb.Cursor<unresolved (:moment_out_of_range)>"

    rendered = inspect(Xitdb.db(db))
    assert rendered =~ ~s({"users", <hash_map>})
    refute rendered =~ ~s(:"<hash_map>")

    closed_cur = Xitdb.as_of(db, 0)
    :ok = Xitdb.close(db)
    assert inspect(closed_cur) =~ "#Xitdb.Cursor<unresolved (:closed)>"
  end

  test "mutating %Xitdb{} directly outside transact/3 raises ArgumentError" do
    db = Xitdb.open!(backend: :memory)

    assert_raise ArgumentError, ~r/cannot mutate %Xitdb{} directly/, fn ->
      put_in(db["users"], %{})
    end

    assert_raise ArgumentError, ~r/cannot mutate %Xitdb{} directly/, fn ->
      pop_in(db["users"])
    end
  end

  test "as_of/2 handles negative and positive out-of-bounds moments consistently" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{"k" => "v"})

    err_neg =
      assert_raise Xitdb.Error, fn ->
        Xitdb.as_of(db, -99)
      end

    assert err_neg.reason == :moment_out_of_range

    oob = Xitdb.as_of(db, 99)
    assert inspect(oob) == "#Xitdb.Cursor<unresolved (:moment_out_of_range)>"

    for op <- [
          fn -> oob["k"] end,
          fn -> Xitdb.materialize(oob) end,
          fn -> Enum.to_list(oob) end
        ] do
      err = assert_raise Xitdb.Error, op
      assert err.reason == :moment_out_of_range
    end
  end

  test "Access auto-vivification and staged %Xitdb.Collection{} read-your-own-writes inside transact!" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{"existing" => %{"old" => 1}})

    test_pid = self()

    db =
      Xitdb.transact!(db, fn root ->
        root = put_in(root["a"]["b"]["c"], 42)
        assert root["a"]["b"]["c"] == 42

        root = put_in(root["existing"]["nested"]["leaf"], 7)
        assert root["existing"]["old"] == 1
        assert root["existing"]["nested"]["leaf"] == 7

        {1, root} = pop_in(root["existing"]["old"])
        assert root["existing"]["old"] == nil

        {_, root} = pop_in(root["existing"])
        root = put_in(root["existing"]["fresh"]["leaf"], 9)
        assert root["existing"]["old"] == nil
        assert root["existing"]["nested"] == nil
        assert root["existing"]["fresh"]["leaf"] == 9

        root = put_in(root["s"], Xitdb.sorted_map(%{"b" => 2, "a" => 1}))
        send(test_pid, {:in_tx_sorted, root["s"]["a"], Enum.to_list(root["s"])})
        root
      end)

    assert_receive {:in_tx_sorted, 1, [{"a", 1}, {"b", 2}]}
    assert Xitdb.db(db)["a"]["b"]["c"] == 42
    assert Xitdb.db(db)["existing"]["old"] == nil
    assert Xitdb.db(db)["existing"]["fresh"]["leaf"] == 9
    assert Xitdb.db(db)["s"].tag == :sorted_map
    assert Enum.to_list(Xitdb.db(db)["s"]) == [{"a", 1}, {"b", 2}]
  end

  test "Enum.slice on :array_list respects non-zero offset and step" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{"nums" => [10, 20, 30, 40, 50, 60]})

    nums_cursor = Xitdb.db(db)["nums"]
    assert nums_cursor.tag == :array_list
    assert Enum.slice(nums_cursor, 2..4) == [30, 40, 50]
    assert Enum.slice(nums_cursor, 1..5//2) == [20, 40, 60]
  end

  test "Enumerable.member?/2 enforces strict type and scalar equality for maps and sets" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "nums" => %{"n" => 1},
        "tags" => Xitdb.counted_set(["tag1", "tag2"])
      })

    nums_cur = Xitdb.db(db)["nums"]
    tags_cur = Xitdb.db(db)["tags"]

    assert Enum.member?(nums_cur, {"n", 1}) == true
    assert Enum.member?(nums_cur, {"n", 1.0}) == false
    assert Enum.member?(nums_cur, {:n, 1}) == false

    assert Enum.member?(tags_cur, "tag1") == true
    assert Enum.member?(tags_cur, 123) == false
  end

  test "Enumerable adaptive chunking preserves exact order and suspend/halt semantics across boundaries" do
    db = Xitdb.open!(backend: :memory)

    for n <- [0, 1, 10, 31, 32, 33, 160, 416, 500] do
      entries =
        for i <- 0..(n - 1)//1 do
          key = String.pad_leading(Integer.to_string(i), 4, "0")
          {key, i}
        end

      db_n =
        Xitdb.transact!(db, %{
          "sorted_map" => Xitdb.sorted_map(entries),
          "array_list" => Enum.map(entries, fn {_k, v} -> v end),
          "hash_map" => Map.new(entries),
          "sorted_set" => Xitdb.sorted_set(Enum.map(entries, fn {k, _v} -> k end))
        })

      root = Xitdb.db(db_n)
      expected_keys = Enum.map(entries, &elem(&1, 0))
      expected_ints = Enum.map(entries, &elem(&1, 1))

      assert Enum.to_list(root["sorted_map"]) == entries
      assert Enum.to_list(root["array_list"]) == expected_ints
      assert Enum.sort(Enum.to_list(root["hash_map"])) == Enum.sort(entries)
      assert Enum.to_list(root["sorted_set"]) == expected_keys

      take_n = min(10, n)
      assert root["sorted_map"] |> Stream.take(10) |> Enum.to_list() == Enum.take(entries, take_n)

      assert root["array_list"] |> Stream.take(10) |> Enum.to_list() ==
               Enum.take(expected_ints, take_n)

      # :suspend handling via Stream.zip/2
      assert Enum.zip(root["sorted_map"], root["array_list"]) ==
               Enum.zip(entries, expected_ints)

      # :halt handling via Enum.find/2
      if n > 0 do
        target_idx = div(n, 2)
        target_key = String.pad_leading(Integer.to_string(target_idx), 4, "0")

        assert Enum.find(root["sorted_map"], fn {k, _v} -> k == target_key end) ==
                 {target_key, target_idx}
      else
        assert Enum.find(root["sorted_map"], fn _ -> true end) == nil
      end
    end
  end

  describe "tx_mode virtual write cursor staging and adaptive steps" do
    test "put_in, update_in, get_and_update_in, pop_in across existing and missing paths" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      Xitdb.transact!(db, fn root ->
        root
        |> put_in(["existing", "nested", "count"], 10)
        |> put_in(["existing", "nested", "label"], "v1")
        |> put_in(["arr"], [10, %{"name" => "first"}, %{"name" => "last"}])
      end)

      result =
        Xitdb.transact!(db, fn root ->
          {old_existing, root} =
            get_and_update_in(root["existing"]["nested"]["label"], fn old ->
              {old, "v2"}
            end)

          {old_missing, root} =
            get_and_update_in(root["brand_new"]["deep"]["key"], fn old ->
              {old, "created"}
            end)

          root =
            root
            |> update_in(["existing", "nested", "count"], &(&1 + 5))
            |> update_in(["existing", "nested", "cond"], fn v ->
              if is_nil(v), do: "was_nil", else: "other"
            end)
            |> update_in(["existing", "nested", "count"], fn v ->
              if v == 15, do: 25, else: 0
            end)
            |> put_in(["new_branch", "a", "b"], 42)
            |> put_in(["arr", 0], 100)
            |> put_in(["arr", -1, "name"], "updated_last")

          {popped_arr_nested, root} = pop_in(root["arr"][1]["name"])
          {popped_missing, root} = pop_in(root["never_existed"]["sub"])

          send(
            self(),
            {:tx_results, old_existing, old_missing, popped_arr_nested, popped_missing}
          )

          root
        end)

      assert %Xitdb{} = result
      assert_received {:tx_results, "v1", nil, "first", nil}

      snap = Xitdb.db(db)
      assert snap["existing"]["nested"]["label"] == "v2"
      assert snap["existing"]["nested"]["count"] == 25
      assert snap["existing"]["nested"]["cond"] == "was_nil"
      assert snap["brand_new"]["deep"]["key"] == "created"
      assert snap["new_branch"]["a"]["b"] == 42
      assert snap["arr"][0] == 100
      assert snap["arr"][1]["name"] == nil
      assert snap["arr"][-1]["name"] == "updated_last"
    end

    test "adapts virtual Hash_Map_Key steps for existing counted_map and sorted_map containers" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      Xitdb.transact!(db, fn root ->
        root
        |> put_in(
          ["cmap"],
          Xitdb.counted_map(%{"a" => 1, "nested" => Xitdb.sorted_map(%{"k" => 10})})
        )
        |> put_in(
          ["smap"],
          Xitdb.sorted_map(%{"b" => 2, "inner" => Xitdb.counted_map(%{"x" => 100})})
        )
      end)

      Xitdb.transact!(db, fn root ->
        {popped_cmap, root} = pop_in(root["cmap"]["a"])
        {old_nested_k, root} = get_and_update_in(root["cmap"]["nested"]["k"], &{&1, &1 + 5})

        root =
          root
          |> put_in(["cmap", "c"], 3)
          |> put_in(["cmap", "nested", "m"], 20)
          |> put_in(["smap", "a"], 1)
          |> update_in(["smap", "b"], &(&1 * 10))
          |> put_in(["smap", "inner", "y"], 200)

        # Read-your-writes through virtual + adaptive nif_select fallback
        assert root["cmap"]["nested"]["k"] == 15
        assert root["smap"]["inner"]["x"] == 100

        send(self(), {:container_results, popped_cmap, old_nested_k})
        root
      end)

      assert_received {:container_results, 1, 10}

      snap = Xitdb.db(db)
      assert snap["cmap"].tag == :counted_hash_map
      assert snap["cmap"]["a"] == nil
      assert snap["cmap"]["c"] == 3
      assert snap["cmap"]["nested"].tag == :sorted_map
      assert snap["cmap"]["nested"]["k"] == 15
      assert snap["cmap"]["nested"]["m"] == 20

      assert snap["smap"].tag == :sorted_map
      assert Enum.to_list(snap["smap"]) |> Enum.map(&elem(&1, 0)) == ["a", "b", "inner"]
      assert snap["smap"]["a"] == 1
      assert snap["smap"]["b"] == 20
      assert snap["smap"]["inner"].tag == :counted_hash_map
      assert snap["smap"]["inner"]["x"] == 100
      assert snap["smap"]["inner"]["y"] == 200
    end

    test "get_and_update_in and update_in do not corrupt guarded callbacks or execute user callbacks multiple times" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "existing" => %{"nested" => %{"count" => 10, "other" => 10}}
        })

      on_exit(fn -> Xitdb.close(db) end)
      test_pid = self()

      Xitdb.transact!(db, fn root ->
        {status1, root} =
          get_and_update_in(root["existing"]["nested"]["count"], fn
            v when is_integer(v) and v >= 10 ->
              send(test_pid, {:macro_gavu, v})
              {:incremented, v + 5}

            other ->
              send(test_pid, {:macro_gavu_fallback, other})
              {:reset, 0}
          end)

        {status2, root} =
          get_and_update_in(root, ["existing", "nested", "other"], fn
            v when is_integer(v) and v >= 10 ->
              send(test_pid, {:list_gavu, v})
              {:incremented, v + 7}

            other ->
              send(test_pid, {:list_gavu_fallback, other})
              {:reset, 0}
          end)

        root =
          root
          |> update_in(
            ["existing", "nested", "count"],
            fn v ->
              send(test_pid, {:list_update, v})
              v + 1
            end
          )
          |> then(fn r ->
            update_in(r["existing"]["nested"]["other"], fn v ->
              send(test_pid, {:macro_update, v})
              v + 1
            end)
          end)

        assert status1 == :incremented
        assert status2 == :incremented
        root
      end)

      assert_received {:macro_gavu, 10}
      refute_received {:macro_gavu, _}
      refute_received {:macro_gavu_fallback, _}

      assert_received {:list_gavu, 10}
      refute_received {:list_gavu, _}
      refute_received {:list_gavu_fallback, _}

      assert_received {:list_update, 15}
      refute_received {:list_update, _}

      assert_received {:macro_update, 17}
      refute_received {:macro_update, _}

      snap = Xitdb.db(db)
      assert snap["existing"]["nested"]["count"] == 16
      assert snap["existing"]["nested"]["other"] == 18
    end

    test "adapts tx ops cleanly across intra-tx container replacements and merge_map_callback" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "cmap" => Xitdb.counted_map(%{"keep" => 1}),
          "smap" => Xitdb.sorted_map(%{"keep" => 2})
        })

      on_exit(fn -> Xitdb.close(db) end)

      # 1. Replacing :counted_hash_map with plain :hash_map before another op triggers .Unexpected_Tag
      Xitdb.transact!(db, fn root ->
        root
        |> put_in(["cmap"], %{"a" => 1})
        |> put_in(["cmap", "b"], 2)
        |> put_in(["smap", "x"], 9)
      end)

      snap1 = Xitdb.db(db)
      assert snap1["cmap"].tag == :hash_map
      assert snap1["cmap"]["a"] == 1
      assert snap1["cmap"]["b"] == 2
      assert snap1["cmap"]["keep"] == nil
      assert snap1["smap"].tag == :sorted_map
      assert snap1["smap"]["keep"] == 2
      assert snap1["smap"]["x"] == 9

      # 2. merge_map_callback adapts plain map merges into existing :counted_hash_map and :sorted_map
      Xitdb.transact!(db, %{
        "cmap" => %{"a" => 10},
        "smap" => %{"b" => 20}
      })

      db =
        Xitdb.transact!(db, %{
          "cmap2" => Xitdb.counted_map(%{"k" => 1})
        })

      Xitdb.transact!(db, %{
        "cmap2" => %{"m" => 2},
        "smap" => %{"c" => 30}
      })

      snap2 = Xitdb.db(db)
      assert snap2["cmap2"].tag == :counted_hash_map
      assert snap2["cmap2"]["k"] == 1
      assert snap2["cmap2"]["m"] == 2
      assert snap2["smap"].tag == :sorted_map
      assert snap2["smap"]["keep"] == 2
      assert snap2["smap"]["b"] == 20
      assert snap2["smap"]["c"] == 30

      # 3. merge_map resetting a container to %{} invalidates stale base_moment tag for later ops
      {:ok, db} =
        Xitdb.transact_ops(db, [
          {:merge_map, %{"cmap2" => %{}}},
          {:put, ".cmap2.fresh", 42},
          {:put, ".smap.d", 40}
        ])

      snap3 = Xitdb.db(db)
      assert snap3["cmap2"].tag == :hash_map
      assert snap3["cmap2"]["fresh"] == 42
      assert snap3["cmap2"]["k"] == nil
      assert snap3["smap"].tag == :sorted_map
      assert snap3["smap"]["d"] == 40
    end

    test "indexing or pop_in through on-disk scalars fails instead of masking as nil" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{"scalar" => "hello", "arr" => [1, 2]})

      on_exit(fn -> Xitdb.close(db) end)

      assert {:error, %Xitdb.Error{reason: "Unexpected_Tag"}} = Xitdb.select(db, ".scalar.sub")
      assert {:ok, nil} = Xitdb.select(db, ".arr.sub")

      assert {:error, %Xitdb.Error{reason: "Unexpected_Tag"}} =
               Xitdb.transact(db, fn root -> pop_in(root["scalar"]["sub"]) end)

      assert {:error, %Xitdb.Error{reason: "Unexpected_Tag"}} =
               Xitdb.transact(db, fn root -> pop_in(root, ["scalar", "sub"]) end)

      assert Xitdb.db(db)["scalar"] == "hello"
    end

    test "single-path overwrite or pop+put of nested sorted_map inside counted_map adapts cleanly" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(fn root ->
          put_in(root["cmap"], Xitdb.counted_map(%{"smap" => Xitdb.sorted_map(%{"a" => 1})}))
        end)

      on_exit(fn -> Xitdb.close(db) end)

      Xitdb.transact!(db, fn root ->
        put_in(root["cmap"]["smap"], %{"k" => 2})
      end)

      snap1 = Xitdb.db(db)
      assert snap1["cmap"].tag == :counted_hash_map
      assert snap1["cmap"]["smap"].tag == :hash_map
      assert snap1["cmap"]["smap"]["k"] == 2
      assert snap1["cmap"]["smap"]["a"] == nil

      # Also test pop_in + put_in on a nested sorted_map
      db =
        Xitdb.transact!(db, fn root ->
          put_in(root["cmap"]["smap"], Xitdb.sorted_map(%{"a" => 1}))
        end)

      Xitdb.transact!(db, fn root ->
        {_, root} = pop_in(root["cmap"]["smap"])
        put_in(root["cmap"]["smap"]["k"], 3)
      end)

      snap2 = Xitdb.db(db)
      assert snap2["cmap"]["smap"].tag == :hash_map
      assert snap2["cmap"]["smap"]["k"] == 3
      assert snap2["cmap"]["smap"]["a"] == nil
    end

    test "get_and_update_in wrapping old value in struct, MapSet, or map key never leaks virtual cursor" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{"existing" => %{"nested" => %{"label" => "v1"}}})

      on_exit(fn -> Xitdb.close(db) end)

      Xitdb.transact!(db, fn root ->
        {wrapped_struct, root} =
          get_and_update_in(root["existing"]["nested"]["label"], fn old ->
            {Xitdb.hash_map(%{"prev" => old}), "v2"}
          end)

        assert wrapped_struct == Xitdb.hash_map(%{"prev" => "v1"})

        {wrapped_key_map, root} =
          get_and_update_in(root, ["existing", "nested", "label"], fn old ->
            {%{old => true}, "v3"}
          end)

        assert wrapped_key_map == %{"v2" => true}

        {wrapped_set, root} =
          get_and_update_in(root, ["existing", "nested", "label"], fn old ->
            {MapSet.new([old]), "v4"}
          end)

        assert wrapped_set == MapSet.new(["v3"])
        root
      end)

      assert Xitdb.db(db)["existing"]["nested"]["label"] == "v4"
    end

    test "mismatched integer/string Access keys on maps and lists fail cleanly and do not coerce" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{"map" => %{"k" => 1}, "arr" => [10, 20]})

      on_exit(fn -> Xitdb.close(db) end)

      assert {:error, %Xitdb.Error{reason: :unexpected_tag}} =
               Xitdb.transact(db, fn root -> put_in(root["nonexistent"][0], "x") end)

      assert {:error, %Xitdb.Error{reason: :unexpected_tag}} =
               Xitdb.transact(db, fn root -> put_in(root, ["nonexistent", 0], "x") end)

      assert {:error, %Xitdb.Error{reason: "Unexpected_Tag"}} =
               Xitdb.transact(db, fn root -> put_in(root["arr"]["bad_key"], 99) end)

      assert {:error, %Xitdb.Error{reason: :unexpected_tag}} =
               Xitdb.transact(db, fn root -> pop_in(root["arr"]["bad_key"]) end)

      assert {:error, %Xitdb.Error{reason: :unexpected_tag}} =
               Xitdb.transact(db, fn root ->
                 get_and_update_in(root, ["arr", "bad_key"], fn v -> {v, 99} end)
               end)

      Xitdb.transact!(db, fn root ->
        assert Access.fetch(root["map"], 0) == :error
        assert Access.fetch(root["arr"], "bad_key") == :error
        root
      end)
    end

    test "Xitdb.select preserves strictness for explicit # and $ sigils" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "hmap" => %{"k" => 1},
          "cmap" => Xitdb.counted_map(%{"k" => 2}),
          "smap" => Xitdb.sorted_map(%{"k" => 3})
        })

      on_exit(fn -> Xitdb.close(db) end)

      assert {:ok, 1} = Xitdb.select(db, ".hmap.k")
      assert {:ok, 2} = Xitdb.select(db, ".cmap.k")
      assert {:ok, 3} = Xitdb.select(db, ".smap.k")

      assert {:ok, nil} = Xitdb.select(db, "#hmap.k")
      assert {:ok, nil} = Xitdb.select(db, ".hmap#k")
      assert {:ok, nil} = Xitdb.select(db, ".cmap$k")
      assert {:ok, nil} = Xitdb.select(db, "#smap.k")
      assert {:ok, nil} = Xitdb.select(db, ".smap#k")

      assert {:ok, 2} = Xitdb.select(db, ".cmap#k")
      assert {:ok, 3} = Xitdb.select(db, ".smap$k")
    end

    test "update_in nil branch, deep exception single execution, non-empty staged mismatched keys, and staged ancestor reads" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "a" => %{"b" => %{"c" => %{}}},
          "map" => %{"k" => 1},
          "arr" => [10, 20]
        })

      on_exit(fn -> Xitdb.close(db) end)
      test_pid = self()

      # 1. nil branch is reached on missing_map instead of non-nil cursor branch
      db =
        Xitdb.transact!(db, fn root ->
          root
          |> then(fn r ->
            update_in(r["missing_map"], fn
              nil -> %{"created_fresh" => true}
              cur -> put_in(cur["updated_existing"], true)
            end)
          end)
          |> update_in(["missing_map_2"], fn
            nil -> %{"created_fresh" => true}
            cur -> put_in(cur["updated_existing"], true)
          end)
        end)

      assert Xitdb.db(db)["missing_map"]["created_fresh"] == true
      assert Xitdb.db(db)["missing_map"]["updated_existing"] == nil
      assert Xitdb.db(db)["missing_map_2"]["created_fresh"] == true

      # 2. Raising leaf callback at depth D executes exactly once (no 2^D retry storm)
      assert {:error, %Xitdb.Error{reason: :transaction_exception}} =
               Xitdb.transact(db, fn root ->
                 update_in(root, ["a", "b", "c", "d"], fn v ->
                   send(test_pid, {:leaf_called, v})
                   v + 1
                 end)
               end)

      assert_received {:leaf_called, nil}
      refute_received {:leaf_called, _}

      # 3. Mismatched keys with non-empty staged_overrides + Enum.to_list on missing path
      Xitdb.transact!(db, fn root ->
        root = put_in(root["other"], 1)
        assert Access.fetch(root["map"], 0) == :error
        assert Access.fetch(root["arr"], "bad_key") == :error

        assert_raise Protocol.UndefinedError, fn ->
          update_in(root["nonexistent"], fn cur -> Enum.to_list(cur) end)
        end

        # 4. Staged whole-collection ancestor does not mask deeper staged leaf writes
        root = put_in(root["cmap"], Xitdb.counted_map(%{"a" => 1}))
        root = put_in(root["cmap"]["sub"]["deep"], 99)
        assert root["cmap"]["sub"]["deep"] == 99
        assert Xitdb.materialize(root["cmap"]) == %{"a" => 1, "sub" => %{"deep" => 99}}
        root
      end)

      assert Xitdb.db(db)["cmap"]["a"] == 1
      assert Xitdb.db(db)["cmap"]["sub"]["deep"] == 99
    end
  end

  describe "Enumerable fast-path heads" do
    test "direct count/1 and member?/2 heads handle resolved sets, maps, lists, and non-binary candidates" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      db =
        Xitdb.transact!(
          db,
          %{
            "hset" => Xitdb.hash_set(["alpha", "beta"]),
            "cset" => Xitdb.counted_set(["one", "two", "three"]),
            "sset" => Xitdb.sorted_set(["x", "y"]),
            "smap" => Xitdb.sorted_map(a: 1, b: 2),
            "arr" => [10, 20, 30, 40]
          },
          doc: "enumerable-fast-paths"
        )

      snap = Xitdb.db(db)

      for {key, hit, miss, expected_count} <- [
            {"hset", "alpha", "gamma", 2},
            {"cset", "two", "four", 3},
            {"sset", "y", "z", 2}
          ] do
        resolved = Xitdb.Cursor.ensure_resolved(snap[key])
        assert resolved.tx_mode == false
        assert resolved.root == false
        assert resolved.tag_id in [11, 13, 15]

        # Exercise both resolved (direct head) and unresolved cursors
        assert Enum.count(resolved) == expected_count
        assert Enum.count(snap[key]) == expected_count
        assert Enum.member?(resolved, hit) == true
        assert Enum.member?(resolved, miss) == false
        assert Enum.member?(resolved, 123) == false
        assert Enum.member?(resolved, nil) == false
        assert Enum.member?(snap[key], hit) == true
        assert Enum.member?(snap[key], miss) == false
        assert Enum.member?(snap[key], :atom_candidate) == false
      end

      resolved_smap = Xitdb.Cursor.ensure_resolved(snap["smap"])
      assert resolved_smap.tag_id > 0
      assert Enum.count(resolved_smap) == 2
      assert Enum.member?(resolved_smap, {"a", 1}) == true
      assert Enum.member?(resolved_smap, {"a", 2}) == false

      resolved_arr = Xitdb.Cursor.ensure_resolved(snap["arr"])
      assert resolved_arr.tag_id > 0
      assert Enum.count(resolved_arr) == 4

      # Exercise resolved vs unresolved root cursor (tag_id transitions -1 -> 4, root: true)
      unresolved_root = Xitdb.as_of(db, 0)
      assert unresolved_root.root == true
      assert unresolved_root.tag_id == -1
      resolved_root = Xitdb.Cursor.ensure_resolved(unresolved_root)
      assert resolved_root.root == true
      assert resolved_root.tag_id > 0

      assert Enum.count(unresolved_root) == 5
      assert Enum.count(resolved_root) == 5
      assert Enum.count(snap) == 5
      assert Enum.member?(unresolved_root, {"smap", %{"a" => 1, "b" => 2}})
      assert Enum.member?(resolved_root, {"smap", %{"a" => 1, "b" => 2}})
      refute Enum.member?(unresolved_root, {"__tx", %{"doc" => "enumerable-fast-paths"}})
      refute Enum.member?(resolved_root, {"__tx", %{"doc" => "enumerable-fast-paths"}})
    end
  end

  describe "Slice 01 bug regressions (BUG-01-01 .. BUG-01-10)" do
    test "BUG-01-01: rolls back file_size and Root_Header after savepoint, fork, and 0-moment failures" do
      empty_db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(empty_db) end)
      {:ok, empty_info} = Xitdb.info(empty_db)

      assert {:error, %Xitdb.Error{}} =
               Xitdb.transact_ops(empty_db, [
                 {:put, ".big", String.duplicate("x", 4096)},
                 {:savepoint},
                 {:rm, ".missing"}
               ])

      assert Xitdb.info(empty_db) == {:ok, empty_info}
      assert Xitdb.materialize(empty_db) == %{}

      db = Xitdb.transact!(empty_db, %{"seed" => %{"a" => 1}})
      {:ok, seeded_info} = Xitdb.info(db)

      assert {:error, %Xitdb.Error{}} =
               Xitdb.transact_ops(db, [
                 {:put, ".big", String.duplicate("y", 4096)},
                 {:fork, ".seed", ".seed_copy"},
                 {:rm, ".does_not_exist"}
               ])

      assert Xitdb.info(db) == {:ok, seeded_info}
      assert Xitdb.db(db)["seed_copy"] == nil
      assert Xitdb.db(db)["big"] == nil
    end

    test "BUG-01-02: adapts nested collections, fork chains, and 0-moment DB paths" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      db =
        Xitdb.transact!(db, fn root ->
          root
          |> put_in(["smap"], Xitdb.counted_map(%{"inner" => Xitdb.sorted_map(%{"x" => 1})}))
          |> put_in(["smap", "inner", "y"], 2)
          |> Xitdb.fork(".smap", ".smap_copy")
          |> put_in(["smap_copy", "inner", "z"], 3)
          |> put_in(["ll"], Xitdb.linked_list(["a", "b"]))
          |> put_in(["ll", 1], "b2")
        end)

      snap = Xitdb.db(db)
      assert snap["smap"].tag == :counted_hash_map
      assert snap["smap"]["inner"].tag == :sorted_map
      assert snap["smap"]["inner"]["y"] == 2
      assert snap["smap_copy"].tag == :counted_hash_map
      assert snap["smap_copy"]["inner"]["z"] == 3
      assert snap["ll"].tag == :linked_array_list
      assert Enum.to_list(snap["ll"]) == ["a", "b2"]
    end

    test "BUG-01-03: macro put_in/update_in and unmodified cursor returns execute leaf O(1) times" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "a" => %{"b" => %{"c" => %{"d" => %{"leaf" => 1}}}},
          "users" => %{"alice" => %{"score" => 10}}
        })

      on_exit(fn -> Xitdb.close(db) end)
      pid = self()

      db =
        Xitdb.transact!(db, fn root ->
          root =
            put_in(
              root["users"]["alice"]["score"],
              (
                send(pid, :put_macro_eval)
                99
              )
            )

          root =
            update_in(root, ["a", "b", "c", "d"], fn cur ->
              send(pid, :unmodified_cur_leaf)
              cur
            end)

          root
        end)

      assert_received :put_macro_eval
      refute_received :put_macro_eval
      assert_received :unmodified_cur_leaf
      refute_received :unmodified_cur_leaf
      assert Xitdb.db(db)["users"]["alice"]["score"] == 99
    end

    test "BUG-01-04: rejects snapshot or foreign cursor assignment without wiping staged_ops" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{"users" => %{"u0" => %{"name" => "Ada"}}})

      on_exit(fn -> Xitdb.close(db) end)
      snap_u0 = Xitdb.db(db)["users"]["u0"]

      assert {:error,
              %Xitdb.Error{
                reason: :transaction_exception,
                details: %{exception: %ArgumentError{message: msg}}
              }} =
               Xitdb.transact(db, fn root ->
                 root = put_in(root["important"], 123)
                 put_in(root["copy"], snap_u0)
               end)

      assert msg =~ "cannot assign a %Xitdb.Cursor"
      assert Xitdb.db(db)["important"] == nil
    end

    test "BUG-01-05: Enumerable raises Xitdb.Error(:closed) on closed handles and inspect stays safe" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "items" => [1, 2, 3],
          "cset" => Xitdb.counted_set(["x"]),
          "cmap" => Xitdb.counted_map(%{"k" => 1})
        })

      root_cur = Xitdb.db(db)
      items_cur = root_cur["items"]
      cset_cur = root_cur["cset"]
      cmap_cur = root_cur["cmap"]
      :ok = Xitdb.close(db)

      assert_raise Xitdb.Error, ~r/closed/, fn -> Enum.to_list(items_cur) end
      assert_raise Xitdb.Error, ~r/closed/, fn -> Enum.count(cmap_cur) end
      assert_raise Xitdb.Error, ~r/closed/, fn -> Enum.slice(items_cur, 0..1) end
      assert_raise Xitdb.Error, ~r/closed/, fn -> Enum.member?(cset_cur, "x") end
      assert_raise Xitdb.Error, ~r/closed/, fn -> Enum.member?(cset_cur, 123) end
      assert inspect(root_cur) == "#Xitdb.Cursor<unresolved (:closed)>"
    end

    test "BUG-01-06: apply_staged_overlay resolves staged ancestors and drops nil in Collection maps" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      Xitdb.transact!(db, fn root ->
        root =
          put_in(
            root["users"],
            Xitdb.counted_map(%{
              "alice" => Xitdb.sorted_map(%{"age" => 30, "removed" => nil})
            })
          )

        alice = root["users"]["alice"]
        assert Xitdb.materialize(alice) == %{"age" => 30}
        assert Enum.to_list(alice) == [{"age", 30}]
        root
      end)
    end

    test "BUG-01-07: Enumerable yields child cursors with exact child path_steps in tx_mode" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "users" => %{"alice" => %{"role" => "member"}},
          "items" => [%{"name" => "first"}, %{"name" => "second"}]
        })

      on_exit(fn -> Xitdb.close(db) end)

      db =
        Xitdb.transact!(db, fn root ->
          [{"alice", %Xitdb.Cursor{} = alice_cur}] = Enum.to_list(root["users"])
          %Xitdb.Cursor{} = alice_cur = put_in(alice_cur["role"], "admin")
          [%Xitdb.Cursor{} = second_cur] = Enum.slice(root["items"], 1..1)
          %Xitdb.Cursor{} = s_cur = put_in(second_cur["name"], "second_updated")

          %{
            alice_cur
            | staged_ops: s_cur.staged_ops ++ alice_cur.staged_ops,
              staged_overrides: Map.merge(alice_cur.staged_overrides, s_cur.staged_overrides)
          }
        end)

      snap = Xitdb.db(db)
      assert snap["users"]["alice"]["role"] == "admin"
      assert snap["users"]["role"] == nil
      assert snap["items"][1]["name"] == "second_updated"
    end

    test "BUG-01-08: staged insert_at, delete_at, fork, pop_in, and nested collections stay synchronized" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "arr" => [Xitdb.sorted_map(%{"k" => 1}), Xitdb.counted_map(%{"k" => 2})],
          "ll" => Xitdb.linked_list(["a", "b"]),
          "cmap" => Xitdb.counted_map(%{"u0" => %{"age" => 10}}),
          "smap" => Xitdb.sorted_map(%{"u0" => %{"age" => 20}})
        })

      on_exit(fn -> Xitdb.close(db) end)

      db =
        Xitdb.transact!(db, fn root ->
          root =
            root
            |> Xitdb.insert_at(".ll", 1, "mid")
            |> Xitdb.delete_at(".ll", 0)

          assert root["ll"][-1] == "b"
          assert root["ll"][0] == "mid"

          root = put_in(root["arr"][2], "tail")
          assert root["arr"][-1] == "tail"
          {"tail", root} = pop_in(root["arr"][-1])

          root =
            root
            |> Xitdb.fork(".cmap#u0", ".backups.c_u0")
            |> update_in(["backups", "c_u0", "age"], &(&1 + 5))

          root
        end)

      snap = Xitdb.db(db)
      assert Enum.to_list(snap["ll"]) == ["mid", "b"]
      assert snap["arr"][0].tag == :sorted_map
      assert snap["arr"][1].tag == :counted_hash_map
      assert Enum.count(snap["arr"]) == 2
      assert snap["backups"]["c_u0"]["age"] == 15
    end

    test "BUG-01-09: pinned as_of(db, -1), select @moment/root:true, root chunks, and explicit pull {__tx}" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      big_root =
        Map.new(0..24, fn i ->
          {"k_#{String.pad_leading(Integer.to_string(i), 2, "0")}", i}
        end)

      db =
        Xitdb.transact!(
          db,
          Map.put(big_root, "users", %{"u0" => %{"v" => 0}}),
          doc: "m0"
        )

      snap_m0 = Xitdb.db(db)
      assert snap_m0.moment == 0
      assert Enum.count(snap_m0) == 26
      assert length(Enum.to_list(snap_m0)) == 26
      assert length(Enum.uniq(Enum.to_list(snap_m0))) == 26

      db = Xitdb.transact!(db, fn root -> put_in(root["users"]["u0"]["v"], 1) end, doc: "m1")
      # Pinned snapshot from m0 must not tear to m1
      assert Xitdb.materialize(snap_m0)["users"]["u0"]["v"] == 0
      assert Xitdb.pull!(snap_m0, "{users{u0{v}}}") == %{"users" => %{"u0" => %{"v" => 0}}}

      # select propagates @moment and root: true
      sel_m0 = Xitdb.select!(db, " @0 ")
      assert %Xitdb.Cursor{root: true, moment: 0} = sel_m0
      refute Map.has_key?(Xitdb.materialize(sel_m0), "__tx")
      assert Xitdb.select!(sel_m0, ".users.u0.v") == 0

      # Explicit {__tx} pull remains accessible
      assert {:ok, %{"__tx" => %{"doc" => "m1"}}} = Xitdb.pull(db, "{__tx{doc}}")
      assert {:ok, %{"__tx" => %{"doc" => "m1"}}} = Xitdb.pull(db, "{*, __tx}")

      # Nested >16-key Sorted_Map chunking & slicing with step > 1
      nested_smap =
        Map.new(0..24, fn i ->
          {"s_#{String.pad_leading(Integer.to_string(i), 2, "0")}", i}
        end)

      smap_db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{"sorted" => Xitdb.sorted_map(nested_smap)}, doc: "nested-sm")

      on_exit(fn -> Xitdb.close(smap_db) end)
      smap_snap = Xitdb.db(smap_db)["sorted"]
      assert smap_snap.tag == :sorted_map
      assert Enum.count(smap_snap) == 25
      smap_list = Enum.to_list(smap_snap)
      assert length(smap_list) == 25
      assert length(Enum.uniq(smap_list)) == 25

      assert Enum.slice(smap_snap, 0..9//2) == [
               {"s_00", 0},
               {"s_02", 2},
               {"s_04", 4},
               {"s_06", 6},
               {"s_08", 8}
             ]
    end

    test "BUG-01-10: index_on eviction works on Counted_Hash_Map and Sorted_Map via pop_in and merge_map" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      rules = [
        {:index_on, "cusers", "username", "username->cid"},
        {:index_on, "susers", "username", "username->sid"}
      ]

      db =
        Xitdb.transact!(
          db,
          %{
            "cusers" => Xitdb.counted_map(%{"u1" => Xitdb.counted_map(%{"username" => "alice"})}),
            "susers" => Xitdb.sorted_map(%{"u1" => Xitdb.sorted_map(%{"username" => "bob"})})
          },
          index_rules: rules
        )

      assert Xitdb.db(db)["username->cid"]["alice"] == "u1"
      assert Xitdb.db(db)["username->sid"]["bob"] == "u1"

      db =
        Xitdb.transact!(
          db,
          fn root ->
            {_, root} = pop_in(root["cusers"]["u1"]["username"])
            {_, root} = pop_in(root["susers"]["u1"]["username"])
            root
          end,
          index_rules: rules
        )

      assert Xitdb.db(db)["username->cid"]["alice"] == nil
      assert Xitdb.db(db)["username->sid"]["bob"] == nil
    end

    test "executes put_in, update_in, and get_and_update_in callbacks exactly once and resolves uncached scalars" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      Xitdb.transact!(db, fn root ->
        root =
          put_in(
            root["a"]["b"]["c"],
            (
              send(self(), :put2_eval)
              "v1"
            )
          )

        assert_received :put2_eval
        refute_received :put2_eval

        root =
          put_in(
            root,
            ["a", "b", "d"],
            (
              send(self(), :put3_eval)
              "d1"
            )
          )

        assert_received :put3_eval
        refute_received :put3_eval

        root =
          update_in(root["a"]["b"]["c"], fn old ->
            send(self(), {:upd2, old})
            String.upcase(old)
          end)

        assert_received {:upd2, "v1"}
        refute_received {:upd2, _}

        root =
          update_in(root, ["a", "b", "c"], fn old ->
            send(self(), {:upd3, old})
            old <> "!"
          end)

        assert_received {:upd3, "V1"}
        refute_received {:upd3, _}

        {g2, root} =
          get_and_update_in(root["a"]["b"]["c"], fn old ->
            send(self(), {:gau2, old})
            {old, "v2"}
          end)

        assert g2 == "V1!"
        assert_received {:gau2, "V1!"}
        refute_received {:gau2, _}

        {g3, root} =
          get_and_update_in(root, ["a", "b", "c"], fn old ->
            send(self(), {:gau3, old})
            {old, "v3"}
          end)

        assert g3 == "v2"
        assert_received {:gau3, "v2"}
        refute_received {:gau3, _}

        root
      end)

      assert Xitdb.db(db)["a"]["b"]["c"] == "v3"
      assert Xitdb.db(db)["a"]["b"]["d"] == "d1"

      db_scalar =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "users" => %{"alice" => %{"label" => "hello", "score" => 15}}
        })

      on_exit(fn -> Xitdb.close(db_scalar) end)

      Xitdb.transact!(db_scalar, fn root ->
        {seen_label, root} =
          get_and_update_in(root["users"]["alice"]["label"], fn old ->
            send(self(), {:scalar_gau, old})
            {old, if(is_map(old) or is_nil(old), do: "fallback", else: "real:" <> old)}
          end)

        root =
          update_in(root["users"]["alice"]["score"], fn old ->
            send(self(), {:scalar_upd, old})
            if old == 15, do: 25, else: 0
          end)

        send(self(), {:seen_label, seen_label})
        root
      end)

      assert_received {:scalar_gau, "hello"}
      refute_received {:scalar_gau, _}
      assert_received {:scalar_upd, 15}
      refute_received {:scalar_upd, _}
      assert_received {:seen_label, "hello"}

      snap = Xitdb.db(db_scalar)
      assert snap["users"]["alice"]["label"] == "real:hello"
      assert snap["users"]["alice"]["score"] == 25
    end

    test "supports partial resolution followed by put_in and write-then-read in the same tx" do
      db =
        Xitdb.open!(backend: :memory)
        |> Xitdb.transact!(%{
          "users" => %{"alice" => %{"score" => 10, "profile" => %{"role" => "member"}}}
        })

      on_exit(fn -> Xitdb.close(db) end)

      db1 =
        Xitdb.transact!(db, fn root ->
          alice = root["users"]["alice"]
          assert alice.tx_mode == true
          alice = put_in(alice["profile"]["bio"], "hello")
          assert alice["profile"]["bio"] == "hello"
          assert alice["profile"]["role"] == "member"
          alice
        end)

      assert Xitdb.db(db1)["users"]["alice"]["profile"]["bio"] == "hello"
      assert Xitdb.db(db1)["users"]["alice"]["profile"]["role"] == "member"

      db2 =
        Xitdb.transact!(db1, fn root ->
          root = put_in(root["users"]["alice"]["score"], 100)
          assert root["users"]["alice"]["score"] == 100

          root = update_in(root["users"]["alice"]["score"], &(&1 + 50))
          assert root["users"]["alice"]["score"] == 150
          root
        end)

      assert Xitdb.db(db2)["users"]["alice"]["score"] == 150
    end

    test "Enum.slice with step > 1, root chunked enumeration, and Enumerable.count on closed db" do
      db = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(db) end)

      big_root =
        Map.new(0..24, fn i ->
          {"k_#{String.pad_leading(Integer.to_string(i), 2, "0")}", i}
        end)

      db =
        Xitdb.transact!(
          db,
          Map.merge(big_root, %{
            "nums" => Enum.to_list(0..9),
            "counted" => Xitdb.counted_map(%{"a" => 1, "b" => 2}),
            "sorted" =>
              Xitdb.sorted_map(
                Map.new(0..24, fn i ->
                  {"s_#{String.pad_leading(Integer.to_string(i), 2, "0")}", i}
                end)
              )
          }),
          doc: "slice-and-count"
        )

      assert Enum.slice(Xitdb.db(db)["nums"], 0..9//2) == [0, 2, 4, 6, 8]

      assert Enum.slice(Xitdb.db(db)["sorted"], 0..9//2) ==
               [{"s_00", 0}, {"s_02", 2}, {"s_04", 4}, {"s_06", 6}, {"s_08", 8}]

      assert Enum.count(Xitdb.db(db)) == 28
      assert map_size(Enum.into(Xitdb.db(db), %{})) == 28
      assert Enum.count(Xitdb.db(db)["sorted"]) == 25
      assert map_size(Enum.into(Xitdb.db(db)["sorted"], %{})) == 25

      counted_cur = Xitdb.db(db)["counted"]
      sorted_cur = Xitdb.db(db)["sorted"]
      root_cur = Xitdb.db(db)
      :ok = Xitdb.close(db)

      assert_raise Xitdb.Error, ~r/closed/, fn -> Enumerable.count(counted_cur) end
      assert_raise Xitdb.Error, ~r/closed/, fn -> Enumerable.slice(sorted_cur) end
      assert_raise Xitdb.Error, ~r/closed/, fn -> Enumerable.count(root_cur) end
    end
  end
end
