if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Verifiers.VerifyCrossStoreReferences do
    @moduledoc false
    use Spark.Dsl.Verifier

    alias Spark.Dsl.Verifier
    alias Spark.Error.DslError
    alias Xitdb.Ash.{Info, NestedIn, Reference}

    @impl Spark.Dsl.Verifier
    def verify(dsl_state) do
      module = Verifier.get_persisted(dsl_state, :module)
      own_store = Info.store!(dsl_state)
      declared_refs = Info.references(dsl_state)

      belongs_to_rels =
        dsl_state
        |> Ash.Resource.Info.relationships()
        |> Enum.filter(&match?(%Ash.Resource.Relationships.BelongsTo{}, &1))

      belongs_to_by_name = Map.new(belongs_to_rels, &{&1.name, &1})
      refs_by_rel = Map.new(declared_refs, &{&1.relationship, &1})

      with :ok <- verify_declared_references_exist(module, declared_refs, belongs_to_by_name),
           :ok <-
             Enum.reduce_while(belongs_to_rels, :ok, fn rel, :ok ->
               ref = Map.get(refs_by_rel, rel.name)
               on_delete = if ref, do: ref.on_delete, else: :nothing
               validate_reference(module, own_store, rel, on_delete)
             end) do
        verify_nested_parent(module, dsl_state, own_store)
      end
    end

    defp verify_declared_references_exist(module, declared_refs, belongs_to_by_name) do
      Enum.reduce_while(declared_refs, :ok, fn %Reference{relationship: rel_name}, :ok ->
        case Map.fetch(belongs_to_by_name, rel_name) do
          {:ok, _rel} ->
            {:cont, :ok}

          :error ->
            {:halt,
             {:error,
              DslError.exception(
                module: module,
                path: [:xitdb, :references, rel_name],
                message:
                  "reference #{inspect(rel_name)} must match a `belongs_to` relationship on #{inspect(module)}"
              )}}
        end
      end)
    end

    defp validate_reference(_mod, _store, _rel, :nothing), do: {:cont, :ok}

    defp validate_reference(mod, _own_store, %{name: name, allow_nil?: false}, :nilify) do
      {:halt,
       {:error,
        DslError.exception(
          module: mod,
          path: [:xitdb, :references, name],
          message:
            "cannot set `on_delete: :nilify` when `belongs_to #{inspect(name)}` has `allow_nil?: false`"
        )}}
    end

    defp validate_reference(mod, own_store, %{name: name, destination: dest}, on_delete) do
      _ = Code.ensure_compiled(dest)

      if not xitdb_datalayer_or_dsl_resource?(dest) do
        {:halt,
         {:error,
          DslError.exception(
            module: mod,
            path: [:xitdb, :references, name],
            message:
              "Cannot enforce on_delete: #{inspect(on_delete)} toward non-Xitdb resource #{inspect(dest)}; use an Ash.Notifier or AshOban trigger instead."
          )}}
      else
        case Info.fetch_store(dest) do
          {:ok, ^own_store} ->
            {:cont, :ok}

          {:ok, dest_store} ->
            {:halt,
             {:error,
              DslError.exception(
                module: mod,
                path: [:xitdb, :references, name],
                message:
                  "Cross-store on_delete: #{inspect(on_delete)} from #{inspect(own_store)} to #{inspect(dest_store)} is not supported."
              )}}

          :error ->
            {:halt,
             {:error,
              DslError.exception(
                module: mod,
                path: [:xitdb, :references, name],
                message:
                  "Cross-store on_delete: #{inspect(on_delete)} toward #{inspect(dest)} without a configured `xitdb.store` is not supported."
              )}}
        end
      end
    end

    defp verify_nested_parent(module, dsl_state, source_store) do
      case Info.nested_in(dsl_state) do
        nil ->
          :ok

        %NestedIn{parent_collection: parent_col, foreign_key: fk_attr} ->
          parent_rel =
            dsl_state
            |> Ash.Resource.Info.relationships()
            |> Enum.find(&(&1.type == :belongs_to and &1.source_attribute == fk_attr))

          validate_nested_relationship(module, source_store, parent_col, parent_rel)
      end
    end

    defp validate_nested_relationship(_module, _source_store, _parent_col, nil), do: :ok

    defp validate_nested_relationship(module, source_store, parent_col, %{destination: dest}) do
      _ = Code.ensure_compiled(dest)

      if not xitdb_datalayer_or_dsl_resource?(dest) do
        {:error,
         DslError.exception(
           module: module,
           path: [:xitdb, :nested_in, parent_col],
           message: "`nested_in` parent resource #{inspect(dest)} must use `Xitdb.Ash.DataLayer`"
         )}
      else
        case Info.fetch_store(dest) do
          :error ->
            {:error,
             DslError.exception(
               module: module,
               path: [:xitdb, :nested_in, parent_col],
               message:
                 "`nested_in` parent resource #{inspect(dest)} has no `xitdb.store` configured"
             )}

          {:ok, dest_store} when dest_store != source_store ->
            {:error,
             DslError.exception(
               module: module,
               path: [:xitdb, :nested_in, parent_col],
               message:
                 "`nested_in` child #{inspect(module)} (#{inspect(source_store)}) must share the same store as parent #{inspect(dest)} (#{inspect(dest_store)})"
             )}

          {:ok, ^source_store} ->
            case Info.fetch_collection(dest) do
              :error ->
                {:error,
                 DslError.exception(
                   module: module,
                   path: [:xitdb, :nested_in, parent_col],
                   message:
                     "`nested_in` parent resource #{inspect(dest)} has no `xitdb.collection` configured"
                 )}

              {:ok, actual_col} when actual_col != parent_col ->
                {:error,
                 DslError.exception(
                   module: module,
                   path: [:xitdb, :nested_in, parent_col],
                   message:
                     "`nested_in #{inspect(parent_col)}` does not match parent #{inspect(dest)} collection #{inspect(actual_col)}"
                 )}

              {:ok, ^parent_col} ->
                :ok
            end
        end
      end
    end

    defp xitdb_datalayer_or_dsl_resource?(dest) when is_atom(dest) do
      Ash.Resource.Info.data_layer(dest) == Xitdb.Ash.DataLayer or
        Xitdb.Ash.Dsl in Spark.extensions(dest)
    end
  end
end
