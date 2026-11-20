defmodule Xitdb.CacheOwner do
  @moduledoc false

  use GenServer

  @page_cache_table :xitdb_page_cache
  @dict_cache_table :xitdb_dict_cache

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_started() :: :ok
  def ensure_started do
    if Process.whereis(__MODULE__) != nil and
         :ets.whereis(@page_cache_table) != :undefined and
         :ets.whereis(@dict_cache_table) != :undefined do
      :ok
    else
      case GenServer.start(__MODULE__, [], name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> GenServer.call(__MODULE__, :ping)
      end
    end
  end

  @spec put_page(term(), term(), non_neg_integer(), pos_integer()) :: :ok
  def put_page(cache_key, page, raw_len, limit) do
    ensure_started()
    GenServer.call(__MODULE__, {:put_page, cache_key, page, raw_len, limit})
  end

  @spec put_dict(term(), term(), term(), pos_integer()) :: :ok
  def put_dict(key, cdict, ddict, limit) do
    ensure_started()
    GenServer.call(__MODULE__, {:put_dict, key, cdict, ddict, limit})
  end

  @impl GenServer
  def init(_opts) do
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

  defp ensure_tables do
    ensure_table(@page_cache_table)
    ensure_table(@dict_cache_table)
  end

  defp ensure_table(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
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
