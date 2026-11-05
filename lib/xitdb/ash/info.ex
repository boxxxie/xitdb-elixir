if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Info do
    @moduledoc """
    Compile-time and runtime introspection helpers for `Xitdb.Ash.Resource`.
    """
    use Spark.InfoGenerator,
      extension: Xitdb.Ash.Resource,
      sections: [:xitdb]

    alias Xitdb.Pull

    @doc """
    Returns the deduplicated list of editable and computed Xitdb field names as strings
    for one or more `Xitdb.Ash.Resource` modules, applying any configured `field_aliases`.
    """
    @spec editable_field_strings(Ash.Resource.t() | [Ash.Resource.t()]) :: [String.t()]
    def editable_field_strings(resources) when is_list(resources) do
      resources
      |> Enum.flat_map(&editable_field_strings/1)
      |> Enum.uniq()
    end

    def editable_field_strings(resource) do
      aliases = xitdb_field_aliases!(resource)

      resource
      |> xitdb_editable_fields!()
      |> Enum.concat(xitdb_computed_xitdb_fields!(resource))
      |> Enum.map(fn attr -> to_string(Keyword.get(aliases, attr, attr)) end)
      |> Enum.uniq()
    end

    @doc """
    Returns the deduplicated list of Xitdb slot atoms (`[:id | editable ++ passthru]`)
    for one or more `Xitdb.Ash.Resource` modules, applying any configured `field_aliases`.
    """
    @spec pull_fields(Ash.Resource.t() | [Ash.Resource.t()]) :: [atom()]
    def pull_fields(resources) when is_list(resources) do
      resources
      |> Enum.flat_map(&pull_fields/1)
      |> Enum.uniq()
    end

    def pull_fields(resource) do
      aliases = xitdb_field_aliases!(resource)

      ([:id] ++ xitdb_editable_fields!(resource) ++ xitdb_passthru_fields!(resource))
      |> Enum.map(&Keyword.get(aliases, &1, &1))
      |> Enum.uniq()
    end

    @doc """
    Compiles a structural `Xitdb.Pull` pattern string for one or more `Xitdb.Ash.Resource` modules.
    """
    @spec pull_pattern_for(Ash.Resource.t() | [Ash.Resource.t()]) :: String.t()
    def pull_pattern_for(resource_or_resources) do
      resource_or_resources
      |> pull_fields()
      |> Pull.compile!()
    end

    @doc """
    Resolves the target Xitdb store server from `context[:xitdb_store]`, keyword `opts[:store]`,
    the resource's `xitdb.store` option, or `Application.get_env(:xitdb, :default_store)`.
    """
    @spec resolve_store(Ash.Resource.t(), map() | keyword()) :: GenServer.server() | nil
    def resolve_store(_resource, %{xitdb_store: store}) when not is_nil(store), do: store

    def resolve_store(resource, opts) when is_list(opts) do
      Keyword.get_lazy(opts, :store, fn -> default_store(resource) end)
    end

    def resolve_store(resource, _), do: default_store(resource)

    @doc """
    Resolves the `Ash.Resource.Change` module for locking/unlocking fields from the
    resource's `xitdb.lock_change` option or `Application.get_env(:xitdb, :default_lock_change)`.
    """
    @spec resolve_lock_change(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
    def resolve_lock_change(resource_or_dsl) do
      case xitdb_lock_change(resource_or_dsl) do
        {:ok, mod} when not is_nil(mod) -> mod
        _ -> Application.get_env(:xitdb, :default_lock_change)
      end
    end

    defp default_store(resource) do
      case xitdb_store(resource) do
        {:ok, store} when not is_nil(store) -> store
        _ -> Application.get_env(:xitdb, :default_store)
      end
    end
  end
end
