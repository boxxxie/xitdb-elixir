if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Transformers.BuildIndexPlan do
    @moduledoc false
    use Spark.Dsl.Transformer

    alias Spark.Dsl.Transformer
    alias Spark.Error.DslError
    alias Xitdb.Ash.{Index, NestedIn, Reference, SearchField}

    @impl Spark.Dsl.Transformer
    def after?(Ash.Resource.Transformers.BelongsToAttribute), do: true
    def after?(Ash.Resource.Transformers.CreateJoinRelationship), do: true
    def after?(Ash.Resource.Transformers.SetTypes), do: true
    def after?(_other), do: false

    @impl Spark.Dsl.Transformer
    def transform(dsl_state) do
      module = Transformer.get_persisted(dsl_state, :module)
      attributes = Ash.Resource.Info.attributes(dsl_state)
      attrs_by_name = Map.new(attributes, &{&1.name, &1})
      attr_names = MapSet.new(Map.keys(attrs_by_name))
      pk_fields = Ash.Resource.Info.primary_key(dsl_state)

      entities = Transformer.get_entities(dsl_state, [:xitdb])

      references =
        for %Reference{} = r <- Transformer.get_entities(dsl_state, [:xitdb, :references]) do
          %Reference{r | __identifier__: nil, __spark_metadata__: nil}
        end

      nested_entries =
        for %NestedIn{parent_collection: pc} = n <- entities, not is_nil(pc) do
          %NestedIn{n | __identifier__: nil, __spark_metadata__: nil}
        end

      explicit_indexes =
        for %Index{} = i <- entities do
          %Index{i | __identifier__: nil, __spark_metadata__: nil}
        end

      search_fields =
        for %SearchField{} = s <- entities do
          %SearchField{s | __identifier__: nil, __spark_metadata__: nil}
        end

      with {:ok, store} <- validate_store(module, dsl_state),
           {:ok, collection} <- validate_collection(module, dsl_state),
           :ok <- validate_primary_key(module, pk_fields),
           {:ok, nesting_plan} <- validate_nested_in(module, nested_entries, attr_names),
           :ok <- validate_explicit_indexes(module, explicit_indexes, attr_names),
           :ok <- validate_counted_set_fields(module, dsl_state, attrs_by_name),
           :ok <- validate_projected_fields(module, dsl_state, attr_names),
           :ok <- validate_search_fields(module, search_fields, attr_names) do
        all_indexes =
          maybe_append_relationship_indexes(dsl_state, explicit_indexes, pk_fields)

        normalized_indexes = build_tx_for_indexes(collection, all_indexes)

        updated_state =
          dsl_state
          |> Transformer.persist(:xitdb_store, store)
          |> Transformer.persist(:xitdb_collection, collection)
          |> Transformer.persist(:xitdb_nesting_plan, nesting_plan)
          |> Transformer.persist(:xitdb_indexes, all_indexes)
          |> Transformer.persist(:xitdb_search_fields, search_fields)
          |> Transformer.persist(:xitdb_references, references)
          |> Transformer.persist(:xitdb_normalized_indexes, normalized_indexes)
          |> define_direct_callbacks(store, collection, normalized_indexes)

        {:ok, updated_state}
      end
    end

    defp validate_store(module, dsl_state) do
      case Transformer.get_option(dsl_state, [:xitdb], :store) ||
             Application.get_env(:xitdb, :default_store) do
        store when is_atom(store) and not is_nil(store) ->
          {:ok, store}

        _ ->
          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :store],
             message: "#{inspect(module)} must configure `xitdb.store`"
           )}
      end
    end

    defp validate_collection(module, dsl_state) do
      case Transformer.get_option(dsl_state, [:xitdb], :collection) do
        col when is_atom(col) and not is_nil(col) ->
          {:ok, col}

        _ ->
          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :collection],
             message: "#{inspect(module)} must configure `xitdb.collection`"
           )}
      end
    end

    defp validate_primary_key(module, pk_fields) when length(pk_fields) > 1 do
      {:error,
       DslError.exception(
         module: module,
         path: [:attributes],
         message:
           "composite primary keys are not yet supported by Xitdb.Ash.DataLayer (got #{inspect(pk_fields)})"
       )}
    end

    defp validate_primary_key(_module, _pk_fields), do: :ok

    defp validate_nested_in(_module, [], _attr_names), do: {:ok, nil}

    defp validate_nested_in(module, [%NestedIn{foreign_key: fk} = nested], attr_names) do
      if MapSet.member?(attr_names, fk) do
        {:ok, nested}
      else
        {:error,
         DslError.exception(
           module: module,
           path: [:xitdb, :nested_in, nested.parent_collection],
           message:
             "nested_in foreign_key #{inspect(fk)} is not a defined attribute on #{inspect(module)}"
         )}
      end
    end

    defp validate_nested_in(module, [_first, _second | _rest], _attr_names) do
      {:error,
       DslError.exception(
         module: module,
         path: [:xitdb, :nested_in],
         message: "at most one `nested_in` declaration is allowed per resource"
       )}
    end

    defp validate_explicit_indexes(module, indexes, attr_names) do
      indexes
      |> Enum.reduce_while({MapSet.new(), MapSet.new()}, fn %Index{fields: fields, name: name} =
                                                              idx,
                                                            {seen_fields, seen_names} ->
        slot_name = canonical_index_slot_name(idx)

        cond do
          fields == [] ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :index],
                message: "index `fields` cannot be empty"
              )}}

          Enum.any?(fields, &(not MapSet.member?(attr_names, &1))) ->
            missing = Enum.reject(fields, &MapSet.member?(attr_names, &1))

            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :index, fields],
                message:
                  "unknown attribute(s) #{inspect(missing)} in `xitdb.index` on #{inspect(module)}"
              )}}

          MapSet.member?(seen_fields, fields) ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :index, fields],
                message: "duplicate `index #{inspect(fields)}` declaration on #{inspect(module)}"
              )}}

          MapSet.member?(seen_names, slot_name) ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :index, name || fields],
                message:
                  "colliding index slot name #{inspect(slot_name)} in `xitdb.index` on #{inspect(module)}"
              )}}

          true ->
            {:cont, {MapSet.put(seen_fields, fields), MapSet.put(seen_names, slot_name)}}
        end
      end)
      |> case do
        {:error, _} = err -> err
        {_seen_fields, _seen_names} -> :ok
      end
    end

    defp canonical_index_slot_name(%Index{name: name}) when is_atom(name) and not is_nil(name),
      do: Atom.to_string(name)

    defp canonical_index_slot_name(%Index{name: name}) when is_binary(name), do: name
    defp canonical_index_slot_name(%Index{fields: [single]}), do: "attr_#{single}"

    defp canonical_index_slot_name(%Index{fields: fields}) when is_list(fields),
      do: "idx_" <> Enum.map_join(fields, "_", &Atom.to_string/1)

    defp validate_counted_set_fields(module, dsl_state, attrs_by_name) do
      counted_fields = Transformer.get_option(dsl_state, [:xitdb], :counted_set_fields, [])

      Enum.reduce_while(counted_fields, :ok, fn field, :ok ->
        case Map.fetch(attrs_by_name, field) do
          :error ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :counted_set_fields],
                message:
                  "counted_set_fields entry #{inspect(field)} is not a defined attribute on #{inspect(module)}"
              )}}

          {:ok, %{type: {:array, _}}} ->
            {:cont, :ok}

          {:ok, %{type: type}} ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :counted_set_fields, field],
                message:
                  "counted_set_fields entry #{inspect(field)} must have `{:array, inner_type}` attribute type, got #{inspect(type)}"
              )}}
        end
      end)
    end

    defp validate_projected_fields(module, dsl_state, attr_names) do
      editable = Transformer.get_option(dsl_state, [:xitdb], :editable_fields, [])
      passthru = Transformer.get_option(dsl_state, [:xitdb], :passthru_fields, [])

      case Enum.reject(editable ++ passthru, &MapSet.member?(attr_names, &1)) do
        [] ->
          :ok

        missing ->
          {:error,
           DslError.exception(
             module: module,
             path: [:xitdb, :editable_fields],
             message:
               "unknown attribute(s) #{inspect(Enum.uniq(missing))} in `editable_fields` / `passthru_fields` on #{inspect(module)}"
           )}
      end
    end

    defp validate_search_fields(module, search_fields, attr_names) do
      Enum.reduce_while(search_fields, :ok, fn %SearchField{} = sf, :ok ->
        cond do
          sf.boost <= 0.0 ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :search_field, sf.field],
                message: "`search_field` boost must be > 0.0, got: #{inspect(sf.boost)}"
              )}}

          is_nil(sf.resolver) and not MapSet.member?(attr_names, sf.field) ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :search_field, sf.field],
                message:
                  "search_field #{inspect(sf.field)} must match an attribute on #{inspect(module)} or supply a `resolver: fun/2`"
              )}}

          true ->
            {:cont, :ok}
        end
      end)
    end

    defp maybe_append_relationship_indexes(dsl_state, explicit_indexes, pk_fields) do
      index_rels? =
        Transformer.get_option(dsl_state, [:xitdb], :index_relationships?, true)

      if not index_rels? do
        explicit_indexes
      else
        covered_leading_fields =
          explicit_indexes
          |> Enum.map(fn %Index{fields: [first | _]} -> first end)
          |> MapSet.new()

        auto_fk_indexes =
          dsl_state
          |> Ash.Resource.Info.relationships()
          |> Enum.filter(&(&1.type == :belongs_to))
          |> Enum.map(& &1.source_attribute)
          |> Enum.uniq()
          |> Enum.reject(fn fk_attr ->
            [fk_attr] == pk_fields or MapSet.member?(covered_leading_fields, fk_attr)
          end)
          |> Enum.map(fn fk_attr -> %Index{fields: [fk_attr], name: nil} end)

        explicit_indexes ++ auto_fk_indexes
      end
    end

    defp build_tx_for_indexes(collection, all_indexes) do
      for %Index{fields: [single_field]} = idx <- all_indexes do
        {collection, single_field, canonical_index_slot_name(idx)}
      end
    end

    defp define_direct_callbacks(dsl_state, store, collection, normalized_indexes) do
      Transformer.eval(
        dsl_state,
        [store: store, collection: collection, normalized_indexes: normalized_indexes],
        quote do
          @doc false
          def __xitdb_store__, do: unquote(Macro.escape(store))

          @doc false
          def __xitdb_collection__, do: unquote(Macro.escape(collection))

          @doc false
          def __xitdb_indexes__, do: unquote(Macro.escape(normalized_indexes))
        end
      )
    end
  end
end
