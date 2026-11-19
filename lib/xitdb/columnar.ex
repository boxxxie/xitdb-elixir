defmodule Xitdb.Columnar do
  @moduledoc """
  Parquet-style row-group columnar storage and read path on top of `Xitdb`.

  Groups rows into fixed-size row groups (`:row_group_size`, default `128`), encodes each
  configured column slice into an immutable `"XCP1"` `Xitdb.Columnar.Page` stored under
  `["__col_pages", collection, field, page_id]`, and replaces non-nil row field values with
  a compact `"pg"` `format_tag` pointer.

  Reads inspect only metadata keys when columnar attributes are omitted (performing `0` page
  reads and `0` page decompressions), and lazily load, cache (bounded LRU ETS table
  `:xitdb_page_cache`), and `O(1)` slice individual column values when a `"pg"` field is
  actually traversed or selected.
  """

  alias Xitdb.{Compression, Cursor, Error, NIF}
  alias Xitdb.Columnar.Page

  @version_pg 0x10
  @default_row_group_size 128
  @max_row_group_size 65_536
  @page_cache_table :xitdb_page_cache
  @page_cache_limit 128
  @stats_key :xitdb_columnar_stats

  @type column_spec :: atom() | String.t() | {atom() | String.t(), keyword() | map()}
  @type row_entry :: {term(), map()}

  @doc """
  Writes `rows` into `collection` using Parquet-style row-group column pages.

  Returns `{:ok, updated_db}` or `{:error, %Xitdb.Error{}}`.

  ## Options
  - `:columns` — list of column names or `{name, opts}` tuples to store in column pages.
  - `:row_group_size` — rows per column page group (default `128`).
  - `:encoding` — `:auto | :plain_block | :dict_rle | :dict_block` (default `:auto`).
  - `:codec` — `:zstd | :zlib | :none` (default `Xitdb.Compression.default_codec/0`).
  - `:level` — codec compression level.
  - `:dictionary` — shared dictionary name under `__dicts`.
  - `:dictionary_bytes` — preloaded dictionary binary (optional).
  """
  @spec put_rows(Xitdb.t(), atom() | String.t(), [row_entry()] | map(), keyword()) ::
          {:ok, Xitdb.t()} | {:error, Error.t()}
  def put_rows(db_or_cursor, collection, rows, opts \\ [])

  def put_rows(%Xitdb{} = db, collection, rows, opts) when is_list(opts) do
    with {:ok, ops} <- build_put_ops(db, collection, rows, opts) do
      Xitdb.transact_ops(db, ops)
    end
  end

  def put_rows(_other, _collection, _rows, _opts) do
    {:error, %Error{reason: :invalid_options, details: %{reason: :expected_xitdb_struct}}}
  end

  @doc "Same as `put_rows/4`, but raises `Xitdb.Error` on failure."
  @spec put_rows!(Xitdb.t(), atom() | String.t(), [row_entry()] | map(), keyword()) :: Xitdb.t()
  def put_rows!(db_or_cursor, collection, rows, opts \\ []) do
    db_or_cursor |> put_rows(collection, rows, opts) |> Error.unwrap!()
  end

  @doc """
  Builds the list of `{:put, path, value}` transaction operations for writing `rows` into
  `collection` with row-group column pages, without executing the transaction.
  """
  @spec build_put_ops(
          Xitdb.t() | Cursor.t() | nil,
          atom() | String.t(),
          [row_entry()] | map(),
          keyword()
        ) ::
          {:ok, [tuple()]} | {:error, Error.t()}
  def build_put_ops(db_or_cursor, collection, rows, opts \\ [])

  def build_put_ops(db_or_cursor, collection, rows, opts)
      when (is_atom(collection) or is_binary(collection)) and is_list(opts) do
    col_str = to_string(collection)
    columns = Keyword.get(opts, :columns, [])
    {db_ref, moment} = extract_db_handle(db_or_cursor)

    group_opts =
      opts
      |> maybe_put_opt(:db_ref, db_ref)
      |> maybe_put_opt(:moment, moment)

    with {:ok, row_list} <- normalize_rows(rows),
         {:ok, page_ops, updated_rows} <-
           build_columnar_ops_for_groups(col_str, row_list, columns, group_opts) do
      row_ops =
        Enum.map(updated_rows, fn {row_key, row_map} ->
          {:put, [col_str, normalize_row_key(row_key)], row_map}
        end)

      {:ok, page_ops ++ row_ops}
    end
  end

  def build_put_ops(_db_or_cursor, _collection, _rows, _opts) do
    {:error, %Error{reason: :invalid_options}}
  end

  @doc """
  Encodes columnar page writes and rewrites row maps to hold `"pg"` pointers across row groups.

  Returns `{:ok, page_ops, updated_rows}` where:
  - `page_ops` is a list of `{:put, ["__col_pages", col_str, field_str, page_id], page_binary}` ops.
  - `updated_rows` is `[{row_key, updated_row_map}, ...]` preserving row order.

  Reusable by `Xitdb.Ash.Indexer` and `Xitdb.Ash.Mutator` for bulk atomic commits.
  """
  @spec build_columnar_ops_for_groups(
          atom() | String.t(),
          [row_entry()],
          [column_spec()],
          keyword()
        ) ::
          {:ok, [tuple()], [row_entry()]} | {:error, Error.t()}
  def build_columnar_ops_for_groups(collection, rows, columns, opts \\ [])

  def build_columnar_ops_for_groups(collection, rows, columns, opts)
      when (is_atom(collection) or is_binary(collection)) and is_list(rows) and is_list(columns) and
             is_list(opts) do
    col_str = to_string(collection)
    row_group_size = Keyword.get(opts, :row_group_size, @default_row_group_size)

    cond do
      byte_size(col_str) == 0 or byte_size(col_str) > 65_535 ->
        {:error, %Error{reason: :invalid_options, details: %{collection: col_str}}}

      not is_integer(row_group_size) or row_group_size <= 0 or
          row_group_size > @max_row_group_size ->
        {:error, %Error{reason: :invalid_options, details: %{row_group_size: row_group_size}}}

      rows == [] or columns == [] ->
        {:ok, [], rows}

      true ->
        with {:ok, col_configs} <- normalize_columns(columns, opts),
             {:ok, dict_cache} <- preload_dictionaries(col_configs, opts[:db_ref], opts[:moment]) do
          process_row_groups(col_str, rows, col_configs, row_group_size, dict_cache)
        end
    end
  end

  def build_columnar_ops_for_groups(_collection, _rows, _columns, _opts) do
    {:error, %Error{reason: :invalid_options}}
  end

  @doc """
  Resolves a `"pg"` tagged binary pointer into the decompressed binary field value (or `nil`).

  Consults the bounded ETS page cache `:xitdb_page_cache` before falling back to reading and
  decoding the target `"XCP1"` page from `["__col_pages", collection, field, page_id]`.
  """
  @spec read_pointer(binary(), reference(), integer(), keyword()) ::
          {:ok, binary() | nil} | {:error, Error.t()}
  def read_pointer(payload, db_ref, moment, opts \\ [])

  def read_pointer(payload, db_ref, moment, opts)
      when is_binary(payload) and is_reference(db_ref) and is_integer(moment) and is_list(opts) do
    with {:ok, col, field, page_id, row_idx} <- parse_pointer(payload),
         {:ok, page} <- fetch_or_decode_page(col, field, page_id, db_ref, moment, opts) do
      bump_stat(:row_decodes)
      Page.decode_row(page, row_idx)
    end
  end

  def read_pointer(_payload, nil, _moment, _opts) do
    {:error, %Error{reason: :missing_database_handle}}
  end

  def read_pointer(_payload, _db_ref, _moment, _opts) do
    {:error, %Error{reason: :corrupt_column_page}}
  end

  @doc """
  Encodes a `"pg"` wire pointer binary referencing `{collection, field, page_id, row_idx}`.
  """
  @spec encode_pointer(String.t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, binary()} | {:error, Error.t()}
  def encode_pointer(col, field, page_id, row_idx)
      when is_binary(col) and is_binary(field) and is_binary(page_id) and
             is_integer(row_idx) and row_idx >= 0 and row_idx < 0x1_0000_0000 do
    col_len = byte_size(col)
    field_len = byte_size(field)
    page_id_len = byte_size(page_id)

    if col_len in 1..65_535 and field_len in 1..65_535 and page_id_len in 1..255 do
      bin =
        <<@version_pg::8, col_len::unsigned-little-16, col::binary, field_len::unsigned-little-16,
          field::binary, page_id_len::8, page_id::binary, row_idx::unsigned-little-32>>

      {:ok, bin}
    else
      {:error, %Error{reason: :invalid_column_page}}
    end
  end

  def encode_pointer(_col, _field, _page_id, _row_idx) do
    {:error, %Error{reason: :invalid_column_page}}
  end

  @doc """
  Parses a `"pg"` wire pointer binary into `{:ok, collection, field, page_id, row_idx}`.
  """
  @spec parse_pointer(binary()) ::
          {:ok, String.t(), String.t(), String.t(), non_neg_integer()} | {:error, Error.t()}
  def parse_pointer(
        <<@version_pg::8, col_len::unsigned-little-16, col::binary-size(col_len),
          field_len::unsigned-little-16, field::binary-size(field_len), page_id_len::8,
          page_id::binary-size(page_id_len), row_idx::unsigned-little-32>>
      )
      when col_len > 0 and field_len > 0 and page_id_len > 0 do
    {:ok, col, field, page_id, row_idx}
  end

  def parse_pointer(_other) do
    {:error, %Error{reason: :corrupt_column_page}}
  end

  @doc """
  Clears cached decoded column pages from `:xitdb_page_cache`.

  Pass `:all` (default) to wipe the global cache, or pass a `%Xitdb{}` handle or
  `%Xitdb.Cursor{}` to evict only entries belonging to that database reference.
  """
  @spec clear_cache(:all | Xitdb.t() | Cursor.t()) :: :ok
  def clear_cache(target \\ :all) do
    case :ets.whereis(@page_cache_table) do
      :undefined ->
        :ok

      _tid when target == :all ->
        :ets.delete_all_objects(@page_cache_table) && :ok

      _tid ->
        case extract_db_handle(target) do
          {db_ref, _} when is_reference(db_ref) ->
            ref_id = :erlang.ref_to_list(db_ref)
            :ets.match_delete(@page_cache_table, {{ref_id, :_, :_, :_, :_}, :_, :_, :_})
            :ok

          _ ->
            :ok
        end
    end
  end

  @doc """
  Resets per-process columnar observability counters (`page_reads`, `page_cache_hits`,
  `page_decompressions`, `row_decodes`) to zero.
  """
  @spec reset_stats() :: :ok
  def reset_stats do
    Process.put(@stats_key, initial_stats())
    :ok
  end

  @doc """
  Returns the current per-process columnar read statistics map.
  """
  @spec stats() :: %{
          page_reads: non_neg_integer(),
          page_cache_hits: non_neg_integer(),
          page_decompressions: non_neg_integer(),
          row_decodes: non_neg_integer()
        }
  def stats do
    Process.get(@stats_key, initial_stats())
  end

  # ============================================================================
  # Private Helpers — Writing & Row Grouping
  # ============================================================================

  defp extract_db_handle(%Xitdb{db_ref: db_ref}), do: {db_ref, -1}
  defp extract_db_handle(%Cursor{db_ref: db_ref, moment: moment}), do: {db_ref, moment}
  defp extract_db_handle(_), do: {nil, nil}

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, val), do: Keyword.put_new(opts, key, val)

  defp normalize_rows(rows) when is_list(rows) do
    if Enum.all?(rows, fn
         {_k, m} when is_map(m) -> true
         _ -> false
       end) do
      {:ok, rows}
    else
      {:error, %Error{reason: :invalid_options, details: %{reason: :expected_key_map_pairs}}}
    end
  end

  defp normalize_rows(rows) when is_map(rows) and not is_struct(rows) do
    rows |> Map.to_list() |> normalize_rows()
  end

  defp normalize_rows(_other) do
    {:error, %Error{reason: :invalid_options, details: %{reason: :expected_rows_list_or_map}}}
  end

  defp normalize_row_key(k) when is_atom(k), do: Atom.to_string(k)
  defp normalize_row_key(k), do: k

  defp normalize_columns(columns, base_opts) do
    shared_opts =
      base_opts
      |> Keyword.take([:encoding, :codec, :level, :dictionary, :dictionary_bytes])

    columns
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      case normalize_single_column(spec, shared_opts) do
        {:ok, cfg} -> {:cont, {:ok, [cfg | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp normalize_single_column(name, shared_opts) when is_atom(name) or is_binary(name) do
    normalize_single_column({name, []}, shared_opts)
  end

  defp normalize_single_column({name, col_opts}, shared_opts)
       when (is_atom(name) or is_binary(name)) and (is_list(col_opts) or is_map(col_opts)) do
    field_str = to_string(name)

    if byte_size(field_str) in 1..65_535 do
      field_atom = if is_atom(name), do: name, else: nil
      merged = Keyword.merge(shared_opts, Enum.into(col_opts, []))
      {:ok, %{field_str: field_str, field_atom: field_atom, opts: merged}}
    else
      {:error, %Error{reason: :invalid_options, details: %{column: name}}}
    end
  end

  defp normalize_single_column(other, _shared_opts) do
    {:error, %Error{reason: :invalid_options, details: %{column: other}}}
  end

  defp preload_dictionaries(col_configs, db_ref, moment) do
    col_configs
    |> Enum.reduce_while({:ok, %{}}, fn %{opts: opts}, {:ok, cache} ->
      case {Keyword.get(opts, :dictionary), Keyword.get(opts, :dictionary_bytes)} do
        {nil, _} ->
          {:cont, {:ok, cache}}

        {_dict_name, dict_bytes} when is_binary(dict_bytes) ->
          {:cont, {:ok, cache}}

        {dict_name, nil} ->
          dict_str = to_string(dict_name)

          cond do
            Map.has_key?(cache, dict_str) ->
              {:cont, {:ok, cache}}

            is_nil(db_ref) ->
              {:cont, {:ok, cache}}

            true ->
              case Compression.fetch_dictionary_bytes(db_ref, moment, dict_str) do
                {:ok, bytes} -> {:cont, {:ok, Map.put(cache, dict_str, bytes)}}
                {:error, %Error{reason: :missing_compression_dictionary}} -> {:cont, {:ok, cache}}
              end
          end
      end
    end)
  end

  defp process_row_groups(col_str, rows, col_configs, row_group_size, dict_cache) do
    rows
    |> Enum.chunk_every(row_group_size)
    |> Enum.reduce_while({:ok, [], []}, fn group, {:ok, ops_rev, rows_rev} ->
      case encode_single_group(col_str, group, col_configs, dict_cache) do
        {:ok, group_page_ops, updated_group} ->
          {:cont,
           {:ok, Enum.reverse(group_page_ops, ops_rev), Enum.reverse(updated_group, rows_rev)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, ops_rev, rows_rev} -> {:ok, Enum.reverse(ops_rev), Enum.reverse(rows_rev)}
      err -> err
    end
  end

  defp encode_single_group(col_str, group, col_configs, dict_cache) do
    col_configs
    |> Enum.reduce_while({:ok, [], group}, fn cfg, {:ok, page_ops_acc, cur_group} ->
      case encode_column_in_group(col_str, cur_group, cfg, dict_cache) do
        {:ok, nil, unchanged_group} ->
          {:cont, {:ok, page_ops_acc, unchanged_group}}

        {:ok, page_op, updated_group} ->
          {:cont, {:ok, [page_op | page_ops_acc], updated_group}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, page_ops_rev, updated_group} -> {:ok, Enum.reverse(page_ops_rev), updated_group}
      err -> err
    end
  end

  defp encode_column_in_group(
         col_str,
         group,
         %{field_str: field_str, field_atom: field_atom, opts: col_opts},
         dict_cache
       ) do
    {page_values_rev, rewrite_mask_rev} =
      Enum.reduce(group, {[], []}, fn {_row_key, row_map}, {vals, mask} ->
        case extract_column_value(row_map, field_str, field_atom) do
          {:ok, map_key, bin} when is_binary(bin) ->
            {[bin | vals], [map_key | mask]}

          {:ok, map_key, {:compressed, bin, _comp_opts}} when is_binary(bin) ->
            {[bin | vals], [map_key | mask]}

          _ ->
            {[nil | vals], [nil | mask]}
        end
      end)

    page_values = Enum.reverse(page_values_rev)

    if Enum.all?(page_values, &is_nil/1) do
      {:ok, nil, group}
    else
      page_id = new_page_id()
      page_opts = attach_cached_dict(col_opts, dict_cache)

      with {:ok, page_bin} <- Page.encode_page(page_values, page_opts),
           {:ok, updated_group} <-
             rewrite_group_column_pointers(
               group,
               Enum.reverse(rewrite_mask_rev),
               col_str,
               field_str,
               page_id
             ) do
        page_op = {:put, ["__col_pages", col_str, field_str, page_id], page_bin}
        {:ok, page_op, updated_group}
      end
    end
  end

  defp extract_column_value(row_map, field_str, field_atom) do
    case Map.fetch(row_map, field_str) do
      {:ok, val} ->
        {:ok, field_str, val}

      :error ->
        if is_atom(field_atom) do
          case Map.fetch(row_map, field_atom) do
            {:ok, val} -> {:ok, field_atom, val}
            :error -> :missing
          end
        else
          :missing
        end
    end
  end

  defp attach_cached_dict(col_opts, dict_cache) do
    case {Keyword.get(col_opts, :dictionary), Keyword.get(col_opts, :dictionary_bytes)} do
      {dict_name, nil} when not is_nil(dict_name) ->
        case Map.fetch(dict_cache, to_string(dict_name)) do
          {:ok, bytes} -> Keyword.put(col_opts, :dictionary_bytes, bytes)
          :error -> col_opts
        end

      _ ->
        col_opts
    end
  end

  defp rewrite_group_column_pointers(group, mask_keys, col_str, field_str, page_id) do
    group
    |> Enum.zip(mask_keys)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{{row_key, row_map}, map_key}, row_idx}, {:ok, acc} ->
      if is_nil(map_key) do
        {:cont, {:ok, [{row_key, row_map} | acc]}}
      else
        case encode_pointer(col_str, field_str, page_id, row_idx) do
          {:ok, ptr_bin} ->
            updated_map = Map.put(row_map, map_key, {:tagged, "pg", ptr_bin})
            {:cont, {:ok, [{row_key, updated_map} | acc]}}

          {:error, _} = err ->
            {:halt, err}
        end
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      err -> err
    end
  end

  defp new_page_id do
    "p_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # ============================================================================
  # Private Helpers — Reading, Caching & Stats
  # ============================================================================

  defp fetch_or_decode_page(col, field, page_id, db_ref, moment, opts) do
    ensure_page_cache_table()

    max_bytes =
      Keyword.get(opts, :max_decompressed_bytes, Compression.default_max_decompressed_bytes())

    cache_key = {:erlang.ref_to_list(db_ref), moment, col, field, page_id}

    case :ets.lookup(@page_cache_table, cache_key) do
      [{^cache_key, %Page{} = page, raw_len, _ts}] ->
        if raw_len > max_bytes do
          {:error,
           %Error{
             reason: :decompressed_size_exceeded,
             details: %{raw_len: raw_len, max_decompressed_bytes: max_bytes}
           }}
        else
          :ets.update_element(
            @page_cache_table,
            cache_key,
            {4, System.monotonic_time(:nanosecond)}
          )

          bump_stat(:page_cache_hits)
          {:ok, page}
        end

      [] ->
        bump_stat(:page_reads)

        case NIF.nif_select(db_ref, moment, ["__col_pages", col, field, page_id], true) do
          {:ok, page_bin} when is_binary(page_bin) ->
            decode_opts =
              opts
              |> Keyword.take([:dictionary_bytes, :max_decompressed_bytes])
              |> Keyword.merge(db_ref: db_ref, moment: moment)

            bump_stat(:page_decompressions)

            with {:ok, %Page{} = page} <- Page.decode_page(page_bin, decode_opts) do
              <<_::binary-size(11), raw_len::unsigned-little-32, _::binary>> = page_bin
              insert_cached_page(cache_key, page, raw_len)
              {:ok, page}
            end

          {:ok, nil} ->
            {:error,
             %Error{
               reason: :missing_column_page,
               details: %{collection: col, field: field, page_id: page_id}
             }}

          {:error, reason} when is_atom(reason) ->
            {:error, %Error{reason: reason}}

          _other ->
            {:error, %Error{reason: :corrupt_column_page}}
        end
    end
  end

  defp insert_cached_page(cache_key, %Page{} = page, raw_len) do
    ensure_page_cache_table()

    if :ets.info(@page_cache_table, :size) >= @page_cache_limit do
      case :ets.tab2list(@page_cache_table) do
        [] ->
          :ok

        entries ->
          {oldest_key, _page, _raw_len, _ts} =
            Enum.min_by(entries, fn {_k, _p, _len, ts} -> ts end)

          :ets.delete(@page_cache_table, oldest_key)
      end
    end

    :ets.insert(
      @page_cache_table,
      {cache_key, page, raw_len, System.monotonic_time(:nanosecond)}
    )

    :ok
  end

  defp ensure_page_cache_table do
    case :ets.whereis(@page_cache_table) do
      :undefined ->
        try do
          :ets.new(@page_cache_table, [
            :named_table,
            :public,
            :set,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end

  defp initial_stats do
    %{
      page_reads: 0,
      page_cache_hits: 0,
      page_decompressions: 0,
      row_decodes: 0
    }
  end

  defp bump_stat(key) do
    stats = Process.get(@stats_key, initial_stats())
    Process.put(@stats_key, Map.update!(stats, key, &(&1 + 1)))
    :ok
  end
end
