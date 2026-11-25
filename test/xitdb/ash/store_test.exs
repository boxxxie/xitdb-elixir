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
      {store, store_pid} = start_ephemeral_store()
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

      wait_until(fn -> :queue.len(:sys.get_state(store_pid).queue.waiters) == 1 end)
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

      # Waiter timeout cancellation race: hold lease deterministically while caller wait times out
      holder =
        Task.async(fn ->
          Store.transact(
            store,
            fn ->
              send(parent, :holder_ready)
              receive do: (:release_holder -> :holder_done)
            end,
            timeout: 1_000
          )
        end)

      assert_receive :holder_ready, 1_000

      assert {:error, %LeaseError{store: ^store, reason: :lease_timeout}} =
               Store.transact(store, fn -> :never_runs end, timeout: 15)

      send(holder.pid, :release_holder)
      assert {:ok, :holder_done} = Task.await(holder, 1_000)

      # Next transaction can still acquire and commit cleanly
      assert {:ok, :recovered} = Store.transact(store, fn -> :recovered end, timeout: 500)

      # Zombie commit rejection: wait deterministically for short_store lease expiration
      {short_store, short_pid} = start_ephemeral_store(lease_timeout: 25)

      assert {:error, %LeaseError{store: ^short_store, reason: :lease_expired}} =
               Store.transact(
                 short_store,
                 fn ->
                   wait_until(fn -> :sys.get_state(short_pid).queue.active == nil end)
                   :stale_result
                 end,
                 timeout: 500
               )
    end

    defp wait_until(pred, attempts \\ 200)
    defp wait_until(_pred, 0), do: flunk("Condition not satisfied before deadline")

    defp wait_until(pred, attempts) do
      if pred.() do
        :ok
      else
        Process.sleep(1)
        wait_until(pred, attempts - 1)
      end
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

    test "Store.with_as_of/3 pins historical moments on plain atom-named stores" do
      {store, _pid} = start_ephemeral_store()

      {:ok, m0} =
        Store.mutate(store, fn {db, moment} ->
          {:ok, db2} =
            Xitdb.transact(db, %{"vals" => %{"v" => 1}}, base_moment: moment)

          m0 = Xitdb.moment_count(db2) - 1
          {:ok, {db2, m0}, m0}
        end)

      {:ok, _m1} =
        Store.mutate(store, fn {db, moment} ->
          {:ok, db2} =
            Xitdb.transact(db, %{"vals" => %{"v" => 2}}, base_moment: moment)

          m1 = Xitdb.moment_count(db2) - 1
          {:ok, {db2, m1}, m1}
        end)

      assert Store.root(store)["vals"]["v"] == 2

      assert 1 ==
               Store.with_as_of(store, m0, fn ->
                 Store.root(store)["vals"]["v"]
               end)

      assert Store.root(store)["vals"]["v"] == 2
    end

    test "reverse_fks/2 includes nested_in children with nested?: true" do
      defmodule NestedParentOrg do
        use Ash.Resource,
          domain: nil,
          data_layer: Xitdb.Ash.DataLayer,
          validate_domain_inclusion?: false

        xitdb do
          store(Xitdb.Ash.StoreTest.NestedFkStore)
          collection(:parent_orgs)
        end

        attributes do
          integer_primary_key(:id)
        end
      end

      defmodule NestedChildSession do
        use Ash.Resource,
          domain: nil,
          data_layer: Xitdb.Ash.DataLayer,
          validate_domain_inclusion?: false

        xitdb do
          store(Xitdb.Ash.StoreTest.NestedFkStore)
          collection(:nested_sessions)

          nested_in(:parent_orgs,
            foreign_key: :parent_org_id,
            path: :sessions,
            cardinality: :many
          )
        end

        attributes do
          integer_primary_key(:id)
          attribute(:parent_org_id, :integer, allow_nil?: false, public?: true)
        end
      end

      defmodule NestedFkDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          resource(NestedParentOrg)
          resource(NestedChildSession)
        end
      end

      {store, _pid} =
        start_ephemeral_store(
          name: Xitdb.Ash.StoreTest.NestedFkStore,
          domains: [NestedFkDomain]
        )

      assert [
               %{
                 source_resource: NestedChildSession,
                 source_collection: :nested_sessions,
                 source_attribute: :parent_org_id,
                 destination_attribute: :id,
                 on_delete: :delete,
                 nested?: true
               }
             ] = Store.reverse_fks(store, NestedParentOrg)
    end

    test "supports explicit :lease_timeout override and records self-documenting __tx metadata on seed and rollbacks" do
      # Store.ensure_seeded! stamps moment 0 with source/action/actor/instant
      {short_store, _short_pid} = start_ephemeral_store(lease_timeout: 25)
      seed_meta = Xitdb.tx_meta!(Store.current_db(short_store), 0)
      assert seed_meta["doc"] == "initialize store metadata"
      assert is_integer(seed_meta["tx_instant"]) and seed_meta["tx_instant"] > 0
      assert seed_meta["source_system"] == "xitdb_store"
      assert seed_meta["action_name"] == "init_store"
      assert seed_meta["actor_id"] == "system"

      # Baseline: opts[:timeout] does NOT extend state.lease_timeout when :lease_timeout is omitted
      assert {:error, %LeaseError{store: ^short_store, reason: :lease_expired}} =
               Store.transact(
                 short_store,
                 fn ->
                   Process.sleep(60)
                   :late
                 end,
                 timeout: 500
               )

      # Explicit :lease_timeout overrides the store default for heavy transactions
      assert {:ok, :extended_ok} =
               Store.transact(
                 short_store,
                 fn ->
                   Process.sleep(60)
                   :extended_ok
                 end,
                 lease_timeout: 500
               )

      # Rollbacks via Store.rollback/2, :lease_expired, and :DOWN stamp full rollback attribution
      {rb_store, _rb_pid} = start_ephemeral_store(lease_timeout: 25)

      assert {:ok, :seeded} =
               Store.mutate(rb_store, fn {db, moment} ->
                 {:ok, db2} =
                   Xitdb.transact_ops(
                     db,
                     [{:init_col, "items", "hash_map"}, {:put, "items[\"k\"]", "v0"}],
                     base_moment: moment,
                     doc: "seed item",
                     instant: 1_700_000_001_000
                   )

                 {:ok, {db2, Xitdb.moment_count(db2) - 1}, :seeded}
               end)

      assert {:error, :abort_rb} =
               Store.transact(rb_store, fn ->
                 {:ok, _} =
                   Store.mutate(rb_store, fn {db, moment} ->
                     {:ok, db2} =
                       Xitdb.transact_ops(
                         db,
                         [{:put, "items[\"k\"]", "corrupt1"}],
                         base_moment: moment,
                         doc: "uncommitted corrupt1",
                         instant: 1_700_000_002_000
                       )

                     {:ok, {db2, Xitdb.moment_count(db2) - 1}, :corrupt1}
                   end)

                 Store.rollback(rb_store, :abort_rb)
               end)

      aborted_meta = Xitdb.tx_meta!(Store.current_db(rb_store))
      assert aborted_meta["doc"] =~ "rollback tip from moment"
      assert aborted_meta["doc"] =~ "(aborted)"
      assert aborted_meta["tx_instant"] > 1_700_000_002_000
      assert aborted_meta["restored_moment"] == 1
      assert aborted_meta["rolled_back_from"] == 2
      assert aborted_meta["rollback_reason"] == "aborted"
      assert aborted_meta["source_system"] == "xitdb_store"
      assert aborted_meta["action_name"] == "rollback_tip"

      # Lease expiration rollback
      prev_tip = Store.current_db(rb_store).moment

      assert {:error, %LeaseError{store: ^rb_store, reason: :lease_expired}} =
               Store.transact(
                 rb_store,
                 fn ->
                   {:ok, _} =
                     Store.mutate(rb_store, fn {db, moment} ->
                       {:ok, db2} =
                         Xitdb.transact_ops(
                           db,
                           [{:put, "items[\"k\"]", "corrupt2"}],
                           base_moment: moment,
                           doc: "uncommitted corrupt2",
                           instant: 1_700_000_003_000
                         )

                       {:ok, {db2, Xitdb.moment_count(db2) - 1}, :corrupt2}
                     end)

                   Process.sleep(60)
                   :late
                 end,
                 timeout: 500
               )

      expired_meta = Xitdb.tx_meta!(Store.current_db(rb_store))
      assert expired_meta["doc"] =~ "rollback tip from moment"
      assert expired_meta["doc"] =~ "(lease_expired)"
      assert expired_meta["restored_moment"] == prev_tip
      assert expired_meta["rollback_reason"] == "lease_expired"
      assert expired_meta["action_name"] == "rollback_tip"

      # Process crash (:DOWN) rollback
      parent = self()
      {crash_store, _crash_pid} = start_ephemeral_store(lease_timeout: 500)

      {:ok, :seeded} =
        Store.mutate(crash_store, fn {db, moment} ->
          {:ok, db2} =
            Xitdb.transact_ops(
              db,
              [{:init_col, "items", "hash_map"}, {:put, "items[\"k\"]", "ok"}],
              base_moment: moment,
              doc: "seed crash store",
              instant: 1_700_000_004_000
            )

          {:ok, {db2, Xitdb.moment_count(db2) - 1}, :seeded}
        end)

      crasher =
        spawn(fn ->
          Store.transact(crash_store, fn ->
            {:ok, _} =
              Store.mutate(crash_store, fn {db, moment} ->
                {:ok, db2} =
                  Xitdb.transact_ops(
                    db,
                    [{:put, "items[\"k\"]", "crashed_write"}],
                    base_moment: moment,
                    doc: "uncommitted crash write",
                    instant: 1_700_000_005_000
                  )

                {:ok, {db2, Xitdb.moment_count(db2) - 1}, :crashed}
              end)

            send(parent, :crasher_ready)
            Process.exit(self(), :kill)
          end)
        end)

      ref = Process.monitor(crasher)
      assert_receive :crasher_ready, 1_000
      assert_receive {:DOWN, ^ref, :process, ^crasher, :killed}, 1_000

      assert {:ok, :recovered} = Store.transact(crash_store, fn -> :recovered end)
      down_meta = Xitdb.tx_meta!(Store.current_db(crash_store))
      assert down_meta["doc"] =~ "(process_down)"
      assert down_meta["rollback_reason"] == "process_down"
      assert down_meta["restored_moment"] == 1
      assert down_meta["rolled_back_from"] == 2
      assert down_meta["action_name"] == "rollback_tip"
    end

    test "fences zombie writers with :stale_write_epoch, un-clamps lease_timeout, swaps base atomically, isolates as_of(-1), and terminates safely on closed db" do
      alias Xitdb.Ash.Store.Snapshot

      # 1. Zombie writer trying Xitdb.transact_ops after lease_timeout expires is fenced
      {store, pid} = start_ephemeral_store(lease_timeout: 25)

      {:ok, :seed} =
        Store.mutate(store, fn {db, moment} ->
          {:ok, db2} =
            Xitdb.transact_ops(db, [{:init_col, "k", "hash_map"}, {:put, "k[\"v\"]", "init"}],
              base_moment: moment
            )

          {:ok, {db2, Xitdb.moment_count(db2) - 1}, :seed}
        end)

      assert {:error, %LeaseError{store: ^store, reason: :lease_expired}} =
               Store.transact(
                 store,
                 fn ->
                   wait_until(fn -> :sys.get_state(pid).queue.active == nil end)

                   {db, moment} = Process.get({:xitdb_tx_state, store})

                   assert {:error, %Xitdb.Error{reason: :stale_write_epoch}} =
                            Xitdb.transact_ops(db, [{:put, "k[\"v\"]", "zombie"}],
                              base_moment: moment
                            )

                   :zombie_done
                 end,
                 timeout: 500
               )

      assert Store.root(store)["k"]["v"] == "init"

      assert {:error, %LeaseError{store: ^store, reason: :lease_expired}} =
               Store.mutate(
                 store,
                 fn {db, moment} ->
                   wait_until(fn -> :sys.get_state(pid).queue.active == nil end)

                   with {:ok, db2} <-
                          Xitdb.transact_ops(db, [{:put, "k[\"v\"]", "zombie_mutate"}],
                            base_moment: moment
                          ) do
                     {:ok, {db2, Xitdb.moment_count(db2) - 1}, :zombie_mutate}
                   end
                 end,
                 lease_timeout: 25,
                 timeout: 500
               )

      assert Store.root(store)["k"]["v"] == "init"

      # 2. Short opts[:timeout] does NOT clamp state.lease_timeout when :lease_timeout is omitted
      {no_clamp_store, _} = start_ephemeral_store(lease_timeout: 200)

      assert {:ok, :ok} =
               Store.transact(
                 no_clamp_store,
                 fn ->
                   Process.sleep(50)
                   :ok
                 end,
                 timeout: 20
               )

      # 3. Store.as_of(store, -1) does not leak uncommitted staged moments to concurrent readers
      staged_m =
        Store.transact(
          no_clamp_store,
          fn ->
            {:ok, :staged} =
              Store.mutate(no_clamp_store, fn {db, moment} ->
                {:ok, db2} =
                  Xitdb.transact_ops(db, [{:put, "uncommitted", "leak"}], base_moment: moment)

                {:ok, {db2, Xitdb.moment_count(db2) - 1}, :staged}
              end)

            # Check from a separate unlinked process without $callers or tx_db
            parent = self()

            spawn(fn ->
              val = Store.as_of(no_clamp_store, -1)["uncommitted"]
              send(parent, {:reader_saw, val})
            end)

            receive do
              {:reader_saw, val} ->
                assert val == nil
                Store.rollback(no_clamp_store, :checked)
            end
          end
        )

      assert {:error, :checked} = staged_m

      # 4. Store.swap_compacted_base/3 works standalone (with subsequent mutations) and inside Store.transact
      compacted = Xitdb.open!(backend: :memory)
      {:ok, compacted} = Xitdb.transact(compacted, %{"swapped" => "yes"})
      assert :ok = Store.swap_compacted_base(no_clamp_store, compacted)
      assert Store.root(no_clamp_store)["swapped"] == "yes"

      assert {:ok, :ok} =
               Store.mutate(no_clamp_store, fn {db, moment} ->
                 {:ok, db2} =
                   Xitdb.transact_ops(db, [{:put, "after_swap", "ok"}], base_moment: moment)

                 {:ok, {db2, Xitdb.moment_count(db2) - 1}, :ok}
               end)

      assert Store.root(no_clamp_store)["after_swap"] == "ok"

      compacted2 = Xitdb.open!(backend: :memory)
      {:ok, compacted2} = Xitdb.transact(compacted2, %{"swapped_in_tx" => "yes"})

      assert {:ok, :ok} =
               Store.transact(no_clamp_store, fn ->
                 Store.swap_compacted_base(no_clamp_store, compacted2)
               end)

      assert Store.root(no_clamp_store)["swapped_in_tx"] == "yes"

      # 5. Terminating a Store whose db was already closed cleans up Snapshot without crashing
      {closed_store, closed_pid} = start_ephemeral_store()
      raw_db = :sys.get_state(closed_pid).db
      :ok = Xitdb.close(raw_db)
      assert :ok = GenServer.stop(closed_pid, :normal, 1_000)
      assert_raise ArgumentError, fn -> Snapshot.current_moment(closed_store) end
    end

    test "fences an expired zombie writer even while a new active writer is mid-transaction" do
      {store, pid} = start_ephemeral_store(lease_timeout: 25)
      parent = self()

      {:ok, :seed} =
        Store.mutate(store, fn {db, moment} ->
          {:ok, db2} =
            Xitdb.transact_ops(db, [{:init_col, "k", "hash_map"}, {:put, "k[\"v\"]", "init"}],
              base_moment: moment
            )

          {:ok, {db2, Xitdb.moment_count(db2) - 1}, :seed}
        end)

      writer_a =
        Task.async(fn ->
          Store.transact(
            store,
            fn ->
              send(parent, {:writer_a_acquired, self()})
              receive do: (:writer_a_attempt_zombie -> :ok)

              {db, moment} = Process.get({:xitdb_tx_state, store})

              assert {:error, %Xitdb.Error{reason: :stale_write_epoch}} =
                       Xitdb.transact_ops(db, [{:put, "k[\"zombie_raw\"]", "bad"}],
                         base_moment: moment
                       )

              assert {:error, %LeaseError{store: ^store, reason: :lease_expired}} =
                       Store.mutate(store, fn {cur_db, cur_moment} ->
                         with {:ok, db2} <-
                                Xitdb.transact_ops(
                                  cur_db,
                                  [{:put, "k[\"zombie_mutate\"]", "bad"}],
                                  base_moment: cur_moment
                                ) do
                           {:ok, {db2, Xitdb.moment_count(db2) - 1}, :should_not_commit}
                         end
                       end)

              send(parent, :writer_a_fenced)
              :zombie_done
            end,
            timeout: 1_000
          )
        end)

      assert_receive {:writer_a_acquired, _}, 1_000
      wait_until(fn -> :sys.get_state(pid).queue.active == nil end)

      writer_b =
        Task.async(fn ->
          Store.transact(
            store,
            fn ->
              {:ok, :step1} =
                Store.mutate(store, fn {db, moment} ->
                  {:ok, db2} =
                    Xitdb.transact_ops(db, [{:put, "k[\"step1\"]", "ok1"}], base_moment: moment)

                  {:ok, {db2, Xitdb.moment_count(db2) - 1}, :step1}
                end)

              send(parent, :writer_b_mid_tx)
              receive do: (:writer_b_finish -> :ok)

              {:ok, :step2} =
                Store.mutate(store, fn {db, moment} ->
                  {:ok, db2} =
                    Xitdb.transact_ops(db, [{:put, "k[\"step2\"]", "ok2"}], base_moment: moment)

                  {:ok, {db2, Xitdb.moment_count(db2) - 1}, :step2}
                end)

              :writer_b_ok
            end,
            lease_timeout: 2_000
          )
        end)

      assert_receive :writer_b_mid_tx, 1_000
      send(writer_a.pid, :writer_a_attempt_zombie)
      assert_receive :writer_a_fenced, 1_000

      send(writer_b.pid, :writer_b_finish)
      assert {:ok, :writer_b_ok} = Task.await(writer_b, 2_000)

      assert {:error, %LeaseError{store: ^store, reason: :lease_expired}} =
               Task.await(writer_a, 2_000)

      k = Store.root(store)["k"]
      assert k["v"] == "init"
      assert k["step1"] == "ok1"
      assert k["step2"] == "ok2"
      assert k["zombie_raw"] == nil
      assert k["zombie_mutate"] == nil
    end
  end
end
