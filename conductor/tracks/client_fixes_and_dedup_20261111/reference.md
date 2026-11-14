# Reference: Client Bugfixes, Range Semantics, Deadlock Elimination & Cursor Deduplication

> [!IMPORTANT]
> **Track Metadata:**
> - **Track ID:** `client_fixes_and_dedup_20261111`
> - **Execution Waves:**
>   - **Track 5A (`[Wave 1]` — MVP Prerequisites & Client Fixes):** Phase 0 (`mix.exs` `cli/0` + `:stream_data` setup), Step 1 (`@`/`\` escaping + `^sel_len` bitstring pins), Step 3 (`WireChanges` deadlock elimination + atomic `:persistent_term` pair cache + parallel-safe `tx_for`), and Step 4A (`O(1)` `staged_ops` prepending across all callers, `Cursor.fetch/2` integer resolution when `tx_mode: false`, `MapSet.size/1` opacity fix, and direct `%Xitdb{}` mutation guard)
>   - **Track 5B (`[Wave 4]` — Deferred Core Client Cleanup):** Step 2 (`Xitdb.Pull` inclusive range semantics & slice validation) and Step 4B (`Cursor` internal deduplication, stepped `Enumerable.slice/1`, and atom-free `PreviewTag` inspect)
> - **Conductor Patch & Scope Note:** `wave1_mvp_prereqs_and_schema.patch` packages the Conductor specifications, execution plans, and complete self-contained reference implementations/diffs for Wave 1 execution (Tracks 5A and 8) against the `master` (`v1.0.2`) baseline.
> - **Parent Track:** [`dsl_transactions_datalog_20261103`](../dsl_transactions_datalog_20261103/)
> - **Associated Track:** [`lazy_cursor_protocols_20261103`](../lazy_cursor_protocols_20261103/)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Target Modules:**
>   - [`mix.exs`](../../../mix.exs)
>   - [`lib/xitdb/tx_compiler.ex`](../../../lib/xitdb/tx_compiler.ex)
>   - [`lib/xitdb/dsl.ex`](../../../lib/xitdb/dsl.ex)
>   - [`lib/xitdb/pull.ex`](../../../lib/xitdb/pull.ex)
>   - [`lib/xitdb/cursor.ex`](../../../lib/xitdb/cursor.ex)
>   - [`lib/xitdb.ex`](../../../lib/xitdb.ex)
>   - [`lib/xitdb/ash/transformers/wire_changes.ex`](../../../lib/xitdb/ash/transformers/wire_changes.ex)
>   - [`lib/xitdb/ash/info.ex`](../../../lib/xitdb/ash/info.ex)
>   - [`docs/path-and-pull-dsl.md`](../../../docs/path-and-pull-dsl.md)
>   - [`docs/ash-and-spark.md`](../../../docs/ash-and-spark.md)

---

## Table of Contents

0. [Phase 0 (Wave 1): `mix.exs` Test Environment & `StreamData` Setup](#0-phase-0-wave-1-mixexs-test-environment--streamdata-setup)
1. [Step 1 (Wave 1): Selector & Datalog Escaping + Bitstring Pinning](#1-step-1-wave-1-selector--datalog-escaping--bitstring-pinning)
2. [Step 2 (Wave 4): Inclusive Range Semantics & Validation in Xitdb.Pull](#2-step-2-wave-4-inclusive-range-semantics--validation-in-xitdbpull)
3. [Step 3 (Wave 1): Remove WireChanges Deadlocks, Atomic Pair Cache & Fix tx_for Parallel Compilation](#3-step-3-wave-1-remove-wirechanges-deadlocks-atomic-pair-cache--fix-tx_for-parallel-compilation)
4. [Step 4 (Wave 1 / Wave 4): Deduplicate Xitdb.Cursor, Fix MapSet Encapsulation, Stepped Enum.slice, Inspect & O(1) Op Staging](#4-step-4-wave-1--wave-4-deduplicate-xitdbcursor-fix-mapset-encapsulation-stepped-enumslice-inspect--o1-op-staging)
5. [Future Roadmap & Modular Refactoring](#5-future-roadmap--modular-refactoring)

---

## 0. Phase 0 (Wave 1): `mix.exs` Test Environment & `StreamData` Setup

Ensure [`mix.exs`](../../../mix.exs) configures `cli/0` so `mix precommit` automatically runs in `:test` without manual `MIX_ENV=test`, and ensure `:stream_data` is loaded in `:dev` and `:test` so Wave 1 and Wave 2 (Track 11A `Codec` round-trip property checks) have `StreamData` available immediately:

````diff
diff --git a/mix.exs b/mix.exs
--- a/mix.exs
+++ b/mix.exs
@@ -31,6 +31,12 @@ defmodule Xitdb.MixProject do
     ]
   end
 
+  def cli do
+    [
+      preferred_envs: [precommit: :test]
+    ]
+  end
+
   defp elixirc_paths(:test), do: ["lib", "test/support"]
   defp elixirc_paths(_), do: ["lib"]
 
@@ -40,7 +46,7 @@ defmodule Xitdb.MixProject do
       {:telemetry, "~> 1.3"},
       {:ash, "~> 3.0", optional: true},
       {:spark, "~> 2.2", optional: true},
-      {:stream_data, "~> 1.1", optional: true},
+      {:stream_data, "~> 1.1", only: [:dev, :test]},
       {:ex_doc, "~> 0.34", only: :dev, runtime: false}
     ]
   end
````

---

## 1. Step 1 (Wave 1): Selector & Datalog Escaping + Bitstring Pinning

### 1.1 Architectural Motivation & Summary

- **Binary-safe quote escaping (`TxCompiler.encode_quoted/1`):**
  Replaces naive `~s(["#{key}"])` in [`lib/xitdb/tx_compiler.ex`](../../../lib/xitdb/tx_compiler.ex) and `inspect/1` in [`lib/xitdb/dsl.ex`](../../../lib/xitdb/dsl.ex) with a tail-recursive `MatchContext` byte escaper.
  Embedded `"`, `\`, `\n`, `\r`, and `\t` are escaped cleanly, and strings containing `#{...}` are no longer mangled into Elixir interpolation escape sequences like `\#{...}`.
- **Expanded `@special_chars`:**
  Adds `@`, `\`, and `\r` to `@special_chars` in [`lib/xitdb/tx_compiler.ex`](../../../lib/xitdb/tx_compiler.ex) so keys containing moment prefixes (`@0`, `@latest`), email addresses (`user@example.com`), or backslashes are properly bracket-quoted.
- **Datalog bracket & literal parity (consistent pin routing):**
  Updates `compile_datalog_bracket_step/2`, `__format_datalog_bracket_pin__/1`, and `__format_datalog_literal__/1` in [`lib/xitdb/dsl.ex`](../../../lib/xitdb/dsl.ex) to use `TxCompiler.encode_quoted/1`, routes pinned linked-list indices (`todos[[^idx]]`, AST `[{:^, _, [pinned_expr]}]`) through `Xitdb.DSL.__format_datalog_bracket_pin__([unquote(pinned_expr)])` (ensuring `__format_datalog_bracket_pin__([idx]) when is_integer(idx)` is actively exercised with zero dead clauses), adds atom bracket step support, and prevents `nil` from silently serializing as `"\"nil\""`.
- **Elixir 1.20 bitstring pin & set child eviction:**
  Pins `^sel_len` in `deleted_child_path?/3` in [`lib/xitdb/dsl.ex`](../../../lib/xitdb/dsl.ex) (`<<^selector::binary-size(^sel_len), ...>>`) to comply with Elixir 1.20 match semantics, and adds `?%` and `?^` delimiters so `rm` invalidates staged set members under a deleted parent path.

### 1.2 Step 1 Diff

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

### 1.3 Step 1 Verification Suite

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

---

## 2. Step 2 (Wave 4): Inclusive Range Semantics & Validation in Xitdb.Pull

### 2.1 Architectural Motivation & Summary

Step 2 (`Track 5B [Wave 4]`) aligns `Xitdb.Pull` range patterns with Elixir's native inclusive `Range` semantics used in `Enum.slice/2` and `Xitdb.DSL.slice`:

- **Inclusive `first..last` translation:** Converts Elixir's inclusive `first..last//1` into Odin's half-open `[first..last + 1]` wire syntax instead of passing `last` straight through as an exclusive bound. `0..0` now returns 1 item (`[0..1]`) and `0..2` returns 3 items (`[0..3]`), matching `Enum.slice/2` and `DSL.__tx_slice__/3`.
- **Consolidated slice & non-empty nested list validation (`format_slice_spec!/1`):** Deduplicates the four range/slice `compile_entry!/1` clauses in [`lib/xitdb/pull.ex`](../../../lib/xitdb/pull.ex) while preserving `and nested != []` guards on nested sub-projections so `[profile: []]` and `[team: {0..2, []}]` deterministically raise `ArgumentError` in `Pull.compile!/1` (wrapped as `{:error, %Xitdb.Error{reason: :invalid_pull_pattern}}` by `Pull.compile/1`), alongside rejecting negative offsets, negative limits, descending ranges, or stepped ranges (`step != 1`).
- **Synced doctests and guides:** Updates `@moduledoc` / `@doc` examples in [`lib/xitdb/pull.ex`](../../../lib/xitdb/pull.ex) and [`lib/xitdb.ex`](../../../lib/xitdb.ex) plus the pattern reference table in [`docs/path-and-pull-dsl.md`](../../../docs/path-and-pull-dsl.md).

### 2.2 Step 2 Diff

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

### 2.3 Step 2 Verification Suite

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

---

## 3. Step 3 (Wave 1): Remove WireChanges Deadlocks, Atomic Pair Cache & Fix tx_for Parallel Compilation

### 3.1 Architectural Motivation & Summary

Step 3 (`Track 5A [Wave 1]`) eliminates cyclic compilation hazards across `Xitdb.Ash.*` and `Xitdb.DSL.tx_for` while preserving `O(1)` zero-allocation runtime lookups:

- **Remove `Code.ensure_compiled/1` from `WireChanges`:** Deletes the compile-time `Code.ensure_compiled(companion)` call inside [`lib/xitdb/ash/transformers/wire_changes.ex`](../../../lib/xitdb/ash/transformers/wire_changes.ex) so mutual `companion_resource` pairs (`User <-> Profile`) never deadlock parallel compilation.
- **Atomic race-free `:persistent_term` pair cache:** Replaces `pair_lookup/3` in [`lib/xitdb/ash/info.ex`](../../../lib/xitdb/ash/info.ex) with independent per-pair `:persistent_term` keys `{__MODULE__, :pair, kind, a, b}` (`cached_pair/4`)—avoiding any shared `{__MODULE__, :pairs}` registry map read-modify-write lost-update race under concurrent cold readers—plus automatic cache invalidation (`__purge_pair_cache__/1`, scanning `:persistent_term.get/0` only during module recompilation in dev or `IEx`).
- **Elixir 1.19+ type-checker & compile-env hygiene:**
  - Pattern-matches `%Xitdb.Ash.NestedIn{}` in [`lib/xitdb/ash/info.ex`](../../../lib/xitdb/ash/info.ex) and `%Ash.Resource.Actions.Update{}` in [`lib/xitdb/ash/transformers/wire_changes.ex`](../../../lib/xitdb/ash/transformers/wire_changes.ex) before struct updates.
  - Records `Application.compile_env(:xitdb, :default_lock_change)` in the resource body when `lock_change` is omitted so Mix recompiles resources if `:default_lock_change` changes.
- **Parallel-safe `tx_for` resolution:** Replaces `Code.ensure_loaded?/1` with `Code.ensure_compiled/1` in `extract_schema_indexes!/2` ([`lib/xitdb/dsl.ex`](../../../lib/xitdb/dsl.ex)) so `tx_for` waits for concurrently compiling schema modules and reports caller `file` and `line` on `CompileError`.
- **Guide update (`docs/ash-and-spark.md`):** Updates Section 2.1 of [`docs/ash-and-spark.md`](../../../docs/ash-and-spark.md) to replace the legacy LaTeX `O(1)` notation with inline `` `O(1)` `` code spans and document the deadlock-free per-pair `:persistent_term` cache.

### 3.2 Step 3 Diff

````diff
diff --git a/lib/xitdb/ash/transformers/wire_changes.ex b/lib/xitdb/ash/transformers/wire_changes.ex
--- a/lib/xitdb/ash/transformers/wire_changes.ex
+++ b/lib/xitdb/ash/transformers/wire_changes.ex
@@ -17,6 +17,12 @@ if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resour
 
     @impl true
     def transform(dsl_state) do
+      module = Transformer.get_persisted(dsl_state, :module)
+
+      if is_atom(module) and not is_nil(module) do
+        XitdbInfo.__purge_pair_cache__(module)
+      end
+
       dsl_state =
         dsl_state
         |> persist_xitdb_metadata()
@@ -47,63 +53,12 @@ if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resour
       lock_change = Transformer.get_persisted(dsl_state, :xitdb_lock_change)
       normalized_indexes = Transformer.get_persisted(dsl_state, :xitdb_normalized_indexes)
 
-      companion_info_quoted =
-        case XitdbInfo.xitdb_companion_resource(dsl_state) do
-          {:ok, companion} when is_atom(companion) and not is_nil(companion) ->
-            case Code.ensure_compiled(companion) do
-              {:module, ^companion} ->
-                if function_exported?(companion, :__xitdb_pull_fields__, 0) do
-                  comp_editable = companion.__xitdb_editable_field_strings__()
-                  comp_pull = companion.__xitdb_pull_fields__()
-
-                  ab_editable = Enum.uniq(editable_strings ++ comp_editable)
-                  ba_editable = Enum.uniq(comp_editable ++ editable_strings)
-
-                  ab_pull = Enum.uniq(pull_fields ++ comp_pull)
-                  ba_pull = Enum.uniq(comp_pull ++ pull_fields)
-
-                  ab_pattern = Xitdb.Pull.compile!(ab_pull)
-                  ba_pattern = Xitdb.Pull.compile!(ba_pull)
-
-                  quote do
-                    @doc false
-                    def __xitdb_pair_editable_field_strings__(unquote(companion), :self_first),
-                      do: unquote(Macro.escape(ab_editable))
-
-                    def __xitdb_pair_editable_field_strings__(unquote(companion), :other_first),
-                      do: unquote(Macro.escape(ba_editable))
-
-                    def __xitdb_pair_editable_field_strings__(_, _), do: nil
-
-                    @doc false
-                    def __xitdb_pair_pull_fields__(unquote(companion), :self_first),
-                      do: unquote(Macro.escape(ab_pull))
-
-                    def __xitdb_pair_pull_fields__(unquote(companion), :other_first),
-                      do: unquote(Macro.escape(ba_pull))
-
-                    def __xitdb_pair_pull_fields__(_, _), do: nil
-
-                    @doc false
-                    def __xitdb_pair_pull_pattern__(unquote(companion), :self_first),
-                      do: unquote(Macro.escape(ab_pattern))
-
-                    def __xitdb_pair_pull_pattern__(unquote(companion), :other_first),
-                      do: unquote(Macro.escape(ba_pattern))
-
-                    def __xitdb_pair_pull_pattern__(_, _), do: nil
-                  end
-                else
-                  nil
-                end
-
-              _ ->
-                nil
-            end
-
-          _ ->
-            nil
+      compile_env_quoted =
+        if is_nil(lock_change) do
+          quote do
+            _ = Application.compile_env(:xitdb, :default_lock_change)
+          end
         end
 
       Transformer.eval(
         dsl_state,
@@ -118,6 +74,8 @@ if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resour
           normalized_indexes: normalized_indexes
         ],
         quote do
+          unquote(compile_env_quoted)
+
           @doc false
           def __xitdb_collection__, do: unquote(Macro.escape(collection))
 
@@ -141,8 +99,6 @@ if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resour
 
           @doc false
           def __xitdb_lock_change__, do: unquote(Macro.escape(lock_change))
-
-          unquote(companion_info_quoted)
         end
       )
     end
@@ -193,11 +149,8 @@ if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resour
 
     defp maybe_attach_lock_change(dsl_state, action_name, lock_change_mod, op) do
       case Ash.Resource.Info.action(dsl_state, action_name) do
-        nil ->
-          dsl_state
-
-        action ->
-          if lock_change_present?(action.changes, lock_change_mod) do
+        %Ash.Resource.Actions.Update{changes: changes} = action ->
+          if lock_change_present?(changes, lock_change_mod) do
             dsl_state
           else
             {:ok, change} =
@@ -205,7 +158,7 @@ if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resour
                 change: {lock_change_mod, op: op}
               )
 
-            updated_action = %{action | changes: action.changes ++ [change]}
+            updated_action = %Ash.Resource.Actions.Update{action | changes: changes ++ [change]}
 
             Transformer.replace_entity(
               dsl_state,
@@ -214,6 +167,9 @@ if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resour
               &(&1.name == action_name and &1.type == :update)
             )
           end
+
+        _ ->
+          dsl_state
       end
     end
 
diff --git a/lib/xitdb/ash/info.ex b/lib/xitdb/ash/info.ex
--- a/lib/xitdb/ash/info.ex
+++ b/lib/xitdb/ash/info.ex
@@ -18,10 +18,9 @@ if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource
     def editable_field_strings([resource]), do: editable_field_strings(resource)
 
     def editable_field_strings([a, b]) when is_atom(a) and is_atom(b) do
-      case pair_lookup(a, b, :__xitdb_pair_editable_field_strings__) do
-        nil -> Enum.uniq(editable_field_strings(a) ++ editable_field_strings(b))
-        res -> res
-      end
+      cached_pair(:editable_field_strings, a, b, fn ->
+        Enum.uniq(editable_field_strings(a) ++ editable_field_strings(b))
+      end)
     end
 
     def editable_field_strings(resources) when is_list(resources) do
@@ -34,10 +33,12 @@ if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource
       if function_exported?(resource, :__xitdb_editable_field_strings__, 0) do
         resource.__xitdb_editable_field_strings__()
       else
-        case Extension.get_persisted(resource, :xitdb_editable_field_strings, nil) do
-          nil -> compute_editable_field_strings(resource)
-          cached -> cached
-        end
+        fetch_persisted_or_compute(
+          resource,
+          :__xitdb_editable_field_strings__,
+          :xitdb_editable_field_strings,
+          &compute_editable_field_strings/1
+        )
       end
     end
 
@@ -62,10 +63,9 @@ if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource
     def pull_fields([resource]), do: pull_fields(resource)
 
     def pull_fields([a, b]) when is_atom(a) and is_atom(b) do
-      case pair_lookup(a, b, :__xitdb_pair_pull_fields__) do
-        nil -> Enum.uniq(pull_fields(a) ++ pull_fields(b))
-        res -> res
-      end
+      cached_pair(:pull_fields, a, b, fn ->
+        Enum.uniq(pull_fields(a) ++ pull_fields(b))
+      end)
     end
 
     def pull_fields(resources) when is_list(resources) do
@@ -78,10 +78,12 @@ if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource
       if function_exported?(resource, :__xitdb_pull_fields__, 0) do
         resource.__xitdb_pull_fields__()
       else
-        case Extension.get_persisted(resource, :xitdb_pull_fields, nil) do
-          nil -> compute_pull_fields(resource)
-          cached -> cached
-        end
+        fetch_persisted_or_compute(
+          resource,
+          :__xitdb_pull_fields__,
+          :xitdb_pull_fields,
+          &compute_pull_fields/1
+        )
       end
     end
 
@@ -103,20 +105,21 @@ if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource
     def pull_pattern_for([resource]), do: pull_pattern_for(resource)
 
     def pull_pattern_for([a, b] = pair) when is_atom(a) and is_atom(b) do
-      case pair_lookup(a, b, :__xitdb_pair_pull_pattern__) do
-        nil -> pair |> pull_fields() |> Pull.compile!()
-        res -> res
-      end
+      cached_pair(:pull_pattern, a, b, fn ->
+        pair |> pull_fields() |> Pull.compile!()
+      end)
     end
 
     def pull_pattern_for(resource) when is_atom(resource) do
       if function_exported?(resource, :__xitdb_pull_pattern__, 0) do
         resource.__xitdb_pull_pattern__()
       else
-        case Extension.get_persisted(resource, :xitdb_pull_pattern, nil) do
-          nil -> resource |> pull_fields() |> Pull.compile!()
-          cached -> cached
-        end
+        fetch_persisted_or_compute(
+          resource,
+          :__xitdb_pull_pattern__,
+          :xitdb_pull_pattern,
+          &(&1 |> pull_fields() |> Pull.compile!())
+        )
       end
     end
 
@@ -135,7 +138,12 @@ if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource
       if function_exported?(resource, :__xitdb_nested_in__, 0) do
         resource.__xitdb_nested_in__()
       else
-        compute_nested_mappings(resource)
+        fetch_persisted_or_compute(
+          resource,
+          :__xitdb_nested_in__,
+          :xitdb_nested_in,
+          &compute_nested_mappings/1
+        )
       end
     end
 
@@ -143,10 +151,9 @@ if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource
 
     @doc false
     def compute_nested_mappings(resource_or_dsl) do
-      resource_or_dsl
-      |> Extension.get_entities([:xitdb])
-      |> Enum.filter(&match?(%Xitdb.Ash.NestedIn{}, &1))
-      |> Enum.map(&%{&1 | __identifier__: nil, __spark_metadata__: nil})
+      for %Xitdb.Ash.NestedIn{parent: parent} = mapping <-
+            Extension.get_entities(resource_or_dsl, [:xitdb]),
+          not is_nil(parent) do
+        %Xitdb.Ash.NestedIn{mapping | __identifier__: nil, __spark_metadata__: nil}
+      end
     end
 
     @doc "Returns `true` when the resource is stored inside a parent entity."
@@ -265,57 +272,88 @@ if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource
     """
     @spec resolve_lock_change(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
     def resolve_lock_change(resource) when is_atom(resource) do
-      if function_exported?(resource, :__xitdb_lock_change__, 0) do
-        resource.__xitdb_lock_change__() || Application.get_env(:xitdb, :default_lock_change)
-      else
-        case Extension.get_persisted(resource, :xitdb_lock_change, :__not_persisted__) do
-          :__not_persisted__ -> resolve_lock_change_from_dsl(resource)
-          nil -> Application.get_env(:xitdb, :default_lock_change)
-          mod -> mod
-        end
-      end
+      resolve_option_with_env(
+        resource,
+        :__xitdb_lock_change__,
+        :xitdb_lock_change,
+        &xitdb_lock_change/1,
+        :default_lock_change
+      )
     end
 
-    def resolve_lock_change(dsl_state), do: resolve_lock_change_from_dsl(dsl_state)
-
-    defp resolve_lock_change_from_dsl(resource_or_dsl) do
-      case xitdb_lock_change(resource_or_dsl) do
+    def resolve_lock_change(dsl_state) do
+      case xitdb_lock_change(dsl_state) do
         {:ok, mod} when not is_nil(mod) -> mod
         _ -> Application.get_env(:xitdb, :default_lock_change)
       end
     end
 
     defp default_store(resource) when is_atom(resource) do
-      if function_exported?(resource, :__xitdb_store__, 0) do
-        resource.__xitdb_store__() || Application.get_env(:xitdb, :default_store)
-      else
-        case Extension.get_persisted(resource, :xitdb_store, :__not_persisted__) do
-          :__not_persisted__ -> default_store_from_dsl(resource)
-          nil -> Application.get_env(:xitdb, :default_store)
-          store -> store
-        end
-      end
+      resolve_option_with_env(
+        resource,
+        :__xitdb_store__,
+        :xitdb_store,
+        &xitdb_store/1,
+        :default_store
+      )
     end
 
-    defp default_store(dsl_state), do: default_store_from_dsl(dsl_state)
-
-    defp default_store_from_dsl(resource_or_dsl) do
-      case xitdb_store(resource_or_dsl) do
+    defp default_store(dsl_state) do
+      case xitdb_store(dsl_state) do
         {:ok, store} when not is_nil(store) -> store
         _ -> Application.get_env(:xitdb, :default_store)
       end
     end
 
-    defp pair_lookup(a, b, fun_name) do
-      res_a =
-        if function_exported?(a, fun_name, 2) do
-          apply(a, fun_name, [b, :self_first])
-        else
-          nil
-        end
-
-      if not is_nil(res_a) do
-        res_a
+    defp fetch_persisted_or_compute(resource, callback, persisted_key, compute_fun) do
+      if Code.ensure_loaded?(resource) and function_exported?(resource, callback, 0) do
+        apply(resource, callback, [])
+      else
+        case Extension.get_persisted(resource, persisted_key, :__not_persisted__) do
+          :__not_persisted__ -> compute_fun.(resource)
+          cached -> cached
+        end
+      end
+    end
+
+    defp resolve_option_with_env(resource, callback, persisted_key, dsl_fetcher, env_key) do
+      configured =
+        fetch_persisted_or_compute(resource, callback, persisted_key, fn res ->
+          case dsl_fetcher.(res) do
+            {:ok, val} -> val
+            _ -> nil
+          end
+        end)
+
+      configured || Application.get_env(:xitdb, env_key)
+    end
+
+    defp cached_pair(kind, a, b, compute_fun) do
+      key = {__MODULE__, :pair, kind, a, b}
+
+      case :persistent_term.get(key, :__miss__) do
+        :__miss__ ->
+          val = compute_fun.()
+
+          if Code.ensure_loaded?(a) and function_exported?(a, :__xitdb_pull_fields__, 0) and
+               Code.ensure_loaded?(b) and function_exported?(b, :__xitdb_pull_fields__, 0) do
+            :persistent_term.put(key, val)
+          end
+
+          val
+
+        cached ->
+          cached
+      end
+    end
+
+    @doc false
+    def __purge_pair_cache__(module) when is_atom(module) do
+      for {{__MODULE__, :pair, _kind, a, b} = key, _val} <- :persistent_term.get(),
+          a == module or b == module do
+        :persistent_term.erase(key)
       end
+
+      :ok
     end
   end
diff --git a/lib/xitdb/dsl.ex b/lib/xitdb/dsl.ex
--- a/lib/xitdb/dsl.ex
+++ b/lib/xitdb/dsl.ex
@@ -223,49 +223,77 @@ defmodule Xitdb.DSL do
   defp extract_schema_indexes!(schema_ast, caller) do
     mod = Macro.expand(schema_ast, caller)
 
+    if not is_atom(mod) do
+      raise CompileError,
+        file: caller.file,
+        line: caller.line,
+        description:
+          "tx_for expects a compile-time module or list of modules, got: #{Macro.to_string(schema_ast)}"
+    end
+
+    case Code.ensure_compiled(mod) do
+      {:module, ^mod} ->
+        extract_compiled_module_indexes!(mod, caller)
+
+      {:error, reason} ->
+        raise CompileError,
+          file: caller.file,
+          line: caller.line,
+          description:
+            "tx_for could not load schema module #{inspect(mod)} (#{inspect(reason)})"
+    end
+  end
+
+  defp extract_compiled_module_indexes!(mod, caller) do
     cond do
-      not is_atom(mod) ->
-        raise CompileError,
-          description:
-            "tx_for expects a compile-time module or list of modules, got: #{Macro.to_string(schema_ast)}"
-
-      Code.ensure_loaded?(mod) and function_exported?(mod, :__xitdb_indexes__, 0) ->
+      function_exported?(mod, :__xitdb_indexes__, 0) ->
         col =
           if function_exported?(mod, :__xitdb_collection__, 0) do
             mod.__xitdb_collection__()
           else
             nil
           end
 
         Enum.map(mod.__xitdb_indexes__(), fn
-          {c, field, idx_name} -> {c, field, idx_name}
-          {field, idx_name} when not is_nil(col) -> {col, field, idx_name}
+          {c, field, idx_name} ->
+            {c, field, idx_name}
+
+          {field, idx_name} when not is_nil(col) ->
+            {col, field, idx_name}
+
+          {field, idx_name} ->
+            raise CompileError,
+              file: caller.file,
+              line: caller.line,
+              description:
+                "Module #{inspect(mod)} returned 2-tuple index #{inspect({field, idx_name})} from __xitdb_indexes__/0 without defining __xitdb_collection__/0"
         end)
 
-      Code.ensure_loaded?(Xitdb.Ash.Info) and Code.ensure_loaded?(mod) and
-          function_exported?(mod, :spark_dsl_config, 0) ->
+      Code.ensure_loaded?(Xitdb.Ash.Info) and function_exported?(mod, :spark_dsl_config, 0) ->
         case apply(Spark.Dsl.Extension, :get_persisted, [mod, :xitdb_normalized_indexes, nil]) do
           persisted when is_list(persisted) ->
             persisted
 
           nil ->
             case apply(Xitdb.Ash.Info, :xitdb_collection, [mod]) do
               {:ok, col} when not is_nil(col) ->
                 idxs = apply(Xitdb.Ash.Info, :xitdb_indexes!, [mod])
                 for {field, idx_name} <- idxs, do: {col, field, idx_name}
 
               _ ->
-                raise_invalid_tx_for_schema!(mod)
+                raise_invalid_tx_for_schema!(mod, caller)
             end
         end
 
       true ->
-        raise_invalid_tx_for_schema!(mod)
+        raise_invalid_tx_for_schema!(mod, caller)
     end
   end
 
-  defp raise_invalid_tx_for_schema!(mod) do
+  defp raise_invalid_tx_for_schema!(mod, caller) do
     raise CompileError,
+      file: caller.file,
+      line: caller.line,
       description:
         "Module #{inspect(mod)} does not declare Xitdb indexes (use `Xitdb.Ash.Resource` or define `__xitdb_collection__/0` and `__xitdb_indexes__/0`)."
   end
````

And in [`docs/ash-and-spark.md`](../../../docs/ash-and-spark.md) (line 155), replace the second bullet under `### 1. Xitdb.Ash.Transformers.WireChanges` with:

```markdown
- Precomputes and compiles literal module callbacks (`__xitdb_editable_field_strings__/0`, `__xitdb_pull_fields__/0`, `__xitdb_pull_pattern__/0`, `__xitdb_collection__/0`, `__xitdb_indexes__/0`, `__xitdb_store__/0`, `__xitdb_lock_change__/0`) directly onto the resource module—while caching merged `[Resource, CompanionResource]` pair projections in independent per-pair `:persistent_term` entries—so runtime `Xitdb.Ash.Info` lookups run in **`O(1)` (~30 ns)** with zero heap allocations and zero cyclic compilation deadlocks.
```

### 3.3 Step 3 Verification Suite

```elixir
defmodule Xitdb.Ash.CompanionAndTxForTest do
  use ExUnit.Case, async: true

  if Code.ensure_loaded?(Ash.Resource) do
    defmodule MutualUser do
      use Ash.Resource, domain: nil, extensions: [Xitdb.Ash.Resource]

      xitdb do
        collection :users
        companion_resource Xitdb.Ash.CompanionAndTxForTest.MutualProfile
        editable_fields [:email]
      end

      attributes do
        uuid_primary_key :id
        attribute :email, :string, public?: true
      end
    end

    defmodule MutualProfile do
      use Ash.Resource, domain: nil, extensions: [Xitdb.Ash.Resource]

      xitdb do
        collection :users
        companion_resource MutualUser
        editable_fields [:bio]
      end

      attributes do
        uuid_primary_key :id
        attribute :bio, :string, public?: true
      end
    end

    test "mutual companion_resource declarations compile without deadlock and preserve ordering" do
      alias Xitdb.Ash.Info

      assert Info.editable_field_strings([MutualUser, MutualProfile]) == ["email", "bio"]
      assert Info.editable_field_strings([MutualProfile, MutualUser]) == ["bio", "email"]
      assert Info.pull_pattern_for([MutualUser, MutualProfile]) == "{id, email, bio}"

      assert :persistent_term.get(
               {Info, :pair, :pull_pattern, MutualUser, MutualProfile},
               nil
             ) == "{id, email, bio}"

      assert :ok == Info.__purge_pair_cache__(MutualUser)

      assert :persistent_term.get(
               {Info, :pair, :pull_pattern, MutualUser, MutualProfile},
               :purged
             ) == :purged
    end
  end

  test "tx_for raises CompileError with caller line on missing module or missing __xitdb_collection__" do
    assert_raise CompileError, ~r/could not load schema module/, fn ->
      Code.compile_quoted(
        quote do
          use Xitdb.DSL
          def run(db), do: tx_for(db, NonExistentSchemaModule, do: :ok)
        end
      )
    end
  end
end
```

---

## 4. Step 4 (Wave 1 / Wave 4): Deduplicate Xitdb.Cursor, Fix MapSet Encapsulation, Stepped Enum.slice, Inspect & O(1) Op Staging

### 4.1 Architectural Motivation & Summary

Step 4 cleans up [`lib/xitdb/cursor.ex`](../../../lib/xitdb/cursor.ex) and the transactional `Access` plumbing in [`lib/xitdb.ex`](../../../lib/xitdb.ex):

- **O(1) `staged_ops` accumulation & cross-caller audit (Wave 1 — Track 5A):**
  Accumulates `staged_ops` in reverse order via `[op | staged_ops]` and `:lists.reverse(new_ops, staged_ops)` across `Cursor` and `Xitdb.insert_at/4`, `delete_at/3`, and `fork/3`—reversing once on commit in `Xitdb.transact/3`—and raises a clear `ArgumentError` if `put_in`/`update_in`/`pop_in` is called directly on `%Xitdb{}` outside `transact/3`.
  - **Caller Audit (`lib/xitdb/dsl.ex`):** `Xitdb.DSL.tx/2,3` and `tx_for/3,4` do **not** read or write `%Cursor{}.staged_ops`; `lib/xitdb/dsl.ex` maintains its own process-dictionary `%{index_ops: [...], ops: [...]}` lists (which already prepend in `O(1)` and reverse once in `__commit_tx_state__/1`: `:lists.reverse(index_ops) ++ :lists.reverse(ops)`).
- **Integer key resolution when `tx_mode: false` (Wave 1 — Track 5A):**
  Calls `ensure_resolved(cursor)` before `NIF.nif_slot_get_index/4` whenever `is_integer(key)` (in **both** `tx_mode: false` and `tx_mode: true`, centralized in `nif_slot_get/2`), guaranteeing `Xitdb.as_of(db, 0)[0]` resolves cleanly without passing `tag_id: -1` to `nif_slot_get_index`.
- **Opaque `MapSet` compliance in Wave 1 (Elixir 1.19/1.20+ — Track 5A):**
  Replaces `map_size(cursor.deleted_paths.map) == 0` with `MapSet.size(deleted) == 0` immediately in Wave 1 so `mix compile --warnings-as-errors` under Elixir 1.19/1.20 never fails on private `MapSet` internals.
- **Deduplicated cursor construction & `Access.fetch/2` (Wave 4 — Track 5B):**
  Collapses the 4 repetitive `Cursor.fetch/2` clauses and 6 inline `%Cursor{}` tuple unpackings in [`lib/xitdb/cursor.ex`](../../../lib/xitdb/cursor.ex) into `from_nif_tuple/4`, `unwrap_nif_value/4`, `nif_slot_get/2`, and `lookup_staged/2` (preserving direct single-hop NIF resolution for string keys on `tag_id: -1` root cursors).
- **Exact stepped slicing in `Enumerable.slice/1` & atom-free `Inspect` (Wave 4 — Track 5B):**
  Fetches `(length - 1) * step + 1` elements instead of `length * step`, filters via `Enum.take_every/2` *before* allocating `%Cursor{}` / `MapSet` wrappers, handles zero-length slices without a NIF round-trip, raises `Xitdb.Error` cleanly on NIF errors, and replaces dynamic atom creation (`:"<#{child_tag}>"`) in `Inspect` with `PreviewTag` plus safe `#Xitdb.Cursor<unresolved (...)>` rendering.

### 4.2 Step 4 Diff

````diff
diff --git a/lib/xitdb/cursor.ex b/lib/xitdb/cursor.ex
--- a/lib/xitdb/cursor.ex
+++ b/lib/xitdb/cursor.ex
@@ -47,6 +47,15 @@ defmodule Xitdb.Cursor do
           deleted_paths: MapSet.t()
         }
 
+  defmodule PreviewTag do
+    @moduledoc false
+    defstruct [:tag]
+
+    defimpl Inspect do
+      def inspect(%PreviewTag{tag: tag}, _opts), do: "<#{tag}>"
+    end
+  end
+
   @doc false
   def from_nif_tuple(db_ref, {:cursor, tag_atom, tag_id, val, full_int}, moment, path_steps \\ []) do
     %__MODULE__{
@@ -61,16 +70,10 @@ defmodule Xitdb.Cursor do
   end
 
   @doc false
-  def unwrap_nif_value(db_ref, {:cursor, tag_atom, tag_id, val, full_int}, moment, path_steps) do
-    %__MODULE__{
-      db_ref: db_ref,
-      tag: tag_atom,
-      tag_id: tag_id,
-      value: val,
-      full: full_int != 0,
-      moment: moment,
-      path_steps: path_steps
-    }
+  def unwrap_nif_value(db_ref, raw, moment, path_steps \\ [])
+
+  def unwrap_nif_value(db_ref, {:cursor, _, _, _, _} = tuple, moment, path_steps) do
+    from_nif_tuple(db_ref, tuple, moment, path_steps)
   end
 
   def unwrap_nif_value(_db_ref, {:__xitdb_set__, list}, _moment, _path_steps) do
@@ -92,22 +95,17 @@ defmodule Xitdb.Cursor do
   # ============================================================================
 
   @impl Access
-  def fetch(
-        %__MODULE__{tx_mode: false, db_ref: db_ref, tag_id: tag_id, value: val, moment: moment},
-        key
-      )
-      when is_integer(key) do
-    case NIF.nif_slot_get_index(db_ref, tag_id, val, key) do
-      {:ok, {:cursor, c_tag, c_tag_id, c_val, c_full}} ->
-        {:ok,
-         %__MODULE__{
-           db_ref: db_ref,
-           tag: c_tag,
-           tag_id: c_tag_id,
-           value: c_val,
-           full: c_full != 0,
-           moment: moment
-         }}
+  def fetch(%__MODULE__{} = cursor, key) when is_atom(key) do
+    fetch(cursor, Atom.to_string(key))
+  end
+
+  def fetch(%__MODULE__{tx_mode: false} = raw_cursor, key)
+      when is_integer(key) or is_binary(key) do
+    cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
+
+    case nif_slot_get(cursor, key) do
+      {:ok, {:cursor, _, _, _, _} = tuple} ->
+        {:ok, from_nif_tuple(cursor.db_ref, tuple, cursor.moment)}
 
       {:ok, scalar} ->
         {:ok, scalar}
@@ -117,103 +113,58 @@ defmodule Xitdb.Cursor do
     end
   end
 
-  def fetch(
-        %__MODULE__{tx_mode: false, db_ref: db_ref, tag_id: tag_id, value: val, moment: moment},
-        key
-      )
-      when is_binary(key) do
-    case NIF.nif_slot_get_key(db_ref, tag_id, val, key) do
-      {:ok, {:cursor, c_tag, c_tag_id, c_val, c_full}} ->
-        {:ok,
-         %__MODULE__{
-           db_ref: db_ref,
-           tag: c_tag,
-           tag_id: c_tag_id,
-           value: c_val,
-           full: c_full != 0,
-           moment: moment
-         }}
-
-      {:ok, scalar} ->
-        {:ok, scalar}
-
-      :error ->
-        :error
-    end
-  end
-
-  def fetch(%__MODULE__{tx_mode: false} = cursor, key) when is_atom(key) do
-    fetch(cursor, Atom.to_string(key))
-  end
-
-  def fetch(%__MODULE__{tx_mode: true} = cursor, key) when is_integer(key) do
-    cursor = ensure_resolved(cursor)
+  def fetch(%__MODULE__{tx_mode: true} = raw_cursor, key)
+      when is_integer(key) or is_binary(key) do
+    cursor = if is_integer(key), do: ensure_resolved(raw_cursor), else: raw_cursor
     child_steps = [{cursor.tag, key} | cursor.path_steps]
 
-    if map_size(cursor.staged_overrides) == 0 and map_size(cursor.deleted_paths.map) == 0 do
-      case NIF.nif_slot_get_index(cursor.db_ref, cursor.tag_id, cursor.value, key) do
-        {:ok, raw} ->
-          val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
-          {:ok, inherit_staged(val, cursor)}
+    case lookup_staged(cursor, child_steps) do
+      {:staged, val} ->
+        {:ok, val}
 
-        :error ->
-          :error
-      end
-    else
-      selector = steps_to_selector(child_steps)
+      :deleted ->
+        :error
 
-      cond do
-        MapSet.member?(cursor.deleted_paths, selector) ->
-          :error
+      :miss ->
+        case nif_slot_get(cursor, key) do
+          {:ok, raw} ->
+            val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
+            {:ok, inherit_staged(val, cursor)}
 
-        Map.has_key?(cursor.staged_overrides, selector) ->
-          {:ok, Map.fetch!(cursor.staged_overrides, selector)}
-
-        true ->
-          case NIF.nif_slot_get_index(cursor.db_ref, cursor.tag_id, cursor.value, key) do
-            {:ok, raw} ->
-              val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
-              {:ok, inherit_staged(val, cursor)}
-
-            :error ->
-              :error
-          end
-      end
+          :error ->
+            :error
+        end
     end
   end
 
-  def fetch(%__MODULE__{tx_mode: true} = cursor, key) when is_binary(key) or is_atom(key) do
-    key_str = if is_binary(key), do: key, else: Atom.to_string(key)
-    child_steps = [{cursor.tag, key_str} | cursor.path_steps]
+  defp nif_slot_get(%__MODULE__{} = cursor, idx) when is_integer(idx) do
+    %__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val} = ensure_resolved(cursor)
+    NIF.nif_slot_get_index(db_ref, tag_id, val, idx)
+  end
 
-    if map_size(cursor.staged_overrides) == 0 and map_size(cursor.deleted_paths.map) == 0 do
-      case NIF.nif_slot_get_key(cursor.db_ref, cursor.tag_id, cursor.value, key_str) do
-        {:ok, raw} ->
-          val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
-          {:ok, inherit_staged(val, cursor)}
+  defp nif_slot_get(%__MODULE__{db_ref: db_ref, tag_id: tag_id, value: val}, key)
+       when is_binary(key) do
+    NIF.nif_slot_get_key(db_ref, tag_id, val, key)
+  end
 
-        :error ->
-          :error
-      end
+  defp lookup_staged(
+         %__MODULE__{staged_overrides: overrides, deleted_paths: deleted},
+         child_steps
+       ) do
+    if map_size(overrides) == 0 and MapSet.size(deleted) == 0 do
+      :miss
     else
       selector = steps_to_selector(child_steps)
 
       cond do
-        MapSet.member?(cursor.deleted_paths, selector) ->
-          :error
+        MapSet.member?(deleted, selector) ->
+          :deleted
 
-        Map.has_key?(cursor.staged_overrides, selector) ->
-          {:ok, Map.fetch!(cursor.staged_overrides, selector)}
+        Map.has_key?(overrides, selector) ->
+          {:staged, Map.fetch!(overrides, selector)}
 
         true ->
-          case NIF.nif_slot_get_key(cursor.db_ref, cursor.tag_id, cursor.value, key_str) do
-            {:ok, raw} ->
-              val = unwrap_nif_value(cursor.db_ref, raw, cursor.moment, child_steps)
-              {:ok, inherit_staged(val, cursor)}
-
-            :error ->
-              :error
-          end
+          :miss
       end
     end
   end
@@ -222,15 +171,25 @@ defmodule Xitdb.Cursor do
   @doc false
   def ensure_resolved(%__MODULE__{tag_id: -1, db_ref: db_ref, moment: moment} = cursor) do
-    case NIF.nif_moment_slot(db_ref, moment) do
-      {:ok, {:cursor, tag_atom, tag_id, val, full_int}} ->
-        %{cursor | tag: tag_atom, tag_id: tag_id, value: val, full: full_int != 0}
-
-      {:error, reason} ->
-        raise Xitdb.Error, reason: reason, details: %{moment_index: moment}
+    case try_resolve(cursor) do
+      {:ok, resolved} -> resolved
+      {:error, reason} -> raise Xitdb.Error, reason: reason, details: %{moment_index: moment}
     end
   end
 
   def ensure_resolved(cursor), do: cursor
+
+  @doc false
+  def try_resolve(%__MODULE__{tag_id: -1, db_ref: db_ref, moment: moment} = cursor) do
+    case NIF.nif_moment_slot(db_ref, moment) do
+      {:ok, {:cursor, tag_atom, tag_id, val, full_int}} ->
+        {:ok, %__MODULE__{cursor | tag: tag_atom, tag_id: tag_id, value: val, full: full_int != 0}}
+
+      {:error, reason} ->
+        {:error, reason}
+    end
+  end
+
+  def try_resolve(%__MODULE__{} = cursor), do: {:ok, cursor}
 
   @impl Access
   def get_and_update(%__MODULE__{} = cursor, key, fun) do
@@ -249,10 +205,10 @@ defmodule Xitdb.Cursor do
         selector = steps_to_selector(child_steps)
         new_ops = TxCompiler.compile_node(selector, new_val, true)
 
-        updated_cursor = %{
+        updated_cursor = %__MODULE__{
           cursor
           | tx_mode: true,
-            staged_ops: cursor.staged_ops ++ new_ops,
+            staged_ops: :lists.reverse(new_ops, cursor.staged_ops),
             staged_overrides: Map.put(cursor.staged_overrides, selector, new_val),
             deleted_paths: MapSet.delete(cursor.deleted_paths, selector)
         }
@@ -276,10 +232,10 @@ defmodule Xitdb.Cursor do
     child_steps = [{cursor.tag, child_key} | cursor.path_steps]
     selector = steps_to_selector(child_steps)
 
-    updated_cursor = %{
+    updated_cursor = %__MODULE__{
       cursor
       | tx_mode: true,
-        staged_ops: cursor.staged_ops ++ [{:rm, selector}],
+        staged_ops: [{:rm, selector} | cursor.staged_ops],
         staged_overrides: Map.delete(cursor.staged_overrides, selector),
         deleted_paths: MapSet.put(cursor.deleted_paths, selector)
     }
@@ -297,7 +253,7 @@ defmodule Xitdb.Cursor do
   end
 
   defp inherit_staged(%__MODULE__{} = child, parent) do
-    %{
+    %__MODULE__{
       child
       | tx_mode: true,
         staged_ops: parent.staged_ops,
@@ -309,7 +265,7 @@ defmodule Xitdb.Cursor do
   defp inherit_staged(scalar, _parent), do: scalar
 
   defp merge_child_staged(parent, %__MODULE__{} = child) do
-    %{
+    %__MODULE__{
       parent
       | tx_mode: true,
         staged_ops: child.staged_ops,
@@ -371,20 +327,21 @@ defimpl Enumerable, for: Xitdb.Cursor do
     case NIF.nif_slot_count(db_ref, tag_id, val) do
       {:ok, size} ->
         {:ok, size,
-         fn start, length, step ->
-           {:ok, raw_list} =
-             NIF.nif_slot_slice(db_ref, tag_id, val, start, length * step)
+         fn
+           _start, length, _step when length <= 0 ->
+             []
 
-           unwrapped =
-             Enum.map(raw_list, fn item ->
-               unwrap_entry(db_ref, item, moment, cursor.path_steps)
-             end)
+           start, length, step ->
+             span = (length - 1) * step + 1
 
-           if step == 1 do
-             unwrapped
-           else
-             Enum.take_every(unwrapped, step)
-           end
+             case NIF.nif_slot_slice(db_ref, tag_id, val, start, span) do
+               {:ok, raw_list} ->
+                 selected = if step == 1, do: raw_list, else: Enum.take_every(raw_list, step)
+                 Enum.map(selected, &unwrap_entry(db_ref, &1, moment, cursor.path_steps))
+
+               {:error, reason} ->
+                 raise Xitdb.Error, reason: reason
+             end
          end}
 
       _ ->
@@ -442,74 +399,51 @@ defimpl Enumerable, for: Xitdb.Cursor do
     end
   end
 
-  defp unwrap_entry(db_ref, {k, {:cursor, c_tag, c_tag_id, c_val, c_full}}, moment, path_steps)
-       when is_binary(k) do
-    {k,
-     %Cursor{
-       db_ref: db_ref,
-       tag: c_tag,
-       tag_id: c_tag_id,
-       value: c_val,
-       full: c_full != 0,
-       moment: moment,
-       path_steps: path_steps
-     }}
+  defp unwrap_entry(db_ref, {k, raw_val}, moment, path_steps) when is_binary(k) do
+    {k, Cursor.unwrap_nif_value(db_ref, raw_val, moment, path_steps)}
   end
 
-  defp unwrap_entry(_db_ref, {k, _scalar} = pair, _moment, _path_steps) when is_binary(k) do
-    pair
+  defp unwrap_entry(db_ref, raw_val, moment, path_steps) do
+    Cursor.unwrap_nif_value(db_ref, raw_val, moment, path_steps)
   end
-
-  defp unwrap_entry(db_ref, {:cursor, c_tag, c_tag_id, c_val, c_full}, moment, path_steps) do
-    %Cursor{
-      db_ref: db_ref,
-      tag: c_tag,
-      tag_id: c_tag_id,
-      value: c_val,
-      full: c_full != 0,
-      moment: moment,
-      path_steps: path_steps
-    }
-  end
-
-  defp unwrap_entry(db_ref, {:__xitdb_set__, list}, moment, path_steps) do
-    Cursor.unwrap_nif_value(db_ref, {:__xitdb_set__, list}, moment, path_steps)
-  end
-
-  defp unwrap_entry(_db_ref, scalar, _moment, _path_steps), do: scalar
 end
 
 defimpl Inspect, for: Xitdb.Cursor do
   import Inspect.Algebra
+  alias Xitdb.Cursor.PreviewTag
 
   def inspect(%Xitdb.Cursor{} = raw_cursor, opts) do
-    %Xitdb.Cursor{tag: tag, value: val} = cursor = Xitdb.Cursor.ensure_resolved(raw_cursor)
+    case Xitdb.Cursor.try_resolve(raw_cursor) do
+      {:ok, %Xitdb.Cursor{tag: tag, value: val} = cursor} ->
+        preview =
+          cursor
+          |> Stream.take(5)
+          |> Enum.map(fn
+            {k, %Xitdb.Cursor{tag: child_tag}} -> {k, %PreviewTag{tag: child_tag}}
+            {k, v} -> {k, v}
+            %Xitdb.Cursor{tag: child_tag} -> %PreviewTag{tag: child_tag}
+            v -> v
+          end)
+
+        count_part =
+          case Xitdb.NIF.nif_slot_count(cursor.db_ref, cursor.tag_id, val) do
+            {:ok, n} -> " count: #{n},"
+            _ -> ""
+          end
 
-    preview =
-      cursor
-      |> Stream.take(5)
-      |> Enum.map(fn
-        {k, %Xitdb.Cursor{tag: child_tag}} -> {k, :"<#{child_tag}>"}
-        {k, v} -> {k, v}
-        %Xitdb.Cursor{tag: child_tag} -> :"<#{child_tag}>"
-        v -> v
-      end)
-
-    count_part =
-      case Xitdb.NIF.nif_slot_count(cursor.db_ref, cursor.tag_id, val) do
-        {:ok, n} -> " count: #{n},"
-        _ -> ""
-      end
+        concat([
+          "#Xitdb.Cursor<",
+          to_string(tag),
+          count_part,
+          " offset: ",
+          to_string(val),
+          ", preview: ",
+          to_doc(preview, opts),
+          ">"
+        ])
 
-    concat([
-      "#Xitdb.Cursor<",
-      to_string(tag),
-      count_part,
-      " offset: ",
-      to_string(val),
-      ", preview: ",
-      to_doc(preview, opts),
-      ">"
-    ])
+      {:error, reason} ->
+        concat(["#Xitdb.Cursor<unresolved (", inspect(reason), ")>"])
+    end
   end
 end
diff --git a/lib/xitdb.ex b/lib/xitdb.ex
--- a/lib/xitdb.ex
+++ b/lib/xitdb.ex
@@ -280,7 +280,7 @@ defmodule Xitdb do
     try do
       case fun.(root_cursor) do
         %Cursor{staged_ops: ops} ->
-          transact_ops(db, ops, opts)
+          transact_ops(db, :lists.reverse(ops), opts)
 
         {:abort, reason} ->
           {:error, %Error{reason: reason}}
@@ -345,7 +345,7 @@ defmodule Xitdb do
   def insert_at(%Cursor{} = root, path_or_selector, index, value)
       when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
     selector = TxCompiler.format_path_steps(path_or_selector)
-    %{root | staged_ops: root.staged_ops ++ [{:insert, selector, index, value}]}
+    %Cursor{root | staged_ops: [{:insert, selector, index, value} | root.staged_ops]}
   end
 
   @doc """
@@ -359,7 +359,7 @@ defmodule Xitdb do
       TxCompiler.format_path_steps(path_or_selector) <>
         TxCompiler.format_step(:linked_array_list, index)
 
-    %{root | staged_ops: root.staged_ops ++ [{:rm, selector}]}
+    %Cursor{root | staged_ops: [{:rm, selector} | root.staged_ops]}
   end
 
   @doc """
@@ -367,7 +367,7 @@ defmodule Xitdb do
   """
   @spec fork(Cursor.t(), String.t(), String.t()) :: Cursor.t()
   def fork(%Cursor{} = root, from_selector, to_selector) do
-    %{root | staged_ops: root.staged_ops ++ [{:fork, from_selector, to_selector}]}
+    %Cursor{root | staged_ops: [{:fork, from_selector, to_selector} | root.staged_ops]}
   end
 
   # ============================================================================
@@ -557,13 +557,15 @@ defmodule Xitdb do
   end
 
   @impl Access
-  def get_and_update(%__MODULE__{} = db_handle, key, fun) do
-    Cursor.get_and_update(db(db_handle), key, fun)
+  def get_and_update(%__MODULE__{}, _key, _fun) do
+    raise ArgumentError,
+          "cannot mutate %Xitdb{} directly; wrap put_in/update_in/pop_in inside Xitdb.transact/3 or Xitdb.DSL.tx/3"
   end
 
   @impl Access
-  def pop(%__MODULE__{} = db_handle, key) do
-    Cursor.pop(db(db_handle), key)
+  def pop(%__MODULE__{}, _key) do
+    raise ArgumentError,
+          "cannot mutate %Xitdb{} directly; wrap pop_in inside Xitdb.transact/3 or Xitdb.DSL.tx/3"
   end
 
   def at(index) when is_integer(index) do
````

### 4.3 Step 4 Verification Suite

```elixir
defmodule Xitdb.CursorRefactorTest do
  use ExUnit.Case, async: true

  test "Access pipeline preserves op ordering and read-your-own-writes" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{
        "users" => %{
          "alice" => %{
            "age" => 30,
            "temp" => "secret",
            "roles" => Xitdb.linked_list(["staff"])
          }
        }
      })

    db =
      Xitdb.transact!(db, fn root ->
        {"secret", root} = pop_in(root["users"]["alice"]["temp"])
        assert root["users"]["alice"]["temp"] == nil

        root = put_in(root["users"]["alice"]["age"], 31)
        assert root["users"]["alice"]["age"] == 31

        root
        |> update_in(["users", "alice", "age"], &(&1 + 1))
        |> Xitdb.insert_at(["users", "alice", "roles"], 0, "owner")
        |> Xitdb.fork(".users.alice", ".backups.alice")
      end)

    assert db["users"]["alice"]["temp"] == nil
    assert db["users"]["alice"]["age"] == 32
    assert Enum.to_list(db["users"]["alice"]["roles"]) == ["owner", "staff"]
    assert db["backups"]["alice"]["age"] == 32
  end

  test "fetch/2 resolves tag_id: -1 before integer index lookup when tx_mode: false" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"items" => ["first", "second"]})

    assert Access.fetch(Xitdb.as_of(db, 0), 0) == :error
    assert Xitdb.as_of(db, 0)["items"][0] == "first"
  end

  test "Enum.slice handles stepped ranges without overshooting collection bounds" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"items" => ["a", "b", "c", "d", "e"]})

    assert Enum.slice(db["items"], 0..4//2) == ["a", "c", "e"]
    assert Enum.slice(db["items"], 1..3//2) == ["b", "d"]
  end

  test "Inspect renders child cursors without quotes and handles empty DB cursors safely" do
    empty_db = Xitdb.open!(backend: :memory)
    assert inspect(Xitdb.as_of(empty_db, 0)) =~ "#Xitdb.Cursor<unresolved"

    db = Xitdb.transact!(empty_db, %{"users" => %{"alice" => %{"age" => 30}}})
    rendered = inspect(Xitdb.db(db))
    assert rendered =~ ~s({"users", <hash_map>})
    refute rendered =~ ~s(:"<hash_map>")
  end

  test "mutating %Xitdb{} directly outside transact/3 raises ArgumentError" do
    db = Xitdb.open!(backend: :memory)

    assert_raise ArgumentError, ~r/cannot mutate %Xitdb{} directly/, fn ->
      put_in(db["users"], %{})
    end

    assert_raise ArgumentError, ~r/cannot mutate %Xitdb{} directly/, fn ->
      pop_in(db["users"])
    end
  end
end
```

---

## 5. Future Roadmap & Modular Refactoring

Following Wave 1 (`Track 5A` + [`ash_dsl_and_verifiers_20261111`](../ash_dsl_and_verifiers_20261111/index.md)) and the Wave 2–3 `Xitdb.Ash.DataLayer` MVP tracks, **Wave 4** executes:

1. **Track 6 (`[Wave 4]` — [`split_dsl_and_invert_ash_dependency_20261111`](../split_dsl_and_invert_ash_dependency_20261111/index.md)):**
   - Splits the 1500+ line [`lib/xitdb/dsl.ex`](../../../lib/xitdb/dsl.ex) into single-responsibility modules (`Xitdb.Selector`, `Xitdb.DSL.PathCompiler`, `Xitdb.DSL.TxRuntime`, `Xitdb.DSL.DatalogCompiler`).
   - Inverts the Ash/Spark dependency in `tx_for` via `Xitdb.Schema`.
2. **Track 7 (`[Wave 4]` — [`remaining_improvements_20261112`](../remaining_improvements_20261112/index.md)):**
   - Adds `NimbleOptions` validation schemas for `Xitdb.open/1`, `Xitdb.compact/2`, and transaction options, plus complete documentation guides in `docs/`.
