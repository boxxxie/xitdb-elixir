if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Store do
    @moduledoc """
    Caller-supervised single-writer store, lock-free snapshot coordinator, and savepoint
    transaction manager for `Xitdb.Ash.DataLayer`.

    Reads resolve in ~10ns via `Xitdb.Ash.Store.Snapshot` without touching this `GenServer`.
    Transactions acquire a monitored writer lease and execute inside the caller process so
    `self()`, `$callers`, `Swoosh` sandboxes, and multi-store transactions behave naturally.

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

    @type working_snapshot :: {Xitdb.t(), non_neg_integer()}

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
      defstruct [:name, :path, :db, :moment, :lease_timeout, :queue]

      @type t :: %__MODULE__{
              name: module(),
              path: String.t() | :memory,
              db: Xitdb.t(),
              moment: non_neg_integer(),
              lease_timeout: timeout(),
              queue: LeaseQueue.t()
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
    @spec reverse_fks(module(), module()) :: [Snapshot.reverse_fk()]
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
        snapshot = Process.get(tx_state_key(store))

        case fun.(snapshot) do
          {:ok, {_new_db, _new_moment} = next_snapshot, result} ->
            put_working_snapshot(store, next_snapshot)
            {:ok, result}

          {:error, _reason} = error ->
            error
        end
      else
        transact(
          store,
          fn ->
            snapshot = Process.get(tx_state_key(store))

            case fun.(snapshot) do
              {:ok, {_new_db, _new_moment} = next_snapshot, result} ->
                put_working_snapshot(store, next_snapshot)
                result

              {:error, reason} ->
                rollback(store, reason)
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
      timeout = normalize_timeout(opts[:timeout])

      {mode, exec} =
        cond do
          in_transaction?(store) ->
            {:savepoint, fn -> run_savepoint(store, fun) end}

          match?({:ok, _, _}, TestSandbox.checkout_owner(store)) ->
            {:sandbox, fn -> TestSandbox.transact(store, fun, timeout) end}

          true ->
            {:leased, fn -> run_leased_transaction(store, fun, timeout) end}
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
      lease_timeout = min_timeout(state.lease_timeout, call_timeout)
      snapshot = {state.db, state.moment}

      case LeaseQueue.acquire(
             state.queue,
             state.name,
             req_ref,
             from,
             lease_timeout,
             call_timeout,
             snapshot
           ) do
        {:granted, lease_ref, next_queue} ->
          {:reply, {:ok, lease_ref, snapshot}, %State{state | queue: next_queue}}

        {:queued, next_queue} ->
          {:noreply, %State{state | queue: next_queue}}
      end
    end

    def handle_call(
          {:commit_lease, lease_ref, {new_db, new_moment}},
          {caller_pid, _},
          %State{} = state
        ) do
      case LeaseQueue.verify_holder(state.queue, lease_ref, caller_pid) do
        :ok ->
          {committed_db, committed_moment} = Backend.reconcile_tip(new_db, new_moment)
          :ok = Backend.publish_commit(state.name, state.moment, committed_moment)
          next_snapshot = {committed_db, committed_moment}
          next_queue = LeaseQueue.release_and_grant_next(state.queue, state.name, next_snapshot)

          {:reply, :ok,
           %State{state | db: committed_db, moment: committed_moment, queue: next_queue}}

        {:error, :lease_expired} = err ->
          next_state =
            if is_nil(state.queue.active) do
              {restored_db, restored_moment} = Backend.reconcile_tip(state.db, state.moment)
              :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
              %State{state | db: restored_db, moment: restored_moment}
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
      snapshot = {state.db, state.moment}
      next_queue = LeaseQueue.cancel_waiter(state.queue, req_ref, state.name, snapshot)
      {:noreply, %State{state | queue: next_queue}}
    end

    @impl GenServer
    def handle_info({:DOWN, mref, :process, _pid, _reason}, %State{} = state) do
      if match?(%{monitor_ref: ^mref}, state.queue.active) do
        {restored_db, restored_moment} = Backend.reconcile_tip(state.db, state.moment)
        :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
        snapshot = {restored_db, restored_moment}
        {:matched, next_queue} = LeaseQueue.handle_down(state.queue, mref, state.name, snapshot)
        {:noreply, %State{state | db: restored_db, moment: restored_moment, queue: next_queue}}
      else
        {:noreply, state}
      end
    end

    def handle_info({:xitdb_lease_expired, name, lease_ref}, %State{name: name} = state) do
      if match?(%{ref: ^lease_ref}, state.queue.active) do
        {restored_db, restored_moment} = Backend.reconcile_tip(state.db, state.moment)
        :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
        snapshot = {restored_db, restored_moment}

        {:matched, next_queue} =
          LeaseQueue.handle_expired(state.queue, lease_ref, state.name, snapshot)

        {:noreply, %State{state | db: restored_db, moment: restored_moment, queue: next_queue}}
      else
        {:noreply, state}
      end
    end

    def handle_info(_other, %State{} = state), do: {:noreply, state}

    @impl GenServer
    def terminate(_reason, %State{} = state) do
      Snapshot.erase(state.name)
      Backend.close_db(state.db)
      :ok
    end

    defp release_aborted_lease(%State{} = state, lease_ref, caller_pid) do
      case LeaseQueue.verify_holder(state.queue, lease_ref, caller_pid) do
        :ok ->
          {restored_db, restored_moment} = Backend.reconcile_tip(state.db, state.moment)
          :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
          snapshot = {restored_db, restored_moment}
          next_queue = LeaseQueue.release_and_grant_next(state.queue, state.name, snapshot)
          %State{state | db: restored_db, moment: restored_moment, queue: next_queue}

        {:error, :lease_expired} ->
          state
      end
    end

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

      try do
        value = fun.()
        final_snapshot = Process.get(tx_state_key(store))
        delete_working_snapshot(store)

        case commit_fn.(final_snapshot) do
          :ok ->
            {:ok, value}

          {:error, :lease_expired} ->
            {:error, %LeaseError{store: store, reason: :lease_expired}}
        end
      catch
        :throw, {:xitdb_ash_rollback, ^store, reason} ->
          delete_working_snapshot(store)
          abort_fn.()
          {:error, reason}

        kind, payload ->
          stacktrace = __STACKTRACE__
          delete_working_snapshot(store)
          abort_fn.()
          :erlang.raise(kind, payload, stacktrace)
      end
    end

    defp run_savepoint(store, fun) do
      prev_snapshot = Process.get(tx_state_key(store))

      try do
        {:ok, fun.()}
      catch
        :throw, {:xitdb_ash_rollback, ^store, reason} ->
          put_working_snapshot(store, prev_snapshot)
          {:error, reason}

        kind, payload ->
          stacktrace = __STACKTRACE__
          put_working_snapshot(store, prev_snapshot)
          :erlang.raise(kind, payload, stacktrace)
      end
    end

    defp run_leased_transaction(store, fun, call_timeout) do
      req_ref = make_ref()

      case acquire_store_lease(store, req_ref, call_timeout) do
        {:ok, lease_ref, initial_snapshot} ->
          commit_fn = fn final_snapshot ->
            GenServer.call(store, {:commit_lease, lease_ref, final_snapshot}, call_timeout)
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

    defp acquire_store_lease(store, req_ref, call_timeout) do
      GenServer.call(store, {:acquire_lease, req_ref, call_timeout}, call_timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(store, {:cancel_waiter, req_ref})
        {:error, %LeaseError{store: store, reason: :lease_timeout}}
    end

    defp put_working_snapshot(store, {db, moment} = snapshot) do
      Process.put(tx_state_key(store), snapshot)
      Process.put(tx_db_key(store), Xitdb.as_of(db, moment))
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
      by_collection = Map.new(local_resources, fn res -> {resolve_collection(res), res} end)

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
      case resolve_parent_resource(child, fk_attr, parent_col, by_collection) do
        nil -> []
        parent -> [{parent, fk_attr}]
      end
    end

    defp normalize_nested_parent(_child, _other, _by_collection), do: []

    defp resolve_parent_resource(source_resource, fk_attr, parent_col, by_collection) do
      rel_match =
        source_resource
        |> Ash.Resource.Info.relationships()
        |> Enum.find(fn rel -> rel.type == :belongs_to and rel.source_attribute == fk_attr end)

      case rel_match do
        %{destination: dest} -> dest
        nil -> Map.get(by_collection, parent_col)
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
      case resolve_single_nested_in(resource) do
        [_ | _] = list ->
          list

        [] ->
          if function_exported?(Info, :nested_mappings, 1) do
            Info.nested_mappings(resource)
          else
            []
          end
      end
    end

    defp resolve_single_nested_in(resource) do
      if function_exported?(Info, :nested_in, 1) do
        case apply(Info, :nested_in, [resource]) do
          nil -> []
          list when is_list(list) -> list
          spec -> [spec]
        end
      else
        []
      end
    end

    defp resource_nested?(resource), do: resolve_nested_specs(resource) != []

    defp normalize_timeout(nil), do: 15_000
    defp normalize_timeout(:infinity), do: :infinity
    defp normalize_timeout(ms) when is_integer(ms) and ms > 0, do: ms

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
            {:ok, seeded_db} = Xitdb.transact_ops(db, [{:init_col, ".meta", "hash_map"}])
            {seeded_db, Xitdb.moment_count(seeded_db) - 1}

          count when count > 0 ->
            {db, count - 1}
        end
      end

      @spec latest_moment(Xitdb.t()) :: integer()
      def latest_moment(%Xitdb{} = db), do: Xitdb.moment_count(db) - 1

      @spec reconcile_tip(Xitdb.t(), non_neg_integer()) :: {Xitdb.t(), non_neg_integer()}
      def reconcile_tip(%Xitdb{} = db, target_moment) when is_integer(target_moment) do
        tail_moment = latest_moment(db)

        if tail_moment > target_moment do
          {:ok, restored_db} =
            Xitdb.transact_ops(
              db,
              [{:meta, "restored_moment", target_moment}],
              base_moment: target_moment
            )

          {restored_db, latest_moment(restored_db)}
        else
          {db, target_moment}
        end
      end

      @spec publish_commit(module(), non_neg_integer(), non_neg_integer()) :: :ok
      def publish_commit(_store, prev_moment, prev_moment), do: :ok

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
