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
end
