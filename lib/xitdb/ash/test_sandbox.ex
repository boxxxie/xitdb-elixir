if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.TestSandbox do
    @moduledoc false

    def init, do: :ok
    def checkout(_stores, _opts \\ []), do: :ok
    def checkin(_stores), do: :ok
  end
end
