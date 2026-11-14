# Reference: Step 4 — Cursor Deduplication, Opaque MapSet, Stepped Enum.slice & O(1) Staging

> [!IMPORTANT]
> **Step Metadata:**
> - **Track:** [`client_fixes_and_dedup_20261111`](../index.md)
>   - **Track 5A (`[Wave 1]` MVP Scope):** `O(1)` `staged_ops` prepending + commit reversal, `Cursor.fetch/2` integer index resolution when `tx_mode: false`, `MapSet.size/1` opacity fix, and direct `%Xitdb{}` mutation guard
>   - **Track 5B (`[Wave 4]` Deferred Scope):** `Cursor` `fetch/2` + `unwrap_entry/4` deduplication, exact stepped `Enumerable.slice/1`, and atom-free `PreviewTag` `Inspect`
> - **Target Modules:** [`lib/xitdb/cursor.ex`](../../../../lib/xitdb/cursor.ex), [`lib/xitdb.ex`](../../../../lib/xitdb.ex)
> - **Test Suite:** `test/xitdb/cursor_refactor_test.exs`

---

## 1. Architectural Motivation & Summary

Step 4 cleans up [`lib/xitdb/cursor.ex`](../../../../lib/xitdb/cursor.ex) and the transactional `Access` plumbing in [`lib/xitdb.ex`](../../../../lib/xitdb.ex):

1. **O(1) `staged_ops` Accumulation & Cross-Caller Audit (Wave 1 — Track 5A):**
   - Accumulates `Cursor.staged_ops` in reverse order via `[op | staged_ops]` and `:lists.reverse(new_ops, staged_ops)` across `Cursor.get_and_update/3`, `Cursor.pop/2`, `Xitdb.insert_at/4`, `Xitdb.delete_at/3`, and `Xitdb.fork/3`—reversing once on commit via `:lists.reverse(ops)` in `Xitdb.transact/3`.
   - **Caller Audit (`lib/xitdb/dsl.ex`):** `Xitdb.DSL.tx/2,3` and `tx_for/3,4` do **not** read or write `%Cursor{}.staged_ops`; `lib/xitdb/dsl.ex` maintains its own process-dictionary `%{index_ops: [...], ops: [...]}` lists (which already prepend in `O(1)` and reverse once in `__commit_tx_state__/1`: `:lists.reverse(index_ops) ++ :lists.reverse(ops)`). Therefore, operations never execute backwards in either `Xitdb.transact/3` or `Xitdb.DSL.tx/3`.
   - Raises a clear `ArgumentError` if `put_in`/`update_in`/`pop_in` is called directly on `%Xitdb{}` outside `transact/3`.

2. **Integer Key Resolution When `tx_mode: false` (Wave 1 — Track 5A):**
   - `Xitdb.as_of(db, 0)` (and `Xitdb.db(db)`) returns a lazy root `%Cursor{tag_id: -1, moment: 0, tx_mode: false}`. While `nif_slot_get_key` handles `tag_id == -1` in the NIF, `nif_slot_get_index` requires a resolved slot `tag_id`.
   - Calling `ensure_resolved(cursor)` before `NIF.nif_slot_get_index/4` whenever `is_integer(key)` (in **both** `tx_mode: false` and `tx_mode: true`, centralized in `nif_slot_get/2`) guarantees `Xitdb.as_of(db, 0)[0]` resolves cleanly without passing `tag_id: -1` to `nif_slot_get_index`.

3. **Opaque `MapSet` Compliance in Wave 1 (Elixir 1.19/1.20+ — Track 5A):**
   - Replaces `map_size(cursor.deleted_paths.map) == 0` with `MapSet.size(deleted) == 0` in Wave 1 so `mix compile --warnings-as-errors` under Elixir 1.19/1.20 never fails on private `MapSet` struct opacity.

4. **Deduplicated Cursor Construction & `Access.fetch/2` (Wave 4 — Track 5B):**
   - Collapses the 4 repetitive `Cursor.fetch/2` clauses and 6 inline `%Cursor{}` tuple unpackings into `from_nif_tuple/4`, `unwrap_nif_value/4`, `nif_slot_get/2`, and `lookup_staged/2` (preserving direct single-hop NIF resolution for string keys on `tag_id: -1` root cursors).

5. **Exact Stepped Slicing in `Enumerable.slice/1` & Atom-Free `Inspect` (Wave 4 — Track 5B):**
   - Fetches `(length - 1) * step + 1` elements instead of `length * step`, filters via `Enum.take_every/2` *before* allocating `%Cursor{}` / `MapSet` wrappers, handles zero-length slices without a NIF round-trip, and raises `Xitdb.Error` cleanly on NIF errors.
   - Replaces dynamic atom creation (`:"<#{child_tag}>"`) in `Inspect` for `Xitdb.Cursor` with a private `PreviewTag` struct and safely renders unresolved cursors (`Xitdb.as_of(empty_db, 0)`) without raising inside `inspect/2`.

---

## 2. Step 4 Code Changes (`diff`)

> [!NOTE]
> When applying **Track 5A (Wave 1)** prior to Track 5B, ensure `MapSet.size(cursor.deleted_paths) == 0`, `ensure_resolved/1` before `nif_slot_get_index`, `O(1)` `staged_ops` prepending + `:lists.reverse(ops)` in `Xitdb.transact/3`, and the `%Xitdb{}` `Access.get_and_update/3` / `pop/2` `ArgumentError` guards are included immediately—or apply the complete self-contained diff below directly.

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

---

## 3. Verification Suite

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

    # Unresolved moment cursor with integer lookup returns :error cleanly on map root
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
