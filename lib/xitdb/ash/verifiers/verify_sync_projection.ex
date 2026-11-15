if Code.ensure_loaded?(Spark.Dsl.Verifier) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Verifiers.VerifySyncProjection do
    @moduledoc """
    Verifies at compile time that:
    1. Every attribute accepted by `xitdb.sync_update_action` (that is not in
       `xitdb.ignored_sync_attributes`) is declared in `xitdb.editable_fields`
       or `xitdb.passthru_fields` (preventing silent field drops during Xitdb ingestion).
    2. Every declared `editable_fields` / `passthru_fields` entry exists on the resource.
    3. Every `indexes` key maps to a known projected or computed field.
    4. The resource declares either a top-level `collection` or at least one `nested_in`,
       every `nested_in` `parent_key` / `key` is an attribute, `cardinality: :many`
       declarations name a `key`, and nested resources declare no secondary `indexes`.
    """
    use Spark.Dsl.Verifier

    alias Ash.Resource.Info, as: ResourceInfo
    alias Spark.Dsl.Verifier
    alias Spark.Error.DslError
    alias Xitdb.Ash.Info, as: XitdbInfo

    @impl true
    def verify(dsl_state) do
      module = Verifier.get_persisted(dsl_state, :module)
      editable = XitdbInfo.xitdb_editable_fields!(dsl_state)
      passthru = XitdbInfo.xitdb_passthru_fields!(dsl_state)
      computed = XitdbInfo.xitdb_computed_xitdb_fields!(dsl_state)
      aliases = XitdbInfo.xitdb_field_aliases!(dsl_state)
      sync_action_name = XitdbInfo.xitdb_sync_update_action!(dsl_state)
      ignored_attrs = XitdbInfo.xitdb_ignored_sync_attributes!(dsl_state)

      projected_set = MapSet.new(editable ++ passthru)

      with :ok <- verify_storage_location(dsl_state, module, computed),
           :ok <- verify_attributes_exist(dsl_state, module, projected_set),
           :ok <-
             verify_sync_action_covered(
               dsl_state,
               module,
               sync_action_name,
               projected_set,
               ignored_attrs
             ) do
        verify_indexes_covered(dsl_state, module, projected_set, computed, aliases)
      end
    end

    defp verify_storage_location(dsl_state, module, computed) do
      collection =
        case XitdbInfo.xitdb_collection(dsl_state) do
          {:ok, col} -> col
          _ -> nil
        end

      mappings = XitdbInfo.compute_nested_mappings(dsl_state)

      cond do
        is_nil(collection) and mappings == [] ->
          dsl_error(
            module,
            [:xitdb],
            "#{inspect(module)} must declare either a top-level `collection` or at least one `nested_in`."
          )

        not is_nil(collection) and mappings != [] ->
          dsl_error(
            module,
            [:xitdb],
            "#{inspect(module)} declares both `collection` and `nested_in`; choose one storage location."
          )

        mappings != [] and
            (XitdbInfo.xitdb_indexes!(dsl_state) != [] or
               Enum.any?(
                 Spark.Dsl.Extension.get_entities(dsl_state, [:xitdb]),
                 &match?(%Xitdb.Ash.Index{}, &1)
               )) ->
          dsl_error(
            module,
            [:xitdb, :indexes],
            "Secondary `indexes` are only supported on top-level collections, not on `nested_in` resources."
          )

        true ->
          Enum.reduce_while(mappings, :ok, fn mapping, :ok ->
            case verify_nested_mapping(dsl_state, module, mapping, computed) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
      end
    end

    defp verify_nested_mapping(dsl_state, module, mapping, computed) do
      cond do
        mapping.cardinality == :many and is_nil(mapping.key) ->
          dsl_error(
            module,
            [:xitdb, :nested_in],
            "`nested_in #{inspect(mapping.parent)}, as: #{inspect(mapping.as)}` uses `cardinality: :many` and must declare a `key`."
          )

        not valid_mapping_key?(dsl_state, mapping.parent_key, computed) ->
          dsl_error(
            module,
            [:xitdb, :nested_in],
            "`parent_key` #{inspect(mapping.parent_key)} does not exist as an attribute or computed_xitdb_field on #{inspect(module)}."
          )

        not is_nil(mapping.key) and not valid_mapping_key?(dsl_state, mapping.key, computed) ->
          dsl_error(
            module,
            [:xitdb, :nested_in],
            "`key` #{inspect(mapping.key)} does not exist as an attribute or computed_xitdb_field on #{inspect(module)}."
          )

        is_atom(mapping.parent) and Code.ensure_loaded?(mapping.parent) and
            XitdbInfo.nested?(mapping.parent) ->
          dsl_error(
            module,
            [:xitdb, :nested_in],
            "multi-level `nested_in` is not supported: parent #{inspect(mapping.parent)} is itself nested."
          )

        true ->
          :ok
      end
    end

    defp valid_mapping_key?(dsl_state, key, computed) do
      not is_nil(ResourceInfo.attribute(dsl_state, key)) or key in computed
    end

    defp dsl_error(module, path, message) do
      {:error, DslError.exception(module: module, path: path, message: message)}
    end

    defp verify_attributes_exist(dsl_state, module, projected_set) do
      Enum.reduce_while(projected_set, :ok, fn field, :ok ->
        if ResourceInfo.attribute(dsl_state, field) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            DslError.exception(
              module: module,
              path: [:xitdb],
              message:
                "Field #{inspect(field)} in `xitdb` does not exist as an attribute on #{inspect(module)}."
            )}}
        end
      end)
    end

    defp verify_sync_action_covered(dsl_state, module, action_name, projected_set, ignored_attrs) do
      case ResourceInfo.action(dsl_state, action_name) do
        nil ->
          :ok

        %{accept: accept} ->
          missing =
            Enum.reject(accept, &(&1 in ignored_attrs or MapSet.member?(projected_set, &1)))

          if missing == [] do
            :ok
          else
            {:error,
             DslError.exception(
               module: module,
               path: [:actions, :update, action_name],
               message: """
               Action #{inspect(action_name)} on #{inspect(module)} accepts #{inspect(missing)}, \
               but those fields are missing from `xitdb.editable_fields` or `xitdb.passthru_fields`. \
               They will be silently dropped by Xitdb ingestion and reconcilers!
               """
             )}
          end
      end
    end

    defp verify_indexes_covered(dsl_state, module, projected_set, computed, aliases) do
      valid_xitdb_keys =
        projected_set
        |> Enum.map(&Keyword.get(aliases, &1, &1))
        |> Enum.concat(computed)
        |> MapSet.new()

      entities = Spark.Dsl.Extension.get_entities(dsl_state, [:xitdb])

      with :ok <-
             dsl_state
             |> XitdbInfo.xitdb_indexes!()
             |> Keyword.keys()
             |> Enum.reduce_while(:ok, fn idx_field, :ok ->
               if MapSet.member?(valid_xitdb_keys, idx_field) do
                 {:cont, :ok}
               else
                 {:halt,
                  {:error,
                   DslError.exception(
                     module: module,
                     path: [:xitdb, :indexes],
                     message:
                       "Indexed field #{inspect(idx_field)} is not in editable_fields, passthru_fields, or computed_xitdb_fields."
                   )}}
               end
             end),
           :ok <-
             verify_index_entities_covered(dsl_state, module, entities, valid_xitdb_keys, aliases) do
        verify_search_entities_covered(dsl_state, module, entities)
      end
    end

    defp verify_index_entities_covered(dsl_state, module, entities, valid_xitdb_keys, aliases) do
      entities
      |> Enum.filter(&match?(%Xitdb.Ash.Index{}, &1))
      |> Enum.reduce_while(:ok, fn %Xitdb.Ash.Index{fields: fields}, :ok ->
        cond do
          fields == [] ->
            {:halt, dsl_error(module, [:xitdb, :index], "index `fields` cannot be empty.")}

          true ->
            missing =
              Enum.reject(fields, fn f ->
                aliased = Keyword.get(aliases, f, f)

                MapSet.member?(valid_xitdb_keys, aliased) or
                  not is_nil(ResourceInfo.attribute(dsl_state, f))
              end)

            if missing == [] do
              {:cont, :ok}
            else
              {:halt,
               dsl_error(
                 module,
                 [:xitdb, :index, fields],
                 "Indexed field(s) #{inspect(missing)} must exist on #{inspect(module)} or in editable/passthru/computed fields."
               )}
            end
        end
      end)
    end

    defp verify_search_entities_covered(dsl_state, module, entities) do
      entities
      |> Enum.filter(&match?(%Xitdb.Ash.SearchField{}, &1))
      |> Enum.reduce_while(:ok, fn %Xitdb.Ash.SearchField{
                                     field: field,
                                     boost: boost,
                                     resolver: resolver
                                   },
                                   :ok ->
        cond do
          boost <= 0.0 ->
            {:halt,
             dsl_error(
               module,
               [:xitdb, :search_field, field],
               "`search_field` boost must be > 0.0, got: #{inspect(boost)}"
             )}

          is_nil(resolver) and is_nil(ResourceInfo.attribute(dsl_state, field)) ->
            {:halt,
             dsl_error(
               module,
               [:xitdb, :search_field, field],
               "SearchField #{inspect(field)} must match an attribute on #{inspect(module)} or supply a `resolver: fun/2`."
             )}

          true ->
            {:cont, :ok}
        end
      end)
    end
  end
end
