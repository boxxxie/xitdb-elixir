if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Indexer do
    @moduledoc false

    def fetch_cursor(_db, _resource, _pk), do: :not_implemented
  end
end
