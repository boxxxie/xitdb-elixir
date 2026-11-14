# Reference: `Xitdb.Ash.Store` & `Xitdb.Ash.TestSandbox`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_store_and_test_sandbox_20261111`](./index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Modules:** `lib/xitdb/ash/store.ex`, `lib/xitdb/ash/test_sandbox.ex`
> - **Purpose:** Complete specification and reference implementation for the single-writer store GenServer, monitored caller-process writer leases, nested savepoint rollback, boot-time reverse-FK compilation, and per-test CoW isolation sandbox.

---

## 1. Concurrency & Safety Invariants

### 1.1 Shared `LeaseQueue` with Zombie-Commit Protection
Both production `Store` processes and per-test `TestSandbox.Coordinator` processes share `Xitdb.Ash.Store.LeaseQueue`. If a caller crashes (`:DOWN`) or exceeds `lease_timeout`, the uncommitted working handle is discarded and stale `lease_ref` tokens are rejected with `Xitdb.Ash.LeaseError` so a hung caller can never overwrite a later transaction.

### 1.2 Cross-Store Savepoint Hygiene
`rollback/2` throws `{:xitdb_ash_rollback, store, reason}`. If a nested transaction across `MDM.Store` and `AppStore` aborts the outer store from inside the inner store's block, the inner store restores its own `prev_db` before re-throwing the outer store's rollback tag.

### 1.3 Implicit `nested_in` Index Cleanup Graph
At boot, `Store` compiles incoming `references` across `domains` and automatically synthesizes `:delete` cleanup entries for `nested_in` children (unless overridden with `:restrict`), ensuring parent deletes purge child `_parent`, secondary, identity, and `idx.search` entries.

### 1.4 Per-Test Lease Serialization + Lock-Free ETS Reads
`TestSandbox` serves `Snapshot.current_db/1` reads directly from a public `read_concurrency: true` ETS table while serializing concurrent writes *within* the same test (`Task.async_stream`, LiveView + async tasks) via a per-checkout coordinator—giving production-identical single-writer guarantees with zero cross-test contention.

---

## 2. Reference Implementation: `lib/xitdb/ash/store.ex`

Supports both direct supervision (`{Xitdb.Ash.Store, name: CaasaConnect.AppStore, path: path, domains: [...]}`) and module-based stores (`use Xitdb.Ash.Store`), plus `Store.mutate/3` so `Mutator` operations stay pure `db -> {:ok, new_db, result} | {:error, reason}` functions.

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
    def acquire(%__MODULE__{active: nil} = queue, owner_key, req_ref, from, lease_timeout, _call_timeout, _db) do
      {caller_pid, _tag} = from
      {lease_ref, active} = build_active_lease(owner_key, caller_pid, lease_timeout)
      _ = req_ref
      {:granted, lease_ref, %__MODULE__{queue | active: active}}
    end

    def acquire(%__MODULE__{} = queue, _owner_key, req_ref, from, lease_timeout, call_timeout, _db) do
      waiter = %{
        req_ref: req_ref,
        from: from,
        lease_timeout: lease_timeout,
        call_timeout: call_timeout,
        enqueued_at_ms: System.monotonic_time(:millisecond)
      }

      {:queued, %__MODULE__{queue | waiters: :queue.in(waiter, queue.waiters)}}
    end

    @spec cancel_waiter(t(), reference()) :: t()
    def cancel_waiter(%__MODULE__{} = queue, req_ref) when is_reference(req_ref) do
      filtered =
        :queue.filter(fn %{req_ref: r} -> r != req_ref end, queue.waiters)

      %__MODULE__{queue | waiters: filtered}
    end

    @spec verify_holder(t(), reference(), pid()) :: :ok | {:error, :lease_expired}
    def verify_holder(%__MODULE__{active: %{ref: ref, holder: pid}}, ref, pid), do: :ok
    def verify_holder(%__MODULE__{}, _ref, _pid), do: {:error, :lease_expired}

    @spec release_and_grant_next(t(), term(), term()) :: t()
    def release_and_grant_next(%__MODULE__{active: active} = queue, owner_key, latest_db) do
      cleanup_active(active)
      grant_next_waiter(%__MODULE__{queue | active: nil}, owner_key, latest_db)
    end

    @spec handle_down(t(), reference(), term(), term()) :: {:matched, t()} | :unmatched
    def handle_down(%__MODULE__{active: %{monitor_ref: mref} = active} = queue, mref, owner_key, latest_db) do
      cancel_timer(active.timer_ref)
      {:matched, grant_next_waiter(%__MODULE__{queue | active: nil}, owner_key, latest_db)}
    end

    def handle_down(%__MODULE__{}, _mref, _owner_key, _latest_db), do: :unmatched

    @spec handle_expired(t(), reference(), term(), term()) :: {:matched, t()} | :unmatched
    def handle_expired(%__MODULE__{active: %{ref: ref} = active} = queue, ref, owner_key, latest_db) do
      Process.demonitor(active.monitor_ref, [:flush])
      {:matched, grant_next_waiter(%__MODULE__{queue | active: nil}, owner_key, latest_db)}
    end

    def handle_expired(%__MODULE__{}, _ref, _owner_key, _latest_db), do: :unmatched

    defp grant_next_waiter(%__MODULE__{} = queue, owner_key, latest_db) do
      now_ms = System.monotonic_time(:millisecond)

      case :queue.out(queue.waiters) do
        {:empty, _} ->
          %__MODULE__{queue | active: nil}

        {{:value, waiter}, rest} ->
          next_queue = %__MODULE__{queue | waiters: rest}
          {caller_pid, _tag} = waiter.from

          if waiter_alive_and_valid?(caller_pid, waiter, now_ms) do
            {lease_ref, active} = build_active_lease(owner_key, caller_pid, waiter.lease_timeout)
            GenServer.reply(waiter.from, {:ok, lease_ref, latest_db})
            %__MODULE__{next_queue | active: active}
          else
            grant_next_waiter(next_queue, owner_key, latest_db)
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

    defp build_active_lease(owner_key, holder_pid, lease_timeout) do
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
    alias Xitdb.Ash.Store.{LeaseQueue, Snapshot}

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
      defstruct [:name, :path, :db, :lease_timeout, :queue]

      @type t :: %__MODULE__{
              name: module(),
              path: String.t() | :memory,
              db: term(),
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
    Returns the active `%Xitdb{}` handle for `store` (transaction working handle ->
    `TestSandbox` handle -> latest committed `Snapshot` moment) with zero `GenServer.call`s.
    """
    @spec current_db(module()) :: term()
    def current_db(store) when is_atom(store), do: Snapshot.current_db(store)

    @doc """
    Returns incoming same-store foreign-key rules compiled at boot for `resource`.
    """
    @spec reverse_fks(module(), module()) :: [Snapshot.reverse_fk()]
    def reverse_fks(store, resource) when is_atom(store) and is_atom(resource) do
      Snapshot.reverse_fks(store, resource)
    end

    @doc """
    Returns `true` if the calling process currently holds an active working handle for `store`.
    """
    @spec in_transaction?(module()) :: boolean()
    def in_transaction?(store) when is_atom(store) do
      Process.get(tx_key(store)) != nil
    end

    @doc """
    Aborts the innermost savepoint or transaction for `store` in `O(1)`.
    """
    @spec rollback(module(), term()) :: no_return()
    def rollback(store, reason) when is_atom(store) do
      throw({:xitdb_ash_rollback, store, reason})
    end

    @doc """
    Applies a pure mutation `fun :: (db -> {:ok, new_db, result} | {:error, reason})`
    against the active transaction handle, or wraps it in `transact/3` automatically.
    """
    @spec mutate(module(), (term() -> {:ok, term(), term()} | {:error, term()}), keyword()) ::
            {:ok, term()} | {:error, term()}
    def mutate(store, fun, opts \\ []) when is_atom(store) and is_function(fun, 1) do
      if in_transaction?(store) do
        db = Process.get(tx_key(store))

        case fun.(db) do
          {:ok, new_db, result} ->
            Process.put(tx_key(store), new_db)
            {:ok, result}

          {:error, _reason} = error ->
            error
        end
      else
        transact(
          store,
          fn ->
            db = Process.get(tx_key(store))

            case fun.(db) do
              {:ok, new_db, result} ->
                Process.put(tx_key(store), new_db)
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
      db = opts[:db] || Backend.open_db!(path)
      initial_moment = Backend.latest_moment(db)
      reverse_fks = compile_reverse_fks(name, opts[:domains], opts[:resources])

      :ok = Snapshot.put_base(name, db, moment: initial_moment, reverse_fks: reverse_fks)

      state = %State{
        name: name,
        path: path,
        db: db,
        lease_timeout: Keyword.fetch!(opts, :lease_timeout),
        queue: LeaseQueue.new()
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_call({:acquire_lease, req_ref, call_timeout}, from, %State{} = state) do
      lease_timeout = min_timeout(state.lease_timeout, call_timeout)

      case LeaseQueue.acquire(
             state.queue,
             state.name,
             req_ref,
             from,
             lease_timeout,
             call_timeout,
             state.db
           ) do
        {:granted, lease_ref, next_queue} ->
          {:reply, {:ok, lease_ref, state.db}, %State{state | queue: next_queue}}

        {:queued, next_queue} ->
          {:noreply, %State{state | queue: next_queue}}
      end
    end

    def handle_call({:commit_lease, lease_ref, new_db}, {caller_pid, _}, %State{} = state) do
      case LeaseQueue.verify_holder(state.queue, lease_ref, caller_pid) do
        :ok ->
          :ok = Backend.publish_commit(state.name, state.db, new_db)
          next_queue = LeaseQueue.release_and_grant_next(state.queue, state.name, new_db)
          {:reply, :ok, %State{state | db: new_db, queue: next_queue}}

        {:error, :lease_expired} = err ->
          {:reply, err, state}
      end
    end

    def handle_call({:abort_lease, lease_ref}, {caller_pid, _}, %State{} = state) do
      case LeaseQueue.verify_holder(state.queue, lease_ref, caller_pid) do
        :ok ->
          next_queue = LeaseQueue.release_and_grant_next(state.queue, state.name, state.db)
          {:reply, :ok, %State{state | queue: next_queue}}

        {:error, :lease_expired} ->
          {:reply, :ok, state}
      end
    end

    @impl GenServer
    def handle_cast({:cancel_waiter, req_ref}, %State{} = state) do
      {:noreply, %State{state | queue: LeaseQueue.cancel_waiter(state.queue, req_ref)}}
    end

    @impl GenServer
    def handle_info({:DOWN, mref, :process, _pid, _reason}, %State{} = state) do
      case LeaseQueue.handle_down(state.queue, mref, state.name, state.db) do
        {:matched, next_queue} -> {:noreply, %State{state | queue: next_queue}}
        :unmatched -> {:noreply, state}
      end
    end

    def handle_info({:xitdb_lease_expired, name, lease_ref}, %State{name: name} = state) do
      case LeaseQueue.handle_expired(state.queue, lease_ref, state.name, state.db) do
        {:matched, next_queue} -> {:noreply, %State{state | queue: next_queue}}
        :unmatched -> {:noreply, state}
      end
    end

    def handle_info(_other, %State{} = state), do: {:noreply, state}

    @impl GenServer
    def terminate(_reason, %State{} = state) do
      Snapshot.erase(state.name)
      Backend.close_db(state.db)
      :ok
    end

    # -- Internal Savepoint & Lease Execution --

    @doc false
    @spec run_with_working_db(
            module(),
            term(),
            (-> term()),
            (term() -> :ok | {:error, :lease_expired}),
            (-> :ok)
          ) :: {:ok, term()} | {:error, term()}
    def run_with_working_db(store, initial_db, fun, commit_fn, abort_fn) do
      Process.put(tx_key(store), initial_db)

      try do
        value = fun.()
        final_db = Process.get(tx_key(store))
        Process.delete(tx_key(store))

        case commit_fn.(final_db) do
          :ok ->
            {:ok, value}

          {:error, :lease_expired} ->
            {:error, %LeaseError{store: store, reason: :lease_expired}}
        end
      catch
        :throw, {:xitdb_ash_rollback, ^store, reason} ->
          Process.delete(tx_key(store))
          abort_fn.()
          {:error, reason}

        kind, payload ->
          stacktrace = __STACKTRACE__
          Process.delete(tx_key(store))
          abort_fn.()
          :erlang.raise(kind, payload, stacktrace)
      end
    end

    defp run_savepoint(store, fun) do
      prev_db = Process.get(tx_key(store))

      try do
        {:ok, fun.()}
      catch
        :throw, {:xitdb_ash_rollback, ^store, reason} ->
          Process.put(tx_key(store), prev_db)
          {:error, reason}

        kind, payload ->
          stacktrace = __STACKTRACE__
          Process.put(tx_key(store), prev_db)
          :erlang.raise(kind, payload, stacktrace)
      end
    end

    defp run_leased_transaction(store, fun, call_timeout) do
      req_ref = make_ref()

      case acquire_store_lease(store, req_ref, call_timeout) do
        {:ok, lease_ref, initial_db} ->
          commit_fn = fn final_db ->
            GenServer.call(store, {:commit_lease, lease_ref, final_db}, call_timeout)
          end

          abort_fn = fn ->
            _ = GenServer.call(store, {:abort_lease, lease_ref}, call_timeout)
            :ok
          end

          run_with_working_db(store, initial_db, fun, commit_fn, abort_fn)

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

    # -- Boot-Time Reverse Foreign-Key Graph Compiler --

    defp compile_reverse_fks(store_name, domains, extra_resources) do
      store_resources =
        domains
        |> Enum.flat_map(&Ash.Domain.Info.resources/1)
        |> Kernel.++(extra_resources)
        |> Enum.uniq()
        |> Enum.filter(fn resource ->
          Ash.Resource.Info.data_layer(resource) == Xitdb.Ash.DataLayer and
            Info.store!(resource) == store_name
        end)

      by_collection =
        Map.new(store_resources, fn resource -> {Info.collection!(resource), resource} end)

      Enum.reduce(store_resources, %{}, fn source_resource, acc ->
        explicit_rules = build_explicit_fk_rules(store_name, source_resource)
        nested_rules = build_nested_fk_rules(source_resource, explicit_rules, by_collection)

        Enum.reduce(explicit_rules ++ nested_rules, acc, fn {dest_resource, rule}, map ->
          Map.update(map, dest_resource, [rule], &[rule | &1])
        end)
      end)
    end

    defp build_explicit_fk_rules(store_name, source_resource) do
      source_collection = Info.collection!(source_resource)

      source_resource
      |> Info.references()
      |> Enum.reject(&(&1.on_delete == :nothing))
      |> Enum.map(fn %{relationship: rel_name, on_delete: on_delete} ->
        rel = Ash.Resource.Info.relationship(source_resource, rel_name)

        if rel == nil or rel.type != :belongs_to do
          raise ArgumentError,
                "#{inspect(source_resource)} reference #{inspect(rel_name)} must target a belongs_to relationship"
        end

        dest_store = Info.store!(rel.destination)

        if dest_store != store_name do
          raise ArgumentError,
                "Cross-store on_delete reference from #{inspect(source_resource)} (#{inspect(store_name)}) " <>
                  "to #{inspect(rel.destination)} (#{inspect(dest_store)}) is not allowed; use Ash.Signals instead"
        end

        rule = %{
          source_resource: source_resource,
          source_collection: source_collection,
          source_attribute: rel.source_attribute,
          destination_attribute: rel.destination_attribute,
          on_delete: on_delete,
          nested?: Info.nested_in(source_resource) != nil
        }

        {rel.destination, rule}
      end)
    end

    # Ensures destroying a parent entity also purges nested children's `_parent`, secondary,
    # identity, and BM25 search indexes even when no explicit `reference` block was written.
    defp build_nested_fk_rules(source_resource, explicit_rules, by_collection) do
      case Info.nested_in(source_resource) do
        nil ->
          []

        %{parent_collection: parent_col, foreign_key: fk_attr} ->
          already_covered? =
            Enum.any?(explicit_rules, fn {_dest, rule} -> rule.source_attribute == fk_attr end)

          parent_resource = resolve_parent_resource(source_resource, fk_attr, parent_col, by_collection)

          if already_covered? or parent_resource == nil do
            []
          else
            rule = %{
              source_resource: source_resource,
              source_collection: Info.collection!(source_resource),
              source_attribute: fk_attr,
              destination_attribute: parent_resource |> Ash.Resource.Info.primary_key() |> hd(),
              on_delete: :delete,
              nested?: true
            }

            [{parent_resource, rule}]
          end
      end
    end

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

    defp normalize_timeout(nil), do: 15_000
    defp normalize_timeout(:infinity), do: :infinity
    defp normalize_timeout(ms) when is_integer(ms) and ms > 0, do: ms

    defp min_timeout(:infinity, b), do: b
    defp min_timeout(a, :infinity), do: a
    defp min_timeout(a, b), do: min(a, b)

    defp tx_key(store), do: {:xitdb_tx_db, store}

    defmodule Backend do
      @moduledoc false
      # Localized 4-function adapter over core `Xitdb` handle lifecycle primitives.

      @spec open_db!(String.t() | :memory) :: term()
      def open_db!(:memory), do: Xitdb.open!(backend: :memory)
      def open_db!(path) when is_binary(path), do: Xitdb.open!(path: path)

      @spec latest_moment(term()) :: integer()
      def latest_moment(db) do
        if function_exported?(Xitdb, :moment, 1) do
          case Xitdb.moment(db) do
            m when is_integer(m) and m >= 0 -> m
            _ -> -1
          end
        else
          -1
        end
      end

      @spec publish_commit(module(), term(), term()) :: :ok
      def publish_commit(_store, prev_db, prev_db), do: :ok

      def publish_commit(store, _prev_db, new_db) do
        case latest_moment(new_db) do
          moment when moment >= 0 ->
            Snapshot.advance_moment(store, moment)

          _unindexed ->
            Snapshot.swap_compacted_base(store, new_db, -1)
        end
      end

      @spec close_db(term()) :: :ok
      def close_db(db) do
        if function_exported?(Xitdb, :close, 1) do
          _ = Xitdb.close(db)
        end

        :ok
      end
    end
  end
end
```

---

## 3. Reference Implementation: `lib/xitdb/ash/test_sandbox.ex`

Provides zero-disk-I/O CoW handle isolation for `async: true` suites. Reads bypass all processes via `:ets.lookup/2` (`read_concurrency: true`), while concurrent writes spawned inside the same test (`$callers`, `Task.Supervisor`, LiveViews, or `TestSandbox.allow/3`) serialize cleanly through a per-test `Coordinator` that terminates automatically when the test exits.

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.TestSandbox do
    @moduledoc """
    Lock-free copy-on-write `%Xitdb{}` test sandbox for `async: true` ExUnit suites.

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
    alias Xitdb.Ash.Store.{LeaseQueue, Snapshot}
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
    Idempotently initializes the public ETS registries for sandbox templates and checkouts.
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
    Registers a schema-seeded in-memory `%Xitdb{}` template for `store` at `test_helper.exs` boot.
    When omitted, `checkout/2` forks directly from `Snapshot.committed_db(store)`.
    """
    @spec seed_template(module(), term()) :: :ok
    def seed_template(store, template_db) when is_atom(store) do
      init()
      true = :ets.insert(@templates_table, {store, template_db})
      :ok
    end

    @doc """
    Checks out isolated CoW `%Xitdb{}` handles for `store_or_stores` keyed to `self()`.

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

      initial_dbs =
        Map.new(stores, fn store ->
          {store, template_for(store)}
        end)

      {:ok, coord_pid} =
        Coordinator.start(owner, initial_dbs, opts[:lease_timeout], @checkouts_table)

      Enum.each(initial_dbs, fn {store, db} ->
        :ets.insert(@checkouts_table, {{:db, store, owner}, db})
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
    Resolves the caller's isolated `%Xitdb{}` handle in `O(1)` via ETS without any `GenServer` calls.
    """
    @spec checkout_db(module()) :: {:ok, term()} | :none
    def checkout_db(store) when is_atom(store) do
      case resolve_owner(store) do
        {:ok, owner} ->
          case :ets.lookup(@checkouts_table, {:db, store, owner}) do
            [{_, db}] -> {:ok, db}
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
            {:ok, lease_ref, initial_db} ->
              commit_fn = fn final_db ->
                GenServer.call(coord_pid, {:commit, store, lease_ref, final_db}, call_timeout)
              end

              abort_fn = fn ->
                _ = GenServer.call(coord_pid, {:abort, store, lease_ref}, call_timeout)
                :ok
              end

              Store.run_with_working_db(store, initial_db, fun, commit_fn, abort_fn)

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
        [{^store, template_db}] -> fork_template(template_db)
        [] -> store |> Snapshot.committed_db() |> fork_template()
      end
    end

    defp fork_template(db) do
      if function_exported?(Xitdb, :fork, 1) do
        Xitdb.fork(db)
      else
        db
      end
    end

    defp register_ex_unit_cleanup(stores, owner) do
      if Code.ensure_loaded?(ExUnit.Callbacks) and function_exported?(ExUnit.Callbacks, :on_exit, 2) do
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
        try do
          _ = :ets.new(name, opts)
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

    alias Xitdb.Ash.Store.LeaseQueue
    alias Xitdb.Ash.TestSandbox

    defstruct [:owner, :owner_mref, :table, :lease_timeout, :dbs, :queues]

    @type t :: %__MODULE__{
            owner: pid(),
            owner_mref: reference(),
            table: atom(),
            lease_timeout: timeout(),
            dbs: %{optional(module()) => term()},
            queues: %{optional(module()) => LeaseQueue.t()}
          }

    @spec start(pid(), %{module() => term()}, timeout(), atom()) :: GenServer.on_start()
    def start(owner, initial_dbs, lease_timeout, table) do
      GenServer.start(__MODULE__, {owner, initial_dbs, lease_timeout, table})
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
    def init({owner, initial_dbs, lease_timeout, table}) do
      owner_mref = Process.monitor(owner)
      queues = Map.new(initial_dbs, fn {store, _db} -> {store, LeaseQueue.new()} end)

      state = %__MODULE__{
        owner: owner,
        owner_mref: owner_mref,
        table: table,
        lease_timeout: lease_timeout,
        dbs: initial_dbs,
        queues: queues
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_call({:acquire, store, req_ref, call_timeout}, from, %__MODULE__{} = state) do
      queue = Map.fetch!(state.queues, store)
      db = Map.fetch!(state.dbs, store)

      case LeaseQueue.acquire(queue, store, req_ref, from, state.lease_timeout, call_timeout, db) do
        {:granted, lease_ref, next_queue} ->
          {:reply, {:ok, lease_ref, db}, put_queue(state, store, next_queue)}

        {:queued, next_queue} ->
          {:noreply, put_queue(state, store, next_queue)}
      end
    end

    def handle_call({:commit, store, lease_ref, new_db}, {caller_pid, _}, %__MODULE__{} = state) do
      queue = Map.fetch!(state.queues, store)

      case LeaseQueue.verify_holder(queue, lease_ref, caller_pid) do
        :ok ->
          :ets.insert(state.table, {{:db, store, state.owner}, new_db})
          next_queue = LeaseQueue.release_and_grant_next(queue, store, new_db)

          next_state = %__MODULE__{
            state
            | dbs: Map.put(state.dbs, store, new_db),
              queues: Map.put(state.queues, store, next_queue)
          }

          {:reply, :ok, next_state}

        {:error, :lease_expired} = err ->
          {:reply, err, state}
      end
    end

    def handle_call({:abort, store, lease_ref}, {caller_pid, _}, %__MODULE__{} = state) do
      queue = Map.fetch!(state.queues, store)
      db = Map.fetch!(state.dbs, store)

      case LeaseQueue.verify_holder(queue, lease_ref, caller_pid) do
        :ok ->
          next_queue = LeaseQueue.release_and_grant_next(queue, store, db)
          {:reply, :ok, put_queue(state, store, next_queue)}

        {:error, :lease_expired} ->
          {:reply, :ok, state}
      end
    end

    @impl GenServer
    def handle_cast({:cancel_waiter, store, req_ref}, %__MODULE__{} = state) do
      queue = Map.fetch!(state.queues, store)
      {:noreply, put_queue(state, store, LeaseQueue.cancel_waiter(queue, req_ref))}
    end

    @impl GenServer
    def handle_info({:DOWN, mref, :process, _pid, _reason}, %__MODULE__{owner_mref: mref} = state) do
      TestSandbox.purge_owner_entries(state.table, Map.keys(state.dbs), state.owner)
      {:stop, :normal, state}
    end

    def handle_info({:DOWN, mref, :process, _pid, _reason}, %__MODULE__{} = state) do
      next_queues =
        Map.new(state.queues, fn {store, queue} ->
          db = Map.fetch!(state.dbs, store)

          case LeaseQueue.handle_down(queue, mref, store, db) do
            {:matched, updated} -> {store, updated}
            :unmatched -> {store, queue}
          end
        end)

      {:noreply, %__MODULE__{state | queues: next_queues}}
    end

    def handle_info({:xitdb_lease_expired, store, lease_ref}, %__MODULE__{} = state) do
      case Map.fetch(state.queues, store) do
        {:ok, queue} ->
          db = Map.fetch!(state.dbs, store)

          case LeaseQueue.handle_expired(queue, lease_ref, store, db) do
            {:matched, next_queue} -> {:noreply, put_queue(state, store, next_queue)}
            :unmatched -> {:noreply, state}
          end

        :error ->
          {:noreply, state}
      end
    end

    def handle_info(_other, %__MODULE__{} = state), do: {:noreply, state}

    defp put_queue(%__MODULE__{} = state, store, queue) do
      %__MODULE__{state | queues: Map.put(state.queues, store, queue)}
    end
  end
end
```
