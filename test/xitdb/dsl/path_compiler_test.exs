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
    id = nil
    flag = false

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
end
