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
  end
end
