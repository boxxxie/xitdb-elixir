defmodule Xitdb.TestDrivers.ClientDriver do
  @moduledoc """
  Layer 3 Protocol Driver for Xitdb Client ATDD Specifications.
  Isolates direct `Xitdb` API calls, NIF resource handles, cross-cutting
  lazy-vs-eager consistency checks, and temporary file cleanup.
  """
  import ExUnit.Assertions

  def new_context do
    unique_id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "xitdb_ex_test_#{unique_id}")
    File.mkdir_p!(tmp_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{
      tmp_dir: tmp_dir,
      db: nil,
      compacted_db: nil,
      pre_compact_size: 0,
      file_paths: %{},
      index_rules: [],
      snapshots: %{},
      results: %{},
      last_error: nil
    }
  end

  def cleanup_context(ctx) do
    if ctx[:db], do: Xitdb.close(ctx.db)
    if ctx[:compacted_db], do: Xitdb.close(ctx.compacted_db)
    if ctx[:tmp_dir], do: File.rm_rf(ctx.tmp_dir)
    :ok
  end

  def open_database(ctx, opts) do
    {:ok, db} = Xitdb.open(opts)
    ExUnit.Callbacks.on_exit(fn -> Xitdb.close(db) end)
    %{ctx | db: db}
  end

  def open_file_database(ctx, label, opts) do
    path = Path.join(ctx.tmp_dir, "#{label}.xit")
    full_opts = Keyword.merge([path: path, backend: :buffered_file], opts)
    {:ok, db} = Xitdb.open(full_opts)
    ExUnit.Callbacks.on_exit(fn -> Xitdb.close(db) end)
    %{ctx | db: db, file_paths: Map.put(ctx.file_paths, label, path)}
  end

  def reopen_file_database(ctx, label) do
    if ctx.db, do: Xitdb.close(ctx.db)
    path = Map.fetch!(ctx.file_paths, label)
    {:ok, db} = Xitdb.open(path: path, backend: :buffered_file)
    ExUnit.Callbacks.on_exit(fn -> Xitdb.close(db) end)
    %{ctx | db: db}
  end

  def add_index_rule(ctx, source_map, field_key, index_map) do
    rule = {:index_on, source_map, field_key, index_map}
    %{ctx | index_rules: ctx.index_rules ++ [rule]}
  end

  def commit_moment(ctx, data, opts) when is_map(data) do
    tx_opts =
      if ctx.index_rules != [] do
        Keyword.update(opts, :index_rules, ctx.index_rules, &(&1 ++ ctx.index_rules))
      else
        opts
      end

    {:ok, db} = Xitdb.transact(ctx.db, data, tx_opts)
    %{ctx | db: db}
  end

  def pin_snapshot(ctx, snapshot_name, moment_index) do
    cursor = Xitdb.as_of(ctx.db, moment_index)
    %{ctx | snapshots: Map.put(ctx.snapshots, snapshot_name, cursor)}
  end

  def train_dictionary(ctx, name, samples, opts) do
    {:ok, db, _dict_bytes} =
      Xitdb.Compression.Dictionary.train_and_put(ctx.db, name, samples, opts)

    %{ctx | db: db}
  end

  def put_columnar_rows(ctx, collection, rows, opts) do
    {:ok, db} = Xitdb.Columnar.put_rows(ctx.db, collection, rows, opts)
    %{ctx | db: db}
  end

  def reset_columnar_probe(ctx) do
    Xitdb.Columnar.clear_cache()
    Xitdb.Columnar.reset_stats()
    ctx
  end

  def navigate_access(ctx, result_key, path_keys) do
    root = Xitdb.db(ctx.db)
    val = Enum.reduce(path_keys, root, fn key, acc -> acc[key] end)
    %{ctx | results: Map.put(ctx.results, result_key, val)}
  end

  def navigate_get_in(ctx, result_key, access_path) do
    root = Xitdb.db(ctx.db)
    val = Kernel.get_in(root, access_path)
    %{ctx | results: Map.put(ctx.results, result_key, val)}
  end

  def read_cursor_in_tasks(ctx, result_key, cursor_path, sub_keys) do
    cursor = resolve_path(Xitdb.db(ctx.db), cursor_path)
    assert %Xitdb.Cursor{} = cursor

    values =
      sub_keys
      |> Task.async_stream(fn k -> cursor[k] end, max_concurrency: 8)
      |> Enum.map(fn {:ok, v} -> v end)

    %{ctx | results: Map.put(ctx.results, result_key, values)}
  end

  def transact_cursor(ctx, fun) do
    {:ok, db} = Xitdb.transact(ctx.db, fun)
    %{ctx | db: db}
  end

  def transact_ops(ctx, ops, opts) do
    {:ok, db} = Xitdb.transact_ops(ctx.db, ops, opts)
    %{ctx | db: db}
  end

  def attempt_failing_transact(ctx, fun_or_map, opts \\ []) do
    case Xitdb.transact(ctx.db, fun_or_map, opts) do
      {:error, err} ->
        %{ctx | last_error: err}

      {:ok, _} ->
        flunk("Expected transaction to fail and roll back, but it succeeded")
    end
  end

  def execute_dsl_tx(ctx, fun) when is_function(fun, 1) do
    {:ok, db} = fun.(ctx.db)
    %{ctx | db: db}
  end

  def attempt_failing_dsl_tx(ctx, fun) when is_function(fun, 1) do
    case fun.(ctx.db) do
      {:error, err} ->
        %{ctx | last_error: err}

      {:ok, _} ->
        flunk("Expected DSL transaction to fail and roll back, but it succeeded")
    end
  end

  def select_path(ctx, result_key, selector, opts \\ []) do
    val = Xitdb.select!(ctx.db, selector, opts)
    %{ctx | results: Map.put(ctx.results, result_key, val)}
  end

  def seek_sorted_map_range(ctx, result_key, path_keys, opts) do
    cursor = resolve_path(Xitdb.db(ctx.db), path_keys)

    entries =
      cursor
      |> Xitdb.Key.stream_range(opts)
      |> Enum.map(fn {k, v} -> {k, materialize_if_cursor(v)} end)

    %{ctx | results: Map.put(ctx.results, result_key, entries)}
  end

  def pull_projection(ctx, result_key, selector_or_path, pattern, opts \\ []) do
    target =
      case selector_or_path do
        :root -> Xitdb.db(ctx.db)
        path when is_list(path) -> resolve_path(Xitdb.db(ctx.db), path)
        sel when is_binary(sel) -> Xitdb.select!(ctx.db, sel)
      end

    val = Xitdb.pull!(target, pattern, opts)
    %{ctx | results: Map.put(ctx.results, result_key, val)}
  end

  def materialize_path(ctx, result_key, path_keys, opts \\ []) do
    target =
      case path_keys do
        [] -> ctx.db
        _ -> resolve_path(Xitdb.db(ctx.db), path_keys)
      end

    val = Xitdb.materialize(target, opts)
    %{ctx | results: Map.put(ctx.results, result_key, val)}
  end

  def diff_moments(ctx, result_key, moment_a, moment_b) do
    {:ok, diffs} = Xitdb.diff_moments(ctx.db, moment_a, moment_b)
    %{ctx | results: Map.put(ctx.results, result_key, diffs)}
  end

  def history_of(ctx, result_key, selector) do
    {:ok, history} = Xitdb.history_of(ctx.db, selector)
    %{ctx | results: Map.put(ctx.results, result_key, history)}
  end

  def query_datalog(ctx, result_key, query_str, opts) do
    {:ok, res} = Xitdb.query(ctx.db, query_str, opts)
    %{ctx | results: Map.put(ctx.results, result_key, res)}
  end

  def compact_database(ctx, target_label) do
    info_before = Xitdb.info!(ctx.db)
    target_path = Path.join(ctx.tmp_dir, "#{target_label}.xit")
    {:ok, compacted_db} = Xitdb.compact(ctx.db, path: target_path)
    ExUnit.Callbacks.on_exit(fn -> Xitdb.close(compacted_db) end)

    %{
      ctx
      | compacted_db: compacted_db,
        pre_compact_size: info_before.file_size,
        file_paths: Map.put(ctx.file_paths, target_label, target_path)
    }
  end

  def evaluate_quoted_ast(ctx, result_key, quoted_ast) do
    outcome =
      try do
        {val, _binding} = Code.eval_quoted(quoted_ast)
        {:ok, val}
      rescue
        e in CompileError -> {:error, e}
      end

    %{ctx | results: Map.put(ctx.results, result_key, outcome)}
  end

  # ============================================================================
  # Assertions
  # ============================================================================

  def assert_resolved_value(ctx, result_key, expected_value) do
    actual = Map.fetch!(ctx.results, result_key)

    actual_normalized =
      case actual do
        %Xitdb.Cursor{} = cur -> Xitdb.materialize(cur)
        other -> other
      end

    assert actual_normalized == expected_value
    ctx
  end

  def assert_resolved_tag(ctx, result_key, expected_tag) do
    actual = Map.fetch!(ctx.results, result_key)
    assert {:tagged, ^expected_tag, payload} = actual
    assert is_binary(payload)
    ctx
  end

  def assert_columnar_page_reads(ctx, expected_reads) do
    stats = Xitdb.Columnar.stats()
    assert stats.page_reads == expected_reads
    ctx
  end

  def assert_lazy_cursor(ctx, result_key, expected_opts) do
    cursor = Map.fetch!(ctx.results, result_key)
    assert %Xitdb.Cursor{} = cursor

    if expected_kind = Keyword.get(expected_opts, :kind) do
      assert cursor.tag == expected_kind
    end

    assert is_integer(cursor.value) and cursor.value > 0
    ctx
  end

  def assert_access_path_equals(ctx, path_keys, expected_value) do
    root = Xitdb.db(ctx.db)
    actual = resolve_path(root, path_keys)

    actual_val =
      case actual do
        %Xitdb.Cursor{} = cur -> Xitdb.materialize(cur)
        scalar -> scalar
      end

    assert actual_val == expected_value

    # Cross-cutting invariant: Kernel.get_in/2 on root cursor must agree with bracket Access
    if Enum.all?(path_keys, &(is_binary(&1) or is_atom(&1))) do
      get_in_val =
        case Kernel.get_in(root, path_keys) do
          %Xitdb.Cursor{} = cur -> Xitdb.materialize(cur)
          scalar -> scalar
        end

      assert get_in_val == expected_value
    end

    ctx
  end

  def assert_snapshot_access_path_equals(ctx, snapshot_name, path_keys, expected_value) do
    snapshot_cursor = Map.fetch!(ctx.snapshots, snapshot_name)
    actual = resolve_path(snapshot_cursor, path_keys)

    actual_val =
      case actual do
        %Xitdb.Cursor{} = cur -> Xitdb.materialize(cur)
        scalar -> scalar
      end

    assert actual_val == expected_value
    ctx
  end

  def assert_enumerable_count(ctx, path_keys, expected_count) do
    cursor = resolve_path(Xitdb.db(ctx.db), path_keys)
    assert %Xitdb.Cursor{} = cursor
    assert Enum.count(cursor) == expected_count
    ctx
  end

  def assert_enumerable_member(ctx, path_keys, candidate, expected_bool) do
    cursor = resolve_path(Xitdb.db(ctx.db), path_keys)
    assert %Xitdb.Cursor{} = cursor
    assert Enum.member?(cursor, candidate) == expected_bool
    ctx
  end

  def assert_enumerable_slice(ctx, path_keys, range, expected_list) do
    cursor = resolve_path(Xitdb.db(ctx.db), path_keys)
    assert %Xitdb.Cursor{} = cursor
    sliced = Enum.slice(cursor, range) |> Enum.map(&materialize_if_cursor/1)
    assert sliced == expected_list
    ctx
  end

  def assert_enumerable_entries(ctx, path_keys, expected_entries, opts) do
    cursor = resolve_path(Xitdb.db(ctx.db), path_keys)
    assert %Xitdb.Cursor{} = cursor

    actual =
      cursor
      |> Enum.to_list()
      |> Enum.map(&materialize_if_cursor/1)

    if Keyword.get(opts, :ordered, false) do
      assert actual == expected_entries
    else
      assert Enum.sort(actual) == Enum.sort(expected_entries)
    end

    ctx
  end

  def assert_stream_take(ctx, path_keys, count, expected_items) do
    cursor = resolve_path(Xitdb.db(ctx.db), path_keys)
    assert %Xitdb.Cursor{} = cursor

    taken =
      cursor
      |> Stream.map(&materialize_if_cursor/1)
      |> Enum.take(count)

    assert taken == expected_items
    ctx
  end

  def assert_materialized_subtree(ctx, path_keys, expected_term) do
    cursor = resolve_path(Xitdb.db(ctx.db), path_keys)
    assert Xitdb.materialize(cursor) == expected_term
    ctx
  end

  def assert_cursor_inspect(ctx, path_keys, expected_substrings) do
    cursor = resolve_path(Xitdb.db(ctx.db), path_keys)
    inspected = inspect(cursor)

    for sub <- List.wrap(expected_substrings) do
      assert inspected =~ sub
    end

    ctx
  end

  def assert_moment_count(ctx, expected_count) do
    assert Xitdb.moment_count(ctx.db) == expected_count
    ctx
  end

  def assert_last_tx_error(ctx, expected_reason) do
    assert %Xitdb.Error{reason: ^expected_reason} = ctx.last_error
    ctx
  end

  def assert_diff_changes(ctx, result_key, expected_changes) do
    diffs = Map.fetch!(ctx.results, result_key)

    simplified =
      Enum.map(diffs, fn d ->
        {d.op, d.path, d.new_value}
      end)

    assert length(simplified) == length(expected_changes)
    assert Enum.sort(simplified) == Enum.sort(expected_changes)

    ctx
  end

  def assert_history_lineage(ctx, result_key, expected_entries) do
    history = Map.fetch!(ctx.results, result_key)

    simplified =
      Enum.map(history, fn h ->
        base = %{moment: h.moment_index, value: h.value, doc: h.doc}
        if Map.get(h, :instant, 0) != 0, do: Map.put(base, :instant, h.instant), else: base
      end)

    assert simplified == expected_entries
    ctx
  end

  def assert_datalog_rows(ctx, result_key, expected_rows, opts) do
    res = Map.fetch!(ctx.results, result_key)

    if Keyword.get(opts, :ordered, false) do
      assert res.rows == expected_rows
    else
      assert Enum.sort(res.rows) == Enum.sort(expected_rows)
    end

    ctx
  end

  def assert_compacted_valid(ctx, path_keys, expected_value) do
    info_after = Xitdb.info!(ctx.compacted_db)
    assert info_after.file_size < ctx.pre_compact_size
    assert Xitdb.moment_count(ctx.compacted_db) == 1

    root = Xitdb.db(ctx.compacted_db)
    actual = resolve_path(root, path_keys) |> materialize_if_cursor()
    assert actual == expected_value
    ctx
  end

  def assert_ash_action_has_change(ctx, resource, action_name, expected_change_tuple) do
    action = Ash.Resource.Info.action(resource, action_name)
    assert not is_nil(action), "Expected action #{inspect(action_name)} on #{inspect(resource)}"

    matching =
      Enum.filter(action.changes, fn
        %{change: ^expected_change_tuple} -> true
        _ -> false
      end)

    assert length(matching) == 1
    ctx
  end

  def assert_compile_error(ctx, result_key, expected_snippets) do
    assert {:error, %CompileError{description: desc}} = Map.fetch!(ctx.results, result_key)

    for snippet <- List.wrap(expected_snippets) do
      assert desc =~ snippet
    end

    ctx
  end

  defp resolve_path(cursor, []), do: cursor

  defp resolve_path(cursor, [key | rest]) do
    resolve_path(cursor[key], rest)
  end

  defp materialize_if_cursor(%Xitdb.Cursor{} = cur), do: Xitdb.materialize(cur)
  defp materialize_if_cursor({k, %Xitdb.Cursor{} = cur}), do: {k, Xitdb.materialize(cur)}
  defp materialize_if_cursor(other), do: other
end
