# Reference: `Xitdb.Ash.Store` & `Xitdb.Ash.TestSandbox`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_store_and_test_sandbox_20261111`](./index.md)
> - **Wave:** Wave 2
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules:** `lib/xitdb/ash/store.ex`, `lib/xitdb/ash/test_sandbox.ex`
> - **Purpose:** Complete specification and reference implementation for the single-writer store GenServer, `{db, moment}` snapshot pinning, monitored caller-process writer leases, nested savepoint rollback, file-backed `.xit` tip reconciliation, boot-time reverse-FK compilation, and per-test isolated `:memory` handle sandbox.

---

## 1. Concurrency & Safety Invariants

### 1.1 `{db, moment}` Working State & File-Backed Rollback Hygiene
`%Xitdb{}` wraps an append-only native `db_ref` resource. Appending a commit via `Xitdb.transact_ops(db, ops, base_moment: moment)` mutates the underlying `db_ref` and increments `Xitdb.moment_count(db)` while returning the identical `%Xitdb{}` Elixir struct. Therefore:
- Both `Store` and `TestSandbox.Coordinator` seed moment `0` (`[{:init_col, ".meta", "hash_map"}]`) on empty databases so `moment >= 0` always holds, and track `{db, moment}` explicitly.
- Active transactions store `{db, moment}` in `{:xitdb_tx_state, store}` for writers (`Store.mutate/3`) and `Xitdb.as_of(db, moment)` (`%Xitdb.Cursor{moment: moment}`) in `{:xitdb_tx_db, store}` so `Snapshot.current_db/1` serves lock-free reads strictly pinned to `moment`.
- On commit, `Backend.publish_commit(store, prev_moment, new_moment)` compares integer moments (`prev_moment` vs `new_moment`) rather than struct equality, and `Backend.reconcile_tip/2` appends a lightweight root-restore moment from `base_moment: target_moment` whenever an aborted transaction or rolled-back inner savepoint left uncommitted moments at the tail of `db`.

### 1.2 Shared `LeaseQueue` with Zombie-Commit & Timeout-Race Protection
Both production `Store` processes and per-test `TestSandbox.Coordinator` processes share `Xitdb.Ash.Store.LeaseQueue`. Each `active_lease` stores both `lease_ref` and the originating `req_ref`. If a queued caller times out in `GenServer.call/3` at the exact instant the previous holder releases the lease and `grant_next_waiter/3` promotes that caller to `active`, `LeaseQueue.cancel_waiter/4` detects `active.req_ref == req_ref`, cleans up the orphaned active lease, and immediately grants the next live waiter. If a caller crashes (`:DOWN`) or exceeds `lease_timeout`, uncommitted moments are reconciled back to `state.moment` and stale `lease_ref` tokens are rejected with `Xitdb.Ash.LeaseError`.

### 1.3 Cross-Store Savepoint Hygiene & Timeout-Safe Aborts
`rollback/2` throws `{:xitdb_ash_rollback, store, reason}`. If a nested transaction across `MDM.Store` and `AppStore` aborts the outer store from inside the inner store's block, the inner store restores its own `{prev_db, prev_moment}` snapshot before re-throwing the outer store's rollback tag. Aborts notify the coordinator via `GenServer.cast/2` (`{:abort_lease, lease_ref, self()}`) so an exhausted `call_timeout` never raises a secondary `:timeout` exit that masks the original rollback or exception.

### 1.4 Canonical Reverse-FK & `nested_in` Cleanup Graph
At boot, `Store` compiles incoming same-store `references` across `domains` and `resources` into `%{source_resource, source_collection, source_attribute, destination_attribute, on_delete, nested?}` rules matching `Snapshot.reverse_fk()`, `Mutator`, and `Indexer`, and synthesizes `:delete` cleanup rules from `Info.nested_in/1` / `Info.nested_mappings/1` (returning `[]` when no `nested_in` is configured in Wave 2 and activating seamlessly in Wave 3 Track 11B).

### 1.5 Per-Test Isolated `:memory` Handles + Heir-Protected ETS Reads
`TestSandbox` clones an independent `:memory` `%Xitdb{}` handle per test checkout via `Xitdb.compact!/1` so `async: true` tests never mutate a shared `db_ref`, assigns `:kernel_sup` as the ETS `:heir` so `@templates_table` and `@checkouts_table` survive dynamic caller exits, serves pinned `%Xitdb.Cursor{}` snapshots from ETS (`read_concurrency: true`), and closes sandbox `%Xitdb{}` handles in `Coordinator.terminate/2`.

---

## 2. Reference Implementation: `lib/xitdb/ash/store.ex`

Supports both direct supervision (`{Xitdb.Ash.Store, name: MyApp.AppStore, path: path, domains: [...]}`) and module-based stores (`use Xitdb.Ash.Store`), plus `Store.mutate/3` operating on `{db, moment}` snapshots.

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.LeaseError do
    @moduledoc """
    Raised or returned when a writer lease times out or expires before commit.
    """
    defexception [:store, :reason]

    @type t :: %__MODULE__{store: module(), reason: :lease_timeout | :lease_expired}

    @impl Exception
    def message(%__MODULE__{store: store, reason: :lease_timeout}) do
      "timed out waiting to acquire Xitdb writer lease for #{inspect(store)}"
    end

    def message(%__MODULE__{store: store, reason: :lease_expired}) do
      "Xitdb writer lease for #{inspect(store)} expired before transaction committed"
    end
  end

  defmodule Xitdb.Ash.Store.LeaseQueue do
    @moduledoc false

    @type active_lease :: %{
            ref: reference(),
            req_ref: reference(),
            holder: pid(),
            monitor_ref: reference(),
            timer_ref: reference()
          }

    @type waiter :: %{
            req_ref: reference(),
            from: GenServer.from(),
            lease_timeout: timeout(),
            call_timeout: timeout(),
            enqueued_at_ms: integer()
          }

    defstruct active: nil, waiters: :queue.new()

    @type t :: %__MODULE__{
            active: active_lease() | nil,
            waiters: :queue.queue(waiter())
          }

    @spec new() :: t()
    def new, do: %__MODULE__{}

    @spec acquire(t(), term(), reference(), GenServer.from(), timeout(), timeout(), term()) ::
            {:granted, reference(), t()} | {:queued, t()}
    def acquire(
          %__MODULE__{active: nil} = queue,
          owner_key,
          req_ref,
          from,
          lease_timeout,
          _call_timeout,
          _snapshot
        ) do
      {caller_pid, _tag} = from
      {lease_ref, active} = build_active_lease(owner_key, req_ref, caller_pid, lease_timeout)
      {:granted, lease_ref, %__MODULE__{queue | active: active}}
    end

    def acquire(
          %__MODULE__{} = queue,
          _owner_key,
          req_ref,
          from,
          lease_timeout,
          call_timeout,
          _snapshot
        ) do
      waiter = %{
        req_ref: req_ref,
        from: from,
        lease_timeout: lease_timeout,
        call_timeout: call_timeout,
        enqueued_at_ms: System.monotonic_time(:millisecond)
      }

      {:queued, %__MODULE__{queue | waiters: :queue.in(waiter, queue.waiters)}}
    end

    @spec cancel_waiter(t(), reference(), term(), term()) :: t()
    def cancel_waiter(
          %__MODULE__{active: %{req_ref: req_ref} = active} = queue,
          req_ref,
          owner_key,
          latest_snapshot
        )
        when is_reference(req_ref) do
      cleanup_active(active)
      grant_next_waiter(%__MODULE__{queue | active: nil}, owner_key, latest_snapshot)
    end

    def cancel_waiter(%__MODULE__{} = queue, req_ref, _owner_key, _latest_snapshot)
        when is_reference(req_ref) do
      filtered = :queue.filter(fn %{req_ref: r} -> r != req_ref end, queue.waiters)
      %__MODULE__{queue | waiters: filtered}
    end

    @spec verify_holder(t(), reference(), pid()) :: :ok | {:error, :lease_expired}
    def verify_holder(%__MODULE__{active: %{ref: ref, holder: pid}}, ref, pid), do: :ok
    def verify_holder(%__MODULE__{}, _ref, _pid), do: {:error, :lease_expired}

    @spec release_and_grant_next(t(), term(), term()) :: t()
    def release_and_grant_next(%__MODULE__{active: active} = queue, owner_key, latest_snapshot) do
      cleanup_active(active)
      grant_next_waiter(%__MODULE__{queue | active: nil}, owner_key, latest_snapshot)
    end

    @spec handle_down(t(), reference(), term(), term()) :: {:matched, t()} | :unmatched
    def handle_down(
          %__MODULE__{active: %{monitor_ref: mref} = active} = queue,
          mref,
          owner_key,
          latest_snapshot
        ) do
      cancel_timer(active.timer_ref)
      {:matched, grant_next_waiter(%__MODULE__{queue | active: nil}, owner_key, latest_snapshot)}
    end

    def handle_down(%__MODULE__{}, _mref, _owner_key, _latest_snapshot), do: :unmatched

    @spec handle_expired(t(), reference(), term(), term()) :: {:matched, t()} | :unmatched
    def handle_expired(
          %__MODULE__{active: %{ref: ref} = active} = queue,
          ref,
          owner_key,
          latest_snapshot
        ) do
      Process.demonitor(active.monitor_ref, [:flush])
      {:matched, grant_next_waiter(%__MODULE__{queue | active: nil}, owner_key, latest_snapshot)}
    end

    def handle_expired(%__MODULE__{}, _ref, _owner_key, _latest_snapshot), do: :unmatched

    defp grant_next_waiter(%__MODULE__{} = queue, owner_key, latest_snapshot) do
      now_ms = System.monotonic_time(:millisecond)

      case :queue.out(queue.waiters) do
        {:empty, _} ->
          %__MODULE__{queue | active: nil}

        {{:value, waiter}, rest} ->
          next_queue = %__MODULE__{queue | waiters: rest}
          {caller_pid, _tag} = waiter.from

          if waiter_alive_and_valid?(caller_pid, waiter, now_ms) do
            {lease_ref, active} =
              build_active_lease(owner_key, waiter.req_ref, caller_pid, waiter.lease_timeout)

            GenServer.reply(waiter.from, {:ok, lease_ref, latest_snapshot})
            %__MODULE__{next_queue | active: active}
          else
            grant_next_waiter(next_queue, owner_key, latest_snapshot)
          end
      end
    end

    defp waiter_alive_and_valid?(caller_pid, waiter, now_ms) do
      alive? = Process.alive?(caller_pid)

      not_expired? =
        case waiter.call_timeout do
          :infinity -> true
          ms when is_integer(ms) -> now_ms - waiter.enqueued_at_ms < ms
        end

      alive? and not_expired?
    end

    defp build_active_lease(owner_key, req_ref, holder_pid, lease_timeout) do
      lease_ref = make_ref()
      monitor_ref = Process.monitor(holder_pid)

      timer_ref =
        case lease_timeout do
          :infinity ->
            make_ref()

          ms when is_integer(ms) and ms > 0 ->
            Process.send_after(self(), {:xitdb_lease_expired, owner_key, lease_ref}, ms)
        end

      active = %{
        ref: lease_ref,
        req_ref: req_ref,
        holder: holder_pid,
        monitor_ref: monitor_ref,
        timer_ref: timer_ref
      }

      {lease_ref, active}
    end

    defp cleanup_active(nil), do: :ok

    defp cleanup_active(%{monitor_ref: mref, timer_ref: tref}) do
      Process.demonitor(mref, [:flush])
      cancel_timer(tref)
    end

    defp cancel_timer(tref) when is_reference(tref) do
      _ = Process.cancel_timer(tref, async: true, info: false)
      :ok
    end
  end

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
                        doc: "Ash domains backed by this store (used to compile reverse-FK rules)."
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

        @spec in_transaction?() :: boolean()
        def in_transaction?, do: Xitdb.Ash.Store.in_transaction?(__MODULE__)

        @spec transact((-> term()), keyword()) :: {:ok, term()} | {:error, term()}
        def transact(fun, opts \\ []), do: Xitdb.Ash.Store.transact(__MODULE__, fun, opts)

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
          {:ok, {new_db, new_moment} = next_snapshot, result} ->
            put_working_snapshot(store, next_snapshot)
            _ = {new_db, new_moment}
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
        result = exec.()

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
          {:reply, err, state}
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
      {restored_db, restored_moment} = Backend.reconcile_tip(state.db, state.moment)
      :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
      snapshot = {restored_db, restored_moment}

      case LeaseQueue.handle_down(state.queue, mref, state.name, snapshot) do
        {:matched, next_queue} ->
          {:noreply, %State{state | db: restored_db, moment: restored_moment, queue: next_queue}}

        :unmatched ->
          {:noreply, %State{state | db: restored_db, moment: restored_moment}}
      end
    end

    def handle_info({:xitdb_lease_expired, name, lease_ref}, %State{name: name} = state) do
      {restored_db, restored_moment} = Backend.reconcile_tip(state.db, state.moment)
      :ok = Backend.publish_commit(state.name, state.moment, restored_moment)
      snapshot = {restored_db, restored_moment}

      case LeaseQueue.handle_expired(state.queue, lease_ref, state.name, snapshot) do
        {:matched, next_queue} ->
          {:noreply, %State{state | db: restored_db, moment: restored_moment, queue: next_queue}}

        :unmatched ->
          {:noreply, %State{state | db: restored_db, moment: restored_moment}}
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
            GenServer.cast(store, {:abort_lease, lease_ref, self()})
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

    # Synthesizes `:delete` cleanup rules for `nested_in` children when no explicit
    # `reference` block already covers `(parent, foreign_key)`. Returns `[]` in Wave 2
    # when no `nested_in` is configured, and activates automatically in Track 11B.
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
      def open_db!(path) when is_binary(path), do: Xitdb.open!(backend: :buffered_file, path: path)

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
```

---

## 3. Reference Implementation: `lib/xitdb/ash/test_sandbox.ex`

Provides zero-disk-I/O `:memory` handle isolation for `async: true` suites. Each test checkout compacts the seeded template into an independent `:memory` `%Xitdb{}` handle so concurrent tests never contend on or mutate a shared `db_ref`. Reads bypass all processes via `:ets.lookup/2` (`read_concurrency: true`) returning a pinned `%Xitdb.Cursor{}`, while concurrent writes spawned inside the same test (`$callers`, `Task.Supervisor`, LiveViews, or `TestSandbox.allow/3`) serialize cleanly through a per-test `Coordinator` that closes its `:memory` handles automatically on exit.

```elixir
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

        Enum.each(coords, &Coordinator.stop/1)
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
                GenServer.cast(coord_pid, {:abort, store, lease_ref, self()})
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
          {:reply, err, state}
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
          {db, moment} = Map.fetch!(snaps_acc, store)
          {restored_db, restored_moment} = Backend.reconcile_tip(db, moment)
          restored_snap = {restored_db, restored_moment}

          case LeaseQueue.handle_down(queue, mref, store, restored_snap) do
            {:matched, updated} ->
              {Map.put(snaps_acc, store, restored_snap), Map.put(queues_acc, store, updated)}

            :unmatched ->
              {snaps_acc, queues_acc}
          end
        end)

      {:noreply, %__MODULE__{state | snapshots: next_snapshots, queues: next_queues}}
    end

    def handle_info({:xitdb_lease_expired, store, lease_ref}, %__MODULE__{} = state) do
      case Map.fetch(state.queues, store) do
        {:ok, queue} ->
          {db, moment} = Map.fetch!(state.snapshots, store)
          {restored_db, restored_moment} = Backend.reconcile_tip(db, moment)
          restored_snap = {restored_db, restored_moment}

          case LeaseQueue.handle_expired(queue, lease_ref, store, restored_snap) do
            {:matched, next_queue} ->
              {:noreply,
               %__MODULE__{
                 state
                 | snapshots: Map.put(state.snapshots, store, restored_snap),
                   queues: Map.put(state.queues, store, next_queue)
               }}

            :unmatched ->
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
```
