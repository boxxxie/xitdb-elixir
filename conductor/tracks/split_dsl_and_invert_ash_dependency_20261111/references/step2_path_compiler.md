# Reference: Step 2 — Extract `Xitdb.DSL.PathCompiler` (`lib/xitdb/dsl/path_compiler.ex`)

> [!IMPORTANT]
> **Step Metadata:**
> - **Track:** [`split_dsl_and_invert_ash_dependency_20261111`](../index.md)
> - **Wave:** Wave 4 (after Step 1 [`step1_selector_and_tx_compiler.md`](./step1_selector_and_tx_compiler.md))
> - **Target Modules:** `lib/xitdb/dsl/path_compiler.ex`, [`lib/xitdb/dsl.ex`](../../../../lib/xitdb/dsl.ex)
> - **Test Suite:** `test/xitdb/dsl/path_compiler_test.exs`

---

## 1. Architectural Motivation & Summary

Step 2 moves all `path/1` AST parsing, typed collection modifier handling, and static binary segment folding out of `lib/xitdb/dsl.ex` into a dedicated `Xitdb.DSL.PathCompiler` module:

* **Isolated path AST compiler (`lib/xitdb/dsl/path_compiler.ex`):** Extracts `extract_segments/1`, `extract_list_step_segment/1`, `extract_bracket_segment/1`, `typed_modifier_segment/2`, `moment_segment/1`, `fold_static_segments/1`, and `segments_to_quoted/1` from `lib/xitdb/dsl.ex` behind `PathCompiler.compile/1`.

* **Shared AST segment helpers for Datalog:** Exposes `PathCompiler.typed_modifier_segment/2` and `PathCompiler.fold_and_quote/1` (`@doc false`) so `DatalogCompiler` reuses the exact same typed step and binary-folding pipeline instead of duplicating it.

* **Compile-time folding & pin support (`(^base)` and `at_moment(^m, ...)`):** Folds unary negative integer AST nodes (`{:-, _, [n]}`) in `roles[-1]`, `todos[[-1]]`, and `at_moment(-1, ...)` into static binary literals at compile time, unwraps pinned moment variables (`{:^, _, [inner]}`) in `moment_segment/1`, and splices parenthesized leading pinned prefixes (`path((^base).sorted(:directory)[emp_id])`—parenthesized because Elixir parses `.` and `[]` tighter than unary `^`).

* **Guard & `Selector` cleanup in `lib/xitdb/dsl.ex`:** Removes `@typed_modifiers` from `lib/xitdb/dsl.ex` in favor of `Xitdb.Selector` guards (`is_typed_modifier/1`, `is_set_modifier/1`, `is_map_modifier/1`) and routes `Selector` calls directly.

---

## 2. Step 2 Code Changes (`diff`)

````diff
diff --git a/lib/xitdb/dsl/path_compiler.ex b/lib/xitdb/dsl/path_compiler.ex
new file mode 100644
--- /dev/null
+++ b/lib/xitdb/dsl/path_compiler.ex
@@ -0,0 +1,204 @@
+defmodule Xitdb.DSL.PathCompiler do
+  @moduledoc false
+
+  import Xitdb.Selector, only: [is_map_modifier: 1, is_typed_modifier: 1]
+  alias Xitdb.Selector
+
+  @type segment :: {:static, String.t()} | {:dynamic, Macro.t()}
+
+  @doc """
+  Compiles a path DSL AST expression into a folded binary literal (when static)
+  or minimal `<>` binary concatenation AST (when dynamic).
+  """
+  @spec compile(Macro.t()) :: Macro.t()
+  def compile(ast) do
+    ast
+    |> extract_segments()
+    |> fold_and_quote()
+  end
+
+  @doc false
+  @spec fold_and_quote([segment()]) :: Macro.t()
+  def fold_and_quote(segments) when is_list(segments) do
+    segments
+    |> fold_static_segments()
+    |> segments_to_quoted()
+  end
+
+  @doc false
+  @spec typed_modifier_segment(atom(), Macro.t()) :: segment()
+  def typed_modifier_segment(mod_fn, {:^, _, [inner]}) do
+    typed_modifier_segment(mod_fn, inner)
+  end
+
+  def typed_modifier_segment(mod_fn, idx)
+      when mod_fn in [:linked, :linked_list, :linked_array_list] and is_integer(idx) do
+    {:static, Selector.format_step(:linked_array_list, idx)}
+  end
+
+  def typed_modifier_segment(mod_fn, {:-, _, [idx]})
+      when mod_fn in [:linked, :linked_list, :linked_array_list] and is_integer(idx) do
+    {:static, Selector.format_step(:linked_array_list, -idx)}
+  end
+
+  def typed_modifier_segment(mod_fn, idx)
+      when mod_fn in [:array, :array_list] and is_integer(idx) do
+    {:static, Selector.format_step(:array_list, idx)}
+  end
+
+  def typed_modifier_segment(mod_fn, {:-, _, [idx]})
+      when mod_fn in [:array, :array_list] and is_integer(idx) do
+    {:static, Selector.format_step(:array_list, -idx)}
+  end
+
+  def typed_modifier_segment(mod_fn, literal)
+      when is_binary(literal) or
+             (is_atom(literal) and not is_nil(literal) and not is_boolean(literal)) do
+    {:static, Selector.format_typed_step(mod_fn, literal)}
+  end
+
+  def typed_modifier_segment(mod_fn, dynamic_ast) do
+    {:dynamic, quote(do: Xitdb.Selector.format_typed_step(unquote(mod_fn), unquote(dynamic_ast)))}
+  end
+
+  defp extract_segments(str) when is_binary(str) do
+    [{:static, str}]
+  end
+
+  defp extract_segments(atom)
+       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
+    [{:static, Selector.format_step(:hash_map, atom)}]
+  end
+
+  defp extract_segments({:sigil_x, _, _} = sigil_ast) do
+    [{:dynamic, sigil_ast}]
+  end
+
+  defp extract_segments(list) when is_list(list) do
+    Enum.flat_map(list, &extract_list_step_segment/1)
+  end
+
+  defp extract_segments({:root, _, ctx}) when is_atom(ctx), do: []
+  defp extract_segments({:_, _, ctx}) when is_atom(ctx), do: []
+
+  defp extract_segments({:^, _, [pinned_expr]}) do
+    [{:dynamic, quote(do: Xitdb.Selector.format_root_or_step(unquote(pinned_expr)))}]
+  end
+
+  defp extract_segments({:at_moment, _, [moment_ast, inner_ast]}) do
+    [moment_segment(moment_ast) | extract_segments(inner_ast)]
+  end
+
+  defp extract_segments({mod_fn, _, [arg]}) when is_typed_modifier(mod_fn) do
+    [typed_modifier_segment(mod_fn, arg)]
+  end
+
+  defp extract_segments({{:., _, [left, mod_fn]}, _, [arg]}) when is_typed_modifier(mod_fn) do
+    extract_segments(left) ++ [typed_modifier_segment(mod_fn, arg)]
+  end
+
+  defp extract_segments({{:., _, [left, field]}, _, []}) when is_atom(field) do
+    extract_segments(left) ++ [{:static, Selector.format_step(:hash_map, field)}]
+  end
+
+  defp extract_segments(
+         {{:., _, [Access, :get]}, _, [{{:., _, [parent, mod_fn]}, _, [container_key]}, right]}
+       )
+       when is_map_modifier(mod_fn) do
+    extract_segments(parent) ++
+      [typed_modifier_segment(:hash_map, container_key), typed_modifier_segment(mod_fn, right)]
+  end
+
+  defp extract_segments({{:., _, [Access, :get]}, _, [{mod_fn, _, [container_key]}, right]})
+       when is_map_modifier(mod_fn) do
+    [typed_modifier_segment(:hash_map, container_key), typed_modifier_segment(mod_fn, right)]
+  end
+
+  defp extract_segments({{:., _, [Access, :get]}, _, [left, right]}) do
+    extract_segments(left) ++ [extract_bracket_segment(right)]
+  end
+
+  defp extract_segments({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
+    [{:static, Selector.format_step(:hash_map, name)}]
+  end
+
+  defp extract_segments(other) do
+    [{:dynamic, quote(do: Xitdb.Selector.format_root_or_step(unquote(other)))}]
+  end
+
+  defp extract_list_step_segment([idx_ast]) do
+    [typed_modifier_segment(:linked, idx_ast)]
+  end
+
+  defp extract_list_step_segment({kind, val_ast}) when is_atom(kind) do
+    [typed_modifier_segment(kind, val_ast)]
+  end
+
+  defp extract_list_step_segment(step_ast) do
+    [extract_bracket_segment(step_ast)]
+  end
+
+  defp extract_bracket_segment([idx_ast]) do
+    typed_modifier_segment(:linked, idx_ast)
+  end
+
+  defp extract_bracket_segment({mod_fn, _, [arg]}) when is_typed_modifier(mod_fn) do
+    typed_modifier_segment(mod_fn, arg)
+  end
+
+  defp extract_bracket_segment({:^, _, [inner]}) do
+    extract_bracket_segment(inner)
+  end
+
+  defp extract_bracket_segment(idx) when is_integer(idx) do
+    {:static, Selector.format_step(:array_list, idx)}
+  end
+
+  defp extract_bracket_segment({:-, _, [idx]}) when is_integer(idx) do
+    {:static, Selector.format_step(:array_list, -idx)}
+  end
+
+  defp extract_bracket_segment(key)
+       when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)) do
+    {:static, Selector.format_step(:hash_map, key)}
+  end
+
+  defp extract_bracket_segment(dynamic_ast) do
+    {:dynamic, quote(do: Xitdb.Selector.format_bracket_step(unquote(dynamic_ast)))}
+  end
+
+  defp moment_segment({:^, _, [inner]}), do: moment_segment(inner)
+  defp moment_segment(m) when is_integer(m), do: {:static, "@#{m}"}
+  defp moment_segment({:-, _, [m]}) when is_integer(m), do: {:static, "@-#{m}"}
+
+  defp moment_segment(m_ast) do
+    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(m_ast)))}
+  end
+
+  defp fold_static_segments(segments) do
+    segments
+    |> Enum.reduce([], fn
+      {:static, s2}, [{:static, s1} | rest] -> [{:static, s1 <> s2} | rest]
+      seg, acc -> [seg | acc]
+    end)
+    |> :lists.reverse()
+  end
+
+  defp segments_to_quoted([]), do: ""
+  defp segments_to_quoted([{:static, s}]), do: s
+  defp segments_to_quoted([{:dynamic, expr}]), do: expr
+
+  defp segments_to_quoted(segments) do
+    exprs =
+      Enum.map(segments, fn
+        {:static, s} -> s
+        {:dynamic, expr} -> expr
+      end)
+
+    Enum.reduce(tl(exprs), hd(exprs), fn seg, acc ->
+      quote do
+        unquote(acc) <> unquote(seg)
+      end
+    end)
+  end
+end
diff --git a/lib/xitdb/dsl.ex b/lib/xitdb/dsl.ex
--- a/lib/xitdb/dsl.ex
+++ b/lib/xitdb/dsl.ex
@@ -37,24 +37,9 @@ defmodule Xitdb.DSL do
         end
   """
 
-  alias Xitdb.{Cursor, NIF, Pull, TxCompiler}
-
-  @typed_modifiers [
-    :counted,
-    :counted_map,
-    :sorted,
-    :sorted_map,
-    :linked,
-    :linked_list,
-    :array,
-    :array_list,
-    :set_member,
-    :hash_set,
-    :counted_set_member,
-    :counted_set,
-    :sorted_set_member,
-    :sorted_set
-  ]
+  import Xitdb.Selector, only: [is_map_modifier: 1, is_set_modifier: 1, is_typed_modifier: 1]
+  alias Xitdb.DSL.PathCompiler
+  alias Xitdb.{Cursor, NIF, Pull, Selector, TxCompiler}
 
   @datalog_aggregations [:count, :sum, :min, :max]
   @datalog_predicates [:starts_with, :contains]
@@ -89,7 +74,7 @@ defmodule Xitdb.DSL do
   - `at_moment(moment, path)` — prefixes `@<moment>`
   """
   defmacro path(expr) do
-    compile_path_ast(expr)
+    PathCompiler.compile(expr)
   end
 
   @doc """
@@ -358,7 +343,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:put, _meta, [path_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
 
     quote do
       Xitdb.DSL.__tx_put_set_member__(unquote(tx_ref_var), unquote(selector_ast))
@@ -366,7 +351,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:put, _meta, [path_ast, val_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
     rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
 
     quote do
@@ -375,7 +360,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:update, _meta, [path_ast, fun_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
     rewritten_fun = rewrite_tx_ast(fun_ast, tx_ref_var)
 
     quote do
@@ -384,7 +369,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:update, _meta, [path_ast, default_ast, fun_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
     rewritten_default = rewrite_tx_ast(default_ast, tx_ref_var)
     rewritten_fun = rewrite_tx_ast(fun_ast, tx_ref_var)
 
@@ -399,7 +384,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:rm, _meta, [path_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
 
     quote do
       Xitdb.DSL.__tx_rm__(unquote(tx_ref_var), unquote(selector_ast))
@@ -407,7 +392,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:append, _meta, [path_ast, val_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
     rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
 
     quote do
@@ -417,7 +402,7 @@ defmodule Xitdb.DSL do
 
   defp rewrite_tx_ast({:insert, _meta, [target_ast, val_ast]}, tx_ref_var) do
     {list_path_ast, idx_ast} = split_insert_target!(target_ast)
-    selector_ast = compile_path_ast(list_path_ast)
+    selector_ast = PathCompiler.compile(list_path_ast)
     rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
 
     quote do
@@ -431,7 +416,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:insert, _meta, [list_path_ast, idx_ast, val_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(list_path_ast)
+    selector_ast = PathCompiler.compile(list_path_ast)
     rewritten_val = rewrite_tx_ast(val_ast, tx_ref_var)
 
     quote do
@@ -445,7 +430,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:slice, _meta, [path_ast, range_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
 
     quote do
       Xitdb.DSL.__tx_slice__(unquote(tx_ref_var), unquote(selector_ast), unquote(range_ast))
@@ -453,7 +438,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:slice, _meta, [path_ast, offset_ast, size_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
 
     quote do
       Xitdb.DSL.__tx_slice__(
@@ -466,8 +451,8 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:fork, _meta, [from_path_ast, to_path_ast]}, tx_ref_var) do
-    from_selector = compile_path_ast(from_path_ast)
-    to_selector = compile_path_ast(to_path_ast)
+    from_selector = PathCompiler.compile(from_path_ast)
+    to_selector = PathCompiler.compile(to_path_ast)
 
     quote do
       Xitdb.DSL.__tx_fork__(unquote(tx_ref_var), unquote(from_selector), unquote(to_selector))
@@ -490,7 +475,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:init_col, _meta, [path_ast, kind_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
 
     quote do
       Xitdb.DSL.__tx_init_col__(
@@ -503,7 +488,7 @@ defmodule Xitdb.DSL do
   end
 
   defp rewrite_tx_ast({:reset_col, _meta, [path_ast, kind_ast]}, tx_ref_var) do
-    selector_ast = compile_path_ast(path_ast)
+    selector_ast = PathCompiler.compile(path_ast)
 
     quote do
       Xitdb.DSL.__tx_init_col__(
@@ -672,178 +657,6 @@ defmodule Xitdb.DSL do
     end
   end
 
-  # ============================================================================
-  # Path AST Compiler Implementation
-  # ============================================================================
-
-  defp compile_path_ast(ast) do
-    ast
-    |> extract_path_segments()
-    |> fold_static_segments()
-    |> segments_to_quoted()
-  end
-
-  defp extract_path_segments(str) when is_binary(str) do
-    [{:static, str}]
-  end
-
-  defp extract_path_segments(atom)
-       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
-    [{:static, TxCompiler.format_step(:hash_map, atom)}]
-  end
-
-  defp extract_path_segments({:sigil_x, _, _} = sigil_ast) do
-    [{:dynamic, sigil_ast}]
-  end
-
-  defp extract_path_segments(list) when is_list(list) do
-    Enum.flat_map(list, &extract_list_step_segment/1)
-  end
-
-  defp extract_path_segments({:root, _, ctx}) when is_atom(ctx), do: []
-  defp extract_path_segments({:_, _, ctx}) when is_atom(ctx), do: []
-
-  defp extract_path_segments({:^, _, [pinned_expr]}) do
-    [{:dynamic, quote(do: Xitdb.TxCompiler.format_root_or_step(unquote(pinned_expr)))}]
-  end
-
-  defp extract_path_segments({:at_moment, _, [moment_ast, inner_ast]}) do
-    [moment_segment(moment_ast) | extract_path_segments(inner_ast)]
-  end
-
-  defp extract_path_segments({mod_fn, _, [arg]}) when mod_fn in @typed_modifiers do
-    [typed_modifier_segment(mod_fn, arg)]
-  end
-
-  defp extract_path_segments({{:., _, [left, mod_fn]}, _, [arg]})
-       when mod_fn in @typed_modifiers do
-    extract_path_segments(left) ++ [typed_modifier_segment(mod_fn, arg)]
-  end
-
-  defp extract_path_segments({{:., _, [left, field]}, _, []}) when is_atom(field) do
-    extract_path_segments(left) ++ [{:static, TxCompiler.format_step(:hash_map, field)}]
-  end
-
-  defp extract_path_segments(
-         {{:., _, [Access, :get]}, _, [{{:., _, [parent, mod_fn]}, _, [container_key]}, right]}
-       )
-       when mod_fn in [:counted, :counted_map, :sorted, :sorted_map] do
-    extract_path_segments(parent) ++
-      [typed_modifier_segment(:hash_map, container_key), typed_modifier_segment(mod_fn, right)]
-  end
-
-  defp extract_path_segments({{:., _, [Access, :get]}, _, [{mod_fn, _, [container_key]}, right]})
-       when mod_fn in [:counted, :counted_map, :sorted, :sorted_map] do
-    [typed_modifier_segment(:hash_map, container_key), typed_modifier_segment(mod_fn, right)]
-  end
-
-  defp extract_path_segments({{:., _, [Access, :get]}, _, [left, right]}) do
-    extract_path_segments(left) ++ [extract_bracket_segment(right)]
-  end
-
-  defp extract_path_segments({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
-    [{:static, TxCompiler.format_step(:hash_map, name)}]
-  end
-
-  defp extract_path_segments(other) do
-    [{:dynamic, quote(do: Xitdb.TxCompiler.format_root_or_step(unquote(other)))}]
-  end
-
-  defp extract_list_step_segment([idx_ast]) do
-    [typed_modifier_segment(:linked, idx_ast)]
-  end
-
-  defp extract_list_step_segment({kind, val_ast}) when is_atom(kind) do
-    [typed_modifier_segment(kind, val_ast)]
-  end
-
-  defp extract_list_step_segment(step_ast) do
-    [extract_bracket_segment(step_ast)]
-  end
-
-  defp extract_bracket_segment([idx_ast]) do
-    typed_modifier_segment(:linked, idx_ast)
-  end
-
-  defp extract_bracket_segment({mod_fn, _, [arg]}) when mod_fn in @typed_modifiers do
-    typed_modifier_segment(mod_fn, arg)
-  end
-
-  defp extract_bracket_segment({:^, _, [inner]}) do
-    extract_bracket_segment(inner)
-  end
-
-  defp extract_bracket_segment(idx) when is_integer(idx) do
-    {:static, TxCompiler.format_step(:array_list, idx)}
-  end
-
-  defp extract_bracket_segment(key)
-       when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)) do
-    {:static, TxCompiler.format_step(:hash_map, key)}
-  end
-
-  defp extract_bracket_segment(dynamic_ast) do
-    {:dynamic, quote(do: Xitdb.TxCompiler.format_bracket_step(unquote(dynamic_ast)))}
-  end
-
-  defp typed_modifier_segment(mod_fn, {:^, _, [inner]}) do
-    typed_modifier_segment(mod_fn, inner)
-  end
-
-  defp typed_modifier_segment(mod_fn, idx)
-       when mod_fn in [:linked, :linked_list, :linked_array_list] and is_integer(idx) do
-    {:static, TxCompiler.format_step(:linked_array_list, idx)}
-  end
-
-  defp typed_modifier_segment(mod_fn, idx)
-       when mod_fn in [:array, :array_list] and is_integer(idx) do
-    {:static, TxCompiler.format_step(:array_list, idx)}
-  end
-
-  defp typed_modifier_segment(mod_fn, literal)
-       when is_binary(literal) or
-              (is_atom(literal) and not is_nil(literal) and not is_boolean(literal)) do
-    {:static, TxCompiler.format_typed_step(mod_fn, literal)}
-  end
-
-  defp typed_modifier_segment(mod_fn, dynamic_ast) do
-    {:dynamic,
-     quote(do: Xitdb.TxCompiler.format_typed_step(unquote(mod_fn), unquote(dynamic_ast)))}
-  end
-
-  defp moment_segment(m) when is_integer(m), do: {:static, "@#{m}"}
-
-  defp moment_segment(m_ast) do
-    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(m_ast)))}
-  end
-
-  defp fold_static_segments(segments) do
-    segments
-    |> Enum.reduce([], fn
-      {:static, s2}, [{:static, s1} | rest] -> [{:static, s1 <> s2} | rest]
-      seg, acc -> [seg | acc]
-    end)
-    |> :lists.reverse()
-  end
-
-  defp segments_to_quoted([]), do: ""
-  defp segments_to_quoted([{:static, s}]), do: s
-  defp segments_to_quoted([{:dynamic, expr}]), do: expr
-
-  defp segments_to_quoted(segments) do
-    exprs =
-      Enum.map(segments, fn
-        {:static, s} -> s
-        {:dynamic, expr} -> expr
-      end)
-
-    Enum.reduce(tl(exprs), hd(exprs), fn seg, acc ->
-      quote do
-        unquote(acc) <> unquote(seg)
-      end
-    end)
-  end
-
   # ============================================================================
   # Datalog AST Compiler Implementation
   # ============================================================================
@@ -906,9 +719,7 @@ defmodule Xitdb.DSL do
 
     header = "find " <> Enum.join(find_parts, ", ") <> "\nwhere\n  "
 
-    ([{:static, header}] ++ where_segments)
-    |> fold_static_segments()
-    |> segments_to_quoted()
+    PathCompiler.fold_and_quote([{:static, header} | where_segments])
   end
 
   defp extract_datalog_sections!(exprs, default_from) do
@@ -983,9 +794,9 @@ defmodule Xitdb.DSL do
   end
 
   defp build_collection_binding({mod_fn, _, [arg]}, alias_var)
-       when mod_fn in [:counted, :counted_map, :sorted, :sorted_map] do
+       when is_map_modifier(mod_fn) do
     [
-      typed_modifier_segment(mod_fn, arg),
+      PathCompiler.typed_modifier_segment(mod_fn, arg),
       {:static, "[#{format_logic_var(alias_var)}]"}
     ]
   end
@@ -997,7 +808,7 @@ defmodule Xitdb.DSL do
 
   defp build_collection_binding(col_name, alias_var)
        when is_atom(col_name) or is_binary(col_name) do
-    [{:static, TxCompiler.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
+    [{:static, Selector.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
   end
 
   defp compile_where_clause!({:not, _, [inner_clause]}, find_vars, binds) do
@@ -1086,27 +897,13 @@ defmodule Xitdb.DSL do
          find_vars,
          binds
        )
-       when set_fn in [
-              :set_member,
-              :hash_set,
-              :counted_set_member,
-              :counted_set,
-              :sorted_set_member,
-              :sorted_set
-            ] do
+       when is_set_modifier(set_fn) do
     compile_datalog_path_segments(left, find_vars, binds) ++
       compile_datalog_set_step(set_fn, member_arg)
   end
 
   defp compile_where_clause!({set_fn, _, [left, member_arg]}, find_vars, binds)
-       when set_fn in [
-              :set_member,
-              :hash_set,
-              :counted_set_member,
-              :counted_set,
-              :sorted_set_member,
-              :sorted_set
-            ] do
+       when is_set_modifier(set_fn) do
     compile_datalog_path_segments(left, find_vars, binds) ++
       compile_datalog_set_step(set_fn, member_arg)
   end
@@ -1122,7 +919,7 @@ defmodule Xitdb.DSL do
 
   defp datalog_path_expr?({:at_moment, _, [_, _]}), do: true
   defp datalog_path_expr?({{:., _, _}, _, _}), do: true
-  defp datalog_path_expr?({mod_fn, _, _}) when mod_fn in @typed_modifiers, do: true
+  defp datalog_path_expr?({mod_fn, _, _}) when is_typed_modifier(mod_fn), do: true
   defp datalog_path_expr?(_), do: false
 
   defp compile_datalog_path_segments({:root, _, ctx}, _find_vars, _binds) when is_atom(ctx),
@@ -1143,33 +940,26 @@ defmodule Xitdb.DSL do
   end
 
   defp compile_datalog_path_segments({mod_fn, _, [arg]}, _find_vars, _binds)
-       when mod_fn in @typed_modifiers do
-    [typed_modifier_segment(mod_fn, arg)]
+       when is_typed_modifier(mod_fn) do
+    [PathCompiler.typed_modifier_segment(mod_fn, arg)]
   end
 
   defp compile_datalog_path_segments({{:., _, [left, set_fn]}, _, [member_arg]}, find_vars, binds)
-       when set_fn in [
-              :set_member,
-              :hash_set,
-              :counted_set_member,
-              :counted_set,
-              :sorted_set_member,
-              :sorted_set
-            ] do
+       when is_set_modifier(set_fn) do
     compile_datalog_path_segments(left, find_vars, binds) ++
       compile_datalog_set_step(set_fn, member_arg)
   end
 
   defp compile_datalog_path_segments({{:., _, [left, mod_fn]}, _, [arg]}, find_vars, binds)
-       when mod_fn in @typed_modifiers do
+       when is_typed_modifier(mod_fn) do
     compile_datalog_path_segments(left, find_vars, binds) ++
-      [typed_modifier_segment(mod_fn, arg)]
+      [PathCompiler.typed_modifier_segment(mod_fn, arg)]
   end
 
   defp compile_datalog_path_segments({{:., _, [left, field]}, _, []}, find_vars, binds)
        when is_atom(field) do
     compile_datalog_path_segments(left, find_vars, binds) ++
-      [{:static, TxCompiler.format_step(:hash_map, field)}]
+      [{:static, Selector.format_step(:hash_map, field)}]
   end
 
   defp compile_datalog_path_segments(
@@ -1187,7 +977,7 @@ defmodule Xitdb.DSL do
           Map.fetch!(binds, root_name)
 
         true ->
-          [{:static, TxCompiler.format_step(:hash_map, root_name)}]
+          [{:static, Selector.format_step(:hash_map, root_name)}]
       end
 
     base_segs ++ [compile_datalog_bracket_step(right, find_vars)]
@@ -1214,7 +1004,7 @@ defmodule Xitdb.DSL do
         [{:static, "[#{format_logic_var(norm)}]"}]
 
       true ->
-        [{:static, TxCompiler.format_step(:hash_map, name)}]
+        [{:static, Selector.format_step(:hash_map, name)}]
     end
   end
 
@@ -1257,12 +1047,12 @@ defmodule Xitdb.DSL do
   end
 
   defp compile_datalog_bracket_step(str, _find_vars) when is_binary(str) do
-    {:static, "[" <> TxCompiler.encode_quoted(str) <> "]"}
+    {:static, "[" <> Selector.encode_quoted(str) <> "]"}
   end
 
   defp compile_datalog_bracket_step(atom, _find_vars)
        when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
-    {:static, "[" <> TxCompiler.encode_quoted(Atom.to_string(atom)) <> "]"}
+    {:static, "[" <> Selector.encode_quoted(Atom.to_string(atom)) <> "]"}
   end
 
   defp compile_datalog_set_step(set_fn, member_arg) do
@@ -1581,21 +1371,21 @@ defmodule Xitdb.DSL do
   end
 
   @doc false
-  def __format_datalog_literal__(val) when is_binary(val), do: TxCompiler.encode_quoted(val)
+  def __format_datalog_literal__(val) when is_binary(val), do: Selector.encode_quoted(val)
   def __format_datalog_literal__(val) when is_integer(val) or is_float(val), do: to_string(val)
   def __format_datalog_literal__(val) when is_boolean(val), do: Atom.to_string(val)
 
   def __format_datalog_literal__(val) when is_atom(val) and not is_nil(val),
-    do: TxCompiler.encode_quoted(Atom.to_string(val))
+    do: Selector.encode_quoted(Atom.to_string(val))
 
   @doc false
   def __format_datalog_bracket_pin__(idx) when is_integer(idx), do: "[#{idx}]"
   def __format_datalog_bracket_pin__([idx]) when is_integer(idx), do: "[[#{idx}]]"
 
   def __format_datalog_bracket_pin__(key) when is_binary(key),
-    do: "[" <> TxCompiler.encode_quoted(key) <> "]"
+    do: "[" <> Selector.encode_quoted(key) <> "]"
 
   def __format_datalog_bracket_pin__(key)
       when is_atom(key) and not is_nil(key) and not is_boolean(key),
-      do: "[" <> TxCompiler.encode_quoted(Atom.to_string(key)) <> "]"
+      do: "[" <> Selector.encode_quoted(Atom.to_string(key)) <> "]"
 end
````

---

## 3. Verification Tests for Step 2

```elixir
defmodule Xitdb.DSL.PathCompilerTest do
  use ExUnit.Case, async: true
  use Xitdb.DSL

  alias Xitdb.DSL.PathCompiler

  test "folds static paths, negative indices, and moments into single compile-time binaries" do
    ast =
      quote do
        at_moment(-1, org.counted(:departments)["eng"].todos[[-1]])
      end

    assert PathCompiler.compile(ast) == "@-1.org.departments#eng.todos[[-1]]"
  end

  test "splices parenthesized pinned prefixes, pinned moments, and dynamic runtime keys" do
    base = path(org.counted(:departments)["eng"])
    emp_id = "emp.101"
    idx = 2

    # Note: Elixir parses `.` and `[]` tighter than unary `^`, so wrap leading `^base` in `(...)`
    assert path((^base).sorted(:directory)[emp_id].todos[[idx]]) ==
             ~s(.org.departments#eng.directory$["emp.101"].todos[[2]])

    m = 3
    id = "42"
    assert path(at_moment(^m, users[id])) == "@3.users.42"
  end

  test "raises ArgumentError when a dynamic runtime bracket key is nil or boolean" do
    id = nil
    flag = false

    assert_raise ArgumentError, ~r/Invalid bracket path step nil/, fn ->
      path(users[id])
    end

    assert_raise ArgumentError, ~r/Invalid bracket path step false/, fn ->
      path(users[flag])
    end
  end
end
```
