defmodule Xitdb.Features.MacroDslPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Xitdb.DSL

  alias Xitdb.Pull

  # ============================================================================
  # Generators
  # ============================================================================

  defp key_gen do
    string(:alphanumeric, min_length: 1, max_length: 12)
  end

  defp scalar_gen do
    one_of([
      string(:alphanumeric, min_length: 1, max_length: 24),
      integer(-50_000..50_000),
      float(min: -1.0e3, max: 1.0e3),
      boolean()
    ])
  end

  defp entity_gen do
    fixed_map(%{
      "username" => string(:alphanumeric, min_length: 2, max_length: 12),
      "age" => integer(18..90),
      "active" => boolean(),
      "score" => integer(-1_000..1_000),
      "todos" =>
        list_of(string(:alphanumeric, min_length: 1, max_length: 16),
          min_length: 1,
          max_length: 8
        ),
      "profile" =>
        fixed_map(%{
          "city" => string(:alphanumeric, min_length: 2, max_length: 12),
          "tier" => member_of(["free", "pro", "enterprise"]),
          "team" => string(:alphanumeric, min_length: 2, max_length: 10)
        })
    })
  end

  # ============================================================================
  # 1. Path Selector Properties (`Xitdb.DSL.path/1` & `Xitdb.select!/2`)
  # ============================================================================

  property "path/1 selectors across counted, sorted, array, and linked collections resolve identically to lazy Access navigation" do
    check all(
            dept_id <- key_gen(),
            user_id <- key_gen(),
            todos <- list_of(scalar_gen(), min_length: 1, max_length: 6),
            metrics <- list_of(integer(1..1_000), min_length: 1, max_length: 6),
            todo_idx <- integer(0..(length(todos) - 1)),
            metric_idx <- integer(0..(length(metrics) - 1)),
            max_runs: 40
          ) do
      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        payload = %{
          "org" => %{
            "departments" =>
              Xitdb.counted_map(%{
                dept_id => %{
                  "directory" =>
                    Xitdb.sorted_map(%{
                      user_id => %{
                        "todos" => Xitdb.linked_list(todos),
                        "metrics" => Xitdb.array_list(metrics)
                      }
                    })
                }
              })
          }
        }

        {:ok, db} = Xitdb.transact(db, payload)
        root = Xitdb.db(db)

        # Chained container-modifier AST form
        chained_todo_sel =
          path(org.counted(:departments)[dept_id].sorted(:directory)[user_id].todos[[todo_idx]])

        # Step-list AST form
        list_todo_sel =
          path([
            :org,
            :departments,
            {:counted, dept_id},
            :directory,
            {:sorted, user_id},
            :todos,
            [todo_idx]
          ])

        metric_sel =
          path(org.counted(:departments)[dept_id].sorted(:directory)[user_id].metrics[metric_idx])

        expected_todo =
          root["org"]["departments"][dept_id]["directory"][user_id]["todos"][todo_idx]

        expected_metric =
          root["org"]["departments"][dept_id]["directory"][user_id]["metrics"][metric_idx]

        assert chained_todo_sel == list_todo_sel
        assert Xitdb.select!(db, chained_todo_sel) == expected_todo
        assert Xitdb.select!(db, metric_sel) == expected_metric
        assert expected_todo == Enum.at(todos, todo_idx)
        assert expected_metric == Enum.at(metrics, metric_idx)
      after
        Xitdb.close(db)
      end
    end
  end

  # ============================================================================
  # 2. Structural Pull Properties (`Xitdb.Pull` & `Xitdb.pull!/2`)
  # ============================================================================

  property "structural pull patterns compile and project the exact subset of fields and list slices as materialized Elixir maps" do
    check all(
            entity <- entity_gen(),
            scalar_fields <-
              list_of(member_of([:username, :age, :active, :score]),
                min_length: 1,
                max_length: 4
              )
              |> map(&Enum.uniq/1),
            profile_fields <-
              list_of(member_of([:city, :tier, :team]), min_length: 1, max_length: 3)
              |> map(&Enum.uniq/1),
            slice_start <- integer(0..(length(entity["todos"]) - 1)),
            slice_len <- integer(1..length(entity["todos"])),
            max_runs: 40
          ) do
      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        {:ok, db} = Xitdb.transact(db, %{"entity" => entity})
        cursor = Xitdb.db(db)["entity"]

        pattern =
          scalar_fields ++
            [
              todos: {:slice, slice_start, slice_len},
              profile: profile_fields
            ]

        compiled_str = Pull.compile!(pattern)
        pulled_via_list = Xitdb.pull!(cursor, pattern)
        pulled_via_str = Xitdb.pull!(cursor, compiled_str)

        assert pulled_via_list == pulled_via_str

        scalar_keys = Enum.map(scalar_fields, &Atom.to_string/1)
        profile_keys = Enum.map(profile_fields, &Atom.to_string/1)

        expected =
          entity
          |> Map.take(scalar_keys)
          |> Map.put("todos", Enum.slice(entity["todos"], slice_start, slice_len))
          |> Map.put("profile", Map.take(entity["profile"], profile_keys))

        assert pulled_via_list == expected
      after
        Xitdb.close(db)
      end
    end
  end

  # ============================================================================
  # 3. Transaction DSL Round-Trip Properties (`Xitdb.DSL.tx/2`)
  # ============================================================================

  property "Xitdb.DSL.tx mutations (put, update, append, insert, slice, fork, rm) match an Elixir reference state while preserving moment 0" do
    check all(
            user_id <- key_gen(),
            initial_count <- integer(0..500),
            delta <- integer(1..100),
            initial_todos <- list_of(key_gen(), min_length: 3, max_length: 6),
            inserted_todo <- key_gen(),
            insert_idx <- integer(0..2),
            slice_len <- integer(2..3),
            appended_log <- key_gen(),
            new_city <- key_gen(),
            max_runs: 40
          ) do
      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        initial_state = %{
          "users" => %{
            user_id => %{
              "login_count" => initial_count,
              "temp_token" => "ephemeral",
              "audit_log" => ["init"],
              "todos" => Xitdb.linked_list(initial_todos)
            }
          }
        }

        {:ok, db} = Xitdb.transact(db, initial_state)
        v0_snapshot = Xitdb.as_of(db, 0)

        {:ok, db} =
          tx db, doc: "property mutation batch" do
            fork users[user_id], backups[user_id]
            put users[user_id].profile.city, new_city
            append users[user_id].audit_log, appended_log
            insert users[user_id].todos[[insert_idx]], inserted_todo
            slice users[user_id].todos, 0..(slice_len - 1)
            rm users[user_id].temp_token
            update users[user_id].login_count, &((&1 || 0) + delta)
          end

        expected_todos =
          initial_todos
          |> List.insert_at(insert_idx, inserted_todo)
          |> Enum.slice(0, slice_len)

        root = Xitdb.db(db)
        user_cur = root["users"][user_id]
        backup_cur = root["backups"][user_id]

        assert Xitdb.materialize(user_cur) == %{
                 "login_count" => initial_count + delta,
                 "audit_log" => ["init", appended_log],
                 "todos" => expected_todos,
                 "profile" => %{"city" => new_city}
               }

        # Forked backup must preserve pre-mutation fields from the savepoint
        assert Xitdb.materialize(backup_cur) == %{
                 "login_count" => initial_count,
                 "temp_token" => "ephemeral",
                 "audit_log" => ["init"],
                 "todos" => initial_todos
               }

        # Moment 0 snapshot remains completely untouched
        assert v0_snapshot["users"][user_id]["login_count"] == initial_count
        assert v0_snapshot["users"][user_id]["temp_token"] == "ephemeral"
      after
        Xitdb.close(db)
      end
    end
  end

  # ============================================================================
  # 4. Datalog DSL Properties (`Xitdb.DSL.query!/2`)
  # ============================================================================

  property "Xitdb.DSL.query! with pinned runtime variables matches Elixir Enum filtering and aggregation" do
    user_row_gen =
      fixed_map(%{
        "dept" => member_of(["eng", "design", "ops"]),
        "salary" => integer(80..250),
        "suspended" => boolean()
      })

    check all(
            users_map <- map_of(key_gen(), user_row_gen, min_length: 1, max_length: 10),
            target_dept <- member_of(["eng", "design", "ops"]),
            min_salary <- integer(80..200),
            max_runs: 35
          ) do
      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        db_users =
          Map.new(users_map, fn {id, u} ->
            flags = if u["suspended"], do: ["suspended"], else: ["active"]

            {id,
             %{
               "dept" => u["dept"],
               "salary" => u["salary"],
               "flags" => Xitdb.hash_set(flags)
             }}
          end)

        {:ok, db} = Xitdb.transact(db, %{"users" => db_users})

        res =
          query! db do
            find {u, salary}

            where [
              u <- users,
              u.dept == ^target_dept,
              u.salary == salary,
              salary >= ^min_salary,
              not u.flags.set_member("suspended")
            ]
          end

        expected_rows =
          users_map
          |> Enum.filter(fn {_id, u} ->
            u["dept"] == target_dept and u["salary"] >= min_salary and not u["suspended"]
          end)
          |> Enum.map(fn {id, u} -> [id, u["salary"]] end)
          |> Enum.sort()

        assert Enum.sort(res.rows) == expected_rows
      after
        Xitdb.close(db)
      end
    end
  end

  # ============================================================================
  # 5. Special-Character Key Escaping Properties (`path/1` & `tx/2`)
  # ============================================================================

  property "dynamic keys containing dots, brackets, spaces, and sigil characters round-trip through tx and path/1" do
    special_key_gen =
      map(
        {
          string(:alphanumeric, min_length: 1, max_length: 6),
          member_of([".", "#", "$", "%", "^", " ", "[", "]"]),
          string(:alphanumeric, min_length: 1, max_length: 6)
        },
        fn {a, sep, b} -> a <> sep <> b end
      )

    check all(
            special_key <- special_key_gen,
            initial_val <- integer(1..1_000),
            delta <- integer(1..500),
            max_runs: 35
          ) do
      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        {:ok, db} =
          tx db do
            put accounts[special_key].balance, initial_val
            update accounts[special_key].balance, &(&1 + delta)
          end

        sel = path(accounts[special_key].balance)
        assert Xitdb.select!(db, sel) == initial_val + delta
        assert Xitdb.db(db)["accounts"][special_key]["balance"] == initial_val + delta
      after
        Xitdb.close(db)
      end
    end
  end

  # ============================================================================
  # 6. Set Member Put, Default Update, Temporal Datalog & Sigil Coexistence
  # ============================================================================

  property "tx 1-arity set put, 3-arity update with default, and temporal/sigil query! calls agree across moments" do
    check all(
            user_id <- key_gen(),
            flag_a <- key_gen(),
            flag_b <- key_gen(),
            default_score <- integer(10..100),
            bonus <- integer(1..50),
            instant_ms <- integer(1_700_000_000_000..1_800_000_000_000),
            max_runs: 35
          ) do
      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        db =
          tx! db, doc: "m0", instant: instant_ms do
            init_col users[user_id].flags, :counted_hash_set
            put(users[user_id].flags.counted_set_member(flag_a))
            update(users[user_id].score, default_score, &(&1 + bonus))
          end

        db =
          tx! db, doc: "m1", instant: instant_ms + 1_000 do
            put(users[user_id].flags.counted_set_member(flag_b))
            update(users[user_id].score, default_score, &(&1 + bonus))
          end

        assert Enum.member?(db["users"][user_id]["flags"], flag_a)
        assert Enum.member?(db["users"][user_id]["flags"], flag_b)
        assert db["users"][user_id]["score"] == default_score + 2 * bonus

        # Coexistence of `query!(db, ~q"...")` and `query!(db) do ... end` when `use Xitdb.DSL` is active
        sigil_res = query!(db, ~q"find ?u, ?s where .users[?u].score = ?s")
        assert sigil_res.rows == [[user_id, default_score + 2 * bonus]]

        timeline_res =
          query! db do
            find {m, s}

            where [
              at_moment(m, users[^user_id].score) == s
            ]
          end

        assert timeline_res.rows == [
                 [0, default_score + bonus],
                 [1, default_score + 2 * bonus]
               ]
      after
        Xitdb.close(db)
      end
    end
  end
end
