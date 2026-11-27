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

    test "active-lease :cancel_waiter and late expired :abort reconcile sandbox tip and fence stale writer" do
      store = start_sandboxed_store()
      :ok = TestSandbox.checkout([store], lease_timeout: 5_000)
      owner = self()
      [{_, coord_pid}] = :ets.lookup(:xitdb_ash_sandbox_checkouts, {:coord, store, owner})

      writer_a =
        Task.async(fn ->
          TestSandbox.allow([store], owner, self())

          Store.transact(
            store,
            fn ->
              {:ok, :staged} =
                Store.mutate(store, fn {db, moment} ->
                  {:ok, db2} =
                    Xitdb.transact_ops(db, [{:put, "entries[\"cancelled\"]", "bad"}],
                      base_moment: moment
                    )

                  {:ok, {db2, Xitdb.moment_count(db2) - 1}, :staged}
                end)

              send(owner, :sandbox_writer_a_staged)
              receive do: (:sandbox_writer_a_check_fenced -> :ok)

              {db, moment} = Process.get({:xitdb_tx_state, store})

              assert {:error, %Xitdb.Error{reason: :stale_write_epoch}} =
                       Xitdb.transact_ops(db, [{:put, "entries[\"after_cancel\"]", "bad"}],
                         base_moment: moment
                       )

              :writer_a_done
            end,
            lease_timeout: 5_000,
            timeout: 5_000
          )
        end)

      assert_receive :sandbox_writer_a_staged, 1_000
      active = :sys.get_state(coord_pid).queues[store].active
      assert active != nil

      waiter =
        Task.async(fn ->
          TestSandbox.allow([store], owner, self())

          Store.transact(
            store,
            fn ->
              assert Store.root(store)["entries"]["cancelled"] == nil
              :waiter_ok
            end,
            timeout: 5_000
          )
        end)

      wait_until_sandbox(fn ->
        :queue.len(:sys.get_state(coord_pid).queues[store].waiters) == 1
      end)

      GenServer.cast(coord_pid, {:cancel_waiter, store, active.req_ref})
      assert {:ok, :waiter_ok} = Task.await(waiter, 2_000)

      send(writer_a.pid, :sandbox_writer_a_check_fenced)

      assert {:error, %LeaseError{store: ^store, reason: :lease_expired}} =
               Task.await(writer_a, 2_000)

      assert Store.root(store)["entries"]["cancelled"] == nil

      # Late expired :abort when queue.active == nil keeps the sandbox healthy
      wait_until_sandbox(fn -> :sys.get_state(coord_pid).queues[store].active == nil end)
      GenServer.cast(coord_pid, {:abort, store, make_ref(), self()})
      _ = :sys.get_state(coord_pid)
      assert Store.root(store)["entries"]["seed"] == "from_template"
    end

    test "swap_compacted_base with close_previous?: false keeps pre-swap sandbox cursors readable" do
      store = start_sandboxed_store()
      assert :ok = TestSandbox.checkout([store])
      on_exit(fn -> TestSandbox.checkin([store]) end)

      pre_cursor = Store.root(store)
      assert pre_cursor["entries"]["seed"] == "from_template"

      compacted = Xitdb.open!(backend: :memory)
      {:ok, compacted} = Xitdb.transact(compacted, %{"entries" => %{"seed" => "compacted"}})

      assert :ok = Store.swap_compacted_base(store, compacted, nil, close_previous?: false)
      assert Store.root(store)["entries"]["seed"] == "compacted"
      assert pre_cursor["entries"]["seed"] == "from_template"
    end

    test "seed_template/2, shared: true checkouts, registered atom $callers, explicit lease_timeout, waiter timeout, and holder crash recovery" do
      # 1. seed_template with populated db and with empty (0-moment) db
      store_tmpl = :"XitdbTmplStore_#{System.unique_integer([:positive])}"
      tmpl_db = Xitdb.open!(backend: :memory) |> Xitdb.transact!(%{"tmpl" => "seeded"})
      on_exit(fn -> Xitdb.close(tmpl_db) end)

      assert :ok == TestSandbox.seed_template(store_tmpl, tmpl_db)
      assert :ok == TestSandbox.checkout([store_tmpl])
      assert Store.root(store_tmpl)["tmpl"] == "seeded"
      assert :ok == TestSandbox.checkin([store_tmpl])

      store_empty_tmpl = :"XitdbEmptyTmplStore_#{System.unique_integer([:positive])}"
      empty_tmpl = Xitdb.open!(backend: :memory)
      on_exit(fn -> Xitdb.close(empty_tmpl) end)

      assert :ok == TestSandbox.seed_template(store_empty_tmpl, empty_tmpl)
      assert :ok == TestSandbox.checkout([store_empty_tmpl])
      assert Store.root(store_empty_tmpl)["anything"] == nil
      assert :ok == TestSandbox.checkin([store_empty_tmpl])

      # 2. shared: true checkout visible from unlinked process, and stale :shared entry cleaned up
      store = start_sandboxed_store()
      assert :ok == TestSandbox.checkout([store], shared: true, lease_timeout: 25)
      parent = self()

      spawn(fn ->
        send(parent, {:shared_read, Store.root(store)["entries"]["seed"]})
      end)

      assert_receive {:shared_read, "from_template"}, 1_000

      # Explicit lease_timeout overrides short sandbox default (25ms)
      assert {:ok, :extended} ==
               Store.transact(
                 store,
                 fn ->
                   Process.sleep(50)
                   :extended
                 end,
                 lease_timeout: 500
               )

      # Registered atom name, nil, and non-pid entries in $callers (on a NON-shared store so :shared doesn't mask it)
      non_shared_store = start_sandboxed_store()
      assert :ok == TestSandbox.checkout([non_shared_store], shared: false)
      reg_name = :"xitdb_sb_owner_#{System.unique_integer([:positive])}"
      Process.register(self(), reg_name)

      on_exit(fn ->
        if Process.whereis(reg_name) == self(), do: Process.unregister(reg_name)
      end)

      assert :ok ==
               Task.async(fn ->
                 Process.put(:"$callers", [nil, "not_pid", :unregistered_sb_name, reg_name])
                 assert TestSandbox.checked_out?(non_shared_store) == true
                 :ok
               end)
               |> Task.await()

      assert :ok == TestSandbox.checkin([non_shared_store])

      # Waiter timeout cancellation inside sandbox (queued waiter cancels cleanly)
      holder =
        Task.async(fn ->
          Store.transact(
            store,
            fn ->
              send(parent, :sb_holder_ready)
              receive do: (:release_sb_holder -> :holder_ok)
            end,
            lease_timeout: 2_000
          )
        end)

      assert_receive :sb_holder_ready, 1_000

      assert {:error, %LeaseError{store: ^store, reason: :lease_timeout}} =
               Store.transact(store, fn -> :never end, timeout: 15)

      send(holder.pid, :release_sb_holder)
      assert {:ok, :holder_ok} = Task.await(holder, 1_000)

      # Holder crash (:DOWN) inside sandbox releases lease for subsequent writer
      crasher =
        spawn(fn ->
          Store.transact(
            store,
            fn ->
              send(parent, :sb_crasher_ready)
              Process.exit(self(), :kill)
            end,
            lease_timeout: 2_000
          )
        end)

      mref = Process.monitor(crasher)
      assert_receive :sb_crasher_ready, 1_000
      assert_receive {:DOWN, ^mref, :process, ^crasher, :killed}, 1_000
      assert {:ok, :recovered} = Store.transact(store, fn -> :recovered end)

      # Unknown handle_info message on Coordinator is ignored
      [{_, coord_pid}] = :ets.lookup(:xitdb_ash_sandbox_checkouts, {:coord, store, self()})
      send(coord_pid, :unexpected_coord_msg)
      assert Process.alive?(coord_pid)
      _ = :sys.get_state(coord_pid)

      # allow/3 guard and error when not checked out
      assert_raise FunctionClauseError, fn ->
        apply(TestSandbox, :allow, [store, :bad, self()])
      end

      assert_raise FunctionClauseError, fn ->
        apply(TestSandbox, :allow, [store, self(), :bad])
      end

      assert_raise ArgumentError, ~r/has not checked out/, fn ->
        TestSandbox.allow(:unchecked_store_xyz, self(), self())
      end

      assert_raise ArgumentError, ~r/was checked in/, fn ->
        TestSandbox.transact(:unchecked_store_xyz, fn -> :ok end, 500)
      end

      assert_raise FunctionClauseError, fn ->
        apply(TestSandbox, :transact, ["bad", fn -> :ok end, 500])
      end

      assert_raise FunctionClauseError, fn ->
        apply(TestSandbox, :transact, [store, :not_fun, 500])
      end

      assert :ok == TestSandbox.checkin([store])

      # Stale :shared entry pointing to dead/checked-in owner is evicted
      :ets.insert(:xitdb_ash_sandbox_checkouts, {{:shared, store}, self()})
      assert TestSandbox.checkout_db(store) == :none
      assert :ets.lookup(:xitdb_ash_sandbox_checkouts, {:shared, store}) == []

      # Coordinator.stop/1 on already-dead pid returns :ok
      assert :ok == TestSandbox.Coordinator.stop(coord_pid)
    end

    test "Coordinator guards, partial checkin monitor retention, invalid commit, unrelated :DOWN/:lease_expired, and stop/1 on live pid" do
      alias Xitdb.Ash.TestSandbox.Coordinator

      store_a = start_sandboxed_store()
      store_b = start_sandboxed_store()
      assert :ok == TestSandbox.checkout([store_a, store_b], lease_timeout: 5_000)
      owner = self()
      [{_, coord_pid}] = :ets.lookup(:xitdb_ash_sandbox_checkouts, {:coord, store_a, owner})

      # 1. Coordinator guard clauses
      assert_raise FunctionClauseError, fn ->
        apply(Coordinator, :allow, [:bad, store_a, self()])
      end

      assert_raise FunctionClauseError, fn ->
        apply(Coordinator, :allow, [coord_pid, "bad", self()])
      end

      assert_raise FunctionClauseError, fn ->
        apply(Coordinator, :allow, [coord_pid, store_a, :bad])
      end

      assert_raise FunctionClauseError, fn ->
        apply(Coordinator, :checkin_stores, [:bad, [store_a]])
      end

      assert_raise FunctionClauseError, fn ->
        apply(Coordinator, :checkin_stores, [coord_pid, :bad])
      end

      # 2. Partial checkin demonitors store_a's allowed pid while retaining store_b's allowed monitor
      p_a = spawn(fn -> receive do: (:stop -> :ok) end)
      p_b = spawn(fn -> receive do: (:stop -> :ok) end)

      on_exit(fn ->
        send(p_a, :stop)
        send(p_b, :stop)
      end)

      assert :ok == TestSandbox.allow([store_a], owner, p_a)
      assert :ok == TestSandbox.allow([store_b], owner, p_b)
      assert map_size(:sys.get_state(coord_pid).allowed_monitors) == 2

      assert :ok == TestSandbox.checkin([store_a])
      assert Map.values(:sys.get_state(coord_pid).allowed_monitors) == [{store_b, p_b}]

      # 3. Direct invalid commit moment returns {:error, :invalid_moment} and releases lease
      req_ref = make_ref()

      {:ok, lease_ref, {fenced_db, _m}} =
        GenServer.call(coord_pid, {:acquire, store_b, req_ref, 500, nil})

      assert {:error, :invalid_moment} ==
               GenServer.call(coord_pid, {:commit, store_b, lease_ref, {fenced_db, 999}})

      assert :sys.get_state(coord_pid).queues[store_b].active == nil

      # 4. Unrelated :DOWN, wrong :xitdb_lease_expired, and stale :commit while another lease is active
      req2 = make_ref()

      {:ok, lease2, {fenced_db2, m2}} =
        GenServer.call(coord_pid, {:acquire, store_b, req2, 500, nil})

      send(coord_pid, {:DOWN, make_ref(), :process, self(), :normal})
      send(coord_pid, {:xitdb_lease_expired, store_b, make_ref()})

      assert {:error, :lease_expired} ==
               GenServer.call(coord_pid, {:commit, store_b, make_ref(), {fenced_db2, m2}})

      # Active lease must still be held!
      assert :sys.get_state(coord_pid).queues[store_b].active.ref == lease2

      # Queued waiter cancelled via :cancel_waiter removes only the waiter, leaving active lease intact
      waiter_req = make_ref()

      waiter =
        Task.async(fn ->
          GenServer.call(coord_pid, {:acquire, store_b, waiter_req, 5_000, nil}, 5_000)
        end)

      wait_until_sandbox(fn ->
        :queue.len(:sys.get_state(coord_pid).queues[store_b].waiters) == 1
      end)

      GenServer.cast(coord_pid, {:cancel_waiter, store_b, waiter_req})

      wait_until_sandbox(fn ->
        :queue.len(:sys.get_state(coord_pid).queues[store_b].waiters) == 0
      end)

      assert :sys.get_state(coord_pid).queues[store_b].active.ref == lease2
      Task.shutdown(waiter, :brutal_kill)

      # Commit active lease cleanly
      assert :ok == GenServer.call(coord_pid, {:commit, store_b, lease2, {fenced_db2, m2}})

      # Stale commit when active == nil reconciles cleanly
      assert {:error, :lease_expired} ==
               GenServer.call(coord_pid, {:commit, store_b, make_ref(), {fenced_db2, m2}})

      # 5. Checking in a store while a waiter is queued replies {:error, :sandbox_checked_in}
      store_c = start_sandboxed_store()
      assert :ok == TestSandbox.checkout([store_c], lease_timeout: 5_000)
      [{_, coord_c}] = :ets.lookup(:xitdb_ash_sandbox_checkouts, {:coord, store_c, owner})
      {:ok, _l_c, _snap_c} = GenServer.call(coord_c, {:acquire, store_c, make_ref(), 5_000, nil})

      queued_c =
        Task.async(fn ->
          GenServer.call(coord_c, {:acquire, store_c, make_ref(), 5_000, nil}, 5_000)
        end)

      wait_until_sandbox(fn ->
        :queue.len(:sys.get_state(coord_c).queues[store_c].waiters) == 1
      end)

      assert :ok == TestSandbox.checkin([store_c])
      assert {:error, :sandbox_checked_in} == Task.await(queued_c, 1_000)

      # 6. Coordinator.stop/1 terminates a live coordinator cleanly
      assert Process.alive?(coord_pid)
      assert :ok == Coordinator.stop(coord_pid)
      refute Process.alive?(coord_pid)
      assert :ok == Coordinator.checkin_stores(coord_pid, [store_b])
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
