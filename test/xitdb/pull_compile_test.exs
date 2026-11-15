defmodule Xitdb.PullCompileTest do
  use ExUnit.Case, async: true
  doctest Xitdb.Pull

  alias Xitdb.{Error, Pull}

  test "inclusive ranges translate to half-open [first..last + 1] bounds" do
    assert Pull.compile!(todos: 0..0) == "{todos[0..1]}"
    assert Pull.compile!(todos: 0..2) == "{todos[0..3]}"
    assert Pull.compile!(team: {2..4, [:username]}) == "{team[2..5]{username}}"
  end

  test "{:slice, offset, limit} supports zero-length slices and nested projections" do
    assert Pull.compile!(todos: {:slice, 10, 0}) == "{todos[10..10]}"
    assert Pull.compile!(team: {{:slice, 10, 5}, [:id]}) == "{team[10..15]{id}}"
  end

  test "rejects negative, descending, stepped, or empty-nested patterns with ArgumentError" do
    for invalid <- [
          [],
          [todos: -1..2//1],
          [todos: 5..2//1],
          [todos: 0..6//2],
          [todos: {:slice, -1, 5}],
          [todos: {:slice, 0, -1}],
          [profile: []],
          [team: {0..2, []}]
        ] do
      assert {:error, %Error{reason: :invalid_pull_pattern}} = Pull.compile(invalid)
      assert_raise ArgumentError, fn -> Pull.compile!(invalid) end
    end
  end

  test "supports root [*] wildcard, runtime mixed pull with nested/range specs, and escaped field names" do
    assert {:ok, "*"} = Pull.compile([:*])
    assert "*" == Pull.compile!([:*])

    {:ok, db} = Xitdb.open(backend: :memory)

    try do
      {:ok, db} =
        Xitdb.transact(db, %{
          "user" => %{
            "name" => "Alice",
            "role" => "admin",
            "profile" => %{"city" => "NYC", "zip" => "10001"},
            "friends" => [
              %{"name" => "Bob", "secret" => "x"},
              %{"name" => "Carol", "secret" => "y"}
            ],
            "scores" => [10, 20, 30]
          },
          "weird" => %{
            "a.b" => 1,
            "c,d" => 2,
            "e{f}" => 3,
            "g h" => 4
          }
        })

      assert {:ok, pulled} =
               Xitdb.pull(
                 Xitdb.db(db)["user"],
                 [:*, profile: [:city], friends: {0..1, [:name]}, scores: 0..1]
               )

      assert pulled == %{
               "name" => "Alice",
               "role" => "admin",
               "profile" => %{"city" => "NYC"},
               "friends" => [%{"name" => "Bob"}, %{"name" => "Carol"}],
               "scores" => [10, 20]
             }

      weird_pattern = Pull.compile!(["a.b", "c,d", "e{f}", "g h"])
      assert weird_pattern == ~s({["a.b"], ["c,d"], ["e{f}"], ["g h"]})

      assert Xitdb.pull!(Xitdb.db(db)["weird"], ["a.b", "c,d", "e{f}", "g h"]) == %{
               "a.b" => 1,
               "c,d" => 2,
               "e{f}" => 3,
               "g h" => 4
             }
    after
      :ok = Xitdb.close(db)
    end
  end

  test "pull_pattern/1 raises ArgumentError at compile time on invalid static patterns" do
    assert_raise ArgumentError, fn ->
      Code.compile_quoted(
        quote do
          use Xitdb.DSL

          defmodule BadPullPattern do
            def bad, do: pull_pattern(todos: 5..2//1)
          end
        end
      )
    end
  end
end
