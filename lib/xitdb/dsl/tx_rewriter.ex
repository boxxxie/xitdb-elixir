defmodule Xitdb.DSL.TxRewriter do
  @moduledoc false

  alias Xitdb.DSL.PathCompiler

  @nested_tx_macros [:tx, :tx!, :tx_for, :tx_for!]

  @spec compile_tx(Macro.t(), Macro.t(), Macro.t(), Macro.Env.t() | nil) :: Macro.t()
  def compile_tx(db_ast, opts_ast, block_ast, caller \\ nil) do
    tx_ref_var = Macro.unique_var(:tx_ref, __MODULE__)
    track_staged? = block_has_tx_update?(block_ast)
    rewritten_block = rewrite_ast(block_ast, tx_ref_var, caller)

    quote do
      case Xitdb.DSL.TxRuntime.init_state(
             unquote(db_ast),
             unquote(opts_ast),
             unquote(track_staged?)
           ) do
        {:ok, unquote(tx_ref_var)} ->
          try do
            _ = unquote(rewritten_block)
            Xitdb.DSL.TxRuntime.commit_state(unquote(tx_ref_var))
          rescue
            e in Xitdb.Error ->
              {:error, e}

            e ->
              {:error, %Xitdb.Error{reason: :transaction_exception, details: %{exception: e}}}
          catch
            {:xitdb_tx_abort, unquote(tx_ref_var), reason} ->
              {:error, %Xitdb.Error{reason: reason}}
          after
            Xitdb.DSL.TxRuntime.cleanup_state(unquote(tx_ref_var))
          end

        {:error, _} = err ->
          err
      end
    end
  end

  @spec compile_tx_bang(Macro.t(), Macro.t(), Macro.t(), Macro.Env.t() | nil) :: Macro.t()
  def compile_tx_bang(db_ast, opts_ast, block_ast, caller \\ nil) do
    wrap_bang(compile_tx(db_ast, opts_ast, block_ast, caller))
  end

  @spec compile_tx_for(Macro.t(), Macro.t(), Macro.t(), Macro.t(), Macro.Env.t()) :: Macro.t()
  def compile_tx_for(db_ast, schemas_ast, opts_ast, block_ast, caller) do
    schema_list =
      case Macro.expand(schemas_ast, caller) do
        list when is_list(list) -> list
        single -> [single]
      end

    index_calls =
      for schema_node <- schema_list,
          {col, field, idx_name} <- extract_schema_indexes!(schema_node, caller),
          uniq: true do
        {:index_on, [], [col, field, idx_name]}
      end

    combined_block = {:__block__, [], index_calls ++ [block_ast]}
    compile_tx(db_ast, opts_ast, combined_block, caller)
  end

  @spec compile_tx_for_bang(Macro.t(), Macro.t(), Macro.t(), Macro.t(), Macro.Env.t()) ::
          Macro.t()
  def compile_tx_for_bang(db_ast, schemas_ast, opts_ast, block_ast, caller) do
    wrap_bang(compile_tx_for(db_ast, schemas_ast, opts_ast, block_ast, caller))
  end

  defp wrap_bang(tx_quoted) do
    quote do
      case unquote(tx_quoted) do
        {:ok, updated_db} -> updated_db
        {:error, err} -> raise err
      end
    end
  end

  defp extract_schema_indexes!(schema_ast, caller) do
    mod = Macro.expand(schema_ast, caller)

    if not is_atom(mod) or is_nil(mod) do
      compile_error!(
        caller,
        "tx_for expects a compile-time module or list of modules, got: #{Macro.to_string(schema_ast)}"
      )
    end

    case Code.ensure_compiled(mod) do
      {:module, ^mod} ->
        extract_compiled_module_indexes!(mod, caller)

      {:error, reason} ->
        compile_error!(
          caller,
          "tx_for could not load schema module #{inspect(mod)} (#{inspect(reason)})"
        )
    end
  end

  defp extract_compiled_module_indexes!(mod, caller) do
    if not function_exported?(mod, :__xitdb_indexes__, 0) do
      compile_error!(
        caller,
        "Module #{inspect(mod)} does not declare Xitdb indexes (define `__xitdb_indexes__/0` and optional `__xitdb_collection__/0`)."
      )
    end

    col =
      if function_exported?(mod, :__xitdb_collection__, 0) do
        mod.__xitdb_collection__()
      else
        nil
      end

    Enum.map(mod.__xitdb_indexes__(), fn
      {c, field, idx_name} ->
        {c, field, idx_name}

      {field, idx_name} when not is_nil(col) ->
        {col, field, idx_name}

      {field, idx_name} ->
        compile_error!(
          caller,
          "Module #{inspect(mod)} returned 2-tuple index #{inspect({field, idx_name})} from __xitdb_indexes__/0 without defining __xitdb_collection__/0"
        )
    end)
  end

  defp block_has_tx_update?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {op, meta, _args}, acc when op in @nested_tx_macros and is_list(meta) ->
          {nil, acc}

        {{:., _, [_mod, op]}, _, _}, acc when op in @nested_tx_macros ->
          {nil, acc}

        {:update, _meta, args} = node, _acc when length(args) in [2, 3] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp rewrite_ast({op, meta, _args} = node, _tx_ref_var, _caller)
       when op in @nested_tx_macros and is_list(meta) do
    node
  end

  defp rewrite_ast({{:., _, [_mod, op]}, _, _} = node, _tx_ref_var, _caller)
       when op in @nested_tx_macros do
    node
  end

  defp rewrite_ast({:put, _meta, [path_ast]}, tx_ref_var, _caller) do
    selector_ast = PathCompiler.compile(path_ast)

    quote do
      Xitdb.DSL.TxRuntime.put_set_member(unquote(tx_ref_var), unquote(selector_ast))
    end
  end

  defp rewrite_ast({:put, _meta, [path_ast, val_ast]}, tx_ref_var, caller) do
    selector_ast = PathCompiler.compile(path_ast)
    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)

    quote do
      Xitdb.DSL.TxRuntime.put(unquote(tx_ref_var), unquote(selector_ast), unquote(rewritten_val))
    end
  end

  defp rewrite_ast({:update, _meta, [path_ast, fun_ast]}, tx_ref_var, caller) do
    selector_ast = PathCompiler.compile(path_ast)
    rewritten_fun = rewrite_ast(fun_ast, tx_ref_var, caller)

    quote do
      Xitdb.DSL.TxRuntime.update(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(rewritten_fun)
      )
    end
  end

  defp rewrite_ast({:update, _meta, [path_ast, default_ast, fun_ast]}, tx_ref_var, caller) do
    selector_ast = PathCompiler.compile(path_ast)
    rewritten_default = rewrite_ast(default_ast, tx_ref_var, caller)
    rewritten_fun = rewrite_ast(fun_ast, tx_ref_var, caller)

    quote do
      Xitdb.DSL.TxRuntime.update(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(rewritten_default),
        unquote(rewritten_fun)
      )
    end
  end

  defp rewrite_ast({:rm, _meta, [path_ast]}, tx_ref_var, _caller) do
    selector_ast = PathCompiler.compile(path_ast)

    quote do
      Xitdb.DSL.TxRuntime.rm(unquote(tx_ref_var), unquote(selector_ast))
    end
  end

  defp rewrite_ast({:append, _meta, [path_ast, val_ast]}, tx_ref_var, caller) do
    selector_ast = PathCompiler.compile(path_ast)
    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)

    quote do
      Xitdb.DSL.TxRuntime.append(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(rewritten_val)
      )
    end
  end

  defp rewrite_ast({:insert, _meta, [target_ast, val_ast]}, tx_ref_var, caller) do
    {list_path_ast, idx_ast} = split_insert_target!(target_ast, caller)
    selector_ast = PathCompiler.compile(list_path_ast)
    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)

    quote do
      Xitdb.DSL.TxRuntime.insert(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(idx_ast),
        unquote(rewritten_val)
      )
    end
  end

  defp rewrite_ast({:insert, _meta, [list_path_ast, idx_ast, val_ast]}, tx_ref_var, caller) do
    selector_ast = PathCompiler.compile(list_path_ast)
    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)

    quote do
      Xitdb.DSL.TxRuntime.insert(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(idx_ast),
        unquote(rewritten_val)
      )
    end
  end

  defp rewrite_ast({:slice, _meta, [path_ast, range_ast]}, tx_ref_var, _caller) do
    selector_ast = PathCompiler.compile(path_ast)

    quote do
      Xitdb.DSL.TxRuntime.slice(unquote(tx_ref_var), unquote(selector_ast), unquote(range_ast))
    end
  end

  defp rewrite_ast({:slice, _meta, [path_ast, offset_ast, size_ast]}, tx_ref_var, _caller) do
    selector_ast = PathCompiler.compile(path_ast)

    quote do
      Xitdb.DSL.TxRuntime.slice(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(offset_ast),
        unquote(size_ast)
      )
    end
  end

  defp rewrite_ast({:fork, _meta, [from_path_ast, to_path_ast]}, tx_ref_var, _caller) do
    from_selector = PathCompiler.compile(from_path_ast)
    to_selector = PathCompiler.compile(to_path_ast)

    quote do
      Xitdb.DSL.TxRuntime.fork(
        unquote(tx_ref_var),
        unquote(from_selector),
        unquote(to_selector)
      )
    end
  end

  defp rewrite_ast({:index_on, _meta, [src_ast, field_ast, idx_ast]}, tx_ref_var, _caller) do
    quote do
      Xitdb.DSL.TxRuntime.index_on(
        unquote(tx_ref_var),
        unquote(src_ast),
        unquote(field_ast),
        unquote(idx_ast)
      )
    end
  end

  defp rewrite_ast({:init_col, _meta, [path_ast, kind_ast]}, tx_ref_var, _caller) do
    selector_ast = PathCompiler.compile(path_ast)

    quote do
      Xitdb.DSL.TxRuntime.init_col(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(kind_ast),
        false
      )
    end
  end

  defp rewrite_ast({:reset_col, _meta, [path_ast, kind_ast]}, tx_ref_var, _caller) do
    selector_ast = PathCompiler.compile(path_ast)

    quote do
      Xitdb.DSL.TxRuntime.init_col(
        unquote(tx_ref_var),
        unquote(selector_ast),
        unquote(kind_ast),
        true
      )
    end
  end

  defp rewrite_ast({:meta, _meta, [key_ast, val_ast]}, tx_ref_var, caller) do
    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)

    quote do
      Xitdb.DSL.TxRuntime.meta(unquote(tx_ref_var), unquote(key_ast), unquote(rewritten_val))
    end
  end

  defp rewrite_ast({:instant, _meta, [epoch_ast]}, tx_ref_var, _caller) do
    quote do
      Xitdb.DSL.TxRuntime.instant(unquote(tx_ref_var), unquote(epoch_ast))
    end
  end

  defp rewrite_ast({:savepoint, _meta, args}, tx_ref_var, _caller)
       when is_nil(args) or args == [] do
    quote do
      Xitdb.DSL.TxRuntime.savepoint(unquote(tx_ref_var))
    end
  end

  defp rewrite_ast({:abort, _meta, [reason_ast]}, tx_ref_var, _caller) do
    quote do
      throw({:xitdb_tx_abort, unquote(tx_ref_var), unquote(reason_ast)})
    end
  end

  defp rewrite_ast({form, meta, args}, tx_ref_var, caller) when is_list(args) do
    {rewrite_ast(form, tx_ref_var, caller), meta,
     Enum.map(args, &rewrite_ast(&1, tx_ref_var, caller))}
  end

  defp rewrite_ast({left, right}, tx_ref_var, caller) do
    {rewrite_ast(left, tx_ref_var, caller), rewrite_ast(right, tx_ref_var, caller)}
  end

  defp rewrite_ast(list, tx_ref_var, caller) when is_list(list) do
    Enum.map(list, &rewrite_ast(&1, tx_ref_var, caller))
  end

  defp rewrite_ast(other, _tx_ref_var, _caller), do: other

  defp split_insert_target!({{:., _, [Access, :get]}, _, [list_ast, [idx_ast]]}, _caller) do
    {list_ast, unwrap_pin(idx_ast)}
  end

  defp split_insert_target!({{:., _, [Access, :get]}, _, [list_ast, idx_ast]}, _caller) do
    {list_ast, unwrap_pin(idx_ast)}
  end

  defp split_insert_target!({{:., _, [list_ast, mod_fn]}, _, [idx_ast]}, _caller)
       when mod_fn in [:linked, :linked_list] do
    {list_ast, unwrap_pin(idx_ast)}
  end

  defp split_insert_target!(bad_ast, caller) do
    compile_error!(
      caller,
      "insert/2 expects a list index path like `insert todos[[0]], val` or `insert todos, 0, val`, got: #{Macro.to_string(bad_ast)}"
    )
  end

  defp unwrap_pin({:^, _, [inner]}), do: inner
  defp unwrap_pin(ast), do: ast

  defp compile_error!(%Macro.Env{file: file, line: line}, description) do
    raise CompileError, file: file, line: line, description: description
  end

  defp compile_error!(nil, description) do
    raise CompileError, description: description
  end
end
