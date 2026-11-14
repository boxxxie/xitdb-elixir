if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.TestSandbox do
    @moduledoc """
    Lock-free isolated `:memory` `%Xitdb{}` test sandbox for `async: true` ExUnit suites.

    ## Usage in `test_helper.exs`

        Xitdb.Ash.TestSandbox.init()

    ## Usage in `DataCase`

        setup tags do
          :ok =
            Xitdb.Ash.TestSandbox.checkout(
              [MyApp.MDM.Store, MyApp.AppStore],
              shared: not tags[:async]
            )

          :ok
        end
    """

    alias Xitdb.Ash.{LeaseError, Store}
    alias Xitdb.Ash.Store.{Backend, LeaseQueue, Snapshot}
    alias Xitdb.Ash.TestSandbox.Coordinator

    @checkouts_table :xitdb_ash_sandbox_checkouts
    @templates_table :xitdb_ash_sandbox_templates

    @checkout_schema NimbleOptions.new!(
                       shared: [
                         type: :boolean,
                         default: false,
                         doc: "Shares this checkout globally for `async: false` tests."
                       ],
                       lease_timeout: [
                         type: :timeout,
                         default: 15_000,
                         doc: "Maximum duration a single writer lease inside the test may run."
                       ]
                     )

    @doc """
    Idempotently initializes the public ETS registries for sandbox templates and checkouts,
    assigning `:kernel_sup` as `:heir` so tables survive dynamic `async: true` process exits.
    """
    @spec init() :: :ok
    def init do
      ensure_table(@templates_table, [:named_table, :public, :set, read_concurrency: true])

      ensure_table(@checkouts_table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

      :ok
    end

    @doc """
    Registers a schema-seeded in-memory `%Xitdb{}` (or `%Xitdb.Cursor{}`) template for `store`
    at `test_helper.exs` boot. When omitted, `checkout/2` clones `Snapshot.committed_db(store)`.
    """
    @spec seed_template(module(), term()) :: :ok
    def seed_template(store, template_db) when is_atom(store) do
      init()
      true = :ets.insert(@templates_table, {store, template_db})
      :ok
    end

    @doc """
    Checks out isolated `:memory` `{db, moment}` snapshots for `store_or_stores` keyed to `self()`.

    ## Options
    #{NimbleOptions.docs(@checkout_schema)}
    """
    @spec checkout(module() | [module()], keyword()) :: :ok
    def checkout(store_or_stores, opts \\ []) when is_list(opts) do
      opts = NimbleOptions.validate!(opts, @checkout_schema)
      stores = List.wrap(store_or_stores)
      owner = self()

      init()
      checkin(stores, owner)

      initial_snapshots =
        Map.new(stores, fn store ->
          {store, template_for(store)}
        end)

      {:ok, coord_pid} =
        Coordinator.start(owner, initial_snapshots, opts[:lease_timeout], @checkouts_table)

      Enum.each(initial_snapshots, fn {store, {db, moment}} ->
        :ets.insert(@checkouts_table, {{:db, store, owner}, Xitdb.as_of(db, moment)})
        :ets.insert(@checkouts_table, {{:coord, store, owner}, coord_pid})

        if opts[:shared] do
          :ets.insert(@checkouts_table, {{:shared, store}, owner})
        end
      end)

      register_ex_unit_cleanup(stores, owner)
      :ok
    end

    @doc """
    Releases the sandbox checkouts held by `owner` (defaults to `self()`).
    """
    @spec checkin(module() | [module()], pid()) :: :ok
    def checkin(store_or_stores, owner \\ self()) when is_pid(owner) do
      if :ets.whereis(@checkouts_table) != :undefined do
        stores = List.wrap(store_or_stores)

        coords =
          Enum.reduce(stores, MapSet.new(), fn store, acc ->
            case :ets.lookup(@checkouts_table, {:coord, store, owner}) do
              [{_, pid}] -> MapSet.put(acc, pid)
              [] -> acc
            end
          end)

        Enum.each(coords, &Coordinator.checkin_stores(&1, stores))
        purge_owner_entries(@checkouts_table, stores, owner)
      end

      :ok
    end

    @doc """
    Grants `allowed_pid` access to `owner_pid`'s sandbox handle for unlinked child processes
    that do not propagate `$callers`.
    """
    @spec allow(module() | [module()], pid(), pid()) :: :ok
    def allow(store_or_stores, owner_pid, allowed_pid)
        when is_pid(owner_pid) and is_pid(allowed_pid) do
      init()

      Enum.each(List.wrap(store_or_stores), fn store ->
        if :ets.lookup(@checkouts_table, {:db, store, owner_pid}) == [] do
          raise ArgumentError,
                "#{inspect(owner_pid)} has not checked out Xitdb.Ash.TestSandbox for #{inspect(store)}"
        end

        :ets.insert(@checkouts_table, {{:allow, store, allowed_pid}, owner_pid})
      end)

      :ok
    end

    @doc """
    Returns `true` if `self()` (or an ancestor in `$callers`) has checked out `store`.
    """
    @spec checked_out?(module()) :: boolean()
    def checked_out?(store) when is_atom(store) do
      match?({:ok, _}, checkout_db(store))
    end

    @doc """
    Resolves the caller's isolated `%Xitdb.Cursor{}` snapshot in `O(1)` via ETS without any `GenServer` calls.
    """
    @spec checkout_db(module()) :: {:ok, Xitdb.Cursor.t()} | :none
    def checkout_db(store) when is_atom(store) do
      case resolve_owner(store) do
        {:ok, owner} ->
          case :ets.lookup(@checkouts_table, {:db, store, owner}) do
            [{_, cursor}] -> {:ok, cursor}
            [] -> :none
          end

        :none ->
          :none
      end
    end

    @doc false
    @spec checkout_owner(module()) :: {:ok, pid(), pid()} | :none
    def checkout_owner(store) when is_atom(store) do
      with {:ok, owner} <- resolve_owner(store),
           [{_, coord_pid}] <- :ets.lookup(@checkouts_table, {:coord, store, owner}) do
        {:ok, owner, coord_pid}
      else
        _ -> :none
      end
    end

    @doc false
    @spec transact(module(), (-> term()), timeout()) :: {:ok, term()} | {:error, term()}
    def transact(store, fun, call_timeout) when is_atom(store) and is_function(fun, 0) do
      case checkout_owner(store) do
        {:ok, _owner, coord_pid} ->
          req_ref = make_ref()

          case acquire_sandbox_lease(coord_pid, store, req_ref, call_timeout) do
            {:ok, lease_ref, initial_snapshot} ->
              commit_fn = fn final_snapshot ->
                GenServer.call(
                  coord_pid,
                  {:commit, store, lease_ref, final_snapshot},
                  call_timeout
                )
              end

              abort_fn = fn ->
                try do
                  GenServer.call(coord_pid, {:abort, store, lease_ref}, call_timeout)
                catch
                  :exit, _ ->
                    GenServer.cast(coord_pid, {:abort, store, lease_ref, self()})
                end

                :ok
              end

              Store.run_with_working_db(store, initial_snapshot, fun, commit_fn, abort_fn)

            {:error, _} = err ->
              err
          end

        :none ->
          raise ArgumentError,
                "Xitdb.Ash.TestSandbox for #{inspect(store)} was checked in while transaction was starting"
      end
    end

    @doc false
    @spec purge_owner_entries(:ets.tid() | atom(), [module()], pid()) :: :ok
    def purge_owner_entries(table, stores, owner) do
      Enum.each(stores, fn store ->
        :ets.delete(table, {:db, store, owner})
        :ets.delete(table, {:coord, store, owner})
        :ets.match_delete(table, {{:allow, store, :_}, owner})
        :ets.match_delete(table, {{:shared, store}, owner})
      end)

      :ok
    end

    # -- Internal Resolution & Helpers --

    defp acquire_sandbox_lease(coord_pid, store, req_ref, call_timeout) do
      GenServer.call(coord_pid, {:acquire, store, req_ref, call_timeout}, call_timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(coord_pid, {:cancel_waiter, store, req_ref})
        {:error, %LeaseError{store: store, reason: :lease_timeout}}
    end

    defp resolve_owner(store) do
      if :ets.whereis(@checkouts_table) == :undefined do
        :none
      else
        caller_chain = [self() | Process.get(:"$callers", [])]

        case find_chain_owner(store, caller_chain) do
          {:ok, _} = hit ->
            hit

          :none ->
            case :ets.lookup(@checkouts_table, {:shared, store}) do
              [{_, shared_owner}] -> {:ok, shared_owner}
              [] -> :none
            end
        end
      end
    end

    defp find_chain_owner(_store, []), do: :none

    defp find_chain_owner(store, [pid | rest]) when is_pid(pid) do
      cond do
        :ets.member(@checkouts_table, {:db, store, pid}) ->
          {:ok, pid}

        match?([{_, _}], :ets.lookup(@checkouts_table, {:allow, store, pid})) ->
          [{_, owner}] = :ets.lookup(@checkouts_table, {:allow, store, pid})
          {:ok, owner}

        true ->
          find_chain_owner(store, rest)
      end
    end

    defp find_chain_owner(store, [_non_pid | rest]), do: find_chain_owner(store, rest)

    defp template_for(store) do
      case :ets.lookup(@templates_table, store) do
        [{^store, template}] -> clone_isolated_snapshot(template)
        [] -> store |> Snapshot.committed_db() |> clone_isolated_snapshot()
      end
    end

    defp clone_isolated_snapshot(%Xitdb.Cursor{db_ref: db_ref}) do
      source_db = %Xitdb{db_ref: db_ref, backend: :memory, path: ""}
      clone_isolated_snapshot(source_db)
    end

    defp clone_isolated_snapshot(%Xitdb{} = source_db) do
      if Xitdb.moment_count(source_db) > 0 do
        compacted = Xitdb.compact!(source_db)
        Backend.ensure_seeded!(compacted)
      else
        :memory |> Backend.open_db!() |> Backend.ensure_seeded!()
      end
    end

    defp register_ex_unit_cleanup(stores, owner) do
      if Code.ensure_loaded?(ExUnit.Callbacks) and
           function_exported?(ExUnit.Callbacks, :on_exit, 2) do
        try do
          ExUnit.Callbacks.on_exit({__MODULE__, owner, stores}, fn ->
            checkin(stores, owner)
          end)
        rescue
          ArgumentError -> :ok
        end
      end
    end

    defp ensure_table(name, opts) do
      if :ets.whereis(name) == :undefined do
        # `:heir` is set atomically at creation, so tables outlive the creating process
        # without a helper process or a `give_away/3` race.
        table_opts =
          case Process.whereis(:kernel_sup) do
            pid when is_pid(pid) -> [{:heir, pid, nil} | opts]
            nil -> opts
          end

        try do
          _ = :ets.new(name, table_opts)
          :ok
        rescue
          ArgumentError -> :ok
        end
      else
        :ok
      end
    end
  end

  defmodule Xitdb.Ash.TestSandbox.Coordinator do
    @moduledoc false
    use GenServer

    alias Xitdb.Ash.{Store, TestSandbox}
    alias Xitdb.Ash.Store.{Backend, LeaseQueue}

    defstruct [:owner, :owner_mref, :table, :lease_timeout, :snapshots, :queues]

    @type t :: %__MODULE__{
            owner: pid(),
            owner_mref: reference(),
            table: atom(),
            lease_timeout: timeout(),
            snapshots: %{optional(module()) => Store.working_snapshot()},
            queues: %{optional(module()) => LeaseQueue.t()}
          }

    @spec start(pid(), %{module() => Store.working_snapshot()}, timeout(), atom()) ::
            GenServer.on_start()
    def start(owner, initial_snapshots, lease_timeout, table) do
      GenServer.start(__MODULE__, {owner, initial_snapshots, lease_timeout, table})
    end

    @spec checkin_stores(pid(), [module()]) :: :ok
    def checkin_stores(pid, stores) when is_pid(pid) and is_list(stores) do
      if Process.alive?(pid) do
        GenServer.call(pid, {:checkin_stores, stores}, 5_000)
      else
        :ok
      end
    catch
      :exit, _ -> :ok
    end

    @spec stop(pid()) :: :ok
    def stop(pid) when is_pid(pid) do
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal, 5_000)
      else
        :ok
      end
    catch
      :exit, _ -> :ok
    end

    @impl GenServer
    def init({owner, initial_snapshots, lease_timeout, table}) do
      Process.flag(:trap_exit, true)
      owner_mref = Process.monitor(owner)

      queues =
        Map.new(initial_snapshots, fn {store, _snapshot} -> {store, LeaseQueue.new()} end)

      state = %__MODULE__{
        owner: owner,
        owner_mref: owner_mref,
        table: table,
        lease_timeout: lease_timeout,
        snapshots: initial_snapshots,
        queues: queues
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_call({:checkin_stores, stores}, _from, %__MODULE__{} = state) do
      TestSandbox.purge_owner_entries(state.table, stores, state.owner)

      {closing, remaining_snapshots} = Map.split(state.snapshots, stores)

      Enum.each(closing, fn {_store, {db, _moment}} ->
        Backend.close_db(db)
      end)

      next_queues = Map.drop(state.queues, stores)
      next_state = %__MODULE__{state | snapshots: remaining_snapshots, queues: next_queues}

      if map_size(remaining_snapshots) == 0 do
        {:stop, :normal, :ok, next_state}
      else
        {:reply, :ok, next_state}
      end
    end

    def handle_call({:acquire, store, req_ref, call_timeout}, from, %__MODULE__{} = state) do
      queue = Map.fetch!(state.queues, store)
      snapshot = Map.fetch!(state.snapshots, store)
      lease_timeout = Store.min_timeout(state.lease_timeout, call_timeout)

      case LeaseQueue.acquire(queue, store, req_ref, from, lease_timeout, call_timeout, snapshot) do
        {:granted, lease_ref, next_queue} ->
          {:reply, {:ok, lease_ref, snapshot}, put_queue(state, store, next_queue)}

        {:queued, next_queue} ->
          {:noreply, put_queue(state, store, next_queue)}
      end
    end

    def handle_call(
          {:commit, store, lease_ref, {new_db, new_moment}},
          {caller_pid, _},
          %__MODULE__{} = state
        ) do
      queue = Map.fetch!(state.queues, store)

      case LeaseQueue.verify_holder(queue, lease_ref, caller_pid) do
        :ok ->
          {committed_db, committed_moment} = Backend.reconcile_tip(new_db, new_moment)
          next_snapshot = {committed_db, committed_moment}

          :ets.insert(
            state.table,
            {{:db, store, state.owner}, Xitdb.as_of(committed_db, committed_moment)}
          )

          next_queue = LeaseQueue.release_and_grant_next(queue, store, next_snapshot)

          next_state = %__MODULE__{
            state
            | snapshots: Map.put(state.snapshots, store, next_snapshot),
              queues: Map.put(state.queues, store, next_queue)
          }

          {:reply, :ok, next_state}

        {:error, :lease_expired} = err ->
          next_state =
            if is_nil(queue.active) do
              {db, moment} = Map.fetch!(state.snapshots, store)
              restored_snap = Backend.reconcile_tip(db, moment)
              %__MODULE__{state | snapshots: Map.put(state.snapshots, store, restored_snap)}
            else
              state
            end

          {:reply, err, next_state}
      end
    end

    def handle_call({:abort, store, lease_ref}, {caller_pid, _}, %__MODULE__{} = state) do
      {:reply, :ok, release_aborted_sandbox_lease(state, store, lease_ref, caller_pid)}
    end

    @impl GenServer
    def handle_cast({:abort, store, lease_ref, caller_pid}, %__MODULE__{} = state) do
      {:noreply, release_aborted_sandbox_lease(state, store, lease_ref, caller_pid)}
    end

    def handle_cast({:cancel_waiter, store, req_ref}, %__MODULE__{} = state) do
      queue = Map.fetch!(state.queues, store)
      snapshot = Map.fetch!(state.snapshots, store)
      next_queue = LeaseQueue.cancel_waiter(queue, req_ref, store, snapshot)
      {:noreply, put_queue(state, store, next_queue)}
    end

    @impl GenServer
    def handle_info({:DOWN, mref, :process, _pid, _reason}, %__MODULE__{owner_mref: mref} = state) do
      TestSandbox.purge_owner_entries(state.table, Map.keys(state.snapshots), state.owner)
      {:stop, :normal, state}
    end

    def handle_info({:DOWN, mref, :process, _pid, _reason}, %__MODULE__{} = state) do
      {next_snapshots, next_queues} =
        Enum.reduce(state.queues, {state.snapshots, state.queues}, fn {store, queue},
                                                                      {snaps_acc, queues_acc} ->
          if match?(%{monitor_ref: ^mref}, queue.active) do
            {db, moment} = Map.fetch!(snaps_acc, store)
            {restored_db, restored_moment} = Backend.reconcile_tip(db, moment)
            restored_snap = {restored_db, restored_moment}
            {:matched, updated} = LeaseQueue.handle_down(queue, mref, store, restored_snap)
            {Map.put(snaps_acc, store, restored_snap), Map.put(queues_acc, store, updated)}
          else
            {snaps_acc, queues_acc}
          end
        end)

      {:noreply, %__MODULE__{state | snapshots: next_snapshots, queues: next_queues}}
    end

    def handle_info({:xitdb_lease_expired, store, lease_ref}, %__MODULE__{} = state) do
      case Map.fetch(state.queues, store) do
        {:ok, queue} ->
          if match?(%{ref: ^lease_ref}, queue.active) do
            {db, moment} = Map.fetch!(state.snapshots, store)
            {restored_db, restored_moment} = Backend.reconcile_tip(db, moment)
            restored_snap = {restored_db, restored_moment}

            {:matched, next_queue} =
              LeaseQueue.handle_expired(queue, lease_ref, store, restored_snap)

            {:noreply,
             %__MODULE__{
               state
               | snapshots: Map.put(state.snapshots, store, restored_snap),
                 queues: Map.put(state.queues, store, next_queue)
             }}
          else
            {:noreply, state}
          end

        :error ->
          {:noreply, state}
      end
    end

    def handle_info(_other, %__MODULE__{} = state), do: {:noreply, state}

    @impl GenServer
    def terminate(_reason, %__MODULE__{} = state) do
      TestSandbox.purge_owner_entries(state.table, Map.keys(state.snapshots), state.owner)

      Enum.each(state.snapshots, fn {_store, {db, _moment}} ->
        Backend.close_db(db)
      end)

      :ok
    end

    defp release_aborted_sandbox_lease(%__MODULE__{} = state, store, lease_ref, caller_pid) do
      queue = Map.fetch!(state.queues, store)

      case LeaseQueue.verify_holder(queue, lease_ref, caller_pid) do
        :ok ->
          {db, moment} = Map.fetch!(state.snapshots, store)
          {restored_db, restored_moment} = Backend.reconcile_tip(db, moment)
          restored_snap = {restored_db, restored_moment}
          next_queue = LeaseQueue.release_and_grant_next(queue, store, restored_snap)

          %__MODULE__{
            state
            | snapshots: Map.put(state.snapshots, store, restored_snap),
              queues: Map.put(state.queues, store, next_queue)
          }

        {:error, :lease_expired} ->
          state
      end
    end

    defp put_queue(%__MODULE__{} = state, store, queue) do
      %__MODULE__{state | queues: Map.put(state.queues, store, queue)}
    end
  end
end
