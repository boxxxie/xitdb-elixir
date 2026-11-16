if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Info do
    @moduledoc """
    Compile-time and runtime introspection helpers for `Xitdb.Ash.DataLayer`
    and `Xitdb.Ash.Dsl`.
    """

    alias Spark.Dsl.Extension
    alias Xitdb.Ash.{Index, NestedIn, Reference, SearchField}

    @type resource_or_dsl :: Ash.Resource.t() | Spark.Dsl.t()

    @doc """
    Returns the configured `Xitdb.Ash.Store` module for `resource_or_dsl`, or `nil` if undeclared.
    """
    @spec store(resource_or_dsl()) :: module() | nil
    def store(resource_or_dsl) do
      resolve_store(resource_or_dsl, [])
    end

    @doc """
    Fetches `{:ok, store_mod}` when a `xitdb.store` (or `:default_store`) is configured, or `:error`.
    """
    @spec fetch_store(resource_or_dsl()) :: {:ok, module()} | :error
    def fetch_store(resource_or_dsl) do
      case store(resource_or_dsl) do
        store_mod when is_atom(store_mod) and not is_nil(store_mod) -> {:ok, store_mod}
        _ -> :error
      end
    end

    @doc """
    Returns the configured `Xitdb.Ash.Store` module for `resource_or_dsl`, raising `ArgumentError` if undeclared.
    """
    @spec store!(resource_or_dsl()) :: module()
    def store!(resource_or_dsl) do
      case fetch_store(resource_or_dsl) do
        {:ok, store_mod} ->
          store_mod

        :error ->
          raise ArgumentError, "Resource #{inspect(resource_or_dsl)} does not declare a store"
      end
    end

    @doc """
    Returns the primary Xitdb collection atom for `resource_or_dsl`, or `nil` if undeclared.
    """
    @spec collection(resource_or_dsl()) :: atom() | nil
    def collection(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_collection__,
        :xitdb_collection,
        &collection_from_dsl/1
      )
    end

    def collection(dsl_state), do: collection_from_dsl(dsl_state)

    defp collection_from_dsl(resource_or_dsl) do
      case Extension.fetch_opt(resource_or_dsl, [:xitdb], :collection) do
        {:ok, col} when is_atom(col) and not is_nil(col) -> col
        _ -> nil
      end
    end

    @doc """
    Fetches `{:ok, collection}` when `xitdb.collection` is configured, or `:error`.
    """
    @spec fetch_collection(resource_or_dsl()) :: {:ok, atom()} | :error
    def fetch_collection(resource_or_dsl) do
      case collection(resource_or_dsl) do
        col when is_atom(col) and not is_nil(col) -> {:ok, col}
        _ -> :error
      end
    end

    @doc """
    Returns the primary Xitdb collection atom for `resource_or_dsl`, raising `ArgumentError` if undeclared.
    """
    @spec collection!(resource_or_dsl()) :: atom()
    def collection!(resource_or_dsl) do
      case fetch_collection(resource_or_dsl) do
        {:ok, col} ->
          col

        :error ->
          raise ArgumentError,
                "Resource #{inspect(resource_or_dsl)} does not declare a collection"
      end
    end

    @doc """
    Returns attributes configured as `:counted_hash_set` slots on `resource_or_dsl`.
    """
    @spec counted_set_fields(resource_or_dsl()) :: [atom()]
    def counted_set_fields(resource_or_dsl) do
      Extension.get_opt(resource_or_dsl, [:xitdb], :counted_set_fields, [])
    end

    @doc """
    Returns whether `belongs_to` foreign keys are indexed automatically on `resource_or_dsl`.
    """
    @spec index_relationships?(resource_or_dsl()) :: boolean()
    def index_relationships?(resource_or_dsl) do
      Extension.get_opt(resource_or_dsl, [:xitdb], :index_relationships?, true)
    end

    @doc """
    Returns the `%Xitdb.Ash.NestedIn{}` subtree plan if `resource_or_dsl` uses DataLayer
    co-located nesting (`:xitdb_nesting_plan`), or `nil`.
    """
    @spec nested_in(resource_or_dsl()) :: NestedIn.t() | nil
    def nested_in(resource_or_dsl) do
      case Extension.get_persisted(resource_or_dsl, :xitdb_nesting_plan, :__not_persisted__) do
        :__not_persisted__ ->
          resource_or_dsl
          |> Extension.get_entities([:xitdb])
          |> Enum.find(fn
            %NestedIn{parent_collection: pc} when not is_nil(pc) -> true
            _ -> false
          end)
          |> case do
            %NestedIn{} = n -> %NestedIn{n | __identifier__: nil, __spark_metadata__: nil}
            nil -> nil
          end

        persisted ->
          persisted
      end
    end

    @doc "Returns `true` when the resource is stored inside a parent entity."
    @spec nested?(resource_or_dsl()) :: boolean()
    def nested?(resource_or_dsl) do
      nested_in(resource_or_dsl) != nil
    end

    @doc """
    Returns all explicit and auto-generated `%Xitdb.Ash.Index{}` definitions for `resource_or_dsl`.
    """
    @spec indexes(resource_or_dsl()) :: [Index.t()]
    def indexes(resource_or_dsl) do
      case Extension.get_persisted(resource_or_dsl, :xitdb_indexes, :__not_persisted__) do
        :__not_persisted__ ->
          for %Index{} = idx <- Extension.get_entities(resource_or_dsl, [:xitdb]) do
            %Index{idx | __identifier__: nil, __spark_metadata__: nil}
          end

        persisted ->
          persisted
      end
    end

    @doc """
    Returns secondary indexes whose leading column is `field`, ordered from narrowest
    (single-column `[field]`) to widest composite index for the Stage 1 query planner.
    """
    @spec indexes_for_field(resource_or_dsl(), atom()) :: [Index.t()]
    def indexes_for_field(resource_or_dsl, field) when is_atom(field) do
      resource_or_dsl
      |> indexes()
      |> Enum.filter(fn %Index{fields: [leading | _]} -> leading == field end)
      |> Enum.sort_by(fn %Index{fields: fields} -> length(fields) end)
    end

    @doc """
    Returns all `%Xitdb.Ash.SearchField{}` definitions for `resource_or_dsl`.
    """
    @spec search_fields(resource_or_dsl()) :: [SearchField.t()]
    def search_fields(resource_or_dsl) do
      case Extension.get_persisted(resource_or_dsl, :xitdb_search_fields, :__not_persisted__) do
        :__not_persisted__ ->
          for %SearchField{} = sf <- Extension.get_entities(resource_or_dsl, [:xitdb]) do
            %SearchField{sf | __identifier__: nil, __spark_metadata__: nil}
          end

        persisted ->
          persisted
      end
    end

    @doc """
    Returns outgoing `%Xitdb.Ash.Reference{}` foreign-key rules declared on `resource_or_dsl`.
    """
    @spec references(resource_or_dsl()) :: [Reference.t()]
    def references(resource_or_dsl) do
      case Extension.get_persisted(resource_or_dsl, :xitdb_references, :__not_persisted__) do
        :__not_persisted__ ->
          for %Reference{} = ref <- Extension.get_entities(resource_or_dsl, [:xitdb, :references]) do
            %Reference{ref | __identifier__: nil, __spark_metadata__: nil}
          end

        persisted ->
          persisted
      end
    end

    @doc """
    Resolves the target Xitdb store server from `context[:xitdb_store]`, keyword `opts[:store]`,
    the resource's `xitdb.store` option, or `Application.get_env(:xitdb, :default_store)`.
    """
    @spec resolve_store(resource_or_dsl(), map() | keyword()) :: GenServer.server() | nil
    def resolve_store(_resource, %{xitdb_store: store}) when not is_nil(store), do: store

    def resolve_store(resource, opts) when is_list(opts) do
      Keyword.get_lazy(opts, :store, fn -> default_store(resource) end)
    end

    def resolve_store(resource, _), do: default_store(resource)

    defp default_store(resource) when is_atom(resource) do
      configured =
        fetch_persisted_or_compute(resource, :__xitdb_store__, :xitdb_store, fn res ->
          case Extension.fetch_opt(res, [:xitdb], :store) do
            {:ok, store} -> store
            _ -> nil
          end
        end)

      configured || Application.get_env(:xitdb, :default_store)
    end

    defp default_store(dsl_state) do
      case Extension.fetch_opt(dsl_state, [:xitdb], :store) do
        {:ok, store} when not is_nil(store) -> store
        _ -> Application.get_env(:xitdb, :default_store)
      end
    end

    defp fetch_persisted_or_compute(resource, callback, persisted_key, compute_fun) do
      if Code.ensure_loaded?(resource) and function_exported?(resource, callback, 0) do
        apply(resource, callback, [])
      else
        case Extension.get_persisted(resource, persisted_key, :__not_persisted__) do
          :__not_persisted__ -> compute_fun.(resource)
          cached -> cached
        end
      end
    end
  end
end
