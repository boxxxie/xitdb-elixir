if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Info do
    @moduledoc """
    Compile-time and runtime introspection helpers for `Xitdb.Ash.DataLayer`,
    `Xitdb.Ash.Dsl`, and `Xitdb.Ash.Resource`.
    """

    use Spark.InfoGenerator,
      extension: Xitdb.Ash.Resource,
      sections: [:xitdb]

    alias Spark.Dsl.Extension
    alias Xitdb.Ash.{Index, NestedIn, Reference, SearchField}
    alias Xitdb.Pull

    @type resource_or_dsl :: Ash.Resource.t() | Spark.Dsl.t()

    # ==========================================================================
    # Shared & DataLayer Persisted Introspection Helpers
    # ==========================================================================

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
    Returns steward-editable field atoms declared on `resource_or_dsl`.
    """
    @spec editable_fields(resource_or_dsl()) :: [atom()]
    def editable_fields(resource_or_dsl) do
      Extension.get_opt(resource_or_dsl, [:xitdb], :editable_fields, [])
    end

    @doc """
    Returns passthrough field atoms declared on `resource_or_dsl`.
    """
    @spec passthru_fields(resource_or_dsl()) :: [atom()]
    def passthru_fields(resource_or_dsl) do
      Extension.get_opt(resource_or_dsl, [:xitdb], :passthru_fields, [])
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

    Note: Uses `:xitdb_nesting_plan` so it never collides with `Xitdb.Ash.Resource`'s
    `:xitdb_nested_in` list (`nested_mappings/1`).
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

    # ==========================================================================
    # v1.0.2 MDM Sync-Projection & Companion Pair Helpers (100% Preserved)
    # ==========================================================================

    @doc """
    Returns the deduplicated list of editable and computed Xitdb field names as strings
    for one or more `Xitdb.Ash.Resource` modules, applying any configured `field_aliases`.
    """
    @spec editable_field_strings(Ash.Resource.t() | [Ash.Resource.t()]) :: [String.t()]
    def editable_field_strings([resource]), do: editable_field_strings(resource)

    def editable_field_strings([a, b]) when is_atom(a) and is_atom(b) do
      cached_pair(:editable_field_strings, a, b, fn ->
        Enum.uniq(editable_field_strings(a) ++ editable_field_strings(b))
      end)
    end

    def editable_field_strings(resources) when is_list(resources) do
      resources
      |> Enum.flat_map(&editable_field_strings/1)
      |> Enum.uniq()
    end

    def editable_field_strings(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_editable_field_strings__,
        :xitdb_editable_field_strings,
        &compute_editable_field_strings/1
      )
    end

    def editable_field_strings(dsl_state), do: compute_editable_field_strings(dsl_state)

    @doc false
    def compute_editable_field_strings(resource_or_dsl) do
      aliases = Extension.get_opt(resource_or_dsl, [:xitdb], :field_aliases, [])
      editable = Extension.get_opt(resource_or_dsl, [:xitdb], :editable_fields, [])
      computed = Extension.get_opt(resource_or_dsl, [:xitdb], :computed_xitdb_fields, [])

      (editable ++ computed)
      |> Enum.map(fn attr -> to_string(Keyword.get(aliases, attr, attr)) end)
      |> Enum.uniq()
    end

    @doc """
    Returns the deduplicated list of Xitdb slot atoms (`[:id | editable ++ passthru]`)
    for one or more `Xitdb.Ash.Resource` modules, applying any configured `field_aliases`.
    """
    @spec pull_fields(Ash.Resource.t() | [Ash.Resource.t()]) :: [atom()]
    def pull_fields([resource]), do: pull_fields(resource)

    def pull_fields([a, b]) when is_atom(a) and is_atom(b) do
      cached_pair(:pull_fields, a, b, fn ->
        Enum.uniq(pull_fields(a) ++ pull_fields(b))
      end)
    end

    def pull_fields(resources) when is_list(resources) do
      resources
      |> Enum.flat_map(&pull_fields/1)
      |> Enum.uniq()
    end

    def pull_fields(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_pull_fields__,
        :xitdb_pull_fields,
        &compute_pull_fields/1
      )
    end

    def pull_fields(dsl_state), do: compute_pull_fields(dsl_state)

    @doc false
    def compute_pull_fields(resource_or_dsl) do
      aliases = Extension.get_opt(resource_or_dsl, [:xitdb], :field_aliases, [])
      editable = Extension.get_opt(resource_or_dsl, [:xitdb], :editable_fields, [])
      passthru = Extension.get_opt(resource_or_dsl, [:xitdb], :passthru_fields, [])

      ([:id] ++ editable ++ passthru)
      |> Enum.map(&Keyword.get(aliases, &1, &1))
      |> Enum.uniq()
    end

    @doc """
    Compiles a structural `Xitdb.Pull` pattern string for one or more `Xitdb.Ash.Resource` modules.
    """
    @spec pull_pattern_for(Ash.Resource.t() | [Ash.Resource.t()]) :: String.t()
    def pull_pattern_for([resource]), do: pull_pattern_for(resource)

    def pull_pattern_for([a, b] = pair) when is_atom(a) and is_atom(b) do
      cached_pair(:pull_pattern, a, b, fn ->
        pair |> pull_fields() |> Pull.compile!()
      end)
    end

    def pull_pattern_for(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_pull_pattern__,
        :xitdb_pull_pattern,
        &(&1 |> pull_fields() |> Pull.compile!())
      )
    end

    def pull_pattern_for(resources) do
      resources
      |> pull_fields()
      |> Pull.compile!()
    end

    @doc """
    Returns the MDM `nested_in` declarations (`Xitdb.Ash.NestedIn` structs) of a resource,
    or `[]` for resources stored in their own top-level collection.
    """
    @spec nested_mappings(resource_or_dsl()) :: [NestedIn.t()]
    def nested_mappings(resource) when is_atom(resource) do
      fetch_persisted_or_compute(
        resource,
        :__xitdb_nested_in__,
        :xitdb_nested_in,
        &compute_nested_mappings/1
      )
    end

    def nested_mappings(dsl_state), do: compute_nested_mappings(dsl_state)

    @doc false
    def compute_nested_mappings(resource_or_dsl) do
      for %NestedIn{parent: parent} = mapping <- Extension.get_entities(resource_or_dsl, [:xitdb]),
          not is_nil(parent) do
        %NestedIn{mapping | __identifier__: nil, __spark_metadata__: nil}
      end
    end

    @doc "Returns `true` when the resource is stored inside a parent entity."
    @spec nested?(resource_or_dsl()) :: boolean()
    def nested?(resource_or_dsl) do
      nested_in(resource_or_dsl) != nil or nested_mappings(resource_or_dsl) != []
    end

    @doc """
    Filters `resources` down to those nested in `parent`, returning
    `{resource, %Xitdb.Ash.NestedIn{}}` pairs.
    """
    @spec nested_under([Ash.Resource.t()], Ash.Resource.t()) ::
            [{Ash.Resource.t(), NestedIn.t()}]
    def nested_under(resources, parent) when is_list(resources) and is_atom(parent) do
      for resource <- resources,
          %NestedIn{parent: ^parent} = mapping <- nested_mappings(resource) do
        {resource, mapping}
      end
    end

    @doc """
    Returns every Xitdb path (a list of string keys from the root) where `record` is stored.
    """
    @spec entity_paths(Ash.Resource.t(), map()) :: [[String.t()]]
    def entity_paths(resource, record) when is_atom(resource) and is_map(record) do
      case nested_mappings(resource) do
        [] ->
          with {:ok, col} <- fetch_collection(resource),
               id when not is_nil(id) and id != "" <- fetch_record_value(record, :id) do
            [[to_string(col), to_string(id)]]
          else
            _ -> []
          end

        mappings ->
          Enum.flat_map(mappings, &nested_entity_path(&1, record))
      end
    end

    defp nested_entity_path(%NestedIn{} = mapping, record) do
      parent_collection = collection(mapping.parent)
      parent_id = fetch_record_value(record, mapping.parent_key)

      cond do
        is_nil(parent_collection) ->
          raise ArgumentError,
                "#{inspect(mapping.parent)} has no top-level `collection`; `nested_in` parents must be top-level resources."

        blank?(parent_id) ->
          []

        mapping.cardinality == :one ->
          [[to_string(parent_collection), to_string(parent_id), to_string(mapping.as)]]

        true ->
          case fetch_record_value(record, mapping.key) do
            entry_key when is_nil(entry_key) or entry_key == "" ->
              []

            entry_key ->
              [
                [
                  to_string(parent_collection),
                  to_string(parent_id),
                  to_string(mapping.as),
                  to_string(entry_key)
                ]
              ]
          end
      end
    end

    defp fetch_record_value(_record, nil), do: nil

    defp fetch_record_value(record, key) when is_atom(key) do
      case Map.get(record, key) do
        nil -> Map.get(record, Atom.to_string(key))
        val -> val
      end
    end

    defp blank?(nil), do: true
    defp blank?(""), do: true
    defp blank?(_), do: false

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

    @doc """
    Resolves the `Ash.Resource.Change` module for locking/unlocking fields from the
    resource's `xitdb.lock_change` option or `Application.get_env(:xitdb, :default_lock_change)`.
    """
    @spec resolve_lock_change(resource_or_dsl()) :: module() | nil
    def resolve_lock_change(resource) when is_atom(resource) do
      resolve_option_with_env(
        resource,
        :__xitdb_lock_change__,
        :xitdb_lock_change,
        &Extension.fetch_opt(&1, [:xitdb], :lock_change),
        :default_lock_change
      )
    end

    def resolve_lock_change(dsl_state) do
      case Extension.fetch_opt(dsl_state, [:xitdb], :lock_change) do
        {:ok, mod} when not is_nil(mod) -> mod
        _ -> Application.get_env(:xitdb, :default_lock_change)
      end
    end

    defp default_store(resource) when is_atom(resource) do
      resolve_option_with_env(
        resource,
        :__xitdb_store__,
        :xitdb_store,
        &Extension.fetch_opt(&1, [:xitdb], :store),
        :default_store
      )
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

    defp resolve_option_with_env(resource, callback, persisted_key, dsl_fetcher, env_key) do
      configured =
        fetch_persisted_or_compute(resource, callback, persisted_key, fn res ->
          case dsl_fetcher.(res) do
            {:ok, val} -> val
            _ -> nil
          end
        end)

      configured || Application.get_env(:xitdb, env_key)
    end

    defp cached_pair(kind, a, b, compute_fun) do
      key = {__MODULE__, :pair, kind, a, b}

      case :persistent_term.get(key, :__miss__) do
        :__miss__ ->
          val = compute_fun.()

          if Code.ensure_loaded?(a) and function_exported?(a, :__xitdb_pull_fields__, 0) and
               Code.ensure_loaded?(b) and function_exported?(b, :__xitdb_pull_fields__, 0) do
            :persistent_term.put(key, val)
          end

          val

        cached ->
          cached
      end
    end

    @doc false
    def __purge_pair_cache__(module) when is_atom(module) do
      for {{__MODULE__, :pair, _kind, a, b} = key, _val} <- :persistent_term.get(),
          a == module or b == module do
        :persistent_term.erase(key)
      end

      :ok
    end
  end
end
