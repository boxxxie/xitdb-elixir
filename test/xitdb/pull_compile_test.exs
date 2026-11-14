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
end
