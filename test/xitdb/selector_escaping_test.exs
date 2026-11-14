defmodule Xitdb.SelectorEscapingTest do
  use ExUnit.Case, async: true
  use Xitdb.DSL

  test "path/1 escapes quotes, backslashes, @, newlines, and preserves \#{...}" do
    tricky_key = ~s(a"b\\c\n\#{raw}@0)
    assert path(users[tricky_key].role) == ~s(.users.["a\\"b\\\\c\\n\#{raw}@0"].role)
  end

  test "datalog/1 escapes pinned strings, atoms, and linked-list [[^idx]] pins without Elixir \\\#{ artifacts" do
    pinned_key = ~s(user"1)
    pinned_val = "hello \#{world}\n"
    pinned_idx = 2

    compiled =
      datalog do
        find {role}

        where [
          users[^pinned_key].note == ^pinned_val,
          users[:alice].todos[[^pinned_idx]] == "ship",
          users[:alice].role == role
        ]
      end

    assert compiled =~ ~s(.users["user\\"1"].note = "hello \#{world}\\n")
    assert compiled =~ ~s(.users["alice"].todos[[2]] = "ship")
    assert compiled =~ ~s(.users["alice"].role = ?role)
  end
end
