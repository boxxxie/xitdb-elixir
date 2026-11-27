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

  test "compile/1 and compile!/1 handle binary patterns, string wildcard, and invalid inputs" do
    assert {:ok, "{name}"} = Pull.compile("  {name}  ")
    assert "{name}" == Pull.compile!("  {name}  ")

    assert {:error, %Error{reason: :invalid_pull_pattern}} = Pull.compile("")
    assert {:error, %Error{reason: :invalid_pull_pattern}} = Pull.compile("   ")
    assert_raise ArgumentError, fn -> Pull.compile!("") end
    assert_raise ArgumentError, fn -> Pull.compile!("   ") end

    assert {:ok, "*"} = Pull.compile(["*"])
    assert "*" == Pull.compile!(["*"])
    assert "{*, name}" == Pull.compile!(["*", "name"])

    for invalid <- [
          123,
          nil,
          :atom,
          [""],
          [nil],
          [true],
          [false],
          [{:a, {:not_slice, 1, 2}}],
          [{:a, {:slice, 1}}],
          [{:a, {{:not_slice, 1, 2}, [:b]}}],
          [{:a, {0..1, :not_list}}],
          [{123, [:b]}]
        ] do
      assert {:error, %Error{reason: :invalid_pull_pattern}} = Pull.compile(invalid)
      assert_raise ArgumentError, fn -> Pull.compile!(invalid) end
    end

    # Boundary: first == 0 and last == first == 0
    assert "{a[0..1]}" == Pull.compile!(a: 0..0//1)
    assert "{a[0..0]}" == Pull.compile!(a: {:slice, 0, 0})
    assert "{a[0..2]{b}}" == Pull.compile!(a: {0..1, [:b]})
  end

  test "split_wildcard_plan/1 and merge_wildcard_results/2 handle braces, quotes, escapes, and empty items" do
    assert {:single, "*"} == Pull.split_wildcard_plan("*")
    assert {:single, "*"} == Pull.split_wildcard_plan("  { * }  ")
    assert {:single, "{name, age}"} == Pull.split_wildcard_plan("{name, age}")
    assert {:single, "{unclosed"} == Pull.split_wildcard_plan("{unclosed")
    assert {:single, "{"} == Pull.split_wildcard_plan("{")
    assert {:single, "{}"} == Pull.split_wildcard_plan("{}")

    assert {:merge_top, "*", "{name, profile{city, zip}}"} ==
             Pull.split_wildcard_plan("{*, name, profile{city, zip}}")

    # Quoted strings with commas, escaped quotes, brackets, braces, and trailing/empty commas
    complex = ~s({*, "a,b", 'c,d', "e\\"f", 'g\\'h', items[0..2]{x, y}, , })

    assert {:merge_top, "*",
            ~s("a,b", 'c,d', "e\\"f", 'g\\'h', items[0..2]{x, y}) |> then(&"{#{&1}}")} ==
             Pull.split_wildcard_plan(complex)

    assert %{"a" => 1, "b" => 2} == Pull.merge_wildcard_results(%{"a" => 1}, %{"b" => 2})
    assert :fallback == Pull.merge_wildcard_results(:not_a_map, :fallback)
    assert :fallback == Pull.merge_wildcard_results(%{"a" => 1}, :fallback)
  end
end
