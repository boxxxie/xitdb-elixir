defmodule Xitdb.TestDSL.ClientDSL do
  @moduledoc """
  Layer 2 Domain-Specific Language for Xitdb Client ATDD Specifications.
  Bridges declarative `@given`, `@upon`, and `@then` steps in Layer 1 to
  `Xitdb.TestDrivers.ClientDriver` in Layer 3.
  """

  alias Xitdb.TestDrivers.ClientDriver

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

  def executing_dsl_transaction(ctx, fun) when is_function(fun, 1) do
    ClientDriver.execute_dsl_tx(ctx, fun)
  end

  def attempting_failing_dsl_transaction(ctx, fun) when is_function(fun, 1) do
    ClientDriver.attempt_failing_dsl_tx(ctx, fun)
  end

  def selecting_path(ctx, result_key, selector) do
    ClientDriver.select_path(ctx, result_key, selector)
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

  def inspecting_ash_resource_info(ctx, result_key, resource_or_resources, opts \\ []) do
    ClientDriver.inspect_ash_resource_info(ctx, result_key, resource_or_resources, opts)
  end

  def creating_ash_record(ctx, record_key, resource, action, params) do
    ClientDriver.create_ash_record(ctx, record_key, resource, action, params)
  end

  def updating_ash_record(ctx, record_key, action, params) do
    ClientDriver.update_ash_record(ctx, record_key, action, params)
  end

  def verifying_ash_sync_projection(ctx, result_key, resource, option_overrides \\ []) do
    ClientDriver.verify_ash_sync_projection(ctx, result_key, resource, option_overrides)
  end

  def evaluating_quoted_ast(ctx, result_key, quoted_ast) do
    ClientDriver.evaluate_quoted_ast(ctx, result_key, quoted_ast)
  end

  # ============================================================================
  # @then steps
  # ============================================================================

  def resolved_value_is(ctx, result_key, expected_value) do
    ClientDriver.assert_resolved_value(ctx, result_key, expected_value)
  end

  def resolved_node_is_lazy_cursor(ctx, result_key, expected_opts) do
    ClientDriver.assert_lazy_cursor(ctx, result_key, expected_opts)
  end

  def access_path_equals(ctx, path_keys, expected_value) do
    ClientDriver.assert_access_path_equals(ctx, path_keys, expected_value)
  end

  def snapshot_access_path_equals(ctx, snapshot_name, path_keys, expected_value) do
    ClientDriver.assert_snapshot_access_path_equals(ctx, snapshot_name, path_keys, expected_value)
  end

  def enumerable_count_is(ctx, path_keys, expected_count) do
    ClientDriver.assert_enumerable_count(ctx, path_keys, expected_count)
  end

  def enumerable_membership_is(ctx, path_keys, candidate, expected_bool) do
    ClientDriver.assert_enumerable_member(ctx, path_keys, candidate, expected_bool)
  end

  def enumerable_slice_is(ctx, path_keys, range, expected_list) do
    ClientDriver.assert_enumerable_slice(ctx, path_keys, range, expected_list)
  end

  def enumerable_entries_are(ctx, path_keys, expected_entries, opts \\ []) do
    ClientDriver.assert_enumerable_entries(ctx, path_keys, expected_entries, opts)
  end

  def stream_take_is(ctx, path_keys, count, expected_items) do
    ClientDriver.assert_stream_take(ctx, path_keys, count, expected_items)
  end

  def materialized_subtree_is(ctx, path_keys, expected_term) do
    ClientDriver.assert_materialized_subtree(ctx, path_keys, expected_term)
  end

  def cursor_inspect_includes(ctx, path_keys, expected_substrings) do
    ClientDriver.assert_cursor_inspect(ctx, path_keys, expected_substrings)
  end

  def database_moment_count_is(ctx, expected_count) do
    ClientDriver.assert_moment_count(ctx, expected_count)
  end

  def last_transaction_failed_with(ctx, expected_reason) do
    ClientDriver.assert_last_tx_error(ctx, expected_reason)
  end

  def diff_changes_are(ctx, result_key, expected_changes) do
    ClientDriver.assert_diff_changes(ctx, result_key, expected_changes)
  end

  def history_lineage_is(ctx, result_key, expected_entries) do
    ClientDriver.assert_history_lineage(ctx, result_key, expected_entries)
  end

  def datalog_rows_are(ctx, result_key, expected_rows, opts \\ []) do
    ClientDriver.assert_datalog_rows(ctx, result_key, expected_rows, opts)
  end

  def compacted_database_Shrinks_and_preserves(ctx, path_keys, expected_value) do
    ClientDriver.assert_compacted_valid(ctx, path_keys, expected_value)
  end

  def ash_action_includes_change(ctx, resource, action_name, expected_change_tuple) do
    ClientDriver.assert_ash_action_has_change(ctx, resource, action_name, expected_change_tuple)
  end

  def ash_record_attribute_equals(ctx, record_key, attribute, expected_value) do
    ClientDriver.assert_ash_record_attribute(ctx, record_key, attribute, expected_value)
  end

  def ash_verifier_succeeded(ctx, result_key) do
    ClientDriver.assert_ash_verifier_ok(ctx, result_key)
  end

  def ash_verifier_failed_with(ctx, result_key, expected_opts) do
    ClientDriver.assert_ash_verifier_error(ctx, result_key, expected_opts)
  end

  def compile_error_raised_with(ctx, result_key, expected_snippets) do
    ClientDriver.assert_compile_error(ctx, result_key, expected_snippets)
  end
end
