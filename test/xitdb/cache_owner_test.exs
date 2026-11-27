defmodule Xitdb.CacheOwnerTest do
  use ExUnit.Case, async: false

  alias Xitdb.CacheOwner

  @page_cache_table :xitdb_page_cache
  @dict_cache_table :xitdb_dict_cache

  setup do
    CacheOwner.ensure_started()
    :ets.delete_all_objects(@page_cache_table)
    :ets.delete_all_objects(@dict_cache_table)

    on_exit(fn ->
      CacheOwner.ensure_started()
      :ets.delete_all_objects(@page_cache_table)
      :ets.delete_all_objects(@dict_cache_table)
    end)

    :ok
  end

  test "ensure_tables_ready/0 and ensure_started/0 return :ok when running and recreate tables with read_concurrency: true if deleted" do
    assert :ok == CacheOwner.ensure_tables_ready()
    assert :ok == CacheOwner.ensure_started()

    # Deleting one table forces ensure_tables_ready/0 and ensure_started/0 to recreate it
    :ets.delete(@dict_cache_table)
    assert :ets.whereis(@dict_cache_table) == :undefined
    assert :ok == CacheOwner.ensure_tables_ready()
    assert :ets.whereis(@dict_cache_table) != :undefined
    assert :ets.info(@dict_cache_table, :read_concurrency) == true

    :ets.delete(@page_cache_table)
    assert :ets.whereis(@page_cache_table) == :undefined
    assert :ok == CacheOwner.ensure_started()
    assert :ets.whereis(@page_cache_table) != :undefined
    assert :ets.info(@page_cache_table, :read_concurrency) == true
  end

  test "put_page/4 enforces exact limit boundary, evicts oldest timestamp, and updates existing keys without eviction" do
    assert :ok == CacheOwner.put_page(:k1, :p1, 10, 2)
    assert :ets.info(@page_cache_table, :size) == 1

    assert :ok == CacheOwner.put_page(:k2, :p2, 20, 2)
    assert :ets.info(@page_cache_table, :size) == 2

    # Updating an existing key at capacity (size == limit) must NOT evict the other key
    assert :ok == CacheOwner.put_page(:k1, :p1_updated, 15, 2)
    assert :ets.info(@page_cache_table, :size) == 2
    assert [{:k1, :p1_updated, 15, _}] = :ets.lookup(@page_cache_table, :k1)
    assert [{:k2, :p2, 20, _}] = :ets.lookup(@page_cache_table, :k2)

    # Inserting a new key at size == limit evicts the oldest entry (:k2, since :k1 was just updated)
    assert :ok == CacheOwner.put_page(:k3, :p3, 30, 2)
    assert :ets.info(@page_cache_table, :size) == 2
    assert :ets.lookup(@page_cache_table, :k2) == []
    assert [{:k1, :p1_updated, 15, _}] = :ets.lookup(@page_cache_table, :k1)
    assert [{:k3, :p3, 30, _}] = :ets.lookup(@page_cache_table, :k3)

    # Lowering limit below current size evicts (size - limit + 1) entries so resulting size == limit
    assert :ok == CacheOwner.put_page(:k4, :p4, 40, 1)
    assert :ets.info(@page_cache_table, :size) == 1
    assert [{:k4, :p4, 40, _}] = :ets.lookup(@page_cache_table, :k4)
  end

  test "put_dict/4 enforces exact limit boundary and updates existing keys without eviction" do
    assert :ok == CacheOwner.put_dict(:d1, :c1, :dd1, 2)
    assert :ets.info(@dict_cache_table, :size) == 1

    assert :ok == CacheOwner.put_dict(:d2, :c2, :dd2, 2)
    assert :ets.info(@dict_cache_table, :size) == 2

    # Updating existing key at capacity must NOT evict
    assert :ok == CacheOwner.put_dict(:d1, :c1_new, :dd1_new, 2)
    assert :ets.info(@dict_cache_table, :size) == 2
    assert [{:d1, :c1_new, :dd1_new}] = :ets.lookup(@dict_cache_table, :d1)
    assert [{:d2, :c2, :dd2}] = :ets.lookup(@dict_cache_table, :d2)

    # Inserting new key at capacity evicts down to limit - 1, then inserts -> final size == 2
    assert :ok == CacheOwner.put_dict(:d3, :c3, :dd3, 2)
    assert :ets.info(@dict_cache_table, :size) == 2
    assert [{:d3, :c3, :dd3}] = :ets.lookup(@dict_cache_table, :d3)

    # Lowering limit below current size evicts recursively down to limit == 1
    assert :ok == CacheOwner.put_dict(:d4, :c4, :dd4, 1)
    assert :ets.info(@dict_cache_table, :size) == 1
    assert [{:d4, :c4, :dd4}] = :ets.lookup(@dict_cache_table, :d4)
  end

  test "handles :reattach_heir, ETS-TRANSFER, and unknown info messages while keeping CacheHeir attached" do
    pid = Process.whereis(CacheOwner)
    assert is_pid(pid)

    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:xitdb, :fallback, :used],
      fn _ev, _meas, meta, _ -> send(parent, {:fallback_used, meta.reason}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok == CacheOwner.put_page(:survives_messages, :val, 5, 10)

    # :ping when tables already exist must not trigger :cache_owner_table_race
    assert :ok == GenServer.call(pid, :ping)
    refute_received {:fallback_used, :cache_owner_table_race}

    # ETS-TRANSFER for a table NOT owned by CacheOwner must not trigger :cache_owner_heir_race
    other_tbl = :ets.new(:xitdb_test_other_tbl, [:set, :public])
    on_exit(fn -> if :ets.info(other_tbl) != :undefined, do: :ets.delete(other_tbl) end)
    send(pid, {:"ETS-TRANSFER", other_tbl, self(), :xitdb_cache})
    assert :ok == GenServer.call(pid, :ping)
    refute_received {:fallback_used, :cache_owner_heir_race}

    # ETS-TRANSFER for a table actually given away to CacheOwner attaches CacheHeir
    xfer_tbl = :ets.new(:xitdb_test_xfer_tbl, [:set, :public])
    on_exit(fn -> if :ets.info(xfer_tbl) != :undefined, do: :ets.delete(xfer_tbl) end)
    :ets.give_away(xfer_tbl, pid, :xitdb_cache)
    assert :ok == GenServer.call(pid, :ping)
    heir_pid = Process.whereis(Xitdb.CacheHeir)
    assert is_pid(heir_pid)
    assert :ets.info(xfer_tbl, :heir) == heir_pid

    send(pid, :reattach_heir)
    send(pid, :unknown_message)
    assert :ok == GenServer.call(pid, :ping)

    assert [{:survives_messages, :val, 5, _}] = :ets.lookup(@page_cache_table, :survives_messages)
    assert :ets.info(@page_cache_table, :heir) == heir_pid
    assert :ets.info(@dict_cache_table, :heir) == heir_pid
  end

  test "ensure_tables_ready/0 fast-paths when CacheOwner is stopped, and ensure_started/0 handles retry fallback cleanly" do
    :ok = Supervisor.terminate_child(Xitdb.Supervisor, Xitdb.CacheOwner)

    on_exit(fn ->
      _ = Supervisor.restart_child(Xitdb.Supervisor, Xitdb.CacheOwner)
      CacheOwner.ensure_started()
    end)

    assert Process.whereis(CacheOwner) == nil

    # Tables survived via CacheHeir -> ensure_tables_ready returns :ok immediately without waking CacheOwner
    assert :ok == CacheOwner.ensure_tables_ready()
    assert Process.whereis(CacheOwner) == nil

    # ensure_started retries ping while CacheOwner is stopped, then falls back to :ok since both tables exist
    ExUnit.CaptureLog.capture_log(fn ->
      assert :ok == CacheOwner.ensure_started()

      # Best-effort put_page when CacheOwner is stopped returns :ok after retry without crashing
      assert :ok == CacheOwner.put_page(:dropped_while_stopped, :v, 1, 10)

      # Deleting a table while CacheOwner is stopped makes ensure_started exit with :noproc
      :ets.delete(@page_cache_table)

      assert {:noproc, _} = catch_exit(CacheOwner.ensure_started())
    end)

    # Restarting CacheOwner cleanly recreates the table
    assert {:ok, _pid} = Supervisor.restart_child(Xitdb.Supervisor, Xitdb.CacheOwner)
    assert :ok == CacheOwner.ensure_started()
    assert :ets.whereis(@page_cache_table) != :undefined
  end
end
