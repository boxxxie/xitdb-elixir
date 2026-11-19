defmodule Xitdb.TestDSL.ClientDSL do
  @moduledoc """
  Layer 2 Domain-Specific Language for Xitdb Client ATDD Specifications.
  Bridges declarative `@given`, `@upon`, and `@then` steps in Layer 1 to
  `Xitdb.TestDrivers.ClientDriver` in Layer 3.
  """

  alias Xitdb.TestDrivers.ClientDriver

  @spec new_world(map()) :: map()
  def new_world(_ex_unit_ctx \\ %{}) do
    ClientDriver.new_context()
  end

  # ============================================================================
  # @given steps
  # ============================================================================

  def memory_database(ctx, opts \\ []) do
    ClientDriver.open_database(ctx, Keyword.put(opts, :backend, :memory))
  end

  def file_database(ctx, label, opts \\ []) do
    ClientDriver.open_file_database(ctx, label, opts)
  end

  def committed_moment(ctx, data, opts \\ []) do
    ClientDriver.commit_moment(ctx, data, opts)
  end

  def secondary_index_rule(ctx, source_map, field_key, index_map) do
    ClientDriver.add_index_rule(ctx, source_map, field_key, index_map)
  end

  def pinned_snapshot(ctx, snapshot_name, moment_index \\ -1) do
    ClientDriver.pin_snapshot(ctx, snapshot_name, moment_index)
  end

  # ============================================================================
  # @upon steps
  # ============================================================================

  def navigating_access_path(ctx, result_key, path_keys) when is_list(path_keys) do
    ClientDriver.navigate_access(ctx, result_key, path_keys)
  end

  def navigating_get_in(ctx, result_key, access_path) when is_list(access_path) do
    ClientDriver.navigate_get_in(ctx, result_key, access_path)
  end

  def reading_cursor_across_tasks(ctx, result_key, cursor_path, sub_keys) do
    ClientDriver.read_cursor_in_tasks(ctx, result_key, cursor_path, sub_keys)
  end

  def transacting_with_cursor(ctx, fun) when is_function(fun, 1) do
    ClientDriver.transact_cursor(ctx, fun)
  end

  def transacting_operations(ctx, ops, opts \\ []) when is_list(ops) do
    ClientDriver.transact_ops(ctx, ops, opts)
  end

  def attempting_failing_transaction(ctx, fun) when is_function(fun, 1) do
    ClientDriver.attempt_failing_transact(ctx, fun)
  end

  def attempting_failing_moment(ctx, map, opts \\ []) when is_map(map) do
    ClientDriver.attempt_failing_transact(ctx, map, opts)
  end

  def executing_dsl_transaction(ctx, fun) when is_function(fun, 1) do
    ClientDriver.execute_dsl_tx(ctx, fun)
  end

  def attempting_failing_dsl_transaction(ctx, fun) when is_function(fun, 1) do
    ClientDriver.attempt_failing_dsl_tx(ctx, fun)
  end

  def selecting_path(ctx, result_key, selector) do
    ClientDriver.select_path(ctx, result_key, selector)
  end

  def seeking_sorted_map_range(ctx, result_key, path_keys, opts \\ []) do
    ClientDriver.seek_sorted_map_range(ctx, result_key, path_keys, opts)
  end

  def pulling_projection(ctx, result_key, selector_or_path, pattern) do
    ClientDriver.pull_projection(ctx, result_key, selector_or_path, pattern)
  end

  def diffing_moments(ctx, result_key, moment_a, moment_b) do
    ClientDriver.diff_moments(ctx, result_key, moment_a, moment_b)
  end

  def inspecting_history_of(ctx, result_key, selector) do
    ClientDriver.history_of(ctx, result_key, selector)
  end

  def querying_datalog(ctx, result_key, query_str, opts \\ []) do
    ClientDriver.query_datalog(ctx, result_key, query_str, opts)
  end

  def compacting_database(ctx, target_label) do
    ClientDriver.compact_database(ctx, target_label)
  end

  def reopening_file_database(ctx, label) do
    ClientDriver.reopen_file_database(ctx, label)
  end

  def evaluating_quoted_ast(ctx, result_key, quoted_ast) do
    ClientDriver.evaluate_quoted_ast(ctx, result_key, quoted_ast)
  end

  # ============================================================================
  # @then steps (macros preserve caller line numbers on failure)
  # ============================================================================

  defmacro resolved_value_is(ctx_ast, result_key, expected_value) do
    quote line: __CALLER__.line do
      ClientDriver.assert_resolved_value(
        unquote(ctx_ast),
        unquote(result_key),
        unquote(expected_value)
      )
    end
  end

  defmacro resolved_node_is_lazy_cursor(ctx_ast, result_key, expected_opts) do
    quote line: __CALLER__.line do
      ClientDriver.assert_lazy_cursor(
        unquote(ctx_ast),
        unquote(result_key),
        unquote(expected_opts)
      )
    end
  end

  defmacro access_path_equals(ctx_ast, path_keys, expected_value) do
    quote line: __CALLER__.line do
      ClientDriver.assert_access_path_equals(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(expected_value)
      )
    end
  end

  defmacro snapshot_access_path_equals(ctx_ast, snapshot_name, path_keys, expected_value) do
    quote line: __CALLER__.line do
      ClientDriver.assert_snapshot_access_path_equals(
        unquote(ctx_ast),
        unquote(snapshot_name),
        unquote(path_keys),
        unquote(expected_value)
      )
    end
  end

  defmacro enumerable_count_is(ctx_ast, path_keys, expected_count) do
    quote line: __CALLER__.line do
      ClientDriver.assert_enumerable_count(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(expected_count)
      )
    end
  end

  defmacro enumerable_membership_is(ctx_ast, path_keys, candidate, expected_bool) do
    quote line: __CALLER__.line do
      ClientDriver.assert_enumerable_member(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(candidate),
        unquote(expected_bool)
      )
    end
  end

  defmacro enumerable_slice_is(ctx_ast, path_keys, range, expected_list) do
    quote line: __CALLER__.line do
      ClientDriver.assert_enumerable_slice(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(range),
        unquote(expected_list)
      )
    end
  end

  defmacro enumerable_entries_are(ctx_ast, path_keys, expected_entries, opts \\ []) do
    quote line: __CALLER__.line do
      ClientDriver.assert_enumerable_entries(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(expected_entries),
        unquote(opts)
      )
    end
  end

  defmacro stream_take_is(ctx_ast, path_keys, count, expected_items) do
    quote line: __CALLER__.line do
      ClientDriver.assert_stream_take(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(count),
        unquote(expected_items)
      )
    end
  end

  defmacro materialized_subtree_is(ctx_ast, path_keys, expected_term) do
    quote line: __CALLER__.line do
      ClientDriver.assert_materialized_subtree(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(expected_term)
      )
    end
  end

  defmacro cursor_inspect_includes(ctx_ast, path_keys, expected_substrings) do
    quote line: __CALLER__.line do
      ClientDriver.assert_cursor_inspect(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(expected_substrings)
      )
    end
  end

  defmacro database_moment_count_is(ctx_ast, expected_count) do
    quote line: __CALLER__.line do
      ClientDriver.assert_moment_count(unquote(ctx_ast), unquote(expected_count))
    end
  end

  defmacro last_transaction_failed_with(ctx_ast, expected_reason) do
    quote line: __CALLER__.line do
      ClientDriver.assert_last_tx_error(unquote(ctx_ast), unquote(expected_reason))
    end
  end

  defmacro diff_changes_are(ctx_ast, result_key, expected_changes) do
    quote line: __CALLER__.line do
      ClientDriver.assert_diff_changes(
        unquote(ctx_ast),
        unquote(result_key),
        unquote(expected_changes)
      )
    end
  end

  defmacro history_lineage_is(ctx_ast, result_key, expected_entries) do
    quote line: __CALLER__.line do
      ClientDriver.assert_history_lineage(
        unquote(ctx_ast),
        unquote(result_key),
        unquote(expected_entries)
      )
    end
  end

  defmacro datalog_rows_are(ctx_ast, result_key, expected_rows, opts \\ []) do
    quote line: __CALLER__.line do
      ClientDriver.assert_datalog_rows(
        unquote(ctx_ast),
        unquote(result_key),
        unquote(expected_rows),
        unquote(opts)
      )
    end
  end

  defmacro compacted_database_shrinks_and_preserves(ctx_ast, path_keys, expected_value) do
    quote line: __CALLER__.line do
      ClientDriver.assert_compacted_valid(
        unquote(ctx_ast),
        unquote(path_keys),
        unquote(expected_value)
      )
    end
  end

  defmacro ash_action_includes_change(ctx_ast, resource, action_name, expected_change_tuple) do
    quote line: __CALLER__.line do
      ClientDriver.assert_ash_action_has_change(
        unquote(ctx_ast),
        unquote(resource),
        unquote(action_name),
        unquote(expected_change_tuple)
      )
    end
  end

  defmacro compile_error_raised_with(ctx_ast, result_key, expected_snippets) do
    quote line: __CALLER__.line do
      ClientDriver.assert_compile_error(
        unquote(ctx_ast),
        unquote(result_key),
        unquote(expected_snippets)
      )
    end
  end
end
