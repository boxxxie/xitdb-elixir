if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.StoreTest do
    use ExUnit.Case, async: true

    alias Xitdb.Ash.{LeaseError, Store}

    defmodule ParentOrg do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store Xitdb.Ash.StoreTest.FkStore
        collection :parent_orgs
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, public?: true)
      end
    end

    defmodule ChildEvent do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store Xitdb.Ash.StoreTest.FkStore
        collection :child_events

        references do
          reference :parent_org, on_delete: :restrict
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, public?: true)
      end

      relationships do
        belongs_to(:parent_org, ParentOrg, attribute_type: :integer, allow_nil?: false)
      end
    end

    defmodule NonXitdbAudit do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false

      attributes do
        integer_primary_key(:id)
      end
    end

    defmodule FkDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(ParentOrg)
        resource(ChildEvent)
        resource(NonXitdbAudit)
      end
    end

    defp start_ephemeral_store(opts \\ []) do
      uid = System.unique_integer([:positive])
      name = Keyword.get_lazy(opts, :name, fn -> :"XitdbStoreTest_#{uid}" end)

      start_opts =
        opts
        |> Keyword.put_new(:name, name)
        |> Keyword.put_new(:path, :memory)

      {:ok, pid} = Store.start_link(start_opts)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {name, pid}
    end

    test "serializes concurrent transactions in FIFO order and preserves caller context" do
      {store, _pid} = start_ephemeral_store()
      Process.put(:caller_marker, :preserved)

      t1_started = self()

      t1 =
        Task.async(fn ->
          Store.transact(store, fn ->
            send(t1_started, :t1_acquired)
            receive do: (:release_t1 -> :ok)

            {:ok, :v1} =
              Store.mutate(store, fn {db, moment} ->
                {:ok, updated_db} =
                  Xitdb.transact_ops(
                    db,
                    [
                      {:init_col, "log", "linked_array_list"},
                      {:append, "log", "first"}
                    ],
                    base_moment: moment
                  )

                {:ok, {updated_db, Xitdb.moment_count(updated_db) - 1}, :v1}
              end)

            :t1_done
          end)
        end)

      assert_receive :t1_acquired, 1_000

      t2 =
        Task.async(fn ->
          Store.transact(store, fn ->
            {:ok, :v2} =
              Store.mutate(store, fn {db, moment} ->
                {:ok, updated_db} =
                  Xitdb.transact_ops(db, [{:append, "log", "second"}], base_moment: moment)

                {:ok, {updated_db, Xitdb.moment_count(updated_db) - 1}, :v2}
              end)

            :t2_done
          end)
        end)

      # Give t2 a brief moment to enqueue behind t1 before releasing t1
      Process.sleep(30)
      send(t1.pid, :release_t1)

      assert {:ok, :t1_done} = Task.await(t1)
      assert {:ok, :t2_done} = Task.await(t2)

      # Inside Store.transact, caller process dictionary is preserved
      assert {:ok, :preserved} = Store.transact(store, fn -> Process.get(:caller_marker) end)

      root = Store.root(store)
      assert Enum.to_list(root["log"]) == ["first", "second"]
    end

    test "cancels waiters cleanly on call timeout race and rejects zombie commits after lease expiration" do
      {store, _pid} = start_ephemeral_store(lease_timeout: 200)

      parent = self()

      # Waiter timeout cancellation race: hold lease for 60ms while caller wait timeout is 20ms
      holder =
        Task.async(fn ->
          Store.transact(
            store,
            fn ->
              send(parent, :holder_ready)
              Process.sleep(60)
              :holder_done
            end,
            timeout: 500
          )
        end)

      assert_receive :holder_ready, 1_000

      assert {:error, %LeaseError{store: ^store, reason: :lease_timeout}} =
               Store.transact(store, fn -> :never_runs end, timeout: 20)

      assert {:ok, :holder_done} = Task.await(holder, 1_000)

      # Next transaction can still acquire and commit cleanly
      assert {:ok, :recovered} = Store.transact(store, fn -> :recovered end, timeout: 500)

      # Zombie commit rejection: exceed store lease_timeout (40ms) inside closure
      {short_store, _short_pid} = start_ephemeral_store(lease_timeout: 40)

      assert {:error, %LeaseError{store: ^short_store, reason: :lease_expired}} =
               Store.transact(
                 short_store,
                 fn ->
                   Process.sleep(80)
                   :stale_result
                 end,
                 timeout: 500
               )
    end

    test "reclaims lease on holder crash (:DOWN) and restores file-backed .xit tip on rollback" do
      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "xitdb_store_test_#{System.unique_integer([:positive])}.xit"
        )

      on_exit(fn -> File.rm(tmp_path) end)

      {store, store_pid} = start_ephemeral_store(path: tmp_path, lease_timeout: 500)

      assert {:ok, :seed} =
               Store.mutate(store, fn {db, moment} ->
                 {:ok, db2} =
                   Xitdb.transact_ops(
                     db,
                     [{:init_col, "items", "hash_map"}, {:put, "items[\"k1\"]", "good"}],
                     base_moment: moment
                   )

                 {:ok, {db2, Xitdb.moment_count(db2) - 1}, :seed}
               end)

      # Rollback after an uncommitted Xitdb.transact_ops write must restore tip cleanly
      assert {:error, :abort_write} =
               Store.transact(store, fn ->
                 {:ok, _} =
                   Store.mutate(store, fn {db, moment} ->
                     {:ok, db2} =
                       Xitdb.transact_ops(
                         db,
                         [{:put, "items[\"k1\"]", "corrupted"}],
                         base_moment: moment
                       )

                     {:ok, {db2, Xitdb.moment_count(db2) - 1}, :mutated}
                   end)

                 Store.rollback(store, :abort_write)
               end)

      assert Store.root(store)["items"]["k1"] == "good"

      # Holder crash must release lease for subsequent callers
      parent = self()

      crasher =
        spawn(fn ->
          Store.transact(store, fn ->
            send(parent, :crasher_holding)
            Process.exit(self(), :kill)
          end)
        end)

      ref = Process.monitor(crasher)
      assert_receive :crasher_holding, 1_000
      assert_receive {:DOWN, ^ref, :process, ^crasher, :killed}, 1_000

      assert {:ok, :after_crash} = Store.transact(store, fn -> :after_crash end)

      # Reopening the file-backed store preserves only committed moments
      :ok = GenServer.stop(store_pid, :normal, 1_000)
      {reopened_store, _pid2} = start_ephemeral_store(path: tmp_path)
      assert Store.root(reopened_store)["items"]["k1"] == "good"
    end

    test "supports nested savepoints and cross-store rollback hygiene" do
      {store_a, _} = start_ephemeral_store()
      {store_b, _} = start_ephemeral_store()

      assert {:ok, :committed} =
               Store.transact(store_a, fn ->
                 {:ok, _} =
                   Store.mutate(store_a, fn {db, moment} ->
                     {:ok, db2} =
                       Xitdb.transact_ops(
                         db,
                         [
                           {:init_col, "nums", "hash_map"},
                           {:put, "nums[\"a\"]", 1}
                         ],
                         base_moment: moment
                       )

                     {:ok, {db2, Xitdb.moment_count(db2) - 1}, :a}
                   end)

                 # Inner savepoint rolls back cleanly without losing outer write
                 assert {:error, :inner_abort} =
                          Store.transact(store_a, fn ->
                            {:ok, _} =
                              Store.mutate(store_a, fn {db, moment} ->
                                {:ok, db2} =
                                  Xitdb.transact_ops(
                                    db,
                                    [{:put, "nums[\"b\"]", 999}],
                                    base_moment: moment
                                  )

                                {:ok, {db2, Xitdb.moment_count(db2) - 1}, :b}
                              end)

                            Store.rollback(store_a, :inner_abort)
                          end)

                 assert Store.root(store_a)["nums"]["a"] == 1
                 assert Store.root(store_a)["nums"]["b"] == nil

                 # Cross-store rollback of store_a from inside store_b cleans up store_b snapshot too
                 assert {:error, :cross_abort} =
                          Store.transact(store_a, fn ->
                            Store.transact(store_b, fn ->
                              {:ok, _} =
                                Store.mutate(store_b, fn {db, moment} ->
                                  {:ok, db2} =
                                    Xitdb.transact_ops(
                                      db,
                                      [
                                        {:init_col, "b_col", "hash_map"},
                                        {:put, "b_col[\"x\"]", "leaked"}
                                      ],
                                      base_moment: moment
                                    )

                                  {:ok, {db2, Xitdb.moment_count(db2) - 1}, :b_write}
                                end)

                              Store.rollback(store_a, :cross_abort)
                            end)
                          end)

                 :committed
               end)

      assert Store.root(store_a)["nums"]["a"] == 1
      assert Store.root(store_b)["b_col"] == nil
    end

    test "compiles boot-time reverse-FK graph filtered strictly to same-store Xitdb.Ash.DataLayer resources" do
      {store, _pid} =
        start_ephemeral_store(
          name: Xitdb.Ash.StoreTest.FkStore,
          domains: [FkDomain]
        )

      assert [
               %{
                 source_resource: ChildEvent,
                 source_collection: :child_events,
                 source_attribute: :parent_org_id,
                 destination_attribute: :id,
                 on_delete: :restrict,
                 nested?: false
               }
             ] = Store.reverse_fks(store, ParentOrg)

      assert Store.reverse_fks(store, ChildEvent) == []
    end

    test "emits [:xitdb, :ash, :transaction] telemetry spans" do
      {store, _pid} = start_ephemeral_store()
      handler_id = "store-telemetry-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach_many(
        handler_id,
        [[:xitdb, :ash, :transaction, :start], [:xitdb, :ash, :transaction, :stop]],
        fn event, measurements, meta, _ ->
          if meta.store == store do
            send(parent, {:telemetry, event, measurements, meta})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, 42} = Store.transact(store, fn -> 42 end)

      assert_receive {:telemetry, [:xitdb, :ash, :transaction, :start], _,
                      %{store: ^store, mode: :leased}}

      assert_receive {:telemetry, [:xitdb, :ash, :transaction, :stop], _,
                      %{store: ^store, mode: :leased, status: :ok}}
    end

    test "synchronous abort_lease releases lease before returning and unmatched :DOWN does not interfere" do
      {store, pid} = start_ephemeral_store()

      assert {:error, :rolled_back} =
               Store.transact(store, fn ->
                 # Simulate an unrelated process dying while we hold the active lease
                 send(pid, {:DOWN, make_ref(), :process, self(), :normal})
                 Store.rollback(store, :rolled_back)
               end)

      # Immediately after rollback returns, the store lease is already released
      state = :sys.get_state(pid)
      assert state.queue.active == nil
    end
  end
end
