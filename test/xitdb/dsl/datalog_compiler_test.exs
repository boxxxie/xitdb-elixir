defmodule Xitdb.DSL.DatalogCompilerTest do
  use ExUnit.Case, async: true
  use Xitdb.DSL

  test "compiles aggregations, negative literals, reach, and set predicates" do
    prefix = "da"

    compiled =
      datalog do
        find {dept, count(u), sum(delta)}
        from u in counted(:users)

        where [
          u.dept == dept,
          starts_with(dept, ^prefix),
          u.delta == delta,
          delta >= -50,
          not u.flags.counted_set_member("archived")
        ]
      end

    assert compiled == """
           find ?dept, count(?u), sum(?delta)
           where
             #users[?u].dept = ?dept
             starts_with(?dept, "da")
             #users[?u].delta = ?delta
             ?delta >= -50
             not #users[?u].flags#%"archived"\
           """

    neg_compiled =
      datalog do
        find {item}

        where [
          at_moment(-1, users[item].roles[-1].todos[[-1]]) == item
        ]
      end

    assert neg_compiled == """
           find ?item
           where
             @-1.users[?item].roles[-1].todos[[-1]] = ?item\
           """
  end

  test "raises ArgumentError when pinning nil in a Datalog where clause" do
    bad = nil

    assert_raise ArgumentError, "cannot match nil in Datalog where clause", fn ->
      datalog do
        find {id}
        where [users[id].role == ^bad]
      end
    end
  end

  test "raises CompileError with helpful message on unpinned function call or invalid path/collection AST" do
    assert_raise CompileError, ~r/Unsupported Datalog operand/, fn ->
      Code.compile_quoted(
        quote do
          use Xitdb.DSL

          datalog do
            find {id}
            where [users[id].age >= String.to_integer("10")]
          end
        end
      )
    end

    assert_raise CompileError, ~r/Invalid collection source in Datalog/, fn ->
      Code.compile_quoted(
        quote do
          use Xitdb.DSL

          datalog do
            find {u}
            from u in foo(x)
            where [u.role == "admin"]
          end
        end
      )
    end

    assert_raise CompileError, ~r/Invalid path expression in Datalog clause/, fn ->
      Code.compile_quoted(
        quote do
          use Xitdb.DSL

          datalog do
            find {id}
            where [foo(id).bar == 1]
          end
        end
      )
    end
  end
end
