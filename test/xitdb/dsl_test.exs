defmodule Xitdb.DSLTest do
  use ExUnit.Case, async: true

  test "pull_pattern/1 expands static patterns at compile time and falls back to runtime for dynamic patterns" do
    env = %{__ENV__ | requires: [Xitdb.DSL | __ENV__.requires]}

    # Static pattern with atoms, strings, nested list, range, stepped range, slice, tuple, negative int
    static_ast =
      quote do
        Xitdb.DSL.pull_pattern([
          :name,
          "email",
          profile: [:city],
          todos: 0..2,
          logs: 0..2//1,
          items: {:slice, 1, 3},
          friends: {0..1, [:name]}
        ])
      end

    expanded_static = Macro.expand(static_ast, env)
    assert is_binary(expanded_static)

    assert expanded_static ==
             "{name, email, profile{city}, todos[0..3], logs[0..3], items[1..4], friends[0..2]{name}}"

    # Static string key with nested value
    str_kv_ast = quote(do: Xitdb.DSL.pull_pattern([{"profile", [:city]}]))
    assert Macro.expand(str_kv_ast, env) == "{profile{city}}"

    # Negative int inside static range fails Pull.compile! at expansion time
    assert_raise ArgumentError, fn ->
      Macro.expand(quote(do: Xitdb.DSL.pull_pattern(todos: -1..2)), env)
    end

    # Dynamic element in list falls back to runtime Xitdb.Pull.compile!/1
    dyn_elem_ast = quote(do: Xitdb.DSL.pull_pattern([var!(field_var)]))
    expanded_dyn_elem = Macro.expand(dyn_elem_ast, env)
    assert Macro.to_string(expanded_dyn_elem) =~ "Xitdb.Pull.compile!"
    assert {res, _} = Code.eval_quoted(expanded_dyn_elem, [field_var: :username], env)
    assert res == "{username}"

    # Non-list dynamic variable falls back to runtime Xitdb.Pull.compile!/1
    dyn_var_ast = quote(do: Xitdb.DSL.pull_pattern(var!(pat_var)))
    expanded_dyn_var = Macro.expand(dyn_var_ast, env)
    assert Macro.to_string(expanded_dyn_var) =~ "Xitdb.Pull.compile!"
    assert {res2, _} = Code.eval_quoted(expanded_dyn_var, [pat_var: [:age]], env)
    assert res2 == "{age}"

    # Dynamic slice offset falls back to runtime
    dyn_slice_ast = quote(do: Xitdb.DSL.pull_pattern(items: {:slice, var!(off_var), 2}))
    expanded_dyn_slice = Macro.expand(dyn_slice_ast, env)
    assert {res3, _} = Code.eval_quoted(expanded_dyn_slice, [off_var: 3], env)
    assert res3 == "{items[3..5]}"

    # Dynamic tuple nested pattern (non-list second element) falls back to runtime
    dyn_tuple_ast = quote(do: Xitdb.DSL.pull_pattern(friends: {0..1, var!(nested_var)}))
    expanded_dyn_tuple = Macro.expand(dyn_tuple_ast, env)
    assert {res4, _} = Code.eval_quoted(expanded_dyn_tuple, [nested_var: [:id]], env)
    assert res4 == "{friends[0..2]{id}}"
  end

  test "tx/2 and tx!/2 validate keyword :do blocks at macro expansion time" do
    env = %{__ENV__ | requires: [Xitdb.DSL | __ENV__.requires]}
    db = Xitdb.open!(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    # Valid tx/2 and tx!/2 with do: block
    tx_ast =
      quote do
        Xitdb.DSL.tx(var!(db), doc: "m1", do: put(users.alice.name, "Alice"))
      end

    assert {{:ok, db}, _} = Code.eval_quoted(Macro.expand(tx_ast, env), [db: db], env)
    assert Xitdb.db(db)["users"]["alice"]["name"] == "Alice"

    tx_bang_ast =
      quote do
        Xitdb.DSL.tx!(var!(db), do: put(users.alice.role, "admin"))
      end

    assert {db, _} = Code.eval_quoted(Macro.expand(tx_bang_ast, env), [db: db], env)
    assert Xitdb.db(db)["users"]["alice"]["role"] == "admin"

    # Invalid keyword list without :do raises ArgumentError
    assert_raise ArgumentError, ~r/expected a :do block/, fn ->
      Macro.expand(quote(do: Xitdb.DSL.tx(var!(db), doc: "no_do")), env)
    end

    # Invalid non-keyword list raises ArgumentError
    assert_raise ArgumentError, ~r/expected a :do block/, fn ->
      Macro.expand(quote(do: Xitdb.DSL.tx!(var!(db), [:not_kw])), env)
    end
  end

  test "query/2, query/3, query!/2, and query!/3 expand both block and raw string forms at runtime" do
    env = %{__ENV__ | requires: [Xitdb.DSL | __ENV__.requires]}
    db = Xitdb.open!(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    db = Xitdb.transact!(db, %{"users" => %{"u1" => %{"name" => "Ada"}}})

    # 1. query/2 with do: block and :from option
    q2_block =
      quote do
        Xitdb.DSL.query(var!(db),
          from: users,
          do:
            (
              find({name})
              where([e.name == name])
            )
        )
      end

    assert {{:ok, %{rows: [["Ada"]]}}, _} =
             Code.eval_quoted(Macro.expand(q2_block, env), [db: db], env)

    # 2. query/2 with raw string (not a keyword list with :do)
    q2_raw = quote(do: Xitdb.DSL.query(var!(db), "find ?n where .users[?e].name = ?n"))

    assert {{:ok, %{rows: [["Ada"]]}}, _} =
             Code.eval_quoted(Macro.expand(q2_raw, env), [db: db], env)

    # 3. query/2 with keyword list lacking :do falls through to Xitdb.query/3
    q2_kw_no_do = quote(do: Xitdb.DSL.query(var!(db), foo: :bar))

    assert Macro.to_string(Macro.expand(q2_kw_no_do, env)) =~
             "Xitdb.query(var!(db), [foo: :bar], [])"

    # 4. query/3 with keyword opts + do: block
    q3_kw =
      quote do
        Xitdb.DSL.query(var!(db), [from: users],
          do:
            (
              find({name})
              where([e.name == name])
            )
        )
      end

    assert {{:ok, %{rows: [["Ada"]]}}, _} =
             Code.eval_quoted(Macro.expand(q3_kw, env), [db: db], env)

    # 5. query/3 with dynamic (non-keyword AST) opts + do: block
    q3_dyn =
      quote do
        Xitdb.DSL.query(var!(db), var!(opts_var),
          do:
            (
              find({name})
              where([users[e].name == name])
            )
        )
      end

    assert {{:ok, %{rows: [["Ada"]]}}, _} =
             Code.eval_quoted(Macro.expand(q3_dyn, env), [db: db, opts_var: []], env)

    # 6. query!/2 and query!/3 (keyword opts and dynamic opts)
    q2_bang = quote(do: Xitdb.DSL.query!(var!(db), "find ?n where .users[?e].name = ?n"))

    assert {%{rows: [["Ada"]]}, _} =
             Code.eval_quoted(Macro.expand(q2_bang, env), [db: db], env)

    q3_bang_kw =
      quote do
        Xitdb.DSL.query!(var!(db), [from: users],
          do:
            (
              find({name})
              where([e.name == name])
            )
        )
      end

    assert {%{rows: [["Ada"]]}, _} =
             Code.eval_quoted(Macro.expand(q3_bang_kw, env), [db: db], env)

    q3_bang_dyn =
      quote do
        Xitdb.DSL.query!(var!(db), var!(opts_var),
          do:
            (
              find({name})
              where([users[e].name == name])
            )
        )
      end

    assert {%{rows: [["Ada"]]}, _} =
             Code.eval_quoted(Macro.expand(q3_bang_dyn, env), [db: db, opts_var: []], env)
  end
end
