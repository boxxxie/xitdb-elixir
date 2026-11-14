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
end
