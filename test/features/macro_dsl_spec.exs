defmodule Xitdb.Features.MacroDslSpec do
  use Xitdb.FeatureCase, async: true

  scenario "Xitdb.DSL.tx compiles deep mutations, native list ops, forks, and read-modify-write updates in one atomic commit" do
    @given memory_database()
    @given committed_moment(%{
             "users" => %{
               "alice" => %{
                 "role" => "member",
                 "login_count" => 4,
                 "temp_token" => "tok-123",
                 "audit_log" => ["created"],
                 "todos" => Xitdb.linked_list(["t1", "t2", "t3", "t4", "t5"])
               }
             }
           })

    @upon executing_dsl_transaction(fn db ->
            id = "alice"
            new_user = "bob"

            tx db, doc: "promote alice and initialize bob" do
              # Auto-vivifies missing intermediate maps with 0 NIF reads
              put users[new_user].profile.city, "Tokyo"
              put users[id].role, "admin"

              # Native list, slice, fork, and removal ops
              append users[id].audit_log, "promoted"
              insert users[id].todos[[0]], "urgent-t0"
              slice users[id].todos, 0..3
              fork users[id], backups[id]
              rm users[id].temp_token

              # Read-modify-write update (works on existing, newly created, and nested map-staged paths)
              put users["carol"], %{"login_count" => 10}
              update users["carol"].login_count, &(&1 + 5)
              update users[id].login_count, &((&1 || 0) + 1)
              update users[new_user].login_count, &((&1 || 0) + 1)
            end
          end)

    @then database_moment_count_is(2)
    @then access_path_equals(["users", "alice", "role"], "admin")
    @then access_path_equals(["users", "alice", "login_count"], 5)
    @then access_path_equals(["users", "alice", "temp_token"], nil)
    @then access_path_equals(["users", "alice", "audit_log"], ["created", "promoted"])
    @then access_path_equals(["users", "alice", "todos"], ["urgent-t0", "t1", "t2", "t3"])
    @then access_path_equals(["backups", "alice", "role"], "admin")
    @then access_path_equals(["backups", "alice", "temp_token"], "tok-123")
    @then access_path_equals(["users", "bob", "profile", "city"], "Tokyo")
    @then access_path_equals(["users", "bob", "login_count"], 1)
    @then access_path_equals(["users", "carol", "login_count"], 15)
  end

  scenario "Xitdb.DSL.tx rolls back atomically when abort/1 is invoked inside the block" do
    @given memory_database()
    @given committed_moment(%{"vault" => %{"balance" => 1000}})

    @upon attempting_failing_dsl_transaction(fn db ->
            tx db do
              put vault.balance, 0
              abort :unauthorized_withdrawal
            end
          end)

    @then last_transaction_failed_with(:unauthorized_withdrawal)
    @then database_moment_count_is(1)
    @then access_path_equals(["vault", "balance"], 1000)
  end

  scenario "path/1 and structural pull patterns interpolate variables and preserve collection tags" do
    @given memory_database()
    @given committed_moment(%{
             "org" => %{
               "departments" =>
                 Xitdb.counted_map(%{
                   "eng" => %{
                     "directory" =>
                       Xitdb.sorted_map(%{
                         "101" => %{
                           "username" => "dan",
                           "age" => 29,
                           "todos" =>
                             Xitdb.linked_list([
                               "design schema",
                               "write specs",
                               "ship dsl",
                               "celebrate"
                             ]),
                           "profile" => %{"city" => "Montreal", "tier" => "pro"}
                         }
                       })
                   }
                 })
             }
           })

    @upon selecting_path(
            :third_todo,
            path(org.counted(:departments)["eng"].sorted(:directory)["101"].todos[[2]])
          )
    @upon pulling_projection(
            :structured_card,
            path(org.counted(:departments)["eng"].sorted(:directory)["101"]),
            [
              :username,
              :age,
              todos: 0..2,
              profile: [:city]
            ]
          )

    @then resolved_value_is(:third_todo, "ship dsl")
    @then resolved_value_is(:structured_card, %{
            "username" => "dan",
            "age" => 29,
            "todos" => ["design schema", "write specs"],
            "profile" => %{"city" => "Montreal"}
          })
  end

  scenario "Xitdb.DSL.datalog compiles entity bindings, pinned runtime variables, negated sets, and aggregations" do
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
            :pinned_index_query,
            (
              prefix = "da"
              min_salary = 115

              datalog do
                find {name, salary}

                where [
                  sorted("username->id")[name] == id,
                  starts_with(name, ^prefix),
                  users[id].salary == salary,
                  salary >= ^min_salary,
                  not users[id].flags.set_member("suspended")
                ]
              end
            )
          )

    @upon querying_datalog(
            :entity_alias_rollup,
            (
              excluded_flag = "suspended"

              datalog do
                find {dept, count(u), sum(salary)}

                where [
                  u <- users,
                  u.dept == dept,
                  u.salary == salary,
                  not u.flags.set_member(^excluded_flag)
                ]
              end
            )
          )

    @then datalog_rows_are(:pinned_index_query, [
            ["dan", 120],
            ["daria", 140]
          ])

    @then datalog_rows_are(:entity_alias_rollup, [
            ["eng", 2, 260],
            ["design", 1, 130]
          ])
  end

  scenario "tx supports index_on, init_col, reset_col, and base_moment branching while at_moment/2 and pull_pattern/1 project historical and nested list slices" do
    @given memory_database()
    @given committed_moment(%{
             "config" => %{"env" => "staging"},
             "cache" => %{"stale" => "yes"}
           })

    @upon executing_dsl_transaction(fn db ->
            tx db, doc: "initialize indexes, collections, and team roster" do
              index_on :accounts, :email, "email->id"
              init_col metrics.counters, :counted_hash_map
              reset_col :cache, :hash_map

              put config.env, "prod"

              put accounts["a1"], %{
                "email" => "alice.liddell@example.com",
                "team" => [
                  %{"username" => "bob", "profile" => %{"city" => "Tokyo", "tier" => "pro"}},
                  %{"username" => "carol", "profile" => %{"city" => "Paris", "tier" => "free"}},
                  %{"username" => "dave", "profile" => %{"city" => "Berlin", "tier" => "pro"}}
                ]
              }
            end
          end)

    @upon selecting_path(:v0_env, path(at_moment(0, config.env)))
    @upon selecting_path(
            :indexed_account_id,
            path(sorted("email->id")["alice.liddell@example.com"])
          )
    @upon pulling_projection(
            :account_team_slice,
            path(accounts["a1"]),
            pull_pattern([
              :email,
              team: {0..2, [:username, profile: [:city]]}
            ])
          )

    @then resolved_value_is(:v0_env, "staging")
    @then resolved_value_is(:indexed_account_id, "a1")
    @then access_path_equals(["config", "env"], "prod")
    @then access_path_equals(["cache"], %{})
    @then enumerable_count_is(["metrics", "counters"], 0)
    @then resolved_value_is(:account_team_slice, %{
            "email" => "alice.liddell@example.com",
            "team" => [
              %{"username" => "bob", "profile" => %{"city" => "Tokyo"}},
              %{"username" => "carol", "profile" => %{"city" => "Paris"}}
            ]
          })
  end

  scenario "datalog supports top-level from clause, min/max aggregations, contains predicate, sorted/counted sets, and historical moment queries" do
    @given memory_database()
    @given committed_moment(%{
             "employees" => %{
               "e1" => %{
                 "email" => "dan@eng.acme.io",
                 "salary" => 100,
                 "perms" => Xitdb.counted_set(["deploy", "read"]),
                 "badges" => Xitdb.sorted_set(["elixir", "odin"])
               },
               "e2" => %{
                 "email" => "daria@eng.acme.io",
                 "salary" => 200,
                 "perms" => Xitdb.counted_set(["deploy", "admin"]),
                 "badges" => Xitdb.sorted_set(["odin", "zig"])
               },
               "e3" => %{
                 "email" => "guest@contractor.org",
                 "salary" => 90,
                 "perms" => Xitdb.counted_set(["read"]),
                 "badges" => Xitdb.sorted_set(["elixir"])
               }
             }
           })
    @given committed_moment(%{
             "employees" => %{
               "e1" => %{
                 "email" => "dan@eng.acme.io",
                 "salary" => 300,
                 "perms" => Xitdb.counted_set(["deploy"]),
                 "badges" => Xitdb.sorted_set(["odin"])
               }
             }
           })

    @upon querying_datalog(
            :v0_stats,
            (
              domain_tag = "@eng.acme.io"
              required_perm = "deploy"
              required_badge = "odin"

              datalog do
                find {min(salary), max(salary), count(email)}
                from e in employees

                where [
                  e.email == email,
                  contains(email, ^domain_tag),
                  e.perms.counted_set_member(^required_perm),
                  e.badges.sorted_set_member(^required_badge),
                  e.salary == salary
                ]
              end
            ),
            moment: 0
          )

    @then datalog_rows_are(:v0_stats, [[100, 200, 2]])
  end

  scenario "tx supports 1-arity set member put, 3-arity update with default, instant, meta, and savepoint" do
    @given memory_database()
    @given committed_moment(
             %{
               "users" => %{
                 "alice" => %{
                   "role" => "member",
                   "flags" => Xitdb.hash_set(["active"]),
                   "badges" => Xitdb.sorted_set(["elixir"])
                 }
               }
             },
             doc: "seed alice",
             instant: 1_700_000_000_000
           )

    @upon executing_dsl_transaction(fn db ->
            id = "alice"

            tx db, doc: "grant admin and track metadata", instant: 1_700_000_060_000 do
              meta(:author, "system")
              meta("trace_id", "req-42")

              # 1-arity put on set members (symmetrical with rm)
              put(users[id].flags.set_member("staff"))
              put(users[id].badges.sorted_set_member("odin"))

              # 3-arity update with default when key does not exist yet
              update(users[id].login_count, 0, &(&1 + 1))
              update(users[id].login_count, 0, &(&1 + 4))

              # Explicit savepoint + mutation
              savepoint()
              put users[id].role, "admin"
            end
          end)

    @upon inspecting_history_of(:role_history, path(users["alice"].role))

    @then access_path_equals(["users", "alice", "login_count"], 5)
    @then enumerable_membership_is(["users", "alice", "flags"], "staff", true)
    @then enumerable_membership_is(["users", "alice", "badges"], "odin", true)
    @then access_path_equals(["__tx", "author"], "system")
    @then access_path_equals(["__tx", "trace_id"], "req-42")
    @then history_lineage_is(:role_history, [
            %{moment: 0, value: "member", doc: "seed alice", instant: 1_700_000_000_000},
            %{
              moment: 1,
              value: "admin",
              doc: "grant admin and track metadata",
              instant: 1_700_000_060_000
            }
          ])
  end

  scenario "datalog supports transitive reach/3,4 graph traversal, per-clause at_moment/2 temporal queries, and key existence checks" do
    @given memory_database()
    @given committed_moment(
             %{
               "users" => %{
                 "alice" => %{
                   "salary" => 100,
                   "reports" => ["bob", "carol"]
                 },
                 "bob" => %{
                   "salary" => 90,
                   "reports" => ["dave"],
                   "temp_token" => "tok-bob"
                 },
                 "carol" => %{
                   "salary" => 95,
                   "reports" => []
                 },
                 "dave" => %{
                   "salary" => 80,
                   "reports" => []
                 }
               }
             },
             doc: "initial org chart"
           )
    @given committed_moment(
             %{
               "users" => %{
                 "alice" => %{
                   "salary" => 130,
                   "reports" => ["bob", "carol"]
                 },
                 "bob" => %{
                   "salary" => 110,
                   "reports" => ["dave"],
                   "temp_token" => "tok-bob"
                 },
                 "carol" => %{
                   "salary" => 95,
                   "reports" => []
                 },
                 "dave" => %{
                   "salary" => 85,
                   "reports" => []
                 }
               }
             },
             doc: "annual raises"
           )

    @upon querying_datalog(
            :transitive_reports,
            (
              root_mgr = "alice"

              datalog do
                find {report, depth}

                where [
                  mgr == ^root_mgr,
                  reach(mgr, report, depth, users[mgr].reports[idx] == report),
                  not users[report].temp_token
                ]
              end
            )
          )

    @upon querying_datalog(
            :cross_moment_raises,
            datalog do
              find {id, old_salary, new_salary}

              where [
                at_moment(0, users[id].salary) == old_salary,
                at_moment(1, users[id].salary) == new_salary,
                new_salary > old_salary
              ]
            end
          )

    @upon querying_datalog(
            :alice_salary_timeline,
            datalog do
              find {m, sal}

              where [
                at_moment(m, users["alice"].salary) == sal
              ]
            end
          )

    @then datalog_rows_are(:transitive_reports, [
            ["carol", 1],
            ["dave", 2]
          ])
    @then datalog_rows_are(:cross_moment_raises, [
            ["alice", 100, 130],
            ["bob", 90, 110],
            ["dave", 80, 85]
          ])
    @then datalog_rows_are(:alice_salary_timeline, [
            [0, 100],
            [1, 130]
          ])
  end
end
