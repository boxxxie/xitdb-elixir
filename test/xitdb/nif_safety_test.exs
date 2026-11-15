defmodule Xitdb.NifSafetyTest do
  use ExUnit.Case, async: true

  alias Xitdb.{Error, NIF, Selector}

  test "encodes long atoms (200+ chars) and multiple atoms within one transaction" do
    db = Xitdb.open!(backend: :memory)
    a1 = String.to_atom(String.duplicate("a", 210))
    a2 = String.to_atom(String.duplicate("b", 220))

    assert {:ok, db} = Xitdb.transact_ops(db, [{:put, ".a", a1}, {:put, ".b", a2}])
    assert db["a"] == Atom.to_string(a1)
    assert db["b"] == Atom.to_string(a2)
  end

  test "rejects integers outside signed 64-bit bounds and round-trips i64 extremes" do
    db = Xitdb.open!(backend: :memory)
    max_i64 = 9_223_372_036_854_775_807
    min_i64 = -9_223_372_036_854_775_808

    assert {:error, %Error{}} = Xitdb.transact_ops(db, [{:put, ".over", max_i64 + 1}])
    assert {:error, %Error{}} = Xitdb.transact_ops(db, [{:put, ".under", min_i64 - 1}])

    assert {:ok, db} = Xitdb.transact_ops(db, [{:put, ".max", max_i64}, {:put, ".min", min_i64}])
    assert db["max"] == max_i64
    assert db["min"] == min_i64
  end

  test "rejects malformed transaction op tuples and unknown op atoms without crashing" do
    db = Xitdb.open!(backend: :memory)

    for bad_op <- [
          {:put, ".a"},
          {:append, ".a"},
          {:insert, ".a", 0},
          {:slice, ".a", 0},
          {:fork, ".a"},
          {:init_col, ".a"},
          {:reset_col, ".a"},
          {:merge_map},
          {:merge_map, "not_a_map"},
          {:merge_map, %{nil => "bad_key"}},
          {:merge_map, %{true => "bad_key"}},
          {:rm},
          {:rm_if_exists},
          {:bogus_op, ".a", 1},
          :not_a_tuple
        ] do
      assert {:error, _reason} = NIF.nif_transact(db.db_ref, -1, [bad_op], "")
    end
  end

  test "handles forged and out-of-bounds cursors safely across slot NIFs" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"k" => "v"})

    for {tag_id, val} <- [{99, -5}, {2, 999_999_999}, {2, -100}] do
      assert {:error, _} = NIF.nif_slot_materialize(db.db_ref, tag_id, val, 0)
      assert {:error, _} = NIF.nif_slot_count(db.db_ref, tag_id, val)
      assert {:error, _} = NIF.nif_slot_entries(db.db_ref, tag_id, val, 0, 10)
      assert {:error, _} = NIF.nif_pull(db.db_ref, tag_id, val, "*")
      assert {:error, :invalid_slot} = NIF.nif_slot_get_key(db.db_ref, tag_id, val, "k")
      assert {:error, :invalid_slot} = NIF.nif_slot_get_index(db.db_ref, tag_id, val, 0)
      assert {:error, _} = NIF.nif_slot_contains(db.db_ref, tag_id, val, "k")
      assert {:error, _} = NIF.nif_slot_slice(db.db_ref, tag_id, val, 0, 5)
    end
  end

  test "handles root cursor (tag_id: -1) safely in pull, slice, and member checks" do
    empty_db = Xitdb.open!(backend: :memory)
    assert {:ok, %{}} = Xitdb.pull(Xitdb.db(empty_db), "*")
    assert {:error, _} = NIF.nif_slot_slice(empty_db.db_ref, -1, -1, 0, 5)
    assert {:ok, false} = NIF.nif_slot_contains(empty_db.db_ref, -1, -1, "__tx")

    db = Xitdb.transact!(empty_db, %{"k" => "v"}, doc: "init")
    assert {:ok, %{"k" => "v"}} = Xitdb.pull(Xitdb.db(db), "*")
    assert {:ok, %{"k" => "v"}} = Xitdb.pull(Xitdb.as_of(db, 0), "*")
    assert {:error, _} = NIF.nif_slot_slice(db.db_ref, -1, -1, 0, 5)
    assert {:ok, false} = NIF.nif_slot_contains(db.db_ref, -1, -1, "__tx")
    assert {:ok, true} = NIF.nif_slot_contains(db.db_ref, -1, -1, "k")
    assert Enum.member?(Xitdb.db(db), {"k", "v"})
    refute Enum.member?(Xitdb.db(db), {"__tx", %{"doc" => "init"}})
  end

  test "pull tolerates duplicate leaf keys via safe map builder" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"a" => %{"city" => "NYC"}, "b" => %{"city" => "LA"}})

    assert {:ok, %{"city" => "LA"}} = Xitdb.pull(db, "{a.city, b.city}")
  end

  test "preserves nested user maps containing __tx while hiding root __tx metadata" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(
        db,
        %{"user" => %{"__tx" => %{"keep" => true}, "name" => "Ada"}},
        doc: "commit-meta"
      )

    mat = Xitdb.materialize(db)
    refute Map.has_key?(mat, "__tx")
    assert mat["user"]["__tx"] == %{"keep" => true}
    assert mat["user"]["name"] == "Ada"

    {:ok, pulled} = Xitdb.pull(db, "*")
    refute Map.has_key?(pulled, "__tx")
    assert pulled["user"]["__tx"] == %{"keep" => true}

    root_entries = Enum.into(Xitdb.db(db), %{})
    refute Map.has_key?(root_entries, "__tx")
    assert Xitdb.materialize(db["user"])["__tx"] == %{"keep" => true}
  end

  test "materializes and pulls empty list, map, and set collections safely" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{
        "empty_arr" => Xitdb.array_list([]),
        "empty_ll" => Xitdb.linked_list([]),
        "empty_hs" => Xitdb.hash_set([]),
        "empty_chs" => Xitdb.counted_set([]),
        "empty_ss" => Xitdb.sorted_set([]),
        "empty_hm" => %{},
        "empty_cm" => Xitdb.counted_map(%{}),
        "empty_sm" => Xitdb.sorted_map(%{})
      })

    assert Xitdb.materialize(db["empty_arr"]) == []
    assert Xitdb.materialize(db["empty_ll"]) == []
    assert Xitdb.materialize(db["empty_hs"]) == MapSet.new()
    assert Xitdb.materialize(db["empty_chs"]) == MapSet.new()
    assert Xitdb.materialize(db["empty_ss"]) == MapSet.new()
    assert Xitdb.materialize(db["empty_hm"]) == %{}
    assert Xitdb.materialize(db["empty_cm"]) == %{}
    assert Xitdb.materialize(db["empty_sm"]) == %{}

    assert {:ok,
            %{
              "empty_arr" => [],
              "empty_ll" => [],
              "empty_hs" => [],
              "empty_chs" => [],
              "empty_ss" => [],
              "empty_hm" => %{},
              "empty_cm" => %{},
              "empty_sm" => %{}
            }} = Xitdb.pull(db, "*")
  end

  test "round-trips escaped selector keys across transact, select, history_of, pull, and datalog" do
    db = Xitdb.open!(backend: :memory)
    tricky = "k.\"q\"\\b\n\t"
    sel = Selector.format_step(:hash_map, "box") <> Selector.format_step(:hash_map, tricky)

    {:ok, db} = Xitdb.transact_ops(db, [{:put, sel, "v1"}], doc: "m1")
    {:ok, db} = Xitdb.transact_ops(db, [{:put, sel, "v2"}], doc: "m2")

    assert {:ok, "v2"} = Xitdb.select(db, sel)
    {:ok, pulled} = Xitdb.pull(db, "{#{sel}}")
    assert pulled[tricky] == "v2"

    {:ok, history} = Xitdb.history_of(db, sel)
    assert Enum.map(history, & &1.value) == ["v1", "v2"]

    escaped_q =
      tricky
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")

    {:ok, %{rows: rows}} = Xitdb.query(db, ~s(find ?v where .box["#{escaped_q}"] = ?v))
    assert rows == [["v2"]]
  end

  test "supports non-zero offset slicing on array_list and in-place slice ops" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"arr" => ["a", "b", "c", "d", "e"]})

    assert Enum.slice(db["arr"], 1..3) == ["b", "c", "d"]
    assert Enum.slice(db["arr"], 2..4//2) == ["c", "e"]

    {:ok, db} = Xitdb.transact_ops(db, [{:slice, ".arr", 2, 2}])
    assert Enum.to_list(db["arr"]) == ["c", "d"]
  end

  test "handles structured append, insert, and rm_if_exists with secondary index eviction" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(
        db,
        %{
          "items" => Xitdb.array_list(["head"]),
          "ll" => Xitdb.linked_list(["tail"]),
          "users" => %{"u1" => %{"email" => "u1@acme.io"}}
        },
        index_rules: [{:index_on, :users, :email, "email->user_id"}]
      )

    {:ok, db} =
      Xitdb.transact_ops(
        db,
        [
          {:append, ".items", %{"id" => 2, "tags" => Xitdb.sorted_set(["z", "a"])}},
          {:insert, ".ll", 0, %{"nested" => [10, 20]}},
          {:rm_if_exists, ".missing.path"},
          {:rm_if_exists, ".users.u1"}
        ],
        index_rules: [{:index_on, :users, :email, "email->user_id"}]
      )

    assert Enum.at(db["items"], 1) |> Xitdb.materialize() == %{
             "id" => 2,
             "tags" => MapSet.new(["a", "z"])
           }

    assert Xitdb.materialize(db["ll"][0]) == %{"nested" => [10, 20]}
    assert db["ll"][1] == "tail"
    assert db["users"]["u1"] == nil
    assert db["email->user_id"]["u1@acme.io"] == nil
  end

  test "datalog supports boolean comparison/grouping, negated predicates, and reports invalid_reach_clause & too_many_datalog_vars" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{
        "users" => %{
          "u1" => %{
            "name" => "alice",
            "role" => "eng",
            "active" => true,
            "reports" => Xitdb.array_list(["u2"])
          },
          "u2" => %{
            "name" => "zoe_bot",
            "role" => "guest",
            "active" => false,
            "reports" => Xitdb.array_list([])
          },
          "u3" => %{
            "name" => "bob",
            "role" => "eng",
            "active" => true,
            "reports" => Xitdb.array_list([])
          }
        }
      })

    {:ok, %{rows: bool_rows}} =
      Xitdb.query(db, "find ?act, count(?u) where .users[?u].active = ?act, ?act == true")

    assert bool_rows == [[true, 2]]

    {:ok, %{rows: neg_rows}} =
      Xitdb.query(
        db,
        ~s|find ?u, ?n where .users[?u].name = ?n, .users[?u].role = ?r, not ?r == "guest", not starts_with(?n, "b"), not contains(?n, "bot")|
      )

    assert neg_rows == [["u1", "alice"]]

    {:ok, %{rows: not_reach_rows}} =
      Xitdb.query(
        db,
        ~s|find ?u where .users[?u].active = true, ?root == "u1", not reach(?root, ?u, .users[?root].reports[?idx] = ?u)|
      )

    assert not_reach_rows == [["u3"]] or not_reach_rows == [["u1"], ["u3"]]

    assert {:error, %Error{reason: :invalid_reach_clause}} =
             Xitdb.query(
               db,
               "find ?u where .users[?u].name = ?n, reach(?u, ?v, ?d, .users[?u].name = ?n)"
             )

    vars = Enum.map_join(1..17, ", ", &"?v#{&1}")
    clauses = Enum.map_join(1..17, ", ", &".users[?u].name = ?v#{&1}")

    assert {:error, %Error{reason: :too_many_datalog_vars}} =
             Xitdb.query(db, "find #{vars} where #{clauses}")
  end

  test "concurrent readers racing with Xitdb.close/1 fail cleanly without crashing" do
    for _ <- 1..5 do
      db = Xitdb.open!(backend: :memory)

      db =
        Xitdb.transact!(db, %{
          "items" => Enum.to_list(1..50),
          "users" => Map.new(1..20, fn i -> {"u#{i}", %{"role" => "user"}} end)
        })

      tasks =
        for _ <- 1..8 do
          Task.async(fn ->
            for _ <- 1..15 do
              for res <- [
                    Xitdb.pull(db, "{users}"),
                    Xitdb.select(db, ".items[0]"),
                    Xitdb.query(db, ~s|find ?u where .users[?u].role = "user"|)
                  ] do
                assert match?({:ok, _}, res) or match?({:error, %Error{reason: :closed}}, res)
              end
            end
          end)
        end

      :ok = Xitdb.close(db)

      for task <- tasks do
        Task.await(task, 5_000)
      end
    end
  end

  test "merge_map preserves deep-merge, nil/pure-nil removal, empty-map reset, collections, and index rules" do
    db = Xitdb.open!(backend: :memory)
    rules = [{:index_on, :users, :email, "email->user_id"}]

    db =
      Xitdb.transact!(
        db,
        %{
          "users" => %{
            "u1" => %{
              "name" => "Alice",
              "email" => "alice@old.io",
              "meta" => %{"tier" => "gold"},
              "flags" => MapSet.new(["verified", "oncall"])
            },
            "u2" => %{"name" => "Bob", "email" => "bob@acme.io"}
          },
          "counted" => Xitdb.counted_map(%{"k1" => 1}),
          "sorted" => Xitdb.sorted_map(a: 10, b: 20)
        },
        index_rules: rules
      )

    assert db["counted"]["k1"] == 1
    assert Enum.count(db["counted"]) == 1
    assert Enum.count(db["users"]["u1"]["flags"]) == 2
    assert db["email->user_id"]["alice@old.io"] == "u1"
    assert db["email->user_id"]["bob@acme.io"] == "u2"

    db =
      Xitdb.transact!(
        db,
        %{
          "users" => %{
            "u1" => %{
              "email" => "alice@new.io",
              "meta" => %{}
            },
            "u2" => nil,
            "missing" => %{"nested" => nil}
          },
          "nonexistent" => %{"deep" => %{"field" => nil}},
          "sorted" => Xitdb.sorted_map(b: nil, c: 30)
        },
        index_rules: rules
      )

    # Sibling key "name" preserved while "email" updated and "meta" reset to empty map
    assert db["users"]["u1"]["name"] == "Alice"
    assert db["users"]["u1"]["email"] == "alice@new.io"
    assert Xitdb.materialize(db["users"]["u1"]["meta"]) == %{}

    # Record removal + pure-nil removal on absent containers
    assert db["users"]["u2"] == nil
    assert db["users"]["missing"] == nil
    assert db["nonexistent"] == nil

    # Secondary index eviction + re-indexing + record deletion cleanup
    assert db["email->user_id"]["alice@old.io"] == nil
    assert db["email->user_id"]["alice@new.io"] == "u1"
    assert db["email->user_id"]["bob@acme.io"] == nil

    # Sorted map collection merge & nil key deletion
    assert db["sorted"]["a"] == 10
    assert db["sorted"]["b"] == nil
    assert db["sorted"]["c"] == 30
  end
end
