# Reference: Step 1 — Error Helpers, `NimbleOptions` Validation, `:index_rules`, Root-Cursor Guard & IEx Docs

> [!IMPORTANT]
> **Step Metadata:**
> - **Parent Track:** [`remaining_improvements_20261112`](../index.md)
> - **Wave:** Wave 4 (after [`split_dsl_and_invert_ash_dependency_20261111`](../../split_dsl_and_invert_ash_dependency_20261111/index.md))
> - **Target Modules:** [`lib/xitdb/error.ex`](../../../../lib/xitdb/error.ex), [`lib/xitdb.ex`](../../../../lib/xitdb.ex), [`lib/xitdb/cursor.ex`](../../../../lib/xitdb/cursor.ex), [`lib/xitdb/collection.ex`](../../../../lib/xitdb/collection.ex), `lib/xitdb/dsl/tx_rewriter.ex`, `lib/xitdb/dsl/tx_runtime.ex`
> - **Test Suite:** `test/xitdb/options_and_cursor_guard_test.exs`

---

## 1. Architectural Motivation & Summary

* **Centralized error helpers (`lib/xitdb/error.ex`):** Adds `Error.wrap/2` (handling `:ok`, `{:ok, val}`, `{:error, %Error{}}`, `{:error, reason}`, `%Error{}`, and bare atom/string `reason`) and `Error.unwrap!/1`, collapsing all seven bang wrappers (`open!/1`, `info!/1`, `transact!/3`, `select!/2`, `pull!/2`, `query!/3`, `compact!/2`), NIF error-wrapping `case` blocks, `validate_opts/2`, and `TxRewriter.wrap_bang/1`.

* **Compile-time `NimbleOptions` schemas & eager `tx` validation (`lib/xitdb.ex`, `lib/xitdb/dsl/tx_runtime.ex`):**
  - Defines `@transact_schema`, `@query_schema` (**without** `default: -1` on `:moment`, so `Xitdb.query(%Cursor{moment: m}, ...)` preserves `m`), and `@compact_schema` via `NimbleOptions.new!/1`.
  - Defines `defp validate_opts(opts, schema)` explicitly for both keyword lists and non-list values, and exposes `@doc false` `validate_transact_opts/1` called eagerly inside `TxRuntime.init_state/3` so invalid `tx` options fail immediately as `:invalid_options` before `read_current_value/2` ever runs.

* **Unified `:index_rules` across all four transaction paths (`lib/xitdb.ex`):** Normalizes `validated[:index_rules]` inside `do_transact_ops/3` (`{:index_on, to_string(src), to_string(field), to_string(idx)}`), deduplicates against any `{:index_on, ...}` ops already present in `ops`, and passes `Keyword.delete(validated, :index_rules)` to `TxCompiler.compile_moment_map/2` so map transactions, `%Cursor{}` callbacks, map-returning callbacks, and `transact_ops/3` (`tx` / `tx_for`) all honor `:index_rules` identically without double-emitting `{:index_on, ...}`.

* **Root snapshot & `tx_mode` guard on `Xitdb.select/2` (`lib/xitdb.ex`, `lib/xitdb/cursor.ex`):** Adds `root: false` to `%Xitdb.Cursor{}`, marks committed root snapshots from `Xitdb.db/1` and `Xitdb.as_of/2` with `root: true`, and guards `Xitdb.select/2` on `%Cursor{root: true, tx_mode: false}`—rejecting both nested child sub-cursors (`root: false`) and in-flight transaction cursors (`tx_mode: true`) with `{:error, %Xitdb.Error{reason: :non_root_cursor}}` so `select/2` never silently bypasses staged transaction writes.

* **Complete `@spec`s, documented `Xitdb.at/1` & IEx-clean `@doc` formatting:** Updates `@spec transact/3` and `transact!/3` callback return unions to `Cursor.t() | map() | {:abort, term()}`, adds `@doc` and `@spec` to `Xitdb.at/1`, links the seven guide documents in `Xitdb`'s `@moduledoc`, and replaces raw LaTeX math in docstrings with inline code spans (`` `O(1)` ``, `` `O(log N)` ``).

---

## 2. Step 1 Code Changes (`diff`)

````diff
diff --git a/lib/xitdb/collection.ex b/lib/xitdb/collection.ex
--- a/lib/xitdb/collection.ex
+++ b/lib/xitdb/collection.ex
@@ -5,12 +5,12 @@ defmodule Xitdb.Collection do
 
   Supported `:kind` values:
   - `:hash_map` — 16-way HAMT (`Tag.Hash_Map`, `.key`)
-  - `:counted_hash_map` — 16-way HAMT with $O(1)$ count header (`Tag.Counted_Hash_Map`, `#key`)
+  - `:counted_hash_map` — 16-way HAMT with `O(1)` count header (`Tag.Counted_Hash_Map`, `#key`)
   - `:sorted_map` — Count-augmented B+Tree ordered lexicographically (`Tag.Sorted_Map`, `$key`)
   - `:array_list` — 16-way Radix Trie (`Tag.Array_List`, `[i]`)
-  - `:linked_array_list` — Count-augmented B-Tree with $O(\\log N)$ insert/remove/slice (`Tag.Linked_Array_List`, `[[i]]`)
+  - `:linked_array_list` — Count-augmented B-Tree with `O(log N)` insert/remove/slice (`Tag.Linked_Array_List`, `[[i]]`)
   - `:hash_set` — 16-way HAMT set (`Tag.Hash_Set`, `%member`)
-  - `:counted_hash_set` — 16-way HAMT set with $O(1)$ count header (`Tag.Counted_Hash_Set`, `#%member`)
+  - `:counted_hash_set` — 16-way HAMT set with `O(1)` count header (`Tag.Counted_Hash_Set`, `#%member`)
   - `:sorted_set` — Count-augmented B+Tree set (`Tag.Sorted_Set`, `^member`)
   """
   @enforce_keys [:kind, :data]
diff --git a/lib/xitdb/cursor.ex b/lib/xitdb/cursor.ex
--- a/lib/xitdb/cursor.ex
+++ b/lib/xitdb/cursor.ex
@@ -8,8 +8,8 @@ defmodule Xitdb.Cursor do
   - Can be passed across BEAM processes (`Task.async/1`, GenServers, ETS, LiveView assigns)
     with zero mutexes or dangling pointer hazards.
   - Implements `Access` (`cursor["key"]`, `cursor[0]`, `get_in/2`, `put_in/3`, `update_in/3`, `pop_in/2`).
-  - Implements `Enumerable` (`Enum.count/1` in $O(1)$ on counted collections,
-    `Enum.member?/2` in $O(1)$ / $O(\\log N)$ via HAMT/B+Tree lookup,
-    `Enum.slice/2` in $O(\\log N)$ via index seek, and `Enum.to_list/1` / `Stream.*`).
+  - Implements `Enumerable` (`Enum.count/1` in `O(1)` on counted collections,
+    `Enum.member?/2` in `O(1)` / `O(log N)` via HAMT/B+Tree lookup,
+    `Enum.slice/2` in `O(log N)` via index seek, and `Enum.to_list/1` / `Stream.*`).
   - Implements `Inspect` with a safe, bounded preview.
   """
@@ -26,6 +26,7 @@ defmodule Xitdb.Cursor do
     :value,
     full: false,
     moment: -1,
+    root: false,
     tx_mode: false,
     path_steps: [],
     staged_ops: [],
@@ -40,6 +41,7 @@ defmodule Xitdb.Cursor do
           value: integer(),
           full: boolean(),
           moment: integer(),
+          root: boolean(),
           tx_mode: boolean(),
           path_steps: [{atom(), String.t() | integer()}],
           staged_ops: list(),
diff --git a/lib/xitdb/dsl/tx_rewriter.ex b/lib/xitdb/dsl/tx_rewriter.ex
--- a/lib/xitdb/dsl/tx_rewriter.ex
+++ b/lib/xitdb/dsl/tx_rewriter.ex
@@ -72,10 +72,7 @@ defmodule Xitdb.DSL.TxRewriter do
 
   defp wrap_bang(tx_quoted) do
     quote do
-      case unquote(tx_quoted) do
-        {:ok, updated_db} -> updated_db
-        {:error, err} -> raise err
-      end
+      Xitdb.Error.unwrap!(unquote(tx_quoted))
     end
   end
 
diff --git a/lib/xitdb/dsl/tx_runtime.ex b/lib/xitdb/dsl/tx_runtime.ex
--- a/lib/xitdb/dsl/tx_runtime.ex
+++ b/lib/xitdb/dsl/tx_runtime.ex
@@ -1,29 +1,23 @@
 defmodule Xitdb.DSL.TxRuntime do
   @moduledoc false
 
-  alias Xitdb.{Collection, Cursor, Error, NIF, TxCompiler}
+  alias Xitdb.{Collection, Cursor, NIF, TxCompiler}
 
   @enforce_keys [:db, :opts]
   defstruct [:db, :opts, index_ops: [], ops: [], staged_log: nil]
 
   def init_state(db, opts, track_staged? \\ false) do
-    if is_list(opts) do
+    with {:ok, validated} <- Xitdb.validate_transact_opts(opts) do
       tx_ref = make_ref()
 
       state = %__MODULE__{
         db: db,
-        opts: opts,
+        opts: validated,
         staged_log: if(track_staged?, do: [], else: nil)
       }
 
       Process.put(tx_ref, state)
       {:ok, tx_ref}
-    else
-      {:error,
-       %Error{
-         reason: :invalid_options,
-         details: %{message: "expected keyword list of options, got: #{inspect(opts)}"}
-       }}
     end
   end
 
diff --git a/lib/xitdb/error.ex b/lib/xitdb/error.ex
--- a/lib/xitdb/error.ex
+++ b/lib/xitdb/error.ex
@@ -1,15 +1,15 @@
 defmodule Xitdb.Error do
   @moduledoc """
-  Structured exception returned or raised when a `Xitdb` operation fails.
+  Exception and error struct returned by `Xitdb` operations.
   """
   defexception [:reason, :details]
 
   @type t :: %__MODULE__{
           reason: atom() | String.t(),
-          details: map() | nil
+          details: term()
         }
 
-  @impl Exception
+  @impl true
   def message(%__MODULE__{reason: reason, details: nil}) do
     "Xitdb operation failed: #{inspect(reason)}"
   end
@@ -17,4 +17,28 @@ defmodule Xitdb.Error do
   def message(%__MODULE__{reason: reason, details: details}) do
     "Xitdb operation failed (#{inspect(reason)}): #{inspect(details)}"
   end
+
+  @doc false
+  @spec wrap(:ok | {:ok, val} | {:error, term()} | atom() | String.t(), map() | nil) ::
+          :ok | {:ok, val} | {:error, t()} | t()
+        when val: var
+  def wrap(result, details \\ nil)
+  def wrap(:ok, _details), do: :ok
+  def wrap({:ok, _} = ok, _details), do: ok
+  def wrap({:error, %__MODULE__{}} = err, _details), do: err
+
+  def wrap({:error, reason}, details) do
+    {:error, %__MODULE__{reason: reason, details: details}}
+  end
+
+  def wrap(%__MODULE__{} = err, _details), do: err
+
+  def wrap(reason, details) when is_atom(reason) or is_binary(reason) do
+    %__MODULE__{reason: reason, details: details}
+  end
+
+  @doc false
+  @spec unwrap!({:ok, val} | {:error, Exception.t()}) :: val when val: var
+  def unwrap!({:ok, val}), do: val
+  def unwrap!({:error, err}), do: raise(err)
 end
diff --git a/lib/xitdb.ex b/lib/xitdb.ex
--- a/lib/xitdb.ex
+++ b/lib/xitdb.ex
@@ -7,6 +7,15 @@ defmodule Xitdb do
   Elixir's `Access`, `Enumerable`, and `Inspect` protocols—allowing you to navigate
   and query on-disk data structures (`Hash_Map`, `Counted_Hash_Map`, `Sorted_Map`,
   `Array_List`, `Linked_Array_List`, and sets) just like standard Elixir maps and lists.
+
+  ## Guides
+  - [Lazy Cursors, `Access` & `Enumerable`](docs/access-and-enumerable.md)
+  - [Collections, Data Modeling & Secondary Indexes](docs/collections-and-indexing.md)
+  - [Path Selector & Structural Pull DSL](docs/path-and-pull-dsl.md)
+  - [Declarative Transaction Block DSL](docs/transaction-dsl.md)
+  - [Declarative Datalog Query DSL](docs/datalog-dsl.md)
+  - [Time-Travel, Structural Diffs, Lineage & Storage Lifecycle](docs/time-travel-and-storage.md)
+  - [Ash & Spark Integration](docs/ash-and-spark.md)
   """
 
   @behaviour Access
@@ -80,6 +89,58 @@ defmodule Xitdb do
                  ]
                )
 
+  @index_rule_type {:tuple,
+                    [
+                      {:in, [:index_on]},
+                      {:or, [:atom, :string]},
+                      {:or, [:atom, :string]},
+                      {:or, [:atom, :string]}
+                    ]}
+
+  @transact_schema NimbleOptions.new!(
+                     doc: [
+                       type: :string,
+                       default: "",
+                       doc: "Commit message stored in `__tx.doc`."
+                     ],
+                     instant: [
+                       type: :integer,
+                       doc: "Epoch timestamp in milliseconds stored in `__tx.tx_instant`."
+                     ],
+                     meta: [
+                       type: {:or, [:map, :keyword_list]},
+                       doc: "Custom commit metadata stored under `__tx.<key>`."
+                     ],
+                     base_moment: [
+                       type: :integer,
+                       default: -1,
+                       doc: "Historical moment index to branch from (`-1` for latest)."
+                     ],
+                     index_rules: [
+                       type: {:list, @index_rule_type},
+                       default: [],
+                       doc:
+                         "Secondary B+Tree index rules (`[{:index_on, source_map, field, index_map}]`)."
+                     ]
+                   )
+
+  @query_schema NimbleOptions.new!(
+                  moment: [
+                    type: :integer,
+                    doc:
+                      "Historical moment index to query (`-1` for latest; defaults to cursor moment when querying a `%Xitdb.Cursor{}`)."
+                  ]
+                )
+
+  @compact_schema NimbleOptions.new!(
+                    path: [
+                      type: :string,
+                      default: "",
+                      doc:
+                        "Destination file path for compacted database (compacts into `:memory` when empty)."
+                    ]
+                  )
+
   @enforce_keys [:db_ref, :backend]
   defstruct [:db_ref, :backend, :path, hash: :sha1]
 
@@ -123,12 +184,7 @@ defmodule Xitdb do
 
   @doc "Same as `open/1`, but raises `Xitdb.Error` on failure."
   @spec open!(keyword()) :: t()
-  def open!(opts \\ []) do
-    case open(opts) do
-      {:ok, db} -> db
-      {:error, err} -> raise err
-    end
-  end
+  def open!(opts \\ []), do: opts |> open() |> Error.unwrap!()
 
   @doc "Flushes and closes the underlying `xitdb` storage handle."
   @spec close(t()) :: :ok
@@ -139,29 +195,18 @@ defmodule Xitdb do
   @doc "Synchronizes buffered writes to disk."
   @spec sync(t()) :: :ok | {:error, Error.t()}
   def sync(%__MODULE__{db_ref: db_ref}) do
-    case NIF.nif_sync(db_ref) do
-      :ok -> :ok
-      {:error, reason} -> {:error, %Error{reason: reason}}
-    end
+    db_ref |> NIF.nif_sync() |> Error.wrap()
   end
 
   @doc "Returns database metadata (`%{moment_count: integer(), file_size: integer()}`)."
   @spec info(t()) :: {:ok, map()} | {:error, Error.t()}
   def info(%__MODULE__{db_ref: db_ref}) do
-    case NIF.nif_info(db_ref) do
-      {:ok, map} -> {:ok, map}
-      {:error, reason} -> {:error, %Error{reason: reason}}
-    end
+    db_ref |> NIF.nif_info() |> Error.wrap()
   end
 
   @doc "Same as `info/1`, but raises `Xitdb.Error` on failure."
   @spec info!(t()) :: map()
-  def info!(%__MODULE__{} = db) do
-    case info(db) do
-      {:ok, map} -> map
-      {:error, err} -> raise err
-    end
-  end
+  def info!(%__MODULE__{} = db), do: db |> info() |> Error.unwrap!()
 
   @doc "Returns the number of committed historical moments in `db`."
   @spec moment_count(t()) :: non_neg_integer()
@@ -195,14 +240,16 @@ defmodule Xitdb do
       tag: :hash_map,
       tag_id: -1,
       value: moment_index,
-      moment: moment_index
+      moment: moment_index,
+      root: true
     }
   end
 
   def as_of(%__MODULE__{db_ref: db_ref}, moment_index) when is_integer(moment_index) do
     case NIF.nif_moment_slot(db_ref, moment_index) do
       {:ok, tuple} ->
-        Cursor.from_nif_tuple(db_ref, tuple, moment_index)
+        cursor = Cursor.from_nif_tuple(db_ref, tuple, moment_index)
+        %Cursor{cursor | root: true}
 
       {:error, reason} ->
         raise Error, reason: reason, details: %{moment_index: moment_index}
@@ -217,7 +264,7 @@ defmodule Xitdb do
   @spec hash_map(Enumerable.t()) :: Collection.t()
   def hash_map(map), do: %Collection{kind: :hash_map, data: map}
 
-  @doc "Wraps `map` to be stored as a `Counted_Hash_Map` with $O(1)$ `Enum.count/1`."
+  @doc "Wraps `map` to be stored as a `Counted_Hash_Map` with `O(1)` `Enum.count/1`."
   @spec counted_map(Enumerable.t()) :: Collection.t()
   def counted_map(map), do: %Collection{kind: :counted_hash_map, data: map}
 
@@ -237,7 +284,7 @@ defmodule Xitdb do
   @spec hash_set(Enumerable.t()) :: Collection.t()
   def hash_set(members), do: %Collection{kind: :hash_set, data: members}
 
-  @doc "Wraps `members` to be stored as a `Counted_Hash_Set` with $O(1)$ `Enum.count/1`."
+  @doc "Wraps `members` to be stored as a `Counted_Hash_Set` with `O(1)` `Enum.count/1`."
   @spec counted_set(Enumerable.t()) :: Collection.t()
   def counted_set(members), do: %Collection{kind: :counted_hash_set, data: members}
 
@@ -255,55 +302,65 @@ defmodule Xitdb do
   Accepts either:
   - A map of top-level keys/subtrees (`Xitdb.transact(db, %{"users" => ...}, opts)`), or
   - A 1-arity callback receiving the root `%Xitdb.Cursor{}` (`Xitdb.transact(db, fn root -> put_in(root["a"]["b"], 1) end)`).
+
+  ## Options
+  #{NimbleOptions.docs(@transact_schema)}
   """
-  @spec transact(t(), map() | (Cursor.t() -> Cursor.t() | {:abort, term()}), keyword()) ::
+  @spec transact(t(), map() | (Cursor.t() -> Cursor.t() | map() | {:abort, term()}), keyword()) ::
           {:ok, t()} | {:error, Error.t()}
   def transact(db, map_or_fun, opts \\ [])
 
   def transact(%__MODULE__{} = db, map, opts) when is_map(map) and not is_struct(map) do
-    ops = TxCompiler.compile_moment_map(map, opts)
-    transact_ops(db, ops, opts)
+    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
+      ops = TxCompiler.compile_moment_map(map, Keyword.delete(validated, :index_rules))
+      do_transact_ops(db, ops, validated)
+    end
   end
 
   def transact(%__MODULE__{db_ref: db_ref} = db, fun, opts) when is_function(fun, 1) do
-    base_moment = Keyword.get(opts, :base_moment, -1)
-
-    root_cursor = %Cursor{
-      db_ref: db_ref,
-      tag: :hash_map,
-      tag_id: -1,
-      value: base_moment,
-      moment: base_moment,
-      tx_mode: true
-    }
+    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
+      base_moment = validated[:base_moment]
+
+      root_cursor = %Cursor{
+        db_ref: db_ref,
+        tag: :hash_map,
+        tag_id: -1,
+        value: base_moment,
+        moment: base_moment,
+        root: true,
+        tx_mode: true
+      }
+
+      try do
+        case fun.(root_cursor) do
+          %Cursor{staged_ops: ops} ->
+            do_transact_ops(db, :lists.reverse(ops), validated)
+
+          {:abort, reason} ->
+            {:error, %Error{reason: reason}}
 
-    try do
-      case fun.(root_cursor) do
-        %Cursor{staged_ops: ops} ->
-          transact_ops(db, :lists.reverse(ops), opts)
+          other when is_map(other) and not is_struct(other) ->
+            ops = TxCompiler.compile_moment_map(other, Keyword.delete(validated, :index_rules))
+            do_transact_ops(db, ops, validated)
 
-        {:abort, reason} ->
-          {:error, %Error{reason: reason}}
+          other ->
+            {:error, %Error{reason: :invalid_transaction_return, details: %{value: other}}}
+        end
+      rescue
+        e in Error ->
+          {:error, e}
 
-        other when is_map(other) ->
-          transact(db, other, opts)
+        e ->
+          {:error, %Error{reason: :transaction_exception, details: %{exception: e}}}
       end
-    rescue
-      e in Error ->
-        {:error, e}
-
-      e ->
-        {:error, %Error{reason: :transaction_exception, details: %{exception: e}}}
     end
   end
 
   @doc "Same as `transact/3`, but raises `Xitdb.Error` on failure."
-  @spec transact!(t(), map() | (Cursor.t() -> Cursor.t()), keyword()) :: t()
+  @spec transact!(t(), map() | (Cursor.t() -> Cursor.t() | map() | {:abort, term()}), keyword()) ::
+          t()
   def transact!(%__MODULE__{} = db, map_or_fun, opts \\ []) do
-    case transact(db, map_or_fun, opts) do
-      {:ok, db} -> db
-      {:error, err} -> raise err
-    end
+    db |> transact(map_or_fun, opts) |> Error.unwrap!()
   end
 
   @doc """
@@ -311,16 +368,35 @@ defmodule Xitdb do
   in a single atomic NIF transaction commit.
   """
   @spec transact_ops(t(), list(), keyword()) :: {:ok, t()} | {:error, Error.t()}
-  def transact_ops(%__MODULE__{db_ref: db_ref} = db, ops, opts \\ []) when is_list(ops) do
-    base_moment = Keyword.get(opts, :base_moment, -1)
-    doc = Keyword.get(opts, :doc, "")
+  def transact_ops(%__MODULE__{} = db, ops, opts \\ []) when is_list(ops) do
+    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
+      do_transact_ops(db, ops, validated)
+    end
+  end
+
+  defp do_transact_ops(%__MODULE__{db_ref: db_ref} = db, ops, validated) do
+    base_moment = validated[:base_moment]
+    doc = validated[:doc]
+
+    existing_index_ops =
+      for {:index_on, _, _, _} = op <- ops, into: MapSet.new(), do: op
+
+    index_ops =
+      validated
+      |> Keyword.get(:index_rules, [])
+      |> Enum.map(fn {:index_on, src, field, idx} ->
+        {:index_on, to_string(src), to_string(field), to_string(idx)}
+      end)
+      |> Enum.uniq()
+      |> Enum.reject(&MapSet.member?(existing_index_ops, &1))
 
     opt_ops =
-      case Keyword.get(opts, :instant) do
-        inst when is_integer(inst) -> [{:instant, inst}]
-        _ -> []
-      end ++
-        case Keyword.get(opts, :meta) do
+      index_ops ++
+        case validated[:instant] do
+          inst when is_integer(inst) -> [{:instant, inst}]
+          _ -> []
+        end ++
+        case validated[:meta] do
           meta when is_map(meta) or is_list(meta) ->
             Enum.map(meta, fn {k, v} -> {:meta, to_string(k), v} end)
 
@@ -335,7 +411,7 @@ defmodule Xitdb do
   end
 
   @doc """
-  Stages an $O(\\log N)$ insertion into a `Linked_Array_List` at `path_or_selector` and `index`
+  Stages an `O(log N)` insertion into a `Linked_Array_List` at `path_or_selector` and `index`
   on a root `%Xitdb.Cursor{}` inside `Xitdb.transact/2`.
 
   `path_or_selector` can be a selector string (`path(users[id].queue)`) or a list of keys /
@@ -349,7 +425,7 @@ defmodule Xitdb do
   end
 
   @doc """
-  Stages an $O(\\log N)$ removal from a `Linked_Array_List` at `path_or_selector` and `index`
+  Stages an `O(log N)` removal from a `Linked_Array_List` at `path_or_selector` and `index`
   on a root `%Xitdb.Cursor{}` inside `Xitdb.transact/2`.
   """
   @spec delete_at(Cursor.t(), String.t() | [term()], integer()) :: Cursor.t()
@@ -363,7 +439,7 @@ defmodule Xitdb do
   end
 
   @doc """
-  Stages an $O(1)$ zero-copy structural clone (`tx_fork`) from `from_selector` to `to_selector`.
+  Stages an `O(1)` zero-copy structural clone (`tx_fork`) from `from_selector` to `to_selector`.
   """
   @spec fork(Cursor.t(), String.t(), String.t()) :: Cursor.t()
   def fork(%Cursor{} = root, from_selector, to_selector) do
@@ -398,17 +474,27 @@ defmodule Xitdb do
   def materialize(scalar), do: scalar
 
   @doc """
-  Resolves a canonical `xitdb` selector string (`~x|.users["101"].todos[1]|`) against `db` or a `%Xitdb.Cursor{}`.
+  Resolves a canonical root-anchored `xitdb` selector string (`~x|.users["101"].todos[1]|`)
+  against `db` or a committed root snapshot `%Xitdb.Cursor{}` (from `Xitdb.db/1` or `Xitdb.as_of/2`).
   """
   @spec select(t() | Cursor.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
   def select(%__MODULE__{db_ref: db_ref}, selector) when is_binary(selector) do
     do_select(db_ref, -1, selector)
   end
 
-  def select(%Cursor{db_ref: db_ref, moment: moment}, selector) when is_binary(selector) do
+  def select(%Cursor{root: true, tx_mode: false, db_ref: db_ref, moment: moment}, selector)
+      when is_binary(selector) do
     do_select(db_ref, moment, selector)
   end
 
+  def select(%Cursor{tag: tag, tx_mode: tx_mode}, selector) when is_binary(selector) do
+    {:error,
+     %Error{
+       reason: :non_root_cursor,
+       details: %{tag: tag, tx_mode: tx_mode, selector: selector}
+     }}
+  end
+
   defp do_select(db_ref, moment, selector) do
     case NIF.nif_select(db_ref, moment, selector) do
       {:ok, raw} -> {:ok, Cursor.unwrap_nif_value(db_ref, raw, moment, [])}
@@ -418,12 +504,7 @@ defmodule Xitdb do
 
   @doc "Same as `select/2`, but raises `Xitdb.Error` on failure."
   @spec select!(t() | Cursor.t(), String.t()) :: term()
-  def select!(target, selector) do
-    case select(target, selector) do
-      {:ok, val} -> val
-      {:error, err} -> raise err
-    end
-  end
+  def select!(target, selector), do: target |> select(selector) |> Error.unwrap!()
 
   @doc """
   Executes a Datomic-style Pull projection against a `%Xitdb.Cursor{}` or `%Xitdb{}` handle.
@@ -439,10 +520,7 @@ defmodule Xitdb do
   def pull(%Cursor{} = cursor, pattern) when is_binary(pattern) do
     %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = Cursor.ensure_resolved(cursor)
 
-    case NIF.nif_pull(db_ref, tag_id, val, pattern) do
-      {:ok, projected} -> {:ok, projected}
-      {:error, reason} -> {:error, %Error{reason: reason, details: %{pattern: pattern}}}
-    end
+    db_ref |> NIF.nif_pull(tag_id, val, pattern) |> Error.wrap(%{pattern: pattern})
   end
 
   def pull(%Cursor{} = cursor, pattern) when is_list(pattern) do
@@ -453,24 +531,16 @@ defmodule Xitdb do
 
   @doc "Same as `pull/2`, but raises `Xitdb.Error` on failure."
   @spec pull!(t() | Cursor.t(), Pull.pattern()) :: term()
-  def pull!(target, pattern) do
-    case pull(target, pattern) do
-      {:ok, val} -> val
-      {:error, err} -> raise err
-    end
-  end
+  def pull!(target, pattern), do: target |> pull(pattern) |> Error.unwrap!()
 
   @doc """
   Computes the structural diff between `moment_a` and `moment_b`, skipping unchanged
-  subtrees in $O(1)$ via 9-byte `Slot` equality.
+  subtrees in `O(1)` via 9-byte `Slot` equality.
   """
   @spec diff_moments(t(), integer(), integer()) :: {:ok, [map()]} | {:error, Error.t()}
   def diff_moments(%__MODULE__{db_ref: db_ref}, moment_a, moment_b)
       when is_integer(moment_a) and is_integer(moment_b) do
-    case NIF.nif_diff_moments(db_ref, moment_a, moment_b) do
-      {:ok, changes} -> {:ok, changes}
-      {:error, reason} -> {:error, %Error{reason: reason}}
-    end
+    db_ref |> NIF.nif_diff_moments(moment_a, moment_b) |> Error.wrap()
   end
 
   @doc """
@@ -478,71 +548,70 @@ defmodule Xitdb do
   """
   @spec history_of(t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
   def history_of(%__MODULE__{db_ref: db_ref}, selector) when is_binary(selector) do
-    case NIF.nif_history_of(db_ref, selector) do
-      {:ok, entries} -> {:ok, entries}
-      {:error, reason} -> {:error, %Error{reason: reason, details: %{selector: selector}}}
-    end
+    db_ref |> NIF.nif_history_of(selector) |> Error.wrap(%{selector: selector})
   end
 
   @doc """
   Executes a Datalog query (`~q"find ?e, ?name where ..."`) against `db` or a `%Xitdb.Cursor{}`.
+
+  ## Options
+  #{NimbleOptions.docs(@query_schema)}
   """
   @spec query(t() | Cursor.t(), String.t(), keyword()) ::
           {:ok, %{vars: [String.t()], rows: [[term()]]}} | {:error, Error.t()}
   def query(target, query_str, opts \\ [])
 
   def query(%__MODULE__{db_ref: db_ref}, query_str, opts) when is_binary(query_str) do
-    moment = Keyword.get(opts, :moment, -1)
-    do_query(db_ref, moment, query_str)
+    with {:ok, validated} <- validate_opts(opts, @query_schema) do
+      moment = Keyword.get(validated, :moment, -1)
+      do_query(db_ref, moment, query_str)
+    end
   end
 
-  def query(%Cursor{db_ref: db_ref, moment: moment}, query_str, _opts)
+  def query(%Cursor{db_ref: db_ref, moment: cursor_moment}, query_str, opts)
       when is_binary(query_str) do
-    do_query(db_ref, moment, query_str)
+    with {:ok, validated} <- validate_opts(opts, @query_schema) do
+      moment = Keyword.get(validated, :moment, cursor_moment)
+      do_query(db_ref, moment, query_str)
+    end
   end
 
   defp do_query(db_ref, moment, query_str) do
-    case NIF.nif_query_datalog(db_ref, moment, query_str) do
-      {:ok, res} -> {:ok, res}
-      {:error, reason} -> {:error, %Error{reason: reason}}
-    end
+    db_ref |> NIF.nif_query_datalog(moment, query_str) |> Error.wrap()
   end
 
   @doc "Same as `query/3`, but raises `Xitdb.Error` on failure."
   @spec query!(t() | Cursor.t(), String.t(), keyword()) :: %{vars: [String.t()], rows: [[term()]]}
   def query!(target, query_str, opts \\ []) do
-    case query(target, query_str, opts) do
-      {:ok, res} -> res
-      {:error, err} -> raise err
-    end
+    target |> query(query_str, opts) |> Error.unwrap!()
   end
 
   @doc """
   Compacts `db` into a new database keeping only the latest committed moment and deduplicating
   reachable slots.
+
+  ## Options
+  #{NimbleOptions.docs(@compact_schema)}
   """
   @spec compact(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
   def compact(%__MODULE__{db_ref: db_ref, hash: hash}, opts \\ []) do
-    target_path = Keyword.get(opts, :path, "")
-    backend = if target_path == "", do: :memory, else: :buffered_file
+    with {:ok, validated} <- validate_opts(opts, @compact_schema) do
+      target_path = validated[:path]
+      backend = if target_path == "", do: :memory, else: :buffered_file
 
-    case NIF.nif_compact(db_ref, target_path) do
-      {:ok, new_ref} ->
-        {:ok, %__MODULE__{db_ref: new_ref, backend: backend, path: target_path, hash: hash}}
+      case NIF.nif_compact(db_ref, target_path) do
+        {:ok, new_ref} ->
+          {:ok, %__MODULE__{db_ref: new_ref, backend: backend, path: target_path, hash: hash}}
 
-      {:error, reason} ->
-        {:error, %Error{reason: reason}}
+        {:error, reason} ->
+          {:error, %Error{reason: reason}}
+      end
     end
   end
 
   @doc "Same as `compact/2`, but raises `Xitdb.Error` on failure."
   @spec compact!(t(), keyword()) :: t()
-  def compact!(%__MODULE__{} = db, opts \\ []) do
-    case compact(db, opts) do
-      {:ok, comp_db} -> comp_db
-      {:error, err} -> raise err
-    end
-  end
+  def compact!(%__MODULE__{} = db, opts \\ []), do: db |> compact(opts) |> Error.unwrap!()
 
   # ============================================================================
   # Access Delegation on `%Xitdb{}` (`db["users"]["alice"]`)
@@ -551,7 +620,7 @@ defmodule Xitdb do
   @impl Access
   def fetch(%__MODULE__{db_ref: db_ref}, key) do
     Cursor.fetch(
-      %Cursor{db_ref: db_ref, tag: :hash_map, tag_id: -1, value: -1, moment: -1},
+      %Cursor{db_ref: db_ref, tag: :hash_map, tag_id: -1, value: -1, moment: -1, root: true},
       key
     )
   end
@@ -568,6 +637,12 @@ defmodule Xitdb do
           "cannot mutate %Xitdb{} directly; wrap pop_in inside Xitdb.transact/3 or Xitdb.DSL.tx/3"
   end
 
+  @doc """
+  Returns an `Access` lens function for positive or negative integer list indices
+  that works on both `%Xitdb.Cursor{}` list collections and standard Elixir lists
+  (unlike `Access.at/1`, which guards `when is_list(data)`).
+  """
+  @spec at(integer()) :: Access.access_fun(Cursor.t() | list(), term())
   def at(index) when is_integer(index) do
     fn
       :get, data, next ->
@@ -581,13 +656,24 @@ defmodule Xitdb do
     end
   end
 
-  defp validate_opts(opts, schema) do
+  @doc false
+  @spec validate_transact_opts(term()) :: {:ok, keyword()} | {:error, Error.t()}
+  def validate_transact_opts(opts), do: validate_opts(opts, @transact_schema)
+
+  defp validate_opts(opts, schema) when is_list(opts) do
     case NimbleOptions.validate(opts, schema) do
       {:ok, validated} ->
         {:ok, validated}
 
       {:error, %NimbleOptions.ValidationError{} = err} ->
-        {:error, %Error{reason: :invalid_options, details: %{message: Exception.message(err)}}}
+        {:error, Error.wrap(:invalid_options, %{message: Exception.message(err)})}
     end
   end
+
+  defp validate_opts(other, _schema) do
+    {:error,
+     Error.wrap(:invalid_options, %{
+       message: "expected keyword list of options, got: #{inspect(other)}"
+     })}
+  end
 end
````

---

## 3. Verification Tests for Step 1

```elixir
defmodule Xitdb.OptionsAndCursorGuardTest do
  use ExUnit.Case, async: true
  use Xitdb.DSL

  alias Xitdb.Error

  test "NimbleOptions rejects unknown or mistyped options across compact/2, transact/3, query/3, and eager tx" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"users" => %{"alice" => %{"role" => "admin"}}})

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.compact(db, file: "/tmp/typo.xit")

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.transact(db, %{}, docs: "typo")

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.transact(db, %{}, "not_a_keyword_list")

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.query(db, ~s(find ?u where .users[?u].role = "admin"), moments: 0)

    assert {:error, %Error{reason: :invalid_options}} =
             (tx db, base_moment: "bad_moment" do
                update users["alice"].role, &String.upcase/1
              end)
  end

  test "index_rules applies identically across map, %Cursor{} callback, map-returning callback, and transact_ops/tx" do
    db = Xitdb.open!(backend: :memory)
    rules = [{:index_on, :users, :email, "email->user_id"}]

    db =
      Xitdb.transact!(
        db,
        %{"users" => %{"u1" => %{"email" => "u1@acme.io"}}},
        index_rules: rules
      )

    db =
      Xitdb.transact!(
        db,
        fn root -> put_in(root["users"]["u2"], %{"email" => "u2@acme.io"}) end,
        index_rules: rules
      )

    db =
      Xitdb.transact!(
        db,
        fn _root -> %{"users" => %{"u3" => %{"email" => "u3@acme.io"}}} end,
        index_rules: rules
      )

    db =
      tx! db, index_rules: rules do
        index_on :users, :email, "email->user_id"
        put users["u4"].email, "u4@acme.io"
      end

    assert db["email->user_id"]["u1@acme.io"] == "u1"
    assert db["email->user_id"]["u2@acme.io"] == "u2"
    assert db["email->user_id"]["u3@acme.io"] == "u3"
    assert db["email->user_id"]["u4@acme.io"] == "u4"
  end

  test "Xitdb.query/3 preserves historical cursor moment when :moment option is omitted" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"users" => %{"alice" => %{"role" => "admin"}}})
    db = Xitdb.transact!(db, %{"users" => %{"bob" => %{"role" => "admin"}}})

    snap0 = Xitdb.as_of(db, 0)
    assert {:ok, %{rows: [["alice"]]}} = Xitdb.query(snap0, ~s(find ?u where .users[?u].role = "admin"))
  end

  test "Xitdb.select/2 allows committed root snapshots and rejects child sub-cursors and tx_mode cursors" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"users" => %{"alice" => %{"role" => "admin"}}})

    assert Xitdb.select!(Xitdb.db(db), ".users.alice.role") == "admin"
    assert Xitdb.select!(Xitdb.as_of(db, 0), ".users.alice.role") == "admin"

    users_cursor = db["users"]

    assert {:error, %Error{reason: :non_root_cursor}} =
             Xitdb.select(users_cursor, ".alice.role")

    {:ok, _} =
      Xitdb.transact(db, fn tx_root ->
        assert {:error, %Error{reason: :non_root_cursor, details: %{tx_mode: true}}} =
                 Xitdb.select(tx_root, ".users.alice.role")

        tx_root
      end)
  end
end
```
