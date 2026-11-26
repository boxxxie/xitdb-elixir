defmodule Xitdb.CacheHeir do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec claim([atom()]) :: :ok
  def claim(tables) when is_list(tables) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        if pid != self() do
          GenServer.call(pid, {:claim, tables, self()})
        else
          :ok
        end

      nil ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  @impl GenServer
  def init(_opts) do
    if pid = Process.whereis(Xitdb.CacheOwner) do
      send(pid, :reattach_heir)
    end

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:claim, tables, owner_pid}, _from, state) do
    Enum.each(tables, fn table ->
      try do
        if :ets.whereis(table) != :undefined and :ets.info(table, :owner) == self() do
          :ets.give_away(table, owner_pid, :xitdb_cache)
        end
      rescue
        ArgumentError -> :ok
      end
    end)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}
end
