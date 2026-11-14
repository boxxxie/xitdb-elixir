if Code.ensure_loaded?(Ash.DataLayer) do
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
end
