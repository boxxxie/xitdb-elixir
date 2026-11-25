if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.TestSandboxTest do
    use ExUnit.Case, async: true

    alias Xitdb.Ash.{LeaseError, Store, TestSandbox}

    setup_all do
      TestSandbox.init()
      :ok
    end

    defp start_sandboxed_store do
      uid = System.unique_integer([:positive])
      store = :"XitdbSandboxTest_#{uid}"
      {:ok, pid} = Store.start_link(name: store, path: :memory)

      {:ok, :seeded} =
        Store.mutate(store, fn {db, moment} ->
          {:ok, db2} =
            Xitdb.transact_ops(
              db,
              [
                {:init_col, "entries", "hash_map"},
                {:put, "entries[\"seed\"]", "from_template"}
              ],
              base_moment: moment
            )

          {:ok, {db2, Xitdb.moment_count(db2) - 1}, :seeded}
        end)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      store
    end

    test "ETS sandbox registries have :kernel_sup as :heir so tables outlive dynamic callers" do
      assert :ok = TestSandbox.init()
      kernel_sup = Process.whereis(:kernel_sup)
      assert is_pid(kernel_sup)

      assert :ets.info(:xitdb_ash_sandbox_templates, :heir) == kernel_sup
      assert :ets.info(:xitdb_ash_sandbox_checkouts, :heir) == kernel_sup
    end

    test "isolates concurrent async processes with independent :memory CoW handles" do
      store = start_sandboxed_store()
      parent = self()

      worker_a =
        Task.async(fn ->
          :ok = TestSandbox.checkout([store])

          {:ok, :ok} =
            Store.transact(store, fn ->
              {:ok, :ok} =
                Store.mutate(store, fn {db, moment} ->
                  {:ok, db2} =
                    Xitdb.transact_ops(
                      db,
                      [{:put, "entries[\"only_a\"]", "alpha"}],
                      base_moment: moment
                    )

                  {:ok, {db2, Xitdb.moment_count(db2) - 1}, :ok}
                end)

              :ok
            end)

          send(parent, {:a_wrote, Store.root(store)["entries"]["only_a"]})
          receive do: (:finish_a -> Store.root(store)["entries"]["only_b"])
        end)

      worker_b =
        Task.async(fn ->
          :ok = TestSandbox.checkout([store])

          {:ok, :ok} =
            Store.transact(store, fn ->
              {:ok, :ok} =
                Store.mutate(store, fn {db, moment} ->
                  {:ok, db2} =
                    Xitdb.transact_ops(
                      db,
                      [{:put, "entries[\"only_b\"]", "beta"}],
                      base_moment: moment
                    )

                  {:ok, {db2, Xitdb.moment_count(db2) - 1}, :ok}
                end)

              :ok
            end)

          send(parent, {:b_wrote, Store.root(store)["entries"]["only_b"]})
          receive do: (:finish_b -> Store.root(store)["entries"]["only_a"])
        end)

      assert_receive {:a_wrote, "alpha"}, 1_000
      assert_receive {:b_wrote, "beta"}, 1_000

      send(worker_a.pid, :finish_a)
      send(worker_b.pid, :finish_b)

      assert Task.await(worker_a) == nil
      assert Task.await(worker_b) == nil

      # Unchecked-out parent process still sees untouched template state
      assert Store.root(store)["entries"]["seed"] == "from_template"
      assert Store.root(store)["entries"]["only_a"] == nil
      assert Store.root(store)["entries"]["only_b"] == nil
    end

    test "propagates sandbox access via $callers and explicit allow/3" do
      store = start_sandboxed_store()
      :ok = TestSandbox.checkout([store])

      # $callers propagation through Task.async
      {:ok, :written} =
        Task.async(fn ->
          Store.transact(store, fn ->
            {:ok, :written} =
              Store.mutate(store, fn {db, moment} ->
                {:ok, db2} =
                  Xitdb.transact_ops(
                    db,
                    [{:put, "entries[\"child\"]", "via_callers"}],
                    base_moment: moment
                  )

                {:ok, {db2, Xitdb.moment_count(db2) - 1}, :written}
              end)

            :written
          end)
        end)
        |> Task.await()

      assert Store.root(store)["entries"]["child"] == "via_callers"

      # Unlinked spawned process without $callers requires explicit allow/3
      owner = self()

      unlinked =
        spawn(fn ->
          assert TestSandbox.checked_out?(store) == false
          send(owner, :ready_for_allow)
          receive do: (:go -> :ok)
          assert TestSandbox.checked_out?(store) == true
          send(owner, {:saw_child, Store.root(store)["entries"]["child"]})
        end)

      assert_receive :ready_for_allow, 1_000
      :ok = TestSandbox.allow([store], owner, unlinked)
      send(unlinked, :go)
      assert_receive {:saw_child, "via_callers"}, 1_000
    end

    test "prevents zombie commits when a sandboxed writer exceeds lease_timeout" do
      store = start_sandboxed_store()
      :ok = TestSandbox.checkout([store], lease_timeout: 40)

      assert {:error, %LeaseError{store: ^store, reason: :lease_expired}} =
               Store.transact(store, fn ->
                 {:ok, _} =
                   Store.mutate(store, fn {db, moment} ->
                     {:ok, db2} =
                       Xitdb.transact_ops(
                         db,
                         [{:put, "entries[\"zombie\"]", "stale"}],
                         base_moment: moment
                       )

                     {:ok, {db2, Xitdb.moment_count(db2) - 1}, :mutated}
                   end)

                 Process.sleep(80)
                 :stale_commit
               end)

      # Stale commit was not published to ETS checkout snapshot
      assert Store.root(store)["entries"]["zombie"] == nil
    end

    test "partial checkin checks in only the targeted store while keeping other checkouts isolated" do
      store_a = start_sandboxed_store()
      store_b = start_sandboxed_store()
      :ok = TestSandbox.checkout([store_a, store_b])

      assert {:ok, _} =
               Store.mutate(store_a, fn {db, moment} ->
                 {:ok, db2} =
                   Xitdb.transact_ops(
                     db,
                     [{:put, "entries[\"only_a\"]", "v_a"}],
                     base_moment: moment
                   )

                 {:ok, {db2, Xitdb.moment_count(db2) - 1}, :ok}
               end)

      assert {:ok, _} =
               Store.mutate(store_b, fn {db, moment} ->
                 {:ok, db2} =
                   Xitdb.transact_ops(
                     db,
                     [{:put, "entries[\"only_b\"]", "v_b"}],
                     base_moment: moment
                   )

                 {:ok, {db2, Xitdb.moment_count(db2) - 1}, :ok}
               end)

      assert Store.root(store_a)["entries"]["only_a"] == "v_a"
      assert Store.root(store_b)["entries"]["only_b"] == "v_b"

      :ok = TestSandbox.checkin([store_a])

      # store_b keeps its checked-out sandbox snapshot
      assert Store.root(store_b)["entries"]["only_b"] == "v_b"

      # Re-checking out store_a starts fresh from template without leaked sandbox writes
      :ok = TestSandbox.checkout([store_a])
      assert Store.root(store_a)["entries"]["seed"] == "from_template"
      assert Store.root(store_a)["entries"]["only_a"] == nil
    end

    test "file-backed store reopen after rolled-back or lease-expired write never resurrects uncommitted tail" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "xitdb_store_reopen_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      db_path = Path.join(tmp_dir, "reopen.xit")
      store_name = :"XitdbFileReopen_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        if pid = Process.whereis(store_name) do
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, 1_000)
            catch
              :exit, _ -> :ok
            end
          end
        end

        File.rm_rf!(tmp_dir)
      end)

      {:ok, pid1} = Store.start_link(name: store_name, path: db_path, lease_timeout: 40)

      assert {:ok, {:ok, :committed}} =
               Store.transact(store_name, fn ->
                 Store.mutate(store_name, fn {db, moment} ->
                   {:ok, db2} =
                     Xitdb.transact_ops(
                       db,
                       [
                         {:init_col, "entries", "hash_map"},
                         {:put, "entries[\"kept\"]", "initial"}
                       ],
                       base_moment: moment
                     )

                   {:ok, {db2, Xitdb.moment_count(db2) - 1}, :committed}
                 end)
               end)

      # Explicit rollback after staging an uncommitted moment in the .xit file
      assert {:error, :aborted} =
               Store.transact(store_name, fn ->
                 {:ok, _} =
                   Store.mutate(store_name, fn {db, moment} ->
                     {:ok, db2} =
                       Xitdb.transact_ops(
                         db,
                         [{:put, "entries[\"ghost_abort\"]", "should_vanish"}],
                         base_moment: moment
                       )

                     {:ok, {db2, Xitdb.moment_count(db2) - 1}, :staged}
                   end)

                 Store.rollback(store_name, :aborted)
               end)

      # Lease-expired mutation in the .xit file
      assert {:error, %LeaseError{store: ^store_name, reason: :lease_expired}} =
               Store.transact(store_name, fn ->
                 {:ok, _} =
                   Store.mutate(store_name, fn {db, moment} ->
                     {:ok, db2} =
                       Xitdb.transact_ops(
                         db,
                         [{:put, "entries[\"ghost_lease\"]", "should_vanish"}],
                         base_moment: moment
                       )

                     {:ok, {db2, Xitdb.moment_count(db2) - 1}, :staged}
                   end)

                 Process.sleep(80)
                 :stale
               end)

      assert Store.root(store_name)["entries"]["kept"] == "initial"
      assert Store.root(store_name)["entries"]["ghost_abort"] == nil
      assert Store.root(store_name)["entries"]["ghost_lease"] == nil

      :ok = GenServer.stop(pid1, :normal, 1_000)

      {:ok, _pid2} = Store.start_link(name: store_name, path: db_path)
      assert Store.root(store_name)["entries"]["kept"] == "initial"
      assert Store.root(store_name)["entries"]["ghost_abort"] == nil
      assert Store.root(store_name)["entries"]["ghost_lease"] == nil
    end

    test "cleans up :allow entries on allowed pid exit, fences sandbox zombies, and wakes queued waiters on owner crash" do
      store = start_sandboxed_store()
      :ok = TestSandbox.checkout([store], lease_timeout: 30)
      owner = self()

      # Allowed process exit removes its :allow ETS entry
      allowed =
        spawn(fn ->
          receive do: (:die -> :ok)
        end)

      :ok = TestSandbox.allow([store], owner, allowed)
      # Repeated allow/3 calls for the same {store, pid} do not leak duplicate monitors
      :ok = TestSandbox.allow([store], owner, allowed)
      [{_, coord_pid}] = :ets.lookup(:xitdb_ash_sandbox_checkouts, {:coord, store, owner})
      assert map_size(:sys.get_state(coord_pid).allowed_monitors) == 1

      ref = Process.monitor(allowed)
      send(allowed, :die)
      assert_receive {:DOWN, ^ref, :process, ^allowed, :normal}, 1_000

      wait_until_sandbox(fn ->
        :ets.lookup(:xitdb_ash_sandbox_checkouts, {:allow, store, allowed}) == [] and
          map_size(:sys.get_state(coord_pid).allowed_monitors) == 0
      end)

      # Stale :allow pointing to a checked-in owner is evicted and falls back to $callers
      stale_owner =
        spawn(fn ->
          receive do: (:stop -> :ok)
        end)

      Task.async(fn ->
        :ets.insert(:xitdb_ash_sandbox_checkouts, {{:allow, store, self()}, stale_owner})
        assert TestSandbox.checked_out?(store) == true
        assert :ets.lookup(:xitdb_ash_sandbox_checkouts, {:allow, store, self()}) == []
      end)
      |> Task.await()

      send(stale_owner, :stop)

      # Explicit rollback inside sandbox advances reconciled moment and updates ETS Snapshot
      pre_rb_moment = Store.current_db(store).moment

      assert {:error, :test_abort} =
               Store.transact(store, fn ->
                 {:ok, :staged} =
                   Store.mutate(store, fn {db, moment} ->
                     {:ok, db2} =
                       Xitdb.transact_ops(db, [{:put, "entries[\"rolled_back\"]", "bad"}],
                         base_moment: moment
                       )

                     {:ok, {db2, Xitdb.moment_count(db2) - 1}, :staged}
                   end)

                 Store.rollback(store, :test_abort)
               end)

      assert Store.current_db(store).moment > pre_rb_moment
      assert Store.root(store)["entries"]["rolled_back"] == nil

      # Zombie writer in sandbox is fenced with :stale_write_epoch and ETS reflects restored tip
      pre_exp_moment = Store.current_db(store).moment

      assert {:error, %LeaseError{store: ^store, reason: :lease_expired}} =
               Store.transact(
                 store,
                 fn ->
                   {:ok, :staged} =
                     Store.mutate(store, fn {db, moment} ->
                       {:ok, db2} =
                         Xitdb.transact_ops(db, [{:put, "entries[\"z_staged\"]", "stale"}],
                           base_moment: moment
                         )

                       {:ok, {db2, Xitdb.moment_count(db2) - 1}, :staged}
                     end)

                   wait_until_sandbox(fn ->
                     :sys.get_state(coord_pid).queues[store].active == nil
                   end)

                   {db, moment} = Process.get({:xitdb_tx_state, store})

                   assert {:error, %Xitdb.Error{reason: :stale_write_epoch}} =
                            Xitdb.transact_ops(db, [{:put, "entries[\"z\"]", "stale"}],
                              base_moment: moment
                            )

                   :zombie
                 end,
                 timeout: 500
               )

      assert Store.current_db(store).moment > pre_exp_moment
      assert Store.root(store)["entries"]["z_staged"] == nil
      assert Store.root(store)["entries"]["z"] == nil

      # Queued waiter receives {:error, :sandbox_checked_in} promptly when owner terminates/checks in
      owner2_pid =
        spawn(fn ->
          :ok = TestSandbox.checkout([store], lease_timeout: 5_000)

          Store.transact(store, fn ->
            send(owner, {:owner2_ready, self()})
            receive do: (:hold -> :ok)
          end)
        end)

      assert_receive {:owner2_ready, ^owner2_pid}, 1_000

      [{_, coord2}] = :ets.lookup(:xitdb_ash_sandbox_checkouts, {:coord, store, owner2_pid})

      waiter =
        Task.async(fn ->
          TestSandbox.allow([store], owner2_pid, self())
          Store.transact(store, fn -> :never end, timeout: 5_000)
        end)

      wait_until_sandbox(fn ->
        :queue.len(:sys.get_state(coord2).queues[store].waiters) == 1
      end)

      Process.exit(owner2_pid, :kill)
      assert {:error, :sandbox_checked_in} = Task.await(waiter, 1_000)
    end

    defp wait_until_sandbox(pred, attempts \\ 200)
    defp wait_until_sandbox(_pred, 0), do: flunk("Sandbox condition not met")

    defp wait_until_sandbox(pred, attempts) do
      if pred.() do
        :ok
      else
        Process.sleep(5)
        wait_until_sandbox(pred, attempts - 1)
      end
    end
  end
end
