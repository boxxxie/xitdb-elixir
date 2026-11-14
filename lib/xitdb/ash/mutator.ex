if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Mutator do
    @moduledoc false

    def create(_resource, _changeset), do: {:error, :not_implemented}
    def bulk_create(_resource, _stream, _options), do: {:error, :not_implemented}
    def update(_resource, _changeset), do: {:error, :not_implemented}
    def update_query(_query, _changeset, _resource, _options), do: {:error, :not_implemented}
    def upsert(_resource, _changeset, _keys, _identity \\ nil), do: {:error, :not_implemented}
    def destroy(_resource, _changeset), do: {:error, :not_implemented}
    def destroy_query(_query, _changeset, _resource, _options), do: {:error, :not_implemented}
  end
end
