if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Store.LeaseQueueTest do
    use ExUnit.Case, async: true

    alias Xitdb.Ash.Store.LeaseQueue

    test "acquire grants immediately when idle and queues when active" do
      q = LeaseQueue.new()
      req1 = make_ref()
      tag1 = make_ref()
      from1 = {self(), tag1}

      assert {:granted, lease_ref, q} =
               LeaseQueue.acquire(q, :store, req1, from1, 5_000, 5_000, {:db, 0})

      assert q.active.ref == lease_ref
      assert q.active.req_ref == req1
      assert q.active.holder == self()
      assert :ok == LeaseQueue.verify_holder(q, lease_ref, self())
      assert {:error, :lease_expired} == LeaseQueue.verify_holder(q, make_ref(), self())

      # Queues second caller while active
      req2 = make_ref()
      tag2 = make_ref()

      assert {:queued, q} =
               LeaseQueue.acquire(q, :store, req2, {self(), tag2}, 5_000, 5_000, {:db, 0})

      assert :queue.len(q.waiters) == 1

      # Release grants next waiter and sends GenServer reply
      q = LeaseQueue.release_and_grant_next(q, :store, {:db, 1})
      assert_receive {^tag2, {:ok, lease_ref2, {:db, 1}}}, 500
      assert q.active.ref == lease_ref2

      _q = LeaseQueue.cancel_all(q, {:error, :done})
    end

    test "grant_next_waiter handles :infinity call_timeout, {:ok, snap}, and {:error, reason} cascading cancel_all" do
      q = LeaseQueue.new()

      {:granted, _ref1, q} =
        LeaseQueue.acquire(
          q,
          :store,
          make_ref(),
          {self(), make_ref()},
          :infinity,
          :infinity,
          {:db, 0}
        )

      # Waiter with :infinity call_timeout succeeds via {:ok, snap} snapshot function
      tag_inf = make_ref()

      {:queued, q} =
        LeaseQueue.acquire(
          q,
          :store,
          make_ref(),
          {self(), tag_inf},
          :infinity,
          :infinity,
          {:db, 0}
        )

      q = LeaseQueue.release_and_grant_next(q, :store, fn -> {:ok, {:db, 2}} end)
      assert_receive {^tag_inf, {:ok, _ref_inf, {:db, 2}}}, 500
      assert q.active != nil

      # Two waiters queued when snapshot_source returns {:error, :closed} -> both receive error
      tag_err1 = make_ref()
      tag_err2 = make_ref()

      {:queued, q} =
        LeaseQueue.acquire(q, :store, make_ref(), {self(), tag_err1}, 5_000, 5_000, {:db, 2})

      {:queued, q} =
        LeaseQueue.acquire(q, :store, make_ref(), {self(), tag_err2}, 5_000, 5_000, {:db, 2})

      q = LeaseQueue.release_and_grant_next(q, :store, fn -> {:error, :closed} end)
      assert_receive {^tag_err1, {:error, :closed}}, 500
      assert_receive {^tag_err2, {:error, :closed}}, 500
      assert q.active == nil
      assert :queue.is_empty(q.waiters)
    end

    test "grant_next_waiter skips dead waiters and expired waiters (exact boundary call_timeout == 0)" do
      q = LeaseQueue.new()

      {:granted, _ref1, q} =
        LeaseQueue.acquire(q, :store, make_ref(), {self(), make_ref()}, 5_000, 5_000, {:db, 0})

      # 1. Dead waiter with valid :infinity timeout (alive? == false, not_expired? == true)
      dead_pid = spawn(fn -> :ok end)
      mref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^mref, :process, ^dead_pid, :normal}, 500

      {:queued, q} =
        LeaseQueue.acquire(
          q,
          :store,
          make_ref(),
          {dead_pid, make_ref()},
          5_000,
          :infinity,
          {:db, 0}
        )

      # 2. Alive waiter with call_timeout: 0 (now_ms - enqueued_at_ms >= 0, so < 0 is false!)
      tag_zero = make_ref()

      {:queued, q} =
        LeaseQueue.acquire(q, :store, make_ref(), {self(), tag_zero}, 5_000, 0, {:db, 0})

      # 3. Alive waiter with call_timeout: 5ms after sleeping 10ms (expired via elapsed time)
      tag_expired = make_ref()

      {:queued, q} =
        LeaseQueue.acquire(q, :store, make_ref(), {self(), tag_expired}, 5_000, 5, {:db, 0})

      Process.sleep(10)

      # 4. Alive waiter with generous call_timeout: 5_000 (should be granted)
      tag_ok = make_ref()

      {:queued, q} =
        LeaseQueue.acquire(q, :store, make_ref(), {self(), tag_ok}, 5_000, 5_000, {:db, 0})

      q = LeaseQueue.release_and_grant_next(q, :store, {:db, 3})

      refute_received {^tag_zero, _}
      refute_received {^tag_expired, _}
      assert_receive {^tag_ok, {:ok, _ref_ok, {:db, 3}}}, 500
      assert q.active != nil

      _q = LeaseQueue.cancel_all(q)
    end

    test "build_active_lease accepts lease_timeout 0 and rejects negative or non-integer timeouts" do
      q = LeaseQueue.new()

      assert {:granted, lease_ref, q} =
               LeaseQueue.acquire(q, :store, make_ref(), {self(), make_ref()}, 0, 5_000, {:db, 0})

      assert_receive {:xitdb_lease_expired, :store, ^lease_ref}, 500
      assert {:matched, q} = LeaseQueue.handle_expired(q, lease_ref, :store, {:db, 0})
      assert :unmatched == LeaseQueue.handle_expired(q, make_ref(), :store, {:db, 0})
      assert :unmatched == LeaseQueue.handle_down(q, make_ref(), :store, {:db, 0})

      assert_raise CaseClauseError, fn ->
        LeaseQueue.acquire(q, :store, make_ref(), {self(), make_ref()}, -1, 5_000, {:db, 0})
      end

      assert_raise CaseClauseError, fn ->
        LeaseQueue.acquire(q, :store, make_ref(), {self(), make_ref()}, :invalid, 5_000, {:db, 0})
      end
    end

    test "cancel_waiter removes queued waiter without disturbing active lease, and releases active lease when matched" do
      q = LeaseQueue.new()
      req_active = make_ref()

      {:granted, _ref1, q} =
        LeaseQueue.acquire(q, :store, req_active, {self(), make_ref()}, 5_000, 5_000, {:db, 0})

      req_w1 = make_ref()
      req_w2 = make_ref()
      tag_w1 = make_ref()
      tag_w2 = make_ref()

      {:queued, q} =
        LeaseQueue.acquire(q, :store, req_w1, {self(), tag_w1}, 5_000, 5_000, {:db, 0})

      {:queued, q} =
        LeaseQueue.acquire(q, :store, req_w2, {self(), tag_w2}, 5_000, 5_000, {:db, 0})

      # Cancel queued waiter w1
      q = LeaseQueue.cancel_waiter(q, req_w1, :store, {:db, 0})
      assert :queue.len(q.waiters) == 1
      assert q.active.req_ref == req_active

      # Cancel active lease -> grants w2
      q = LeaseQueue.cancel_waiter(q, req_active, :store, {:db, 4})
      refute_received {^tag_w1, _}
      assert_receive {^tag_w2, {:ok, _ref2, {:db, 4}}}, 500

      _q = LeaseQueue.cancel_all(q)
    end
  end
end
