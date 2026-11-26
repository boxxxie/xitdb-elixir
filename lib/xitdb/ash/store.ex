if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Store do
    @moduledoc """
    Caller-supervised single-writer store, lock-free snapshot coordinator, and savepoint
    transaction manager for `Xitdb.Ash.DataLayer`.

    Reads resolve in ~10ns via `:persistent_term` and `:atomics` snapshot state without
    touching this `GenServer`. Transactions acquire a monitored writer lease and execute
    inside the caller process so `self()`, `$callers`, `Swoosh` sandboxes, and multi-store
    transactions behave naturally.

    ## Supervision

        children = [
          {Xitdb.Ash.Store,
           name: MyApp.MDM.Store,
           path: "/var/data/connect_mdm.xit",
           domains: [MyApp.Accounts, MyApp.Events]}
        ]

    Or define a dedicated store module:

        defmodule MyApp.MDM.Store do
          use Xitdb.Ash.Store
        end

    ## Telemetry

    * `[:xitdb, :ash, :transaction, :start | :stop | :exception]` — emitted by `transact/3`,
      carrying `%{store: module(), mode: :leased | :savepoint | :sandbox, status: :ok | :rollback | :error}`.
    """

    use GenServer

    alias Xitdb.Ash.{Info, LeaseError, TestSandbox}
    alias Xitdb.Ash.Store.{Backend, LeaseQueue, Snapshot}

    @type working_snapshot :: {Xitdb.t(), integer()}
    @type reverse_fk :: %{
            :source_resource => module(),
            :source_collection => atom() | nil,
            :source_attribute => atom(),
            :destination_attribute => atom(),
            :on_delete => :delete | :nilify | :restrict,
            optional(:nested?) => boolean()
          }

    @options_schema NimbleOptions.new!(
                      name: [
                        type: :atom,
                        required: true,
                        doc: "Atom store identifier referenced in `xitdb do store ... end`."
                      ],
                      path: [
                        type: {:or, [:string, {:in, [:memory]}]},
                        default: :memory,
                        doc: "Filesystem `.xit` path or `:memory` for ephemeral stores."
                      ],
                      db: [
                        type: :any,
                        default: nil,
                        doc: "Pre-opened `%Xitdb{}` handle (overrides `:path` when provided)."
                      ],
                      domains: [
                        type: {:list, :atom},
                        default: [],
                        doc:
                          "Ash domains backed by this store (used to compile reverse-FK rules)."
                      ],
                      resources: [
                        type: {:list, :atom},
                        default: [],
                        doc: "Additional Ash resources backed by this store."
                      ],
                      lease_timeout: [
                        type: :timeout,
                        default: 15_000,
                        doc: "Maximum duration a single writer lease may be held before expiring."
                      ]
                    )

    defmodule State do
      @moduledoc false
      defstruct [:name, :path, :db, :moment, :lease_timeout, :queue, next_write_epoch: nil]

      @type t :: %__MODULE__{
              name: module(),
              path: String.t() | :memory,
              db: Xitdb.t(),
              moment: integer(),
              lease_timeout: timeout(),
              queue: LeaseQueue.t(),
              next_write_epoch: {reference(), pos_integer()} | nil
            }
    end

    defmacro __using__(_opts) do
      quote do
        @spec child_spec(keyword()) :: Supervisor.child_spec()
        def child_spec(opts) do
          opts
          |> Keyword.put_new(:name, __MODULE__)
          |> Xitdb.Ash.Store.child_spec()
        end

        @spec start_link(keyword()) :: GenServer.on_start()
        def start_link(opts \\ []) do
          opts
          |> Keyword.put_new(:name, __MODULE__)
          |> Xitdb.Ash.Store.start_link()
        end

        @spec current_db() :: term()
        def current_db, do: Xitdb.Ash.Store.current_db(__MODULE__)

        @spec root() :: Xitdb.Cursor.t()
        def root, do: Xitdb.Ash.Store.root(__MODULE__)

        @spec as_of(integer()) :: Xitdb.Cursor.t()
        def as_of(moment), do: Xitdb.Ash.Store.as_of(__MODULE__, moment)

        @spec with_as_of(integer() | Xitdb.Cursor.t() | Xitdb.t(), (-> result)) :: result
              when result: var
        def with_as_of(moment_or_db, fun),
          do: Xitdb.Ash.Store.with_as_of(__MODULE__, moment_or_db, fun)

        @spec in_transaction?() :: boolean()
        def in_transaction?, do: Xitdb.Ash.Store.in_transaction?(__MODULE__)

        @spec transact((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
        def transact(fun, opts \\ []), do: Xitdb.Ash.Store.transact(__MODULE__, fun, opts)

        @spec mutate(
                (Xitdb.Ash.Store.working_snapshot() ->
                   {:ok, Xitdb.Ash.Store.working_snapshot(), term()} | {:error, term()}),
                keyword()
              ) :: {:ok, term()} | {:error, term()}
        def mutate(fun, opts \\ []), do: Xitdb.Ash.Store.mutate(__MODULE__, fun, opts)

        @spec rollback(term()) :: no_return()
        def rollback(reason), do: Xitdb.Ash.Store.rollback(__MODULE__, reason)

        @spec swap_compacted_base(Xitdb.t(), integer() | nil, keyword()) ::
                :ok | {:error, term()}
        def swap_compacted_base(compacted_db, moment \\ nil, opts \\ []),
          do: Xitdb.Ash.Store.swap_compacted_base(__MODULE__, compacted_db, moment, opts)
      end
    end

    @doc """
    Builds a supervisor child specification keyed by `opts[:name]`.

    ## Options
    #{NimbleOptions.docs(@options_schema)}
    """
    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) when is_list(opts) do
      %{
        id: opts[:name] || __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    @doc """
    Starts the `Xitdb.Ash.Store` process and publishes its initial lock-free `Snapshot`.
    """
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) when is_list(opts) do
      opts = NimbleOptions.validate!(opts, @options_schema)
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end

    @doc """
    Returns the active snapshot handle for `store` (transaction `%Xitdb.Cursor{}` ->
    `TestSandbox` `%Xitdb.Cursor{}` -> latest committed `Snapshot` moment) with zero `GenServer.call`s.
    """
    @spec current_db(module()) :: term()
    def current_db(store) when is_atom(store), do: Snapshot.current_db(store)

    @doc """
    Returns the active root `%Xitdb.Cursor{}` for `store` pinned to the caller's visible moment.
    """
    @spec root(module()) :: Xitdb.Cursor.t()
    def root(store) when is_atom(store) do
      case current_db(store) do
        %Xitdb.Cursor{} = cursor -> cursor
        %Xitdb{} = db -> Xitdb.db(db)
      end
    end

    @doc """
    Returns a root `%Xitdb.Cursor{}` pinned to `moment` on `store`.
    """
    @spec as_of(module(), integer()) :: Xitdb.Cursor.t()
    def as_of(store, moment) when is_atom(store) and is_integer(moment) do
      Snapshot.as_of(store, moment)
    end

    @doc """
    Executes `fun` with all reads (`Ash.read`, `Ash.get`, `Ash.load`, `Ash.aggregate`,
    and `Xitdb.Ash.Search.query`) on `store` pinned to `moment_or_db` (an integer moment,
    `%Xitdb.Cursor{}`, or `%Xitdb{}`).
    """
    @spec with_as_of(module(), integer() | Xitdb.Cursor.t() | Xitdb.t(), (-> result)) :: result
          when result: var
    def with_as_of(store, moment_or_db, fun) when is_atom(store) and is_function(fun, 0) do
      pinned_db =
        case moment_or_db do
          moment when is_integer(moment) -> Snapshot.as_of(store, moment)
          %Xitdb.Cursor{} = cursor -> cursor
          %Xitdb{} = db -> db
        end

      key = {:xitdb_as_of_db, store}
      prev = Process.get(key)
      Process.put(key, pinned_db)

      try do
        fun.()
      after
        if prev == nil, do: Process.delete(key), else: Process.put(key, prev)
      end
    end

    @doc """
    Returns incoming same-store foreign-key rules compiled at boot for `resource`.
    """
    @spec reverse_fks(module(), module()) :: [reverse_fk()]
    def reverse_fks(store, resource) when is_atom(store) and is_atom(resource) do
      Snapshot.reverse_fks(store, resource)
    end

    @doc """
    Returns `true` if the calling process currently holds an active working snapshot for `store`.
    """
    @spec in_transaction?(module()) :: boolean()
    def in_transaction?(store) when is_atom(store) do
      Process.get(tx_state_key(store)) != nil
    end

    @doc """
    Aborts the innermost savepoint or transaction for `store` in `O(1)`.
    """
    @spec rollback(module(), term()) :: no_return()
    def rollback(store, reason) when is_atom(store) do
      throw({:xitdb_ash_rollback, store, reason})
    end

    @doc """
    Applies a pure mutation `fun :: ({db, moment} -> {:ok, {new_db, new_moment}, result} | {:error, reason})`
    against the active transaction snapshot, or wraps it in `transact/3` automatically.
    """
    @spec mutate(
            module(),
            (working_snapshot() -> {:ok, working_snapshot(), term()} | {:error, term()}),
            keyword()
          ) :: {:ok, term()} | {:error, term()}
    def mutate(store, fun, opts \\ []) when is_atom(store) and is_function(fun, 1) do
      if in_transaction?(store) do
        {old_db, old_moment} = snapshot = Process.get(tx_state_key(store))
        prev_tail = Backend.latest_moment(old_db)

        case fun.(snapshot) do
          {:ok, {new_db, new_moment} = next_snapshot, result} ->
            if Backend.invalid_mutate_moment?(old_db, old_moment, prev_tail, new_db, new_moment) do
              if Backend.latest_moment(old_db) > prev_tail do
                restore_savepoint_snapshot(store, snapshot)
              end

              {:error, :invalid_moment}
            else
              put_working_snapshot(store, next_snapshot)
              {:ok, result}
            end

          {:error, reason} ->
            if Backend.latest_moment(old_db) > prev_tail do
              restore_savepoint_snapshot(store, snapshot)
            end

            {:error, normalize_lease_error(store, reason)}
        end
      else
        transact(
          store,
          fn ->
            {old_db, old_moment} = snapshot = Process.get(tx_state_key(store))
            prev_tail = Backend.latest_moment(old_db)

            case fun.(snapshot) do
              {:ok, {new_db, new_moment} = next_snapshot, result} ->
                if Backend.invalid_mutate_moment?(
                     old_db,
                     old_moment,
                     prev_tail,
                     new_db,
                     new_moment
                   ) do
                  rollback(store, :invalid_moment)
                else
                  put_working_snapshot(store, next_snapshot)
                  result
                end

              {:error, reason} ->
                rollback(store, normalize_lease_error(store, reason))
            end
          end,
          opts
        )
      end
    end

    @doc """
    Executes `fun` inside a savepoint (when nested), a `TestSandbox` checkout lease,
    or a monitored caller-process writer lease on `store`.
    """
    @spec transact(module(), (-> term()), keyword()) :: {:ok, term()} | {:error, term()}
    def transact(store, fun, opts \\ [])
        when is_atom(store) and is_function(fun, 0) and is_list(opts) do
      explicit_lease_timeout = normalize_optional_timeout(opts[:lease_timeout])

      call_timeout =
        case opts[:timeout] do
          nil -> max_timeout(normalize_timeout(nil), explicit_lease_timeout)
          t -> normalize_timeout(t)
        end

      {mode, exec} =
        cond do
          in_transaction?(store) ->
            {:savepoint, fn -> run_savepoint(store, fun) end}

          match?({:ok, _, _}, TestSandbox.checkout_owner(store)) ->
            {:sandbox,
             fn -> TestSandbox.transact(store, fun, call_timeout, explicit_lease_timeout) end}

          true ->
            {:leased,
             fn -> run_leased_transaction(store, fun, call_timeout, explicit_lease_timeout) end}
        end

      meta = %{store: store, mode: mode}

      :telemetry.span([:xitdb, :ash, :transaction], meta, fn ->
        as_of_key = {:xitdb_as_of_db, store}
        prev_as_of = Process.delete(as_of_key)

        result =
          try do
            exec.()
          after
            if prev_as_of != nil, do: Process.put(as_of_key, prev_as_of)
          end

        status =
          case result do
            {:ok, _} -> :ok
            {:error, %LeaseError{}} -> :error
            {:error, _} -> :rollback
          end

        {result, Map.put(meta, :status, status)}
      end)
    end

    @doc """
    Atomically replaces the active `%Xitdb{}` handle on `store` outside an open transaction.

    Note: Supervisor restarts reopen the original configured `:path` unless the underlying file
    is atomically replaced on disk.

    Options:
    - `:close_previous?` — when `true`, closes the previous `%Xitdb{}` handle after a successful
      swap (default `false`).
    - `:expected_moment` — if provided, verifies that the store's current committed moment matches
      before swapping, returning `{:error, :stale_compaction_base}` if another commit landed.
    - `:expected_db_ref` — if provided, verifies that the store's current `db.db_ref` matches
      before swapping, returning `{:error, :stale_compaction_base}` on mismatch.
    """
    @spec swap_compacted_base(module(), Xitdb.t(), integer() | nil, keyword()) ::
            :ok | {:error, term()}
    def swap_compacted_base(store, %Xitdb{} = compacted_db, moment \\ nil, opts \\ [])
        when is_atom(store) and is_list(opts) do
      cond do
        in_transaction?(store) ->
          {:error, :swap_inside_transaction}

        compacted_db.read_only ->
          {:error, :read_only}

        true ->
          with {:ok, %{moment_count: count}} <- Xitdb.info(compacted_db),
               {:ok, target_moment} <- validate_swap_moment(moment, count) do
            close_previous? = Keyword.get(opts, :close_previous?, false)
            expected_moment = Keyword.get(opts, :expected_moment)
            expected_db_ref = Keyword.get(opts, :expected_db_ref)

            case mutate(
                   store,
                   fn {old_db, old_moment} ->
                     cond do
                       expected_moment != nil and old_moment != expected_moment ->
                         {:error, :stale_compaction_base}

                       expected_db_ref != nil and old_db.db_ref != expected_db_ref ->
                         {:error, :stale_compaction_base}

                       true ->
                         {:ok, {compacted_db, target_moment}, old_db}
                     end
                   end,
                   Keyword.drop(opts, [:close_previous?, :expected_moment, :expected_db_ref])
                 ) do
              {:ok, old_db} ->
                if close_previous? and old_db.db_ref != compacted_db.db_ref do
                  _ = Backend.close_db(old_db)
                end

                :ok

              {:error, _} = err ->
                err
            end
          end
      end
    end

    defp validate_swap_moment(nil, count), do: {:ok, count - 1}
    defp validate_swap_moment(-1, count), do: {:ok, count - 1}

    defp validate_swap_moment(moment, count)
         when is_integer(moment) and moment >= 0 and moment < count do
      {:ok, moment}
    end

    defp validate_swap_moment(_moment, _count), do: {:error, :invalid_moment}

    # -- GenServer Callbacks --

    @impl GenServer
    def init(opts) do
      Process.flag(:trap_exit, true)
      name = Keyword.fetch!(opts, :name)
      path = Keyword.fetch!(opts, :path)
      raw_db = opts[:db] || Backend.open_db!(path)
      {db, initial_moment} = Backend.ensure_seeded!(raw_db)
      reverse_fks = compile_reverse_fks(name, opts[:domains], opts[:resources])

      :ok = Snapshot.put_base(name, db, moment: initial_moment, reverse_fks: reverse_fks)

      state = %State{
        name: name,
        path: path,
        db: db,
        moment: initial_moment,
        lease_timeout: Keyword.fetch!(opts, :lease_timeout),
        queue: LeaseQueue.new()
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_call({:acquire_lease, req_ref, call_timeout}, from, %State{} = state) do
      handle_call({:acquire_lease, req_ref, call_timeout, nil}, from, state)
    end

    def handle_call(
          {:acquire_lease, req_ref, call_timeout, explicit_lease_timeout},
          from,
          %State{} = state
        ) do
      lease_timeout =
        if explicit_lease_timeout == nil do
          state.lease_timeout
        else
          normalize_timeout(explicit_lease_timeout)
        end

      snapshot = {state.db, state.moment}

      if state.queue.active == nil do
        db_ref = state.db.db_ref

        fenced_result =
          case state.next_write_epoch do
            {^db_ref, epoch} -> {:ok, {%{state.db | write_epoch: epoch}, state.moment}}
            _ -> Backend.fence_snapshot(snapshot)
          end

        case fenced_result do
          {:ok, fenced_snapshot} ->
            {:granted, lease_ref, next_queue} =
              LeaseQueue.acquire(
                state.queue,
                state.name,
                req_ref,
                from,
                lease_timeout,
                call_timeout,
                snapshot
              )

            {:reply, {:ok, lease_ref, fenced_snapshot},
             %{state | queue: next_queue, next_write_epoch: nil}}

          {:error, _} = err ->
            {:reply, err, %{state | next_write_epoch: nil}}
        end
      else
        {:queued, next_queue} =
          LeaseQueue.acquire(
            state.queue,
            state.name,
            req_ref,
            from,
            lease_timeout,
            call_timeout,
            snapshot
          )

        {:noreply, %{state | queue: next_queue}}
      end
    end

    def handle_call(
          {:commit_lease, lease_ref, {%Xitdb{} = new_db, new_moment}},
          {caller_pid, _},
          %State{} = state
        ) do
      case LeaseQueue.verify_holder(state.queue, lease_ref, caller_pid) do
        :ok ->
          if Backend.invalid_commit_moment?(state.db, state.moment, new_db, new_moment) do
            {:reply, {:error, :invalid_moment},
             release_aborted_lease(state, lease_ref, caller_pid)}
          else
            bump_result = Backend.bump_write_epoch(state.db)
            base_db = %{new_db | write_epoch: nil}

            {committed_db, committed_moment} =
              Backend.reconcile_tip(base_db, new_moment, :reconcile_commit)

            {next_db, bump_for_next} =
              if committed_db.db_ref != state.db.db_ref do
                if is_integer(state.moment) do
                  _ = Backend.reconcile_tip(state.db, state.moment, :aborted)
                end

                :ok = Snapshot.swap_compacted_base(state.name, committed_db, committed_moment)
                {committed_db, Backend.bump_write_epoch(committed_db)}
              else
                :ok = Backend.publish_commit(state.name, state.moment, committed_moment)
                {state.db, bump_result}
              end

            next_snapshot = {committed_db, committed_moment}

            next_queue =
              LeaseQueue.release_and_grant_next(
                state.queue,
                state.name,
                fn -> Backend.fence_snapshot_with_epoch(next_snapshot, next_db, bump_for_next) end
              )

            next_epoch = next_cached_epoch(next_queue, committed_db, next_db, bump_for_next)

            {:reply, :ok,
             %{
               state
               | db: committed_db,
                 moment: committed_moment,
                 queue: next_queue,
                 next_write_epoch: next_epoch
             }}
          end

        {:error, :lease_expired} = err ->
          next_state =
            if is_nil(state.queue.active) do
              bump_result = Backend.bump_write_epoch(state.db)

              {restored_db, restored_moment} =
                Backend.reconcile_tip(state.db, state.moment, :lease_expired)

              :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
              next_epoch = next_cached_epoch(state.queue, restored_db, state.db, bump_result)

              %{
                state
                | db: restored_db,
                  moment: restored_moment,
                  next_write_epoch: next_epoch
              }
            else
              state
            end

          {:reply, err, next_state}
      end
    end

    def handle_call({:abort_lease, lease_ref}, {caller_pid, _}, %State{} = state) do
      {:reply, :ok, release_aborted_lease(state, lease_ref, caller_pid)}
    end

    @impl GenServer
    def handle_cast({:abort_lease, lease_ref, caller_pid}, %State{} = state) do
      {:noreply, release_aborted_lease(state, lease_ref, caller_pid)}
    end

    def handle_cast({:cancel_waiter, req_ref}, %State{} = state) do
      if match?(%{req_ref: ^req_ref}, state.queue.active) do
        bump_result = Backend.bump_write_epoch(state.db)

        {restored_db, restored_moment} =
          Backend.reconcile_tip(state.db, state.moment, :lease_timeout)

        :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
        snapshot = {restored_db, restored_moment}

        next_queue =
          LeaseQueue.cancel_waiter(
            state.queue,
            req_ref,
            state.name,
            fn -> Backend.fence_snapshot_with_epoch(snapshot, state.db, bump_result) end
          )

        next_epoch = next_cached_epoch(next_queue, restored_db, state.db, bump_result)

        {:noreply,
         %{
           state
           | db: restored_db,
             moment: restored_moment,
             queue: next_queue,
             next_write_epoch: next_epoch
         }}
      else
        snapshot = {state.db, state.moment}

        next_queue =
          LeaseQueue.cancel_waiter(
            state.queue,
            req_ref,
            state.name,
            fn -> Backend.fence_snapshot(snapshot) end
          )

        {:noreply, %{state | queue: next_queue}}
      end
    end

    @impl GenServer
    def handle_info({:DOWN, mref, :process, _pid, _reason}, %State{} = state) do
      if match?(%{monitor_ref: ^mref}, state.queue.active) do
        bump_result = Backend.bump_write_epoch(state.db)

        {restored_db, restored_moment} =
          Backend.reconcile_tip(state.db, state.moment, :process_down)

        :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
        snapshot = {restored_db, restored_moment}

        {:matched, next_queue} =
          LeaseQueue.handle_down(
            state.queue,
            mref,
            state.name,
            fn -> Backend.fence_snapshot_with_epoch(snapshot, state.db, bump_result) end
          )

        next_epoch = next_cached_epoch(next_queue, restored_db, state.db, bump_result)

        {:noreply,
         %{
           state
           | db: restored_db,
             moment: restored_moment,
             queue: next_queue,
             next_write_epoch: next_epoch
         }}
      else
        {:noreply, state}
      end
    end

    def handle_info({:xitdb_lease_expired, name, lease_ref}, %State{name: name} = state) do
      if match?(%{ref: ^lease_ref}, state.queue.active) do
        bump_result = Backend.bump_write_epoch(state.db)

        {restored_db, restored_moment} =
          Backend.reconcile_tip(state.db, state.moment, :lease_expired)

        :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
        snapshot = {restored_db, restored_moment}

        {:matched, next_queue} =
          LeaseQueue.handle_expired(
            state.queue,
            lease_ref,
            state.name,
            fn -> Backend.fence_snapshot_with_epoch(snapshot, state.db, bump_result) end
          )

        next_epoch = next_cached_epoch(next_queue, restored_db, state.db, bump_result)

        {:noreply,
         %{
           state
           | db: restored_db,
             moment: restored_moment,
             queue: next_queue,
             next_write_epoch: next_epoch
         }}
      else
        {:noreply, state}
      end
    end

    def handle_info(_other, %State{} = state), do: {:noreply, state}

    @impl GenServer
    def terminate(_reason, %State{} = state) do
      _ = LeaseQueue.cancel_all(state.queue, {:error, :store_stopped})
      Backend.bump_write_epoch(state.db)

      try do
        case state.db do
          %Xitdb{} = db when is_integer(state.moment) ->
            _ = Backend.reconcile_tip(db, state.moment, :terminate)
            :ok

          _ ->
            :ok
        end
      after
        Snapshot.erase(state.name)
        Backend.close_db(state.db)
      end

      :ok
    end

    defp release_aborted_lease(%State{} = state, lease_ref, caller_pid) do
      case LeaseQueue.verify_holder(state.queue, lease_ref, caller_pid) do
        :ok ->
          bump_result = Backend.bump_write_epoch(state.db)

          {restored_db, restored_moment} =
            Backend.reconcile_tip(state.db, state.moment, :aborted)

          :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
          snapshot = {restored_db, restored_moment}

          next_queue =
            LeaseQueue.release_and_grant_next(
              state.queue,
              state.name,
              fn -> Backend.fence_snapshot_with_epoch(snapshot, state.db, bump_result) end
            )

          next_epoch = next_cached_epoch(next_queue, restored_db, state.db, bump_result)

          %{
            state
            | db: restored_db,
              moment: restored_moment,
              queue: next_queue,
              next_write_epoch: next_epoch
          }

        {:error, :lease_expired} ->
          state
      end
    end

    defp next_cached_epoch(
           %LeaseQueue{active: nil},
           %Xitdb{db_ref: db_ref},
           %Xitdb{db_ref: db_ref},
           {:ok, epoch}
         ),
         do: {db_ref, epoch}

    defp next_cached_epoch(_queue, _db, _prev_db, _bump_result), do: nil

    # -- Internal Savepoint & Lease Execution --

    @doc false
    @spec run_with_working_db(
            module(),
            working_snapshot(),
            (-> term()),
            (working_snapshot() -> :ok | {:error, :lease_expired}),
            (-> :ok)
          ) :: {:ok, term()} | {:error, term()}
    def run_with_working_db(store, initial_snapshot, fun, commit_fn, abort_fn) do
      put_working_snapshot(store, initial_snapshot)

      result =
        try do
          {:ok, fun.()}
        catch
          :throw, {:xitdb_ash_rollback, ^store, reason} ->
            delete_working_snapshot(store)
            abort_fn.()
            {:error, normalize_lease_error(store, reason)}

          kind, payload ->
            stacktrace = __STACKTRACE__
            delete_working_snapshot(store)
            abort_fn.()
            :erlang.raise(kind, payload, stacktrace)
        end

      case result do
        {:ok, value} ->
          final_snapshot = Process.get(tx_state_key(store))
          delete_working_snapshot(store)

          case commit_fn.(final_snapshot) do
            :ok ->
              {:ok, value}

            {:error, :lease_expired} ->
              {:error, %LeaseError{store: store, reason: :lease_expired}}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, _reason} = err ->
          err
      end
    end

    defp run_savepoint(store, fun) do
      prev_snapshot = Process.get(tx_state_key(store))

      try do
        {:ok, fun.()}
      catch
        :throw, {:xitdb_ash_rollback, ^store, reason} ->
          restore_savepoint_snapshot(store, prev_snapshot)
          {:error, normalize_lease_error(store, reason)}

        kind, payload ->
          stacktrace = __STACKTRACE__
          restore_savepoint_snapshot(store, prev_snapshot)
          :erlang.raise(kind, payload, stacktrace)
      end
    end

    defp restore_savepoint_snapshot(store, {%Xitdb{} = prev_db, prev_moment})
         when is_integer(prev_moment) do
      restored_snapshot = Backend.reconcile_tip(prev_db, prev_moment, :savepoint_rollback)
      put_working_snapshot(store, restored_snapshot)
    end

    defp restore_savepoint_snapshot(store, prev_snapshot) do
      put_working_snapshot(store, prev_snapshot)
    end

    defp normalize_lease_error(store, %Xitdb.Error{reason: :stale_write_epoch}),
      do: %LeaseError{store: store, reason: :lease_expired}

    defp normalize_lease_error(_store, reason), do: reason

    defp run_leased_transaction(store, fun, call_timeout, explicit_lease_timeout) do
      req_ref = make_ref()

      case acquire_store_lease(store, req_ref, call_timeout, explicit_lease_timeout) do
        {:ok, lease_ref, initial_snapshot} ->
          commit_fn = fn final_snapshot ->
            GenServer.call(store, {:commit_lease, lease_ref, final_snapshot}, :infinity)
          end

          abort_fn = fn ->
            try do
              GenServer.call(store, {:abort_lease, lease_ref}, call_timeout)
            catch
              :exit, _ ->
                GenServer.cast(store, {:abort_lease, lease_ref, self()})
            end

            :ok
          end

          run_with_working_db(store, initial_snapshot, fun, commit_fn, abort_fn)

        {:error, _} = err ->
          err
      end
    end

    defp acquire_store_lease(store, req_ref, call_timeout, explicit_lease_timeout) do
      GenServer.call(
        store,
        {:acquire_lease, req_ref, call_timeout, explicit_lease_timeout},
        call_timeout
      )
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(store, {:cancel_waiter, req_ref})
        {:error, %LeaseError{store: store, reason: :lease_timeout}}
    end

    defp put_working_snapshot(store, {%Xitdb{} = db, moment} = snapshot) do
      Process.put(tx_state_key(store), snapshot)

      cursor =
        if is_integer(moment) and moment >= 0 do
          Xitdb.as_of(db, moment)
        else
          Xitdb.Cursor.empty_root(db.db_ref)
        end

      Process.put(tx_db_key(store), cursor)
      :ok
    end

    defp delete_working_snapshot(store) do
      Process.delete(tx_state_key(store))
      Process.delete(tx_db_key(store))
      :ok
    end

    # -- Boot-Time Reverse Foreign-Key Graph Compiler --

    @doc false
    @spec compile_reverse_fks(module(), [module()] | nil, [module()] | nil) ::
            Snapshot.reverse_fk_map()
    def compile_reverse_fks(store_mod, domains, explicit_resources) do
      domain_resources = Enum.flat_map(domains || [], &Ash.Domain.Info.resources/1)

      local_resources =
        (domain_resources ++ (explicit_resources || []))
        |> Enum.uniq()
        |> Enum.filter(fn resource ->
          Ash.Resource.Info.data_layer(resource) == Xitdb.Ash.DataLayer and
            resource_store_matches?(resource, store_mod)
        end)

      local_set = MapSet.new(local_resources)
      by_collection = Enum.group_by(local_resources, &resolve_collection/1)

      explicit_pairs =
        for child <- local_resources,
            refs = Map.new(Info.references(child), &{&1.relationship, &1.on_delete}),
            %Ash.Resource.Relationships.BelongsTo{} = rel <-
              Ash.Resource.Info.relationships(child),
            MapSet.member?(local_set, rel.destination),
            on_delete = Map.get(refs, rel.name, :nothing),
            on_delete in [:restrict, :nilify, :delete] do
          rule = %{
            source_resource: child,
            source_collection: resolve_collection(child),
            source_attribute: rel.source_attribute,
            destination_attribute: rel.destination_attribute,
            on_delete: on_delete,
            nested?: resource_nested?(child)
          }

          {rel.destination, rule}
        end

      nested_pairs =
        Enum.flat_map(local_resources, fn child ->
          build_nested_fk_rules(child, explicit_pairs, by_collection, local_set)
        end)

      Enum.reduce(explicit_pairs ++ nested_pairs, %{}, fn {dest, rule}, acc ->
        Map.update(acc, dest, [rule], &[rule | &1])
      end)
    end

    defp build_nested_fk_rules(child, explicit_pairs, by_collection, local_set) do
      for spec <- resolve_nested_specs(child),
          {parent, fk_attr} <- normalize_nested_parent(child, spec, by_collection),
          MapSet.member?(local_set, parent),
          not Enum.any?(explicit_pairs, fn {dest, rule} ->
            dest == parent and rule.source_resource == child and rule.source_attribute == fk_attr
          end) do
        dest_attr = resolve_destination_attribute(child, parent, fk_attr)

        rule = %{
          source_resource: child,
          source_collection: resolve_collection(child),
          source_attribute: fk_attr,
          destination_attribute: dest_attr,
          on_delete: :delete,
          nested?: true
        }

        {parent, rule}
      end
    end

    defp normalize_nested_parent(_child, %{parent: parent, parent_key: fk_attr}, _by_collection)
         when is_atom(parent) and not is_nil(parent) do
      [{parent, fk_attr}]
    end

    defp normalize_nested_parent(
           child,
           %{parent_collection: parent_col, foreign_key: fk_attr},
           by_collection
         ) do
      child
      |> resolve_parent_resources(fk_attr, parent_col, by_collection)
      |> Enum.map(&{&1, fk_attr})
    end

    defp normalize_nested_parent(_child, _other, _by_collection), do: []

    defp resolve_parent_resources(source_resource, fk_attr, parent_col, by_collection) do
      rel_match =
        source_resource
        |> Ash.Resource.Info.relationships()
        |> Enum.find(fn rel -> rel.type == :belongs_to and rel.source_attribute == fk_attr end)

      case rel_match do
        %{destination: dest} ->
          [dest]

        nil ->
          candidates = Map.get(by_collection, parent_col, [])
          top_level = Enum.reject(candidates, &resource_nested?/1)
          if top_level != [], do: top_level, else: candidates
      end
    end

    defp resolve_destination_attribute(child, parent, fk_attr) do
      rel_match =
        child
        |> Ash.Resource.Info.relationships()
        |> Enum.find(fn rel ->
          rel.type == :belongs_to and rel.destination == parent and
            rel.source_attribute == fk_attr
        end)

      case rel_match do
        %{destination_attribute: dest_attr} -> dest_attr
        nil -> parent |> Ash.Resource.Info.primary_key() |> hd()
      end
    end

    defp resource_store_matches?(resource, store_mod) do
      case Info.store(resource) do
        {:ok, ^store_mod} -> true
        ^store_mod -> true
        _ -> false
      end
    end

    defp resolve_collection(resource) do
      case Info.collection(resource) do
        {:ok, col} -> col
        col when is_atom(col) -> col
        _ -> nil
      end
    end

    defp resolve_nested_specs(resource) do
      case Info.nested_in(resource) do
        nil -> []
        list when is_list(list) -> list
        spec -> [spec]
      end
    end

    defp resource_nested?(resource), do: resolve_nested_specs(resource) != []

    defp normalize_optional_timeout(nil), do: nil
    defp normalize_optional_timeout(t), do: normalize_timeout(t)

    @doc false
    def normalize_timeout(nil), do: 15_000
    def normalize_timeout(:infinity), do: :infinity
    def normalize_timeout(ms) when is_integer(ms) and ms >= 0, do: ms

    defp max_timeout(a, nil), do: a
    defp max_timeout(_a, :infinity), do: :infinity
    defp max_timeout(a, b), do: max(a, b)

    @doc false
    def min_timeout(:infinity, b), do: b
    def min_timeout(a, :infinity), do: a
    def min_timeout(a, b), do: min(a, b)

    defp tx_db_key(store), do: {:xitdb_tx_db, store}
    defp tx_state_key(store), do: {:xitdb_tx_state, store}

    defmodule Backend do
      @moduledoc false
      # Localized adapter over core `Xitdb` handle lifecycle and moment-pinning primitives.

      @spec open_db!(String.t() | :memory) :: Xitdb.t()
      def open_db!(:memory), do: Xitdb.open!(backend: :memory)

      def open_db!(path) when is_binary(path),
        do: Xitdb.open!(backend: :buffered_file, path: path)

      @spec ensure_seeded!(Xitdb.t()) :: {Xitdb.t(), non_neg_integer()}
      def ensure_seeded!(%Xitdb{} = db) do
        case Xitdb.moment_count(db) do
          0 ->
            {:ok, seeded_db, moment} =
              Xitdb.transact_ops_with_moment(
                db,
                [{:init_col, ".meta", "hash_map"}],
                doc: "initialize store metadata",
                instant: System.os_time(:millisecond),
                meta: %{
                  "source_system" => "xitdb_store",
                  "action_name" => "init_store",
                  "actor_id" => "system"
                }
              )

            {seeded_db, moment}

          count when count > 0 ->
            {db, count - 1}
        end
      end

      @spec latest_moment(Xitdb.t()) :: integer()
      def latest_moment(%Xitdb{} = db) do
        case Xitdb.info(db) do
          {:ok, %{moment_count: count}} -> count - 1
          {:error, _} -> -1
        end
      end

      @spec invalid_commit_moment?(Xitdb.t(), integer(), Xitdb.t(), term()) :: boolean()
      def invalid_commit_moment?(%Xitdb{} = old_db, old_moment, %Xitdb{} = new_db, new_moment) do
        cond do
          not is_integer(new_moment) or new_moment < -1 ->
            true

          new_moment == -1 ->
            (new_db.db_ref == old_db.db_ref and old_moment >= 0) or
              (new_db.db_ref != old_db.db_ref and latest_moment(new_db) >= 0)

          true ->
            case Xitdb.info(new_db) do
              {:ok, %{moment_count: count}} -> new_moment >= count
              {:error, _} -> false
            end
        end
      end

      @spec invalid_mutate_moment?(Xitdb.t(), integer(), integer(), Xitdb.t(), term()) ::
              boolean()
      def invalid_mutate_moment?(
            %Xitdb{} = old_db,
            old_moment,
            prev_tail,
            %Xitdb{} = new_db,
            new_moment
          ) do
        invalid_commit_moment?(old_db, old_moment, new_db, new_moment) or
          (new_moment == -1 and new_db.db_ref == old_db.db_ref and
             latest_moment(new_db) > prev_tail)
      end

      @spec reconcile_tip(Xitdb.t(), integer(), atom() | String.t()) ::
              {Xitdb.t(), integer()}
      def reconcile_tip(%Xitdb{} = db, target_moment, reason \\ :rollback)
          when is_integer(target_moment) do
        case Xitdb.info(db) do
          {:ok, %{moment_count: count}} when count - 1 > target_moment ->
            tail_moment = count - 1
            reason_str = to_string(reason)

            ops_and_base =
              if target_moment < 0 do
                try do
                  tail_cursor = Xitdb.as_of(db, tail_moment)

                  delete_ops =
                    for {key, _val} <- tail_cursor, key != "__tx" do
                      {:rm_if_exists, [key]}
                    end

                  if delete_ops == [] and
                       match?(
                         {:ok,
                          %{
                            "action_name" => "rollback_tip",
                            "restored_moment" => ^target_moment
                          }},
                         Xitdb.tx_meta(tail_cursor)
                       ) do
                    :already_reconciled
                  else
                    {:ok, delete_ops ++ [{:meta, "restored_moment", target_moment}], tail_moment}
                  end
                rescue
                  _ in Xitdb.Error -> :error
                end
              else
                {:ok, [{:meta, "restored_moment", target_moment}], target_moment}
              end

            case ops_and_base do
              {:ok, ops, tx_base_moment} ->
                case Xitdb.transact_ops_with_moment(
                       db,
                       ops,
                       base_moment: tx_base_moment,
                       doc:
                         "rollback tip from moment #{tail_moment} to #{target_moment} (#{reason_str})",
                       instant: System.os_time(:millisecond),
                       meta: %{
                         "restored_moment" => target_moment,
                         "rolled_back_from" => tail_moment,
                         "rollback_reason" => reason_str,
                         "source_system" => "xitdb_store",
                         "action_name" => "rollback_tip",
                         "actor_id" => "system"
                       }
                     ) do
                  {:ok, restored_db, restored_moment} ->
                    Xitdb.Columnar.clear_cache(restored_db)

                    returned_moment =
                      if target_moment < 0, do: target_moment, else: restored_moment

                    {restored_db, returned_moment}

                  {:error, _} ->
                    {db, target_moment}
                end

              status when status in [:already_reconciled, :error] ->
                {db, target_moment}
            end

          _ ->
            {db, target_moment}
        end
      end

      @spec bump_write_epoch(term()) :: {:ok, pos_integer()} | {:error, term()}
      def bump_write_epoch(%Xitdb{} = db), do: Xitdb.bump_write_epoch(db)
      def bump_write_epoch(_other), do: {:error, :invalid_db}

      @spec fence_snapshot(Xitdb.Ash.Store.working_snapshot()) ::
              {:ok, Xitdb.Ash.Store.working_snapshot()} | {:error, term()}
      def fence_snapshot({%Xitdb{} = db, moment}) do
        apply_epoch_to_snapshot({db, moment}, Xitdb.bump_write_epoch(db))
      end

      @spec fence_snapshot_with_epoch(
              Xitdb.Ash.Store.working_snapshot(),
              Xitdb.t(),
              {:ok, pos_integer()} | {:error, term()}
            ) :: {:ok, Xitdb.Ash.Store.working_snapshot()} | {:error, term()}
      def fence_snapshot_with_epoch({%Xitdb{} = db, moment}, %Xitdb{} = prev_db, bump_result) do
        if db.db_ref == prev_db.db_ref do
          apply_epoch_to_snapshot({db, moment}, bump_result)
        else
          fence_snapshot({db, moment})
        end
      end

      defp apply_epoch_to_snapshot({%Xitdb{} = db, moment}, {:ok, epoch}) do
        {:ok, {%{db | write_epoch: epoch}, moment}}
      end

      defp apply_epoch_to_snapshot(
             {%Xitdb{} = db, moment},
             {:error, %Xitdb.Error{reason: :read_only}}
           ) do
        {:ok, {db, moment}}
      end

      defp apply_epoch_to_snapshot({_db, _moment}, {:error, _} = err), do: err

      @spec publish_commit(module(), integer(), integer()) :: :ok
      def publish_commit(_store, prev_moment, prev_moment), do: :ok
      def publish_commit(_store, _prev_moment, new_moment) when new_moment < 0, do: :ok

      def publish_commit(store, _prev_moment, new_moment) when new_moment >= 0 do
        Snapshot.advance_moment(store, new_moment)
      end

      @spec close_db(term()) :: :ok
      def close_db(%Xitdb{} = db) do
        _ = Xitdb.close(db)
        :ok
      end

      def close_db(_other), do: :ok
    end
  end
end
