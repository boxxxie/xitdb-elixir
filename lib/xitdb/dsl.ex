defmodule Xitdb.DSL do
  @moduledoc """
  Compile-time macro DSL for `Xitdb` path selectors, transaction mutation blocks,
  structural Pull patterns, and Ecto/Datomic-style Datalog queries.

  ## Usage

      use Xitdb.DSL

      # 1. Path selector macro with runtime interpolation & collection tags
      sel = path(users[user_id].todos[[idx]])
      counted_sel = path(org.counted(:departments)[dept_id].headcount)

      # 2. Atomic transaction block (0 intermediate NIF reads, auto-vivifies paths)
      {:ok, db} =
        tx db, doc: "promote alice" do
          put users[id].role, "admin"
          append users[id].audit_log, "promoted"
          insert users[id].todos[[0]], "urgent task"
          slice users[id].todos, 0..9
          fork users[id], backups[id]
          rm users[id].temp_token
          update users[id].login_count, &((&1 || 0) + 1)
        end

      # 3. Declarative Datalog query macro with ^var pinning
      {:ok, res} =
        query db do
          find {name, salary}
          where [
            sorted("username->id")[name] == id,
            starts_with(name, ^prefix),
            users[id].salary == salary,
            salary >= ^min_salary,
            not(users[id].flags.set_member("suspended"))
          ]
        end
  """

  alias Xitdb.{Cursor, NIF, Pull, TxCompiler}

  @typed_modifiers [
    :counted,
    :counted_map,
    :sorted,
    :sorted_map,
    :linked,
    :linked_list,
    :array,
    :array_list,
    :set_member,
    :hash_set,
    :counted_set_member,
    :counted_set,
    :sorted_set_member,
    :sorted_set
  ]

  @datalog_aggregations [:count, :sum, :min, :max]
  @datalog_predicates [:starts_with, :contains]

  defmacro __using__(_opts) do
    quote do
      import Xitdb.DSL
      import Xitdb.Sigils
    end
  end

  # ============================================================================
  # 1. Path & Pull Selector Macros (`path/1`, `pull_pattern/1`)
  # ============================================================================

  @doc """
  Compiles an Elixir path expression into a canonical `xitdb` selector binary.

  Static segments are folded into a single binary literal at compile time, while
  dynamic runtime expressions (`users[id]`, `todos[[idx]]`) are safely encoded at
  runtime.

  ## Supported Step Modifiers
  - `.field` or `[key]` — `:hash_map` (`.key`)
  - `counted(:key)` or `counted(var)` — `:counted_hash_map` (`#key`)
  - `sorted(:key)` or `sorted(var)` — `:sorted_map` (`$key`)
  - `[idx]` or `array(idx)` — `:array_list` (`[idx]`)
  - `[[idx]]` or `linked(idx)` — `:linked_array_list` (`[[idx]]`)
  - `set_member(m)` — `:hash_set` (`%m`)
  - `counted_set_member(m)` — `:counted_hash_set` (`#%m`)
  - `sorted_set_member(m)` — `:sorted_set` (`^m`)
  - `at_moment(moment, path)` — prefixes `@<moment>`
  """
  defmacro path(expr) do
    compile_path_ast(expr)
  end

  @doc """
  Compiles a structural Pull pattern into a canonical `xitdb` Pull string at compile time
  when given a literal list, or at runtime if dynamic.
  """
  defmacro pull_pattern(pattern) when is_list(pattern) do
    if Macro.quoted_literal?(pattern) do
      Pull.compile!(pattern)
    else
      quote do
        Xitdb.Pull.compile!(unquote(pattern))
      end
    end
  end

  defmacro pull_pattern(pattern) do
    quote do
      Xitdb.Pull.compile!(unquote(pattern))
    end
  end

  # ============================================================================
  # 2. Transaction Mutation Block DSL (`tx/2`, `tx/3`, `tx!/2`, `tx!/3`)
  # ============================================================================

  @doc """
  Executes a declarative transaction block and commits all staged operations in a
  single atomic NIF call.

  Inside `tx`, the following operations are available:
  - `put path_expr, value` (or 1-arity `put set_path.set_member(member)` for set members)
  - `update path_expr, fun` (or 3-arity `update path_expr, default, fun`)
  - `rm path_expr`
  - `append path_expr, value`
  - `insert list_path[[idx]], value` (or `insert list_path, idx, value`)
  - `slice list_path, first..last` (or `slice list_path, offset, size`)
  - `fork from_path, to_path`
  - `index_on source_map, field_key, index_map`
  - `init_col path_expr, kind`
  - `reset_col path_expr, kind`
  - `meta key, value`
  - `instant epoch_ms`
  - `savepoint()`
  - `abort reason`
  """
  defmacro tx(db, do: block) do
    compile_tx_block(db, [], block)
  end

  defmacro tx(db, opts, do: block) do
    compile_tx_block(db, opts, block)
  end

  @doc """
  Same as `tx/2` and `tx/3`, but returns the updated `%Xitdb{}` handle directly
  or raises `Xitdb.Error` on failure.
  """
  defmacro tx!(db, do: block) do
    quote do
      case unquote(compile_tx_block(db, [], block)) do
        {:ok, updated_db} -> updated_db
        {:error, err} -> raise err
      end
    end
  end

  defmacro tx!(db, opts, do: block) do
    quote do
      case unquote(compile_tx_block(db, opts, block)) do
        {:ok, updated_db} -> updated_db
        {:error, err} -> raise err
      end
    end
  end

  @doc """
  Wraps `tx/2` and `tx/3`, automatically injecting all `index_on` declarations
  configured on one or more `Xitdb.Ash.Resource` modules (or modules exporting
  `__xitdb_indexes__/0` and optional `__xitdb_collection__/0`).
  """
  defmacro tx_for(db, schemas, do: block) do
    compile_tx_for_block(db, schemas, [], block, __CALLER__)
  end

  defmacro tx_for(db, schemas, opts, do: block) do
    compile_tx_for_block(db, schemas, opts, block, __CALLER__)
  end

  @doc """
  Same as `tx_for/3` and `tx_for/4`, but returns the updated `%Xitdb{}` handle directly
  or raises `Xitdb.Error` on failure.
  """
  defmacro tx_for!(db, schemas, do: block) do
    quote do
      case unquote(compile_tx_for_block(db, schemas, [], block, __CALLER__)) do
        {:ok, updated_db} -> updated_db
        {:error, err} -> raise err
      end
    end
  end

  defmacro tx_for!(db, schemas, opts, do: block) do
    quote do
      case unquote(compile_tx_for_block(db, schemas, opts, block, __CALLER__)) do
        {:ok, updated_db} -> updated_db
        {:error, err} -> raise err
      end
    end
  end

  defp compile_tx_for_block(db_ast, schemas_ast, opts_ast, block_ast, caller) do
    schema_list =
      case schemas_ast do
        list when is_list(list) -> list
        single -> [single]
      end

    index_calls =
      for schema_node <- schema_list,
          {col, field, idx_name} <- extract_schema_indexes!(schema_node, caller),
          uniq: true do
        {:index_on, [], [col, field, idx_name]}
      end

    combined_block =
      {:__block__, [], index_calls ++ [block_ast]}

    compile_tx_block(db_ast, opts_ast, combined_block)
  end

  defp extract_schema_indexes!(schema_ast, caller) do
    mod = Macro.expand(schema_ast, caller)

    cond do
      not is_atom(mod) ->
        raise CompileError,
          description:
            "tx_for expects a compile-time module or list of modules, got: #{Macro.to_string(schema_ast)}"

      Code.ensure_loaded?(mod) and function_exported?(mod, :__xitdb_indexes__, 0) ->
        col =
          if function_exported?(mod, :__xitdb_collection__, 0) do
            mod.__xitdb_collection__()
          else
            nil
          end

        Enum.map(mod.__xitdb_indexes__(), fn
          {c, field, idx_name} -> {c, field, idx_name}
          {field, idx_name} when not is_nil(col) -> {col, field, idx_name}
        end)

      Code.ensure_loaded?(Xitdb.Ash.Info) ->
        col = apply(Xitdb.Ash.Info, :xitdb_collection!, [mod])
        idxs = apply(Xitdb.Ash.Info, :xitdb_indexes!, [mod])
        for {field, idx_name} <- idxs, do: {col, field, idx_name}

      true ->
        raise CompileError,
          description:
            "Module #{inspect(mod)} does not declare Xitdb indexes (use `Xitdb.Ash.Resource` or define `__xitdb_collection__/0` and `__xitdb_indexes__/0`)."
    end
  end

  defp compile_tx_block(db_ast, opts_ast, block_ast) do
    tx_ref_var = Macro.unique_var(:tx_ref, __MODULE__)
    rewritten_block = rewrite_tx_ast(block_ast, tx_ref_var)

    quote do
      unquote(tx_ref_var) =
        Xitdb.DSL.__init_tx_state__(unquote(db_ast), unquote(opts_ast))

      try do
        _ = unquote(rewritten_block)
        Xitdb.DSL.__commit_tx_state__(unquote(tx_ref_var))
      rescue
        e in Xitdb.Error ->
          {:error, e}

        e ->
          {:error, %Xitdb.Error{reason: :transaction_exception, details: %{exception: e}}}
      catch
        {:xitdb_tx_abort, unquote(tx_ref_var), reason} ->
          {:error, %Xitdb.Error{reason: reason}}
      after
        Xitdb.DSL.__cleanup_tx_state__(unquote(tx_ref_var))
      end
    end
  end

  defp rewrite_tx_ast({op, meta, _args} = node, _tx_ref_var)
       when op in [:tx, :tx!, :tx_for, :tx_for!] and is_list(meta) do
    # Do not rewrite inside nested `tx` blocks
    node
  end

  defp rewrite_tx_ast({{:., _, [_mod, op]}, _, _} = node, _tx_ref_var)
       when op in [:tx, :tx!, :tx_for, :tx_for!] do
    node
  end

  defp rewrite_tx_ast({:put, _meta, [path_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)

    quote do
      Xitdb.DSL.__tx_put_set_member__(unquote(tx_ref_var), unquote(selector_ast))
    end
  end

  defp rewrite_tx_ast({:put, _meta, [path_ast, val_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)
    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)

    quote do
      Xitdb.DSL.__tx_put__(unquote(tx_ref_var), unquote(selector_ast), unquote(rewritten_val))
    end
  end

  defp rewrite_tx_ast({:update, _meta, [path_ast, fun_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)
    rewritten_fun = rewrite_tx_ast(fun_ast, tx_ref_var)

    quote do
      Xitdb.DSL.__tx_update__(unquote(tx_ref_var), unquote(selector_ast), unquote(rewritten_fun))
    end
  end

  defp rewrite_tx_ast({:update, _meta, [path_ast, default_ast, fun_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)
    rewritten_default = rewrite_tx_ast(default_ast, tx_ref_var)
    rewritten_fun = rewrite_tx_ast(fun_ast, tx_ref_var)

    quote do
      Xitdb.DSL.__tx_update__(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(rewritten_default),
        unquote(rewritten_fun)
      )
    end
  end

  defp rewrite_tx_ast({:rm, _meta, [path_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)

    quote do
      Xitdb.DSL.__tx_rm__(unquote(tx_ref_var), unquote(selector_ast))
    end
  end

  defp rewrite_tx_ast({:append, _meta, [path_ast, val_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)
    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)

    quote do
      Xitdb.DSL.__tx_append__(unquote(tx_ref_var), unquote(selector_ast), unquote(rewritten_val))
    end
  end

  defp rewrite_tx_ast({:insert, _meta, [target_ast, val_ast]}, tx_ref_var) do
    {list_path_ast, idx_ast} = split_insert_target!(target_ast)
    selector_ast = compile_path_ast(list_path_ast)
    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)

    quote do
      Xitdb.DSL.__tx_insert__(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(idx_ast),
        unquote(rewritten_val)
      )
    end
  end

  defp rewrite_tx_ast({:insert, _meta, [list_path_ast, idx_ast, val_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(list_path_ast)
    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)

    quote do
      Xitdb.DSL.__tx_insert__(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(idx_ast),
        unquote(rewritten_val)
      )
    end
  end

  defp rewrite_tx_ast({:slice, _meta, [path_ast, range_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)

    quote do
      Xitdb.DSL.__tx_slice__(unquote(tx_ref_var), unquote(selector_ast), unquote(range_ast))
    end
  end

  defp rewrite_tx_ast({:slice, _meta, [path_ast, offset_ast, size_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)

    quote do
      Xitdb.DSL.__tx_slice__(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(offset_ast),
        unquote(size_ast)
      )
    end
  end

  defp rewrite_tx_ast({:fork, _meta, [from_path_ast, to_path_ast]}, tx_ref_var) do
    from_selector = compile_path_ast(from_path_ast)
    to_selector = compile_path_ast(to_path_ast)

    quote do
      Xitdb.DSL.__tx_fork__(unquote(tx_ref_var), unquote(from_selector), unquote(to_selector))
    end
  end

  defp rewrite_tx_ast({:index_on, _meta, [src_ast, field_ast, idx_ast]}, tx_ref_var) do
    src_str = normalize_index_name(src_ast)
    field_str = normalize_index_name(field_ast)
    idx_str = normalize_index_name(idx_ast)

    quote do
      Xitdb.DSL.__tx_index_on__(
        unquote(tx_ref_var),
        unquote(src_str),
        unquote(field_str),
        unquote(idx_str)
      )
    end
  end

  defp rewrite_tx_ast({:init_col, _meta, [path_ast, kind_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)

    quote do
      Xitdb.DSL.__tx_init_col__(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(kind_ast),
        false
      )
    end
  end

  defp rewrite_tx_ast({:reset_col, _meta, [path_ast, kind_ast]}, tx_ref_var) do
    selector_ast = compile_path_ast(path_ast)

    quote do
      Xitdb.DSL.__tx_init_col__(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(kind_ast),
        true
      )
    end
  end

  defp rewrite_tx_ast({:meta, _meta, [key_ast, val_ast]}, tx_ref_var) do
    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)

    quote do
      Xitdb.DSL.__tx_meta__(unquote(tx_ref_var), unquote(key_ast), unquote(rewritten_val))
    end
  end

  defp rewrite_tx_ast({:instant, _meta, [ms_ast]}, tx_ref_var) do
    rewritten_ms = rewrite_tx_ast(ms_ast, tx_ref_var)

    quote do
      Xitdb.DSL.__tx_instant__(unquote(tx_ref_var), unquote(rewritten_ms))
    end
  end

  defp rewrite_tx_ast({:savepoint, _meta, args}, tx_ref_var) when args in [[], nil] do
    quote do
      Xitdb.DSL.__tx_savepoint__(unquote(tx_ref_var))
    end
  end

  defp rewrite_tx_ast({:abort, _meta, [reason_ast]}, tx_ref_var) do
    quote do
      throw({:xitdb_tx_abort, unquote(tx_ref_var), unquote(reason_ast)})
    end
  end

  defp rewrite_tx_ast({form, meta, args}, tx_ref_var) when is_list(args) do
    {rewrite_tx_ast(form, tx_ref_var), meta, Enum.map(args, &rewrite_tx_ast(&1, tx_ref_var))}
  end

  defp rewrite_tx_ast({left, right}, tx_ref_var) do
    {rewrite_tx_ast(left, tx_ref_var), rewrite_tx_ast(right, tx_ref_var)}
  end

  defp rewrite_tx_ast(list, tx_ref_var) when is_list(list) do
    Enum.map(list, &rewrite_tx_ast(&1, tx_ref_var))
  end

  defp rewrite_tx_ast(other, _tx_ref_var), do: other

  defp split_insert_target!({{:., _, [Access, :get]}, _, [list_path_ast, [idx_ast]]}) do
    {list_path_ast, idx_ast}
  end

  defp split_insert_target!({{:., _, [Access, :get]}, _, [list_path_ast, idx_ast]}) do
    {list_path_ast, idx_ast}
  end

  defp split_insert_target!({{:., _, [list_path_ast, :linked]}, _, [idx_ast]}) do
    {list_path_ast, idx_ast}
  end

  defp split_insert_target!(other) do
    raise CompileError,
      description:
        "insert/2 expects a path ending in an index like `users[id].todos[[0]]`, or use insert/3 (`insert path, idx, val`). Got: #{Macro.to_string(other)}"
  end

  defp normalize_index_name({name, _, ctx}) when is_atom(name) and is_atom(ctx),
    do: Atom.to_string(name)

  defp normalize_index_name(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize_index_name(other), do: other

  # ============================================================================
  # 3. Datalog Query Macro (`datalog/1`, `query/2`, `query/3`, `query!/2`, `query!/3`)
  # ============================================================================

  @doc """
  Compiles an Ecto/Datomic-style Datalog query block into a canonical `xitdb` Datalog string.

  ## Examples

      min_age = 21

      q =
        datalog do
          find {e, name, age}
          from users
          where [
            e.username == name,
            e.age == age,
            age >= ^min_age,
            not(e.banned == true)
          ]
        end
  """
  defmacro datalog(do: block) do
    compile_datalog_block(block, [])
  end

  @doc """
  Compiles and executes a Datalog query block against `target` (`%Xitdb{}` or `%Xitdb.Cursor{}`).
  """
  defmacro query(target, do: block) do
    query_str_ast = compile_datalog_block(block, [])

    quote do
      Xitdb.query(unquote(target), unquote(query_str_ast), [])
    end
  end

  defmacro query(target, query_str) do
    quote do
      Xitdb.query(unquote(target), unquote(query_str), [])
    end
  end

  defmacro query(target, opts, do: block) do
    {from_opt, runtime_opts} = Keyword.pop(opts, :from)
    query_str_ast = compile_datalog_block(block, from: from_opt)

    quote do
      Xitdb.query(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
    end
  end

  defmacro query(target, query_str, opts) do
    quote do
      Xitdb.query(unquote(target), unquote(query_str), unquote(opts))
    end
  end

  @doc """
  Same as `query/2` and `query/3`, but raises `Xitdb.Error` on failure.
  """
  defmacro query!(target, do: block) do
    query_str_ast = compile_datalog_block(block, [])

    quote do
      Xitdb.query!(unquote(target), unquote(query_str_ast), [])
    end
  end

  defmacro query!(target, query_str) do
    quote do
      Xitdb.query!(unquote(target), unquote(query_str), [])
    end
  end

  defmacro query!(target, opts, do: block) do
    {from_opt, runtime_opts} = Keyword.pop(opts, :from)
    query_str_ast = compile_datalog_block(block, from: from_opt)

    quote do
      Xitdb.query!(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
    end
  end

  defmacro query!(target, query_str, opts) do
    quote do
      Xitdb.query!(unquote(target), unquote(query_str), unquote(opts))
    end
  end

  # ============================================================================
  # Path AST Compiler Implementation
  # ============================================================================

  defp compile_path_ast(ast) do
    ast
    |> extract_path_segments()
    |> fold_static_segments()
    |> segments_to_quoted()
  end

  defp extract_path_segments(str) when is_binary(str) do
    [{:static, str}]
  end

  defp extract_path_segments(atom)
       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    [{:static, TxCompiler.format_step(:hash_map, atom)}]
  end

  defp extract_path_segments({:sigil_x, _, _} = sigil_ast) do
    [{:dynamic, sigil_ast}]
  end

  defp extract_path_segments(list) when is_list(list) do
    Enum.flat_map(list, &extract_list_step_segment/1)
  end

  defp extract_path_segments({:root, _, ctx}) when is_atom(ctx), do: []
  defp extract_path_segments({:_, _, ctx}) when is_atom(ctx), do: []

  defp extract_path_segments({:^, _, [pinned_expr]}) do
    [{:dynamic, quote(do: Xitdb.TxCompiler.format_root_or_step(unquote(pinned_expr)))}]
  end

  defp extract_path_segments({:at_moment, _, [moment_ast, inner_ast]}) do
    [moment_segment(moment_ast) | extract_path_segments(inner_ast)]
  end

  defp extract_path_segments({mod_fn, _, [arg]}) when mod_fn in @typed_modifiers do
    [typed_modifier_segment(mod_fn, arg)]
  end

  defp extract_path_segments({{:., _, [left, mod_fn]}, _, [arg]})
       when mod_fn in @typed_modifiers do
    extract_path_segments(left) ++ [typed_modifier_segment(mod_fn, arg)]
  end

  defp extract_path_segments({{:., _, [left, field]}, _, []}) when is_atom(field) do
    extract_path_segments(left) ++ [{:static, TxCompiler.format_step(:hash_map, field)}]
  end

  defp extract_path_segments(
         {{:., _, [Access, :get]}, _, [{{:., _, [parent, mod_fn]}, _, [container_key]}, right]}
       )
       when mod_fn in [:counted, :counted_map, :sorted, :sorted_map] do
    extract_path_segments(parent) ++
      [typed_modifier_segment(:hash_map, container_key), typed_modifier_segment(mod_fn, right)]
  end

  defp extract_path_segments({{:., _, [Access, :get]}, _, [{mod_fn, _, [container_key]}, right]})
       when mod_fn in [:counted, :counted_map, :sorted, :sorted_map] do
    [typed_modifier_segment(:hash_map, container_key), typed_modifier_segment(mod_fn, right)]
  end

  defp extract_path_segments({{:., _, [Access, :get]}, _, [left, right]}) do
    extract_path_segments(left) ++ [extract_bracket_segment(right)]
  end

  defp extract_path_segments({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    [{:static, TxCompiler.format_step(:hash_map, name)}]
  end

  defp extract_path_segments(other) do
    [{:dynamic, quote(do: Xitdb.TxCompiler.format_root_or_step(unquote(other)))}]
  end

  defp extract_list_step_segment([idx_ast]) do
    [typed_modifier_segment(:linked, idx_ast)]
  end

  defp extract_list_step_segment({kind, val_ast}) when is_atom(kind) do
    [typed_modifier_segment(kind, val_ast)]
  end

  defp extract_list_step_segment(step_ast) do
    [extract_bracket_segment(step_ast)]
  end

  defp extract_bracket_segment([idx_ast]) do
    typed_modifier_segment(:linked, idx_ast)
  end

  defp extract_bracket_segment({mod_fn, _, [arg]}) when mod_fn in @typed_modifiers do
    typed_modifier_segment(mod_fn, arg)
  end

  defp extract_bracket_segment({:^, _, [inner]}) do
    extract_bracket_segment(inner)
  end

  defp extract_bracket_segment(idx) when is_integer(idx) do
    {:static, TxCompiler.format_step(:array_list, idx)}
  end

  defp extract_bracket_segment(key)
       when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)) do
    {:static, TxCompiler.format_step(:hash_map, key)}
  end

  defp extract_bracket_segment(dynamic_ast) do
    {:dynamic, quote(do: Xitdb.TxCompiler.format_bracket_step(unquote(dynamic_ast)))}
  end

  defp typed_modifier_segment(mod_fn, {:^, _, [inner]}) do
    typed_modifier_segment(mod_fn, inner)
  end

  defp typed_modifier_segment(mod_fn, idx)
       when mod_fn in [:linked, :linked_list, :linked_array_list] and is_integer(idx) do
    {:static, TxCompiler.format_step(:linked_array_list, idx)}
  end

  defp typed_modifier_segment(mod_fn, idx)
       when mod_fn in [:array, :array_list] and is_integer(idx) do
    {:static, TxCompiler.format_step(:array_list, idx)}
  end

  defp typed_modifier_segment(mod_fn, literal)
       when is_binary(literal) or
              (is_atom(literal) and not is_nil(literal) and not is_boolean(literal)) do
    {:static, TxCompiler.format_typed_step(mod_fn, literal)}
  end

  defp typed_modifier_segment(mod_fn, dynamic_ast) do
    {:dynamic,
     quote(do: Xitdb.TxCompiler.format_typed_step(unquote(mod_fn), unquote(dynamic_ast)))}
  end

  defp moment_segment(m) when is_integer(m), do: {:static, "@#{m}"}

  defp moment_segment(m_ast) do
    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(m_ast)))}
  end

  defp fold_static_segments(segments) do
    segments
    |> Enum.reduce([], fn
      {:static, s2}, [{:static, s1} | rest] -> [{:static, s1 <> s2} | rest]
      seg, acc -> [seg | acc]
    end)
    |> :lists.reverse()
  end

  defp segments_to_quoted([]), do: ""
  defp segments_to_quoted([{:static, s}]), do: s
  defp segments_to_quoted([{:dynamic, expr}]), do: expr

  defp segments_to_quoted(segments) do
    exprs =
      Enum.map(segments, fn
        {:static, s} -> s
        {:dynamic, expr} -> expr
      end)

    Enum.reduce(tl(exprs), hd(exprs), fn seg, acc ->
      quote do
        unquote(acc) <> unquote(seg)
      end
    end)
  end

  # ============================================================================
  # Datalog AST Compiler Implementation
  # ============================================================================

  defp compile_datalog_block(block_ast, opts) do
    exprs =
      case block_ast do
        {:__block__, _, lines} -> lines
        single -> [single]
      end

    {find_ast, from_ast, where_ast} = extract_datalog_sections!(exprs, opts[:from])
    {find_parts, find_vars} = compile_datalog_find!(find_ast)

    initial_bindings =
      case from_ast do
        nil ->
          %{}

        {alias_var, col_ast} when is_atom(alias_var) ->
          %{alias_var => build_collection_binding(col_ast, alias_var)}

        {col_name, _, ctx} = col_ast when is_atom(col_name) and is_atom(ctx) ->
          primary_var = List.first(find_vars) || :_e

          if primary_var == col_name do
            %{col_name => build_collection_binding(col_ast, col_name)}
          else
            %{
              primary_var => build_collection_binding(col_ast, primary_var),
              col_name => build_collection_binding(col_ast, :_e)
            }
          end

        col_ast ->
          primary_var = List.first(find_vars) || :e
          %{primary_var => build_collection_binding(col_ast, primary_var)}
      end

    where_clauses_ast = unwrap_where_clauses!(where_ast)

    {where_segments, _final_bindings} =
      Enum.reduce(where_clauses_ast, {[], initial_bindings}, fn
        {:<-, _, [{alias_var, _, ctx}, source_ast]}, {seg_acc, binds}
        when is_atom(alias_var) and is_atom(ctx) ->
          new_binds = Map.put(binds, alias_var, build_collection_binding(source_ast, alias_var))
          {seg_acc, new_binds}

        clause_ast, {seg_acc, binds} ->
          clause_segs = compile_where_clause!(clause_ast, find_vars, binds)

          line_segs =
            case seg_acc do
              [] -> clause_segs
              _ -> [{:static, "\n  "} | clause_segs]
            end

          {seg_acc ++ line_segs, binds}
      end)

    header = "find " <> Enum.join(find_parts, ", ") <> "\nwhere\n  "

    ([{:static, header}] ++ where_segments)
    |> fold_static_segments()
    |> segments_to_quoted()
  end

  defp extract_datalog_sections!(exprs, default_from) do
    Enum.reduce(exprs, {nil, default_from, nil}, fn
      {:find, _, args}, {_find, from, where} ->
        {args, from, where}

      {:from, _, [{op, _, [{alias_var, _, ctx}, col_ast]}]}, {find, _from, where}
      when op in [:in, :<-] and is_atom(alias_var) and is_atom(ctx) ->
        {find, {alias_var, col_ast}, where}

      {:from, _, [col_ast]}, {find, _from, where} ->
        {find, col_ast, where}

      {:where, _, [where_arg]}, {find, from, _where} ->
        {find, from, where_arg}

      other, _acc ->
        raise CompileError,
          description:
            "Unsupported clause in Xitdb.DSL.datalog/query block (expected `find`, `from`, or `where`): #{Macro.to_string(other)}"
    end)
    |> case do
      {nil, _, _} ->
        raise CompileError, description: "Xitdb.DSL.query block is missing a `find` clause"

      {_, _, nil} ->
        raise CompileError, description: "Xitdb.DSL.query block is missing a `where` clause"

      sections ->
        sections
    end
  end

  defp compile_datalog_find!(find_args) do
    items =
      case find_args do
        [{:{}, _, tuple_elems}] -> tuple_elems
        [{a, b}] -> [a, b]
        [list] when is_list(list) -> list
        multiple when is_list(multiple) -> multiple
      end

    Enum.map_reduce(items, [], fn
      {agg, _, [{var_name, _, ctx}]}, vars_acc
      when agg in @datalog_aggregations and is_atom(var_name) and is_atom(ctx) ->
        lvar = format_logic_var(var_name)
        {"#{agg}(#{lvar})", Enum.uniq(vars_acc ++ [normalize_var_atom(var_name)])}

      {var_name, _, ctx}, vars_acc when is_atom(var_name) and is_atom(ctx) ->
        lvar = format_logic_var(var_name)
        {lvar, Enum.uniq(vars_acc ++ [normalize_var_atom(var_name)])}

      atom, vars_acc when is_atom(atom) ->
        lvar = format_logic_var(atom)
        {lvar, Enum.uniq(vars_acc ++ [normalize_var_atom(atom)])}

      other, _vars_acc ->
        raise CompileError,
          description: "Invalid `find` element in Datalog query: #{Macro.to_string(other)}"
    end)
  end

  defp unwrap_where_clauses!(do: {:__block__, _, lines}), do: lines
  defp unwrap_where_clauses!(do: single), do: [single]
  defp unwrap_where_clauses!(clauses) when is_list(clauses), do: clauses
  defp unwrap_where_clauses!({:__block__, _, lines}), do: lines
  defp unwrap_where_clauses!(single), do: [single]

  defp build_collection_binding({{:., _, [Access, :get]}, _, _} = indexed_ast, _alias_var) do
    compile_datalog_path_segments(indexed_ast, [], %{})
  end

  defp build_collection_binding({mod_fn, _, [arg]}, alias_var)
       when mod_fn in [:counted, :counted_map, :sorted, :sorted_map] do
    [
      typed_modifier_segment(mod_fn, arg),
      {:static, "[#{format_logic_var(alias_var)}]"}
    ]
  end

  defp build_collection_binding({col_name, _, ctx}, alias_var)
       when is_atom(col_name) and is_atom(ctx) do
    [{:static, ".#{col_name}[#{format_logic_var(alias_var)}]"}]
  end

  defp build_collection_binding(col_name, alias_var)
       when is_atom(col_name) or is_binary(col_name) do
    [{:static, TxCompiler.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
  end

  defp compile_where_clause!({:not, _, [inner_clause]}, find_vars, binds) do
    [{:static, "not "} | compile_where_clause!(inner_clause, find_vars, binds)]
  end

  defp compile_where_clause!(
         {:reach, _, [{from_var, _, c1}, {to_var, _, c2}, edge_clause]},
         find_vars,
         binds
       )
       when is_atom(from_var) and is_atom(c1) and is_atom(to_var) and is_atom(c2) do
    reach_vars =
      Enum.uniq(find_vars ++ [normalize_var_atom(from_var), normalize_var_atom(to_var)])

    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds)

    [{:static, "reach(#{format_logic_var(from_var)}, #{format_logic_var(to_var)}, "}] ++
      edge_segs ++
      [{:static, ")"}]
  end

  defp compile_where_clause!(
         {:reach, _, [{from_var, _, c1}, {to_var, _, c2}, {depth_var, _, c3}, edge_clause]},
         find_vars,
         binds
       )
       when is_atom(from_var) and is_atom(c1) and is_atom(to_var) and is_atom(c2) and
              is_atom(depth_var) and is_atom(c3) do
    reach_vars =
      Enum.uniq(
        find_vars ++
          [
            normalize_var_atom(from_var),
            normalize_var_atom(to_var),
            normalize_var_atom(depth_var)
          ]
      )

    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds)

    [
      {:static,
       "reach(#{format_logic_var(from_var)}, #{format_logic_var(to_var)}, #{format_logic_var(depth_var)}, "}
    ] ++
      edge_segs ++
      [{:static, ")"}]
  end

  defp compile_where_clause!({pred, _, [arg1, arg2]}, _find_vars, _binds)
       when pred in @datalog_predicates do
    [{:static, "#{pred}("}] ++
      compile_datalog_operand(arg1) ++
      [{:static, ", "}] ++
      compile_datalog_operand(arg2) ++
      [{:static, ")"}]
  end

  defp compile_where_clause!({op, _, [lhs, rhs]}, find_vars, binds)
       when op in [:==, :=] do
    if datalog_path_expr?(lhs) do
      compile_datalog_path_segments(lhs, find_vars, binds) ++
        [{:static, " = "}] ++
        compile_datalog_operand(rhs)
    else
      compile_datalog_operand(lhs) ++
        [{:static, " == "}] ++
        compile_datalog_operand(rhs)
    end
  end

  defp compile_where_clause!({op, _, [lhs, rhs]}, find_vars, binds)
       when op in [:!=, :>, :>=, :<, :<=] do
    lhs_segs =
      if datalog_path_expr?(lhs) do
        compile_datalog_path_segments(lhs, find_vars, binds)
      else
        compile_datalog_operand(lhs)
      end

    lhs_segs ++ [{:static, " #{op} "}] ++ compile_datalog_operand(rhs)
  end

  defp compile_where_clause!(
         {{:., _, [left, set_fn]}, _, [member_arg]},
         find_vars,
         binds
       )
       when set_fn in [
              :set_member,
              :hash_set,
              :counted_set_member,
              :counted_set,
              :sorted_set_member,
              :sorted_set
            ] do
    compile_datalog_path_segments(left, find_vars, binds) ++
      compile_datalog_set_step(set_fn, member_arg)
  end

  defp compile_where_clause!({set_fn, _, [left, member_arg]}, find_vars, binds)
       when set_fn in [
              :set_member,
              :hash_set,
              :counted_set_member,
              :counted_set,
              :sorted_set_member,
              :sorted_set
            ] do
    compile_datalog_path_segments(left, find_vars, binds) ++
      compile_datalog_set_step(set_fn, member_arg)
  end

  defp compile_where_clause!(other, find_vars, binds) do
    if datalog_path_expr?(other) do
      compile_datalog_path_segments(other, find_vars, binds)
    else
      raise CompileError,
        description: "Unsupported Datalog `where` clause: #{Macro.to_string(other)}"
    end
  end

  defp datalog_path_expr?({:at_moment, _, [_, _]}), do: true
  defp datalog_path_expr?({{:., _, _}, _, _}), do: true
  defp datalog_path_expr?({mod_fn, _, _}) when mod_fn in @typed_modifiers, do: true
  defp datalog_path_expr?(_), do: false

  defp compile_datalog_path_segments({:root, _, ctx}, _find_vars, _binds) when is_atom(ctx),
    do: []

  defp compile_datalog_path_segments({:_, _, ctx}, _find_vars, _binds) when is_atom(ctx),
    do: []

  defp compile_datalog_path_segments(
         {:at_moment, _, [moment_ast, inner_ast]},
         find_vars,
         binds
       ) do
    [
      compile_datalog_moment_segment(moment_ast)
      | compile_datalog_path_segments(inner_ast, find_vars, binds)
    ]
  end

  defp compile_datalog_path_segments({mod_fn, _, [arg]}, _find_vars, _binds)
       when mod_fn in @typed_modifiers do
    [typed_modifier_segment(mod_fn, arg)]
  end

  defp compile_datalog_path_segments({{:., _, [left, set_fn]}, _, [member_arg]}, find_vars, binds)
       when set_fn in [
              :set_member,
              :hash_set,
              :counted_set_member,
              :counted_set,
              :sorted_set_member,
              :sorted_set
            ] do
    compile_datalog_path_segments(left, find_vars, binds) ++
      compile_datalog_set_step(set_fn, member_arg)
  end

  defp compile_datalog_path_segments({{:., _, [left, mod_fn]}, _, [arg]}, find_vars, binds)
       when mod_fn in @typed_modifiers do
    compile_datalog_path_segments(left, find_vars, binds) ++
      [typed_modifier_segment(mod_fn, arg)]
  end

  defp compile_datalog_path_segments({{:., _, [left, field]}, _, []}, find_vars, binds)
       when is_atom(field) do
    compile_datalog_path_segments(left, find_vars, binds) ++
      [{:static, TxCompiler.format_step(:hash_map, field)}]
  end

  defp compile_datalog_path_segments(
         {{:., _, [Access, :get]}, _, [{root_name, _, ctx}, right]},
         find_vars,
         binds
       )
       when is_atom(root_name) and is_atom(ctx) do
    base_segs =
      cond do
        root_name in [:root, :_] ->
          []

        Map.has_key?(binds, root_name) ->
          Map.fetch!(binds, root_name)

        true ->
          [{:static, TxCompiler.format_step(:hash_map, root_name)}]
      end

    base_segs ++ [compile_datalog_bracket_step(right, find_vars)]
  end

  defp compile_datalog_path_segments(
         {{:., _, [Access, :get]}, _, [left, right]},
         find_vars,
         binds
       ) do
    compile_datalog_path_segments(left, find_vars, binds) ++
      [compile_datalog_bracket_step(right, find_vars)]
  end

  defp compile_datalog_path_segments({name, _, ctx}, find_vars, binds)
       when is_atom(name) and is_atom(ctx) do
    norm = normalize_var_atom(name)

    cond do
      Map.has_key?(binds, norm) ->
        Map.fetch!(binds, norm)

      norm in find_vars ->
        [{:static, "[#{format_logic_var(norm)}]"}]

      true ->
        [{:static, TxCompiler.format_step(:hash_map, name)}]
    end
  end

  defp compile_datalog_moment_segment(m) when is_integer(m), do: {:static, "@#{m}"}
  defp compile_datalog_moment_segment({:-, _, [m]}) when is_integer(m), do: {:static, "@-#{m}"}

  defp compile_datalog_moment_segment({:^, _, [pinned_expr]}) do
    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(pinned_expr)))}
  end

  defp compile_datalog_moment_segment({var_name, _, ctx})
       when is_atom(var_name) and is_atom(ctx) do
    {:static, "@" <> format_logic_var(var_name)}
  end

  defp compile_datalog_bracket_step({:^, _, [pinned_expr]}, _find_vars) do
    {:dynamic, quote(do: Xitdb.DSL.__format_datalog_bracket_pin__(unquote(pinned_expr)))}
  end

  defp compile_datalog_bracket_step([{var_name, _, ctx}], _find_vars)
       when is_atom(var_name) and is_atom(ctx) do
    {:static, "[[#{format_logic_var(var_name)}]]"}
  end

  defp compile_datalog_bracket_step([idx], _find_vars) when is_integer(idx) do
    {:static, "[[#{idx}]]"}
  end

  defp compile_datalog_bracket_step({var_name, _, ctx}, _find_vars)
       when is_atom(var_name) and is_atom(ctx) do
    {:static, "[#{format_logic_var(var_name)}]"}
  end

  defp compile_datalog_bracket_step(idx, _find_vars) when is_integer(idx) do
    {:static, "[#{idx}]"}
  end

  defp compile_datalog_bracket_step(str, _find_vars) when is_binary(str) do
    {:static, ~s(["#{str}"])}
  end

  defp compile_datalog_set_step(set_fn, member_arg) do
    prefix =
      case set_fn do
        f when f in [:set_member, :hash_set] -> "%"
        f when f in [:counted_set_member, :counted_set] -> "#%"
        f when f in [:sorted_set_member, :sorted_set] -> "^"
      end

    [{:static, prefix} | compile_datalog_operand(member_arg)]
  end

  defp compile_datalog_operand({:^, _, [pinned_expr]}) do
    [{:dynamic, quote(do: Xitdb.DSL.__format_datalog_literal__(unquote(pinned_expr)))}]
  end

  defp compile_datalog_operand({var_name, _, ctx}) when is_atom(var_name) and is_atom(ctx) do
    [{:static, format_logic_var(var_name)}]
  end

  defp compile_datalog_operand(literal)
       when is_binary(literal) or is_number(literal) or is_boolean(literal) or is_atom(literal) do
    [{:static, __format_datalog_literal__(literal)}]
  end

  defp format_logic_var(atom) when is_atom(atom) do
    str = Atom.to_string(atom)
    if String.starts_with?(str, "?"), do: str, else: "?" <> str
  end

  defp normalize_var_atom(atom) when is_atom(atom) do
    str = Atom.to_string(atom)

    if String.starts_with?(str, "?") do
      String.to_atom(String.trim_leading(str, "?"))
    else
      atom
    end
  end

  # ============================================================================
  # Internal Runtime Helpers for `tx` and `datalog`
  # ============================================================================

  @doc false
  def __init_tx_state__(db, opts) do
    tx_ref = make_ref()

    state = %{
      db: db,
      opts: opts,
      index_ops: [],
      ops: [],
      staged: %{}
    }

    Process.put(tx_ref, state)
    tx_ref
  end

  @doc false
  def __cleanup_tx_state__(tx_ref) do
    Process.delete(tx_ref)
    :ok
  end

  @doc false
  def __commit_tx_state__(tx_ref) do
    %{db: db, opts: opts, index_ops: index_ops, ops: ops} = Process.get(tx_ref)
    all_ops = :lists.reverse(index_ops) ++ :lists.reverse(ops)
    Xitdb.transact_ops(db, all_ops, opts)
  end

  @doc false
  def __tx_put__(tx_ref, selector, value) when is_binary(selector) do
    state = Process.get(tx_ref)
    compiled_ops = TxCompiler.compile_node(selector, value, true)

    staged =
      Enum.reduce(compiled_ops, Map.put(state.staged, selector, {:val, value}), fn
        {:put, path, v}, acc -> Map.put(acc, path, {:val, v})
        {:rm, path}, acc -> Map.put(acc, path, :deleted)
        _, acc -> acc
      end)

    new_state = %{
      state
      | ops: :lists.reverse(compiled_ops) ++ state.ops,
        staged: staged
    }

    Process.put(tx_ref, new_state)
    value
  end

  @doc false
  def __tx_put_set_member__(tx_ref, selector) when is_binary(selector) do
    state = Process.get(tx_ref)
    op = {:put, selector, ""}

    new_state = %{
      state
      | ops: [op | state.ops],
        staged: Map.put(state.staged, selector, {:val, true})
    }

    Process.put(tx_ref, new_state)
    true
  end

  @doc false
  def __tx_update__(tx_ref, selector, fun) when is_binary(selector) and is_function(fun, 1) do
    state = Process.get(tx_ref)
    current = read_tx_current_value(state, selector)
    new_val = fun.(current)
    __tx_put__(tx_ref, selector, new_val)
  end

  @doc false
  def __tx_update__(tx_ref, selector, default, fun)
      when is_binary(selector) and is_function(fun, 1) do
    state = Process.get(tx_ref)
    current = read_tx_current_value(state, selector)
    resolved = if is_nil(current), do: default, else: current
    new_val = fun.(resolved)
    __tx_put__(tx_ref, selector, new_val)
  end

  @doc false
  def __tx_rm__(tx_ref, selector) when is_binary(selector) do
    state = Process.get(tx_ref)

    staged =
      state.staged
      |> Map.new(fn {k, v} ->
        if k == selector or String.starts_with?(k, selector <> ".") or
             String.starts_with?(k, selector <> "[") or
             String.starts_with?(k, selector <> "#") or
             String.starts_with?(k, selector <> "$") do
          {k, :deleted}
        else
          {k, v}
        end
      end)
      |> Map.put(selector, :deleted)

    new_state = %{
      state
      | ops: [{:rm, selector} | state.ops],
        staged: staged
    }

    Process.put(tx_ref, new_state)
    :ok
  end

  @doc false
  def __tx_append__(tx_ref, selector, value) when is_binary(selector) do
    state = Process.get(tx_ref)
    Process.put(tx_ref, %{state | ops: [{:append, selector, value} | state.ops]})
    value
  end

  @doc false
  def __tx_insert__(tx_ref, selector, index, value)
      when is_binary(selector) and is_integer(index) do
    state = Process.get(tx_ref)
    Process.put(tx_ref, %{state | ops: [{:insert, selector, index, value} | state.ops]})
    value
  end

  @doc false
  def __tx_slice__(tx_ref, selector, first.._last//1 = range) when is_binary(selector) do
    size = Range.size(range)
    __tx_slice__(tx_ref, selector, first, size)
  end

  @doc false
  def __tx_slice__(tx_ref, selector, offset, size)
      when is_binary(selector) and is_integer(offset) and is_integer(size) do
    state = Process.get(tx_ref)
    Process.put(tx_ref, %{state | ops: [{:slice, selector, offset, size} | state.ops]})
    :ok
  end

  @doc false
  def __tx_fork__(tx_ref, from_selector, to_selector)
      when is_binary(from_selector) and is_binary(to_selector) do
    state = Process.get(tx_ref)

    new_state = %{
      state
      | ops: [{:fork, from_selector, to_selector} | state.ops]
    }

    Process.put(tx_ref, new_state)
    :ok
  end

  @doc false
  def __tx_index_on__(tx_ref, src_map, field_key, idx_map) do
    state = Process.get(tx_ref)
    op = {:index_on, to_string(src_map), to_string(field_key), to_string(idx_map)}
    Process.put(tx_ref, %{state | index_ops: [op | state.index_ops]})
    :ok
  end

  @doc false
  def __tx_init_col__(tx_ref, selector, kind, reset?) when is_binary(selector) do
    state = Process.get(tx_ref)
    op_tag = if reset?, do: :reset_col, else: :init_col
    Process.put(tx_ref, %{state | ops: [{op_tag, selector, to_string(kind)} | state.ops]})
    :ok
  end

  @doc false
  def __tx_meta__(tx_ref, key, val) do
    state = Process.get(tx_ref)
    op = {:meta, to_string(key), val}
    Process.put(tx_ref, %{state | ops: [op | state.ops]})
    val
  end

  @doc false
  def __tx_instant__(tx_ref, epoch_ms) when is_integer(epoch_ms) do
    state = Process.get(tx_ref)
    op = {:instant, epoch_ms}
    Process.put(tx_ref, %{state | ops: [op | state.ops]})
    epoch_ms
  end

  @doc false
  def __tx_savepoint__(tx_ref) do
    state = Process.get(tx_ref)
    op = {:savepoint, ""}
    Process.put(tx_ref, %{state | ops: [op | state.ops]})
    :ok
  end

  defp read_tx_current_value(%{staged: staged, db: db, opts: opts}, selector) do
    case Map.get(staged, selector) do
      {:val, val} ->
        val

      :deleted ->
        nil

      nil ->
        if Xitdb.moment_count(db) == 0 do
          nil
        else
          base_moment = Keyword.get(opts, :base_moment, -1)

          case NIF.nif_select(db.db_ref, base_moment, selector) do
            {:ok, raw} ->
              case Cursor.unwrap_nif_value(db.db_ref, raw, base_moment, []) do
                %Cursor{} = cur -> Xitdb.materialize(cur)
                scalar -> scalar
              end

            {:error, _} ->
              nil
          end
        end
    end
  end

  @doc false
  def __format_datalog_literal__(val) when is_binary(val), do: inspect(val)
  def __format_datalog_literal__(val) when is_integer(val) or is_float(val), do: to_string(val)
  def __format_datalog_literal__(val) when is_boolean(val), do: to_string(val)
  def __format_datalog_literal__(val) when is_atom(val), do: inspect(Atom.to_string(val))

  @doc false
  def __format_datalog_bracket_pin__(idx) when is_integer(idx), do: "[#{idx}]"
  def __format_datalog_bracket_pin__(key), do: ~s(["#{key}"])
end
