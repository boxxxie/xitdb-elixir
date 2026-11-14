# Reference: Step 2 — Inclusive `Range` Semantics & Validation in `Xitdb.Pull`

> [!IMPORTANT]
> **Step Metadata:**
> - **Track:** [`client_fixes_and_dedup_20261111`](../index.md) (`Track 5B [Wave 4]`)
> - **Target Modules:** [`lib/xitdb/pull.ex`](../../../../lib/xitdb/pull.ex), [`lib/xitdb.ex`](../../../../lib/xitdb.ex), [`docs/path-and-pull-dsl.md`](../../../../docs/path-and-pull-dsl.md)
> - **Test Suite:** `test/xitdb/pull_compile_test.exs`

---

## 1. Architectural Motivation & Summary

Step 2 aligns `Xitdb.Pull` range patterns with Elixir's native inclusive `Range` semantics used in `Enum.slice/2` and `Xitdb.DSL.slice`:

1. **Inclusive `first..last` Translation:**
   Converts Elixir's inclusive `first..last//1` into Odin's half-open `[first..last + 1]` wire syntax instead of passing `last` straight through as an exclusive bound.
   - `0..0` now returns 1 item (`[0..1]`).
   - `0..2` returns 3 items (`[0..3]`), matching `Enum.slice/2` and `DSL.__tx_slice__/3`.

2. **Consolidated Slice & Non-Empty Nested List Validation (`format_slice_spec!/1`):**
   Deduplicates the four range/slice `compile_entry!/1` clauses in [`lib/xitdb/pull.ex`](../../../../lib/xitdb/pull.ex) while preserving `and nested != []` guards on nested sub-projections so `[profile: []]` and `[team: {0..2, []}]` deterministically raise `ArgumentError` in `Pull.compile!/1` (and return `{:error, %Xitdb.Error{reason: :invalid_pull_pattern}}` in `Pull.compile/1`), alongside rejecting negative offsets, negative limits, descending ranges, or stepped ranges (`step != 1`).

3. **Synced Doctests and Guides:**
   Updates `@moduledoc` / `@doc` examples in [`lib/xitdb/pull.ex`](../../../../lib/xitdb/pull.ex) and [`lib/xitdb.ex`](../../../../lib/xitdb.ex) plus the pattern reference table in [`docs/path-and-pull-dsl.md`](../../../../docs/path-and-pull-dsl.md).

---

## 2. Step 2 Code Changes (`diff`)

````diff
diff --git a/lib/xitdb/pull.ex b/lib/xitdb/pull.ex
--- a/lib/xitdb/pull.ex
+++ b/lib/xitdb/pull.ex
@@ -5,10 +5,10 @@ defmodule Xitdb.Pull do
   ## Examples
 
       iex> Xitdb.Pull.compile!([:username, :age, todos: 0..2, profile: [:city]])
-      "{username, age, todos[0..2], profile{city}}"
+      "{username, age, todos[0..3], profile{city}}"
 
-      iex> Xitdb.Pull.compile!([:*, friends: {0..5, [:username, profile: [:city]]}])
-      "{*, friends[0..5]{username, profile{city}}}"
+      iex> Xitdb.Pull.compile!([:*, friends: {0..4, [:username, profile: [:city]]}])
+      "{*, friends[0..5]{username, profile{city}}}"
   """
 
   alias Xitdb.Error
@@ -25,6 +25,9 @@ defmodule Xitdb.Pull do
 
   @type pattern :: String.t() | [pattern_entry()]
 
+  defguardp is_slice_spec(spec)
+            when is_struct(spec, Range) or
+                   (is_tuple(spec) and tuple_size(spec) == 3 and elem(spec, 0) == :slice)
 
   @doc """
   Compiles a structural Pull pattern list or validates a Pull pattern binary.
@@ -90,33 +93,42 @@ defmodule Xitdb.Pull do
     field
   end
 
-  defp compile_entry!({field, first..last//1}) do
-    format_field_name!(field) <> "[#{first}..#{last}]"
+  defp compile_entry!({field, nested}) when is_list(nested) and nested != [] do
+    format_field_name!(field) <> compile_list!(nested)
   end
 
-  defp compile_entry!({field, {:slice, offset, limit}})
-       when is_integer(offset) and is_integer(limit) do
-    format_field_name!(field) <> "[#{offset}..#{offset + limit}]"
+  defp compile_entry!({field, {slice_spec, nested}})
+       when is_slice_spec(slice_spec) and is_list(nested) and nested != [] do
+    format_field_name!(field) <> format_slice_spec!(slice_spec) <> compile_list!(nested)
   end
 
-  defp compile_entry!({field, nested}) when is_list(nested) and nested != [] do
-    format_field_name!(field) <> compile_list!(nested)
+  defp compile_entry!({field, slice_spec}) when is_slice_spec(slice_spec) do
+    format_field_name!(field) <> format_slice_spec!(slice_spec)
   end
 
-  defp compile_entry!({field, {first..last//1, nested}})
-       when is_list(nested) and nested != [] do
-    format_field_name!(field) <> "[#{first}..#{last}]" <> compile_list!(nested)
+  defp compile_entry!(other) do
+    raise ArgumentError, "Unsupported pull pattern entry: #{inspect(other)}"
   end
 
-  defp compile_entry!({field, {{:slice, offset, limit}, nested}})
-       when is_integer(offset) and is_integer(limit) and is_list(nested) and nested != [] do
-    format_field_name!(field) <> "[#{offset}..#{offset + limit}]" <> compile_list!(nested)
+  defp format_slice_spec!(first..last//1) when first >= 0 and last >= first do
+    "[#{first}..#{last + 1}]"
+  end
+
+  defp format_slice_spec!(%Range{} = range) do
+    raise ArgumentError,
+          "Pull range must be a non-negative ascending step-1 range, got: #{inspect(range)}"
   end
 
-  defp compile_entry!(other) do
-    raise ArgumentError, "Unsupported pull pattern entry: #{inspect(other)}"
+  defp format_slice_spec!({:slice, offset, limit})
+       when is_integer(offset) and offset >= 0 and is_integer(limit) and limit >= 0 do
+    "[#{offset}..#{offset + limit}]"
   end
 
+  defp format_slice_spec!({:slice, _, _} = bad_slice) do
+    raise ArgumentError,
+          "Pull slice requires non-negative integer offset and limit, got: #{inspect(bad_slice)}"
+  end
+
   defp format_field_name!(field)
        when is_atom(field) and not is_nil(field) and not is_boolean(field),
        do: Atom.to_string(field)
diff --git a/lib/xitdb.ex b/lib/xitdb.ex
--- a/lib/xitdb.ex
+++ b/lib/xitdb.ex
@@ -428,7 +428,7 @@ defmodule Xitdb do
   @doc """
   Executes a Datomic-style Pull projection against a `%Xitdb.Cursor{}` or `%Xitdb{}` handle.
 
-  Accepts either a raw Pull pattern string (`"{username, age, todos[0..2], profile{city}}"`)
+  Accepts either a raw Pull pattern string (`"{username, age, todos[0..3], profile{city}}"`)
   or a structural Elixir list (`[:username, :age, todos: 0..2, profile: [:city]]`).
   """
   @spec pull(t() | Cursor.t(), Pull.pattern()) :: {:ok, term()} | {:error, Error.t()}
diff --git a/docs/path-and-pull-dsl.md b/docs/path-and-pull-dsl.md
--- a/docs/path-and-pull-dsl.md
+++ b/docs/path-and-pull-dsl.md
@@ -124,7 +124,7 @@
 Xitdb.pull!(user_cursor, [
   :username,
   :age,
-  todos: 0..2,
+  todos: 0..1,
   profile: [:city, :tier]
 ])
 # => %{
@@ -141,10 +141,10 @@
 | :--- | :--- | :--- |
 | `:field` or `"field"` | `field` | Projects a single key |
 | `:*` or `"*"` | `*` | Wildcard: projects all keys on the map |
-| `field: first..end_exclusive` | `field[first..end_exclusive]` | Projects a half-open range `[first, end_exclusive)` of a list (`Array_List` or `Linked_Array_List`) |
+| `field: first..last` | `field[first..(last + 1)]` | Projects an inclusive Elixir range `first..last` (matching `Enum.slice/2`) of a list (`Array_List` or `Linked_Array_List`) |
 | `field: {:slice, offset, limit}` | `field[offset..(offset + limit)]` | Projects `limit` items starting at `offset` (matches `Enum.slice(list, offset, limit)`) |
 | `field: [:a, :b]` | `field{a, b}` | Recursively projects nested map attributes |
-| `field: {0..5, [:a, :b]}` | `field[0..5]{a, b}` | Slices a list of maps by range and projects nested attributes on each element |
+| `field: {0..4, [:a, :b]}` | `field[0..5]{a, b}` | Slices a list of maps by inclusive range and projects nested attributes on each element |
 | `field: {{:slice, offset, limit}, [:a, :b]}` | `field[offset..(offset + limit)]{a, b}` | Slices `limit` maps starting at `offset` and projects nested attributes on each element |
 
 ### Practical Pull Recipes
@@ -179,6 +179,6 @@
 use Xitdb.DSL
 
 @user_card pull_pattern([:username, :age, todos: 0..2, profile: [:city]])
-# Compiled at compile time to "{username, age, todos[0..2], profile{city}}"
+# Compiled at compile time to "{username, age, todos[0..3], profile{city}}"
 
 Xitdb.pull!(user_cursor, @user_card)
````

---

## 3. Verification Suite

> [!NOTE]
> Check existing test assertions across your suite for `todos: 0..N` where tests may have previously expected `N` elements instead of `N + 1`.

```elixir
defmodule Xitdb.PullCompileTest do
  use ExUnit.Case, async: true
  doctest Xitdb.Pull

  alias Xitdb.{Error, Pull}

  test "inclusive ranges translate to half-open [first..last + 1] bounds" do
    assert Pull.compile!([todos: 0..0]) == "{todos[0..1]}"
    assert Pull.compile!([todos: 0..2]) == "{todos[0..3]}"
    assert Pull.compile!([team: {2..4, [:username]}]) == "{team[2..5]{username}}"
  end

  test "{:slice, offset, limit} supports zero-length slices and nested projections" do
    assert Pull.compile!([todos: {:slice, 10, 0}]) == "{todos[10..10]}"
    assert Pull.compile!([team: {{:slice, 10, 5}, [:id]}]) == "{team[10..15]{id}}"
  end

  test "rejects negative, descending, stepped, or empty-nested patterns with ArgumentError" do
    for invalid <- [
          [],
          [todos: -1..2//1],
          [todos: 5..2//1],
          [todos: 0..6//2],
          [todos: {:slice, -1, 5}],
          [todos: {:slice, 0, -1}],
          [profile: []],
          [team: {0..2, []}]
        ] do
      assert {:error, %Error{reason: :invalid_pull_pattern}} = Pull.compile(invalid)
      assert_raise ArgumentError, fn -> Pull.compile!(invalid) end
    end
  end
end
```
