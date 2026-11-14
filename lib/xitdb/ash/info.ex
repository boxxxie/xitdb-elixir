if Code.ensure_loaded?(Spark.InfoGenerator) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Info do
    @moduledoc """
    Compile-time and runtime introspection helpers for `Xitdb.Ash.Resource`.
    """
    use Spark.InfoGenerator,
      extension: Xitdb.Ash.Resource,
      sections: [:xitdb]

    alias Spark.Dsl.Extension
    alias Xitdb.Pull

    @doc """
    Returns the list of `search_field` declarations for a resource.
    """
    @spec search_fields(Ash.Resource.t() | Spark.Dsl.t()) :: [Xitdb.Ash.SearchField.t()]
    def search_fields(resource_or_dsl) do
      resource_or_dsl
      |> Extension.get_entities([:xitdb])
      |> Enum.filter(&match?(%Xitdb.Ash.SearchField{}, &1))
      |> Enum.map(&%{&1 | __identifier__: nil, __spark_metadata__: nil})
    end

    @doc """
    Returns the list of explicit `index` declarations for a resource.
    """
    @spec indexes(Ash.Resource.t() | Spark.Dsl.t()) :: [Xitdb.Ash.Index.t()]
    def indexes(resource_or_dsl) do
      resource_or_dsl
      |> Extension.get_entities([:xitdb])
      |> Enum.filter(&match?(%Xitdb.Ash.Index{}, &1))
      |> Enum.map(&%{&1 | __identifier__: nil, __spark_metadata__: nil})
    end

    @doc """
    Returns the list of `reference` declarations for a resource.
    """
    @spec references(Ash.Resource.t() | Spark.Dsl.t()) :: [Xitdb.Ash.Reference.t()]
    def references(resource_or_dsl) do
      resource_or_dsl
      |> Extension.get_entities([:xitdb, :references])
      |> Enum.filter(&match?(%Xitdb.Ash.Reference{}, &1))
      |> Enum.map(&%{&1 | __identifier__: nil, __spark_metadata__: nil})
    end

    @doc """
    Returns the primary Xitdb collection atom for `resource`, raising if undeclared.
    """
    @spec collection!(Ash.Resource.t() | Spark.Dsl.t()) :: atom()
    def collection!(resource_or_dsl) do
      case xitdb_collection(resource_or_dsl) do
        {:ok, col} when not is_nil(col) ->
          col

        _ ->
          case xitdb_collection!(resource_or_dsl) do
            col when not is_nil(col) ->
              col

            _ ->
              raise ArgumentError,
                    "Resource #{inspect(resource_or_dsl)} does not declare a collection"
          end
      end
    end

    @doc """
    Returns the primary Xitdb collection atom for `resource`, or `nil` if undeclared.
    """
    @spec collection(Ash.Resource.t() | Spark.Dsl.t()) :: atom() | nil
    def collection(resource_or_dsl) do
      case xitdb_collection(resource_or_dsl) do
        {:ok, col} -> col
        _ -> nil
      end
    end

    @doc """
    Returns the configured store module for `resource`, raising if undeclared.
    """
    @spec store!(Ash.Resource.t() | Spark.Dsl.t()) :: module()
    def store!(resource_or_dsl) do
      case resolve_store(resource_or_dsl, []) do
        store when not is_nil(store) ->
          store

        nil ->
          raise ArgumentError, "Resource #{inspect(resource_or_dsl)} does not declare a store"
      end
    end

    @doc """
    Returns the configured store module for `resource`, or `nil` if undeclared.
    """
    @spec store(Ash.Resource.t() | Spark.Dsl.t()) :: module() | nil
    def store(resource_or_dsl) do
      resolve_store(resource_or_dsl, [])
    end

    @doc """
    Returns the deduplicated list of editable and computed Xitdb field names as strings
    for one or more `Xitdb.Ash.Resource` modules, applying any configured `field_aliases`.
    """
    @spec editable_field_strings(Ash.Resource.t() | [Ash.Resource.t()]) :: [String.t()]
    def editable_field_strings([resource]), do: editable_field_strings(resource)

    def editable_field_strings([a, b]) when is_atom(a) and is_atom(b) do
      case pair_lookup(a, b, :__xitdb_pair_editable_field_strings__) do
        nil -> Enum.uniq(editable_field_strings(a) ++ editable_field_strings(b))
        res -> res
      end
    end

    def editable_field_strings(resources) when is_list(resources) do
      resources
      |> Enum.flat_map(&editable_field_strings/1)
      |> Enum.uniq()
    end

    def editable_field_strings(resource) when is_atom(resource) do
      if function_exported?(resource, :__xitdb_editable_field_strings__, 0) do
        resource.__xitdb_editable_field_strings__()
      else
        case Extension.get_persisted(resource, :xitdb_editable_field_strings, nil) do
          nil -> compute_editable_field_strings(resource)
          cached -> cached
        end
      end
    end

    def editable_field_strings(dsl_state), do: compute_editable_field_strings(dsl_state)

    @doc false
    def compute_editable_field_strings(resource_or_dsl) do
      aliases = xitdb_field_aliases!(resource_or_dsl)

      resource_or_dsl
      |> xitdb_editable_fields!()
      |> Enum.concat(xitdb_computed_xitdb_fields!(resource_or_dsl))
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
      case pair_lookup(a, b, :__xitdb_pair_pull_fields__) do
        nil -> Enum.uniq(pull_fields(a) ++ pull_fields(b))
        res -> res
      end
    end

    def pull_fields(resources) when is_list(resources) do
      resources
      |> Enum.flat_map(&pull_fields/1)
      |> Enum.uniq()
    end

    def pull_fields(resource) when is_atom(resource) do
      if function_exported?(resource, :__xitdb_pull_fields__, 0) do
        resource.__xitdb_pull_fields__()
      else
        case Extension.get_persisted(resource, :xitdb_pull_fields, nil) do
          nil -> compute_pull_fields(resource)
          cached -> cached
        end
      end
    end

    def pull_fields(dsl_state), do: compute_pull_fields(dsl_state)

    @doc false
    def compute_pull_fields(resource_or_dsl) do
      aliases = xitdb_field_aliases!(resource_or_dsl)

      ([:id] ++ xitdb_editable_fields!(resource_or_dsl) ++ xitdb_passthru_fields!(resource_or_dsl))
      |> Enum.map(&Keyword.get(aliases, &1, &1))
      |> Enum.uniq()
    end

    @doc """
    Compiles a structural `Xitdb.Pull` pattern string for one or more `Xitdb.Ash.Resource` modules.
    """
    @spec pull_pattern_for(Ash.Resource.t() | [Ash.Resource.t()]) :: String.t()
    def pull_pattern_for([resource]), do: pull_pattern_for(resource)

    def pull_pattern_for([a, b] = pair) when is_atom(a) and is_atom(b) do
      case pair_lookup(a, b, :__xitdb_pair_pull_pattern__) do
        nil -> pair |> pull_fields() |> Pull.compile!()
        res -> res
      end
    end

    def pull_pattern_for(resource) when is_atom(resource) do
      if function_exported?(resource, :__xitdb_pull_pattern__, 0) do
        resource.__xitdb_pull_pattern__()
      else
        case Extension.get_persisted(resource, :xitdb_pull_pattern, nil) do
          nil -> resource |> pull_fields() |> Pull.compile!()
          cached -> cached
        end
      end
    end

    def pull_pattern_for(resources) do
      resources
      |> pull_fields()
      |> Pull.compile!()
    end

    @doc """
    Returns the `nested_in` declarations (`Xitdb.Ash.NestedIn` structs) of a resource,
    or `[]` for resources stored in their own top-level collection.
    """
    @spec nested_mappings(Ash.Resource.t() | Spark.Dsl.t()) :: [Xitdb.Ash.NestedIn.t()]
    def nested_mappings(resource) when is_atom(resource) do
      if function_exported?(resource, :__xitdb_nested_in__, 0) do
        resource.__xitdb_nested_in__()
      else
        compute_nested_mappings(resource)
      end
    end

    def nested_mappings(dsl_state), do: compute_nested_mappings(dsl_state)

    @doc false
    def compute_nested_mappings(resource_or_dsl) do
      resource_or_dsl
      |> Extension.get_entities([:xitdb])
      |> Enum.filter(&match?(%Xitdb.Ash.NestedIn{}, &1))
      |> Enum.map(&%{&1 | __identifier__: nil, __spark_metadata__: nil})
    end

    @doc "Returns `true` when the resource is stored inside a parent entity."
    @spec nested?(Ash.Resource.t() | Spark.Dsl.t()) :: boolean()
    def nested?(resource), do: nested_mappings(resource) != []

    @doc """
    Filters `resources` down to those nested in `parent`, returning
    `{resource, %Xitdb.Ash.NestedIn{}}` pairs.

    Parents cannot discover their children at compile time without creating dependency
    cycles, so callers pass the candidate list explicitly.
    """
    @spec nested_under([Ash.Resource.t()], Ash.Resource.t()) ::
            [{Ash.Resource.t(), Xitdb.Ash.NestedIn.t()}]
    def nested_under(resources, parent) when is_list(resources) and is_atom(parent) do
      for resource <- resources,
          %Xitdb.Ash.NestedIn{parent: ^parent} = mapping <- nested_mappings(resource) do
        {resource, mapping}
      end
    end

    @doc """
    Returns every Xitdb path (a list of string keys from the root) where `record` is stored.

    - Top-level resources return `[[collection, id]]` when `record` has an `:id`.
    - Nested resources return one path per `nested_in` declaration whose `parent_key`
      (and `key`, for `cardinality: :many`) is present on `record`. A phone owned by a
      user returns `[["people", "42", "phones", "+14165550199"]]`.

    `record` may be a struct or a map with atom or string keys.
    """
    @spec entity_paths(Ash.Resource.t(), map()) :: [[String.t()]]
    def entity_paths(resource, record) when is_atom(resource) and is_map(record) do
      case nested_mappings(resource) do
        [] ->
          with {:ok, collection} when not is_nil(collection) <- xitdb_collection(resource),
               id when not is_nil(id) and id != "" <- fetch_record_value(record, :id) do
            [[to_string(collection), to_string(id)]]
          else
            _ -> []
          end

        mappings ->
          Enum.flat_map(mappings, &nested_entity_path(&1, record))
      end
    end

    defp nested_entity_path(%Xitdb.Ash.NestedIn{} = mapping, record) do
      parent_collection =
        case xitdb_collection(mapping.parent) do
          {:ok, collection} -> collection
          _ -> nil
        end

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
    def resolve_lock_change(resource) when is_atom(resource) do
      if function_exported?(resource, :__xitdb_lock_change__, 0) do
        resource.__xitdb_lock_change__() || Application.get_env(:xitdb, :default_lock_change)
      else
        case Extension.get_persisted(resource, :xitdb_lock_change, :__not_persisted__) do
          :__not_persisted__ -> resolve_lock_change_from_dsl(resource)
          nil -> Application.get_env(:xitdb, :default_lock_change)
          mod -> mod
        end
      end
    end

    def resolve_lock_change(dsl_state), do: resolve_lock_change_from_dsl(dsl_state)

    defp resolve_lock_change_from_dsl(resource_or_dsl) do
      case xitdb_lock_change(resource_or_dsl) do
        {:ok, mod} when not is_nil(mod) -> mod
        _ -> Application.get_env(:xitdb, :default_lock_change)
      end
    end

    defp default_store(resource) when is_atom(resource) do
      if function_exported?(resource, :__xitdb_store__, 0) do
        resource.__xitdb_store__() || Application.get_env(:xitdb, :default_store)
      else
        case Extension.get_persisted(resource, :xitdb_store, :__not_persisted__) do
          :__not_persisted__ -> default_store_from_dsl(resource)
          nil -> Application.get_env(:xitdb, :default_store)
          store -> store
        end
      end
    end

    defp default_store(dsl_state), do: default_store_from_dsl(dsl_state)

    defp default_store_from_dsl(resource_or_dsl) do
      case xitdb_store(resource_or_dsl) do
        {:ok, store} when not is_nil(store) -> store
        _ -> Application.get_env(:xitdb, :default_store)
      end
    end

    defp pair_lookup(a, b, fun_name) do
      res_a =
        if function_exported?(a, fun_name, 2) do
          apply(a, fun_name, [b, :self_first])
        else
          nil
        end

      if not is_nil(res_a) do
        res_a
      else
        if function_exported?(b, fun_name, 2) do
          apply(b, fun_name, [a, :other_first])
        else
          nil
        end
      end
    end
  end
end
