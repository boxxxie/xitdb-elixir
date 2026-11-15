defmodule Xitdb.Features.QueriesAndDatalogSpec do
  use Xitdb.FeatureCase, async: true

  scenario "client queries nested paths with ~x selector sigils and Datomic-style pull projections" do
    @given memory_database()
    @given committed_moment(%{
             "users" => %{
               "101" => %{
                 "username" => "dan",
                 "age" => 29,
                 "todos" => ["design schema", "write specs", "ship nif", "celebrate"],
                 "profile" => %{"city" => "Montreal", "tier" => "pro"}
               }
             }
           })

    @upon selecting_path(:second_todo, ~x|.users["101"].todos[1]|)
    @upon pulling_projection(
            :user_card,
            ["users", "101"],
            "{username, age, todos[0..2], profile{city}}"
          )

    @then resolved_value_is(:second_todo, "write specs")
    @then resolved_value_is(:user_card, %{
            "username" => "dan",
            "age" => 29,
            "todos" => ["design schema", "write specs"],
            "profile" => %{"city" => "Montreal"}
          })
  end

  scenario "client executes Datalog queries with secondary index pushdown, negated sets, and aggregations" do
    @given memory_database()
    @given secondary_index_rule("users", "username", "username->id")
    @given committed_moment(%{
             "users" => %{
               "u1" => %{
                 "username" => "dan",
                 "dept" => "eng",
                 "salary" => 120,
                 "flags" => Xitdb.hash_set(["active"])
               },
               "u2" => %{
                 "username" => "daria",
                 "dept" => "eng",
                 "salary" => 140,
                 "flags" => Xitdb.hash_set(["active"])
               },
               "u3" => %{
                 "username" => "dave",
                 "dept" => "eng",
                 "salary" => 110,
                 "flags" => Xitdb.hash_set(["suspended"])
               },
               "u4" => %{
                 "username" => "alice",
                 "dept" => "design",
                 "salary" => 130,
                 "flags" => Xitdb.hash_set(["active"])
               }
             }
           })

    @upon querying_datalog(
            :prefix_active_da,
            ~q"""
            find ?name, ?salary
            where
              $username->id[?name] = ?id
              starts_with(?name, "da")
              .users[?id].salary = ?salary
              not .users[?id].flags%"suspended"
            """
          )

    @upon querying_datalog(
            :dept_rollup,
            ~q"""
            find ?dept, count(?id), sum(?salary)
            where
              .users[?id].dept = ?dept
              .users[?id].salary = ?salary
              not .users[?id].flags%"suspended"
            """
          )

    @upon querying_datalog(
            :comma_separated_single_line,
            ~q|find ?name, ?salary where $username->id[?name] = ?id, .users[?id].salary = ?salary, ?salary > 125, not .users[?id].flags%"suspended"|
          )

    @then datalog_rows_are(:prefix_active_da, [
            ["dan", 120],
            ["daria", 140]
          ])

    @then datalog_rows_are(:dept_rollup, [
            ["eng", 2, 260],
            ["design", 1, 130]
          ])

    @then datalog_rows_are(:comma_separated_single_line, [
            ["alice", 130],
            ["daria", 140]
          ])
  end

  scenario "file-backed database persists across reopens and compacts historical moments into a smaller file" do
    @given file_database("primary")
    @given committed_moment(%{"counter" => 1, "scratch" => String.duplicate("a", 2048)})
    @given committed_moment(%{"counter" => 2, "scratch" => String.duplicate("b", 2048)})
    @given committed_moment(%{"counter" => 3, "scratch" => "compact-final"})

    @upon reopening_file_database("primary")
    @upon compacting_database("compacted")

    @then database_moment_count_is(3)
    @then access_path_equals(["counter"], 3)
    @then compacted_database_shrinks_and_preserves(["scratch"], "compact-final")
  end

  scenario "Xitdb.DSL.datalog supports inline path comparisons, independent wildcards, and negated string predicates" do
    @given memory_database()
    @given committed_moment(%{
             "users" => %{
               "u1" => %{
                 "tag_a" => 1,
                 "tag_b" => 2,
                 "salary" => 130,
                 "username" => "alice",
                 "bio" => "distributed systems"
               },
               "u2" => %{
                 "tag_a" => 5,
                 "tag_b" => 6,
                 "salary" => 140,
                 "username" => "adm_bob",
                 "bio" => "human"
               },
               "u3" => %{
                 "tag_a" => 7,
                 "tag_b" => 8,
                 "salary" => 125,
                 "username" => "carol",
                 "bio" => "support_bot"
               },
               "u4" => %{
                 "tag_a" => 9,
                 "tag_b" => 10,
                 "salary" => 115,
                 "username" => "dave",
                 "bio" => "human"
               }
             }
           })

    @upon querying_datalog(
            :filtered_staff,
            datalog do
              find {id, name, salary}

              where [
                users[id].tag_a == _,
                users[id].tag_b == _,
                users[id].salary >= 120,
                145 > users[id].salary,
                salary == users[id].salary,
                name == users[id].username,
                bio == users[id].bio,
                not starts_with(name, "adm_"),
                not contains(bio, "bot")
              ]
            end
          )

    @then datalog_rows_are(:filtered_staff, [
            ["u1", "alice", 130]
          ])
  end
end
