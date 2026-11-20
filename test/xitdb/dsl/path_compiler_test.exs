defmodule Xitdb.DSL.PathCompilerTest do
  use ExUnit.Case, async: true
  use Xitdb.DSL

  alias Xitdb.DSL.PathCompiler

  test "folds static paths, negative indices, and moments into single compile-time binaries" do
    ast =
      quote do
        at_moment(-1, org.counted(:departments)["eng"].todos[[-1]])
      end

    assert PathCompiler.compile(ast) == "@-1.org.departments#eng.todos[[-1]]"
  end

  test "splices parenthesized pinned prefixes, pinned moments, and dynamic runtime keys" do
    base = path(org.counted(:departments)["eng"])
    emp_id = "emp.101"
    idx = 2

    # Note: Elixir parses `.` and `[]` tighter than unary `^`, so wrap leading `^base` in `(...)`
    assert path((^base).sorted(:directory)[emp_id].todos[[idx]]) ==
             ~s(.org.departments#eng.directory$["emp.101"].todos[[2]])

    m = 3
    id = "42"
    assert path(at_moment(^m, users[id])) == "@3.users.42"
  end

  test "raises ArgumentError when a dynamic runtime bracket key is nil or boolean" do
    id = apply(Function, :identity, [nil])
    flag = apply(Function, :identity, [false])

    assert_raise ArgumentError, ~r/Invalid bracket path step nil/, fn ->
      path(users[id])
    end

    assert_raise ArgumentError, ~r/Invalid bracket path step false/, fn ->
      path(users[flag])
    end
  end

  test "compiles static and dynamic path_steps/1 expressions into pre-tokenized step lists" do
    assert path_steps(users.alice.name) == ["users", "alice", "name"]
    assert path_steps(users["alice"].roles[0]) == ["users", "alice", "roles", 0]
    assert path_steps(users["alice"].todos[[2]]) == ["users", "alice", "todos", [2]]

    base = path_steps(org.counted(:departments)["eng"])
    assert base == ["org", "departments", {:counted_hash_map, "eng"}]

    emp_id = "101"
    idx = 2

    steps = path_steps((^base).sorted(:directory)[emp_id].todos[[idx]])

    assert steps == [
             "org",
             "departments",
             {:counted_hash_map, "eng"},
             "directory",
             {:sorted_map, "101"},
             "todos",
             {:linked_array_list, 2}
           ]

    assert Xitdb.Selector.format_path_steps(steps) ==
             ".org.departments#eng.directory$101.todos[[2]]"

    str_base = path(org.counted(:departments)["eng"])

    assert path_steps((^str_base).sorted(:directory)[emp_id]) == [
             {:hash_map, "org"},
             {:hash_map, "departments"},
             {:counted_hash_map, "eng"},
             "directory",
             {:sorted_map, "101"}
           ]

    m = 3
    id = "42"
    assert path_steps(at_moment(^m, users[id])) == [{:at_moment, 3}, "users", "42"]
    assert Xitdb.Selector.format_path_steps(path_steps(at_moment(^m, users[id]))) == "@3.users.42"
  end

  test "path_steps/1 raises ArgumentError when a dynamic bracket key is nil or boolean" do
    id = nil
    flag = false

    assert_raise ArgumentError, ~r/Invalid bracket path step nil/, fn ->
      path_steps(users[id])
    end

    assert_raise ArgumentError, ~r/Invalid bracket path step false/, fn ->
      path_steps(users[flag])
    end
  end

  test "select/2, history_of/2, tx/2, and fork/3 work end-to-end with path_steps/1 and step lists" do
    db = Xitdb.open!(backend: :memory)

    try do
      {:ok, db} =
        Xitdb.DSL.tx db, doc: "seed", instant: 1_000 do
          put(path_steps(users.alice.name), "Alice")
          put(path_steps(users.alice.score), 10)
          init_col(path_steps(org.departments), :counted_hash_map)
          init_col(path_steps(org.counted(:departments)["eng"].directory), :sorted_map)

          put(path_steps(org.counted(:departments)["eng"].sorted(:directory)["101"]), %{
            role: "staff"
          })

          init_col(path_steps(queue), :linked_array_list)
          append(path_steps(queue), "a")
          append(path_steps(queue), "c")
        end

      {:ok, db} =
        Xitdb.DSL.tx db, doc: "update_and_update_fn", instant: 2_000 do
          update(path_steps(users.alice.score), fn s -> s + 5 end)
          put(path_steps(users.alice.name), "Alice Liddell")
        end

      # Exercises >16 step depth (overflows 16-slot NIF stack buffer into dynamic slice)
      deep_steps = Enum.map(1..20, fn i -> "k#{i}" end)

      {:ok, db} =
        Xitdb.transact(db, fn root ->
          root
          |> Xitdb.insert_at(["queue"], 1, "b")
          |> Xitdb.delete_at(["queue"], 2)
          |> Xitdb.fork(["users", "alice"], ["backups", "alice"])
          |> put_in(["deep"], Enum.reduce(20..1//-1, "leaf", fn i, acc -> %{"k#{i}" => acc} end))
        end)

      # Verify select/2 & select!/2 with step lists and at_moment
      assert Xitdb.select(db, path_steps(users.alice.name)) == {:ok, "Alice Liddell"}
      assert Xitdb.select(db, path_steps(users.alice.score)) == {:ok, 15}
      assert Xitdb.select(db, path_steps(at_moment(0, users.alice.name))) == {:ok, "Alice"}
      assert Xitdb.select(db, [{:at_moment, 0}]) |> elem(0) == :ok

      assert Xitdb.select!(
               db,
               path_steps(org.counted(:departments)["eng"].sorted(:directory)["101"].role)
             ) == "staff"

      assert Xitdb.select(db, deep_steps |> then(&["deep" | &1])) == {:ok, "leaf"}
      assert Xitdb.select(db, path_steps(backups.alice.name)) == {:ok, "Alice Liddell"}
      assert Enum.to_list(Xitdb.db(db)["queue"]) == ["a", "b"]

      # Chained fork followed by another op in same tx + standalone fork as last op
      {:ok, db} =
        Xitdb.transact(db, fn root ->
          root
          |> Xitdb.fork(["backups", "alice"], ["backups", "alice_v2"])
          |> put_in(["backups", "alice_v2", "name"], "Forked")
        end)

      assert Xitdb.select!(db, path_steps(backups.alice_v2.name)) == "Forked"

      assert Xitdb.history_of(db, path_steps(users.alice.name)) ==
               Xitdb.history_of(db, path(users.alice.name))

      assert {:ok,
              [
                %{moment_index: 0, value: "Alice", doc: "seed", instant: 1_000},
                %{
                  moment_index: 1,
                  value: "Alice Liddell",
                  doc: "update_and_update_fn",
                  instant: 2_000
                }
              ]} = Xitdb.history_of(db, path_steps(users.alice.name))

      assert Xitdb.history_of(
               db,
               path_steps(org.counted(:departments)["eng"].sorted(:directory)["101"].role)
             ) == {:ok, [%{moment_index: 0, value: "staff", doc: "seed", instant: 1_000}]}

      assert match?({:error, _}, Xitdb.history_of(db, [{:at_moment, 0}, "users"]))
      assert match?({:error, _}, Xitdb.select(db, ["users", nil]))
      assert match?({:error, _}, Xitdb.select(db, ["users", :bad_tail | :improper]))
    after
      Xitdb.close(db)
    end
  end

  test "select/2 and select!/2 support nif_unpack_step_list fast paths and fallbacks" do
    db = Xitdb.open!(backend: :memory)

    try do
      deep_tree = Enum.reduce(20..1//-1, "leaf20", fn i, acc -> %{"k#{i}" => acc} end)

      db =
        Xitdb.transact!(db, %{
          "users" => %{"alice" => %{"name" => "Alice v1"}},
          "arr" => [10, %{"label" => "second"}, 30],
          "counted" => Xitdb.counted_map(%{"dept" => Xitdb.sorted_map(%{"101" => "staff"})}),
          "linked" => Xitdb.linked_list(["head", "tail"]),
          "hset" => Xitdb.hash_set(["ok"]),
          "cset" => Xitdb.counted_set(["cok"]),
          "sset" => Xitdb.sorted_set(["sok"]),
          "deep" => deep_tree
        })

      db = Xitdb.transact!(db, %{"users" => %{"alice" => %{"name" => "Alice v2"}}})

      # Plain binaries, negative & positive integers, >16 step depth, tagged steps, and at_moment
      assert Xitdb.select!(db, ["users", "alice", "name"]) == "Alice v2"
      assert Xitdb.select(db, ["arr", 0]) == {:ok, 10}
      assert Xitdb.select!(db, ["arr", 1, "label"]) == "second"
      assert Xitdb.select!(db, ["arr", -1]) == 30

      assert Xitdb.select!(db, ["deep" | Enum.map(1..20, &"k#{&1}")]) == "leaf20"

      assert Xitdb.select!(db, [{:map, "counted"}, {:counted_map, "dept"}, {:sorted_map, "101"}]) ==
               "staff"

      assert Xitdb.select!(db, [{:map, "linked"}, {:linked_list, 1}]) == "tail"
      assert Xitdb.select!(db, [{:map, "linked"}, {:linked_list, [1]}]) == "tail"
      assert Xitdb.select!(db, ["linked", [1]]) == "tail"
      assert Xitdb.select!(db, [{:map, "hset"}, {:set_member, "ok"}]) == "ok"
      assert Xitdb.select!(db, [{:map, "cset"}, {:counted_set_member, "cok"}]) == "cok"
      assert Xitdb.select!(db, [{:map, "sset"}, {:sorted_set_member, "sok"}]) == "sok"

      assert Xitdb.select!(db, [{:at_moment, 0}, "users", "alice", "name"]) == "Alice v1"
      assert is_map(Xitdb.select!(db, [{:at_moment, 0}, "deep" | Enum.map(1..15, &"k#{&1}")]))
      assert is_map(Xitdb.select!(db, ["deep" | Enum.map(1..16, &"k#{&1}")]))
      assert Xitdb.select!(db, [{:at_moment, 0}, "deep" | Enum.map(1..20, &"k#{&1}")]) == "leaf20"
      assert Xitdb.select!(db, [:users, :alice, :name]) == "Alice v2"
      assert is_map(Xitdb.select!(db, [{:at_moment, 0}]))

      # Missing map key resolves to nil; invalid moment or invalid steps raise/return errors
      assert Xitdb.select(db, ["users", "nobody"]) == {:ok, nil}
      assert Xitdb.select!(db, ["users", "nobody"]) == nil
      assert {:error, %Xitdb.Error{}} = Xitdb.select(db, [{:at_moment, 999}, "users"])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, [{:at_moment, "0"}, "users"])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, [{:at_moment, :zero}, "users"])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, ["linked", []])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, ["linked", [1, 2]])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, ["users", 1.5])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, ["users", %{}])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, ["users", {:a, :b, :c}])

      assert_raise Xitdb.Error, fn ->
        Xitdb.select!(db, [{:at_moment, 999}, "users"])
      end

      assert_raise Xitdb.Error, fn ->
        Xitdb.select!(db, [{:bogus, "x"}])
      end

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, [{:bogus, "x"}])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.select(db, ["users" | :improper])

      assert {:error, %Xitdb.Error{reason: :invalid_selector}} =
               Xitdb.transact_ops(db, [{:put, [{:at_moment, 0}, "users", "x"], 1}])
    after
      Xitdb.close(db)
    end
  end

  test "path_steps/1 compiles cleanly without warnings when dynamic arguments have narrowed types" do
    assert guarded_dynamic_steps("departments", "alice", 0) == [
             "users",
             "departments",
             {:counted_hash_map, "alice"},
             "todos",
             0
           ]
  end

  defp guarded_dynamic_steps(dept, id, idx)
       when is_binary(dept) and is_binary(id) and is_integer(idx) do
    path_steps(users.counted(dept)[id].todos[idx])
  end

  test "Slice 03 regressions: select! moment/root, adaptive history_of/select, strict sigils, and parser guards" do
    db = Xitdb.open!(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    db =
      db
      |> Xitdb.transact!(%{"users" => %{"alice" => %{"n" => 1}}, "arr" => [10, 20]},
        doc: "scalar-root-m0"
      )
      |> Xitdb.transact!(
        %{
          "susers" => Xitdb.sorted_map(%{"alice" => Xitdb.linked_list(["zero", "one"])}),
          "counted" => Xitdb.counted_map(%{"alice" => %{"a.b" => "dotted"}})
        },
        doc: "m1"
      )

    # BUG-03-01: select! preserves @moment and root: true
    r0 = Xitdb.select!(db, "@0")
    assert r0.root == true
    assert r0.moment == 0

    c0 = Xitdb.select!(db, "@0.users")
    assert c0.moment == 0
    assert c0.root == false

    # BUG-03-02: path_steps/1 works against Sorted_Map + Linked_Array_List in select! and history_of
    assert "one" = Xitdb.select!(db, path_steps(susers.alice[1]))
    assert {:ok, hist} = Xitdb.history_of(db, path_steps(susers.alice[1]))
    assert Enum.map(hist, & &1.value) == ["one"]

    # BUG-03-03: explicit sigils (#, $, [[i]]) stay strict against Hash_Map / Array_List
    assert {:ok, nil} = Xitdb.select(db, "@0#users")
    assert {:ok, []} = Xitdb.history_of(db, "$users.alice")
    assert {:ok, []} = Xitdb.history_of(db, ".arr[[0]]")

    # BUG-03-04: history_of preserves doc/instant when path hits Unexpected_Tag at a later moment
    db_scalar_m1 = Xitdb.open!(backend: :memory)
    on_exit(fn -> Xitdb.close(db_scalar_m1) end)

    db_scalar_m1 =
      db_scalar_m1
      |> Xitdb.transact!(%{"users" => %{"alice" => 2}}, doc: "m0-doc", instant: 111)
      |> Xitdb.transact!(%{"users" => "not-a-map"}, doc: "m1-doc", instant: 222)

    assert {:ok, [h0, h1]} = Xitdb.history_of(db_scalar_m1, ".users.alice")
    assert h0.value == 2
    assert h0.doc == "m0-doc"
    assert h0.instant == 111
    assert h1.value == nil
    assert h1.doc == "m1-doc"
    assert h1.instant == 222

    # BUG-03-05 & BUG-03-06: Selector & NIF parser preserve #users["a.b"] / .counted#alice["a.b"] and reject @ / trailing junk
    assert Xitdb.Selector.parse_selector_steps(~S|#alice["a.b"]|) == [
             {:counted_hash_map, "alice"},
             {:hash_map, "a.b"}
           ]

    assert Xitdb.Selector.parse_selector_steps(~S|.users#alice["a.b"]|) == [
             {:hash_map, "users"},
             {:counted_hash_map, "alice"},
             {:hash_map, "a.b"}
           ]

    assert {:ok, nil} = Xitdb.select(db, ~S|#counted["a.b"]|)
    assert {:ok, "dotted"} = Xitdb.select(db, ~S|.counted#alice["a.b"]|)

    for bad_sel <- [".users.@0", ".users@0", ~S|."a.b"trailing|, ~S|.'a.b'trailing|] do
      assert_raise ArgumentError, fn ->
        Xitdb.Selector.parse_selector_steps(bad_sel)
      end
    end

    assert {:error, %Xitdb.Error{reason: :invalid_selector}} = Xitdb.history_of(db, ".users.@0")
    assert {:error, %Xitdb.Error{reason: :invalid_selector}} = Xitdb.select(db, ".users.@0")

    # BUG-03-07: invalid typed steps raise ArgumentError instead of FunctionClauseError/MatchError
    assert_raise ArgumentError, fn ->
      Xitdb.Selector.format_typed_step(:array, "not_int")
    end

    assert_raise ArgumentError, fn ->
      Xitdb.Selector.format_typed_step(:bogus, "x")
    end

    for bad_expr <- [
          quote(do: path(array("not_int"))),
          quote(do: path(array(1.5))),
          quote(do: path(counted(123))),
          quote(do: path(counted(nil))),
          quote(do: path_steps(array("not_int"))),
          quote(do: path_steps(array(1.5))),
          quote(do: path_steps(counted(123))),
          quote(do: path_steps(counted(nil))),
          quote(do: path_steps(users[{:bogus, "x"}]))
        ] do
      assert_raise ArgumentError, fn ->
        Code.eval_quoted(bad_expr, [], env: __ENV__)
      end
    end
  end

  @tag :tmp_dir
  test "select/2, history_of/2, info/1, and compact/2 handle 18-step overflow paths on :buffered_file",
       %{tmp_dir: tmp_dir} do
    db_path = Path.join(tmp_dir, "deep_history.xit")
    compact_path = Path.join(tmp_dir, "deep_history_compacted.xit")

    db = Xitdb.open!(backend: :buffered_file, path: db_path)
    on_exit(fn -> Xitdb.close(db) end)

    wrap_depth = fn leaf ->
      Enum.reduce(18..1//-1, leaf, fn i, acc -> %{"k#{i}" => acc} end)
    end

    db =
      db
      |> Xitdb.transact!(wrap_depth.("v0"), doc: "m0", instant: 100)
      |> Xitdb.transact!(wrap_depth.("v1"), doc: "m1", instant: 200)
      |> Xitdb.transact!(wrap_depth.("v2"), doc: "m2", instant: 300)

    selector_18 = ".k1.k2.k3.k4.k5.k6.k7.k8.k9.k10.k11.k12.k13.k14.k15.k16.k17.k18"
    steps_18 = path_steps(k1.k2.k3.k4.k5.k6.k7.k8.k9.k10.k11.k12.k13.k14.k15.k16.k17.k18)

    assert length(steps_18) == 18
    assert {:ok, "v2"} = Xitdb.select(db, selector_18)
    assert {:ok, "v2"} = Xitdb.select(db, steps_18)
    assert {:ok, "v0"} = Xitdb.select(db, "@0" <> selector_18)

    assert {:ok, hist_str} = Xitdb.history_of(db, selector_18)
    assert {:ok, hist_steps} = Xitdb.history_of(db, steps_18)
    assert hist_str == hist_steps

    assert Enum.map(hist_str, &{&1.moment_index, &1.value, &1.doc, &1.instant}) == [
             {0, "v0", "m0", 100},
             {1, "v1", "m1", 200},
             {2, "v2", "m2", 300}
           ]

    assert {:ok, %{moment_count: 3, file_size: size_before}} = Xitdb.info(db)
    assert size_before > 0

    {:ok, compacted} = Xitdb.compact(db, path: compact_path)
    on_exit(fn -> Xitdb.close(compacted) end)

    assert {:ok, %{moment_count: 1, file_size: size_after}} = Xitdb.info(compacted)
    assert size_after > 0
    assert size_after < size_before
    assert {:ok, "v2"} = Xitdb.select(compacted, selector_18)
    assert {:ok, [%{moment_index: 0, value: "v2"}]} = Xitdb.history_of(compacted, steps_18)

    assert :ok = Xitdb.close(compacted)
    reopened = Xitdb.open!(backend: :buffered_file, path: compact_path)
    on_exit(fn -> Xitdb.close(reopened) end)
    assert {:ok, %{moment_count: 1, file_size: ^size_after}} = Xitdb.info(reopened)
    assert {:ok, "v2"} = Xitdb.select(reopened, steps_18)
  end
end
