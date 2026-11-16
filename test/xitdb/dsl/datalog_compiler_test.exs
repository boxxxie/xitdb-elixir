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

  test "multiple _ wildcards stay independent, inline path comparisons and negated predicates execute end-to-end" do
    {:ok, db} = Xitdb.open(backend: :memory)

    try do
      {:ok, db} =
        Xitdb.transact(db, %{
          "users" => %{
            "u1" => %{
              "a" => 1,
              "b" => 2,
              "age" => 25,
              "name" => "alice",
              "bio" => "human",
              "dept" => "eng",
              "tags" => %{"core" => true}
            },
            "u2" => %{
              "a" => 5,
              "b" => 5,
              "age" => 19,
              "name" => "adm_bob",
              "bio" => "human",
              "dept" => "eng",
              "tags" => %{"core" => true}
            },
            "u3" => %{
              "a" => 7,
              "b" => 9,
              "age" => 29,
              "name" => "carol",
              "bio" => "helper_bot",
              "dept" => "sales",
              "tags" => %{"ext" => true}
            },
            "u4" => %{
              "a" => 3,
              "b" => 4,
              "age" => 35,
              "name" => "dave",
              "bio" => "human",
              "dept" => "ops",
              "tags" => %{"core" => true}
            }
          }
        })

      q_wildcards =
        datalog do
          find {id, has_tag}

          where [
            users[id].a == _,
            users[id].b == _,
            users[id].tags[_] == has_tag
          ]
        end

      res_wild = Xitdb.query!(db, q_wildcards)
      assert Enum.sort(res_wild.rows) == [["u1", true], ["u2", true], ["u3", true], ["u4", true]]

      q_cmp_and_neg =
        datalog do
          find {id, name, age}

          where [
            users[id].age >= 21,
            30 > users[id].age,
            age == users[id].age,
            21 <= age,
            name == users[id].name,
            bio == users[id].bio,
            dept == users[id].dept,
            not starts_with(name, "adm"),
            not contains(bio, "bot"),
            not (dept == "ops")
          ]
        end

      res_cmp = Xitdb.query!(db, q_cmp_and_neg)
      assert res_cmp.rows == [["u1", "alice", 25]]
    after
      :ok = Xitdb.close(db)
    end
  end

  test "BUG-032/033/034/055: chained <- bindings, Access.get/dot from without trailing alias, find_vars root, and inline do: options" do
    db = Xitdb.open!(backend: :memory)

    try do
      db =
        Xitdb.transact!(db, %{
          "tenants" => %{
            "acme" => %{
              "u1" => %{
                "email" => "ada@acme.test",
                "todos" => %{"t1" => %{"title" => "ship"}}
              }
            }
          },
          "nodes" => %{
            "n1" => %{"next" => "n2"},
            "n2" => %{"next" => "n3"},
            "n3" => %{}
          }
        })

      tenant = "acme"

      # BUG-055 & BUG-033: inline `, do:` with `from:` option + Access.get source without trailing alias
      rows_inline =
        query!(
          db,
          from: tenants[^tenant],
          do:
            (
              find {u, email}
              where u.email == email
            )
        ).rows

      assert rows_inline == [["u1", "ada@acme.test"]]

      # BUG-032: chained `<-` using previously bound variable `u`
      chained_q =
        datalog do
          find {u, title}

          where [
            u <- tenants[^tenant],
            t <- u["todos"],
            t.title == title
          ]
        end

      assert Xitdb.query!(db, chained_q).rows == [["u1", "ship"]]

      # BUG-034: find_vars / reach_vars variable as root of Access.get path
      find_root_q =
        datalog do
          find {n, nxt}

          where [
            nodes[n]["next"] == nxt,
            n == "n1"
          ]
        end

      assert Xitdb.query!(db, find_root_q).rows == [["n1", "n2"]]

      # Also test find var as root of bracket access `u["email"]` without binding
      user_root_q =
        datalog do
          find {u, e}

          where [
            tenants[^tenant][u] == _,
            tenants[^tenant][u]["email"] == e
          ]
        end

      assert Xitdb.query!(db, user_root_q).rows == [["u1", "ada@acme.test"]]

      # Top-level find var as direct root of bracket access `n["next"]` in `reach`
      db_graph =
        Xitdb.transact!(db, %{
          "a1" => %{"next" => "a2"},
          "a2" => %{"next" => "a3"},
          "a3" => %{}
        })

      reach_q =
        datalog do
          find {b}

          where [
            reach(a, b, a["next"] == b),
            a == "a1"
          ]
        end

      assert Enum.sort(Xitdb.query!(db_graph, reach_q).rows) == [["a2"], ["a3"]]
    after
      :ok = Xitdb.close(db)
    end
  end
end
