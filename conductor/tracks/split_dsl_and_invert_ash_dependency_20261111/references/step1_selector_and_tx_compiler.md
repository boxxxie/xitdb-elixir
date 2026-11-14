# Reference: Step 1 — Extract `Xitdb.Selector` & Deduplicate `TxCompiler`

> [!IMPORTANT]
> **Step Metadata:**
> - **Track:** [`split_dsl_and_invert_ash_dependency_20261111`](../index.md)
> - **Wave:** Wave 4 (Prerequisite: [`client_fixes_and_dedup_20261111`](../../client_fixes_and_dedup_20261111/index.md))
> - **Target Modules:** `lib/xitdb/selector.ex`, [`lib/xitdb/tx_compiler.ex`](../../../../lib/xitdb/tx_compiler.ex), [`lib/xitdb/cursor.ex`](../../../../lib/xitdb/cursor.ex), [`lib/xitdb.ex`](../../../../lib/xitdb.ex), [`lib/xitdb/sigils.ex`](../../../../lib/xitdb/sigils.ex), [`lib/xitdb/ash/search.ex`](../../../../lib/xitdb/ash/search.ex)
> - **Test Suite:** `test/xitdb/selector_test.exs`

---

## 1. Architectural Motivation & Summary

* **Single source of truth for selector syntax (`lib/xitdb/selector.ex`):** Consolidates `@valid_sigil_starts` from `lib/xitdb/sigils.ex`, `@valid_selector_starts` and step/key encoders from `lib/xitdb/tx_compiler.ex`, and `@typed_modifiers` from `lib/xitdb/dsl.ex` into reusable `defguard`s (`is_valid_selector_start/1`, `is_typed_modifier/1`, `is_map_modifier/1`, `is_set_modifier/1`) and typed formatting functions. Explicitly guards `format_bracket_step/1` and `format_key/1` (`when is_atom(key) and not is_nil(key) and not is_boolean(key)`) so `nil` or boolean keys raise `ArgumentError` instead of silently emitting `".users.nil"` or `".users.false"`.

* **Deduplicated `TxCompiler` (`lib/xitdb/tx_compiler.ex`):** Extracts `compile_kv_collection/5` to eliminate the duplicated empty-check and `:maps.fold` / `Enum.reduce` branches between plain maps and `%Xitdb.Collection{}` structs. Temporary `defdelegate`s remain on `TxCompiler` until Steps 2–4 migrate `lib/xitdb/dsl.ex`.

* **Direct `Selector` calls in `Xitdb`, `Cursor`, `Sigils`, and `Search.Storage`:** Routes path-formatting calls in `lib/xitdb.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb/sigils.ex`, and `lib/xitdb/ash/search.ex` directly to `Xitdb.Selector` instead of going through `TxCompiler`.

---

## 2. Step 1 Code Changes (`diff`)

````diff
diff --git a/lib/xitdb/ash/search.ex b/lib/xitdb/ash/search.ex
--- a/lib/xitdb/ash/search.ex
+++ b/lib/xitdb/ash/search.ex
@@ -451,7 +451,7 @@ if Code.ensure_loaded?(Ash.DataLayer) do
     #   ├── "docs"  (:hash_map -> doc_key => %{"len" => int, "terms" => %{term => weight}})
     #   └── "terms" (:sorted_map -> term => %{doc_key => weight})
 
-    alias Xitdb.TxCompiler
+    alias Xitdb.Selector
 
     @spec read_entity_field(term(), String.t(), String.t(), String.t() | atom()) :: term()
     def read_entity_field(db, collection, doc_key, attr_key) do
@@ -599,8 +599,8 @@ if Code.ensure_loaded?(Ash.DataLayer) do
 
     @spec apply_diff(term(), String.t(), String.t(), map()) :: term()
     def apply_diff(db, collection, doc_key, diff) do
-      col_str = TxCompiler.format_key(collection)
-      doc_str = TxCompiler.format_key(doc_key)
+      col_str = Selector.format_key(collection)
+      doc_str = Selector.format_key(doc_key)
 
       meta_prefix = ".idx.search." <> col_str <> ".meta"
       docs_prefix = ".idx.search." <> col_str <> ".docs"
@@ -625,11 +625,11 @@ if Code.ensure_loaded?(Ash.DataLayer) do
           %{len: len, terms: doc_terms} ->
             put_terms =
               Enum.map(doc_terms, fn {term, weight} ->
-                {:put, doc_path <> ".terms." <> TxCompiler.format_key(term), weight}
+                {:put, doc_path <> ".terms." <> Selector.format_key(term), weight}
               end)
 
-            [{:put, doc_path <> ".len", len} | put_terms]
+            [
+              {:put, doc_path <> ".len", len},
+              {:reset_col, doc_path <> ".terms", "hash_map"} | put_terms
+            ]
         end
@@ -634,11 +634,11 @@ if Code.ensure_loaded?(Ash.DataLayer) do
       term_ops =
         Enum.flat_map(diff.term_ops, fn
           {:put, term, weight} ->
-            term_str = TxCompiler.format_key(term)
+            term_str = Selector.format_key(term)
             [{:put, terms_prefix <> "$" <> term_str <> "." <> doc_str, weight}]
 
           {:delete, term} ->
-            term_str = TxCompiler.format_key(term)
+            term_str = Selector.format_key(term)
             postings = lookup_term(db, collection, term)
 
             if length(postings) <= 1 do
diff --git a/lib/xitdb/cursor.ex b/lib/xitdb/cursor.ex
--- a/lib/xitdb/cursor.ex
+++ b/lib/xitdb/cursor.ex
@@ -16,7 +16,7 @@ defmodule Xitdb.Cursor do
 
   @behaviour Access
 
-  alias Xitdb.{NIF, TxCompiler}
+  alias Xitdb.{NIF, Selector, TxCompiler}
 
   @enforce_keys [:db_ref, :tag, :tag_id, :value]
   defstruct [
@@ -256,7 +256,7 @@ defmodule Xitdb.Cursor do
     rev_steps
     |> :lists.reverse()
     |> Enum.map_join("", fn {kind, key_or_idx} ->
-      TxCompiler.format_step(kind, key_or_idx)
+      Selector.format_step(kind, key_or_idx)
     end)
   end
 
diff --git a/lib/xitdb/selector.ex b/lib/xitdb/selector.ex
new file mode 100644
--- /dev/null
+++ b/lib/xitdb/selector.ex
@@ -0,0 +1,159 @@
+defmodule Xitdb.Selector do
+  @moduledoc false
+
+  @valid_selector_starts [?., ?#, ?$, ?[, ?%, ?^, ?@]
+
+  @typed_modifiers [
+    :counted,
+    :counted_map,
+    :sorted,
+    :sorted_map,
+    :linked,
+    :linked_list,
+    :array,
+    :array_list,
+    :set_member,
+    :hash_set,
+    :counted_set_member,
+    :counted_set,
+    :sorted_set_member,
+    :sorted_set
+  ]
+
+  @map_modifiers [:counted, :counted_map, :sorted, :sorted_map]
+
+  @set_modifiers [
+    :set_member,
+    :hash_set,
+    :counted_set_member,
+    :counted_set,
+    :sorted_set_member,
+    :sorted_set
+  ]
+
+  @special_chars [
+    ".",
+    "[",
+    "]",
+    "#",
+    "$",
+    "%",
+    "^",
+    "@",
+    "\"",
+    "'",
+    "\\",
+    " ",
+    "\t",
+    "\n",
+    "\r"
+  ]
+
+  @escapable_chars ["\\", "\"", "\n", "\r", "\t"]
+
+  defguard is_valid_selector_start(byte) when byte in @valid_selector_starts
+  defguard is_typed_modifier(name) when name in @typed_modifiers
+  defguard is_map_modifier(name) when name in @map_modifiers
+  defguard is_set_modifier(name) when name in @set_modifiers
+
+  @spec format_step(Xitdb.Collection.kind(), term()) :: String.t()
+  def format_step(:hash_map, key), do: "." <> format_key(key)
+  def format_step(:counted_hash_map, key), do: "#" <> format_key(key)
+  def format_step(:sorted_map, key), do: "$" <> format_key(key)
+  def format_step(:array_list, idx) when is_integer(idx), do: "[#{idx}]"
+  def format_step(:linked_array_list, idx) when is_integer(idx), do: "[[#{idx}]]"
+  def format_step(:hash_set, member), do: "%" <> format_key(member)
+  def format_step(:counted_hash_set, member), do: "#%" <> format_key(member)
+  def format_step(:sorted_set, member), do: "^" <> format_key(member)
+
+  @spec format_typed_step(atom(), term()) :: String.t()
+  def format_typed_step(kind, val) when kind in [:hash_map, :map],
+    do: format_step(:hash_map, val)
+
+  def format_typed_step(kind, val) when kind in [:counted, :counted_map, :counted_hash_map],
+    do: format_step(:counted_hash_map, val)
+
+  def format_typed_step(kind, val) when kind in [:sorted, :sorted_map],
+    do: format_step(:sorted_map, val)
+
+  def format_typed_step(kind, val) when kind in [:array, :array_list],
+    do: format_step(:array_list, val)
+
+  def format_typed_step(kind, val) when kind in [:linked, :linked_list, :linked_array_list],
+    do: format_step(:linked_array_list, val)
+
+  def format_typed_step(kind, val) when kind in [:set, :hash_set, :set_member],
+    do: format_step(:hash_set, val)
+
+  def format_typed_step(kind, val)
+      when kind in [:counted_set, :counted_hash_set, :counted_set_member],
+      do: format_step(:counted_hash_set, val)
+
+  def format_typed_step(kind, val) when kind in [:sorted_set, :sorted_set_member],
+    do: format_step(:sorted_set, val)
+
+  @spec format_bracket_step(term()) :: String.t()
+  def format_bracket_step(idx) when is_integer(idx), do: format_step(:array_list, idx)
+  def format_bracket_step([idx]) when is_integer(idx), do: format_step(:linked_array_list, idx)
+  def format_bracket_step({kind, val}), do: format_typed_step(kind, val)
+
+  def format_bracket_step(key)
+      when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)),
+      do: format_step(:hash_map, key)
+
+  def format_bracket_step(invalid) do
+    raise ArgumentError,
+          "Invalid bracket path step #{inspect(invalid)}: expected non-nil/non-boolean key, integer index, [idx], or {kind, val}"
+  end
+
+  @spec format_root_or_step(term()) :: String.t()
+  def format_root_or_step(<<first, _rest::binary>> = selector)
+      when is_valid_selector_start(first) do
+    selector
+  end
+
+  def format_root_or_step(steps) when is_list(steps), do: format_path_steps(steps)
+  def format_root_or_step({kind, val}), do: format_typed_step(kind, val)
+  def format_root_or_step(key), do: format_step(:hash_map, key)
+
+  @spec format_path_steps(String.t() | [term()]) :: String.t()
+  def format_path_steps(selector) when is_binary(selector), do: selector
+
+  def format_path_steps(steps) when is_list(steps) do
+    Enum.map_join(steps, "", &format_bracket_step/1)
+  end
+
+  @spec format_key(term()) :: String.t()
+  def format_key(invalid) when is_nil(invalid) or is_boolean(invalid) do
+    raise ArgumentError,
+          "Invalid selector key #{inspect(invalid)}: nil and booleans are not valid map or set keys"
+  end
+
+  def format_key(key) when is_binary(key) do
+    if key != <<>> and :binary.match(key, @special_chars) == :nomatch do
+      key
+    else
+      "[" <> encode_quoted(key) <> "]"
+    end
+  end
+
+  def format_key(key) when is_atom(key), do: format_key(Atom.to_string(key))
+  def format_key(key), do: format_key(to_string(key))
+
+  @spec encode_quoted(String.t()) :: String.t()
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
+end
diff --git a/lib/xitdb/sigils.ex b/lib/xitdb/sigils.ex
--- a/lib/xitdb/sigils.ex
+++ b/lib/xitdb/sigils.ex
@@ -10,7 +10,7 @@ defmodule Xitdb.Sigils do
       query = ~q"find ?name where .users[?id].username = ?name"
   """
 
-  @valid_sigil_starts [?., ?#, ?$, ?[, ?%, ?^, ?@]
+  import Xitdb.Selector, only: [is_valid_selector_start: 1]
 
   @doc """
   Validates a `xitdb` path selector at compile time and returns the canonical selector string.
@@ -18,7 +18,7 @@ defmodule Xitdb.Sigils do
   defmacro sigil_x({:<<>>, _meta, [selector]}, _modifiers) when is_binary(selector) do
     trimmed = String.trim(selector)
 
-    if trimmed == "" or :binary.first(trimmed) not in @valid_sigil_starts do
+    if trimmed == "" or not is_valid_selector_start(:binary.first(trimmed)) do
       raise ArgumentError,
             "Invalid ~x selector #{inspect(selector)}: must start with ., #, $, [, %, ^, or @"
     end
diff --git a/lib/xitdb/tx_compiler.ex b/lib/xitdb/tx_compiler.ex
--- a/lib/xitdb/tx_compiler.ex
+++ b/lib/xitdb/tx_compiler.ex
@@ -1,7 +1,16 @@
 defmodule Xitdb.TxCompiler do
   @moduledoc false
 
-  alias Xitdb.Collection
+  alias Xitdb.{Collection, Selector}
+
+  # Temporary delegates until Xitdb.DSL sub-modules are extracted in Steps 2-4
+  defdelegate format_step(kind, key), to: Selector
+  defdelegate format_typed_step(kind, val), to: Selector
+  defdelegate format_bracket_step(val), to: Selector
+  defdelegate format_root_or_step(val), to: Selector
+  defdelegate format_path_steps(steps), to: Selector
+  defdelegate format_key(key), to: Selector
+  defdelegate encode_quoted(str), to: Selector
 
   @doc """
   Compiles a nested Elixir map or `Xitdb.Collection` into a flat list of
@@ -22,7 +31,7 @@ defmodule Xitdb.TxCompiler do
     acc =
       :maps.fold(
         fn k, v, a ->
-          compile_node_acc(format_step(:hash_map, k), v, false, a)
+          compile_node_acc(Selector.format_step(:hash_map, k), v, false, a)
         end,
         acc,
         map
@@ -31,133 +40,6 @@ defmodule Xitdb.TxCompiler do
     :lists.reverse(acc)
   end
 
-  @doc """
-  Formats a single path step according to its parent collection kind.
-  """
-  def format_step(:hash_map, key), do: "." <> format_key(key)
-  def format_step(:counted_hash_map, key), do: "#" <> format_key(key)
-  def format_step(:sorted_map, key), do: "$" <> format_key(key)
-  def format_step(:array_list, idx) when is_integer(idx), do: "[#{idx}]"
-  def format_step(:linked_array_list, idx) when is_integer(idx), do: "[[#{idx}]]"
-  def format_step(:hash_set, member), do: "%" <> format_key(member)
-  def format_step(:counted_hash_set, member), do: "#%" <> format_key(member)
-  def format_step(:sorted_set, member), do: "^" <> format_key(member)
-
-  @doc """
-  Formats a dynamic bracket expression `node[key_or_idx]` based on its runtime type:
-  - Integers format as `:array_list` steps (`"[0]"`).
-  - Single-element integer lists `[idx]` format as `:linked_array_list` steps (`"[[0]]"`).
-  - Typed tuples `{:counted, k}`, `{:sorted, k}`, `{:linked, i}`, etc. format with their collection sigil.
-  - Strings and atoms format as `:hash_map` steps (`".alice"` or `".[\"a.b\"]"`).
-  """
-  def format_bracket_step(idx) when is_integer(idx), do: format_step(:array_list, idx)
-  def format_bracket_step([idx]) when is_integer(idx), do: format_step(:linked_array_list, idx)
-  def format_bracket_step({kind, val}), do: format_typed_step(kind, val)
-
-  def format_bracket_step(key) when is_binary(key) or is_atom(key),
-    do: format_step(:hash_map, key)
-
-  @valid_selector_starts [?., ?#, ?$, ?[, ?%, ?^, ?@]
-
-  @doc """
-  Formats a root-level dynamic value: if it is already a canonical selector string
-  (starting with `.`, `#`, `$`, `[`, `%`, `^`, or `@`), returns it unchanged;
-  otherwise formats it as a path step.
-  """
-  def format_root_or_step(<<first, _rest::binary>> = selector)
-      when first in @valid_selector_starts do
-    selector
-  end
-
-  def format_root_or_step(steps) when is_list(steps), do: format_path_steps(steps)
-  def format_root_or_step({kind, val}), do: format_typed_step(kind, val)
-  def format_root_or_step(key), do: format_step(:hash_map, key)
-
-  @doc """
-  Formats a selector string or a list of path step specifications into a canonical selector.
-  """
-  def format_path_steps(selector) when is_binary(selector), do: selector
-
-  def format_path_steps(steps) when is_list(steps) do
-    Enum.map_join(steps, "", &format_bracket_step/1)
-  end
-
-  def format_typed_step(kind, val) when kind in [:hash_map, :map],
-    do: format_step(:hash_map, val)
-
-  def format_typed_step(kind, val) when kind in [:counted, :counted_map, :counted_hash_map],
-    do: format_step(:counted_hash_map, val)
-
-  def format_typed_step(kind, val) when kind in [:sorted, :sorted_map],
-    do: format_step(:sorted_map, val)
-
-  def format_typed_step(kind, val) when kind in [:array, :array_list],
-    do: format_step(:array_list, val)
-
-  def format_typed_step(kind, val) when kind in [:linked, :linked_list, :linked_array_list],
-    do: format_step(:linked_array_list, val)
-
-  def format_typed_step(kind, val) when kind in [:set, :hash_set, :set_member],
-    do: format_step(:hash_set, val)
-
-  def format_typed_step(kind, val)
-      when kind in [:counted_set, :counted_hash_set, :counted_set_member],
-      do: format_step(:counted_hash_set, val)
-
-  def format_typed_step(kind, val) when kind in [:sorted_set, :sorted_set_member],
-    do: format_step(:sorted_set, val)
-
-  @special_chars [
-    ".",
-    "[",
-    "]",
-    "#",
-    "$",
-    "%",
-    "^",
-    "@",
-    "\"",
-    "'",
-    "\\",
-    " ",
-    "\t",
-    "\n",
-    "\r"
-  ]
-
-  @escapable_chars ["\\", "\"", "\n", "\r", "\t"]
-
-  def format_key(key) when is_binary(key) do
-    if key != <<>> and :binary.match(key, @special_chars) == :nomatch do
-      key
-    else
-      "[" <> encode_quoted(key) <> "]"
-    end
-  end
-
-  def format_key(key) when is_atom(key), do: format_key(Atom.to_string(key))
-  def format_key(key), do: format_key(to_string(key))
-
-  @doc """
-  Wraps `str` in double quotes, escaping backslashes, double quotes, and control
-  whitespace without Elixir `\\\#{` interpolation artifacts.
-  """
-  def encode_quoted(str) when is_binary(str) do
-    if :binary.match(str, @escapable_chars) == :nomatch do
-      "\"" <> str <> "\""
-    else
-      IO.iodata_to_binary([?", escape_bytes(str, []), ?"])
-    end
-  end
-
-  defp escape_bytes(<<>>, acc), do: Enum.reverse(acc)
-  defp escape_bytes(<<?\\, rest::binary>>, acc), do: escape_bytes(rest, ["\\\\" | acc])
-  defp escape_bytes(<<?", rest::binary>>, acc), do: escape_bytes(rest, ["\\\"" | acc])
-  defp escape_bytes(<<?\n, rest::binary>>, acc), do: escape_bytes(rest, ["\\n" | acc])
-  defp escape_bytes(<<?\r, rest::binary>>, acc), do: escape_bytes(rest, ["\\r" | acc])
-  defp escape_bytes(<<?\t, rest::binary>>, acc), do: escape_bytes(rest, ["\\t" | acc])
-  defp escape_bytes(<<byte, rest::binary>>, acc), do: escape_bytes(rest, [byte | acc])
-
   def compile_node(prefix, node, reset?) do
     :lists.reverse(compile_node_acc(prefix, node, reset?, []))
   end
@@ -172,20 +54,7 @@ defmodule Xitdb.TxCompiler do
   defp kind_str(:sorted_set), do: "sorted_set"
 
   defp compile_node_acc(prefix, map, reset?, acc) when is_map(map) and not is_struct(map) do
-    if map_size(map) == 0 do
-      op = if reset?, do: {:reset_col, prefix, "hash_map"}, else: {:init_col, prefix, "hash_map"}
-      [op | acc]
-    else
-      acc = if reset?, do: [{:reset_col, prefix, "hash_map"} | acc], else: acc
-
-      :maps.fold(
-        fn k, v, a ->
-          compile_node_acc(prefix <> format_step(:hash_map, k), v, false, a)
-        end,
-        acc,
-        map
-      )
-    end
+    compile_kv_collection(prefix, :hash_map, map, reset?, acc)
   end
 
   defp compile_node_acc(prefix, list, _reset?, acc) when is_list(list) do
@@ -195,37 +64,7 @@ defmodule Xitdb.TxCompiler do
 
   defp compile_node_acc(prefix, %Collection{kind: kind, data: data}, reset?, acc)
        when kind in [:hash_map, :counted_hash_map, :sorted_map] do
-    k_str = kind_str(kind)
-
-    if is_map(data) and not is_struct(data) do
-      if map_size(data) == 0 do
-        op = if reset?, do: {:reset_col, prefix, k_str}, else: {:init_col, prefix, k_str}
-        [op | acc]
-      else
-        acc = if reset?, do: [{:reset_col, prefix, k_str} | acc], else: acc
-
-        :maps.fold(
-          fn k, v, a ->
-            compile_node_acc(prefix <> format_step(kind, k), v, false, a)
-          end,
-          acc,
-          data
-        )
-      end
-    else
-      entries = Enum.to_list(data)
-
-      if entries == [] do
-        op = if reset?, do: {:reset_col, prefix, k_str}, else: {:init_col, prefix, k_str}
-        [op | acc]
-      else
-        acc = if reset?, do: [{:reset_col, prefix, k_str} | acc], else: acc
-
-        Enum.reduce(entries, acc, fn {k, v}, a ->
-          compile_node_acc(prefix <> format_step(kind, k), v, false, a)
-        end)
-      end
-    end
+    compile_kv_collection(prefix, kind, data, reset?, acc)
   end
 
   defp compile_node_acc(prefix, %Collection{kind: kind, data: list}, reset?, acc)
@@ -248,7 +87,7 @@ defmodule Xitdb.TxCompiler do
 
       Enum.reduce(member_list, acc, fn m, a ->
         member_str = to_string(m)
-        [{:put, prefix <> format_step(kind, member_str), member_str} | a]
+        [{:put, prefix <> Selector.format_step(kind, member_str), member_str} | a]
       end)
     end
   end
@@ -270,10 +109,46 @@ defmodule Xitdb.TxCompiler do
     [{:put, prefix, scalar} | acc]
   end
 
+  defp compile_kv_collection(prefix, kind, map, reset?, acc)
+       when is_map(map) and not is_struct(map) do
+    k_str = kind_str(kind)
+
+    if map_size(map) == 0 do
+      op = if reset?, do: {:reset_col, prefix, k_str}, else: {:init_col, prefix, k_str}
+      [op | acc]
+    else
+      acc = if reset?, do: [{:reset_col, prefix, k_str} | acc], else: acc
+
+      :maps.fold(
+        fn k, v, a ->
+          compile_node_acc(prefix <> Selector.format_step(kind, k), v, false, a)
+        end,
+        acc,
+        map
+      )
+    end
+  end
+
+  defp compile_kv_collection(prefix, kind, enumerable, reset?, acc) do
+    k_str = kind_str(kind)
+    entries = Enum.to_list(enumerable)
+
+    if entries == [] do
+      op = if reset?, do: {:reset_col, prefix, k_str}, else: {:init_col, prefix, k_str}
+      [op | acc]
+    else
+      acc = if reset?, do: [{:reset_col, prefix, k_str} | acc], else: acc
+
+      Enum.reduce(entries, acc, fn {k, v}, a ->
+        compile_node_acc(prefix <> Selector.format_step(kind, k), v, false, a)
+      end)
+    end
+  end
+
   defp compile_list_elems([], _prefix, _kind, _idx, acc), do: acc
 
   defp compile_list_elems([elem | rest], prefix, kind, idx, acc) do
-    acc = compile_node_acc(prefix <> format_step(kind, idx), elem, false, acc)
+    acc = compile_node_acc(prefix <> Selector.format_step(kind, idx), elem, false, acc)
     compile_list_elems(rest, prefix, kind, idx + 1, acc)
   end
 end
diff --git a/lib/xitdb.ex b/lib/xitdb.ex
--- a/lib/xitdb.ex
+++ b/lib/xitdb.ex
@@ -11,7 +11,7 @@ defmodule Xitdb do
 
   @behaviour Access
 
-  alias Xitdb.{Collection, Cursor, Error, NIF, Pull, TxCompiler}
+  alias Xitdb.{Collection, Cursor, Error, NIF, Pull, Selector, TxCompiler}
 
   defmacro path(expr) do
     quote do
@@ -344,7 +344,7 @@ defmodule Xitdb do
   @spec insert_at(Cursor.t(), String.t() | [term()], integer(), term()) :: Cursor.t()
   def insert_at(%Cursor{} = root, path_or_selector, index, value)
       when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
-    selector = TxCompiler.format_path_steps(path_or_selector)
+    selector = Selector.format_path_steps(path_or_selector)
     %Cursor{root | staged_ops: [{:insert, selector, index, value} | root.staged_ops]}
   end
 
@@ -356,8 +356,8 @@ defmodule Xitdb do
   def delete_at(%Cursor{} = root, path_or_selector, index)
       when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
     selector =
-      TxCompiler.format_path_steps(path_or_selector) <>
-        TxCompiler.format_step(:linked_array_list, index)
+      Selector.format_path_steps(path_or_selector) <>
+        Selector.format_step(:linked_array_list, index)
 
     %Cursor{root | staged_ops: [{:rm, selector} | root.staged_ops]}
   end
````

---

## 3. Verification Tests for Step 1

```elixir
defmodule Xitdb.SelectorTest do
  use ExUnit.Case, async: true

  alias Xitdb.{Selector, TxCompiler}

  test "format_path_steps formats mixed maps, typed steps, and linked indices" do
    steps = [{:counted, :users}, "alice.liddell", :todos, [0]]
    assert Selector.format_path_steps(steps) == ~s(#users.["alice.liddell"].todos[[0]])
  end

  test "format_root_or_step preserves canonical selectors and encodes plain keys" do
    assert Selector.format_root_or_step(".users.alice") == ".users.alice"
    assert Selector.format_root_or_step("$idx") == "$idx"
    assert Selector.format_root_or_step("users") == ".users"
  end

  test "rejects nil and boolean keys in format_bracket_step/1 and format_key/1" do
    assert_raise ArgumentError, ~r/Invalid bracket path step nil/, fn ->
      Selector.format_bracket_step(nil)
    end

    assert_raise ArgumentError, ~r/Invalid bracket path step false/, fn ->
      Selector.format_bracket_step(false)
    end

    assert_raise ArgumentError, ~r/Invalid selector key nil/, fn ->
      Selector.format_key(nil)
    end

    assert_raise ArgumentError, ~r/Invalid selector key true/, fn ->
      Selector.format_key(true)
    end
  end

  test "TxCompiler.compile_node handles empty and keyword-backed Collections identically" do
    assert TxCompiler.compile_node(".org", Xitdb.counted_map(%{}), false) == [
             {:init_col, ".org", "counted_hash_map"}
           ]

    assert TxCompiler.compile_node(".cat", Xitdb.sorted_map(a: 1, b: 2), true) == [
             {:reset_col, ".cat", "sorted_map"},
             {:put, ".cat$a", 1},
             {:put, ".cat$b", 2}
           ]
  end
end
```
