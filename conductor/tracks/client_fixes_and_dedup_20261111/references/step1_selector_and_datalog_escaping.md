# Reference: Step 1 — Selector & Datalog Escaping + Bitstring Pinning

> [!IMPORTANT]
> **Step Metadata:**
> - **Track:** [`client_fixes_and_dedup_20261111`](../index.md) (`Track 5A [Wave 1]`)
> - **Target Modules:** [`lib/xitdb/tx_compiler.ex`](../../../../lib/xitdb/tx_compiler.ex), [`lib/xitdb/dsl.ex`](../../../../lib/xitdb/dsl.ex)
> - **Test Suite:** `test/xitdb/selector_escaping_test.exs`

---

## 1. Architectural Motivation & Summary

1. **Binary-Safe Quote Escaping (`TxCompiler.encode_quoted/1`):**
   Replaces naive `~s(["#{key}"])` in [`lib/xitdb/tx_compiler.ex`](../../../../lib/xitdb/tx_compiler.ex) and `inspect/1` in [`lib/xitdb/dsl.ex`](../../../../lib/xitdb/dsl.ex) with a tail-recursive `MatchContext` byte escaper.
   - Embedded `"`, `\`, `\n`, `\r`, and `\t` are escaped cleanly.
   - Strings containing `#{...}` are no longer mangled into Elixir interpolation escape sequences like `\#{...}`.

2. **Expanded `@special_chars`:**
   Adds `@`, `\`, and `\r` to `@special_chars` in [`lib/xitdb/tx_compiler.ex`](../../../../lib/xitdb/tx_compiler.ex) so keys containing moment prefixes (`@0`, `@latest`), email addresses (`user@example.com`), or backslashes are properly bracket-quoted.

3. **Datalog Bracket & Literal Parity (Consistent Pin Routing):**
   Updates `compile_datalog_bracket_step/2`, `__format_datalog_bracket_pin__/1`, and `__format_datalog_literal__/1` in [`lib/xitdb/dsl.ex`](../../../../lib/xitdb/dsl.ex) to use `TxCompiler.encode_quoted/1`.
   - Routes pinned linked-list indices (`todos[[^idx]]`, AST `[{:^, _, [pinned_expr]}]`) directly through `Xitdb.DSL.__format_datalog_bracket_pin__([unquote(pinned_expr)])` rather than bypassing the pin helper, ensuring `__format_datalog_bracket_pin__([idx]) when is_integer(idx)` is actively exercised with zero dead clauses.
   - Adds atom bracket step support and prevents `nil` from silently serializing as `"\"nil\""`.

4. **Elixir 1.20 Bitstring Pin & Set Child Eviction:**
   Pins `^sel_len` in `deleted_child_path?/3` in [`lib/xitdb/dsl.ex`](../../../../lib/xitdb/dsl.ex) (`<<^selector::binary-size(^sel_len), ...>>`) to comply with Elixir 1.20 match semantics.
   - Adds `?%` and `?^` delimiters so `rm` correctly invalidates staged set members under a deleted parent path.

---

## 2. Step 1 Code Changes (`diff`)

````diff
diff --git a/lib/xitdb/tx_compiler.ex b/lib/xitdb/tx_compiler.ex
--- a/lib/xitdb/tx_compiler.ex
+++ b/lib/xitdb/tx_compiler.ex
@@ -112,24 +112,49 @@ defmodule Xitdb.TxCompiler do
     "$",
     "%",
     "^",
+    "@",
     "\"",
     "'",
+    "\\",
     " ",
     "\t",
-    "\n"
+    "\n",
+    "\r"
   ]
 
+  @escapable_chars ["\\", "\"", "\n", "\r", "\t"]
+
   def format_key(key) when is_binary(key) do
     if key != <<>> and :binary.match(key, @special_chars) == :nomatch do
       key
     else
-      ~s(["#{key}"])
+      "[" <> encode_quoted(key) <> "]"
     end
   end
 
   def format_key(key) when is_atom(key), do: format_key(Atom.to_string(key))
   def format_key(key), do: format_key(to_string(key))
 
+  @doc """
+  Wraps `str` in double quotes, escaping backslashes, double quotes, and control
+  whitespace without Elixir `\\#{` interpolation artifacts.
+  """
+  def encode_quoted(str) when is_binary(str) do
+    if :binary.match(str, @escapable_chars) == :nomatch do
+      "\"" <> str <> "\""
+    else
+      IO.iodata_to_binary([?", escape_bytes(str, []), ?"])
+    end
+  end
+
+  defp escape_bytes(<<>>, acc), do: Enum.reverse(acc)
+  defp escape_bytes(<<?\\, rest::binary>>, acc), do: escape_bytes(rest, ["\\\\" | acc])
+  defp escape_bytes(<<?", rest::binary>>, acc), do: escape_bytes(rest, ["\\\"" | acc])
+  defp escape_bytes(<<?\n, rest::binary>>, acc), do: escape_bytes(rest, ["\\n" | acc])
+  defp escape_bytes(<<?\r, rest::binary>>, acc), do: escape_bytes(rest, ["\\r" | acc])
+  defp escape_bytes(<<?\t, rest::binary>>, acc), do: escape_bytes(rest, ["\\t" | acc])
+  defp escape_bytes(<<byte, rest::binary>>, acc), do: escape_bytes(rest, [byte | acc])
+
   def compile_node(prefix, node, reset?) do
     :lists.reverse(compile_node_acc(prefix, node, reset?, []))
   end
diff --git a/lib/xitdb/dsl.ex b/lib/xitdb/dsl.ex
--- a/lib/xitdb/dsl.ex
+++ b/lib/xitdb/dsl.ex
@@ -1206,6 +1206,10 @@ defmodule Xitdb.DSL do
     {:dynamic, quote(do: Xitdb.DSL.__format_datalog_bracket_pin__(unquote(pinned_expr)))}
   end
 
+  defp compile_datalog_bracket_step([{:^, _, [pinned_expr]}], _find_vars) do
+    {:dynamic, quote(do: Xitdb.DSL.__format_datalog_bracket_pin__([unquote(pinned_expr)]))}
+  end
+
   defp compile_datalog_bracket_step([{var_name, _, ctx}], _find_vars)
        when is_atom(var_name) and is_atom(ctx) do
     {:static, "[[#{format_logic_var(var_name)}]]"}
@@ -1225,7 +1229,12 @@ defmodule Xitdb.DSL do
   end
 
   defp compile_datalog_bracket_step(str, _find_vars) when is_binary(str) do
-    {:static, ~s(["#{str}"])}
+    {:static, "[" <> TxCompiler.encode_quoted(str) <> "]"}
+  end
+
+  defp compile_datalog_bracket_step(atom, _find_vars)
+       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
+    {:static, "[" <> TxCompiler.encode_quoted(Atom.to_string(atom)) <> "]"}
   end
 
   defp compile_datalog_set_step(set_fn, member_arg) do
@@ -1424,14 +1433,11 @@ defmodule Xitdb.DSL do
   end
 
   defp deleted_child_path?(k, selector, sel_len) when byte_size(k) > sel_len do
-    case k do
-      <<^selector::binary-size(sel_len), sep, _rest::binary>>
-      when sep in [?., ?[, ?#, ?$] ->
-        true
-
-      _ ->
-        false
-    end
+    match?(
+      <<^selector::binary-size(^sel_len), sep, _rest::binary>>
+      when sep in [?., ?[, ?#, ?$, ?%, ?^],
+      k
+    )
   end
 
   defp deleted_child_path?(_k, _selector, _sel_len), do: false
@@ -1548,12 +1554,21 @@ defmodule Xitdb.DSL do
   end
 
   @doc false
-  def __format_datalog_literal__(val) when is_binary(val), do: inspect(val)
+  def __format_datalog_literal__(val) when is_binary(val), do: TxCompiler.encode_quoted(val)
   def __format_datalog_literal__(val) when is_integer(val) or is_float(val), do: to_string(val)
-  def __format_datalog_literal__(val) when is_boolean(val), do: to_string(val)
-  def __format_datalog_literal__(val) when is_atom(val), do: inspect(Atom.to_string(val))
+  def __format_datalog_literal__(val) when is_boolean(val), do: Atom.to_string(val)
+
+  def __format_datalog_literal__(val) when is_atom(val) and not is_nil(val),
+    do: TxCompiler.encode_quoted(Atom.to_string(val))
 
   @doc false
   def __format_datalog_bracket_pin__(idx) when is_integer(idx), do: "[#{idx}]"
-  def __format_datalog_bracket_pin__(key), do: ~s(["#{key}"])
+  def __format_datalog_bracket_pin__([idx]) when is_integer(idx), do: "[[#{idx}]]"
+
+  def __format_datalog_bracket_pin__(key) when is_binary(key),
+    do: "[" <> TxCompiler.encode_quoted(key) <> "]"
+
+  def __format_datalog_bracket_pin__(key)
+      when is_atom(key) and not is_nil(key) and not is_boolean(key),
+      do: "[" <> TxCompiler.encode_quoted(Atom.to_string(key)) <> "]"
 end
````

---

## 3. Verification Suite

```elixir
defmodule Xitdb.SelectorEscapingTest do
  use ExUnit.Case, async: true
  use Xitdb.DSL

  test "path/1 escapes quotes, backslashes, @, newlines, and preserves \#{...}" do
    tricky_key = ~s(a"b\\c\n\#{raw}@0)
    assert path(users[tricky_key].role) == ~s(.users.["a\\"b\\\\c\\n\#{raw}@0"].role)
  end

  test "datalog/1 escapes pinned strings, atoms, and linked-list [[^idx]] pins without Elixir \\\#{ artifacts" do
    pinned_key = ~s(user"1)
    pinned_val = "hello \#{world}\n"
    pinned_idx = 2

    compiled =
      datalog do
        find {role}
        where [
          users[^pinned_key].note == ^pinned_val,
          users[:alice].todos[[^pinned_idx]] == "ship",
          users[:alice].role == role
        ]
      end

    assert compiled =~ ~s(.users["user\\"1"].note = "hello \#{world}\\n")
    assert compiled =~ ~s(.users["alice"].todos[[2]] = "ship")
    assert compiled =~ ~s(.users["alice"].role = ?role)
  end
end
```
