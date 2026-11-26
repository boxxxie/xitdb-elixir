defmodule Xitdb do
  @moduledoc """
  Embedded, immutable single-file database for Elixir powered by
  [`xitdb`](https://github.com/xit-vcs/xitdb).

  `Xitdb` stores nested maps, lists, sorted B+Tree maps, and sets directly in `:memory`
  or a single `.xit` file, committing every transaction as an immutable snapshot ("moment")
  with structural sharing. Navigate data lazily with standard Elixir `Access`
  (`db["users"]["alice"]["roles"][0]`) and `Enum`/`Stream`, or use `Xitdb.DSL`,
  `Xitdb.pull/2`, Datalog `query/3`, and `Xitdb.Ash.DataLayer`.

  ## Quick Example

      {:ok, db} = Xitdb.open(backend: :memory)
      {:ok, db} = Xitdb.transact(db, %{"users" => %{"alice" => %{"age" => 30}}})

      v0 = Xitdb.as_of(db, 0)
      {:ok, db} = Xitdb.transact(db, fn root -> update_in(root["users"]["alice"]["age"], &(&1 + 1)) end)

      v0["users"]["alice"]["age"] # => 30
      db["users"]["alice"]["age"] # => 31

  ## Guides
  - [Reading & Updating with Access & Enum](docs/access-and-enumerable.md)
  - [Collections & Secondary Indexes](docs/collections-and-indexing.md)
  - [Time-Travel, Diffs & Storage](docs/time-travel-and-storage.md)
  - [Transaction DSL](docs/transaction-dsl.md)
  - [Path Selectors & Pull Projections](docs/path-and-pull-dsl.md)
  - [Datalog & Graph Queries](docs/datalog-dsl.md)
  - [Ash Framework & Full-Text Search](docs/ash-and-spark.md)
  - [Architecture, Internals & Performance](docs/architecture-and-internals.md)
  """

  @behaviour Access

  alias Xitdb.{Collection, Compression, Cursor, Error, NIF, Pull, Selector, TxCompiler}

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
                 ],
                 read_only: [
                   type: :boolean,
                   default: false,
                   doc:
                     "Opens file-backed stores strictly read-only without creating missing files or allowing mutations."
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
                       type: {:or, [{:map, {:or, [:atom, :string]}, :any}, :keyword_list]},
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
                     ],
                     compress: [
                       type: {:or, [:boolean, :keyword_list]},
                       default: false,
                       doc:
                         "Automatic value compression (`true` or keyword list `[codec: :zstd | :zlib, min_bytes: 128, min_savings: 16, dictionary: name, intern: true]`)."
                     ]
                   )

  @query_schema NimbleOptions.new!(
                  moment: [
                    type: :integer,
                    doc:
                      "Historical moment index to query (`-1` for latest; defaults to cursor moment when querying a `%Xitdb.Cursor{}`)."
                  ],
                  raw_tagged: [
                    type: :boolean,
                    default: false,
                    doc:
                      "When `true`, returns raw `{:tagged, tag, payload}` payloads instead of transparently decompressing."
                  ],
                  max_decompressed_bytes: [
                    type: :pos_integer,
                    doc: "Upper limit on decompressed payload size in bytes."
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

  @default_open_opts NimbleOptions.validate!([], @open_schema)
  @default_transact_opts NimbleOptions.validate!([], @transact_schema)
  @default_query_opts NimbleOptions.validate!([], @query_schema)
  @default_compact_opts NimbleOptions.validate!([], @compact_schema)
  @tx_context_key :xitdb_tx_context

  @enforce_keys [:db_ref, :backend]
  defstruct [:db_ref, :backend, :path, hash: :sha1, read_only: false, write_epoch: nil]

  @type t :: %__MODULE__{
          db_ref: reference(),
          backend: :memory | :file | :buffered_file,
          path: String.t() | nil,
          hash: :sha1 | :sha256,
          read_only: boolean(),
          write_epoch: non_neg_integer() | nil
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
      read_only = validated[:read_only]

      if backend in [:file, :buffered_file] and path == "" do
        {:error, %Error{reason: :missing_path, details: %{backend: backend}}}
      else
        case NIF.nif_open(backend, path, hash, read_only) do
          {:ok, db_ref} ->
            {:ok,
             %__MODULE__{
               db_ref: db_ref,
               backend: backend,
               path: path,
               hash: hash,
               read_only: read_only
             }}

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
  def close(%__MODULE__{db_ref: db_ref} = db) do
    Xitdb.Columnar.clear_cache(db)
    NIF.nif_close(db_ref)
  end

  @doc "Synchronizes buffered writes to disk."
  @spec sync(t()) :: :ok | {:error, Error.t()}
  def sync(%__MODULE__{db_ref: db_ref}) do
    db_ref |> NIF.nif_sync() |> Error.wrap()
  end

  @doc false
  @spec bump_write_epoch(t()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def bump_write_epoch(%__MODULE__{db_ref: db_ref}) do
    db_ref |> NIF.nif_bump_write_epoch() |> Error.wrap()
  end

  @doc false
  @spec bump_write_epoch!(t()) :: pos_integer()
  def bump_write_epoch!(%__MODULE__{} = db) do
    db |> bump_write_epoch() |> Error.unwrap!()
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
    case NIF.nif_moment_slot(db_ref, moment_index, true) do
      {:ok, tuple, resolved_moment} ->
        cursor = Cursor.from_nif_tuple(db_ref, tuple, resolved_moment)
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

  def transact(%__MODULE__{db_ref: db_ref} = db, map, [])
      when is_map(map) and not is_struct(map) do
    encoded_map = TxCompiler.encode_value(map)

    if Compression.needs_prepare?(encoded_map, false) do
      {:ok, prepared_map, blob_ops} = Compression.prepare_write(db, encoded_map, false)
      ops = blob_ops ++ TxCompiler.compile_moment_map(prepared_map)
      do_transact_ops_default(db, db_ref, ops)
    else
      ops = TxCompiler.compile_moment_map(encoded_map)
      do_transact_ops_default(db, db_ref, ops)
    end
  rescue
    e in Protocol.UndefinedError ->
      {:error, %Error{reason: :transaction_exception, details: %{exception: e}}}
  end

  def transact(%__MODULE__{} = db, map, opts) when is_map(map) and not is_struct(map) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      try do
        compress_opt = validated[:compress]
        encoded_map = TxCompiler.encode_value(map)

        if Compression.needs_prepare?(encoded_map, compress_opt) do
          target = if validated[:base_moment] == -1, do: db, else: {db, validated[:base_moment]}

          {:ok, prepared_map, blob_ops} =
            Compression.prepare_write(target, encoded_map, compress_opt)

          ops = blob_ops ++ TxCompiler.compile_moment_map(prepared_map)
          do_transact_ops(db, ops, Keyword.put(validated, :compress, false))
        else
          ops = TxCompiler.compile_moment_map(encoded_map)
          do_transact_ops(db, ops, validated)
        end
      rescue
        e in Protocol.UndefinedError ->
          {:error, %Error{reason: :transaction_exception, details: %{exception: e}}}
      end
    end
  end

  def transact(%__MODULE__{db_ref: db_ref} = db, fun, []) when is_function(fun, 1) do
    run_transact_fun(db, db_ref, fun, -1, :default)
  end

  def transact(%__MODULE__{db_ref: db_ref} = db, fun, opts) when is_function(fun, 1) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      run_transact_fun(db, db_ref, fun, validated[:base_moment], validated)
    end
  end

  defp run_transact_fun(db, db_ref, fun, base_moment, validated_or_default) do
    {root_cursor, pinned_validated} =
      cond do
        base_moment == -1 ->
          case NIF.nif_moment_slot(db_ref, -1, true) do
            {:ok, _tuple, resolved_moment} when resolved_moment >= 0 ->
              opts = put_base_moment_opt(validated_or_default, {:strict, resolved_moment})

              cursor = %Cursor{
                db_ref: db_ref,
                tag: :hash_map,
                tag_id: -1,
                value: resolved_moment,
                moment: resolved_moment,
                root: true,
                tx_mode: true
              }

              {cursor, opts}

            _ ->
              case NIF.nif_info(db_ref) do
                {:ok, %{moment_count: 0}} ->
                  opts = put_base_moment_opt(validated_or_default, {:strict, -1})

                  cursor = %Cursor{
                    db_ref: db_ref,
                    tag: :hash_map,
                    tag_id: 4,
                    value: 0,
                    moment: -1,
                    root: true,
                    tx_mode: true
                  }

                  {cursor, opts}

                _ ->
                  cursor = %Cursor{
                    db_ref: db_ref,
                    tag: :hash_map,
                    tag_id: -1,
                    value: base_moment,
                    moment: base_moment,
                    root: true,
                    tx_mode: true
                  }

                  {cursor, validated_or_default}
              end
          end

        base_moment < -1 ->
          {pinned_moment, opts} =
            case NIF.nif_moment_slot(db_ref, base_moment, true) do
              {:ok, _tuple, resolved_moment} ->
                {resolved_moment, put_base_moment_opt(validated_or_default, resolved_moment)}

              {:error, _} ->
                {base_moment, validated_or_default}
            end

          cursor = %Cursor{
            db_ref: db_ref,
            tag: :hash_map,
            tag_id: -1,
            value: pinned_moment,
            moment: pinned_moment,
            root: true,
            tx_mode: true
          }

          {cursor, opts}

        true ->
          cursor = %Cursor{
            db_ref: db_ref,
            tag: :hash_map,
            tag_id: -1,
            value: base_moment,
            moment: base_moment,
            root: true,
            tx_mode: true
          }

          {cursor, validated_or_default}
      end

    try do
      case fun.(root_cursor) do
        %Cursor{staged_ops: [_] = ops} ->
          dispatch_transact_ops(db, db_ref, ops, pinned_validated)

        %Cursor{staged_ops: ops} ->
          dispatch_transact_ops(db, db_ref, :lists.reverse(ops), pinned_validated)

        {:abort, reason} ->
          {:error, %Error{reason: reason}}

        other when is_map(other) and not is_struct(other) ->
          ops = TxCompiler.compile_moment_map(other)
          dispatch_transact_ops(db, db_ref, ops, pinned_validated)

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

  defp put_base_moment_opt(:default, base_moment),
    do: Keyword.put(@default_transact_opts, :base_moment, base_moment)

  defp put_base_moment_opt(validated, base_moment),
    do: Keyword.put(validated, :base_moment, base_moment)

  defp dispatch_transact_ops(db, db_ref, ops, :default) do
    if Compression.needs_prepare?(ops, false) do
      {:ok, prepared_ops, blob_ops} = Compression.prepare_write(db, ops, false)
      do_transact_ops_default(db, db_ref, blob_ops ++ prepared_ops)
    else
      do_transact_ops_default(db, db_ref, ops)
    end
  end

  defp dispatch_transact_ops(db, _db_ref, ops, validated) do
    do_transact_ops(db, ops, validated)
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

  @doc false
  @spec transact_ops_with_moment(t(), list(), keyword()) ::
          {:ok, t(), integer()} | {:error, Error.t()}
  def transact_ops_with_moment(%__MODULE__{} = db, ops, opts \\ []) when is_list(ops) do
    with {:ok, validated} <- validate_opts(opts, @transact_schema) do
      do_transact_ops_with_moment(db, ops, validated)
    end
  end

  @doc """
  Executes `fun.()` with ambient transaction attribution (`:doc`, `:instant`, `:meta`)
  automatically merged into every `Xitdb` commit executed on the current process.

  Nested calls merge `:meta` keys over the outer context and restore the previous
  context when `fun.()` exits. Explicit call-site options override ambient values.
  """
  @spec with_tx_context(keyword() | map(), (-> result)) :: result when result: var
  def with_tx_context(tx_opts, fun)
      when (is_list(tx_opts) or is_map(tx_opts)) and is_function(fun, 0) do
    prev = Process.get(@tx_context_key)
    Process.put(@tx_context_key, merge_tx_context(prev, tx_opts))

    try do
      fun.()
    after
      if prev == nil do
        Process.delete(@tx_context_key)
      else
        Process.put(@tx_context_key, prev)
      end
    end
  end

  @doc """
  Returns the active ambient transaction attribution context for the current process,
  or `nil` when unset.
  """
  @spec current_tx_context() ::
          %{doc: String.t() | nil, instant: integer() | nil, meta: map()} | nil
  def current_tx_context, do: Process.get(@tx_context_key)

  @doc """
  Reads the `__tx` commit metadata map for `target` (`%Xitdb{}` or `%Xitdb.Cursor{}`)
  at `moment` (defaulting to the latest moment `-1` for `%Xitdb{}` or the cursor's
  pinned moment for `%Xitdb.Cursor{}`).
  """
  @spec tx_meta(t() | Cursor.t(), integer() | nil) :: {:ok, map()} | {:error, Error.t()}
  def tx_meta(target, moment \\ nil)

  def tx_meta(%__MODULE__{db_ref: db_ref} = db, nil) do
    if moment_count(db) == 0 do
      {:ok, %{}}
    else
      fetch_tx_meta(db_ref, -1)
    end
  end

  def tx_meta(%__MODULE__{db_ref: db_ref}, moment) when is_integer(moment) do
    fetch_tx_meta(db_ref, moment)
  end

  def tx_meta(%Cursor{root: true, tx_mode: false, tag: :none}, nil), do: {:ok, %{}}

  def tx_meta(%Cursor{db_ref: db_ref, moment: cursor_moment}, moment)
      when is_nil(moment) or is_integer(moment) do
    target_moment = if is_nil(moment), do: cursor_moment, else: moment
    fetch_tx_meta(db_ref, target_moment)
  end

  @doc "Same as `tx_meta/2`, but raises `Xitdb.Error` on failure."
  @spec tx_meta!(t() | Cursor.t(), integer() | nil) :: map()
  def tx_meta!(target, moment \\ nil) do
    target |> tx_meta(moment) |> Error.unwrap!()
  end

  defp fetch_tx_meta(db_ref, moment) when is_integer(moment) do
    case NIF.nif_moment_slot(db_ref, moment, true) do
      {:ok, tuple, resolved_moment} ->
        base_cursor = Cursor.from_nif_tuple(db_ref, tuple, resolved_moment)

        if base_cursor.tag == :none do
          {:ok, %{}}
        else
          root_cursor = %Cursor{base_cursor | root: true}

          case pull(root_cursor, "{__tx}") do
            {:ok, %{"__tx" => %{} = meta}} -> {:ok, meta}
            {:ok, _other} -> {:ok, %{}}
            {:error, _} = err -> err
          end
        end

      {:error, reason} ->
        {:error, %Error{reason: reason, details: %{moment_index: moment}}}
    end
  end

  defp do_transact_ops(%__MODULE__{db_ref: db_ref} = db, ops, @default_transact_opts) do
    eff_ops =
      if Compression.needs_prepare?(ops, false) do
        {:ok, prepared_ops, blob_ops} = Compression.prepare_write(db, ops, false)
        blob_ops ++ prepared_ops
      else
        ops
      end

    do_transact_ops_default(db, db_ref, eff_ops)
  end

  defp do_transact_ops(%__MODULE__{} = db, ops, validated) do
    with {:ok, updated_db, _moment_idx} <- do_transact_ops_with_moment(db, ops, validated) do
      {:ok, updated_db}
    end
  end

  defp do_transact_ops_default(db, db_ref, ops) do
    case Process.get(@tx_context_key) do
      nil ->
        case timed_nif_transact(db, db_ref, -1, ops, length(ops), "") do
          {:ok, _moment_idx} -> {:ok, db}
          {:error, _} = err -> err
        end

      ctx ->
        with {:ok, updated_db, _moment_idx} <-
               do_transact_ops_with_context(db, ops, @default_transact_opts, ctx) do
          {:ok, updated_db}
        end
    end
  end

  defp do_transact_ops_with_moment(%__MODULE__{db_ref: db_ref} = db, ops, @default_transact_opts) do
    eff_ops =
      if Compression.needs_prepare?(ops, false) do
        {:ok, prepared_ops, blob_ops} = Compression.prepare_write(db, ops, false)
        blob_ops ++ prepared_ops
      else
        ops
      end

    case Process.get(@tx_context_key) do
      nil ->
        case timed_nif_transact(db, db_ref, -1, eff_ops, length(ops), "") do
          {:ok, moment_idx} -> {:ok, db, moment_idx}
          {:error, _} = err -> err
        end

      ctx ->
        do_transact_ops_with_context(db, eff_ops, @default_transact_opts, ctx)
    end
  end

  defp do_transact_ops_with_moment(%__MODULE__{} = db, ops, validated) do
    do_transact_ops_with_context(db, ops, validated, Process.get(@tx_context_key))
  end

  defp do_transact_ops_with_context(%__MODULE__{db_ref: db_ref} = db, ops, validated, ctx) do
    base_moment = validated[:base_moment]

    doc =
      case validated[:doc] do
        d when is_binary(d) and d != "" -> d
        _ -> (ctx && ctx.doc) || ""
      end

    compress_opt = Keyword.get(validated, :compress, false)

    {prepared_ops, blob_ops} =
      if Compression.needs_prepare?(ops, compress_opt) do
        target =
          case base_moment do
            m when m in [-1, {:strict, -1}] -> db
            {:strict, m} -> {db, m}
            m -> {db, m}
          end

        {:ok, p_ops, b_ops} = Compression.prepare_write(target, ops, compress_opt)
        {p_ops, b_ops}
      else
        {ops, []}
      end

    index_ops =
      case validated[:index_rules] do
        rules when is_list(rules) and rules != [] ->
          existing_index_ops =
            for {:index_on, _, _, _} = op <- prepared_ops, into: MapSet.new(), do: op

          rules
          |> Enum.map(fn {:index_on, src, field, idx} ->
            {:index_on, to_string(src), to_string(field), to_string(idx)}
          end)
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(existing_index_ops, &1))

        _ ->
          []
      end

    instant = validated[:instant] || (ctx && ctx.instant)

    opt_ops =
      case instant do
        inst when is_integer(inst) -> index_ops ++ [{:instant, inst}]
        _ -> index_ops
      end

    ambient_meta = if ctx, do: ctx.meta, else: %{}
    explicit_meta = normalize_tx_meta(validated[:meta])
    merged_meta = Map.merge(ambient_meta, explicit_meta)

    opt_ops =
      if map_size(merged_meta) > 0 do
        opt_ops ++ Enum.map(merged_meta, fn {k, v} -> {:meta, k, v} end)
      else
        opt_ops
      end

    prefix_ops = opt_ops ++ blob_ops
    all_ops = if prefix_ops == [], do: prepared_ops, else: prefix_ops ++ prepared_ops

    case timed_nif_transact(db, db_ref, base_moment, all_ops, length(ops), doc) do
      {:ok, moment_idx} -> {:ok, db, moment_idx}
      {:error, _} = err -> err
    end
  end

  defp timed_nif_transact(db, db_ref, base_moment, nif_ops, user_op_count, doc) do
    started = System.monotonic_time()

    case NIF.nif_transact(db_ref, base_moment, nif_ops, doc, db.write_epoch) do
      {:ok, moment_idx} ->
        duration = System.monotonic_time() - started

        :telemetry.execute(
          [:xitdb, :tx, :commit],
          %{duration: duration, op_count: user_op_count},
          %{backend: db.backend, doc: doc}
        )

        {:ok, moment_idx}

      {:error, reason} ->
        {:error, %Error{reason: reason}}
    end
  end

  defp merge_tx_context(prev, tx_opts) do
    opts_map = Map.new(tx_opts)

    doc =
      case Map.get(opts_map, :doc) || Map.get(opts_map, "doc") do
        d when is_binary(d) and d != "" -> d
        _ -> prev && prev.doc
      end

    instant =
      case Map.get(opts_map, :instant) || Map.get(opts_map, "instant") do
        i when is_integer(i) -> i
        _ -> prev && prev.instant
      end

    prev_meta = if prev, do: prev.meta, else: %{}
    incoming_meta = normalize_tx_meta(Map.get(opts_map, :meta) || Map.get(opts_map, "meta"))

    %{doc: doc, instant: instant, meta: Map.merge(prev_meta, incoming_meta)}
  end

  defp normalize_tx_meta(nil), do: %{}

  defp normalize_tx_meta(meta) when is_map(meta) or is_list(meta) do
    Enum.reduce(meta, %{}, fn
      {_k, nil}, acc ->
        acc

      {k, v}, acc ->
        case normalize_tx_meta_value(v) do
          nil -> acc
          clean -> Map.put(acc, to_string(k), clean)
        end
    end)
  end

  defp normalize_tx_meta(_other), do: %{}

  defp normalize_tx_meta_value(nil), do: nil
  defp normalize_tx_meta_value(v) when is_boolean(v), do: v
  defp normalize_tx_meta_value(v) when is_atom(v), do: Atom.to_string(v)

  defp normalize_tx_meta_value(v) when is_list(v) do
    v |> Enum.map(&normalize_tx_meta_value/1) |> Enum.reject(&is_nil/1)
  end

  defp normalize_tx_meta_value(v) when is_map(v) and not is_struct(v) do
    normalize_tx_meta(v)
  end

  defp normalize_tx_meta_value(v) when is_binary(v) or is_number(v), do: v
  defp normalize_tx_meta_value(v), do: to_string(v)

  @doc """
  Stages an `O(log N)` insertion into a `Linked_Array_List` at `path_or_selector` and `index`
  on a root `%Xitdb.Cursor{}` inside `Xitdb.transact/2`.

  `path_or_selector` can be a selector string (`path(users[id].queue)`) or a list of keys /
  typed `{kind, key}` steps (`[{:counted, "users"}, "alice", "queue"]`).
  """
  @spec insert_at(Cursor.t(), String.t() | [term()], integer(), term()) :: Cursor.t()
  def insert_at(%Cursor{} = root, path_or_selector, index, value)
      when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
    encoded = TxCompiler.encode_value(value)
    updated = Cursor.stage_list_insert(root, path_or_selector, index, encoded)

    %Cursor{
      updated
      | tx_mode: true,
        staged_ops: [{:insert, path_or_selector, index, encoded} | updated.staged_ops]
    }
  end

  @doc """
  Stages an `O(log N)` removal from a `Linked_Array_List` at `path_or_selector` and `index`
  on a root `%Xitdb.Cursor{}` inside `Xitdb.transact/2`.
  """
  @spec delete_at(Cursor.t(), String.t() | [term()], integer()) :: Cursor.t()
  def delete_at(%Cursor{} = root, path_or_selector, index)
      when (is_list(path_or_selector) or is_binary(path_or_selector)) and is_integer(index) do
    selector =
      if is_binary(path_or_selector) do
        path_or_selector <> Selector.format_step(:linked_array_list, index)
      else
        path_or_selector ++ [[index]]
      end

    updated = Cursor.stage_list_delete(root, path_or_selector, index)

    %Cursor{
      updated
      | tx_mode: true,
        staged_ops: [{:rm, selector} | updated.staged_ops]
    }
  end

  @doc """
  Stages an `O(1)` zero-copy structural clone (`tx_fork`) from `from_selector` to `to_selector`.
  """
  @spec fork(Cursor.t(), String.t() | [term()], String.t() | [term()]) :: Cursor.t()
  def fork(%Cursor{} = root, from_selector, to_selector)
      when (is_binary(from_selector) or is_list(from_selector)) and
             (is_binary(to_selector) or is_list(to_selector)) do
    updated = Cursor.fork_staged_prefix(root, from_selector, to_selector)

    %Cursor{
      updated
      | tx_mode: true,
        staged_ops: [{:fork, from_selector, to_selector} | updated.staged_ops]
    }
  end

  # ============================================================================
  # Materialize, Select, Pull, Diff, History, Datalog & Compaction
  # ============================================================================

  @doc """
  Eagerly materializes a `%Xitdb.Cursor{}` (or `%Xitdb{}` database handle) into native
  Elixir maps (`%{}`), lists (`[]`), sets (`MapSet.t()`), and scalars.

  ## Options
  - `:raw_tagged` (`boolean()`) — returns raw `{:tagged, tag, payload}` tuples when `true` (default `false`).
  - `:max_decompressed_bytes` (`pos_integer()`) — maximum decompressed size per value.
  """
  @spec materialize(t() | Cursor.t() | term(), keyword()) :: term()
  def materialize(target, opts \\ [])

  def materialize(%__MODULE__{} = db, opts) when is_list(opts) do
    materialize(as_of(db, -1), opts)
  end

  def materialize(%Cursor{root: true, tx_mode: false, tag: :none}, opts) when is_list(opts),
    do: %{}

  def materialize(%Cursor{} = cursor, opts) when is_list(opts) do
    raw_tagged? = Keyword.get(opts, :raw_tagged, false)
    max_bytes = fetch_max_decompressed_bytes!(opts)

    base =
      cond do
        cursor.root and cursor.tag == :none ->
          nil

        cursor.root and cursor.tag_id != -1 and cursor.value == 0 ->
          case NIF.nif_slot_materialize(
                 cursor.db_ref,
                 cursor.tag_id,
                 0,
                 0,
                 raw_tagged?,
                 max_bytes
               ) do
            {:ok, raw} -> raw
            {:error, reason} -> raise Error, reason: reason
          end

        cursor.root ->
          case NIF.nif_slot_materialize(
                 cursor.db_ref,
                 -1,
                 cursor.moment,
                 0,
                 raw_tagged?,
                 max_bytes
               ) do
            {:ok, raw} -> raw
            {:error, reason} -> raise Error, reason: reason
          end

        cursor.tx_mode and cursor.value == 0 ->
          Cursor.resolve_fork_disk_base(cursor) || empty_cursor_default(cursor.tag)

        true ->
          %Cursor{db_ref: db_ref, tag_id: tag_id, value: val, full: full} =
            Cursor.ensure_resolved(cursor)

          full_int = if full, do: 1, else: 0

          case NIF.nif_slot_materialize(db_ref, tag_id, val, full_int, raw_tagged?, max_bytes) do
            {:ok, raw} -> raw
            {:error, reason} -> raise Error, reason: reason
          end
      end

    resolved_base =
      if raw_tagged? do
        base
      else
        Compression.resolve_term!(base, cursor.db_ref, cursor.moment, opts)
      end

    Cursor.apply_staged_overlay(cursor, resolved_base)
  end

  def materialize(scalar, opts) when is_list(opts), do: scalar

  defp empty_cursor_default(tag) when tag in [:hash_map, :counted_hash_map, :sorted_map], do: %{}
  defp empty_cursor_default(tag) when tag in [:array_list, :linked_array_list], do: []

  defp empty_cursor_default(tag) when tag in [:hash_set, :counted_hash_set, :sorted_set],
    do: MapSet.new()

  defp empty_cursor_default(_), do: nil

  @doc """
  Resolves a canonical root-anchored `xitdb` selector string (`~x|.users["101"].todos[1]|`)
  against `db` or a committed root snapshot `%Xitdb.Cursor{}` (from `Xitdb.db/1` or `Xitdb.as_of/2`).

  ## Options
  - `:raw_tagged` (`boolean()`) — returns raw `{:tagged, tag, payload}` tuples without decoding (default `false`).
  - `:max_decompressed_bytes` (`pos_integer()`) — maximum allowed decoded payload size in bytes.
  """
  @compile {:inline, do_select: 4, do_select!: 4}
  @spec select(t() | Cursor.t(), String.t() | [term()], keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def select(target, selector, opts \\ [])

  def select(%__MODULE__{db_ref: db_ref}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    do_select(db_ref, -1, selector, opts)
  end

  def select(%Cursor{root: true, tx_mode: false, tag: :none} = cursor, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    if root_selector?(selector), do: {:ok, cursor}, else: {:ok, nil}
  end

  def select(%Cursor{root: true, tx_mode: false, db_ref: db_ref, moment: moment}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    do_select(db_ref, moment, selector, opts)
  end

  def select(%Cursor{tag: tag, tx_mode: tx_mode}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    {:error,
     %Error{
       reason: :non_root_cursor,
       details: %{tag: tag, tx_mode: tx_mode, selector: selector}
     }}
  end

  defp do_select(db_ref, moment, selector, opts) do
    eff_moment = resolve_pinned_moment(db_ref, effective_moment(moment, selector))
    pinned_selector = pin_selector_moment(selector, eff_moment)
    raw_tagged? = Keyword.get(opts, :raw_tagged, false)

    with {:ok, max_bytes} <- fetch_max_decompressed_bytes(opts) do
      case NIF.nif_select(db_ref, eff_moment, pinned_selector, raw_tagged?, max_bytes) do
        {:ok, raw} when is_binary(raw) or is_number(raw) or is_boolean(raw) or is_nil(raw) ->
          {:ok, raw}

        {:ok, raw} ->
          if raw_tagged? do
            case raw do
              {:tagged, _, _} -> {:ok, raw}
              _ -> {:ok, wrap_selected(db_ref, raw, eff_moment, pinned_selector)}
            end
          else
            case raw do
              {:tagged, tag, payload} when is_binary(payload) ->
                if Compression.compression_tag?(tag) do
                  Compression.resolve_tagged(tag, payload, db_ref, eff_moment, opts)
                else
                  {:ok, raw}
                end

              _ ->
                {:ok, wrap_selected(db_ref, raw, eff_moment, pinned_selector)}
            end
          end

        {:error, reason} ->
          {:error, %Error{reason: reason, details: %{selector: selector}}}
      end
    end
  end

  defp wrap_selected(db_ref, raw, eff_moment, selector) do
    eff_moment = resolve_pinned_moment(db_ref, eff_moment)

    case Cursor.unwrap_nif_value(db_ref, raw, eff_moment, []) do
      %Cursor{} = cursor ->
        cursor = %{cursor | moment: eff_moment}
        if root_selector?(selector), do: %{cursor | root: true}, else: cursor

      other ->
        other
    end
  end

  defp pin_selector_moment(sel, eff_moment) when is_binary(sel) and eff_moment >= 0 do
    trimmed = String.trim_leading(sel)

    case trimmed do
      <<"@", rest::binary>> ->
        case Integer.parse(rest) do
          {m, tail} when m < 0 -> "@#{eff_moment}" <> tail
          _ -> sel
        end

      _ ->
        sel
    end
  end

  defp pin_selector_moment([{:at_moment, m} | rest], eff_moment)
       when is_integer(m) and m < 0 and eff_moment >= 0 do
    [{:at_moment, eff_moment} | rest]
  end

  defp pin_selector_moment(sel, _eff_moment), do: sel

  defp resolve_pinned_moment(_db_ref, m) when is_integer(m) and m >= 0, do: m

  defp resolve_pinned_moment(db_ref, m) when is_integer(m) and m < 0 do
    case NIF.nif_moment_slot(db_ref, m, true) do
      {:ok, _tuple, resolved} -> resolved
      _ -> m
    end
  end

  defp root_selector?([]), do: true
  defp root_selector?([{:at_moment, _}]), do: true

  defp root_selector?(sel) when is_binary(sel) do
    trimmed = String.trim(sel)

    cond do
      trimmed == "" ->
        true

      String.starts_with?(trimmed, "@") ->
        case Integer.parse(binary_part(trimmed, 1, byte_size(trimmed) - 1)) do
          {_m, tail} -> String.trim(tail) == ""
          :error -> false
        end

      true ->
        false
    end
  end

  defp root_selector?(_), do: false

  defp effective_moment(moment, sel) when is_binary(sel) do
    case String.trim_leading(sel) do
      <<"@", rest::binary>> ->
        case Integer.parse(rest) do
          {m, _tail} -> m
          :error -> moment
        end

      _ ->
        moment
    end
  end

  defp effective_moment(_moment, [{:at_moment, m} | _]) when is_integer(m), do: m
  defp effective_moment(moment, _selector), do: moment

  @doc "Same as `select/3`, but raises `Xitdb.Error` on failure."
  @spec select!(t() | Cursor.t(), String.t() | [term()], keyword()) :: term()
  def select!(target, selector, opts \\ [])

  def select!(%__MODULE__{db_ref: db_ref}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    do_select!(db_ref, -1, selector, opts)
  end

  def select!(%Cursor{root: true, tx_mode: false, tag: :none} = cursor, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    if root_selector?(selector), do: cursor, else: nil
  end

  def select!(%Cursor{root: true, tx_mode: false, db_ref: db_ref, moment: moment}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    do_select!(db_ref, moment, selector, opts)
  end

  def select!(%Cursor{tag: tag, tx_mode: tx_mode}, selector, opts)
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    raise Error,
      reason: :non_root_cursor,
      details: %{tag: tag, tx_mode: tx_mode, selector: selector}
  end

  defp do_select!(db_ref, moment, selector, opts) do
    case do_select(db_ref, moment, selector, opts) do
      {:ok, val} -> val
      {:error, %Error{} = err} -> raise err
    end
  end

  @doc """
  Executes a Datomic-style Pull projection against a `%Xitdb.Cursor{}` or `%Xitdb{}` handle.

  Accepts either a raw Pull pattern string (`"{username, age, todos[0..3], profile{city}}"`)
  or a structural Elixir list (`[:username, :age, todos: 0..2, profile: [:city]]`).

  ## Options
  - `:raw_tagged` (`boolean()`) — returns raw `{:tagged, tag, payload}` tuples without decoding (default `false`).
  - `:max_decompressed_bytes` (`pos_integer()`) — maximum allowed decoded payload size in bytes.
  """
  @spec pull(t() | Cursor.t(), Pull.pattern(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def pull(target, pattern, opts \\ [])

  def pull(%__MODULE__{db_ref: db_ref}, pattern, opts) when is_list(opts) do
    pull(
      %Cursor{db_ref: db_ref, tag: :hash_map, tag_id: -1, value: -1, moment: -1, root: true},
      pattern,
      opts
    )
  end

  def pull(%Cursor{root: true, tx_mode: false, tag: :none}, pattern, opts)
      when is_binary(pattern) and is_list(opts) do
    {:ok, %{}}
  end

  def pull(%Cursor{} = cursor, pattern, opts) when is_binary(pattern) and is_list(opts) do
    cursor = pin_root_cursor_if_needed(cursor)
    raw_tagged? = Keyword.get(opts, :raw_tagged, false)

    with {:ok, max_bytes} <- fetch_max_decompressed_bytes(opts),
         {:ok, res} <- do_pull_pattern(cursor, pattern, raw_tagged?, max_bytes, opts) do
      if raw_tagged? do
        {:ok, res}
      else
        Compression.resolve_term(res, cursor.db_ref, cursor.moment, opts)
      end
    end
  end

  def pull(%Cursor{} = cursor, pattern, opts) when is_list(pattern) and is_list(opts) do
    with {:ok, compiled} <- Pull.compile(pattern) do
      pull(cursor, compiled, opts)
    end
  end

  defp do_pull_pattern(cursor, pattern, raw_tagged?, max_bytes, opts) do
    if :binary.match(pattern, "*") == :nomatch do
      do_nif_pull(cursor, pattern, raw_tagged?, max_bytes)
    else
      case Pull.split_wildcard_plan(pattern) do
        {:single, single_pat} ->
          do_nif_pull(cursor, single_pat, raw_tagged?, max_bytes)

        {:merge_top, wild_pat, spec_pat} ->
          pinned = pin_root_cursor_if_needed(cursor)

          with {:ok, wild_res} <- do_nif_pull(pinned, wild_pat, raw_tagged?, max_bytes),
               {:ok, spec_res} <- pull(pinned, spec_pat, Keyword.put(opts, :raw_tagged, true)) do
            {:ok, Pull.merge_wildcard_results(wild_res, spec_res)}
          end
      end
    end
  end

  defp pin_root_cursor_if_needed(
         %Cursor{root: true, tx_mode: false, tag_id: -1, moment: moment} = cursor
       )
       when moment < 0 do
    case NIF.nif_moment_slot(cursor.db_ref, moment, true) do
      {:ok, tuple, resolved_moment} ->
        %Cursor{} = resolved = Cursor.from_nif_tuple(cursor.db_ref, tuple, resolved_moment)
        %Cursor{resolved | root: true}

      _ ->
        cursor
    end
  end

  defp pin_root_cursor_if_needed(%Cursor{tx_mode: false, moment: moment} = cursor)
       when moment < 0 do
    %{cursor | moment: resolve_pinned_moment(cursor.db_ref, moment)}
  end

  defp pin_root_cursor_if_needed(cursor), do: cursor

  defp do_nif_pull(
         %Cursor{
           root: true,
           tag: tag,
           tag_id: tag_id,
           value: val,
           db_ref: db_ref,
           moment: moment
         },
         pattern,
         raw_tagged?,
         max_bytes
       )
       when tag != :none do
    {nid, nval} = if tag_id != -1 and val == 0, do: {tag_id, 0}, else: {-1, moment}

    db_ref
    |> NIF.nif_pull(nid, nval, pattern, raw_tagged?, max_bytes)
    |> Error.wrap(%{pattern: pattern})
  end

  defp do_nif_pull(%Cursor{} = cursor, pattern, raw_tagged?, max_bytes) do
    %Cursor{db_ref: db_ref, tag_id: tag_id, value: val} = Cursor.ensure_resolved(cursor)

    db_ref
    |> NIF.nif_pull(tag_id, val, pattern, raw_tagged?, max_bytes)
    |> Error.wrap(%{pattern: pattern})
  end

  @doc "Same as `pull/3`, but raises `Xitdb.Error` on failure."
  @spec pull!(t() | Cursor.t(), Pull.pattern(), keyword()) :: term()
  def pull!(target, pattern, opts \\ []), do: target |> pull(pattern, opts) |> Error.unwrap!()

  @doc """
  Computes the structural diff between `moment_a` and `moment_b`, skipping unchanged
  subtrees in `O(1)` via 9-byte `Slot` equality.

  ## Options
  - `:raw_tagged` (`boolean()`) — keep raw compression tags `{:tagged, tag, payload}` without decoding (default `false`).
  - `:max_decompressed_bytes` (`pos_integer()`) — maximum allowed decoded payload size in bytes.
  - `:include_internal` (`boolean()`) — include `.__blobs`, `.__dicts`, and `.__col_pages` bookkeeping paths (default `false`).
  """
  @spec diff_moments(t(), integer(), integer(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def diff_moments(%__MODULE__{db_ref: db_ref}, moment_a, moment_b, opts \\ [])
      when is_integer(moment_a) and is_integer(moment_b) and is_list(opts) do
    raw_tagged? = Keyword.get(opts, :raw_tagged, false)
    include_internal? = Keyword.get(opts, :include_internal, false)

    with {:ok, max_bytes} <- fetch_max_decompressed_bytes(opts),
         {:ok, raw_diffs} <-
           db_ref
           |> NIF.nif_diff_moments(moment_a, moment_b, raw_tagged?, max_bytes)
           |> Error.wrap() do
      filtered =
        if include_internal? do
          raw_diffs
        else
          Enum.reject(raw_diffs, &internal_diff_path?(&1.path))
        end

      if raw_tagged? do
        {:ok, filtered}
      else
        resolve_diff_entries(filtered, db_ref, moment_a, moment_b, opts)
      end
    end
  end

  @doc """
  Returns the historical lineage of `selector` across all moments where its `Slot` changed.

  ## Options
  - `:raw_tagged` (`boolean()`) — keep raw compression tags `{:tagged, tag, payload}` without decoding (default `false`).
  - `:max_decompressed_bytes` (`pos_integer()`) — maximum allowed decoded payload size in bytes.
  """
  @spec history_of(t(), String.t() | [term()], keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def history_of(%__MODULE__{db_ref: db_ref}, selector, opts \\ [])
      when (is_binary(selector) or is_list(selector)) and is_list(opts) do
    raw_tagged? = Keyword.get(opts, :raw_tagged, false)

    with {:ok, max_bytes} <- fetch_max_decompressed_bytes(opts),
         {:ok, entries} <-
           db_ref
           |> NIF.nif_history_of(selector, raw_tagged?, max_bytes)
           |> Error.wrap(%{selector: selector}) do
      if raw_tagged? do
        {:ok, entries}
      else
        resolve_history_entries(entries, db_ref, opts)
      end
    end
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
      do_query(db_ref, moment, query_str, validated)
    end
  end

  def query(%Cursor{root: true, tx_mode: false, tag: :none, db_ref: db_ref}, query_str, opts)
      when is_binary(query_str) do
    with {:ok, validated} <- validate_opts(opts, @query_schema) do
      case Keyword.get(validated, :moment) do
        nil -> {:ok, %{vars: [], rows: []}}
        moment -> do_query(db_ref, moment, query_str, validated)
      end
    end
  end

  def query(%Cursor{db_ref: db_ref, moment: cursor_moment}, query_str, opts)
      when is_binary(query_str) do
    with {:ok, validated} <- validate_opts(opts, @query_schema) do
      moment = Keyword.get(validated, :moment, cursor_moment)
      do_query(db_ref, moment, query_str, validated)
    end
  end

  defp do_query(db_ref, moment, query_str, validated) do
    moment = resolve_pinned_moment(db_ref, moment)
    raw_tagged = Keyword.get(validated, :raw_tagged, false)

    max_bytes =
      Keyword.get(
        validated,
        :max_decompressed_bytes,
        Compression.default_max_decompressed_bytes()
      )

    run_datalog_loop(db_ref, moment, query_str, raw_tagged, max_bytes, validated, %{}, 16)
  end

  defp run_datalog_loop(
         db_ref,
         moment,
         query_str,
         raw_tagged,
         max_bytes,
         validated,
         predecoded,
         rounds_left
       ) do
    case NIF.nif_query_datalog(db_ref, moment, query_str, raw_tagged, max_bytes, predecoded) do
      {:ok, %{vars: _vars, rows: rows} = res} ->
        if raw_tagged do
          {:ok, res}
        else
          with {:ok, resolved_rows} <- Compression.resolve_term(rows, db_ref, moment, validated) do
            {:ok, %{res | rows: resolved_rows}}
          end
        end

      {:need_decode, missing} ->
        if rounds_left <= 0 do
          {:error,
           %Error{
             reason: :corrupt_compressed_payload,
             details: %{reason: :max_decode_rounds_exceeded}
           }}
        else
          resolved_predecoded =
            Enum.reduce_while(missing, {:ok, predecoded}, fn {m, tag, payload}, {:ok, acc} ->
              case Compression.resolve_tagged(tag, payload, db_ref, m, validated) do
                {:ok, decoded} ->
                  cache_key = <<m::signed-little-64, tag::binary-size(2), payload::binary>>
                  {:cont, {:ok, Map.put(acc, cache_key, decoded)}}

                {:error, _} = err ->
                  {:halt, err}
              end
            end)

          case resolved_predecoded do
            {:ok, next_predecoded} ->
              run_datalog_loop(
                db_ref,
                moment,
                query_str,
                raw_tagged,
                max_bytes,
                validated,
                next_predecoded,
                rounds_left - 1
              )

            {:error, _} = err ->
              err
          end
        end

      other ->
        Error.wrap(other)
    end
  end

  defp internal_diff_path?(path) when is_binary(path) do
    path == ".__blobs" or String.starts_with?(path, ".__blobs.") or
      path == ".__dicts" or String.starts_with?(path, ".__dicts.") or
      path == ".__col_pages" or String.starts_with?(path, ".__col_pages.")
  end

  defp resolve_diff_entries(entries, db_ref, moment_a, moment_b, opts) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, old_v} <- Compression.resolve_term(entry.old_value, db_ref, moment_a, opts),
           {:ok, new_v} <- Compression.resolve_term(entry.new_value, db_ref, moment_b, opts) do
        if old_v == new_v do
          {:cont, {:ok, acc}}
        else
          {:cont, {:ok, [%{entry | old_value: old_v, new_value: new_v} | acc]}}
        end
      else
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, :lists.reverse(rev)}
      err -> err
    end
  end

  defp resolve_history_entries(entries, db_ref, opts) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case Compression.resolve_term(entry.value, db_ref, entry.moment_index, opts) do
        {:ok, resolved_val} ->
          {:cont, {:ok, [%{entry | value: resolved_val} | acc]}}

        err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, :lists.reverse(rev)}
      err -> err
    end
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
  def fetch(%__MODULE__{} = db, key) do
    Cursor.fetch(as_of(db, -1), key)
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
      :get, data, next when is_list(data) ->
        next.(Enum.at(data, index))

      :get, data, next ->
        case Access.fetch(data, index) do
          {:ok, val} -> next.(val)
          :error -> next.(nil)
        end

      :get_and_update, data, next when is_list(data) ->
        len = length(data)
        resolved = if index < 0, do: len + index, else: index

        if resolved >= 0 and resolved < len do
          elem = Enum.at(data, resolved)

          case next.(elem) do
            {get_val, update_val} -> {get_val, List.replace_at(data, resolved, update_val)}
            :pop -> {elem, List.delete_at(data, resolved)}
          end
        else
          case next.(nil) do
            {get_val, _update_val} -> {get_val, data}
            :pop -> {nil, data}
          end
        end

      :get_and_update, data, next ->
        Access.get_and_update(data, index, next)
    end
  end

  @doc false
  @spec validate_transact_opts(term()) :: {:ok, keyword()} | {:error, Error.t()}
  def validate_transact_opts(opts), do: validate_opts(opts, @transact_schema)

  defp validate_opts([], @open_schema), do: {:ok, @default_open_opts}
  defp validate_opts([], @transact_schema), do: {:ok, @default_transact_opts}
  defp validate_opts([], @query_schema), do: {:ok, @default_query_opts}
  defp validate_opts([], @compact_schema), do: {:ok, @default_compact_opts}

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

  defp fetch_max_decompressed_bytes(opts) do
    case Keyword.fetch(opts, :max_decompressed_bytes) do
      :error ->
        {:ok, Compression.default_max_decompressed_bytes()}

      {:ok, max_bytes} when is_integer(max_bytes) and max_bytes > 0 ->
        {:ok, max_bytes}

      {:ok, invalid} ->
        {:error, %Error{reason: :invalid_options, details: %{max_decompressed_bytes: invalid}}}
    end
  end

  defp fetch_max_decompressed_bytes!(opts) do
    opts |> fetch_max_decompressed_bytes() |> Error.unwrap!()
  end
end
