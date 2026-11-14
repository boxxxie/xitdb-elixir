# Reference: Step 4 — Extract `TxRuntime` & `TxRewriter`, Invert `tx_for` Ash Coupling, and Slim `Xitdb.DSL`

> [!IMPORTANT]
> **Step Metadata:**
> - **Track:** [`split_dsl_and_invert_ash_dependency_20261111`](../index.md)
> - **Wave:** Wave 4 (after Step 3 [`step3_datalog_compiler.md`](./step3_datalog_compiler.md))
> - **Target Modules:**
>   - `lib/xitdb/dsl/tx_runtime.ex`
>   - `lib/xitdb/dsl/tx_rewriter.ex`
>   - [`lib/xitdb/dsl.ex`](../../../../lib/xitdb/dsl.ex)
>   - [`lib/xitdb/ash/tx.ex`](../../../../lib/xitdb/ash/tx.ex)
>   - [`lib/xitdb/tx_compiler.ex`](../../../../lib/xitdb/tx_compiler.ex)
> - **Test Suite:** `test/xitdb/dsl/tx_rewriter_and_runtime_test.exs`

---

## 1. Architectural Motivation & Summary

Step 4 completes the `Xitdb.DSL` modularization and severs all references from core `Xitdb` modules to `Xitdb.Ash.*` and `Spark`:

* **Consistent read-your-own-writes staging (`lib/xitdb/dsl/tx_runtime.ex`):** Moves the process-dictionary staging runtime into `%Xitdb.DSL.TxRuntime{}` with a chronological `staged_log` (active only when `update` appears in the `tx` block) that folds exact, ancestor, and descendant mutations on top of committed `base_moment` values:
  1. Child `put`/`rm` followed by an ancestor `update` preserves both committed sibling keys and staged child writes (and auto-vivifies uncommitted parent maps).
  2. Overwriting a parent map or calling `reset_col` evicts stale staged child values.
  3. `%Xitdb.Collection{}` wrappers are recursively unwrapped into native string-keyed maps, lists, and `MapSet`s (`materialize_staged_value/1`) so `update` callbacks never receive raw `%Collection{}` structs.
  4. List operations (`append`, `insert`, `slice`) and `fork` (which snapshots `read_current_value/2` into the destination path) stay 100% consistent with subsequent `update` reads.

* **Isolated `tx` AST rewriter & inverted `tx_for` protocol (`lib/xitdb/dsl/tx_rewriter.ex`):** Moves AST rewriting out of `lib/xitdb/dsl.ex`, matches `{:ok, tx_ref} | {:error, _}` from `TxRuntime.init_state/3` for eager option validation, and removes all `Spark.Dsl.Extension` and `Xitdb.Ash.Info` `apply/3` calls from `tx_for` in favor of the plain-Elixir `__xitdb_indexes__/0` and optional `__xitdb_collection__/0` callbacks (including `@module_attr` schema lists).

* **Macro hygiene in `Xitdb.Ash.Tx` (`lib/xitdb/ash/tx.ex`):** Adds `require Xitdb.DSL` inside the quoted blocks of `tx_for/3,4` and `tx_for!/3,4` so callers using `require Xitdb.Ash.Tx` without `use Xitdb.DSL` never hit a missing-require `CompileError`.

* **Clean `Xitdb.TxCompiler` & ~220-line `Xitdb.DSL` facade:** Removes the temporary Step 1 delegates from `lib/xitdb/tx_compiler.ex` and trims `lib/xitdb/dsl.ex` to a thin macro entry-point module.

---

## 2. Step 4 Code Changes (`diff`)

````diff
diff --git a/lib/xitdb/ash/tx.ex b/lib/xitdb/ash/tx.ex
--- a/lib/xitdb/ash/tx.ex
+++ b/lib/xitdb/ash/tx.ex
@@ -1,32 +1,36 @@
 defmodule Xitdb.Ash.Tx do
   @moduledoc """
-  Provides `tx_for/3`, `tx_for/4`, `tx_for!/3`, and `tx_for!/4` macros that wrap
-  `Xitdb.DSL.tx` and automatically inject all `index_on` declarations configured on
-  one or more `Xitdb.Ash.Resource` modules.
+  Resource-aware transaction macro wrapper (`tx_for/3,4`, `tx_for!/3,4`) that automatically
+  injects `index_on` rules declared in one or more `Xitdb.Ash.Resource` modules (or plain
+  schema modules exporting `__xitdb_collection__/0` and `__xitdb_indexes__/0`).
 
-  Note: `use Xitdb.DSL` also imports `tx_for` and `tx_for!` directly.
+  Re-exports `Xitdb.DSL.tx_for/3,4` and `Xitdb.DSL.tx_for!/3,4` under the `Xitdb.Ash` namespace.
   """
 
   defmacro tx_for(db, resources, do: body) do
     quote do
+      require Xitdb.DSL
       Xitdb.DSL.tx_for(unquote(db), unquote(resources), [], do: unquote(body))
     end
   end
 
   defmacro tx_for(db, resources, opts, do: body) do
     quote do
+      require Xitdb.DSL
       Xitdb.DSL.tx_for(unquote(db), unquote(resources), unquote(opts), do: unquote(body))
     end
   end
 
   defmacro tx_for!(db, resources, do: body) do
     quote do
+      require Xitdb.DSL
       Xitdb.DSL.tx_for!(unquote(db), unquote(resources), [], do: unquote(body))
     end
   end
 
   defmacro tx_for!(db, resources, opts, do: body) do
     quote do
+      require Xitdb.DSL
       Xitdb.DSL.tx_for!(unquote(db), unquote(resources), unquote(opts), do: unquote(body))
     end
   end
diff --git a/lib/xitdb/dsl/tx_rewriter.ex b/lib/xitdb/dsl/tx_rewriter.ex
new file mode 100644
--- /dev/null
+++ b/lib/xitdb/dsl/tx_rewriter.ex
@@ -0,0 +1,401 @@
+defmodule Xitdb.DSL.TxRewriter do
+  @moduledoc false
+
+  alias Xitdb.DSL.PathCompiler
+
+  @nested_tx_macros [:tx, :tx!, :tx_for, :tx_for!]
+
+  @spec compile_tx(Macro.t(), Macro.t(), Macro.t(), Macro.Env.t() | nil) :: Macro.t()
+  def compile_tx(db_ast, opts_ast, block_ast, caller \\ nil) do
+    tx_ref_var = Macro.unique_var(:tx_ref, __MODULE__)
+    track_staged? = block_has_tx_update?(block_ast)
+    rewritten_block = rewrite_ast(block_ast, tx_ref_var, caller)
+
+    quote do
+      case Xitdb.DSL.TxRuntime.init_state(
+             unquote(db_ast),
+             unquote(opts_ast),
+             unquote(track_staged?)
+           ) do
+        {:ok, unquote(tx_ref_var)} ->
+          try do
+            _ = unquote(rewritten_block)
+            Xitdb.DSL.TxRuntime.commit_state(unquote(tx_ref_var))
+          rescue
+            e in Xitdb.Error ->
+              {:error, e}
+
+            e ->
+              {:error, %Xitdb.Error{reason: :transaction_exception, details: %{exception: e}}}
+          catch
+            {:xitdb_tx_abort, unquote(tx_ref_var), reason} ->
+              {:error, %Xitdb.Error{reason: reason}}
+          after
+            Xitdb.DSL.TxRuntime.cleanup_state(unquote(tx_ref_var))
+          end
+
+        {:error, _} = err ->
+          err
+      end
+    end
+  end
+
+  @spec compile_tx_bang(Macro.t(), Macro.t(), Macro.t(), Macro.Env.t() | nil) :: Macro.t()
+  def compile_tx_bang(db_ast, opts_ast, block_ast, caller \\ nil) do
+    wrap_bang(compile_tx(db_ast, opts_ast, block_ast, caller))
+  end
+
+  @spec compile_tx_for(Macro.t(), Macro.t(), Macro.t(), Macro.t(), Macro.Env.t()) :: Macro.t()
+  def compile_tx_for(db_ast, schemas_ast, opts_ast, block_ast, caller) do
+    schema_list =
+      case Macro.expand(schemas_ast, caller) do
+        list when is_list(list) -> list
+        single -> [single]
+      end
+
+    index_calls =
+      for schema_node <- schema_list,
+          {col, field, idx_name} <- extract_schema_indexes!(schema_node, caller),
+          uniq: true do
+        {:index_on, [], [col, field, idx_name]}
+      end
+
+    combined_block = {:__block__, [], index_calls ++ [block_ast]}
+    compile_tx(db_ast, opts_ast, combined_block, caller)
+  end
+
+  @spec compile_tx_for_bang(Macro.t(), Macro.t(), Macro.t(), Macro.t(), Macro.Env.t()) ::
+          Macro.t()
+  def compile_tx_for_bang(db_ast, schemas_ast, opts_ast, block_ast, caller) do
+    wrap_bang(compile_tx_for(db_ast, schemas_ast, opts_ast, block_ast, caller))
+  end
+
+  defp wrap_bang(tx_quoted) do
+    quote do
+      case unquote(tx_quoted) do
+        {:ok, updated_db} -> updated_db
+        {:error, err} -> raise err
+      end
+    end
+  end
+
+  defp extract_schema_indexes!(schema_ast, caller) do
+    mod = Macro.expand(schema_ast, caller)
+
+    if not is_atom(mod) or is_nil(mod) do
+      compile_error!(
+        caller,
+        "tx_for expects a compile-time module or list of modules, got: #{Macro.to_string(schema_ast)}"
+      )
+    end
+
+    case Code.ensure_compiled(mod) do
+      {:module, ^mod} ->
+        extract_compiled_module_indexes!(mod, caller)
+
+      {:error, reason} ->
+        compile_error!(
+          caller,
+          "tx_for could not load schema module #{inspect(mod)} (#{inspect(reason)})"
+        )
+    end
+  end
+
+  defp extract_compiled_module_indexes!(mod, caller) do
+    if not function_exported?(mod, :__xitdb_indexes__, 0) do
+      compile_error!(
+        caller,
+        "Module #{inspect(mod)} does not declare Xitdb indexes (use `Xitdb.Ash.Resource` or define `__xitdb_collection__/0` and `__xitdb_indexes__/0`)."
+      )
+    end
+
+    col =
+      if function_exported?(mod, :__xitdb_collection__, 0) do
+        mod.__xitdb_collection__()
+      else
+        nil
+      end
+
+    Enum.map(mod.__xitdb_indexes__(), fn
+      {c, field, idx_name} ->
+        {c, field, idx_name}
+
+      {field, idx_name} when not is_nil(col) ->
+        {col, field, idx_name}
+
+      {field, idx_name} ->
+        compile_error!(
+          caller,
+          "Module #{inspect(mod)} returned 2-tuple index #{inspect({field, idx_name})} from __xitdb_indexes__/0 without defining __xitdb_collection__/0"
+        )
+    end)
+  end
+
+  defp block_has_tx_update?(ast) do
+    {_ast, found?} =
+      Macro.prewalk(ast, false, fn
+        {op, meta, _args}, acc when op in @nested_tx_macros and is_list(meta) ->
+          {nil, acc}
+
+        {{:., _, [_mod, op]}, _, _}, acc when op in @nested_tx_macros ->
+          {nil, acc}
+
+        {:update, _meta, args} = node, _acc when length(args) in [2, 3] ->
+          {node, true}
+
+        node, acc ->
+          {node, acc}
+      end)
+
+    found?
+  end
+
+  defp rewrite_ast({op, meta, _args} = node, _tx_ref_var, _caller)
+       when op in @nested_tx_macros and is_list(meta) do
+    node
+  end
+
+  defp rewrite_ast({{:., _, [_mod, op]}, _, _} = node, _tx_ref_var, _caller)
+       when op in @nested_tx_macros do
+    node
+  end
+
+  defp rewrite_ast({:put, _meta, [path_ast]}, tx_ref_var, _caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+
+    quote do
+      Xitdb.DSL.TxRuntime.put_set_member(unquote(tx_ref_var), unquote(selector_ast))
+    end
+  end
+
+  defp rewrite_ast({:put, _meta, [path_ast, val_ast]}, tx_ref_var, caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)
+
+    quote do
+      Xitdb.DSL.TxRuntime.put(unquote(tx_ref_var), unquote(selector_ast), unquote(rewritten_val))
+    end
+  end
+
+  defp rewrite_ast({:update, _meta, [path_ast, fun_ast]}, tx_ref_var, caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+    rewritten_fun = rewrite_ast(fun_ast, tx_ref_var, caller)
+
+    quote do
+      Xitdb.DSL.TxRuntime.update(
+        unquote(tx_ref_var),
+        unquote(selector_ast),
+        unquote(rewritten_fun)
+      )
+    end
+  end
+
+  defp rewrite_ast({:update, _meta, [path_ast, default_ast, fun_ast]}, tx_ref_var, caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+    rewritten_default = rewrite_ast(default_ast, tx_ref_var, caller)
+    rewritten_fun = rewrite_ast(fun_ast, tx_ref_var, caller)
+
+    quote do
+      Xitdb.DSL.TxRuntime.update(
+        unquote(tx_ref_var),
+        unquote(selector_ast),
+        unquote(rewritten_default),
+        unquote(rewritten_fun)
+      )
+    end
+  end
+
+  defp rewrite_ast({:rm, _meta, [path_ast]}, tx_ref_var, _caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+
+    quote do
+      Xitdb.DSL.TxRuntime.rm(unquote(tx_ref_var), unquote(selector_ast))
+    end
+  end
+
+  defp rewrite_ast({:append, _meta, [path_ast, val_ast]}, tx_ref_var, caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)
+
+    quote do
+      Xitdb.DSL.TxRuntime.append(
+        unquote(tx_ref_var),
+        unquote(selector_ast),
+        unquote(rewritten_val)
+      )
+    end
+  end
+
+  defp rewrite_ast({:insert, _meta, [target_ast, val_ast]}, tx_ref_var, caller) do
+    {list_path_ast, idx_ast} = split_insert_target!(target_ast, caller)
+    selector_ast = PathCompiler.compile(list_path_ast)
+    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)
+
+    quote do
+      Xitdb.DSL.TxRuntime.insert(
+        unquote(tx_ref_var),
+        unquote(selector_ast),
+        unquote(idx_ast),
+        unquote(rewritten_val)
+      )
+    end
+  end
+
+  defp rewrite_ast({:insert, _meta, [list_path_ast, idx_ast, val_ast]}, tx_ref_var, caller) do
+    selector_ast = PathCompiler.compile(list_path_ast)
+    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)
+
+    quote do
+      Xitdb.DSL.TxRuntime.insert(
+        unquote(tx_ref_var),
+        unquote(selector_ast),
+        unquote(idx_ast),
+        unquote(rewritten_val)
+      )
+    end
+  end
+
+  defp rewrite_ast({:slice, _meta, [path_ast, range_ast]}, tx_ref_var, _caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+
+    quote do
+      Xitdb.DSL.TxRuntime.slice(unquote(tx_ref_var), unquote(selector_ast), unquote(range_ast))
+    end
+  end
+
+  defp rewrite_ast({:slice, _meta, [path_ast, offset_ast, size_ast]}, tx_ref_var, _caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+
+    quote do
+      Xitdb.DSL.TxRuntime.slice(
+        unquote(tx_ref_var),
+        unquote(selector_ast),
+        unquote(offset_ast),
+        unquote(size_ast)
+      )
+    end
+  end
+
+  defp rewrite_ast({:fork, _meta, [from_path_ast, to_path_ast]}, tx_ref_var, _caller) do
+    from_selector = PathCompiler.compile(from_path_ast)
+    to_selector = PathCompiler.compile(to_path_ast)
+
+    quote do
+      Xitdb.DSL.TxRuntime.fork(
+        unquote(tx_ref_var),
+        unquote(from_selector),
+        unquote(to_selector)
+      )
+    end
+  end
+
+  defp rewrite_ast({:index_on, _meta, [src_ast, field_ast, idx_ast]}, tx_ref_var, _caller) do
+    quote do
+      Xitdb.DSL.TxRuntime.index_on(
+        unquote(tx_ref_var),
+        unquote(src_ast),
+        unquote(field_ast),
+        unquote(idx_ast)
+      )
+    end
+  end
+
+  defp rewrite_ast({:init_col, _meta, [path_ast, kind_ast]}, tx_ref_var, _caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+
+    quote do
+      Xitdb.DSL.TxRuntime.init_col(
+        unquote(tx_ref_var),
+        unquote(selector_ast),
+        unquote(kind_ast),
+        false
+      )
+    end
+  end
+
+  defp rewrite_ast({:reset_col, _meta, [path_ast, kind_ast]}, tx_ref_var, _caller) do
+    selector_ast = PathCompiler.compile(path_ast)
+
+    quote do
+      Xitdb.DSL.TxRuntime.init_col(
+        unquote(tx_ref_var),
+        unquote(selector_ast),
+        unquote(kind_ast),
+        true
+      )
+    end
+  end
+
+  defp rewrite_ast({:meta, _meta, [key_ast, val_ast]}, tx_ref_var, caller) do
+    rewritten_val = rewrite_ast(val_ast, tx_ref_var, caller)
+
+    quote do
+      Xitdb.DSL.TxRuntime.meta(unquote(tx_ref_var), unquote(key_ast), unquote(rewritten_val))
+    end
+  end
+
+  defp rewrite_ast({:instant, _meta, [epoch_ast]}, tx_ref_var, _caller) do
+    quote do
+      Xitdb.DSL.TxRuntime.instant(unquote(tx_ref_var), unquote(epoch_ast))
+    end
+  end
+
+  defp rewrite_ast({:savepoint, _meta, args}, tx_ref_var, _caller)
+       when is_nil(args) or args == [] do
+    quote do
+      Xitdb.DSL.TxRuntime.savepoint(unquote(tx_ref_var))
+    end
+  end
+
+  defp rewrite_ast({:abort, _meta, [reason_ast]}, tx_ref_var, _caller) do
+    quote do
+      throw({:xitdb_tx_abort, unquote(tx_ref_var), unquote(reason_ast)})
+    end
+  end
+
+  defp rewrite_ast({form, meta, args}, tx_ref_var, caller) when is_list(args) do
+    {rewrite_ast(form, tx_ref_var, caller), meta,
+     Enum.map(args, &rewrite_ast(&1, tx_ref_var, caller))}
+  end
+
+  defp rewrite_ast({left, right}, tx_ref_var, caller) do
+    {rewrite_ast(left, tx_ref_var, caller), rewrite_ast(right, tx_ref_var, caller)}
+  end
+
+  defp rewrite_ast(list, tx_ref_var, caller) when is_list(list) do
+    Enum.map(list, &rewrite_ast(&1, tx_ref_var, caller))
+  end
+
+  defp rewrite_ast(other, _tx_ref_var, _caller), do: other
+
+  defp split_insert_target!({{:., _, [Access, :get]}, _, [list_ast, [idx_ast]]}, _caller) do
+    {list_ast, unwrap_pin(idx_ast)}
+  end
+
+  defp split_insert_target!({{:., _, [Access, :get]}, _, [list_ast, idx_ast]}, _caller) do
+    {list_ast, unwrap_pin(idx_ast)}
+  end
+
+  defp split_insert_target!({{:., _, [list_ast, mod_fn]}, _, [idx_ast]}, _caller)
+       when mod_fn in [:linked, :linked_list] do
+    {list_ast, unwrap_pin(idx_ast)}
+  end
+
+  defp split_insert_target!(bad_ast, caller) do
+    compile_error!(
+      caller,
+      "insert/2 expects a list index path like `insert todos[[0]], val` or `insert todos, 0, val`, got: #{Macro.to_string(bad_ast)}"
+    )
+  end
+
+  defp unwrap_pin({:^, _, [inner]}), do: inner
+  defp unwrap_pin(ast), do: ast
+
+  defp compile_error!(%Macro.Env{file: file, line: line}, description) do
+    raise CompileError, file: file, line: line, description: description
+  end
+
+  defp compile_error!(nil, description) do
+    raise CompileError, description: description
+  end
+end
diff --git a/lib/xitdb/dsl/tx_runtime.ex b/lib/xitdb/dsl/tx_runtime.ex
new file mode 100644
--- /dev/null
+++ b/lib/xitdb/dsl/tx_runtime.ex
@@ -0,0 +1,680 @@
+defmodule Xitdb.DSL.TxRuntime do
+  @moduledoc false
+
+  alias Xitdb.{Collection, Cursor, Error, NIF, TxCompiler}
+
+  @enforce_keys [:db, :opts]
+  defstruct [:db, :opts, index_ops: [], ops: [], staged_log: nil]
+
+  def init_state(db, opts, track_staged? \\ false) do
+    if is_list(opts) do
+      tx_ref = make_ref()
+
+      state = %__MODULE__{
+        db: db,
+        opts: opts,
+        staged_log: if(track_staged?, do: [], else: nil)
+      }
+
+      Process.put(tx_ref, state)
+      {:ok, tx_ref}
+    else
+      {:error,
+       %Error{
+         reason: :invalid_options,
+         details: %{message: "expected keyword list of options, got: #{inspect(opts)}"}
+       }}
+    end
+  end
+
+  def cleanup_state(tx_ref) do
+    Process.delete(tx_ref)
+    :ok
+  end
+
+  def commit_state(tx_ref) do
+    %__MODULE__{db: db, opts: opts, index_ops: index_ops, ops: ops} = Process.get(tx_ref)
+    all_ops = :lists.reverse(index_ops, :lists.reverse(ops))
+    Xitdb.transact_ops(db, all_ops, opts)
+  end
+
+  def put(tx_ref, selector, value) when is_binary(selector) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+
+    cond do
+      is_nil(value) ->
+        rm(tx_ref, selector)
+        nil
+
+      not is_map(value) and not is_list(value) ->
+        op = {:put, selector, value}
+        staged_log = append_staged(state.staged_log, {:put, parse_selector_steps(selector), value})
+        Process.put(tx_ref, %__MODULE__{state | ops: [op | state.ops], staged_log: staged_log})
+        value
+
+      true ->
+        compiled_ops = TxCompiler.compile_node(selector, value, true)
+
+        staged_log =
+          case state.staged_log do
+            nil ->
+              nil
+
+            log ->
+              [{:put, parse_selector_steps(selector), materialize_staged_value(value)} | log]
+          end
+
+        new_state = %__MODULE__{
+          state
+          | ops: :lists.reverse(compiled_ops, state.ops),
+            staged_log: staged_log
+        }
+
+        Process.put(tx_ref, new_state)
+        value
+    end
+  end
+
+  def put_set_member(tx_ref, selector) when is_binary(selector) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    op = {:put, selector, ""}
+    staged_log = append_staged(state.staged_log, {:put_set_member, parse_selector_steps(selector)})
+    Process.put(tx_ref, %__MODULE__{state | ops: [op | state.ops], staged_log: staged_log})
+    true
+  end
+
+  def update(tx_ref, selector, fun) when is_binary(selector) and is_function(fun, 1) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    current = read_current_value(state, selector)
+    put(tx_ref, selector, fun.(current))
+  end
+
+  def update(tx_ref, selector, default, fun)
+      when is_binary(selector) and is_function(fun, 1) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    current = read_current_value(state, selector)
+    resolved = if is_nil(current), do: default, else: current
+    put(tx_ref, selector, fun.(resolved))
+  end
+
+  def rm(tx_ref, selector) when is_binary(selector) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    staged_log = append_staged(state.staged_log, {:rm, parse_selector_steps(selector)})
+
+    Process.put(tx_ref, %__MODULE__{
+      state
+      | ops: [{:rm, selector} | state.ops],
+        staged_log: staged_log
+    })
+
+    :ok
+  end
+
+  def append(tx_ref, selector, value) when is_binary(selector) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+
+    staged_log =
+      case state.staged_log do
+        nil ->
+          nil
+
+        log ->
+          [{:append, parse_selector_steps(selector), materialize_staged_value(value)} | log]
+      end
+
+    Process.put(tx_ref, %__MODULE__{
+      state
+      | ops: [{:append, selector, value} | state.ops],
+        staged_log: staged_log
+    })
+
+    value
+  end
+
+  def insert(tx_ref, selector, index, value)
+      when is_binary(selector) and is_integer(index) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+
+    staged_log =
+      case state.staged_log do
+        nil ->
+          nil
+
+        log ->
+          [{:insert, parse_selector_steps(selector), index, materialize_staged_value(value)} | log]
+      end
+
+    Process.put(tx_ref, %__MODULE__{
+      state
+      | ops: [{:insert, selector, index, value} | state.ops],
+        staged_log: staged_log
+    })
+
+    value
+  end
+
+  def slice(tx_ref, selector, first.._last//1 = range) when is_binary(selector) do
+    slice(tx_ref, selector, first, Range.size(range))
+  end
+
+  def slice(tx_ref, selector, offset, size)
+      when is_binary(selector) and is_integer(offset) and is_integer(size) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+
+    staged_log =
+      append_staged(state.staged_log, {:slice, parse_selector_steps(selector), offset, size})
+
+    Process.put(tx_ref, %__MODULE__{
+      state
+      | ops: [{:slice, selector, offset, size} | state.ops],
+        staged_log: staged_log
+    })
+
+    :ok
+  end
+
+  def fork(tx_ref, from_selector, to_selector)
+      when is_binary(from_selector) and is_binary(to_selector) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+
+    staged_log =
+      case state.staged_log do
+        nil ->
+          nil
+
+        log ->
+          cloned = read_current_value(state, from_selector)
+          [{:put, parse_selector_steps(to_selector), cloned} | log]
+      end
+
+    Process.put(tx_ref, %__MODULE__{
+      state
+      | ops: [{:fork, from_selector, to_selector} | state.ops],
+        staged_log: staged_log
+    })
+
+    :ok
+  end
+
+  def index_on(tx_ref, src_map, field_key, idx_map) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    op = {:index_on, to_string(src_map), to_string(field_key), to_string(idx_map)}
+    Process.put(tx_ref, %__MODULE__{state | index_ops: [op | state.index_ops]})
+    :ok
+  end
+
+  def init_col(tx_ref, selector, kind, reset?) when is_binary(selector) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    op_tag = if reset?, do: :reset_col, else: :init_col
+    empty_val = empty_collection_value(kind)
+
+    staged_log =
+      append_staged(state.staged_log, {op_tag, parse_selector_steps(selector), empty_val})
+
+    Process.put(tx_ref, %__MODULE__{
+      state
+      | ops: [{op_tag, selector, to_string(kind)} | state.ops],
+        staged_log: staged_log
+    })
+
+    :ok
+  end
+
+  def meta(tx_ref, key, val) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    Process.put(tx_ref, %__MODULE__{state | ops: [{:meta, to_string(key), val} | state.ops]})
+    val
+  end
+
+  def instant(tx_ref, epoch_ms) when is_integer(epoch_ms) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    Process.put(tx_ref, %__MODULE__{state | ops: [{:instant, epoch_ms} | state.ops]})
+    epoch_ms
+  end
+
+  def savepoint(tx_ref) do
+    %__MODULE__{} = state = Process.get(tx_ref)
+    Process.put(tx_ref, %__MODULE__{state | ops: [{:savepoint, ""} | state.ops]})
+    :ok
+  end
+
+  defp append_staged(nil, _entry), do: nil
+  defp append_staged(log, entry), do: [entry | log]
+
+  defp empty_collection_value(kind) when kind in [:hash_map, :counted_hash_map, :sorted_map],
+    do: %{}
+
+  defp empty_collection_value(kind) when kind in [:array_list, :linked_array_list], do: []
+
+  defp empty_collection_value(kind) when kind in [:hash_set, :counted_hash_set, :sorted_set],
+    do: MapSet.new()
+
+  defp empty_collection_value(_), do: nil
+
+  defp materialize_staged_value(%Collection{kind: kind, data: data})
+       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
+    Map.new(data, fn {k, v} -> {to_string(k), materialize_staged_value(v)} end)
+  end
+
+  defp materialize_staged_value(%Collection{kind: kind, data: list})
+       when kind in [:array_list, :linked_array_list] do
+    Enum.map(list, &materialize_staged_value/1)
+  end
+
+  defp materialize_staged_value(%Collection{kind: kind, data: members})
+       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
+    MapSet.new(members, &to_string/1)
+  end
+
+  defp materialize_staged_value(%MapSet{} = set) do
+    MapSet.new(set, &to_string/1)
+  end
+
+  defp materialize_staged_value(map) when is_map(map) and not is_struct(map) do
+    Map.new(map, fn {k, v} -> {to_string(k), materialize_staged_value(v)} end)
+  end
+
+  defp materialize_staged_value(list) when is_list(list) do
+    Enum.map(list, &materialize_staged_value/1)
+  end
+
+  defp materialize_staged_value(scalar), do: scalar
+
+  defp read_current_value(%__MODULE__{staged_log: staged_log, db: db, opts: opts}, selector) do
+    target_steps = parse_selector_steps(selector)
+    chronological = :lists.reverse(staged_log || [])
+    base_steps = effective_base_steps(chronological, target_steps)
+
+    {start_base, entries_to_apply} =
+      case split_at_last_overwrite(chronological, base_steps) do
+        {:overwritten, remaining} ->
+          {nil, remaining}
+
+        :needs_db ->
+          base_sel = format_steps_selector(base_steps)
+          {read_committed_value(db, opts, base_sel), chronological}
+      end
+
+    resolved_base =
+      Enum.reduce(entries_to_apply, start_base, fn entry, acc ->
+        apply_staged_entry(entry, base_steps, acc)
+      end)
+
+    rel_tail = Enum.drop(target_steps, length(base_steps))
+    get_at_steps(resolved_base, rel_tail)
+  end
+
+  defp effective_base_steps(chronological, target_steps) do
+    Enum.reduce(chronological, target_steps, fn
+      {:append, steps, _}, cur -> if prefix_steps?(steps, cur), do: steps, else: cur
+      {:insert, steps, _, _}, cur -> if prefix_steps?(steps, cur), do: steps, else: cur
+      {:slice, steps, _, _}, cur -> if prefix_steps?(steps, cur), do: steps, else: cur
+      _, cur -> cur
+    end)
+  end
+
+  defp split_at_last_overwrite(chronological, target_steps) do
+    chronological
+    |> Enum.with_index()
+    |> Enum.reduce(nil, fn {entry, idx}, last_idx ->
+      if overwrites_target?(entry, target_steps), do: idx, else: last_idx
+    end)
+    |> case do
+      nil -> :needs_db
+      idx -> {:overwritten, Enum.drop(chronological, idx)}
+    end
+  end
+
+  defp overwrites_target?({op, steps, _val}, target_steps) when op in [:put, :reset_col] do
+    prefix_steps?(steps, target_steps)
+  end
+
+  defp overwrites_target?({:rm, steps}, target_steps) do
+    prefix_steps?(steps, target_steps)
+  end
+
+  defp overwrites_target?({:put_set_member, steps}, target_steps) do
+    steps == target_steps
+  end
+
+  defp overwrites_target?(_entry, _target_steps), do: false
+
+  defp read_committed_value(db, opts, selector) do
+    if Xitdb.moment_count(db) == 0 do
+      nil
+    else
+      base_moment = Keyword.get(opts, :base_moment, -1)
+
+      if selector == "" do
+        Xitdb.materialize(Xitdb.as_of(db, base_moment))
+      else
+        case NIF.nif_select(db.db_ref, base_moment, selector) do
+          {:ok, raw} ->
+            case Cursor.unwrap_nif_value(db.db_ref, raw, base_moment, []) do
+              %Cursor{} = cur -> Xitdb.materialize(cur)
+              scalar -> scalar
+            end
+
+          {:error, _} ->
+            nil
+        end
+      end
+    end
+  end
+
+  defp apply_staged_entry({:put, steps, val}, target_steps, current) do
+    case step_relation(steps, target_steps) do
+      :exact -> val
+      {:ancestor, rel_tail} -> get_at_steps(val, rel_tail)
+      {:descendant, rel_tail} -> put_at_steps(current, rel_tail, val)
+      :disjoint -> current
+    end
+  end
+
+  defp apply_staged_entry({:put_set_member, steps}, target_steps, current) do
+    case step_relation(steps, target_steps) do
+      :exact -> true
+      {:descendant, rel_tail} -> put_set_member_at_steps(current, rel_tail)
+      _ -> current
+    end
+  end
+
+  defp apply_staged_entry({:rm, steps}, target_steps, current) do
+    case step_relation(steps, target_steps) do
+      :exact -> nil
+      {:ancestor, _rel_tail} -> nil
+      {:descendant, rel_tail} -> rm_at_steps(current, rel_tail)
+      :disjoint -> current
+    end
+  end
+
+  defp apply_staged_entry({:reset_col, steps, empty_val}, target_steps, current) do
+    case step_relation(steps, target_steps) do
+      :exact -> empty_val
+      {:ancestor, _rel_tail} -> nil
+      {:descendant, rel_tail} -> put_at_steps(current, rel_tail, empty_val)
+      :disjoint -> current
+    end
+  end
+
+  defp apply_staged_entry({:init_col, steps, empty_val}, target_steps, current) do
+    case step_relation(steps, target_steps) do
+      :exact ->
+        if is_nil(current), do: empty_val, else: current
+
+      {:descendant, rel_tail} ->
+        if is_nil(get_at_steps(current, rel_tail)) do
+          put_at_steps(current, rel_tail, empty_val)
+        else
+          current
+        end
+
+      _ ->
+        current
+    end
+  end
+
+  defp apply_staged_entry({:append, steps, elem}, target_steps, current) do
+    update_list_at_steps(steps, target_steps, current, fn list ->
+      (list || []) ++ [elem]
+    end)
+  end
+
+  defp apply_staged_entry({:insert, steps, idx, elem}, target_steps, current) do
+    update_list_at_steps(steps, target_steps, current, fn list ->
+      base = list || []
+      resolved_idx = resolve_insert_index(base, idx)
+      List.insert_at(base, resolved_idx, elem)
+    end)
+  end
+
+  defp apply_staged_entry({:slice, steps, offset, size}, target_steps, current) do
+    update_list_at_steps(steps, target_steps, current, fn
+      list when is_list(list) ->
+        if size <= 0, do: [], else: Enum.slice(list, offset, size)
+
+      other ->
+        other
+    end)
+  end
+
+  defp update_list_at_steps(steps, target_steps, current, list_fun) do
+    case step_relation(steps, target_steps) do
+      :exact ->
+        list_fun.(current)
+
+      {:descendant, rel_tail} ->
+        existing = get_at_steps(current, rel_tail)
+        put_at_steps(current, rel_tail, list_fun.(existing))
+
+      _ ->
+        current
+    end
+  end
+
+  defp resolve_insert_index(list, idx) when idx < 0, do: max(length(list) + idx, 0)
+  defp resolve_insert_index(list, idx), do: min(idx, length(list))
+
+  defp prefix_steps?(prefix, steps) do
+    p_len = length(prefix)
+    length(steps) >= p_len and Enum.take(steps, p_len) == prefix
+  end
+
+  defp step_relation(steps, target_steps) do
+    cond do
+      steps == target_steps -> :exact
+      prefix_steps?(steps, target_steps) -> {:ancestor, Enum.drop(target_steps, length(steps))}
+      prefix_steps?(target_steps, steps) -> {:descendant, Enum.drop(steps, length(target_steps))}
+      true -> :disjoint
+    end
+  end
+
+  defp get_at_steps(val, []), do: val
+  defp get_at_steps(nil, _steps), do: nil
+
+  defp get_at_steps(map, [{kind, key} | rest])
+       when kind in [:hash_map, :counted_hash_map, :sorted_map] and is_map(map) and
+              not is_struct(map) do
+    get_at_steps(Map.get(map, key), rest)
+  end
+
+  defp get_at_steps(list, [{kind, idx} | rest])
+       when kind in [:array_list, :linked_array_list] and is_list(list) do
+    get_at_steps(Enum.at(list, idx), rest)
+  end
+
+  defp get_at_steps(%MapSet{} = set, [{kind, member}])
+       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
+    if MapSet.member?(set, member), do: true, else: nil
+  end
+
+  defp get_at_steps(_other, _steps), do: nil
+
+  defp put_at_steps(_current, [], val), do: val
+
+  defp put_at_steps(current, [{kind, key} | rest], val)
+       when kind in [:hash_map, :counted_hash_map, :sorted_map] do
+    base = if is_map(current) and not is_struct(current), do: current, else: %{}
+    Map.put(base, key, put_at_steps(Map.get(base, key), rest, val))
+  end
+
+  defp put_at_steps(current, [{kind, idx} | rest], val)
+       when kind in [:array_list, :linked_array_list] do
+    base = if is_list(current), do: current, else: []
+    resolved = if idx < 0, do: length(base) + idx, else: idx
+
+    cond do
+      resolved >= 0 and resolved < length(base) ->
+        List.replace_at(base, resolved, put_at_steps(Enum.at(base, resolved), rest, val))
+
+      resolved == length(base) ->
+        base ++ [put_at_steps(nil, rest, val)]
+
+      true ->
+        base
+    end
+  end
+
+  defp put_at_steps(%MapSet{} = set, [{kind, member}], _val)
+       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
+    MapSet.put(set, member)
+  end
+
+  defp put_at_steps(_current, [{kind, member}], _val)
+       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
+    MapSet.new([member])
+  end
+
+  defp put_set_member_at_steps(current, [{kind, member}])
+       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
+    base = if match?(%MapSet{}, current), do: current, else: MapSet.new()
+    MapSet.put(base, member)
+  end
+
+  defp put_set_member_at_steps(current, [step | rest]) do
+    put_at_steps(current, [step], put_set_member_at_steps(get_at_steps(current, [step]), rest))
+  end
+
+  defp rm_at_steps(nil, _steps), do: nil
+
+  defp rm_at_steps(map, [{kind, key}])
+       when kind in [:hash_map, :counted_hash_map, :sorted_map] and is_map(map) and
+              not is_struct(map) do
+    Map.delete(map, key)
+  end
+
+  defp rm_at_steps(list, [{:linked_array_list, idx}]) when is_list(list) do
+    List.delete_at(list, idx)
+  end
+
+  defp rm_at_steps(%MapSet{} = set, [{kind, member}])
+       when kind in [:hash_set, :counted_hash_set, :sorted_set] do
+    MapSet.delete(set, member)
+  end
+
+  defp rm_at_steps(current, [step | rest]) do
+    case get_at_steps(current, [step]) do
+      nil -> current
+      child -> put_at_steps(current, [step], rm_at_steps(child, rest))
+    end
+  end
+
+  defp format_steps_selector([]), do: ""
+
+  defp format_steps_selector(steps) do
+    Enum.map_join(steps, "", fn {kind, key_or_idx} ->
+      Xitdb.Selector.format_step(kind, key_or_idx)
+    end)
+  end
+
+  defp parse_selector_steps(selector) when is_binary(selector) do
+    selector
+    |> strip_leading_moment()
+    |> do_parse_steps([])
+  end
+
+  defp strip_leading_moment(<<?@, rest::binary>>) do
+    {_num, tail} = take_until_sigil(rest)
+    tail
+  end
+
+  defp strip_leading_moment(bin), do: bin
+
+  defp do_parse_steps(<<>>, acc), do: :lists.reverse(acc)
+
+  defp do_parse_steps(<<?#, ?%, rest::binary>>, acc) do
+    {key, tail} = parse_key_token(rest)
+    do_parse_steps(tail, [{:counted_hash_set, key} | acc])
+  end
+
+  defp do_parse_steps(<<?., rest::binary>>, acc) do
+    {key, tail} = parse_key_token(rest)
+    do_parse_steps(tail, [{:hash_map, key} | acc])
+  end
+
+  defp do_parse_steps(<<?#, rest::binary>>, acc) do
+    {key, tail} = parse_key_token(rest)
+    do_parse_steps(tail, [{:counted_hash_map, key} | acc])
+  end
+
+  defp do_parse_steps(<<?$, rest::binary>>, acc) do
+    {key, tail} = parse_key_token(rest)
+    do_parse_steps(tail, [{:sorted_map, key} | acc])
+  end
+
+  defp do_parse_steps(<<?%, rest::binary>>, acc) do
+    {key, tail} = parse_key_token(rest)
+    do_parse_steps(tail, [{:hash_set, key} | acc])
+  end
+
+  defp do_parse_steps(<<?^, rest::binary>>, acc) do
+    {key, tail} = parse_key_token(rest)
+    do_parse_steps(tail, [{:sorted_set, key} | acc])
+  end
+
+  defp do_parse_steps(<<?[, ?[, rest::binary>>, acc) do
+    {int_str, <<?], ?], tail::binary>>} = take_until_byte(rest, ?])
+    do_parse_steps(tail, [{:linked_array_list, String.to_integer(int_str)} | acc])
+  end
+
+  defp do_parse_steps(<<?[, ?", rest::binary>>, acc) do
+    {unescaped, <<?], tail::binary>>} = parse_quoted_string(rest, [])
+    do_parse_steps(tail, [{:hash_map, unescaped} | acc])
+  end
+
+  defp do_parse_steps(<<?[, rest::binary>>, acc) do
+    {int_str, <<?], tail::binary>>} = take_until_byte(rest, ?])
+    do_parse_steps(tail, [{:array_list, String.to_integer(int_str)} | acc])
+  end
+
+  defp parse_key_token(<<?[, ?", rest::binary>>) do
+    {unescaped, <<?], tail::binary>>} = parse_quoted_string(rest, [])
+    {unescaped, tail}
+  end
+
+  defp parse_key_token(bin), do: take_until_sigil(bin)
+
+  defp take_until_sigil(bin), do: do_take_until_sigil(bin, 0, bin)
+
+  defp do_take_until_sigil(<<>>, len, orig), do: {binary_part(orig, 0, len), <<>>}
+
+  defp do_take_until_sigil(<<b, _::binary>> = tail, len, orig)
+       when b in [?., ?#, ?$, ?[, ?%, ?^] do
+    {binary_part(orig, 0, len), tail}
+  end
+
+  defp do_take_until_sigil(<<_, rest::binary>>, len, orig) do
+    do_take_until_sigil(rest, len + 1, orig)
+  end
+
+  defp take_until_byte(bin, stop_byte), do: do_take_until_byte(bin, stop_byte, 0, bin)
+
+  defp do_take_until_byte(<<b, _::binary>> = tail, b, len, orig) do
+    {binary_part(orig, 0, len), tail}
+  end
+
+  defp do_take_until_byte(<<_, rest::binary>>, stop_byte, len, orig) do
+    do_take_until_byte(rest, stop_byte, len + 1, orig)
+  end
+
+  defp parse_quoted_string(<<?", tail::binary>>, acc),
+    do: {IO.iodata_to_binary(:lists.reverse(acc)), tail}
+
+  defp parse_quoted_string(<<?\\, ?\\, rest::binary>>, acc),
+    do: parse_quoted_string(rest, [?\\ | acc])
+
+  defp parse_quoted_string(<<?\\, ?", rest::binary>>, acc),
+    do: parse_quoted_string(rest, [?" | acc])
+
+  defp parse_quoted_string(<<?\\, ?n, rest::binary>>, acc),
+    do: parse_quoted_string(rest, [?\n | acc])
+
+  defp parse_quoted_string(<<?\\, ?r, rest::binary>>, acc),
+    do: parse_quoted_string(rest, [?\r | acc])
+
+  defp parse_quoted_string(<<?\\, ?t, rest::binary>>, acc),
+    do: parse_quoted_string(rest, [?\t | acc])
+
+  defp parse_quoted_string(<<b, rest::binary>>, acc),
+    do: parse_quoted_string(rest, [b | acc])
+end
diff --git a/lib/xitdb/dsl.ex b/lib/xitdb/dsl.ex
--- a/lib/xitdb/dsl.ex
+++ b/lib/xitdb/dsl.ex
@@ -37,8 +37,8 @@ defmodule Xitdb.DSL do
         end
   """
 
-  alias Xitdb.DSL.{DatalogCompiler, PathCompiler}
-  alias Xitdb.{Cursor, NIF, Pull, TxCompiler}
+  alias Xitdb.DSL.{DatalogCompiler, PathCompiler, TxRewriter}
+  alias Xitdb.Pull
 
   defmacro __using__(_opts) do
     quote do
@@ -94,7 +94,7 @@ defmodule Xitdb.DSL do
   end
 
   # ============================================================================
-  # 2. Transaction Mutation Block DSL (`tx/2`, `tx/3`, `tx!/2`, `tx!/3`)
+  # 2. Transaction Mutation Block DSL (`tx/2,3`, `tx!/2,3`, `tx_for/3,4`, `tx_for!/3,4`)
   # ============================================================================
 
   @doc """
@@ -118,11 +118,11 @@ defmodule Xitdb.DSL do
   - `abort reason`
   """
   defmacro tx(db, do: block) do
-    compile_tx_block(db, [], block)
+    TxRewriter.compile_tx(db, [], block, __CALLER__)
   end
 
   defmacro tx(db, opts, do: block) do
-    compile_tx_block(db, opts, block)
+    TxRewriter.compile_tx(db, opts, block, __CALLER__)
   end
 
   @doc """
@@ -130,21 +130,11 @@ defmodule Xitdb.DSL do
   or raises `Xitdb.Error` on failure.
   """
   defmacro tx!(db, do: block) do
-    quote do
-      case unquote(compile_tx_block(db, [], block)) do
-        {:ok, updated_db} -> updated_db
-        {:error, err} -> raise err
-      end
-    end
+    TxRewriter.compile_tx_bang(db, [], block, __CALLER__)
   end
 
   defmacro tx!(db, opts, do: block) do
-    quote do
-      case unquote(compile_tx_block(db, opts, block)) do
-        {:ok, updated_db} -> updated_db
-        {:error, err} -> raise err
-      end
-    end
+    TxRewriter.compile_tx_bang(db, opts, block, __CALLER__)
   end
 
   @doc """
@@ -153,11 +143,11 @@ defmodule Xitdb.DSL do
   `__xitdb_indexes__/0` and optional `__xitdb_collection__/0`).
   """
   defmacro tx_for(db, schemas, do: block) do
-    compile_tx_for_block(db, schemas, [], block, __CALLER__)
+    TxRewriter.compile_tx_for(db, schemas, [], block, __CALLER__)
   end
 
   defmacro tx_for(db, schemas, opts, do: block) do
-    compile_tx_for_block(db, schemas, opts, block, __CALLER__)
+    TxRewriter.compile_tx_for(db, schemas, opts, block, __CALLER__)
   end
 
   @doc """
@@ -165,771 +155,61 @@ defmodule Xitdb.DSL do
   or raises `Xitdb.Error` on failure.
   """
   defmacro tx_for!(db, schemas, do: block) do
-    quote do
-      case unquote(compile_tx_for_block(db, schemas, [], block, __CALLER__)) do
-        {:ok, updated_db} -> updated_db
-        {:error, err} -> raise err
-      end
-    end
+    TxRewriter.compile_tx_for_bang(db, schemas, [], block, __CALLER__)
   end
 
   defmacro tx_for!(db, schemas, opts, do: block) do
-    quote do
-      case unquote(compile_tx_for_block(db, schemas, opts, block, __CALLER__)) do
-        {:ok, updated_db} -> updated_db
-        {:error, err} -> raise err
-      end
-    end
-  end
-
-  defp compile_tx_for_block(db_ast, schemas_ast, opts_ast, block_ast, caller) do
-    schema_list =
-      case schemas_ast do
-        list when is_list(list) -> list
-        single -> [single]
-      end
-
-    index_calls =
-      for schema_node <- schema_list,
-          {col, field, idx_name} <- extract_schema_indexes!(schema_node, caller),
-          uniq: true do
-        {:index_on, [], [col, field, idx_name]}
-      end
-
-    combined_block =
-      {:__block__, [], index_calls ++ [block_ast]}
-
-    compile_tx_block(db_ast, opts_ast, combined_block)
-  end
-
-  defp extract_schema_indexes!(schema_ast, caller) do
-    mod = Macro.expand(schema_ast, caller)
-
-    if not is_atom(mod) do
-      raise CompileError,
-        file: caller.file,
-        line: caller.line,
-        description:
-          "tx_for expects a compile-time module or list of modules, got: #{Macro.to_string(schema_ast)}"
-    end
-
-    case Code.ensure_compiled(mod) do
-      {:module, ^mod} ->
-        extract_compiled_module_indexes!(mod, caller)
-
-      {:error, reason} ->
-        raise CompileError,
-          file: caller.file,
-          line: caller.line,
-          description: "tx_for could not load schema module #{inspect(mod)} (#{inspect(reason)})"
-    end
-  end
-
-  defp extract_compiled_module_indexes!(mod, caller) do
-    cond do
-      function_exported?(mod, :__xitdb_indexes__, 0) ->
-        col =
-          if function_exported?(mod, :__xitdb_collection__, 0) do
-            mod.__xitdb_collection__()
-          else
-            nil
-          end
-
-        Enum.map(mod.__xitdb_indexes__(), fn
-          {c, field, idx_name} ->
-            {c, field, idx_name}
-
-          {field, idx_name} when not is_nil(col) ->
-            {col, field, idx_name}
-
-          {field, idx_name} ->
-            raise CompileError,
-              file: caller.file,
-              line: caller.line,
-              description:
-                "Module #{inspect(mod)} returned 2-tuple index #{inspect({field, idx_name})} from __xitdb_indexes__/0 without defining __xitdb_collection__/0"
-        end)
-
-      Code.ensure_loaded?(Xitdb.Ash.Info) and function_exported?(mod, :spark_dsl_config, 0) ->
-        case apply(Spark.Dsl.Extension, :get_persisted, [mod, :xitdb_normalized_indexes, nil]) do
-          persisted when is_list(persisted) ->
-            persisted
-
-          nil ->
-            case apply(Xitdb.Ash.Info, :xitdb_collection, [mod]) do
-              {:ok, col} when not is_nil(col) ->
-                idxs = apply(Xitdb.Ash.Info, :xitdb_indexes!, [mod])
-                for {field, idx_name} <- idxs, do: {col, field, idx_name}
-
-              _ ->
-                raise_invalid_tx_for_schema!(mod, caller)
-            end
-        end
-
-      true ->
-        raise_invalid_tx_for_schema!(mod, caller)
-    end
+    TxRewriter.compile_tx_for_bang(db, schemas, opts, block, __CALLER__)
   end
 
-  defp raise_invalid_tx_for_schema!(mod, caller) do
-    raise CompileError,
-      file: caller.file,
-      line: caller.line,
-      description:
-        "Module #{inspect(mod)} does not declare Xitdb indexes (use `Xitdb.Ash.Resource` or define `__xitdb_collection__/0` and `__xitdb_indexes__/0`)."
-  end
-
-  defp compile_tx_block(db_ast, opts_ast, block_ast) do
-    tx_ref_var = Macro.unique_var(:tx_ref, __MODULE__)
-    track_staged? = block_has_tx_update?(block_ast)
-    rewritten_block = rewrite_tx_ast(block_ast, tx_ref_var)
-
-    quote do
-      unquote(tx_ref_var) =
-        Xitdb.DSL.__init_tx_state__(unquote(db_ast), unquote(opts_ast), unquote(track_staged?))
-
-      try do
-        _ = unquote(rewritten_block)
-        Xitdb.DSL.__commit_tx_state__(unquote(tx_ref_var))
-      rescue
-        e in Xitdb.Error ->
-          {:error, e}
-
-        e ->
-          {:error, %Xitdb.Error{reason: :transaction_exception, details: %{exception: e}}}
-      catch
-        {:xitdb_tx_abort, unquote(tx_ref_var), reason} ->
-          {:error, %Xitdb.Error{reason: reason}}
-      after
-        Xitdb.DSL.__cleanup_tx_state__(unquote(tx_ref_var))
-      end
-    end
-  end
-
-  defp block_has_tx_update?(ast) do
-    {_ast, found?} =
-      Macro.prewalk(ast, false, fn
-        {op, meta, _args}, acc
-        when op in [:tx, :tx!, :tx_for, :tx_for!] and is_list(meta) ->
-          {nil, acc}
-
-        {{:., _, [_mod, op]}, _, _}, acc
-        when op in [:tx, :tx!, :tx_for, :tx_for!] ->
-          {nil, acc}
-
-        {:update, _meta, args} = node, _acc when length(args) in [2, 3] ->
-          {node, true}
-
-        node, acc ->
-          {node, acc}
-      end)
-
-    found?
-  end
-
-  defp rewrite_tx_ast({op, meta, _args} = node, _tx_ref_var)
-       when op in [:tx, :tx!, :tx_for, :tx_for!] and is_list(meta) do
-    # Do not rewrite inside nested `tx` blocks
-    node
-  end
-
-  defp rewrite_tx_ast({{:., _, [_mod, op]}, _, _} = node, _tx_ref_var)
-       when op in [:tx, :tx!, :tx_for, :tx_for!] do
-    node
-  end
-
-  defp rewrite_tx_ast({:put, _meta, [path_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-
-    quote do
-      Xitdb.DSL.__tx_put_set_member__(unquote(tx_ref_var), unquote(selector_ast))
-    end
-  end
-
-  defp rewrite_tx_ast({:put, _meta, [path_ast, val_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
-
-    quote do
-      Xitdb.DSL.__tx_put__(unquote(tx_ref_var), unquote(selector_ast), unquote(rewritten_val))
-    end
-  end
-
-  defp rewrite_tx_ast({:update, _meta, [path_ast, fun_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-    rewritten_fun = rewrite_tx_ast(fun_ast, tx_ref_var)
-
-    quote do
-      Xitdb.DSL.__tx_update__(unquote(tx_ref_var), unquote(selector_ast), unquote(rewritten_fun))
-    end
-  end
-
-  defp rewrite_tx_ast({:update, _meta, [path_ast, default_ast, fun_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-    rewritten_default = rewrite_tx_ast(default_ast, tx_ref_var)
-    rewritten_fun = rewrite_tx_ast(fun_ast, tx_ref_var)
-
-    quote do
-      Xitdb.DSL.__tx_update__(
-        unquote(tx_ref_var),
-        unquote(selector_ast),
-        unquote(rewritten_default),
-        unquote(rewritten_fun)
-      )
-    end
-  end
-
-  defp rewrite_tx_ast({:rm, _meta, [path_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-
-    quote do
-      Xitdb.DSL.__tx_rm__(unquote(tx_ref_var), unquote(selector_ast))
-    end
-  end
-
-  defp rewrite_tx_ast({:append, _meta, [path_ast, val_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
-
-    quote do
-      Xitdb.DSL.__tx_append__(unquote(tx_ref_var), unquote(selector_ast), unquote(rewritten_val))
-    end
-  end
-
-  defp rewrite_tx_ast({:insert, _meta, [target_ast, val_ast]}, tx_ref_var) do
-    {list_path_ast, idx_ast} = split_insert_target!(target_ast)
-    selector_ast = PathCompiler.compile(list_path_ast)
-    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
-
-    quote do
-      Xitdb.DSL.__tx_insert__(
-        unquote(tx_ref_var),
-        unquote(selector_ast),
-        unquote(idx_ast),
-        unquote(rewritten_val)
-      )
-    end
-  end
-
-  defp rewrite_tx_ast({:insert, _meta, [list_path_ast, idx_ast, val_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(list_path_ast)
-    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
-
-    quote do
-      Xitdb.DSL.__tx_insert__(
-        unquote(tx_ref_var),
-        unquote(selector_ast),
-        unquote(idx_ast),
-        unquote(rewritten_val)
-      )
-    end
-  end
-
-  defp rewrite_tx_ast({:slice, _meta, [path_ast, range_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-
-    quote do
-      Xitdb.DSL.__tx_slice__(unquote(tx_ref_var), unquote(selector_ast), unquote(range_ast))
-    end
-  end
-
-  defp rewrite_tx_ast({:slice, _meta, [path_ast, offset_ast, size_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-
-    quote do
-      Xitdb.DSL.__tx_slice__(
-        unquote(tx_ref_var),
-        unquote(selector_ast),
-        unquote(offset_ast),
-        unquote(size_ast)
-      )
-    end
-  end
-
-  defp rewrite_tx_ast({:fork, _meta, [from_path_ast, to_path_ast]}, tx_ref_var) do
-    from_selector = PathCompiler.compile(from_path_ast)
-    to_selector = PathCompiler.compile(to_path_ast)
-
-    quote do
-      Xitdb.DSL.__tx_fork__(unquote(tx_ref_var), unquote(from_selector), unquote(to_selector))
-    end
-  end
-
-  defp rewrite_tx_ast({:index_on, _meta, [src_ast, field_ast, idx_ast]}, tx_ref_var) do
-    src_str = normalize_index_name(src_ast)
-    field_str = normalize_index_name(field_ast)
-    idx_str = normalize_index_name(idx_ast)
-
-    quote do
-      Xitdb.DSL.__tx_index_on__(
-        unquote(tx_ref_var),
-        unquote(src_str),
-        unquote(field_str),
-        unquote(idx_str)
-      )
-    end
-  end
-
-  defp rewrite_tx_ast({:init_col, _meta, [path_ast, kind_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-
-    quote do
-      Xitdb.DSL.__tx_init_col__(
-        unquote(tx_ref_var),
-        unquote(selector_ast),
-        unquote(kind_ast),
-        false
-      )
-    end
-  end
-
-  defp rewrite_tx_ast({:reset_col, _meta, [path_ast, kind_ast]}, tx_ref_var) do
-    selector_ast = PathCompiler.compile(path_ast)
-
-    quote do
-      Xitdb.DSL.__tx_init_col__(
-        unquote(tx_ref_var),
-        unquote(selector_ast),
-        unquote(kind_ast),
-        true
-      )
-    end
-  end
-
-  defp rewrite_tx_ast({:meta, _meta, [key_ast, val_ast]}, tx_ref_var) do
-    rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
-
-    quote do
-      Xitdb.DSL.__tx_meta__(unquote(tx_ref_var), unquote(key_ast), unquote(rewritten_val))
-    end
-  end
-
-  defp rewrite_tx_ast({:instant, _meta, [ms_ast]}, tx_ref_var) do
-    rewritten_ms = rewrite_tx_ast(ms_ast, tx_ref_var)
-
-    quote do
-      Xitdb.DSL.__tx_instant__(unquote(tx_ref_var), unquote(rewritten_ms))
-    end
-  end
-
-  defp rewrite_tx_ast({:savepoint, _meta, args}, tx_ref_var) when args in [[], nil] do
-    quote do
-      Xitdb.DSL.__tx_savepoint__(unquote(tx_ref_var))
-    end
-  end
-
-  defp rewrite_tx_ast({:abort, _meta, [reason_ast]}, tx_ref_var) do
-    quote do
-      throw({:xitdb_tx_abort, unquote(tx_ref_var), unquote(reason_ast)})
-    end
-  end
-
-  defp rewrite_tx_ast({form, meta, args}, tx_ref_var) when is_list(args) do
-    {rewrite_tx_ast(form, tx_ref_var), meta, Enum.map(args, &rewrite_tx_ast(&1, tx_ref_var))}
-  end
-
-  defp rewrite_tx_ast({left, right}, tx_ref_var) do
-    {rewrite_tx_ast(left, tx_ref_var), rewrite_tx_ast(right, tx_ref_var)}
-  end
-
-  defp rewrite_tx_ast(list, tx_ref_var) when is_list(list) do
-    Enum.map(list, &rewrite_tx_ast(&1, tx_ref_var))
-  end
-
-  defp rewrite_tx_ast(other, _tx_ref_var), do: other
-
-  defp split_insert_target!({{:., _, [Access, :get]}, _, [list_path_ast, [idx_ast]]}) do
-    {list_path_ast, idx_ast}
-  end
-
-  defp split_insert_target!({{:., _, [Access, :get]}, _, [list_path_ast, idx_ast]}) do
-    {list_path_ast, idx_ast}
-  end
-
-  defp split_insert_target!({{:., _, [list_path_ast, :linked]}, _, [idx_ast]}) do
-    {list_path_ast, idx_ast}
-  end
-
-  defp split_insert_target!(other) do
-    raise CompileError,
-      description:
-        "insert/2 expects a path ending in an index like `users[id].todos[[0]]`, or use insert/3 (`insert path, idx, val`). Got: #{Macro.to_string(other)}"
-  end
-
-  defp normalize_index_name({name, _, ctx}) when is_atom(name) and is_atom(ctx),
-    do: Atom.to_string(name)
-
-  defp normalize_index_name(atom) when is_atom(atom), do: Atom.to_string(atom)
-  defp normalize_index_name(other), do: other
-
   # ============================================================================
-  # 3. Datalog Query Macro (`datalog/1`, `query/2`, `query/3`, `query!/2`, `query!/3`)
+  # 3. Declarative Datalog Query DSL (`datalog/1`, `query/2,3`, `query!/2,3`)
   # ============================================================================
 
   @doc """
-  Compiles an Ecto/Datomic-style Datalog query block into a canonical `xitdb` Datalog string.
-
-  ## Examples
-
-      min_age = 21
-
-      q =
-        datalog do
-          find {e, name, age}
-          from users
-          where [
-            e.username == name,
-            e.age == age,
-            age >= ^min_age,
-            not(e.banned == true)
-          ]
-        end
+  Compiles an Ecto/Datomic-style Datalog query block into a `xitdb` Datalog string
+  at compile time (or minimal `<>` binary concatenation when `^pinned` runtime values
+  are interpolated).
   """
   defmacro datalog(do: block) do
     DatalogCompiler.compile(block, [], __CALLER__)
   end
 
   @doc """
-  Compiles and executes a Datalog query block against `target` (`%Xitdb{}` or `%Xitdb.Cursor{}`).
+  Compiles and executes a declarative Datalog query against `db` or a `%Xitdb.Cursor{}`.
   """
   defmacro query(target, do: block) do
-    query_str_ast = DatalogCompiler.compile(block, [], __CALLER__)
+    q_ast = DatalogCompiler.compile(block, [], __CALLER__)
 
     quote do
-      Xitdb.query(unquote(target), unquote(query_str_ast), [])
+      Xitdb.query(unquote(target), unquote(q_ast))
     end
   end
 
   defmacro query(target, query_str) do
     quote do
       Xitdb.query(unquote(target), unquote(query_str), [])
     end
   end
 
   defmacro query(target, opts, do: block) do
     {from_opt, runtime_opts} =
       if Keyword.keyword?(opts), do: Keyword.pop(opts, :from), else: {nil, opts}
 
-    query_str_ast = DatalogCompiler.compile(block, [from: from_opt], __CALLER__)
+    q_ast = DatalogCompiler.compile(block, [from: from_opt], __CALLER__)
 
     quote do
-      Xitdb.query(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
+      Xitdb.query(unquote(target), unquote(q_ast), unquote(runtime_opts))
     end
   end
 
   defmacro query(target, query_str, opts) do
     quote do
       Xitdb.query(unquote(target), unquote(query_str), unquote(opts))
     end
   end
 
-  @doc """
-  Same as `query/2` and `query/3`, but raises `Xitdb.Error` on failure.
-  """
+  @doc "Same as `query/2` and `query/3`, but unwraps `{:ok, result}` or raises `Xitdb.Error`."
   defmacro query!(target, do: block) do
-    query_str_ast = DatalogCompiler.compile(block, [], __CALLER__)
+    q_ast = DatalogCompiler.compile(block, [], __CALLER__)
 
     quote do
-      Xitdb.query!(unquote(target), unquote(query_str_ast), [])
-    end
-  end
-
-  defmacro query!(target, query_str) do
-    quote do
-      Xitdb.query!(unquote(target), unquote(query_str), [])
+      Xitdb.query!(unquote(target), unquote(q_ast))
     end
   end
 
+  defmacro query!(target, query_str) do
+    quote do
+      Xitdb.query!(unquote(target), unquote(query_str), [])
+    end
+  end
+
   defmacro query!(target, opts, do: block) do
-    {from_opt, runtime_opts} =
-      if Keyword.keyword?(opts), do: Keyword.pop(opts, :from), else: {nil, opts}
-
-    query_str_ast = DatalogCompiler.compile(block, [from: from_opt], __CALLER__)
+    {from_opt, runtime_opts} =
+      if Keyword.keyword?(opts), do: Keyword.pop(opts, :from), else: {nil, opts}
+    q_ast = DatalogCompiler.compile(block, [from: from_opt], __CALLER__)
 
     quote do
-      Xitdb.query!(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
-    end
-  end
-
   defmacro query!(target, query_str, opts) do
     quote do
       Xitdb.query!(unquote(target), unquote(query_str), unquote(opts))
     end
   end
-
-  # ============================================================================
-  # Internal Runtime Helpers for `tx` and `datalog`
-  # ============================================================================
-
-  @doc false
-  def __init_tx_state__(db, opts, track_staged? \\ false) do
-    tx_ref = make_ref()
-
-    state = %{
-      db: db,
-      opts: opts,
-      index_ops: [],
-      ops: [],
-      staged: if(track_staged?, do: %{}, else: nil)
-    }
-
-    Process.put(tx_ref, state)
-    tx_ref
-  end
-
-  @doc false
-  def __cleanup_tx_state__(tx_ref) do
-    Process.delete(tx_ref)
-    :ok
-  end
-
-  @doc false
-  def __commit_tx_state__(tx_ref) do
-    %{db: db, opts: opts, index_ops: index_ops, ops: ops} = Process.get(tx_ref)
-    all_ops = :lists.reverse(index_ops) ++ :lists.reverse(ops)
-    Xitdb.transact_ops(db, all_ops, opts)
-  end
-
-  @doc false
-  def __tx_put__(tx_ref, selector, value) when is_binary(selector) do
-    state = Process.get(tx_ref)
-
-    if is_nil(value) do
-      __tx_rm__(tx_ref, selector)
-      nil
-    else
-      if not is_map(value) and not is_list(value) do
-        op = {:put, selector, value}
-
-        staged =
-          case state.staged do
-            nil -> nil
-            staged_map -> Map.put(staged_map, selector, {:val, value})
-          end
-
-        Process.put(tx_ref, %{state | ops: [op | state.ops], staged: staged})
-        value
-      else
-        compiled_ops = TxCompiler.compile_node(selector, value, true)
-
-        staged =
-          case state.staged do
-            nil ->
-              nil
-
-            staged_map ->
-              Enum.reduce(compiled_ops, Map.put(staged_map, selector, {:val, value}), fn
-                {:put, path, v}, acc -> Map.put(acc, path, {:val, v})
-                {:rm, path}, acc -> Map.put(acc, path, :deleted)
-                _, acc -> acc
-              end)
-          end
-
-        new_state = %{
-          state
-          | ops: :lists.reverse(compiled_ops) ++ state.ops,
-            staged: staged
-        }
-
-        Process.put(tx_ref, new_state)
-        value
-      end
-    end
-  end
-
-  @doc false
-  def __tx_put_set_member__(tx_ref, selector) when is_binary(selector) do
-    state = Process.get(tx_ref)
-    op = {:put, selector, ""}
-
-    staged =
-      case state.staged do
-        nil -> nil
-        staged_map -> Map.put(staged_map, selector, {:val, true})
-      end
-
-    new_state = %{
-      state
-      | ops: [op | state.ops],
-        staged: staged
-    }
-
-    Process.put(tx_ref, new_state)
-    true
-  end
-
-  @doc false
-  def __tx_update__(tx_ref, selector, fun) when is_binary(selector) and is_function(fun, 1) do
-    state = Process.get(tx_ref)
-    current = read_tx_current_value(state, selector)
-    new_val = fun.(current)
-    __tx_put__(tx_ref, selector, new_val)
-  end
-
-  @doc false
-  def __tx_update__(tx_ref, selector, default, fun)
-      when is_binary(selector) and is_function(fun, 1) do
-    state = Process.get(tx_ref)
-    current = read_tx_current_value(state, selector)
-    resolved = if is_nil(current), do: default, else: current
-    new_val = fun.(resolved)
-    __tx_put__(tx_ref, selector, new_val)
-  end
-
-  @doc false
-  def __tx_rm__(tx_ref, selector) when is_binary(selector) do
-    state = Process.get(tx_ref)
-
-    staged =
-      case state.staged do
-        nil ->
-          nil
-
-        staged_map when map_size(staged_map) == 0 ->
-          %{selector => :deleted}
-
-        staged_map ->
-          sel_len = byte_size(selector)
-
-          staged_map
-          |> Map.new(fn {k, v} ->
-            if k == selector or deleted_child_path?(k, selector, sel_len) do
-              {k, :deleted}
-            else
-              {k, v}
-            end
-          end)
-          |> Map.put(selector, :deleted)
-      end
-
-    new_state = %{
-      state
-      | ops: [{:rm, selector} | state.ops],
-        staged: staged
-    }
-
-    Process.put(tx_ref, new_state)
-    :ok
-  end
-
-  defp deleted_child_path?(k, selector, sel_len) when byte_size(k) > sel_len do
-    match?(
-      <<^selector::binary-size(^sel_len), sep, _rest::binary>>
-      when sep in [?., ?[, ?#, ?$, ?%, ?^],
-      k
-    )
-  end
-
-  defp deleted_child_path?(_k, _selector, _sel_len), do: false
-
-  @doc false
-  def __tx_append__(tx_ref, selector, value) when is_binary(selector) do
-    state = Process.get(tx_ref)
-    Process.put(tx_ref, %{state | ops: [{:append, selector, value} | state.ops]})
-    value
-  end
-
-  @doc false
-  def __tx_insert__(tx_ref, selector, index, value)
-      when is_binary(selector) and is_integer(index) do
-    state = Process.get(tx_ref)
-    Process.put(tx_ref, %{state | ops: [{:insert, selector, index, value} | state.ops]})
-    value
-  end
-
-  @doc false
-  def __tx_slice__(tx_ref, selector, first.._last//1 = range) when is_binary(selector) do
-    size = Range.size(range)
-    __tx_slice__(tx_ref, selector, first, size)
-  end
-
-  @doc false
-  def __tx_slice__(tx_ref, selector, offset, size)
-      when is_binary(selector) and is_integer(offset) and is_integer(size) do
-    state = Process.get(tx_ref)
-    Process.put(tx_ref, %{state | ops: [{:slice, selector, offset, size} | state.ops]})
-    :ok
-  end
-
-  @doc false
-  def __tx_fork__(tx_ref, from_selector, to_selector)
-      when is_binary(from_selector) and is_binary(to_selector) do
-    state = Process.get(tx_ref)
-
-    new_state = %{
-      state
-      | ops: [{:fork, from_selector, to_selector} | state.ops]
-    }
-
-    Process.put(tx_ref, new_state)
-    :ok
-  end
-
-  @doc false
-  def __tx_index_on__(tx_ref, src_map, field_key, idx_map) do
-    state = Process.get(tx_ref)
-    op = {:index_on, to_string(src_map), to_string(field_key), to_string(idx_map)}
-    Process.put(tx_ref, %{state | index_ops: [op | state.index_ops]})
-    :ok
-  end
-
-  @doc false
-  def __tx_init_col__(tx_ref, selector, kind, reset?) when is_binary(selector) do
-    state = Process.get(tx_ref)
-    op_tag = if reset?, do: :reset_col, else: :init_col
-    Process.put(tx_ref, %{state | ops: [{op_tag, selector, to_string(kind)} | state.ops]})
-    :ok
-  end
-
-  @doc false
-  def __tx_meta__(tx_ref, key, val) do
-    state = Process.get(tx_ref)
-    op = {:meta, to_string(key), val}
-    Process.put(tx_ref, %{state | ops: [op | state.ops]})
-    val
-  end
-
-  @doc false
-  def __tx_instant__(tx_ref, epoch_ms) when is_integer(epoch_ms) do
-    state = Process.get(tx_ref)
-    op = {:instant, epoch_ms}
-    Process.put(tx_ref, %{state | ops: [op | state.ops]})
-    epoch_ms
-  end
-
-  @doc false
-  def __tx_savepoint__(tx_ref) do
-    state = Process.get(tx_ref)
-    op = {:savepoint, ""}
-    Process.put(tx_ref, %{state | ops: [op | state.ops]})
-    :ok
-  end
-
-  defp read_tx_current_value(%{staged: staged, db: db, opts: opts}, selector) do
-    case Map.get(staged, selector) do
-      {:val, val} ->
-        val
-
-      :deleted ->
-        nil
-
-      nil ->
-        if Xitdb.moment_count(db) == 0 do
-          nil
-        else
-          base_moment = Keyword.get(opts, :base_moment, -1)
-
-          case NIF.nif_select(db.db_ref, base_moment, selector) do
-            {:ok, raw} ->
-              case Cursor.unwrap_nif_value(db.db_ref, raw, base_moment, []) do
-                %Cursor{} = cur -> Xitdb.materialize(cur)
-                scalar -> scalar
-              end
-
-            {:error, _} ->
-              nil
-          end
-        end
+      Xitdb.query!(unquote(target), unquote(q_ast), unquote(runtime_opts))
     end
   end
 end
diff --git a/lib/xitdb/tx_compiler.ex b/lib/xitdb/tx_compiler.ex
--- a/lib/xitdb/tx_compiler.ex
+++ b/lib/xitdb/tx_compiler.ex
@@ -3,15 +3,6 @@ defmodule Xitdb.TxCompiler do
 
   alias Xitdb.{Collection, Selector}
 
-  # Temporary delegates until Xitdb.DSL sub-modules are extracted in Steps 2-4
-  defdelegate format_step(kind, key), to: Selector
+  # Retained for Xitdb.Ash.Indexer.Storage and Xitdb.Ash.Mutator.Sequences
+  defdelegate format_step(kind, key), to: Selector
 -  defdelegate format_typed_step(kind, val), to: Selector
 -  defdelegate format_bracket_step(val), to: Selector
 -  defdelegate format_root_or_step(val), to: Selector
 -  defdelegate format_path_steps(steps), to: Selector
-  defdelegate format_key(key), to: Selector
+  defdelegate format_key(key), to: Selector
 -  defdelegate encode_quoted(str), to: Selector
-
   @doc """
   Compiles a nested Elixir map or `Xitdb.Collection` into a flat list of
   coarse-grained NIF transaction tuples (`{:put, path, val}`, `{:init_col, path, kind}`, etc.).
````

---

## 3. Resulting Module Layout

* **`lib/xitdb/selector.ex`:** Canonical sigil guards, special-character key escaping, `nil`/boolean key guards, and step encoders.
* **`lib/xitdb/tx_compiler.ex`:** Nested Elixir map/`%Collection{}` to NIF op-list compilation.
* **`lib/xitdb/dsl.ex`:** Public macro entry points (`path`, `pull_pattern`, `tx`, `tx_for`, `datalog`, `query`) and `__using__/1`.
* **`lib/xitdb/dsl/path_compiler.ex`:** `path/1` AST segment parser and static binary folder.
* **`lib/xitdb/dsl/datalog_compiler.ex`:** `datalog/1` and `query/2,3` AST compiler and pin encoders.
* **`lib/xitdb/dsl/tx_rewriter.ex`:** `tx` and `tx_for` AST rewriter (zero Ash/Spark dependencies).
* **`lib/xitdb/dsl/tx_runtime.ex`:** Process-dictionary staging state machine for `tx` blocks with exact ancestor/descendant/collection/list/fork read-your-own-writes.

---

## 4. Verification Tests for Step 4

Run `mix do compile --warnings-as-errors + test` (and optionally `mix xref graph --source lib/xitdb/dsl/tx_rewriter.ex` to confirm zero `Ash`/`Spark` edges):

```elixir
defmodule Xitdb.DSL.TxRewriterAndRuntimeTest do
  use ExUnit.Case, async: true

  defmodule PlainCatalogSchema do
    def __xitdb_collection__, do: :items
    def __xitdb_indexes__, do: [sku: "sku->item_id"]
  end

  test "Xitdb.Ash.Tx.tx_for! works standalone with module-attribute schema lists" do
    defmodule StandaloneCaller do
      require Xitdb.Ash.Tx
      @schemas [PlainCatalogSchema]

      def seed(db) do
        Xitdb.Ash.Tx.tx_for! db, @schemas do
          put items["i1"].sku, "KB-01"
        end
      end
    end

    db = Xitdb.open!(backend: :memory) |> StandaloneCaller.seed()
    assert db["sku->item_id"]["KB-01"] == "i1"
  end

  test "read-your-own-writes stays consistent across ancestors, descendants, %Collection{}, lists, and fork" do
    use Xitdb.DSL

    db = Xitdb.open!(backend: :memory)

    db =
      tx! db do
        put users["alice"], %{"name" => "Alice", "role" => "viewer"}
      end

    db =
      tx! db do
        # 1a. Child put on committed ancestor -> update ancestor preserves sibling keys + staged child
        put users["alice"].role, "admin"
        update users["alice"], fn m -> Map.put(m, "tier", "gold") end

        # 1b. Child put on uncommitted parent -> update parent auto-vivifies and preserves child
        put users["bob"].role, "editor"
        update users["bob"], fn m -> Map.put(m, "name", "Bob") end

        # 1c. Overwriting a parent map evicts stale staged child values
        put users["carol"], %{"login_count" => 10, "role" => "member"}
        put users["carol"], %{"role" => "admin"}
        update users["carol"].login_count, 0, &(&1 + 1)

        # 2. %Xitdb.Collection{} wrappers unwrap to native maps/lists/MapSets on update
        put org.counted(:depts), Xitdb.counted_map(%{"eng" => %{"headcount" => 5}})

        update org.counted(:depts), fn m ->
          assert is_map(m) and not is_struct(m)
          put_in(m, ["eng", "headcount"], m["eng"]["headcount"] + 2)
        end

        # 3. append, insert, and slice update staged list state before update
        put queue, Xitdb.linked_list(["b", "c"])
        insert queue[[0]], "a"
        append queue, "d"
        slice queue, 1..2

        update queue, fn list ->
          assert list == ["b", "c"]
          list ++ ["done"]
        end

        # 4. fork snapshots staged source state and isolates subsequent edits
        fork users["alice"], backups["alice"]
        put users["alice"].role, "superadmin"

        update backups["alice"].role, fn role ->
          assert role == "admin"
          role <> "-snapshot"
        end
      end

    assert Xitdb.materialize(db["users"]["alice"]) == %{
             "name" => "Alice",
             "role" => "superadmin",
             "tier" => "gold"
           }

    assert Xitdb.materialize(db["users"]["bob"]) == %{"name" => "Bob", "role" => "editor"}
    assert Xitdb.materialize(db["users"]["carol"]) == %{"login_count" => 1, "role" => "admin"}
    assert db["org"]["depts"]["eng"]["headcount"] == 7
    assert Enum.to_list(db["queue"]) == ["b", "c", "done"]

    assert Xitdb.materialize(db["backups"]["alice"]) == %{
             "name" => "Alice",
             "role" => "admin-snapshot",
             "tier" => "gold"
           }
  end
end
```
