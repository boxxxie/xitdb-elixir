defmodule Xitdb.Fallback do
  @moduledoc """
  Standardized observable helper for legitimate read-only, query-planner, cache-miss,
  or display-only fallbacks.

  Every fallback routed through `Xitdb.Fallback` must pass the **3-question fallback gate**:

  1. Is it strictly read-only, query-planner, cache-miss, or display-only without mutating
     database state, transactions, or persistence?
  2. Does it emit a `:telemetry` event (`[:xitdb, :fallback, :used]`) rather than only a log line?
  3. Is it exercised regularly or covered by an ExUnit test?

  `Xitdb.Fallback` is **strictly forbidden** on write, transaction (`Xitdb.transact/3`,
  `Xitdb.TxCompiler`, `Xitdb.DSL.tx`), NIF boundary, lock/lease-fencing, compaction,
  and `Xitdb.Ash.Mutator` paths — those must fail fast and return `{:error, ...}` or raise.
  """

  require Logger

  @type reason :: atom() | String.t()

  @doc """
  Emits `[:xitdb, :fallback, :used]` telemetry, logs a structured warning, and invokes `fun`.
  """
  @spec run(reason(), map(), (-> result)) :: result when result: var
  def run(reason, metadata \\ %{}, fun)
      when (is_atom(reason) or is_binary(reason)) and is_map(metadata) and is_function(fun, 0) do
    meta = Map.put(metadata, :reason, reason)

    :telemetry.execute([:xitdb, :fallback, :used], %{count: 1}, meta)

    Logger.warning(
      "Xitdb fallback used: reason=#{inspect(reason)} metadata=#{inspect(Map.delete(meta, :reason))}"
    )

    fun.()
  end

  @doc """
  Executes `try_fun.()` and, if an exception is raised, records exception metadata and
  delegates to `run/3` with `fallback_fun` (0-arity or 1-arity receiving the exception).
  """
  @spec try_run(reason(), (-> result), (-> result) | (Exception.t() -> result)) :: result
        when result: var
  def try_run(reason, try_fun, fallback_fun)
      when is_function(try_fun, 0) and
             (is_function(fallback_fun, 0) or is_function(fallback_fun, 1)) do
    try_run(reason, %{}, try_fun, fallback_fun)
  end

  @spec try_run(reason(), map(), (-> result), (-> result) | (Exception.t() -> result)) :: result
        when result: var
  def try_run(reason, metadata, try_fun, fallback_fun)
      when (is_atom(reason) or is_binary(reason)) and is_map(metadata) and
             is_function(try_fun, 0) and
             (is_function(fallback_fun, 0) or is_function(fallback_fun, 1)) do
    try_fun.()
  rescue
    e ->
      enriched_meta =
        metadata
        |> Map.put(:exception, Exception.message(e))
        |> Map.put(:exception_module, e.__struct__)

      run(reason, enriched_meta, fn ->
        if is_function(fallback_fun, 1) do
          fallback_fun.(e)
        else
          fallback_fun.()
        end
      end)
  end
end
