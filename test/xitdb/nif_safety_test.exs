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

  test "single-pass :merge_map, :put, :append, and :insert roll back atomically on mid-payload errors" do
    empty_db = Xitdb.open!(backend: :memory)
    empty_info = Xitdb.info(empty_db)
    empty_mat = Xitdb.materialize(empty_db)

    # Empty DB: mid-map failure in :merge_map and post-savepoint :put must roll back root init
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(empty_db, [
               {:merge_map, %{"valid" => "v", "nested" => %{"ok" => 1, "bad" => {:tuple, 1}}}}
             ])

    assert Xitdb.info(empty_db) == empty_info
    assert Xitdb.materialize(empty_db) == empty_mat
    assert empty_db["valid"] == nil

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(empty_db, [
               {:put, ["valid"], "written"},
               {:savepoint},
               {:put, ["bad_list"], [1, 2, {:bad, 3}]}
             ])

    assert Xitdb.info(empty_db) == empty_info
    assert Xitdb.materialize(empty_db) == empty_mat

    assert {:ok, db} =
             Xitdb.transact_ops(empty_db, [
               {:put, ["keep"], "v1"},
               {:put, ["list"], ["a", "b"]},
               {:put, ["linked"], Xitdb.linked_list(["a", "b"])}
             ])

    info_before = Xitdb.info(db)

    # Populated DB: mid-payload validation errors across :merge_map, :put, :append, :insert
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [
               {:merge_map, %{"keep" => "mutated", "sub" => %{"a" => 1, "bad" => self()}}}
             ])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [
               {:put, ["keep"], "mutated"},
               {:savepoint},
               {:put, ["sub"], Xitdb.sorted_map(a: 1, bad: {:tuple, 2})}
             ])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [
               {:put, ["set"], Xitdb.hash_set(["ok", {:bad, :member}])}
             ])

    assert {:error, %Error{reason: :invalid_append_op}} =
             Xitdb.transact_ops(db, [
               {:append, ["list"], %{"ok" => 1, "bad" => {:a, :b}}}
             ])

    assert {:error, %Error{reason: :invalid_insert_op}} =
             Xitdb.transact_ops(db, [
               {:insert, ["linked"], 1, %{"ok" => 1, "bad" => {:a, :b}}}
             ])

    assert {:error, %Error{reason: :invalid_insert_op}} =
             Xitdb.transact_ops(db, [
               {:insert, ["list"], 1, %{"ok" => 1, "bad" => {:a, :b}}}
             ])

    assert {:error, %Error{reason: "Unexpected_Tag"}} =
             Xitdb.transact_ops(db, [
               {:insert, ["list"], 1, %{"ok" => 1}}
             ])

    assert Xitdb.info(db) == info_before
    assert db["keep"] == "v1"
    assert db["sub"] == nil
    assert Enum.to_list(db["list"]) == ["a", "b"]
    assert Enum.to_list(db["linked"]) == ["a", "b"]
    Xitdb.close(db)
  end

  test "streaming lazy is_pure_removal_term skips absent parents and still validates keys" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"present" => %{"keep" => 1, "drop" => 2}})
    {:ok, info_before} = Xitdb.info(db)

    # Pure-removal update removes existing nested key while leaving absent parents unmaterialized
    assert {:ok, db} =
             Xitdb.transact_ops(db, [
               {:merge_map,
                %{
                  "missing" => %{"deep" => %{"k" => nil}},
                  "missing_cm" => Xitdb.counted_map(%{"k" => nil}),
                  "present" => %{"drop" => nil}
                }}
             ])

    assert db["present"]["keep"] == 1
    assert db["present"]["drop"] == nil
    assert db["missing"] == nil
    assert db["missing_cm"] == nil

    # Invalid key inside pure-removal map targeting absent parent still fails with :invalid_put_op
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"missing" => %{true => nil}}}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"missing" => %{{:bad, :key} => nil}}}])

    # Non-removal invalid leaf mixed with nil under absent parent fails and rolls back
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [
               {:merge_map, %{"missing" => %{"a" => nil, "bad" => {:x, :y}}}}
             ])

    {:ok, info_after} = Xitdb.info(db)
    assert info_after.moment_count == info_before.moment_count + 1
    assert db["present"]["keep"] == 1
    Xitdb.close(db)
  end

  test "pure-removal under existing keys, invalid collection containers, >32-key maps, and MAX_WRITE_DEPTH guard" do
    db = Xitdb.open!(backend: :memory)

    # Large (>32 keys) map exercises Nif_Map_Iter heap wstack traversal
    wide_map = Map.new(1..48, fn i -> {"k#{i}", i} end)
    db = Xitdb.transact!(db, %{"wide" => wide_map, "nested" => %{"a" => %{"b" => 1, "c" => 2}}})
    {:ok, info_before} = Xitdb.info(db)
    assert db["wide"]["k48"] == 48

    # Pure-removal targeting existing nested key removes leaf cleanly
    assert {:ok, db} =
             Xitdb.transact_ops(db, [
               {:merge_map, %{"nested" => %{"a" => %{"b" => nil}}}}
             ])

    assert db["nested"]["a"]["b"] == nil
    assert db["nested"]["a"]["c"] == 2

    # Invalid leaf mixed under existing key still fails and rolls back
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [
               {:merge_map, %{"nested" => %{"a" => %{"c" => nil, "bad" => {:x, :y}}}}}
             ])

    assert db["nested"]["a"]["c"] == 2

    # Invalid collection data containers fail pre-validation cleanly
    for bad_col <- [
          %Xitdb.Collection{kind: :hash_map, data: 123},
          %Xitdb.Collection{kind: :counted_hash_map, data: :not_a_map},
          %Xitdb.Collection{kind: :sorted_map, data: 123},
          %Xitdb.Collection{kind: :hash_set, data: 123},
          %Xitdb.Collection{kind: :counted_hash_set, data: %{a: 1}},
          %Xitdb.Collection{kind: :sorted_set, data: "bad"}
        ] do
      assert {:error, %Error{reason: :invalid_put_op}} =
               Xitdb.transact_ops(db, [{:put, ["bad_col"], bad_col}])

      assert {:error, %Error{reason: :invalid_put_op}} =
               Xitdb.transact_ops(db, [{:merge_map, %{"nested" => bad_col}}])
    end

    # Nesting deeper than MAX_WRITE_DEPTH (64) is rejected cleanly without stack overflow
    too_deep = Enum.reduce(1..70, 1, fn i, acc -> %{"l#{i}" => acc} end)
    too_deep_nil = Enum.reduce(1..70, nil, fn i, acc -> %{"l#{i}" => acc} end)

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:put, ["too_deep"], too_deep}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"too_deep" => too_deep}}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"absent_deep" => too_deep_nil}}])

    # Within MAX_WRITE_DEPTH (60) succeeds cleanly
    within_depth = Enum.reduce(1..60, "leaf", fn i, acc -> %{"l#{i}" => acc} end)
    assert {:ok, db} = Xitdb.transact_ops(db, [{:put, ["within_depth"], within_depth}])
    assert get_in(db, ["within_depth" | Enum.map(60..1//-1, &"l#{&1}")]) == "leaf"

    {:ok, info_after} = Xitdb.info(db)
    assert info_after.moment_count == info_before.moment_count + 2
    Xitdb.close(db)
  end

  test "error precedence: invalid payloads take priority over tag mismatch, empty steps, and later malformed ops" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"scalar" => "alice", "list" => [1, 2]})
    info_before = Xitdb.info(db)

    # Finding 1: invalid nested payloads overwriting a scalar or mismatched container return :invalid_put_op
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"scalar" => %{true => "bad_key"}}}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"scalar" => %{"a" => {:bad_tuple, 1}}}}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"list" => %{{:bad, :key} => "bad_key"}}}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:put, ["scalar", "child"], %{true => "bad_key"}}])

    # Valid payload against scalar parent still returns "Unexpected_Tag"
    assert {:error, %Error{reason: "Unexpected_Tag"}} =
             Xitdb.transact_ops(db, [{:put, ["scalar", "child"], %{"ok" => 1}}])

    # Finding 2: empty steps with unsupported struct or invalid map returns :invalid_put_op, not "Invalid_Range"
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:put, [], URI.parse("https://example.com")}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:put, [], %{true => "bad_key"}}])

    assert {:error, %Error{reason: "Invalid_Range"}} =
             Xitdb.transact_ops(db, [{:put, [], %{"ok" => 1}}])

    # Finding 3: multi-op error precedence preserves Op 1's validation error ahead of Op 2's parse error
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [
               {:put, ["a"], %{"bad" => {:tuple, 1}}},
               {:put, ["b"], {:bad_scalar_tuple, 2}}
             ])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [
               {:put, ["a"], %{"bad" => {:tuple, 1}}},
               {:unknown_op}
             ])

    assert {:error, %Error{reason: :invalid_append_op}} =
             Xitdb.transact_ops(db, [
               {:append, ["list"], %{"bad" => {:tuple, 1}}},
               {:unknown_op}
             ])

    assert Xitdb.info(db) == info_before
    assert db["scalar"] == "alice"
    assert Enum.to_list(db["list"]) == [1, 2]
    Xitdb.close(db)
  end

  test "Slice 04 regressions: exact MAX_WRITE_DEPTH 64/65 boundary, forged MapSet rejection, and wide streaming maps" do
    db = Xitdb.open!(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    # Exact 64-container NIF argument depth succeeds across :put and :merge_map (scalar & pure removal)
    d63_scalar = Enum.reduce(1..63, "leaf", fn i, acc -> %{"l#{i}" => acc} end)
    d64_scalar = Enum.reduce(1..64, "leaf", fn i, acc -> %{"l#{i}" => acc} end)
    d63_nil = Enum.reduce(1..63, nil, fn i, acc -> %{"l#{i}" => acc} end)
    d64_nil = Enum.reduce(1..64, nil, fn i, acc -> %{"l#{i}" => acc} end)

    assert {:ok, db} = Xitdb.transact_ops(db, [{:put, ["d64"], d64_scalar}])
    assert get_in(db, ["d64" | Enum.map(64..1//-1, &"l#{&1}")]) == "leaf"

    assert {:ok, db} = Xitdb.transact_ops(db, [{:merge_map, %{"d64_merge" => d63_scalar}}])
    assert get_in(db, ["d64_merge" | Enum.map(63..1//-1, &"l#{&1}")]) == "leaf"

    # Valid pure-removal at exact depth 64 succeeds cleanly
    assert {:ok, db} = Xitdb.transact_ops(db, [{:merge_map, %{"absent_d64" => d63_nil}}])
    assert db["absent_d64"] == nil

    # Exact 65-container failure boundary across :put, :merge_map, and pure removal
    d65_scalar = Enum.reduce(1..65, "leaf", fn i, acc -> %{"l#{i}" => acc} end)

    {:ok, info_before} = Xitdb.info(db)

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:put, ["d65"], d65_scalar}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"d64" => d64_scalar}}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"absent_d64" => d64_nil}}])

    # BUG-04-03: Forged %MapSet{map: ...} variants are rejected cleanly
    for forged <- [
          %MapSet{map: URI.parse("https://example.com")},
          %MapSet{map: [1, 2]},
          %MapSet{map: 123},
          Xitdb.hash_set(%MapSet{map: [1, 2]}),
          Xitdb.counted_set(%{__struct__: MapSet, map: [1, 2]}),
          Xitdb.sorted_set(%MapSet{map: URI.parse("https://example.com")})
        ] do
      assert {:error, %Error{reason: :invalid_put_op}} =
               Xitdb.transact_ops(db, [{:put, ["forged"], forged}])

      assert {:error, %Error{reason: :invalid_put_op}} =
               Xitdb.transact_ops(db, [{:put, ["forged"], forged}, {:unknown_op}])
    end

    # Wide map (>128 keys) streams cleanly via Nif_Map_Iter, and mid-stream failure cleans up heap wstack
    wide200 = Map.new(1..200, fn i -> {"w_#{i}", i} end)
    assert {:ok, db} = Xitdb.transact_ops(db, [{:put, ["wide200"], wide200}])
    assert db["wide200"]["w_200"] == 200

    wide_bad =
      1..48
      |> Map.new(fn i -> {"k_#{i}", i} end)
      |> Map.put("bad_leaf", {:bad, :tuple})

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:put, ["wide_bad"], wide_bad}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"wide_bad" => wide_bad}}])

    assert db["wide_bad"] == nil

    {:ok, info_after} = Xitdb.info(db)
    assert info_after.moment_count == info_before.moment_count + 1
  end

  test "file-backed rollback restores root header and file length across empty-DB and mid-payload failures" do
    tmp_dir = Path.join(System.tmp_dir!(), "xitdb_rollback_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "rollback.xit")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, db} = Xitdb.open(backend: :buffered_file, path: path)

    # Empty-DB root-init rollback: nested payload writes into core before hitting invalid leaf
    bad_nested = %{"ok" => String.duplicate("x", 256), "bad" => {:bad, :tuple}}

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:put, ["init"], bad_nested}])

    assert {:ok, %{moment_count: 0}} = Xitdb.info(db)

    # Valid commit succeeds cleanly after empty-DB rollback
    assert {:ok, db} = Xitdb.transact(db, %{"users" => %{"alice" => "v1"}})
    assert {:ok, %{moment_count: 1} = info_before} = Xitdb.info(db)

    # Populated-DB mid-payload rollback restores file length and root header
    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"users" => bad_nested}}])

    assert {:ok, ^info_before} = Xitdb.info(db)
    assert db["users"]["alice"] == "v1"

    # Follow-up valid commit, sync, close, and reopen succeed cleanly
    assert {:ok, db} = Xitdb.transact(db, %{"users" => %{"alice" => "v2"}})
    assert :ok = Xitdb.sync(db)
    assert :ok = Xitdb.close(db)

    {:ok, reopened} = Xitdb.open(backend: :buffered_file, path: path)
    assert {:ok, %{moment_count: 2}} = Xitdb.info(reopened)
    assert reopened["users"]["alice"] == "v2"
    assert Xitdb.as_of(reopened, 0)["users"]["alice"] == "v1"
    assert :ok = Xitdb.close(reopened)
  end

  test "BUG-015/016/047: secondary index swap, overwrite eviction, and missing field rm_if_exists" do
    idx_rules = [{:index_on, :users, :email, "idx_email"}]
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(
        db,
        %{
          "users" => %{
            "u1" => %{"email" => "a@x", "name" => "One"},
            "u2" => %{"email" => "b@x", "name" => "Two"}
          }
        },
        index_rules: idx_rules
      )

    # BUG-015: swapping values in a single merge keeps both index entries intact
    {:ok, db} =
      Xitdb.transact_ops(
        db,
        [
          {:merge_map, %{"users" => %{"u1" => %{"email" => "b@x"}, "u2" => %{"email" => "a@x"}}}}
        ],
        index_rules: idx_rules
      )

    assert db["idx_email"]["a@x"] == "u2"
    assert db["idx_email"]["b@x"] == "u1"

    # BUG-047: rm_if_exists on record lacking indexed field succeeds cleanly
    {:ok, db} =
      Xitdb.transact_ops(
        db,
        [
          {:put, ["users", "u3"], %{"name" => "NoEmail"}},
          {:rm_if_exists, ["users", "u3"]}
        ],
        index_rules: idx_rules
      )

    assert db["users"]["u3"] == nil

    # BUG-016: overwriting record with %{}, scalar, or list evicts old secondary index
    {:ok, db} =
      Xitdb.transact_ops(
        db,
        [{:merge_map, %{"users" => %{"u1" => %{}}}}],
        index_rules: idx_rules
      )

    assert db["idx_email"]["b@x"] == nil
    assert db["idx_email"]["a@x"] == "u2"

    {:ok, db} =
      Xitdb.transact_ops(
        db,
        [{:merge_map, %{"users" => %{"u2" => "scalar_wiped"}}}],
        index_rules: idx_rules
      )

    assert db["idx_email"]["a@x"] == nil

    # Clearing source_map_key at depth 0 evicts remaining entries
    {:ok, db} =
      Xitdb.transact_ops(
        db,
        [{:merge_map, %{"users" => %{"u4" => %{"email" => "d@x"}}}}],
        index_rules: idx_rules
      )

    assert db["idx_email"]["d@x"] == "u4"

    {:ok, db} =
      Xitdb.transact_ops(
        db,
        [{:merge_map, %{"users" => %{}}}],
        index_rules: idx_rules
      )

    assert db["idx_email"]["d@x"] == nil
    :ok = Xitdb.close(db)
  end

  test "BUG-017/018/020/048: adapt_tx_ops_for_base_moment handles fork aliases, merge_map tags, and init_col" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{
        "src" => Xitdb.counted_map(%{"nested" => Xitdb.sorted_map(%{"init" => 0})}),
        "users" => Xitdb.sorted_map(%{"seed" => 1}),
        "a" => %{"b" => Xitdb.counted_map(%{"seed" => 1})}
      })

    # BUG-017 & BUG-018: fork + child tag update & fork of base container after nested write
    {:ok, db} =
      Xitdb.transact_ops(db, [
        {:put, ["src", "sub"], Xitdb.sorted_map(%{"x" => 1})},
        {:fork, ["src"], ["dst"]},
        {:put, ["dst", "nested", "k"], "val"},
        {:put, ["dst", "sub", "y"], 2},
        {:put, ["dst", "direct"], 3}
      ])

    assert db["dst"]["nested"]["k"] == "val"
    assert db["dst"]["sub"]["x"] == 1
    assert db["dst"]["sub"]["y"] == 2
    assert db["dst"]["direct"] == 3

    # BUG-020: new nested map in merge_map + rm + recreate + follow-up put
    {:ok, db} =
      Xitdb.transact_ops(db, [
        {:merge_map, %{"new_map" => %{"sub" => Xitdb.counted_map(%{"a" => 1})}}},
        {:put, ["new_map", "sub", "b"], 2},
        {:rm, ["users"]},
        {:merge_map, %{"users" => %{"alice" => 1}}},
        {:put, ["users", "bob"], 2}
      ])

    assert Enum.count(db["new_map"]["sub"]) == 2
    assert db["new_map"]["sub"]["b"] == 2
    assert db["users"]["alice"] == 1
    assert db["users"]["bob"] == 2

    # BUG-048: overwriting ancestor then init_col with reset: false
    {:ok, db} =
      Xitdb.transact_ops(db, [
        {:put, ["a"], %{}},
        {:init_col, ["a", "b"], "sorted_map"},
        {:put, ["a", "b", "k"], 99}
      ])

    assert db["a"]["b"]["k"] == 99
    :ok = Xitdb.close(db)
  end

  test "BUG-021/022/023: select pins moments, pull merges pinned root, and Xitdb.at supports Elixir lists" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{"v" => 1, "profile" => %{"city" => "NYC"}, "users" => %{"a" => 10}})

    snap_root = Xitdb.select!(db, "")
    snap_neg = Xitdb.select!(db, "@-1")
    snap_sub = Xitdb.select!(db, "@-1.profile")

    db = Xitdb.transact!(db, %{"v" => 2, "profile" => %{"city" => "SF"}, "users" => %{"a" => 99}})

    assert snap_root.moment == 0
    assert snap_neg.moment == 0
    assert snap_sub.moment == 0
    assert Xitdb.materialize(snap_root)["v"] == 1

    assert Xitdb.pull!(snap_neg, [:v, profile: [:city]]) == %{
             "v" => 1,
             "profile" => %{"city" => "NYC"}
           }

    assert snap_sub["city"] == "NYC"
    assert Xitdb.query!(snap_root, "find ?a where users[?u] = ?a").rows == [[10]]

    # BUG-022: pull with wildcard + explicit spec on %Xitdb{}
    assert {:ok, pulled} = Xitdb.pull(db, [:*, profile: [:city]])
    assert pulled["v"] == 2
    assert pulled["profile"] == %{"city" => "SF"}

    # BUG-023: Xitdb.at works on standard Elixir lists across Access ops
    list_doc = %{"items" => [10, 20, 30]}
    assert get_in(list_doc, ["items", Xitdb.at(1)]) == 20
    assert put_in(list_doc, ["items", Xitdb.at(-1)], 99) == %{"items" => [10, 20, 99]}
    {popped, after_pop} = pop_in(list_doc, ["items", Xitdb.at(0)])
    assert popped == 10
    assert after_pop == %{"items" => [20, 30]}
    :ok = Xitdb.close(db)
  end

  test "BUG-006/007/030/031/044: Cursor staged fork overlay, list edits, erl_eval inner capture, and fetch_edited_list" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{
        "a" => %{"v" => "from_a", "nums" => Xitdb.linked_list([1, 2])},
        "outer" => Xitdb.linked_list([%{"inner" => Xitdb.linked_list(["x"])}]),
        "src" => %{"k" => "origin"}
      })

    # BUG-006 & BUG-007: nested forks + fork + list edit materialize cleanly from root
    {:ok, db} =
      Xitdb.transact(db, fn root ->
        root = Xitdb.fork(root, ["a"], ["b", "sub"])
        root = Xitdb.fork(root, ["b"], ["c"])
        root = Xitdb.insert_at(root, ["c", "sub", "nums"], 1, 99)

        root = Xitdb.fork(root, ["src"], ["d", "sub"])
        root = Xitdb.fork(root, ["d", "sub"], ["d"])

        root_mat = Xitdb.materialize(root)
        assert root_mat["c"]["sub"]["v"] == "from_a"
        assert root_mat["c"]["sub"]["nums"] == [1, 99, 2]
        assert root_mat["d"]["k"] == "origin"
        root
      end)

    assert Xitdb.materialize(db["c"]["sub"]) == %{"v" => "from_a", "nums" => [1, 99, 2]}
    assert Xitdb.materialize(db["d"]) == %{"k" => "origin"}

    # BUG-031 & BUG-044: child list edit preserved on parent list edit & fetch_edited_list normalizes collections
    {:ok, db} =
      Xitdb.transact(db, fn root ->
        root = Xitdb.insert_at(root, ".outer[[0]].inner", 0, %{"m" => Xitdb.counted_map(%{a: 1})})
        root = Xitdb.insert_at(root, ".outer", 0, %{"second" => true})

        assert Xitdb.materialize(root["outer"][0]) == %{"second" => true}
        edited_inner = Enum.to_list(root["outer"][1]["inner"])
        assert edited_inner == [%{"m" => %{"a" => 1}}, "x"]
        root
      end)

    assert Xitdb.materialize(db["outer"][1]["inner"]) == [%{"m" => %{"a" => 1}}, "x"]

    # BUG-030: :erl_eval get_and_update inner closure inspecting outer cursor var
    {:ok, _db} =
      Xitdb.transact(db, fn root ->
        {quoted_result, _binding} =
          Code.eval_quoted(
            quote do
              Access.get_and_update(var!(r), "src", fn outer_cur ->
                Access.get_and_update(outer_cur, "k", fn _inner ->
                  marker = if is_nil(outer_cur), do: "was_nil", else: "seen:#{outer_cur.tag}"
                  {marker, marker}
                end)
              end)
            end,
            r: root
          )

        {marker, updated_root} = quoted_result
        assert marker == "seen:hash_map"
        assert updated_root["src"]["k"] == "seen:hash_map"
        updated_root
      end)

    :ok = Xitdb.close(db)
  end

  test "BUG-037/045/046/049/050/051/056/057/059/060: NIF slot, pull, datalog sum/whitespace, selector errors, and set validation" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{
        "sm" => Xitdb.sorted_map(%{"field" => "ok", "nested" => Xitdb.counted_map(%{"x" => 7})}),
        "hs" => Xitdb.hash_set(["alpha"]),
        "chs" => Xitdb.counted_set(["beta"]),
        "ss" => Xitdb.sorted_set(["gamma"]),
        "hm" => %{"k" => 1},
        "chm" => Xitdb.counted_map(%{"k" => 2}),
        "a\\,b" => "comma",
        "a\\\"b" => "qval",
        "c" => "plain",
        "vals" => [%{"n" => 1.5}, %{"n" => -2}],
        "users" => %{"u1" => %{"name" => "Ada"}},
        "idx" => %{
          "search" => %{
            "items" => %{
              "meta" => %{"doc_count" => 1, "total_len" => 1},
              "docs" => %{"1" => %{"len" => 1, "terms" => %{"hello" => 100}}},
              "terms" => Xitdb.sorted_map(%{"__tx" => "meta_slot", "hello" => %{"1" => 100}})
            }
          }
        }
      })

    # BUG-045: root "__tx" hidden by slot_get_key
    assert :error = NIF.nif_slot_get_key(db.db_ref, -1, 0, "__tx")

    # BUG-046: slot_contains across all 6 map/set container types
    for {sel, present, absent} <- [
          {"sm", "field", "nope"},
          {"hm", "k", "nope"},
          {"chm", "k", "nope"},
          {"hs", "alpha", "nope"},
          {"chs", "beta", "nope"},
          {"ss", "gamma", "nope"}
        ] do
      cur = Xitdb.select!(db, sel)
      assert NIF.nif_slot_contains(db.db_ref, cur.tag_id, cur.value, present) == {:ok, true}
      assert NIF.nif_slot_contains(db.db_ref, cur.tag_id, cur.value, absent) == {:ok, false}
    end

    # BUG-049 & BUG-059: Pull on Sorted_Map, nested Counted_Hash_Map, and backslash-escaped pattern
    assert Xitdb.pull!(db["sm"], "{field, nested{x}}") == %{
             "field" => "ok",
             "nested" => %{"x" => 7}
           }

    assert Xitdb.pull!(db, ~s({a\\,b, a\\"b, c})) == %{
             "a\\,b" => "comma",
             "a\\\"b" => "qval",
             "c" => "plain"
           }

    # BUG-037: Datalog sum float followed by negative i64 preserves f64
    res_sum = Xitdb.query!(db, "find sum(?n) where vals[[?i]].n = ?n")
    assert [[sum_val]] = res_sum.rows
    assert_in_delta sum_val, -0.5, 1.0e-9

    # BUG-060: Whitespace after @moment before sigil-prefixed path
    res_at = Xitdb.query!(db, "find ?name where @0 .users[?u].name = ?name")
    assert res_at.rows == [["Ada"]]

    # BUG-051: BM25 skips "__tx" metadata entry in terms Sorted_Map
    assert {:ok, [{"1", _score}]} =
             NIF.nif_bm25_search(db.db_ref, -1, 0, "items", ["hello"], 5, %{min_prefix_length: 2})

    assert {:ok, []} =
             NIF.nif_bm25_search(db.db_ref, -1, 0, "items", ["__tx"], 5, %{min_prefix_length: 2})

    # BUG-056: Selector.parse_selector_steps raises ArgumentError on unclosed brackets/quotes
    for bad <- [".[\"unclosed", "[0", "[[0]x]", ".'abc\\", "[abc]"] do
      assert_raise ArgumentError, fn ->
        Selector.parse_selector_steps(bad)
      end
    end

    # BUG-057: TxCompiler rejects nil and booleans in raw MapSet / Collection set
    assert_raise ArgumentError, fn ->
      Xitdb.TxCompiler.compile_node(["s"], MapSet.new([nil]), true)
    end

    assert_raise ArgumentError, fn ->
      Xitdb.TxCompiler.compile_node(["s"], Xitdb.counted_set([true]), true)
    end

    :ok = Xitdb.close(db)
  end

  test "concurrent deeply nested diff_moments, materialize, pull, sync, and compact stay safe on default dirty scheduler stacks" do
    depth = 16

    compressed_leaf =
      Xitdb.Compression.compress(String.duplicate("stack safety ", 32),
        codec: :zlib,
        min_bytes: 0
      )

    nested_a =
      Enum.reduce(depth..1//-1, %{"leaf" => "v1", "blob" => compressed_leaf}, fn i, acc ->
        %{"k#{i}" => acc}
      end)

    nested_b =
      Enum.reduce(depth..1//-1, %{"leaf" => "v2", "blob" => compressed_leaf}, fn i, acc ->
        %{"k#{i}" => acc}
      end)

    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"root" => nested_a, "__blobs" => %{"dead" => "unused"}})
    db = Xitdb.transact!(db, %{"root" => nested_b})

    expected_path = ".root." <> Enum.map_join(1..depth, ".", &"k#{&1}") <> ".leaf"

    tasks =
      for _ <- 1..32 do
        Task.async(fn ->
          {:ok, changes} = Xitdb.diff_moments(db, 0, 1)
          assert [%{op: :put, path: ^expected_path, old_value: "v1", new_value: "v2"}] = changes

          mat = Xitdb.materialize(db)
          leaf_mat = Enum.reduce(1..depth, mat["root"], fn i, acc -> acc["k#{i}"] end)
          assert leaf_mat["leaf"] == "v2"

          {:ok, pulled} = Xitdb.pull(db, "*")
          leaf_pull = Enum.reduce(1..depth, pulled["root"], fn i, acc -> acc["k#{i}"] end)
          assert leaf_pull["leaf"] == "v2"

          :ok = Xitdb.sync(db)

          {:ok, compacted} = Xitdb.compact(db, path: "")
          on_compacted = Xitdb.materialize(compacted)
          assert :ok = Xitdb.close(compacted)

          assert Enum.reduce(1..depth, on_compacted["root"], fn i, acc -> acc["k#{i}"] end)[
                   "leaf"
                 ] == "v2"

          :ok
        end)
      end

    assert Enum.all?(Task.await_many(tasks, 15_000), &(&1 == :ok))
    assert :ok = Xitdb.close(db)
  end
end
