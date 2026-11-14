# Reference: Split `lib/xitdb/dsl.ex` & Invert Ash/Spark Dependency

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`split_dsl_and_invert_ash_dependency_20261111`](./index.md)
> - **Wave:** Wave 4 (executes after [`client_fixes_and_dedup_20261111`](../client_fixes_and_dedup_20261111/index.md) and before [`remaining_improvements_20261112`](../remaining_improvements_20261112/index.md))
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Scope:** Architectural decoupling of `lib/xitdb/dsl.ex` across 4 self-contained steps, inverting Ash/Spark dependencies via `__xitdb_indexes__/0`, and centralizing path selector syntax.

---

## 4-Step Architecture Overview

We split `lib/xitdb/dsl.ex` and invert the Ash/Spark dependency across four self-contained steps so `mix compile --warnings-as-errors` and `mix test` stay green after every patch:

1. **Step 1:** Extract `Xitdb.Selector` (`lib/xitdb/selector.ex`) to unify selector guards, sigil prefixes, `nil`/boolean key validation, and key/step formatting across `Sigils`, `TxCompiler`, `Cursor`, `Xitdb`, and `Search.Storage`, while deduplicating map/collection folding in `TxCompiler`.

2. **Step 2:** Extract `Xitdb.DSL.PathCompiler` (`lib/xitdb/dsl/path_compiler.ex`) for `path/1` AST parsing, negative index/moment compile-time folding, `(^base)` root/receiver pins, and `at_moment(^m, ...)` pinned moments.

3. **Step 3:** Extract `Xitdb.DSL.DatalogCompiler` (`lib/xitdb/dsl/datalog_compiler.ex`) for `datalog/1` and `query/2,3`, reusing `PathCompiler`'s segment folding and typed modifier helpers, rejecting `^nil` in `where` clauses, and raising caller-attributed `CompileError`s on invalid path/collection AST.

4. **Step 4:** Extract `Xitdb.DSL.TxRuntime` (`lib/xitdb/dsl/tx_runtime.ex`) and `Xitdb.DSL.TxRewriter` (`lib/xitdb/dsl/tx_rewriter.ex`), ensure consistent read-your-own-writes across ancestors, descendants, `%Collection{}` wrappers, list operations, and `fork`, remove all `Xitdb.Ash.Info` / `Spark.Dsl.Extension` calls from `tx_for` in favor of `__xitdb_indexes__/0`, fix `require Xitdb.DSL` hygiene in `Xitdb.Ash.Tx`, and trim `lib/xitdb/dsl.ex` to a thin macro facade.

---

## Table of Contents

1. [Step 1: Extract `Xitdb.Selector` & Deduplicate `TxCompiler`](#step-1-extract-xitdbselector--deduplicate-txcompiler)
2. [Step 2: Extract `Xitdb.DSL.PathCompiler` (`lib/xitdb/dsl/path_compiler.ex`)](#step-2-extract-xitdbdslpathcompiler-libxitdbdslpath_compilerex)
3. [Step 3: Extract `Xitdb.DSL.DatalogCompiler` (`lib/xitdb/dsl/datalog_compiler.ex`)](#step-3-extract-xitdbdsldatalogcompiler-libxitdbdsldatalog_compilerex)
4. [Step 4: Extract `TxRuntime` & `TxRewriter`, Invert Ash/Spark Dependency](#step-4-extract-txruntime--txrewriter-invert-ashspark-dependency)

---

## Step 1: Extract `Xitdb.Selector` & Deduplicate `TxCompiler`

* **Single source of truth for selector syntax (`lib/xitdb/selector.ex`):** Consolidates `@valid_sigil_starts` from `lib/xitdb/sigils.ex`, `@valid_selector_starts` and step/key encoders from `lib/xitdb/tx_compiler.ex`, and `@typed_modifiers` from `lib/xitdb/dsl.ex` into reusable `defguard`s (`is_valid_selector_start/1`, `is_typed_modifier/1`, `is_map_modifier/1`, `is_set_modifier/1`) and typed formatting functions, rejecting `nil` and booleans in `format_bracket_step/1` and `format_key/1`.

* **Deduplicated `TxCompiler` (`lib/xitdb/tx_compiler.ex`):** Extracts `compile_kv_collection/5` to eliminate the duplicated empty-check and `:maps.fold` / `Enum.reduce` branches between plain maps and `%Xitdb.Collection{}` structs. Temporary `defdelegate`s remain on `TxCompiler` until Steps 2–4 migrate `lib/xitdb/dsl.ex`.

* **Direct `Selector` calls in `Xitdb`, `Cursor`, `Sigils`, and `Search.Storage`:** Routes path-formatting calls directly to `Xitdb.Selector`.

### Step 1 Git Diff

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
@@ -625,14 +625,14 @@ if Code.ensure_loaded?(Ash.DataLayer) do
           %{len: len, terms: doc_terms} ->
             put_terms =
               Enum.map(doc_terms, fn {term, weight} ->
-                {:put, doc_path <> ".terms." <> TxCompiler.format_key(term), weight}
+                {:put, doc_path <> ".terms." <> Selector.format_key(term), weight}
               end)
 
-            [
-              {:put, doc_path <> ".len", len},
-              {:reset_col, doc_path <> ".terms", "hash_map"} | put_terms
-            ]
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

### Step 1 Verification Tests

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

---

## Step 2: Extract `Xitdb.DSL.PathCompiler` (`lib/xitdb/dsl/path_compiler.ex`)

* **Isolated path AST compiler (`lib/xitdb/dsl/path_compiler.ex`):** Extracts `extract_segments/1`, `extract_list_step_segment/1`, `extract_bracket_segment/1`, `typed_modifier_segment/2`, `moment_segment/1`, `fold_static_segments/1`, and `segments_to_quoted/1` behind `PathCompiler.compile/1`.

* **Compile-time folding & pin support:** Folds negative integer indices/moments at compile time, supports pinned moment specifiers (`at_moment(^m, ...)`), and splices parenthesized leading pinned prefixes (`path((^base).sorted(:directory)[emp_id])`—wrapping `^base` in parentheses because `.` and `[]` bind tighter than unary `^` in Elixir).

### Step 2 Git Diff

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

### Step 2 Verification Tests

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

---

## Step 3: Extract `Xitdb.DSL.DatalogCompiler` (`lib/xitdb/dsl/datalog_compiler.ex`)

* **Isolated Datalog AST compiler (`lib/xitdb/dsl/datalog_compiler.ex`):** Extracts Datalog `find` / `from` / `where` compilation behind `DatalogCompiler.compile/3`, reusing `PathCompiler`'s binary-folding and typed-modifier helpers.

* **Diagnostics & literal validation:** Rejects `nil` in `DatalogCompiler.format_literal/1` with `ArgumentError` and provides catch-all `compile_error!/2` clauses on `build_collection_binding/3` and `compile_path_segments/4` so invalid AST raises `CompileError` with caller `file` and `line`.

### Step 3 Git Diff

````diff
diff --git a/lib/xitdb/dsl/datalog_compiler.ex b/lib/xitdb/dsl/datalog_compiler.ex
new file mode 100644
--- /dev/null
+++ b/lib/xitdb/dsl/datalog_compiler.ex
@@ -0,0 +1,538 @@
+defmodule Xitdb.DSL.DatalogCompiler do
+  @moduledoc false
+
+  import Xitdb.Selector, only: [is_map_modifier: 1, is_set_modifier: 1, is_typed_modifier: 1]
+  alias Xitdb.DSL.PathCompiler
+  alias Xitdb.Selector
+
+  @aggregations [:count, :sum, :min, :max]
+  @predicates [:starts_with, :contains]
+
+  @doc """
+  Compiles a Datalog `do ... end` block AST into a folded binary literal (when static)
+  or minimal `<>` concatenation AST (when containing `^` runtime pins).
+  """
+  @spec compile(Macro.t(), keyword(), Macro.Env.t() | nil) :: Macro.t()
+  def compile(block_ast, opts \\ [], caller \\ nil) do
+    exprs =
+      case block_ast do
+        {:__block__, _, lines} -> lines
+        single -> [single]
+      end
+
+    {find_ast, from_ast, where_ast} = extract_sections!(exprs, opts[:from], caller)
+    {find_parts, find_vars} = compile_find!(find_ast, caller)
+    initial_bindings = init_bindings(from_ast, find_vars, caller)
+    where_clauses_ast = unwrap_where_clauses!(where_ast)
+
+    {where_segments, _final_bindings} =
+      Enum.reduce(where_clauses_ast, {[], initial_bindings}, fn
+        {:<-, _, [{alias_var, _, ctx}, source_ast]}, {seg_acc, binds}
+        when is_atom(alias_var) and is_atom(ctx) ->
+          new_binds =
+            Map.put(binds, alias_var, build_collection_binding(source_ast, alias_var, caller))
+
+          {seg_acc, new_binds}
+
+        clause_ast, {seg_acc, binds} ->
+          clause_segs = compile_where_clause!(clause_ast, find_vars, binds, caller)
+
+          line_segs =
+            case seg_acc do
+              [] -> clause_segs
+              _ -> [{:static, "\n  "} | clause_segs]
+            end
+
+          {seg_acc ++ line_segs, binds}
+      end)
+
+    header = "find " <> Enum.join(find_parts, ", ") <> "\nwhere\n  "
+    PathCompiler.fold_and_quote([{:static, header} | where_segments])
+  end
+
+  @doc false
+  def format_literal(nil) do
+    raise ArgumentError, "cannot match nil in Datalog where clause"
+  end
+
+  def format_literal(val) when is_binary(val), do: Selector.encode_quoted(val)
+  def format_literal(val) when is_integer(val) or is_float(val), do: to_string(val)
+  def format_literal(val) when is_boolean(val), do: Atom.to_string(val)
+
+  def format_literal(val) when is_atom(val),
+    do: Selector.encode_quoted(Atom.to_string(val))
+
+  def format_literal(other) do
+    raise ArgumentError, "unsupported Datalog literal in where clause: #{inspect(other)}"
+  end
+
+  @doc false
+  def format_bracket_pin(idx) when is_integer(idx), do: "[#{idx}]"
+  def format_bracket_pin([idx]) when is_integer(idx), do: "[[#{idx}]]"
+
+  def format_bracket_pin(key) when is_binary(key),
+    do: "[" <> Selector.encode_quoted(key) <> "]"
+
+  def format_bracket_pin(key)
+      when is_atom(key) and not is_nil(key) and not is_boolean(key),
+      do: "[" <> Selector.encode_quoted(Atom.to_string(key)) <> "]"
+
+  def format_bracket_pin(invalid) do
+    raise ArgumentError,
+          "invalid pinned bracket key in Datalog path: #{inspect(invalid)}"
+  end
+
+  defp init_bindings(nil, _find_vars, _caller), do: %{}
+
+  defp init_bindings({alias_var, col_ast}, _find_vars, caller) when is_atom(alias_var) do
+    %{alias_var => build_collection_binding(col_ast, alias_var, caller)}
+  end
+
+  defp init_bindings({col_name, _, ctx} = col_ast, find_vars, caller)
+       when is_atom(col_name) and is_atom(ctx) do
+    primary_var = List.first(find_vars) || :_e
+
+    if primary_var == col_name do
+      %{col_name => build_collection_binding(col_ast, col_name, caller)}
+    else
+      %{
+        primary_var => build_collection_binding(col_ast, primary_var, caller),
+        col_name => build_collection_binding(col_ast, :_e, caller)
+      }
+    end
+  end
+
+  defp init_bindings(col_ast, find_vars, caller) do
+    primary_var = List.first(find_vars) || :e
+    %{primary_var => build_collection_binding(col_ast, primary_var, caller)}
+  end
+
+  defp extract_sections!(exprs, default_from, caller) do
+    exprs
+    |> Enum.reduce({nil, default_from, nil}, fn
+      {:find, _, args}, {_find, from, where} ->
+        {args, from, where}
+
+      {:from, _, [{op, _, [{alias_var, _, ctx}, col_ast]}]}, {find, _from, where}
+      when op in [:in, :<-] and is_atom(alias_var) and is_atom(ctx) ->
+        {find, {alias_var, col_ast}, where}
+
+      {:from, _, [col_ast]}, {find, _from, where} ->
+        {find, col_ast, where}
+
+      {:where, _, [where_arg]}, {find, from, _where} ->
+        {find, from, where_arg}
+
+      other, _acc ->
+        compile_error!(
+          caller,
+          "Unsupported clause in Xitdb.DSL.datalog/query block (expected `find`, `from`, or `where`): #{Macro.to_string(other)}"
+        )
+    end)
+    |> case do
+      {nil, _, _} ->
+        compile_error!(caller, "Xitdb.DSL.query block is missing a `find` clause")
+
+      {_, _, nil} ->
+        compile_error!(caller, "Xitdb.DSL.query block is missing a `where` clause")
+
+      sections ->
+        sections
+    end
+  end
+
+  defp compile_find!(find_args, caller) do
+    items =
+      case find_args do
+        [{:{}, _, tuple_elems}] -> tuple_elems
+        [{a, b}] -> [a, b]
+        [list] when is_list(list) -> list
+        multiple when is_list(multiple) -> multiple
+      end
+
+    Enum.map_reduce(items, [], fn
+      {agg, _, [{var_name, _, ctx}]}, vars_acc
+      when agg in @aggregations and is_atom(var_name) and is_atom(ctx) ->
+        lvar = format_logic_var(var_name)
+        {"#{agg}(#{lvar})", Enum.uniq(vars_acc ++ [normalize_var_atom(var_name)])}
+
+      {var_name, _, ctx}, vars_acc when is_atom(var_name) and is_atom(ctx) ->
+        lvar = format_logic_var(var_name)
+        {lvar, Enum.uniq(vars_acc ++ [normalize_var_atom(var_name)])}
+
+      atom, vars_acc when is_atom(atom) ->
+        lvar = format_logic_var(atom)
+        {lvar, Enum.uniq(vars_acc ++ [normalize_var_atom(atom)])}
+
+      other, _vars_acc ->
+        compile_error!(
+          caller,
+          "Invalid `find` element in Datalog query: #{Macro.to_string(other)}"
+        )
+    end)
+  end
+
+  defp unwrap_where_clauses!(do: {:__block__, _, lines}), do: lines
+  defp unwrap_where_clauses!(do: single), do: [single]
+  defp unwrap_where_clauses!(clauses) when is_list(clauses), do: clauses
+  defp unwrap_where_clauses!({:__block__, _, lines}), do: lines
+  defp unwrap_where_clauses!(single), do: [single]
+
+  defp build_collection_binding(
+         {{:., _, [Access, :get]}, _, _} = indexed_ast,
+         _alias_var,
+         caller
+       ) do
+    compile_path_segments(indexed_ast, [], %{}, caller)
+  end
+
+  defp build_collection_binding({mod_fn, _, [arg]}, alias_var, _caller)
+       when is_map_modifier(mod_fn) do
+    [
+      PathCompiler.typed_modifier_segment(mod_fn, arg),
+      {:static, "[#{format_logic_var(alias_var)}]"}
+    ]
+  end
+
+  defp build_collection_binding({col_name, _, ctx}, alias_var, _caller)
+       when is_atom(col_name) and is_atom(ctx) do
+    [{:static, Selector.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
+  end
+
+  defp build_collection_binding(col_name, alias_var, _caller)
+       when (is_atom(col_name) and not is_nil(col_name) and not is_boolean(col_name)) or
+              is_binary(col_name) do
+    [{:static, Selector.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
+  end
+
+  defp build_collection_binding(bad_ast, _alias_var, caller) do
+    compile_error!(
+      caller,
+      "Invalid collection source in Datalog `from` / `<-` binding: #{Macro.to_string(bad_ast)}"
+    )
+  end
+
+  defp compile_where_clause!({:not, _, [inner_clause]}, find_vars, binds, caller) do
+    [{:static, "not "} | compile_where_clause!(inner_clause, find_vars, binds, caller)]
+  end
+
+  defp compile_where_clause!(
+         {:reach, _, [{from_var, _, c1}, {to_var, _, c2}, edge_clause]},
+         find_vars,
+         binds,
+         caller
+       )
+       when is_atom(from_var) and is_atom(c1) and is_atom(to_var) and is_atom(c2) do
+    reach_vars =
+      Enum.uniq(find_vars ++ [normalize_var_atom(from_var), normalize_var_atom(to_var)])
+
+    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds, caller)
+
+    [{:static, "reach(#{format_logic_var(from_var)}, #{format_logic_var(to_var)}, "}] ++
+      edge_segs ++
+      [{:static, ")"}]
+  end
+
+  defp compile_where_clause!(
+         {:reach, _, [{from_var, _, c1}, {to_var, _, c2}, {depth_var, _, c3}, edge_clause]},
+         find_vars,
+         binds,
+         caller
+       )
+       when is_atom(from_var) and is_atom(c1) and is_atom(to_var) and is_atom(c2) and
+              is_atom(depth_var) and is_atom(c3) do
+    reach_vars =
+      Enum.uniq(
+        find_vars ++
+          [
+            normalize_var_atom(from_var),
+            normalize_var_atom(to_var),
+            normalize_var_atom(depth_var)
+          ]
+      )
+
+    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds, caller)
+
+    [
+      {:static,
+       "reach(#{format_logic_var(from_var)}, #{format_logic_var(to_var)}, #{format_logic_var(depth_var)}, "}
+    ] ++
+      edge_segs ++
+      [{:static, ")"}]
+  end
+
+  defp compile_where_clause!({pred, _, [arg1, arg2]}, _find_vars, _binds, caller)
+       when pred in @predicates do
+    [{:static, "#{pred}("}] ++
+      compile_operand!(arg1, caller) ++
+      [{:static, ", "}] ++
+      compile_operand!(arg2, caller) ++
+      [{:static, ")"}]
+  end
+
+  defp compile_where_clause!({op, _, [lhs, rhs]}, find_vars, binds, caller)
+       when op in [:==, :=] do
+    if datalog_path_expr?(lhs) do
+      compile_path_segments(lhs, find_vars, binds, caller) ++
+        [{:static, " = "}] ++
+        compile_operand!(rhs, caller)
+    else
+      compile_operand!(lhs, caller) ++
+        [{:static, " == "}] ++
+        compile_operand!(rhs, caller)
+    end
+  end
+
+  defp compile_where_clause!({op, _, [lhs, rhs]}, find_vars, binds, caller)
+       when op in [:!=, :>, :>=, :<, :<=] do
+    lhs_segs =
+      if datalog_path_expr?(lhs) do
+        compile_path_segments(lhs, find_vars, binds, caller)
+      else
+        compile_operand!(lhs, caller)
+      end
+
+    lhs_segs ++ [{:static, " #{op} "}] ++ compile_operand!(rhs, caller)
+  end
+
+  defp compile_where_clause!(
+         {{:., _, [left, set_fn]}, _, [member_arg]},
+         find_vars,
+         binds,
+         caller
+       )
+       when is_set_modifier(set_fn) do
+    compile_path_segments(left, find_vars, binds, caller) ++
+      compile_set_step!(set_fn, member_arg, caller)
+  end
+
+  defp compile_where_clause!({set_fn, _, [left, member_arg]}, find_vars, binds, caller)
+       when is_set_modifier(set_fn) do
+    compile_path_segments(left, find_vars, binds, caller) ++
+      compile_set_step!(set_fn, member_arg, caller)
+  end
+
+  defp compile_where_clause!(other, find_vars, binds, caller) do
+    if datalog_path_expr?(other) do
+      compile_path_segments(other, find_vars, binds, caller)
+    else
+      compile_error!(caller, "Unsupported Datalog `where` clause: #{Macro.to_string(other)}")
+    end
+  end
+
+  defp datalog_path_expr?({:at_moment, _, [_, _]}), do: true
+  defp datalog_path_expr?({{:., _, _}, _, _}), do: true
+  defp datalog_path_expr?({mod_fn, _, _}) when is_typed_modifier(mod_fn), do: true
+  defp datalog_path_expr?(_), do: false
+
+  defp compile_path_segments({:root, _, ctx}, _find_vars, _binds, _caller) when is_atom(ctx),
+    do: []
+
+  defp compile_path_segments({:_, _, ctx}, _find_vars, _binds, _caller) when is_atom(ctx),
+    do: []
+
+  defp compile_path_segments(
+         {:at_moment, _, [moment_ast, inner_ast]},
+         find_vars,
+         binds,
+         caller
+       ) do
+    [
+      compile_moment_segment!(moment_ast, caller)
+      | compile_path_segments(inner_ast, find_vars, binds, caller)
+    ]
+  end
+
+  defp compile_path_segments({mod_fn, _, [arg]}, _find_vars, _binds, _caller)
+       when is_typed_modifier(mod_fn) do
+    [PathCompiler.typed_modifier_segment(mod_fn, arg)]
+  end
+
+  defp compile_path_segments({{:., _, [left, set_fn]}, _, [member_arg]}, find_vars, binds, caller)
+       when is_set_modifier(set_fn) do
+    compile_path_segments(left, find_vars, binds, caller) ++
+      compile_set_step!(set_fn, member_arg, caller)
+  end
+
+  defp compile_path_segments({{:., _, [left, mod_fn]}, _, [arg]}, find_vars, binds, caller)
+       when is_typed_modifier(mod_fn) do
+    compile_path_segments(left, find_vars, binds, caller) ++
+      [PathCompiler.typed_modifier_segment(mod_fn, arg)]
+  end
+
+  defp compile_path_segments({{:., _, [left, field]}, _, []}, find_vars, binds, caller)
+       when is_atom(field) do
+    compile_path_segments(left, find_vars, binds, caller) ++
+      [{:static, Selector.format_step(:hash_map, field)}]
+  end
+
+  defp compile_path_segments(
+         {{:., _, [Access, :get]}, _, [{root_name, _, ctx}, right]},
+         find_vars,
+         binds,
+         caller
+       )
+       when is_atom(root_name) and is_atom(ctx) do
+    base_segs =
+      cond do
+        root_name in [:root, :_] -> []
+        Map.has_key?(binds, root_name) -> Map.fetch!(binds, root_name)
+        true -> [{:static, Selector.format_step(:hash_map, root_name)}]
+      end
+
+    base_segs ++ [compile_bracket_step!(right, find_vars, caller)]
+  end
+
+  defp compile_path_segments(
+         {{:., _, [Access, :get]}, _, [left, right]},
+         find_vars,
+         binds,
+         caller
+       ) do
+    compile_path_segments(left, find_vars, binds, caller) ++
+      [compile_bracket_step!(right, find_vars, caller)]
+  end
+
+  defp compile_path_segments({name, _, ctx}, find_vars, binds, _caller)
+       when is_atom(name) and is_atom(ctx) do
+    norm = normalize_var_atom(name)
+
+    cond do
+      Map.has_key?(binds, norm) -> Map.fetch!(binds, norm)
+      norm in find_vars -> [{:static, "[#{format_logic_var(norm)}]"}]
+      true -> [{:static, Selector.format_step(:hash_map, name)}]
+    end
+  end
+
+  defp compile_path_segments(bad_ast, _find_vars, _binds, caller) do
+    compile_error!(
+      caller,
+      "Invalid path expression in Datalog clause: #{Macro.to_string(bad_ast)}"
+    )
+  end
+
+  defp compile_moment_segment!(m, _caller) when is_integer(m), do: {:static, "@#{m}"}
+  defp compile_moment_segment!({:-, _, [m]}, _caller) when is_integer(m), do: {:static, "@-#{m}"}
+
+  defp compile_moment_segment!({:^, _, [pinned_expr]}, _caller) do
+    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(pinned_expr)))}
+  end
+
+  defp compile_moment_segment!({var_name, _, ctx}, _caller)
+       when is_atom(var_name) and is_atom(ctx) do
+    {:static, "@" <> format_logic_var(var_name)}
+  end
+
+  defp compile_moment_segment!(other, caller) do
+    compile_error!(caller, "Invalid moment specifier in at_moment/2: #{Macro.to_string(other)}")
+  end
+
+  defp compile_bracket_step!({:^, _, [pinned_expr]}, _find_vars, _caller) do
+    {:dynamic, quote(do: Xitdb.DSL.DatalogCompiler.format_bracket_pin(unquote(pinned_expr)))}
+  end
+
+  defp compile_bracket_step!([{:^, _, [pinned_expr]}], _find_vars, _caller) do
+    {:dynamic, quote(do: Xitdb.DSL.DatalogCompiler.format_bracket_pin([unquote(pinned_expr)]))}
+  end
+
+  defp compile_bracket_step!([{var_name, _, ctx}], _find_vars, _caller)
+       when is_atom(var_name) and is_atom(ctx) do
+    {:static, "[[#{format_logic_var(var_name)}]]"}
+  end
+
+  defp compile_bracket_step!([idx], _find_vars, _caller) when is_integer(idx) do
+    {:static, "[[#{idx}]]"}
+  end
+
+  defp compile_bracket_step!([{:-, _, [idx]}], _find_vars, _caller) when is_integer(idx) do
+    {:static, "[[-#{idx}]]"}
+  end
+
+  defp compile_bracket_step!({var_name, _, ctx}, _find_vars, _caller)
+       when is_atom(var_name) and is_atom(ctx) do
+    {:static, "[#{format_logic_var(var_name)}]"}
+  end
+
+  defp compile_bracket_step!(idx, _find_vars, _caller) when is_integer(idx) do
+    {:static, "[#{idx}]"}
+  end
+
+  defp compile_bracket_step!({:-, _, [idx]}, _find_vars, _caller) when is_integer(idx) do
+    {:static, "[-#{idx}]"}
+  end
+
+  defp compile_bracket_step!(str, _find_vars, _caller) when is_binary(str) do
+    {:static, "[" <> Selector.encode_quoted(str) <> "]"}
+  end
+
+  defp compile_bracket_step!(atom, _find_vars, _caller)
+       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
+    {:static, "[" <> Selector.encode_quoted(Atom.to_string(atom)) <> "]"}
+  end
+
+  defp compile_bracket_step!(other, _find_vars, caller) do
+    compile_error!(
+      caller,
+      "Invalid bracket expression in Datalog path: #{Macro.to_string(other)}"
+    )
+  end
+
+  defp compile_set_step!(set_fn, member_arg, caller) do
+    prefix =
+      case set_fn do
+        f when f in [:set_member, :hash_set] -> "%"
+        f when f in [:counted_set_member, :counted_set] -> "#%"
+        f when f in [:sorted_set_member, :sorted_set] -> "^"
+      end
+
+    [{:static, prefix} | compile_operand!(member_arg, caller)]
+  end
+
+  defp compile_operand!({:^, _, [pinned_expr]}, _caller) do
+    [{:dynamic, quote(do: Xitdb.DSL.DatalogCompiler.format_literal(unquote(pinned_expr)))}]
+  end
+
+  defp compile_operand!({var_name, _, ctx}, _caller) when is_atom(var_name) and is_atom(ctx) do
+    [{:static, format_logic_var(var_name)}]
+  end
+
+  defp compile_operand!({:-, _, [num]}, _caller) when is_integer(num) or is_float(num) do
+    [{:static, "-" <> to_string(num)}]
+  end
+
+  defp compile_operand!(literal, _caller)
+       when is_binary(literal) or is_number(literal) or is_boolean(literal) or
+              (is_atom(literal) and not is_nil(literal)) do
+    [{:static, format_literal(literal)}]
+  end
+
+  defp compile_operand!(other, caller) do
+    compile_error!(
+      caller,
+      "Unsupported Datalog operand (pin dynamic expressions with `^`): #{Macro.to_string(other)}"
+    )
+  end
+
+  defp format_logic_var(atom) when is_atom(atom) do
+    str = Atom.to_string(atom)
+    if String.starts_with?(str, "?"), do: str, else: "?" <> str
+  end
+
+  defp normalize_var_atom(atom) when is_atom(atom) do
+    str = Atom.to_string(atom)
+
+    if String.starts_with?(str, "?") do
+      String.to_atom(String.trim_leading(str, "?"))
+    else
+      atom
+    end
+  end
+
+  defp compile_error!(%Macro.Env{file: file, line: line}, description) do
+    raise CompileError, file: file, line: line, description: description
+  end
+
+  defp compile_error!(nil, description) do
+    raise CompileError, description: description
+  end
+end
diff --git a/lib/xitdb/dsl.ex b/lib/xitdb/dsl.ex
--- a/lib/xitdb/dsl.ex
+++ b/lib/xitdb/dsl.ex
@@ -37,12 +37,8 @@ defmodule Xitdb.DSL do
         end
   """
 
-  import Xitdb.Selector, only: [is_map_modifier: 1, is_set_modifier: 1, is_typed_modifier: 1]
-  alias Xitdb.DSL.PathCompiler
-  alias Xitdb.{Cursor, NIF, Pull, Selector, TxCompiler}
-
-  @datalog_aggregations [:count, :sum, :min, :max]
-  @datalog_predicates [:starts_with, :contains]
+  alias Xitdb.DSL.{DatalogCompiler, PathCompiler}
+  alias Xitdb.{Cursor, NIF, Pull, TxCompiler}
 
   defmacro __using__(_opts) do
     quote do
@@ -590,14 +586,14 @@ defmodule Xitdb.DSL do
         end
   """
   defmacro datalog(do: block) do
-    compile_datalog_block(block, [])
+    DatalogCompiler.compile(block, [], __CALLER__)
   end
 
   @doc """
   Compiles and executes a Datalog query block against `target` (`%Xitdb{}` or `%Xitdb.Cursor{}`).
   """
   defmacro query(target, do: block) do
-    query_str_ast = compile_datalog_block(block, [])
+    query_str_ast = DatalogCompiler.compile(block, [], __CALLER__)
 
     quote do
       Xitdb.query(unquote(target), unquote(query_str_ast), [])
@@ -611,8 +607,10 @@ defmodule Xitdb.DSL do
   end
 
   defmacro query(target, opts, do: block) do
-    {from_opt, runtime_opts} = Keyword.pop(opts, :from)
-    query_str_ast = compile_datalog_block(block, from: from_opt)
+    {from_opt, runtime_opts} =
+      if Keyword.keyword?(opts), do: Keyword.pop(opts, :from), else: {nil, opts}
+
+    query_str_ast = DatalogCompiler.compile(block, [from: from_opt], __CALLER__)
 
     quote do
       Xitdb.query(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
@@ -629,7 +627,7 @@ defmodule Xitdb.DSL do
   Same as `query/2` and `query/3`, but raises `Xitdb.Error` on failure.
   """
   defmacro query!(target, do: block) do
-    query_str_ast = compile_datalog_block(block, [])
+    query_str_ast = DatalogCompiler.compile(block, [], __CALLER__)
 
     quote do
       Xitdb.query!(unquote(target), unquote(query_str_ast), [])
@@ -643,8 +641,10 @@ defmodule Xitdb.DSL do
   end
 
   defmacro query!(target, opts, do: block) do
-    {from_opt, runtime_opts} = Keyword.pop(opts, :from)
-    query_str_ast = compile_datalog_block(block, from: from_opt)
+    {from_opt, runtime_opts} =
+      if Keyword.keyword?(opts), do: Keyword.pop(opts, :from), else: {nil, opts}
+
+    query_str_ast = DatalogCompiler.compile(block, [from: from_opt], __CALLER__)
 
     quote do
       Xitdb.query!(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
@@ -657,443 +657,6 @@ defmodule Xitdb.DSL do
     end
   end
 
-  # ============================================================================
-  # Datalog AST Compiler Implementation
-  # ============================================================================
-
-  defp compile_datalog_block(block_ast, opts) do
-    exprs =
-      case block_ast do
-        {:__block__, _, lines} -> lines
-        single -> [single]
-      end
-
-    {find_ast, from_ast, where_ast} = extract_datalog_sections!(exprs, opts[:from])
-    {find_parts, find_vars} = compile_datalog_find!(find_ast)
-
-    initial_bindings =
-      case from_ast do
-        nil ->
-          %{}
-
-        {alias_var, col_ast} when is_atom(alias_var) ->
-          %{alias_var => build_collection_binding(col_ast, alias_var)}
-
-        {col_name, _, ctx} = col_ast when is_atom(col_name) and is_atom(ctx) ->
-          primary_var = List.first(find_vars) || :_e
-
-          if primary_var == col_name do
-            %{col_name => build_collection_binding(col_ast, col_name)}
-          else
-            %{
-              primary_var => build_collection_binding(col_ast, primary_var),
-              col_name => build_collection_binding(col_ast, :_e)
-            }
-          end
-
-        col_ast ->
-          primary_var = List.first(find_vars) || :e
-          %{primary_var => build_collection_binding(col_ast, primary_var)}
-      end
-
-    where_clauses_ast = unwrap_where_clauses!(where_ast)
-
-    {where_segments, _final_bindings} =
-      Enum.reduce(where_clauses_ast, {[], initial_bindings}, fn
-        {:<-, _, [{alias_var, _, ctx}, source_ast]}, {seg_acc, binds}
-        when is_atom(alias_var) and is_atom(ctx) ->
-          new_binds = Map.put(binds, alias_var, build_collection_binding(source_ast, alias_var))
-          {seg_acc, new_binds}
-
-        clause_ast, {seg_acc, binds} ->
-          clause_segs = compile_where_clause!(clause_ast, find_vars, binds)
-
-          line_segs =
-            case seg_acc do
-              [] -> clause_segs
-              _ -> [{:static, "\n  "} | clause_segs]
-            end
-
-          {seg_acc ++ line_segs, binds}
-      end)
-
-    header = "find " <> Enum.join(find_parts, ", ") <> "\nwhere\n  "
-
-    PathCompiler.fold_and_quote([{:static, header} | where_segments])
-  end
-
-  defp extract_datalog_sections!(exprs, default_from) do
-    Enum.reduce(exprs, {nil, default_from, nil}, fn
-      {:find, _, args}, {_find, from, where} ->
-        {args, from, where}
-
-      {:from, _, [{op, _, [{alias_var, _, ctx}, col_ast]}]}, {find, _from, where}
-      when op in [:in, :<-] and is_atom(alias_var) and is_atom(ctx) ->
-        {find, {alias_var, col_ast}, where}
-
-      {:from, _, [col_ast]}, {find, _from, where} ->
-        {find, col_ast, where}
-
-      {:where, _, [where_arg]}, {find, from, _where} ->
-        {find, from, where_arg}
-
-      other, _acc ->
-        raise CompileError,
-          description:
-            "Unsupported clause in Xitdb.DSL.datalog/query block (expected `find`, `from`, or `where`): #{Macro.to_string(other)}"
-    end)
-    |> case do
-      {nil, _, _} ->
-        raise CompileError, description: "Xitdb.DSL.query block is missing a `find` clause"
-
-      {_, _, nil} ->
-        raise CompileError, description: "Xitdb.DSL.query block is missing a `where` clause"
-
-      sections ->
-        sections
-    end
-  end
-
-  defp compile_datalog_find!(find_args) do
-    items =
-      case find_args do
-        [{:{}, _, tuple_elems}] -> tuple_elems
-        [{a, b}] -> [a, b]
-        [list] when is_list(list) -> list
-        multiple when is_list(multiple) -> multiple
-      end
-
-    Enum.map_reduce(items, [], fn
-      {agg, _, [{var_name, _, ctx}]}, vars_acc
-      when agg in @datalog_aggregations and is_atom(var_name) and is_atom(ctx) ->
-        lvar = format_logic_var(var_name)
-        {"#{agg}(#{lvar})", Enum.uniq(vars_acc ++ [normalize_var_atom(var_name)])}
-
-      {var_name, _, ctx}, vars_acc when is_atom(var_name) and is_atom(ctx) ->
-        lvar = format_logic_var(var_name)
-        {lvar, Enum.uniq(vars_acc ++ [normalize_var_atom(var_name)])}
-
-      atom, vars_acc when is_atom(atom) ->
-        lvar = format_logic_var(atom)
-        {lvar, Enum.uniq(vars_acc ++ [normalize_var_atom(atom)])}
-
-      other, _vars_acc ->
-        raise CompileError,
-          description: "Invalid `find` element in Datalog query: #{Macro.to_string(other)}"
-    end)
-  end
-
-  defp unwrap_where_clauses!(do: {:__block__, _, lines}), do: lines
-  defp unwrap_where_clauses!(do: single), do: [single]
-  defp unwrap_where_clauses!(clauses) when is_list(clauses), do: clauses
-  defp unwrap_where_clauses!({:__block__, _, lines}), do: lines
-  defp unwrap_where_clauses!(single), do: [single]
-
-  defp build_collection_binding({{:., _, [Access, :get]}, _, _} = indexed_ast, _alias_var) do
-    compile_datalog_path_segments(indexed_ast, [], %{})
-  end
-
-  defp build_collection_binding({mod_fn, _, [arg]}, alias_var)
-       when is_map_modifier(mod_fn) do
-    [
-      PathCompiler.typed_modifier_segment(mod_fn, arg),
-      {:static, "[#{format_logic_var(alias_var)}]"}
-    ]
-  end
-
-  defp build_collection_binding({col_name, _, ctx}, alias_var)
-       when is_atom(col_name) and is_atom(ctx) do
-    [{:static, ".#{col_name}[#{format_logic_var(alias_var)}]"}]
-  end
-
-  defp build_collection_binding(col_name, alias_var)
-       when is_atom(col_name) or is_binary(col_name) do
-    [{:static, Selector.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
-  end
-
-  defp compile_where_clause!({:not, _, [inner_clause]}, find_vars, binds) do
-    [{:static, "not "} | compile_where_clause!(inner_clause, find_vars, binds)]
-  end
-
-  defp compile_where_clause!(
-         {:reach, _, [{from_var, _, c1}, {to_var, _, c2}, edge_clause]},
-         find_vars,
-         binds
-       )
-       when is_atom(from_var) and is_atom(c1) and is_atom(to_var) and is_atom(c2) do
-    reach_vars =
-      Enum.uniq(find_vars ++ [normalize_var_atom(from_var), normalize_var_atom(to_var)])
-
-    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds)
-
-    [{:static, "reach(#{format_logic_var(from_var)}, #{format_logic_var(to_var)}, "}] ++
-      edge_segs ++
-      [{:static, ")"}]
-  end
-
-  defp compile_where_clause!(
-         {:reach, _, [{from_var, _, c1}, {to_var, _, c2}, {depth_var, _, c3}, edge_clause]},
-         find_vars,
-         binds
-       )
-       when is_atom(from_var) and is_atom(c1) and is_atom(to_var) and is_atom(c2) and
-              is_atom(depth_var) and is_atom(c3) do
-    reach_vars =
-      Enum.uniq(
-        find_vars ++
-          [
-            normalize_var_atom(from_var),
-            normalize_var_atom(to_var),
-            normalize_var_atom(depth_var)
-          ]
-      )
-
-    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds)
-
-    [
-      {:static,
-       "reach(#{format_logic_var(from_var)}, #{format_logic_var(to_var)}, #{format_logic_var(depth_var)}, "}
-    ] ++
-      edge_segs ++
-      [{:static, ")"}]
-  end
-
-  defp compile_where_clause!({pred, _, [arg1, arg2]}, _find_vars, _binds)
-       when pred in @datalog_predicates do
-    [{:static, "#{pred}("}] ++
-      compile_datalog_operand(arg1) ++
-      [{:static, ", "}] ++
-      compile_datalog_operand(arg2) ++
-      [{:static, ")"}]
-  end
-
-  defp compile_where_clause!({op, _, [lhs, rhs]}, find_vars, binds)
-       when op in [:==, :=] do
-    if datalog_path_expr?(lhs) do
-      compile_datalog_path_segments(lhs, find_vars, binds) ++
-        [{:static, " = "}] ++
-        compile_datalog_operand(rhs)
-    else
-      compile_datalog_operand(lhs) ++
-        [{:static, " == "}] ++
-        compile_datalog_operand(rhs)
-    end
-  end
-
-  defp compile_where_clause!({op, _, [lhs, rhs]}, find_vars, binds)
-       when op in [:!=, :>, :>=, :<, :<=] do
-    lhs_segs =
-      if datalog_path_expr?(lhs) do
-        compile_datalog_path_segments(lhs, find_vars, binds)
-      else
-        compile_datalog_operand(lhs)
-      end
-
-    lhs_segs ++ [{:static, " #{op} "}] ++ compile_datalog_operand(rhs)
-  end
-
-  defp compile_where_clause!(
-         {{:., _, [left, set_fn]}, _, [member_arg]},
-         find_vars,
-         binds
-       )
-       when is_set_modifier(set_fn) do
-    compile_datalog_path_segments(left, find_vars, binds) ++
-      compile_datalog_set_step(set_fn, member_arg)
-  end
-
-  defp compile_where_clause!({set_fn, _, [left, member_arg]}, find_vars, binds)
-       when is_set_modifier(set_fn) do
-    compile_datalog_path_segments(left, find_vars, binds) ++
-      compile_datalog_set_step(set_fn, member_arg)
-  end
-
-  defp compile_where_clause!(other, find_vars, binds) do
-    if datalog_path_expr?(other) do
-      compile_datalog_path_segments(other, find_vars, binds)
-    else
-      raise CompileError,
-        description: "Unsupported Datalog `where` clause: #{Macro.to_string(other)}"
-    end
-  end
-
-  defp datalog_path_expr?({:at_moment, _, [_, _]}), do: true
-  defp datalog_path_expr?({{:., _, _}, _, _}), do: true
-  defp datalog_path_expr?({mod_fn, _, _}) when is_typed_modifier(mod_fn), do: true
-  defp datalog_path_expr?(_), do: false
-
-  defp compile_datalog_path_segments({:root, _, ctx}, _find_vars, _binds) when is_atom(ctx),
-    do: []
-
-  defp compile_datalog_path_segments({:_, _, ctx}, _find_vars, _binds) when is_atom(ctx),
-    do: []
-
-  defp compile_datalog_path_segments(
-         {:at_moment, _, [moment_ast, inner_ast]},
-         find_vars,
-         binds
-       ) do
-    [
-      compile_datalog_moment_segment(moment_ast)
-      | compile_datalog_path_segments(inner_ast, find_vars, binds)
-    ]
-  end
-
-  defp compile_datalog_path_segments({mod_fn, _, [arg]}, _find_vars, _binds)
-       when is_typed_modifier(mod_fn) do
-    [PathCompiler.typed_modifier_segment(mod_fn, arg)]
-  end
-
-  defp compile_datalog_path_segments({{:., _, [left, set_fn]}, _, [member_arg]}, find_vars, binds)
-       when is_set_modifier(set_fn) do
-    compile_datalog_path_segments(left, find_vars, binds) ++
-      compile_datalog_set_step(set_fn, member_arg)
-  end
-
-  defp compile_datalog_path_segments({{:., _, [left, mod_fn]}, _, [arg]}, find_vars, binds)
-       when is_typed_modifier(mod_fn) do
-    compile_datalog_path_segments(left, find_vars, binds) ++
-      [PathCompiler.typed_modifier_segment(mod_fn, arg)]
-  end
-
-  defp compile_datalog_path_segments({{:., _, [left, field]}, _, []}, find_vars, binds)
-       when is_atom(field) do
-    compile_datalog_path_segments(left, find_vars, binds) ++
-      [{:static, Selector.format_step(:hash_map, field)}]
-  end
-
-  defp compile_datalog_path_segments(
-         {{:., _, [Access, :get]}, _, [{root_name, _, ctx}, right]},
-         find_vars,
-         binds
-       )
-       when is_atom(root_name) and is_atom(ctx) do
-    base_segs =
-      cond do
-        root_name in [:root, :_] ->
-          []
-
-        Map.has_key?(binds, root_name) ->
-          Map.fetch!(binds, root_name)
-
-        true ->
-          [{:static, Selector.format_step(:hash_map, root_name)}]
-      end
-
-    base_segs ++ [compile_datalog_bracket_step(right, find_vars)]
-  end
-
-  defp compile_datalog_path_segments(
-         {{:., _, [Access, :get]}, _, [left, right]},
-         find_vars,
-         binds
-       ) do
-    compile_datalog_path_segments(left, find_vars, binds) ++
-      [compile_datalog_bracket_step(right, find_vars)]
-  end
-
-  defp compile_datalog_path_segments({name, _, ctx}, find_vars, binds)
-       when is_atom(name) and is_atom(ctx) do
-    norm = normalize_var_atom(name)
-
-    cond do
-      Map.has_key?(binds, norm) ->
-        Map.fetch!(binds, norm)
-
-      norm in find_vars ->
-        [{:static, "[#{format_logic_var(norm)}]"}]
-
-      true ->
-        [{:static, Selector.format_step(:hash_map, name)}]
-    end
-  end
-
-  defp compile_datalog_moment_segment(m) when is_integer(m), do: {:static, "@#{m}"}
-  defp compile_datalog_moment_segment({:-, _, [m]}) when is_integer(m), do: {:static, "@-#{m}"}
-
-  defp compile_datalog_moment_segment({:^, _, [pinned_expr]}) do
-    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(pinned_expr)))}
-  end
-
-  defp compile_datalog_moment_segment({var_name, _, ctx})
-       when is_atom(var_name) and is_atom(ctx) do
-    {:static, "@" <> format_logic_var(var_name)}
-  end
-
-  defp compile_datalog_bracket_step({:^, _, [pinned_expr]}, _find_vars) do
-    {:dynamic, quote(do: Xitdb.DSL.__format_datalog_bracket_pin__(unquote(pinned_expr)))}
-  end
-
-  defp compile_datalog_bracket_step([{:^, _, [pinned_expr]}], _find_vars) do
-    {:dynamic, quote(do: Xitdb.DSL.__format_datalog_bracket_pin__([unquote(pinned_expr)]))}
-  end
-
-  defp compile_datalog_bracket_step([{var_name, _, ctx}], _find_vars)
-       when is_atom(var_name) and is_atom(ctx) do
-    {:static, "[[#{format_logic_var(var_name)}]]"}
-  end
-
-  defp compile_datalog_bracket_step([idx], _find_vars) when is_integer(idx) do
-    {:static, "[[#{idx}]]"}
-  end
-
-  defp compile_datalog_bracket_step({var_name, _, ctx}, _find_vars)
-       when is_atom(var_name) and is_atom(ctx) do
-    {:static, "[#{format_logic_var(var_name)}]"}
-  end
-
-  defp compile_datalog_bracket_step(idx, _find_vars) when is_integer(idx) do
-    {:static, "[#{idx}]"}
-  end
-
-  defp compile_datalog_bracket_step(str, _find_vars) when is_binary(str) do
-    {:static, "[" <> Selector.encode_quoted(str) <> "]"}
-  end
-
-  defp compile_datalog_bracket_step(atom, _find_vars)
-       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
-    {:static, "[" <> Selector.encode_quoted(Atom.to_string(atom)) <> "]"}
-  end
-
-  defp compile_datalog_set_step(set_fn, member_arg) do
-    prefix =
-      case set_fn do
-        f when f in [:set_member, :hash_set] -> "%"
-        f when f in [:counted_set_member, :counted_set] -> "#%"
-        f when f in [:sorted_set_member, :sorted_set] -> "^"
-      end
-
-    [{:static, prefix} | compile_datalog_operand(member_arg)]
-  end
-
-  defp compile_datalog_operand({:^, _, [pinned_expr]}) do
-    [{:dynamic, quote(do: Xitdb.DSL.__format_datalog_literal__(unquote(pinned_expr)))}]
-  end
-
-  defp compile_datalog_operand({var_name, _, ctx}) when is_atom(var_name) and is_atom(ctx) do
-    [{:static, format_logic_var(var_name)}]
-  end
-
-  defp compile_datalog_operand(literal)
-       when is_binary(literal) or is_number(literal) or is_boolean(literal) or is_atom(literal) do
-    [{:static, __format_datalog_literal__(literal)}]
-  end
-
-  defp format_logic_var(atom) when is_atom(atom) do
-    str = Atom.to_string(atom)
-    if String.starts_with?(str, "?"), do: str, else: "?" <> str
-  end
-
-  defp normalize_var_atom(atom) when is_atom(atom) do
-    str = Atom.to_string(atom)
-
-    if String.starts_with?(str, "?") do
-      String.to_atom(String.trim_leading(str, "?"))
-    else
-      atom
-    end
-  end
-
   # ============================================================================
   # Internal Runtime Helpers for `tx` and `datalog`
   # ============================================================================
@@ -1369,23 +932,4 @@ defmodule Xitdb.DSL do
         end
     end
   end
-
-  @doc false
-  def __format_datalog_literal__(val) when is_binary(val), do: Selector.encode_quoted(val)
-  def __format_datalog_literal__(val) when is_integer(val) or is_float(val), do: to_string(val)
-  def __format_datalog_literal__(val) when is_boolean(val), do: Atom.to_string(val)
-
-  def __format_datalog_literal__(val) when is_atom(val) and not is_nil(val),
-    do: Selector.encode_quoted(Atom.to_string(val))
-
-  @doc false
-  def __format_datalog_bracket_pin__(idx) when is_integer(idx), do: "[#{idx}]"
-  def __format_datalog_bracket_pin__([idx]) when is_integer(idx), do: "[[#{idx}]]"
-
-  def __format_datalog_bracket_pin__(key) when is_binary(key),
-    do: "[" <> Selector.encode_quoted(key) <> "]"
-
-  def __format_datalog_bracket_pin__(key)
-      when is_atom(key) and not is_nil(key) and not is_boolean(key),
-      do: "[" <> Selector.encode_quoted(Atom.to_string(key)) <> "]"
 end
````

### Step 3 Verification Tests

```elixir
defmodule Xitdb.DSL.DatalogCompilerTest do
  use ExUnit.Case, async: true
  use Xitdb.DSL

  test "compiles aggregations, negative literals, reach, and set predicates" do
    prefix = "da"

    compiled =
      datalog do
        find {dept, count(u), sum(delta)}
        from u in counted(:users)

        where [
          u.dept == dept,
          starts_with(dept, ^prefix),
          u.delta == delta,
          delta >= -50,
          not u.flags.counted_set_member("archived")
        ]
      end

    assert compiled == """
           find ?dept, count(?u), sum(?delta)
           where
             #users[?u].dept = ?dept
             starts_with(?dept, "da")
             #users[?u].delta = ?delta
             ?delta >= -50
             not #users[?u].flags#%"archived"\
           """
  end

  test "raises ArgumentError when pinning nil in a Datalog where clause" do
    bad = nil

    assert_raise ArgumentError, "cannot match nil in Datalog where clause", fn ->
      datalog do
        find {id}
        where [users[id].role == ^bad]
      end
    end
  end

  test "raises CompileError with helpful message on unpinned function call or invalid path/collection AST" do
    assert_raise CompileError, ~r/Unsupported Datalog operand/, fn ->
      Code.compile_quoted(
        quote do
          use Xitdb.DSL

          datalog do
            find {id}
            where [users[id].age >= String.to_integer("10")]
          end
        end
      )
    end

    assert_raise CompileError, ~r/Invalid collection source in Datalog/, fn ->
      Code.compile_quoted(
        quote do
          use Xitdb.DSL

          datalog do
            find {u}
            from u in foo(x)
            where [u.role == "admin"]
          end
        end
      )
    end

    assert_raise CompileError, ~r/Invalid path expression in Datalog clause/, fn ->
      Code.compile_quoted(
        quote do
          use Xitdb.DSL

          datalog do
            find {id}
            where [foo(id).bar == 1]
          end
        end
      )
    end
  end
end
```

---

## Step 4: Extract `TxRuntime` & `TxRewriter`, Invert Ash/Spark Dependency

* **Consistent `staged_log` state machine (`lib/xitdb/dsl/tx_runtime.ex`):** Folds chronological staged mutations across exact, ancestor, and descendant paths on top of committed `base_moment` values, recursively unwraps `%Xitdb.Collection{}` structs (`materialize_staged_value/1`), and stages `append`, `insert`, `slice`, and `fork` snapshots accurately.

* **Inverted `tx_for` protocol & eager option check (`lib/xitdb/dsl/tx_rewriter.ex`):** Pattern-matches `{:ok, tx_ref} | {:error, _}` from `TxRuntime.init_state/3` and removes all `Spark.Dsl.Extension` and `Xitdb.Ash.Info` references from `tx_for`, relying solely on `__xitdb_indexes__/0` and optional `__xitdb_collection__/0`.

* **Standalone `Xitdb.Ash.Tx` hygiene & thin `Xitdb.DSL` facade:** Adds `require Xitdb.DSL` inside `Xitdb.Ash.Tx` macro quotes, deletes Step 1's temporary `TxCompiler` delegates, and reduces `lib/xitdb/dsl.ex` to ~220 lines.

### Step 4 Git Diff

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
+      Xitdb.query!(unquote(target), unquote(q_ast), unquote(runtime_opts))
+    end
+  end
+
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
-    end
-  end
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

### Step 4 Verification Tests

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
