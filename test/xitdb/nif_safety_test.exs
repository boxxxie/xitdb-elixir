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

    # Large (>32 keys) map exercises temp_allocator fallback in extract_map_kvs
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

    # Exact depth 64 scalar & nil maps succeed across :put and :merge_map (pure removal)
    d64_scalar = Enum.reduce(1..64, "leaf", fn i, acc -> %{"l#{i}" => acc} end)
    d63_nil = Enum.reduce(1..63, nil, fn i, acc -> %{"l#{i}" => acc} end)

    assert {:ok, db} = Xitdb.transact_ops(db, [{:put, ["d64"], d64_scalar}])
    assert get_in(db, ["d64" | Enum.map(64..1//-1, &"l#{&1}")]) == "leaf"

    # Valid pure-removal at exact depth 64 succeeds cleanly
    assert {:ok, db} = Xitdb.transact_ops(db, [{:merge_map, %{"absent_d64" => d63_nil}}])
    assert db["absent_d64"] == nil

    # Depth 65 scalar & nil maps fail consistently across :put, :merge_map, and pure removal
    d65_scalar = Enum.reduce(1..65, "leaf", fn i, acc -> %{"l#{i}" => acc} end)
    d65_nil = Enum.reduce(1..65, nil, fn i, acc -> %{"l#{i}" => acc} end)

    {:ok, info_before} = Xitdb.info(db)

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:put, ["d65"], d65_scalar}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"d65" => d65_scalar}}])

    assert {:error, %Error{reason: :invalid_put_op}} =
             Xitdb.transact_ops(db, [{:merge_map, %{"absent_d65" => d65_nil}}])

    # BUG-04-03: Forged %MapSet{map: ...} variants are rejected cleanly
    for forged <- [
          %MapSet{map: URI.parse("https://example.com")},
          %MapSet{map: [1, 2]},
          %MapSet{map: 123},
          Xitdb.hash_set(%MapSet{map: [1, 2]}),
          Xitdb.counted_set(%MapSet{map: %{"ok" => []}} |> then(&%{&1 | map: [1, 2]})),
          Xitdb.sorted_set(%MapSet{map: URI.parse("https://example.com")})
        ] do
      assert {:error, %Error{reason: :invalid_put_op}} =
               Xitdb.transact_ops(db, [{:put, ["forged"], forged}])

      assert {:error, %Error{reason: :invalid_put_op}} =
               Xitdb.transact_ops(db, [{:put, ["forged"], forged}, {:unknown_op}])
    end

    # Wide map (>128 keys) streams cleanly via Nif_Map_Iter
    wide200 = Map.new(1..200, fn i -> {"w_#{i}", i} end)
    assert {:ok, db} = Xitdb.transact_ops(db, [{:put, ["wide200"], wide200}])
    assert db["wide200"]["w_200"] == 200

    {:ok, info_after} = Xitdb.info(db)
    assert info_after.moment_count == info_before.moment_count + 1
  end
end
