defmodule Xitdb do
  @moduledoc """
  Idiomatic Elixir client and Odin NIF wrapper for [`xitdb`](https://github.com/xit-vcs/xitdb),
  an embeddable, immutable, append-only database with persistent structural sharing.

  `Xitdb` exposes database moments as lazy `%Xitdb.Cursor{}` handles that implement
  Elixir's `Access`, `Enumerable`, and `Inspect` protocols—allowing you to navigate
  and query on-disk data structures (`Hash_Map`, `Counted_Hash_Map`, `Sorted_Map`,
  `Array_List`, `Linked_Array_List`, and sets) just like standard Elixir maps and lists.

  ## Guides
  - [Lazy Cursors, `Access` & `Enumerable`](docs/access-and-enumerable.md)
  - [Collections, Data Modeling & Secondary Indexes](docs/collections-and-indexing.md)
  - [Path Selector & Structural Pull DSL](docs/path-and-pull-dsl.md)
  - [Declarative Transaction Block DSL](docs/transaction-dsl.md)
  - [Declarative Datalog Query DSL](docs/datalog-dsl.md)
  - [Time-Travel, Structural Diffs, Lineage & Storage Lifecycle](docs/time-travel-and-storage.md)
  - [Ash & Spark Integration](docs/ash-and-spark.md)
  """

  @behaviour Access

  alias Xitdb.{Collection, Cursor, Error, NIF, Pull, Selector, TxCompiler}

  defmacro path(expr) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.path(unquote(expr))
    end
  end

  defmacro tx(db, block) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.tx(unquote(db), unquote(block))
    end
  end

  defmacro tx(db, opts, block) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.tx(unquote(db), unquote(opts), unquote(block))
    end
  end

  defmacro tx!(db, block) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.tx!(unquote(db), unquote(block))
    end
  end

  defmacro tx!(db, opts, block) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.tx!(unquote(db), unquote(opts), unquote(block))
    end
  end

  defmacro datalog(block) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.datalog(unquote(block))
    end
  end

  defmacro pull_pattern(pattern) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.pull_pattern(unquote(pattern))
    end
  end

  @open_schema NimbleOptions.new!(
                 backend: [
                   type: {:in, [:memory, :file, :buffered_file]},
                   default: :memory,
                   doc: "Storage backend (`:memory`, `:file`, or `:buffered_file`)."
                 ],
                 path: [
                   type: :string,
                   default: "",
                   doc: "Filesystem path for `:file` or `:buffered_file` backends."
                 ],
                 hash: [
                   type: {:in, [:sha1, :sha256]},
                   default: :sha1,
                   doc: "Cryptographic digest algorithm for HAMT keys (`:sha1` or `:sha256`)."
                 ]
               )

  @index_rule_type {:tuple,
                    [
                      {:in, [:index_on]},
                      {:or, [:atom, :string]},
                      {:or, [:atom, :string]},
                      {:or, [:atom, :string]}
                    ]}

  @transact_schema NimbleOptions.new!(
                     doc: [
                       type: :string,
                       default: "",
                       doc: "Commit message stored in `__tx.doc`."
                     ],
                     instant: [
                       type: :integer,
                       doc: "Epoch timestamp in milliseconds stored in `__tx.tx_instant`."
                     ],
                     meta: [
                       type: {:or, [:map, :keyword_list]},
                       doc: "Custom commit metadata stored under `__tx.<key>`."
                     ],
                     base_moment: [
                       type: :integer,
                       default: -1,
                       doc: "Historical moment index to branch from (`-1` for latest)."
                     ],
                     index_rules: [
                       type: {:list, @index_rule_type},
                       default: [],
                       doc:
                         "Secondary B+Tree index rules (`[{:index_on, source_map, field, index_map}]`)."
                     ]
                   )

  @query_schema NimbleOptions.new!(
                  moment: [
                    type: :integer,
                    doc:
                      "Historical moment index to query (`-1` for latest; defaults to cursor moment when querying a `%Xitdb.Cursor{}`)."
                  ]
                )

  @compact_schema NimbleOptions.new!(
                    path: [
                      type: :string,
                      default: "",
                      doc:
                        "Destination file path for compacted database (compacts into `:memory` when empty)."
                    ]
                  )

  @enforce_keys [:db_ref, :backend]
  defstruct [:db_ref, :backend, :path, hash: :sha1]

  @type t :: %__MODULE__{
          db_ref: reference(),
          backend: :memory | :file | :buffered_file,
          path: String.t(),
          hash: :sha1 | :sha256
        }

  # ============================================================================
  # Database Lifecycle
  # ============================================================================

  @doc """
  Opens a `Xitdb` database instance.

  ## Options
  #{NimbleOptions.docs(@open_schema)}
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def open(opts \\ []) do
    with {:ok, validated} <- validate_opts(opts, @open_schema) do
      backend = validated[:backend]
      path = validated[:path]
      hash = validated[:hash]

      if backend in [:file, :buffered_file] and path == "" do
        {:error, %Error{reason: :missing_path, details: %{backend: backend}}}
      else
        case NIF.nif_open(backend, path, hash) do
          {:ok, db_ref} ->
            {:ok, %__MODULE__{db_ref: db_ref, backend: backend, path: path, hash: hash}}

          {:error, reason} ->
            {:error, %Error{reason: reason}}
        end
      end
    end
  end

  @doc "Same as `open/1`, but raises `Xitdb.Error` on failure."
  @spec open!(keyword()) :: t()
  def open!(opts \\ []), do: opts |> open() |> Error.unwrap!()

  @doc "Flushes and closes the underlying `xitdb` storage handle."
  @spec close(t()) :: :ok
  def close(%__MODULE__{db_ref: db_ref}) do
    NIF.nif_close(db_ref)
  end

  @doc "Synchronizes buffered writes to disk."
  @spec sync(t()) :: :ok | {:error, Error.t()}
  def sync(%__MODULE__{db_ref: db_ref}) do
    db_ref |> NIF.nif_sync() |> Error.wrap()
  end

  @doc "Returns database metadata (`%{moment_count: integer(), file_size: integer()}`)."
  @spec info(t()) :: {:ok, map()} | {:error, Error.t()}
  def info(%__MODULE__{db_ref: db_ref}) do
    db_ref |> NIF.nif_info() |> Error.wrap()
  end

  @doc "Same as `info/1`, but raises `Xitdb.Error` on failure."
  @spec info!(t()) :: map()
  def info!(%__MODULE__{} = db), do: db |> info() |> Error.unwrap!()

  @doc "Returns the number of committed historical moments in `db`."
  @spec moment_count(t()) :: non_neg_integer()
  def moment_count(%__MODULE__{} = db) do
    case info(db) do
      {:ok, %{moment_count: count}} -> count
      _ -> 0
    end
  end

  # ============================================================================
  # Snapshots & Time-Travel (`db/1`, `as_of/2`)
  # ============================================================================

  @doc """
  Returns a lazy `%Xitdb.Cursor{}` pointing to the latest committed moment (`-1`).
  """
  @spec db(t()) :: Cursor.t()
  def db(%__MODULE__{} = db_handle) do
    as_of(db_handle, -1)
  end

  @doc """
  Returns a lazy `%Xitdb.Cursor{}` pinned to historical `moment_index` (`0..N-1`, or negative from end).
  """
  @spec as_of(t(), integer()) :: Cursor.t()
  def as_of(%__MODULE__{db_ref: db_ref}, moment_index)
      when is_integer(moment_index) and moment_index >= 0 do
    %Cursor{
      db_ref: db_ref,
      tag: :hash_map,
      tag_id: -1,
      value: moment_index,
      moment: moment_index,
      root: true
    }
  end

  def as_of(%__MODULE__{db_ref: db_ref}, moment_index) when is_integer(moment_index) do
    case NIF.nif_moment_slot(db_ref, moment_index) do
      {:ok, tuple} ->
        cursor = Cursor.from_nif_tuple(db_ref, tuple, moment_index)
        %Cursor{cursor | root: true}

      {:error, reason} ->
        raise Error, reason: reason, details: %{moment_index: moment_index}
    end
  end

  # ============================================================================
  # Collection Type Wrapper Constructors
  # ============================================================================

  @doc "Wraps `map` to be stored as an uncounted 16-way HAMT (`Tag.Hash_Map`)."
  @spec hash_map(Enumerable.t()) :: Collection.t()
  def hash_map(map), do: %Collection{kind: :hash_map, data: map}

  @doc "Wraps `map` to be stored as a `Counted_Hash_Map` with `O(1)` `Enum.count/1`."
  @spec counted_map(Enumerable.t()) :: Collection.t()
  def counted_map(map), do: %Collection{kind: :counted_hash_map, data: map}

  @doc "Wraps `map` to be stored as a lexicographically ordered B+Tree (`Sorted_Map`)."
  @spec sorted_map(Enumerable.t()) :: Collection.t()
  def sorted_map(map), do: %Collection{kind: :sorted_map, data: map}

  @doc "Wraps `list` to be stored as a 16-way Radix Trie (`Array_List`)."
  @spec array_list(list()) :: Collection.t()
  def array_list(list) when is_list(list), do: %Collection{kind: :array_list, data: list}

  @doc "Wraps `list` to be stored as a count-augmented B-Tree (`Linked_Array_List`)."
  @spec linked_list(list()) :: Collection.t()
  def linked_list(list) when is_list(list), do: %Collection{kind: :linked_array_list, data: list}

  @doc "Wraps `members` to be stored as a 16-way HAMT `Hash_Set`."
  @spec hash_set(Enumerable.t()) :: Collection.t()
  def hash_set(members), do: %Collection{kind: :hash_set, data: members}

  @doc "Wraps `members` to be stored as a `Counted_Hash_Set` with `O(1)` `Enum.count/1`."
  @spec counted_set(Enumerable.t()) :: Collection.t()
  def counted_set(members), do: %Collection{kind: :counted_hash_set, data: members}

  @doc "Wraps `members` to be stored as a lexicographically ordered B+Tree `Sorted_Set`."
  @spec sorted_set(Enumerable.t()) :: Collection.t()
  def sorted_set(members), do: %Collection{kind: :sorted_set, data: members}

  # ============================================================================
  # Coarse-Grained Transactions (`transact/3`, `insert_at/4`, `delete_at/3`, `fork/3`)
  # ============================================================================

  @doc """
  Executes an atomic transaction committing a new moment to `db`.

  Accepts either:
  - A map of top-level keys/subtrees (`Xitdb.transact(db, %{"users" => ...}, opts)`), or
  - A 1-arity callback receiving the root `%Xitdb.Cursor{}` (`Xitdb.transact(db, fn root -> put_in(root["a"]["b"], 1) end)`).

  ## Options
  #{NimbleOptions.docs(@transact_schema)}
  """
  @spec transact(t(), map() | (Cursor.t() -> Cursor.t() | map() | {:abort, term()}), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def transact(db, map_or_fun, opts \\ [])

  def transact(%__MODULE__{} = db, map, opts) when is_map(map) and not is_struct(map) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      ops = TxCompiler.compile_moment_map(map, Keyword.delete(validated, :index_rules))
      do_transact_ops(db, ops, validated)
    end
  end

  def transact(%__MODULE__{db_ref: db_ref} = db, fun, opts) when is_function(fun, 1) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      base_moment = validated[:base_moment]

      root_cursor = %Cursor{
        db_ref: db_ref,
        tag: :hash_map,
        tag_id: -1,
        value: base_moment,
        moment: base_moment,
        root: true,
        tx_mode: true
      }

      try do
        case fun.(root_cursor) do
          %Cursor{staged_ops: ops} ->
            do_transact_ops(db, :lists.reverse(ops), validated)

          {:abort, reason} ->
            {:error, %Error{reason: reason}}

          other when is_map(other) and not is_struct(other) ->
            ops = TxCompiler.compile_moment_map(other, Keyword.delete(validated, :index_rules))
            do_transact_ops(db, ops, validated)

          other ->
            {:error, %Error{reason: :invalid_transaction_return, details: %{value: other}}}
        end
      rescue
        e in Error ->
          {:error, e}

        e ->
          {:error, %Error{reason: :transaction_exception, details: %{exception: e}}}
      end
    end
  end

  @doc "Same as `transact/3`, but raises `Xitdb.Error` on failure."
  @spec transact!(t(), map() | (Cursor.t() -> Cursor.t() | map() | {:abort, term()}), keyword()) ::
          t()
  def transact!(%__MODULE__{} = db, map_or_fun, opts \\ []) do
    db |> transact(map_or_fun, opts) |> Error.unwrap!()
  end

  @doc """
  Executes a list of low-level transaction tuples (`{:put, path, val}`, `{:insert, path, idx, val}`, etc.)
  in a single atomic NIF transaction commit.
  """
  @spec transact_ops(t(), list(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def transact_ops(%__MODULE__{} = db, ops, opts \\ []) when is_list(ops) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      do_transact_ops(db, ops, validated)
    end
  end

  defp do_transact_ops(%__MODULE__{db_ref: db_ref} = db, ops, validated) do
    base_moment = validated[:base_moment]
    doc = validated[:doc]

    existing_index_ops =
      for {:index_on, _, _, _} = op <- ops, into: MapSet.new(), do: op

    index_ops =
      validated
      |> Keyword.get(:index_rules, [])
      |> Enum.map(fn {:index_on, src, field, idx} ->
        {:index_on, to_string(src), to_string(field), to_string(idx)}
      end)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(existing_index_ops, &1))

    opt_ops =
      index_ops ++
        case validated[:instant] do
          inst when is_integer(inst) -> [{:instant, inst}]
          _ -> []
        end ++
        case validated[:meta] do
          meta when is_map(meta) or is_list(meta) ->
            Enum.map(meta, fn {k, v} -> {:meta, to_string(k), v} end)

          _ ->
            []
        end

    case NIF.nif_transact(db_ref, base_moment, opt_ops ++ ops, doc) do
      {:ok, _} -> {:ok, db}
      {:error, reason} -> {:error, %Error{reason: reason}}
    end
  end

  @doc """
  Stages an `O(log N)` insertion into a `Linked_Array_List` at `path_or_selector` and `index`
  on a root `%Xitdb.Cursor{}` inside `Xitdb.transact/2`.

  `path_or_selector` can be a selector string (`path(users[id].queue)`) or a list of keys /
  typed `{kind, key}` steps (`[{:counted, "users"}, "alice", "queue"]`).
  """
  @spec insert_at(Cursor.t(), String.t() | [term()], integer(), term()) :: Cursor.t()
  def insert_at(%Cursor{} = root, path_or_selector, index, value)
      when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
    selector = Selector.format_path_steps(path_or_selector)
    %Cursor{root | staged_ops: [{:insert, selector, index, value} | root.staged_ops]}
  end

  @doc """
  Stages an `O(log N)` removal from a `Linked_Array_List` at `path_or_selector` and `index`
  on a root `%Xitdb.Cursor{}` inside `Xitdb.transact/2`.
  """
  @spec delete_at(Cursor.t(), String.t() | [term()], integer()) :: Cursor.t()
  def delete_at(%Cursor{} = root, path_or_selector, index)
      when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
    selector =
      Selector.format_path_steps(path_or_selector) <>
        Selector.format_step(:linked_array_list, index)

    %Cursor{root | staged_ops: [{:rm, selector} | root.staged_ops]}
  end

  @doc """
  Stages an `O(1)` zero-copy structural clone (`tx_fork`) from `from_selector` to `to_selector`.
  """
  @spec fork(Cursor.t(), String.t(), String.t()) :: Cursor.t()
  def fork(%Cursor{} = root, from_selector, to_selector) do
    %Cursor{root | staged_ops: [{:fork, from_selector, to_selector} | root.staged_ops]}
  end

  # ============================================================================
  # Materialize, Select, Pull, Diff, History, Datalog & Compaction
  # ============================================================================

  @doc """
  Eagerly materializes a `%Xitdb.Cursor{}` (or `%Xitdb{}` database handle) into native
  Elixir maps (`%{}`), lists (`[]`), sets (`MapSet.t()`), and scalars.
  """
  @spec materialize(t() | Cursor.t() | term()) :: term()
  def materialize(%__MODULE__{} = db) do
    materialize(as_of(db, -1))
  end

  def materialize(%Cursor{} = cursor) do
    %Cursor{db_ref: db_ref, tag_id: tag_id, value: val, full: full, moment: moment} =
      Cursor.ensure_resolved(cursor)

    full_int = if full, do: 1, else: 0

    case NIF.nif_slot_materialize(db_ref, tag_id, val, full_int) do
      {:ok, raw} -> Cursor.unwrap_nif_value(db_ref, raw, moment, [])
      {:error, reason} -> raise Error, reason: reason
    end
  end

  def materialize(scalar), do: scalar

  @doc """
  Resolves a canonical root-anchored `xitdb` selector string (`~x|.users["101"].todos[1]|`)
  against `db` or a committed root snapshot `%Xitdb.Cursor{}` (from `Xitdb.db/1` or `Xitdb.as_of/2`).
  """
  @spec select(t() | Cursor.t(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def select(%__MODULE__{db_ref: db_ref}, selector) when is_binary(selector) do
    do_select(db_ref, -1, selector)
  end

  def select(%Cursor{root: true, tx_mode: false, db_ref: db_ref, moment: moment}, selector)
      when is_binary(selector) do
    do_select(db_ref, moment, selector)
  end

  def select(%Cursor{tag: tag, tx_mode: tx_mode}, selector) when is_binary(selector) do
    {:error,
     %Error{
       reason: :non_root_cursor,
       details: %{tag: tag, tx_mode: tx_mode, selector: selector}
     }}
  end

  defp do_select(db_ref, moment, selector) do
    case NIF.nif_select(db_ref, moment, selector) do
      {:ok, raw} -> {:ok, Cursor.unwrap_nif_value(db_ref, raw, moment, [])}
      {:error, reason} -> {:error, %Error{reason: reason, details: %{selector: selector}}}
    end
  end

  @doc "Same as `select/2`, but raises `Xitdb.Error` on failure."
  @spec select!(t() | Cursor.t(), String.t()) :: term()
  def select!(target, selector), do: target |> select(selector) |> Error.unwrap!()

  @doc """
  Executes a Datomic-style Pull projection against a `%Xitdb.Cursor{}` or `%Xitdb{}` handle.

  Accepts either a raw Pull pattern string (`"{username, age, todos[0..3], profile{city}}"`)
  or a structural Elixir list (`[:username, :age, todos: 0..2, profile: [:city]]`).
  """
  @spec pull(t() | Cursor.t(), Pull.pattern()) :: {:ok, term()} | {:error, Error.t()}
  def pull(%__MODULE__{} = db, pattern) do
    pull(as_of(db, -1), pattern)
  end

  def pull(%Cursor{} = cursor, pattern) when is_binary(pattern) do
    %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = Cursor.ensure_resolved(cursor)

    db_ref |> NIF.nif_pull(tag_id, val, pattern) |> Error.wrap(%{pattern: pattern})
  end

  def pull(%Cursor{} = cursor, pattern) when is_list(pattern) do
    with {:ok, compiled} <- Pull.compile(pattern) do
      pull(cursor, compiled)
    end
  end

  @doc "Same as `pull/2`, but raises `Xitdb.Error` on failure."
  @spec pull!(t() | Cursor.t(), Pull.pattern()) :: term()
  def pull!(target, pattern), do: target |> pull(pattern) |> Error.unwrap!()

  @doc """
  Computes the structural diff between `moment_a` and `moment_b`, skipping unchanged
  subtrees in `O(1)` via 9-byte `Slot` equality.
  """
  @spec diff_moments(t(), integer(), integer()) :: {:ok, [map()]} | {:error, Error.t()}
  def diff_moments(%__MODULE__{db_ref: db_ref}, moment_a, moment_b)
      when is_integer(moment_a) and is_integer(moment_b) do
    db_ref |> NIF.nif_diff_moments(moment_a, moment_b) |> Error.wrap()
  end

  @doc """
  Returns the historical lineage of `selector` across all moments where its `Slot` changed.
  """
  @spec history_of(t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def history_of(%__MODULE__{db_ref: db_ref}, selector) when is_binary(selector) do
    db_ref |> NIF.nif_history_of(selector) |> Error.wrap(%{selector: selector})
  end

  @doc """
  Executes a Datalog query (`~q"find ?e, ?name where ..."`) against `db` or a `%Xitdb.Cursor{}`.

  ## Options
  #{NimbleOptions.docs(@query_schema)}
  """
  @spec query(t() | Cursor.t(), String.t(), keyword()) ::
          {:ok, %{vars: [String.t()], rows: [[term()]]}} | {:error, Error.t()}
  def query(target, query_str, opts \\ [])

  def query(%__MODULE__{db_ref: db_ref}, query_str, opts) when is_binary(query_str) do
    with {:ok, validated} <- validate_opts(opts, @query_schema) do
      moment = Keyword.get(validated, :moment, -1)
      do_query(db_ref, moment, query_str)
    end
  end

  def query(%Cursor{db_ref: db_ref, moment: cursor_moment}, query_str, opts)
      when is_binary(query_str) do
    with {:ok, validated} <- validate_opts(opts, @query_schema) do
      moment = Keyword.get(validated, :moment, cursor_moment)
      do_query(db_ref, moment, query_str)
    end
  end

  defp do_query(db_ref, moment, query_str) do
    db_ref |> NIF.nif_query_datalog(moment, query_str) |> Error.wrap()
  end

  @doc "Same as `query/3`, but raises `Xitdb.Error` on failure."
  @spec query!(t() | Cursor.t(), String.t(), keyword()) :: %{vars: [String.t()], rows: [[term()]]}
  def query!(target, query_str, opts \\ []) do
    target |> query(query_str, opts) |> Error.unwrap!()
  end

  @doc """
  Compacts `db` into a new database keeping only the latest committed moment and deduplicating
  reachable slots.

  ## Options
  #{NimbleOptions.docs(@compact_schema)}
  """
  @spec compact(t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def compact(%__MODULE__{db_ref: db_ref, hash: hash}, opts \\ []) do
    with {:ok, validated} <- validate_opts(opts, @compact_schema) do
      target_path = validated[:path]
      backend = if target_path == "", do: :memory, else: :buffered_file

      case NIF.nif_compact(db_ref, target_path) do
        {:ok, new_ref} ->
          {:ok, %__MODULE__{db_ref: new_ref, backend: backend, path: target_path, hash: hash}}

        {:error, reason} ->
          {:error, %Error{reason: reason}}
      end
    end
  end

  @doc "Same as `compact/2`, but raises `Xitdb.Error` on failure."
  @spec compact!(t(), keyword()) :: t()
  def compact!(%__MODULE__{} = db, opts \\ []), do: db |> compact(opts) |> Error.unwrap!()

  # ============================================================================
  # Access Delegation on `%Xitdb{}` (`db["users"]["alice"]`)
  # ============================================================================

  @impl Access
  def fetch(%__MODULE__{db_ref: db_ref}, key) do
    Cursor.fetch(
      %Cursor{db_ref: db_ref, tag: :hash_map, tag_id: -1, value: -1, moment: -1, root: true},
      key
    )
  end

  @impl Access
  def get_and_update(%__MODULE__{}, _key, _fun) do
    raise ArgumentError,
          "cannot mutate %Xitdb{} directly; wrap put_in/update_in/pop_in inside Xitdb.transact/3 or Xitdb.DSL.tx/3"
  end

  @impl Access
  def pop(%__MODULE__{}, _key) do
    raise ArgumentError,
          "cannot mutate %Xitdb{} directly; wrap pop_in inside Xitdb.transact/3 or Xitdb.DSL.tx/3"
  end

  @doc """
  Returns an `Access` lens function for positive or negative integer list indices
  that works on both `%Xitdb.Cursor{}` list collections and standard Elixir lists
  (unlike `Access.at/1`, which guards `when is_list(data)`).
  """
  @spec at(integer()) :: Access.access_fun(Cursor.t() | list(), term())
  def at(index) when is_integer(index) do
    fn
      :get, data, next ->
        case Access.fetch(data, index) do
          {:ok, val} -> next.(val)
          :error -> next.(nil)
        end

      :get_and_update, data, next ->
        Access.get_and_update(data, index, next)
    end
  end

  @doc false
  @spec validate_transact_opts(term()) :: {:ok, keyword()} | {:error, Error.t()}
  def validate_transact_opts(opts), do: validate_opts(opts, @transact_schema)

  defp validate_opts(opts, schema) when is_list(opts) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, %NimbleOptions.ValidationError{} = err} ->
        {:error, Error.wrap(:invalid_options, %{message: Exception.message(err)})}
    end
  end

  defp validate_opts(other, _schema) do
    {:error,
     Error.wrap(:invalid_options, %{
       message: "expected keyword list of options, got: #{inspect(other)}"
     })}
  end
end
