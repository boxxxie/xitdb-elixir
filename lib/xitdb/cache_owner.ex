defmodule Xitdb.CacheOwner do
  @moduledoc false

  use GenServer

  @page_cache_table :xitdb_page_cache
  @dict_cache_table :xitdb_dict_cache

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_tables_ready() :: :ok
  def ensure_tables_ready do
    if :ets.whereis(@page_cache_table) != :undefined and
         :ets.whereis(@dict_cache_table) != :undefined do
      :ok
    else
      ensure_started()
    end
  end

  @spec ensure_started() :: :ok
  def ensure_started do
    if Process.whereis(__MODULE__) != nil and
         :ets.whereis(@page_cache_table) != :undefined and
         :ets.whereis(@dict_cache_table) != :undefined do
      :ok
    else
      do_ensure_started(25)
    end
  end

  defp do_ensure_started(attempts) when attempts > 0 do
    if Process.whereis(Xitdb.Supervisor) != nil do
      ping_with_retry(attempts)
    else
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> ping_with_retry(attempts)
      end
    end
  end

  defp ping_with_retry(attempts) do
    Xitdb.Fallback.try_exit(
      :cache_owner_ping_exit,
      %{attempts: attempts},
      fn -> GenServer.call(__MODULE__, :ping, 500) end,
      fn
        {reason, _} when reason != :timeout and attempts > 1 ->
          Process.sleep(10)
          do_ensure_started(attempts - 1)

        reason ->
          if :ets.whereis(@page_cache_table) != :undefined and
               :ets.whereis(@dict_cache_table) != :undefined do
            :ok
          else
            exit(reason)
          end
      end
    )
  end

  @spec put_page(term(), term(), non_neg_integer(), pos_integer()) :: :ok
  def put_page(cache_key, page, raw_len, limit) do
    call_best_effort({:put_page, cache_key, page, raw_len, limit}, 2)
  end

  @spec put_dict(term(), term(), term(), pos_integer()) :: :ok
  def put_dict(key, cdict, ddict, limit) do
    call_best_effort({:put_dict, key, cdict, ddict, limit}, 2)
  end

  defp call_best_effort(msg, attempts) when attempts > 0 do
    if Process.whereis(__MODULE__) == nil and Process.whereis(Xitdb.Supervisor) == nil do
      _ = GenServer.start(__MODULE__, [], name: __MODULE__)
    end

    Xitdb.Fallback.try_exit(
      :cache_owner_best_effort_exit,
      %{attempts: attempts},
      fn -> GenServer.call(__MODULE__, msg, 100) end,
      fn
        {reason, _} when reason != :timeout and attempts > 1 ->
          Process.sleep(10)
          call_best_effort(msg, attempts - 1)

        _reason ->
          :ok
      end
    )
  end

  @impl GenServer
  def init(_opts) do
    Xitdb.CacheHeir.claim([@page_cache_table, @dict_cache_table])
    ensure_tables()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:ping, _from, state) do
    ensure_tables()
    {:reply, :ok, state}
  end

  def handle_call({:put_page, cache_key, page, raw_len, limit}, _from, state) do
    ensure_tables()

    if not :ets.member(@page_cache_table, cache_key) do
      size = :ets.info(@page_cache_table, :size)

      if is_integer(size) and size >= limit do
        to_evict = size - limit + 1

        @page_cache_table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_k, _p, _len, ts} -> ts end)
        |> Enum.take(to_evict)
        |> Enum.each(fn {k, _p, _len, _ts} -> :ets.delete(@page_cache_table, k) end)
      end
    end

    :ets.insert(@page_cache_table, {cache_key, page, raw_len, System.monotonic_time(:nanosecond)})
    {:reply, :ok, state}
  end

  def handle_call({:put_dict, key, cdict, ddict, limit}, _from, state) do
    ensure_tables()

    if not :ets.member(@dict_cache_table, key) do
      evict_dict_excess(limit)
    end

    :ets.insert(@dict_cache_table, {key, cdict, ddict})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:"ETS-TRANSFER", table, _from, _data}, state) do
    attach_heir(table)
    {:noreply, state}
  end

  def handle_info(:reattach_heir, state) do
    Xitdb.CacheHeir.claim([@page_cache_table, @dict_cache_table])
    ensure_tables()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_tables do
    ensure_table(@page_cache_table)
    ensure_table(@dict_cache_table)
  end

  defp ensure_table(name) do
    if :ets.whereis(name) == :undefined do
      base_opts = [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: :auto
      ]

      table_opts =
        case Process.whereis(Xitdb.CacheHeir) do
          pid when is_pid(pid) -> [{:heir, pid, :xitdb_cache} | base_opts]
          nil -> base_opts
        end

      Xitdb.Fallback.try_run(
        :cache_owner_table_race,
        %{table: name},
        fn ->
          _ = :ets.new(name, table_opts)
          :ok
        end,
        fn
          %ArgumentError{} -> :ok
          e -> raise e
        end
      )
    else
      attach_heir(name)
    end
  end

  defp attach_heir(table) do
    case Process.whereis(Xitdb.CacheHeir) do
      pid when is_pid(pid) ->
        Xitdb.Fallback.try_run(
          :cache_owner_heir_race,
          %{table: table},
          fn ->
            if :ets.info(table, :owner) == self() do
              :ets.setopts(table, {:heir, pid, :xitdb_cache})
            end
          end,
          fn
            %ArgumentError{} -> :ok
            e -> raise e
          end
        )

      nil ->
        :ok
    end

    :ok
  end

  defp evict_dict_excess(limit) do
    size = :ets.info(@dict_cache_table, :size)

    if is_integer(size) and size >= limit do
      case :ets.first(@dict_cache_table) do
        :"$end_of_table" ->
          :ok

        evict_key ->
          :ets.delete(@dict_cache_table, evict_key)
          evict_dict_excess(limit)
      end
    else
      :ok
    end
  end
end
