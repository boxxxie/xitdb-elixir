# Reference: Track 7 — `Xitdb.Error` Helpers, `NimbleOptions` Validation, Root-Cursor Guard & Wave 5 Follow-Ups

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Track ID:** `remaining_improvements_20261112`
> - **Wave:** Wave 4 (executes immediately after [`split_dsl_and_invert_ash_dependency_20261111`](../split_dsl_and_invert_ash_dependency_20261111/index.md))
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Wave 4 Scope (Step 1 — executed in this track):** `lib/xitdb/error.ex`, `lib/xitdb.ex`, `lib/xitdb/cursor.ex`, `lib/xitdb/collection.ex`, `lib/xitdb/dsl/tx_rewriter.ex`, `lib/xitdb/dsl/tx_runtime.ex`, `test/xitdb/options_and_cursor_guard_test.exs`
> - **Wave 5 Follow-Up Tracks (Steps 2 & 3 — executed after Ash tracks):**
>   - [`doc_fixes_and_operational_guides_20261112`](../doc_fixes_and_operational_guides_20261112/index.md) (`docs/*.md`)
>   - [`formatter_exports_and_usage_rules_20261112`](../formatter_exports_and_usage_rules_20261112/index.md) (`.formatter.exs`, `usage-rules.md`, `mix.exs`)

---

## 1. Roadmap Overview

1. **Step 1 (Wave 4 — executed in this track):** Add `Xitdb.Error.wrap/2` and `unwrap!/1`, validate options eagerly with compile-time `NimbleOptions` schemas across `transact/3`, `transact_ops/3`, `TxRuntime.init_state/3`, `query/3`, and `compact/2`, normalize `:index_rules` across all four transaction paths in `do_transact_ops/3`, guard `Xitdb.select/2` against both non-root sub-cursors and `tx_mode: true` transaction cursors, complete `transact/3` & `transact!/3` `@spec`s, document `Xitdb.at/1`, and replace raw LaTeX in docstrings with backtick code spans for IEx.

2. **Step 2 (Wave 5 — [`doc_fixes_and_operational_guides_20261112`](../doc_fixes_and_operational_guides_20261112/index.md)):** Fix the `path(sorted(...))` selector output discrepancy, strip `$O(...)` LaTeX math across `docs/*.md`, document `:memory` / `:buffered_file` / `:file` trade-offs and standalone `MyApp.Store` (`Process.flag(:trap_exit, true)`), and document first-class `use Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer`, `Xitdb.Ash.TestSandbox`, and `ModifyLockedFields` (`require_atomic? false`) in `docs/ash-and-spark.md`.

3. **Step 3 (Wave 5 — [`formatter_exports_and_usage_rules_20261112`](../formatter_exports_and_usage_rules_20261112/index.md)):** Export unified `locals_without_parens` in `.formatter.exs` for `import_deps: [:xitdb]` (keeping test-only `scenario: 2` local), unify `Xitdb.Ash.DataLayer` and `Xitdb.Ash.Resource` rules in `usage-rules.md`, and verify source-only Hex packaging in `mix.exs`.

---

## 2. Step 1 (Wave 4): `Xitdb.Error` Helpers, `NimbleOptions` Validation, `:index_rules`, Cursor Guard & IEx Docs

> Dedicated Step 1 reference: [`./references/step1_error_helpers_and_option_validation.md`](./references/step1_error_helpers_and_option_validation.md)

* **Centralized error helpers (`lib/xitdb/error.ex`):** Adds `Error.wrap/2` and `Error.unwrap!/1`, collapsing bang wrappers (`open!/1`, `info!/1`, `transact!/3`, `select!/2`, `pull!/2`, `query!/3`, `compact!/2`), NIF error-wrapping `case` blocks, `validate_opts/2`, and `TxRewriter.wrap_bang/1`.

* **Compile-time `NimbleOptions` schemas & eager `tx` validation (`lib/xitdb.ex`, `lib/xitdb/dsl/tx_runtime.ex`):** Adds `@transact_schema`, `@query_schema` (omitting `default: -1` on `:moment` so `Xitdb.query(%Cursor{moment: m}, ...)` preserves `m`), and `@compact_schema`, explicitly defines guarded `validate_opts/2` + `validate_transact_opts/1`, and validates `tx` options eagerly in `TxRuntime.init_state/3`.

* **Unified `:index_rules` across all transaction paths (`lib/xitdb.ex`):** Normalizes and deduplicates `validated[:index_rules]` inside `do_transact_ops/3` (passing `Keyword.delete(validated, :index_rules)` to `TxCompiler.compile_moment_map/2`) so map transactions, `%Cursor{}` callbacks, map-returning callbacks, and `transact_ops/3` (`tx` / `tx_for`) all apply `:index_rules` identically without double-emitting `{:index_on, ...}`.

* **Root snapshot & `tx_mode` safety on `Xitdb.select/2` (`lib/xitdb.ex`, `lib/xitdb/cursor.ex`):** Marks committed snapshot cursors from `Xitdb.db/1` and `Xitdb.as_of/2` with `root: true` and restricts `Xitdb.select/2` on cursors to `%Cursor{root: true, tx_mode: false}`, returning `{:error, %Xitdb.Error{reason: :non_root_cursor}}` for both nested child sub-cursors and in-flight `tx_mode: true` cursors.

* **Complete `@spec`s, documented `Xitdb.at/1` & IEx-clean `@doc` formatting:** Updates `@spec transact/3` and `transact!/3` callback return unions to `Cursor.t() | map() | {:abort, term()}`, adds `@doc` and `@spec` to `Xitdb.at/1`, links the seven guide documents in `Xitdb`'s `@moduledoc`, and replaces raw LaTeX math in docstrings with `` `O(1)` `` / `` `O(log N)` ``.

### Step 1 Diff

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
   - `:linked_array_list` — Count-augmented B-Tree with $O(\\log N)$ insert/remove/slice (`Tag.Linked_Array_List`, `[[i]]`)
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
+  - Implements `Enumerable` (`Enum.count/1` in `O(1)` on counted collections,
+    `Enum.member?/2` in `O(1)` / $O(\\log N)$ via HAMT/B+Tree lookup,
     `Enum.slice/2` in $O(\\log N)$ via index seek, and `Enum.to_list/1` / `Stream.*`).
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

### Verification Tests for Step 1

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

---

## 3. Step 2 (Wave 5 Archive): Documentation Alignment & Operational Contracts

> Executed in Wave 5 child track: [`../doc_fixes_and_operational_guides_20261112/reference.md`](../doc_fixes_and_operational_guides_20261112/reference.md) after `Xitdb.Ash.Store`, `Xitdb.Ash.DataLayer`, and `Xitdb.Ash.TestSandbox` land.

````diff
diff --git a/docs/path-and-pull-dsl.md b/docs/path-and-pull-dsl.md
--- a/docs/path-and-pull-dsl.md
+++ b/docs/path-and-pull-dsl.md
@@ -52,7 +52,7 @@
 # => ".accounts.[\"alice.liddell@acme.io\"].balance"
 
 path(sorted("email->id")[email])
-# => "$[\"email->id\"].[\"alice.liddell@acme.io\"]"
+# => ".email->id$[\"alice.liddell@acme.io\"]"
 ```
 
 ---
@@ -96,9 +96,10 @@
 Compiled selectors work across all `Xitdb` read, history, and mutation APIs:
 
 ```elixir
-# 1. Single-call selection against the latest moment or a historical moment:
+# 1. Single-call root-anchored selection against `%Xitdb{}` or a root snapshot (`Xitdb.db/1`, `Xitdb.as_of/2`):
 todo = Xitdb.select!(db, path(users[id].todos[[0]]))
 v0_role = Xitdb.select!(db, path(at_moment(0, users[id].role)))
+# Note: Selectors always resolve from the moment root; for child cursors (`db["users"]`), use `Access` or `Xitdb.pull/2`.
 
 # 2. Inspecting the temporal lineage of a path across all commits:
 {:ok, lineage} = Xitdb.history_of(db, path(users[id].role))
diff --git a/docs/time-travel-and-storage.md b/docs/time-travel-and-storage.md
--- a/docs/time-travel-and-storage.md
+++ b/docs/time-travel-and-storage.md
@@ -28,11 +28,18 @@
 :ok = Xitdb.close(disk_db)
 ```
 
+### Choosing a Backend & Hash Algorithm
+
+- **`:memory`** — Backed by an in-memory buffer with zero filesystem I/O; ideal for `async: true` ExUnit tests, ephemeral caches, and scratchpad projections.
+- **`:buffered_file`** — Buffers node writes in user space before flushing to the OS file descriptor on commit or `Xitdb.sync/1`; recommended for production workloads because multi-node HAMT/B+Tree commits avoid per-slot `write` syscalls.
+- **`:file`** — Issues unbuffered OS file reads/writes directly against the file descriptor; useful for small CLI utilities or constrained memory environments with infrequent writes.
+- **`:sha1` vs. `:sha256`** — Controls the cryptographic digest used for HAMT key hashing (`:sha1` by default for slightly faster hashing and compact digests; `:sha256` when collision-resistance policies require SHA-2). Once a database file is created, always reopen it with the same `:hash` setting.
+
 ---
 
 ## 2. Instant Time-Travel Snapshots (`Xitdb.as_of/2`)
 
-Pinning a snapshot to any historical moment index (`0..moment_count - 1`, or negative offsets from the latest commit like `-1`, `-2`) is an **$O(1)$ operation** that returns a `%Xitdb.Cursor{}` bound to that moment:
+Pinning a snapshot to any historical moment index (`0..moment_count - 1`, or negative offsets from the latest commit like `-1`, `-2`) is an **`O(1)` operation** that returns a `%Xitdb.Cursor{}` bound to that moment:
 
 ```elixir
 use Xitdb.DSL
@@ -79,7 +86,7 @@
 
 ### Zero-Copy Subtree Cloning (`fork`)
 
-Inside a transaction, `fork from_path, to_path` (or `Xitdb.fork/3`) clones any subtree—even a collection with millions of entries—in **$O(1)$ time and 9 bytes** by copying its `Slot` pointer and freezing the transaction watermark (`savepoint`) so subsequent edits to either path trigger copy-on-write isolation:
+Inside a transaction, `fork from_path, to_path` (or `Xitdb.fork/3`) clones any subtree—even a collection with millions of entries—in **`O(1)` time and 9 bytes** by copying its `Slot` pointer and freezing the transaction watermark (`savepoint`) so subsequent edits to either path trigger copy-on-write isolation:
 
 ```elixir
 {:ok, db} =
@@ -93,7 +100,7 @@
 
 ## 4. Structural Diffs (`Xitdb.diff_moments/3`)
 
-Because unchanged subtrees share identical 9-byte `Slot` pointers (`tag` + byte `offset`) across moments, `Xitdb.diff_moments(db, moment_a, moment_b)` skips identical subtrees in **$O(1)$ time** without traversing their children, computing the exact delta in $O(\Delta \text{ changed paths})$:
+Because unchanged subtrees share identical 9-byte `Slot` pointers (`tag` + byte `offset`) across moments, `Xitdb.diff_moments(db, moment_a, moment_b)` skips identical subtrees in **`O(1)` time** without traversing their children, computing the exact delta in `O(delta changed paths)`:
 
 ```elixir
 {:ok, changes} = Xitdb.diff_moments(db, 0, 1)
diff --git a/docs/transaction-dsl.md b/docs/transaction-dsl.md
--- a/docs/transaction-dsl.md
+++ b/docs/transaction-dsl.md
@@ -4,7 +4,7 @@
 
 1. **Intermediate NIF reads:** `put_in(root["users"][id]["profile"]["city"], "NYC")` invokes `Access.get_and_update/3` at every step, crossing the NIF boundary on each hop.
 2. **Missing intermediate paths:** If `root["users"][id]` does not exist yet, `Access.get_and_update/3` passes `nil` to the next step and raises unless intermediate maps are initialized first.
-3. **No syntax for native list/tree/metadata operations:** `Access` cannot express `xitdb`'s native $O(\log N)$ list `append`, `insert`, `slice`, $O(1)$ zero-copy subtree `fork`, secondary index registration (`index_on`), or commit metadata (`meta`, `instant`, `savepoint`).
+3. **No syntax for native list/tree/metadata operations:** `Access` cannot express `xitdb`'s native `O(log N)` list `append`, `insert`, `slice`, `O(1)` zero-copy subtree `fork`, secondary index registration (`index_on`), or commit metadata (`meta`, `instant`, `savepoint`).
 
 `Xitdb.DSL.tx/2,3` and `Xitdb.DSL.tx!/2,3` solve all three problems by compiling path expressions directly into a single atomic NIF transaction batch.
 
@@ -95,7 +95,7 @@
 ```
 
 ### `insert list_path[[idx]], value` (or `insert list_path, idx, value`)
-Inserts `value` at `idx` in a `Linked_Array_List` in $O(\log N)$ time, shifting subsequent elements right without copying them.
+Inserts `value` at `idx` in a `Linked_Array_List` in `O(log N)` time, shifting subsequent elements right without copying them.
 
 ```elixir
 insert users[id].todos[[0]], "urgent-task"
@@ -104,7 +104,7 @@
 ```
 
 ### `slice list_path, first..last` (or `slice list_path, offset, size`)
-Slices a `Linked_Array_List` (arbitrary `offset` and `size` in $O(\log N)$) or truncates an `Array_List` to `size`.
+Slices a `Linked_Array_List` (arbitrary `offset` and `size` in `O(log N)`) or truncates an `Array_List` to `size`.
 
 ```elixir
 slice users[id].todos, 0..9
@@ -113,7 +113,7 @@
 ```
 
 ### `fork from_path, to_path`
-Clones the subtree at `from_path` to `to_path` in **$O(1)$ zero-copy time** by copying its 9-byte `Slot` pointer and freezing the transaction watermark so subsequent mutations in the same `tx` block trigger copy-on-write on either branch.
+Clones the subtree at `from_path` to `to_path` in **`O(1)` zero-copy time** by copying its 9-byte `Slot` pointer and freezing the transaction watermark so subsequent mutations in the same `tx` block trigger copy-on-write on either branch.
 
 ```elixir
 fork users[id], backups[id]
@@ -221,3 +221,49 @@
 - `:instant` (`integer()`) — Epoch timestamp in milliseconds stored in `__tx.tx_instant` (inspected by `Xitdb.history_of/2`).
 - `:meta` (`map() | keyword()`) — Custom key-value metadata stored in `__tx.<key>`.
 - `:base_moment` (`integer()`, default `-1`) — Historical moment index to branch from.
+- `:index_rules` (`[{:index_on, source_map, field, index_map}]`, default `[]`) — Secondary B+Tree index rules applied during map or callback transactions.
+
+---
+
+## 5. Concurrency Model: Lock-Free Reads & Single-Writer Serialization
+
+- **Concurrent readers never block each other:** `%Xitdb{}` and `%Xitdb.Cursor{}` handles synchronize NIF slot access with an internal `ErlNifRWLock` and read immutable historical moments, so any number of BEAM processes can query or traverse cursors concurrently.
+- **Serialize read-modify-write transactions through one writer:** While `nif_transact` atomically commits each batch under a write lock, Elixir-side read-modify-write steps (`update` inside `tx` and `Xitdb.transact/3` 1-arity callbacks) read the current moment *before* entering `nif_transact`. If two BEAM processes run read-modify-write transactions concurrently against the same `%Xitdb{}` reference, both can read moment `N` and overwrite each other's updates (TOCTOU).
+
+If you are using Ash, supervise `Xitdb.Ash.Store` (see [`docs/ash-and-spark.md`](ash-and-spark.md)). For standalone non-Ash applications, own writes in a single `GenServer` and publish the `%Xitdb{}` handle in `:persistent_term` so readers bypass the `GenServer` mailbox completely:
+
+```elixir
+defmodule MyApp.Store do
+  use GenServer
+
+  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
+
+  # Zero-bottleneck concurrent reads (never touches GenServer mailbox)
+  def handle, do: :persistent_term.get({__MODULE__, :db})
+  def db, do: Xitdb.db(handle())
+
+  # Serialized atomic writes
+  def write(fun) when is_function(fun, 1) do
+    GenServer.call(__MODULE__, {:write, fun}, :infinity)
+  end
+
+  @impl true
+  def init(opts) do
+    Process.flag(:trap_exit, true)
+    {:ok, db} = Xitdb.open(opts)
+    :persistent_term.put({__MODULE__, :db}, db)
+    {:ok, db}
+  end
+
+  @impl true
+  def handle_call({:write, fun}, _from, db) do
+    {:reply, fun.(db), db}
+  end
+
+  @impl true
+  def terminate(_reason, db) do
+    :persistent_term.erase({__MODULE__, :db})
+    Xitdb.close(db)
+  end
+end
+```
diff --git a/docs/ash-and-spark.md b/docs/ash-and-spark.md
--- a/docs/ash-and-spark.md
+++ b/docs/ash-and-spark.md
@@ -152,7 +152,7 @@
 ### 1. `Xitdb.Ash.Transformers.WireChanges`
 At compile time, `WireChanges`:
 - Automatically attaches `{lock_change_mod, op: :lock}` to `lock_action` and `{lock_change_mod, op: :unlock}` to `unlock_action` (idempotently skipping any action that already declares `lock_change_mod` or does not exist on the resource).
-- Precomputes and compiles literal module callbacks (`__xitdb_editable_field_strings__/0`, `__xitdb_pull_fields__/0`, `__xitdb_pull_pattern__/0`, `__xitdb_collection__/0`, `__xitdb_indexes__/0`, `__xitdb_store__/0`, `__xitdb_lock_change__/0`, plus pre-merged companion pair lookups) directly onto the resource module so runtime `Xitdb.Ash.Info` lookups run in **$O(1)$ (~30 ns)** with zero heap allocations.
+- Precomputes and compiles literal module callbacks (`__xitdb_editable_field_strings__/0`, `__xitdb_pull_fields__/0`, `__xitdb_pull_pattern__/0`, `__xitdb_collection__/0`, `__xitdb_indexes__/0`, `__xitdb_store__/0`, `__xitdb_lock_change__/0`, plus pre-merged companion pair lookups) directly onto the resource module so runtime `Xitdb.Ash.Info` lookups run in **`O(1)` (~30 ns)** with zero heap allocations.
 
 ### 2. `Xitdb.Ash.Verifiers.VerifySyncProjection`
 At compile time, `VerifySyncProjection` verifies four invariants and raises a `Spark.Error.DslError` if any fails:
@@ -228,4 +228,79 @@
   def __xitdb_collection__, do: :items
   def __xitdb_indexes__, do: [sku: "sku->item_id"]
 end
 ```
+
+---
+
+## 5. Store Supervision (`Xitdb.Ash.Store`), `DataLayer`, `TestSandbox` & `lock_change` Contracts
+
+Rather than hand-rolling a bespoke `GenServer`, use `Xitdb.Ash.Store` for both pure `Xitdb.Ash.DataLayer` resources and hybrid `Xitdb.Ash.Resource` MDM projections:
+
+### 1. Defining & Supervising `MyApp.MDM.Store` (`use Xitdb.Ash.Store`)
+
+`Xitdb.Ash.Store` publishes lock-free snapshots via `:persistent_term`, serializes writes with monitored caller-process writer leases, supports nested savepoints (`Store.transact/3`, `Store.rollback/2`), and integrates natively with `Xitdb.Ash.TestSandbox` for `async: true` ExUnit suites:
+
+```elixir
+defmodule MyApp.MDM.Store do
+  use Xitdb.Ash.Store
+end
+
+# In MyApp.Application.start/2:
+children = [
+  {MyApp.MDM.Store,
+   path: "/var/lib/myapp/mdm.xit",
+   domains: [MyApp.Accounts]}
+]
+
+# Lock-free root snapshot cursor (`%Xitdb.Cursor{}` pinned to the latest committed moment):
+root_cursor = MyApp.MDM.Store.root()
+
+# Serialized MDM `tx_for!` batch inside the store's writer lease (re-entrant inside transactions).
+# `mutate/3` passes and expects `{db, moment}` working snapshots:
+{:ok, :synced} =
+  Xitdb.Ash.Store.mutate(MyApp.MDM.Store, fn {db, moment} ->
+    next_db =
+      tx_for! db, [MyApp.Accounts.Organization],
+        base_moment: moment,
+        doc: "sync org 101" do
+        put organizations["101"].id, "101"
+        put organizations["101"].domain, "northleaf.ca"
+      end
+
+    {:ok, {next_db, Xitdb.moment_count(next_db) - 1}, :synced}
+  end)
+```
+
+For resources persisted directly in `.xit` files without Postgres, set `data_layer: Xitdb.Ash.DataLayer` (which automatically includes the `xitdb do ... end` DSL, secondary `index` / `search_field` / `references` entities, and `Store` transaction coordination) and isolate concurrent tests in `test_helper.exs` / `DataCase` via `Xitdb.Ash.TestSandbox.init()` and `Xitdb.Ash.TestSandbox.checkout([MyApp.MDM.Store])`.
+
+### 2. Reference `lock_change` Module (`MyApp.MDM.Changes.ModifyLockedFields`)
+
+`WireChanges` attaches `{lock_change_mod, op: :lock}` to `lock_action` and `{lock_change_mod, op: :unlock}` to `unlock_action`.
+
+> [!IMPORTANT]
+> Because `ModifyLockedFields` inspects `Ash.Changeset.get_data(changeset, :locked_fields)` inside `change/3` without an `atomic/3` callback—and `WireChanges` preserves your action flags as written—both `lock_action` (`:lock_field`) and `unlock_action` (`:unlock_field`) **must** set `require_atomic? false` on the resource (as shown in Section 1).
+
+```elixir
+defmodule MyApp.MDM.Changes.ModifyLockedFields do
+  use Ash.Resource.Change
+  alias Xitdb.Ash.Info, as: XitdbInfo
+
+  @impl true
+  def change(changeset, opts, _context) do
+    field = Ash.Changeset.get_argument(changeset, :field)
+    allowed = XitdbInfo.editable_field_strings(changeset.resource)
+
+    if field in allowed do
+      current = Ash.Changeset.get_data(changeset, :locked_fields) || []
+
+      updated =
+        case Keyword.fetch!(opts, :op) do
+          :lock -> Enum.uniq(current ++ [field])
+          :unlock -> List.delete(current, field)
+        end
+
+      Ash.Changeset.force_change_attribute(changeset, :locked_fields, updated)
+    else
+      Ash.Changeset.add_error(changeset, field: :field, message: "is not an editable Xitdb field")
+    end
+  end
+end
+```
diff --git a/docs/access-and-enumerable.md b/docs/access-and-enumerable.md
--- a/docs/access-and-enumerable.md
+++ b/docs/access-and-enumerable.md
@@ -10,7 +10,7 @@ Each `%Xitdb.Cursor{}` wraps only the NIF database resource reference (`db_ref`)
 
 When you read from a `%Xitdb{}` handle (`Xitdb.db(db)`, `Xitdb.as_of(db, moment)`, or `db["users"]`):
 
-1. **Containers return `%Xitdb.Cursor{}` in $O(1)$ heap space:**
+1. **Containers return `%Xitdb.Cursor{}` in `O(1)` heap space:**
    If the target slot is a collection (`:hash_map`, `:counted_hash_map`, `:sorted_map`, `:array_list`, `:linked_array_list`, `:hash_set`, `:counted_hash_set`, `:sorted_set`), `Xitdb` returns a lightweight `%Xitdb.Cursor{}` struct pointing to that collection's byte offset.
 2. **Leaf scalars unwrap automatically:**
    If the target slot is a scalar (`String.t()`, `integer()`, `float()`, `boolean()`, or `{:tagged, tag, payload}`), `Xitdb` immediately decodes and returns the native Elixir value.
@@ -124,14 +124,14 @@ To abort and roll back from inside a `Xitdb.transact/3` callback, return `{:abor
 
 ## 4. `Enumerable` Fast-Path Pushdowns & `Stream` Pagination
 
-`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure pushdowns so common `Enum` operations execute in $O(1)$ or $O(\log N)$ inside Odin rather than linearly scanning elements in Elixir:
+`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure pushdowns so common `Enum` operations execute in `O(1)` or `O(log N)` inside Odin rather than linearly scanning elements in Elixir:
 
 | `Enum` / `Stream` Operation | Backing NIF Pushdown | Complexity | Supported Collection Kinds |
 | :--- | :--- | :--- | :--- |
-| `Enum.count(cursor)` | `nif_slot_count` | **$O(1)$** | `Counted_Hash_Map`, `Counted_Hash_Set`, `Sorted_Map`, `Sorted_Set`, `Array_List`, `Linked_Array_List` *(falls back to $O(N)$ reducer on uncounted `Hash_Map` / `Hash_Set`)* |
-| `Enum.member?(set_cur, "val")` | `nif_slot_contains` | **$O(1)$ / $O(\log N)$** | `Hash_Set`, `Counted_Hash_Set` ($O(\log_{16} N)$ HAMT), `Sorted_Set` ($O(\log N)$ B+Tree) |
-| `Enum.member?(map_cur, {k, v})` | `Cursor.fetch` + equality | **$O(1)$ / $O(\log N)$** | `Hash_Map`, `Counted_Hash_Map`, `Sorted_Map` |
-| `Enum.slice(cursor, first..last)`<br>`Enum.at(cursor, idx)` | `nif_slot_slice` | **$O(\log N + K)$** | `Array_List`, `Linked_Array_List`, `Sorted_Map` (yields `{k, v}` tuples in key order), `Sorted_Set` (yields members in key order) |
+| `Enum.count(cursor)` | `nif_slot_count` | **`O(1)`** | `Counted_Hash_Map`, `Counted_Hash_Set`, `Sorted_Map`, `Sorted_Set`, `Array_List`, `Linked_Array_List` *(falls back to `O(N)` reducer on uncounted `Hash_Map` / `Hash_Set`)* |
+| `Enum.member?(set_cur, "val")` | `nif_slot_contains` | **`O(1)` / `O(log N)`** | `Hash_Set`, `Counted_Hash_Set` (`O(log_16 N)` HAMT), `Sorted_Set` (`O(log N)` B+Tree) |
+| `Enum.member?(map_cur, {k, v})` | `Cursor.fetch` + equality | **`O(1)` / `O(log N)`** | `Hash_Map`, `Counted_Hash_Map`, `Sorted_Map` |
+| `Enum.slice(cursor, first..last)`<br>`Enum.at(cursor, idx)` | `nif_slot_slice` | **`O(log N + K)`** | `Array_List`, `Linked_Array_List`, `Sorted_Map` (yields `{k, v}` tuples in key order), `Sorted_Set` (yields members in key order) |
 | `Stream.take(cursor, k)`<br>`Enum.to_list(cursor)` | `nif_slot_entries` | **Adaptive chunks (`16 -> 64 -> 256`)** | All 8 collection types |
 
 ### Examples
diff --git a/docs/collections-and-indexing.md b/docs/collections-and-indexing.md
--- a/docs/collections-and-indexing.md
+++ b/docs/collections-and-indexing.md
@@ -3,9 +3,9 @@
 By default, when you pass standard Elixir data structures to `Xitdb.transact/3` or `put` inside `Xitdb.DSL.tx`:
 - Plain Elixir maps (`%{}`) are stored as `:hash_map` (16-way HAMT).
 - Plain Elixir lists (`[]`) are stored as `:array_list` (16-way Radix Trie).
-- `%MapSet{}` values are stored as `:counted_hash_set` (16-way HAMT set with $O(1)$ count).
+- `%MapSet{}` values are stored as `:counted_hash_set` (16-way HAMT set with `O(1)` count).
 
-When your workload requires **$O(1)$ map cardinality**, **lexicographical B+Tree key ordering and range scans**, or **$O(\log N)$ middle-of-list insertions and removals**, wrap your data in `Xitdb`'s explicit collection constructors (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, etc.) or initialize them with `init_col` in `tx`.
+When your workload requires **`O(1)` map cardinality**, **lexicographical B+Tree key ordering and range scans**, or **`O(log N)` middle-of-list insertions and removals**, wrap your data in `Xitdb`'s explicit collection constructors (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`, etc.) or initialize them with `init_col` in `tx`.
 
 ---
 
@@ -15,14 +15,14 @@ When your workload requires **$O(1)$ map cardinality**, **lexicographical B+Tree
 
 | Collection Kind | Constructor | Selector Sigil | Backing Structure | `get` / `member?` | `put` / `append` | `insert` / `rm` / `slice` | `Enum.count/1` |
 | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
-| `:hash_map` | `Xitdb.hash_map(map)` *(or `%{}`)* | `.key` | 16-way HAMT | $O(\log_{16} N)$ | $O(\log_{16} N)$ | `rm`: $O(\log_{16} N)$ | $O(N)$ scan |
-| `:counted_hash_map` | `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count slot | $O(\log_{16} N)$ | $O(\log_{16} N)$ | `rm`: $O(\log_{16} N)$ | **$O(1)$** |
-| `:sorted_map` | `Xitdb.sorted_map(map)` | `$key` | Count-augmented B+Tree | $O(\log N)$ | $O(\log N)$ | `rm` & `slice`: **$O(\log N)$** | **$O(1)$** |
-| `:array_list` | `Xitdb.array_list(list)` *(or `[]`)* | `[idx]` | 16-way Radix Trie | $O(\log_{16} N)$ | $O(\log_{16} N)$ | Tail `slice` only; no middle `insert`/`rm` | **$O(1)$** |
-| `:linked_array_list` | `Xitdb.linked_list(list)` | `[[idx]]` | Count-augmented B-Tree | $O(\log N)$ | $O(\log N)$ | Arbitrary `insert`, `rm`, `slice`: **$O(\log N)$** | **$O(1)$** |
-| `:hash_set` | `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | $O(\log_{16} N)$ | $O(\log_{16} N)$ | `rm`: $O(\log_{16} N)$ | $O(N)$ scan |
-| `:counted_hash_set` | `Xitdb.counted_set(enum)` *(or `MapSet`)* | `#%member` | 16-way HAMT set + count | $O(\log_{16} N)$ | $O(\log_{16} N)$ | `rm`: $O(\log_{16} N)$ | **$O(1)$** |
-| `:sorted_set` | `Xitdb.sorted_set(enum)` | `^member` | Count-augmented B+Tree set | $O(\log N)$ | $O(\log N)$ | `rm` & `slice`: **$O(\log N)$** | **$O(1)$** |
+| `:hash_map` | `Xitdb.hash_map(map)` *(or `%{}`)* | `.key` | 16-way HAMT | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | `O(N)` scan |
+| `:counted_hash_map` | `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count slot | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | **`O(1)`** |
+| `:sorted_map` | `Xitdb.sorted_map(map)` | `$key` | Count-augmented B+Tree | `O(log N)` | `O(log N)` | `rm` & `slice`: **`O(log N)`** | **`O(1)`** |
+| `:array_list` | `Xitdb.array_list(list)` *(or `[]`)* | `[idx]` | 16-way Radix Trie | `O(log_16 N)` | `O(log_16 N)` | Tail `slice` only; no middle `insert`/`rm` | **`O(1)`** |
+| `:linked_array_list` | `Xitdb.linked_list(list)` | `[[idx]]` | Count-augmented B-Tree | `O(log N)` | `O(log N)` | Arbitrary `insert`, `rm`, `slice`: **`O(log N)`** | **`O(1)`** |
+| `:hash_set` | `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | `O(N)` scan |
+| `:counted_hash_set` | `Xitdb.counted_set(enum)` *(or `MapSet`)* | `#%member` | 16-way HAMT set + count | `O(log_16 N)` | `O(log_16 N)` | `rm`: `O(log_16 N)` | **`O(1)`** |
+| `:sorted_set` | `Xitdb.sorted_set(enum)` | `^member` | Count-augmented B+Tree set | `O(log N)` | `O(log N)` | `rm` & `slice`: **`O(log N)`** | **`O(1)`** |
 
 ---
 
@@ -30,15 +30,15 @@ When your workload requires **$O(1)$ map cardinality**, **lexicographical B+Tree
 
 ### Maps: `hash_map` vs. `counted_map` vs. `sorted_map`
 - **Use `%{}` / `Xitdb.hash_map/1`** for entity attributes (`%{"username" => "alice", "age" => 30}`) and general key-value lookups where you don't need `Enum.count/1` or sorted key iteration.
-- **Use `Xitdb.counted_map/1`** for entity tables (`"departments"`, `"tenants"`) when you frequently call `Enum.count(db["tenants"])` and want $O(1)$ cardinality without B+Tree key sorting overhead.
+- **Use `Xitdb.counted_map/1`** for entity tables (`"departments"`, `"tenants"`) when you frequently call `Enum.count(db["tenants"])` and want `O(1)` cardinality without B+Tree key sorting overhead.
 - **Use `Xitdb.sorted_map/1`** for lexicographically ordered directories, time-series keys (`"2026-11-03T22:00:00Z"`), leaderboards, and secondary indexes where you need ordered iteration, `Enum.slice/2` pagination by rank, or Datalog `starts_with` / `>=` B+Tree range pushdowns.
 
 ### Lists: `array_list` vs. `linked_list`
 - **Use `[]` / `Xitdb.array_list/1`** for append-only logs, fixed-order arrays, or random index reads (`roles[0]`). `Array_List` supports fast tail `append` and tail truncation (`slice list, 0, new_size`), but does **not** allow middle-of-list insertions or element deletion.
-- **Use `Xitdb.linked_list/1`** for task queues, ordered feeds, or editable lists where items are inserted at index `0` (`insert todos[[0]], "urgent"`), removed by index (`rm todos[[2]]`), or sliced at arbitrary offsets (`slice todos, 10..19`) in **$O(\log N)$** time without re-indexing subsequent elements.
+- **Use `Xitdb.linked_list/1`** for task queues, ordered feeds, or editable lists where items are inserted at index `0` (`insert todos[[0]], "urgent"`), removed by index (`rm todos[[2]]`), or sliced at arbitrary offsets (`slice todos, 10..19`) in **`O(log N)`** time without re-indexing subsequent elements.
 
 ### Sets: `hash_set` vs. `counted_set` vs. `sorted_set`
-- **Use `Xitdb.counted_set/1` (or `MapSet.new/1`)** for user roles, permissions, or feature flags when you need $O(1)$ `Enum.count/1` and $O(1)$ `Enum.member?/2`.
+- **Use `Xitdb.counted_set/1` (or `MapSet.new/1`)** for user roles, permissions, or feature flags when you need `O(1)` `Enum.count/1` and `O(1)` `Enum.member?/2`.
 - **Use `Xitdb.sorted_set/1`** when set members should always iterate and slice in deterministic alphabetical order (e.g., tags or badges).
 
 ```elixir
@@ -96,7 +96,7 @@ Xitdb.select!(db, path(sorted("email->id")["daria@acme.io"])) # => "u102"
 
 | Elixir Value | `xitdb` Storage Representation | Round-Trip Value |
 | :--- | :--- | :--- |
-| `"hello"` | `Tag.Short_Bytes` ($\le 8$ bytes inline in `Slot`) or `Tag.Bytes` | `"hello"` |
+| `"hello"` | `Tag.Short_Bytes` (`<= 8` bytes inline in `Slot`) or `Tag.Bytes` | `"hello"` |
 | `42` (non-negative `integer()`) | `Tag.Uint` (`u64`) | `42` |
 | `-42` (negative `integer()`) | `Tag.Int` (`i64`) | `-42` |
 | `3.14` (`float()`) | `Tag.Float` (`f64`) | `3.14` |
diff --git a/docs/datalog-dsl.md b/docs/datalog-dsl.md
--- a/docs/datalog-dsl.md
+++ b/docs/datalog-dsl.md
@@ -2,7 +2,7 @@
 
 `Xitdb` includes a native structural and temporal Datalog engine in Odin that supports:
 - Pattern unification across maps, counted maps, sorted maps, lists, and sets
-- Automatic $O(\log N)$ B+Tree secondary index prefix and range pushdown
+- Automatic `O(log N)` B+Tree secondary index prefix and range pushdown
 - Negated clauses (`not`) and key existence checks
 - Cycle-safe BFS transitive graph traversal (`reach/3,4`)
 - Cross-moment and full-history temporal queries (`at_moment/2`)
@@ -197,8 +197,8 @@ Non-aggregated variables in `find` automatically act as the grouping key. If all
   - `u.tags.sorted_set_member("elixir")` (`^` `Sorted_Set`)
 - **Comparisons:** `==`, `!=`, `>`, `>=`, `<`, `<=` (works between two logic variables like `new_salary > old_salary` or a variable and a literal/pinned value like `salary >= ^min_salary`)
 - **String predicates & B+Tree Pushdown:**
-  - `starts_with(var, "prefix")` — triggers an **$O(\log N)$ B+Tree prefix seek** when `var` is unified against a `Sorted_Map` (`sorted(...)`) or `Sorted_Set`!
-  - `var >= "lower_bound"` / `var > "lower_bound"` — also triggers an **$O(\log N)$ B+Tree lower-bound seek** on `Sorted_Map` / `Sorted_Set` keys!
+  - `starts_with(var, "prefix")` — triggers an **`O(log N)` B+Tree prefix seek** when `var` is unified against a `Sorted_Map` (`sorted(...)`) or `Sorted_Set`!
+  - `var >= "lower_bound"` / `var > "lower_bound"` — also triggers an **`O(log N)` B+Tree lower-bound seek** on `Sorted_Map` / `Sorted_Set` keys!
   - `contains(var, "substring")`
 - **Negation:** `not <clause>` (e.g. `not u.flags.set_member("suspended")`, `not u.deleted_at`, or `not (u.role == "guest")`)
 
````

---

## 4. Step 3 (Wave 5 Archive): Unified Formatter Exports & `usage-rules.md`

> Executed in Wave 5 child track: [`../formatter_exports_and_usage_rules_20261112/reference.md`](../formatter_exports_and_usage_rules_20261112/reference.md).

### `.formatter.exs`

```elixir
dsl_locals_without_parens = [
  # Transaction blocks
  tx: 2,
  tx: 3,
  tx!: 2,
  tx!: 3,
  tx_for: 2,
  tx_for: 3,
  tx_for: 4,
  tx_for!: 2,
  tx_for!: 3,
  tx_for!: 4,
  # Transaction operations
  put: 1,
  put: 2,
  update: 2,
  update: 3,
  rm: 1,
  append: 2,
  insert: 2,
  insert: 3,
  slice: 2,
  slice: 3,
  fork: 2,
  index_on: 3,
  init_col: 2,
  reset_col: 2,
  meta: 2,
  instant: 1,
  abort: 1,
  # Datalog blocks & clauses
  datalog: 1,
  query: 2,
  query: 3,
  query!: 2,
  query!: 3,
  find: 1,
  find: 2,
  find: 3,
  find: 4,
  from: 1,
  where: 1
]

spark_locals_without_parens = [
  # Shared & Xitdb.Ash.DataLayer options/entities
  store: 1,
  collection: 1,
  nested_in: 1,
  nested_in: 2,
  index: 1,
  index: 2,
  index_relationships?: 1,
  counted_set_fields: 1,
  search_field: 1,
  search_field: 2,
  reference: 1,
  reference: 2,
  # Xitdb.Ash.Resource (hybrid MDM projection) options
  merge_redirect_collection: 1,
  locked_ids_set: 1,
  companion_resource: 1,
  editable_fields: 1,
  passthru_fields: 1,
  computed_xitdb_fields: 1,
  field_aliases: 1,
  indexes: 1,
  sync_update_action: 1,
  ignored_sync_attributes: 1,
  lock_action: 1,
  unlock_action: 1,
  lock_change: 1
]

exported_locals = dsl_locals_without_parens ++ spark_locals_without_parens

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,benchmarks}/**/*.{ex,exs}"],
  locals_without_parens: exported_locals ++ [scenario: 2],
  export: [locals_without_parens: exported_locals]
]
```

### `usage-rules.md` Diff

````diff
diff --git a/usage-rules.md b/usage-rules.md
--- a/usage-rules.md
+++ b/usage-rules.md
@@ -9,7 +9,7 @@
 1. **Default to Lazy `Access` Navigation (`db["users"]["alice"]["name"]`)**:
    - Reading from `Xitdb` (`Xitdb.db(db)`, `Xitdb.as_of(db, moment)`, or `db["users"]`) returns a lazy `%Xitdb.Cursor{}` holding only the NIF database reference and 9-byte `Slot` coordinates (`tag`, `tag_id`, `value`).
    - Cursors are **pure, immutable Elixir values**. Pass them freely across BEAM processes (`Task.async_stream/3`, GenServers, ETS, Phoenix LiveView assigns) without locks or copying underlying subtrees.
-   - Navigating to a scalar (`string`, `integer`, `float`, `boolean`, or `{:tagged, tag, bytes}`) unwraps and returns the native Elixir value directly; navigating to a nested container returns another `%Xitdb.Cursor{}` in $O(1)$ heap space.
+   - Navigating to a scalar (`string`, `integer`, `float`, `boolean`, or `{:tagged, tag, bytes}`) unwraps and returns the native Elixir value directly; navigating to a nested container returns another `%Xitdb.Cursor{}` in `O(1)` heap space.
 2. **Use `Xitdb.at/1` Instead of `Access.at/1` on Lazy List Cursors**:
    - Elixir's built-in `Access.at/1` guards `is_list(data)` and raises on structs. When navigating `Array_List` or `Linked_Array_List` cursors with `get_in/2` or `put_in/3`, either pass integer keys directly in the path list (`get_in(root, ["users", "alice", "roles", 1])`) or use `Xitdb.at(1)`.
 3. **Never Eagerly Materialize Large Subtrees Unless Needed**:
@@ -38,17 +38,17 @@
 
 ## 3. Choosing Collection Types (`Xitdb.Collection`)
 
-By default, plain Elixir maps (`%{}`) are stored as `:hash_map` (`Tag.Hash_Map`), plain lists (`[]`) as `:array_list` (`Tag.Array_List`), and `%MapSet{}` as `:counted_hash_set`. Use wrapper constructors on `Xitdb` when you need $O(1)$ counts, lexicographical B+Tree ordering, or $O(\log N)$ list insertions/removals:
+By default, plain Elixir maps (`%{}`) are stored as `:hash_map` (`Tag.Hash_Map`), plain lists (`[]`) as `:array_list` (`Tag.Array_List`), and `%MapSet{}` as `:counted_hash_set`. Use wrapper constructors on `Xitdb` when you need `O(1)` counts, lexicographical B+Tree ordering, or `O(log N)` list insertions/removals:
 
 | Constructor | Selector Sigil | Backing Structure | Best For |
 | :--- | :--- | :--- | :--- |
 | `Xitdb.hash_map(map)` | `.key` | 16-way HAMT | General key-value maps |
-| `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count header | Maps needing $O(1)$ `Enum.count/1` |
+| `Xitdb.counted_map(map)` | `#key` | 16-way HAMT + count header | Maps needing `O(1)` `Enum.count/1` |
 | `Xitdb.sorted_map(map)` | `$key` | Lexicographical B+Tree | Ordered iteration, range slices, secondary indexes |
 | `Xitdb.array_list(list)` | `[i]` | 16-way Radix Trie | Append-heavy lists and random index reads |
-| `Xitdb.linked_list(list)` | `[[i]]` | Count-augmented B-Tree | Queues/lists needing $O(\log N)$ `insert`, `rm`, and `slice` |
+| `Xitdb.linked_list(list)` | `[[i]]` | Count-augmented B-Tree | Queues/lists needing `O(log N)` `insert`, `rm`, and `slice` |
 | `Xitdb.hash_set(enum)` | `%member` | 16-way HAMT set | Uncounted string membership sets |
-| `Xitdb.counted_set(enum)` | `#%member` | 16-way HAMT set + count | Sets needing $O(1)$ `Enum.count/1` and `Enum.member?/2` |
+| `Xitdb.counted_set(enum)` | `#%member` | 16-way HAMT set + count | Sets needing `O(1)` `Enum.count/1` and `Enum.member?/2` |
 | `Xitdb.sorted_set(enum)` | `^member` | Lexicographical B+Tree set | Ordered unique tags/badges |
 
 ---
@@ -82,6 +82,8 @@
 - For set member additions inside `tx`, use 1-arity `put path.set_member(val)` (or `counted_set_member`/`sorted_set_member`).
 - For read-modify-write updates with a fallback when the path does not yet exist, use 3-arity `update path, default, fun`.
 - To roll back from inside a `tx` block, call `abort :reason`.
+- **Never mutate `%Xitdb{}` directly** outside `Xitdb.transact/3` or `tx` (`put_in(db["a"], 1)` raises `ArgumentError`).
+- **Single-writer concurrency**: Concurrent readers are lock-free, while read-modify-write transactions (`update` in `tx` and `Xitdb.transact/3` callbacks) must serialize through `Xitdb.Ash.Store` or a single owner `GenServer`.
 
 ### 2. Top-Level Map Transactions (`Xitdb.transact/3`)
 
@@ -122,7 +124,7 @@
 
 ### Lazy `Access` & `Enumerable` Fast Paths
 
-`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure fast paths (`Enum.count/1` in $O(1)$, `Enum.member?/2` in $O(1)$ / $O(\log_{16} N)$, `Enum.slice/2` in $O(\log N + K)$):
+`%Xitdb.Cursor{}` implements `Enumerable` with native data-structure fast paths (`Enum.count/1` in `O(1)`, `Enum.member?/2` in `O(1)` / `O(log_16 N)`, `Enum.slice/2` in `O(log N + K)`):
 
 ```elixir
 root = Xitdb.db(db)
@@ -150,6 +152,8 @@
 # Static compile-time validated sigil
 todo = Xitdb.select!(db, ~x|.users["101"].todos[1]|)
 ```
+
+- `Xitdb.select/2` only accepts `%Xitdb{}` or a root snapshot cursor (`Xitdb.db/1`, `Xitdb.as_of/2`), never a nested child cursor (`db["users"]`).
 
 ### Datomic-Style Pull Projections (`Xitdb.pull/2`)
 
@@ -256,7 +260,7 @@
 end
 ```
 
-For child entities co-located inside a parent entity's subtree for 9-byte `fork` snapshots, declare `nested_in`:
+For `Xitdb.Ash.DataLayer` child entities co-located inside a parent entity's subtree for 9-byte `fork` snapshots, declare **both** `collection` (for `meta.sequences` and `idx.<collection>._parent` locators) and `nested_in`:
 
 ```elixir
 xitdb do
@@ -266,6 +270,13 @@
 end
 ```
 
+### Hybrid MDM Extension Rules (`extensions: [Xitdb.Ash.Resource]`)
+
+When attaching `Xitdb.Ash.Resource` as a secondary MDM sync extension onto an external data layer (such as `Ash.DataLayer.Postgres`):
+- Declare **either** top-level `collection :name` **or** `nested_in ParentResource, as: :slot, parent_key: :fk, key: :entry_key`—never both on an MDM-only `Xitdb.Ash.Resource`, and never declare `indexes` on MDM `nested_in` resources.
+- Every attribute accepted by `sync_update_action` (unless listed in `ignored_sync_attributes`) **must** appear in `editable_fields` or `passthru_fields`, or `VerifySyncProjection` raises a compile-time `Spark.Error.DslError`.
+- Set `require_atomic? false` on `lock_action` and `unlock_action` when your `lock_change` module implements `change/3` via `Ash.Changeset.get_data/2` without an `atomic/3` callback.
+
 ### Strict DO / DON'T Rules
 
 #### 1. Zero SQL Fragments or Codegen Migrations
````
