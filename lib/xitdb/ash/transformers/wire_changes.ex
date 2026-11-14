if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Transformers.WireChanges do
    @moduledoc """
    Automatically attaches the resource's configured `lock_change` (or
    `Application.get_env(:xitdb, :default_lock_change)`) to `lock_action` and `unlock_action`,
    and persists precompiled Xitdb projection metadata (`editable_field_strings`, `pull_fields`,
    `pull_pattern`, `store`, `lock_change`, and `normalized_indexes`) onto the resource.
    """
    use Spark.Dsl.Transformer

    alias Spark.Dsl.Transformer
    alias Xitdb.Ash.Info, as: XitdbInfo

    @impl true
    def after?(Ash.Resource.Transformers.SetTypes), do: true
    def after?(_), do: false

    @impl true
    def transform(dsl_state) do
      module = Transformer.get_persisted(dsl_state, :module)

      if is_atom(module) and not is_nil(module) do
        XitdbInfo.__purge_pair_cache__(module)
      end

      dsl_state =
        dsl_state
        |> persist_xitdb_metadata()
        |> define_direct_info_functions()

      case XitdbInfo.resolve_lock_change(dsl_state) do
        nil ->
          {:ok, dsl_state}

        lock_change_mod ->
          lock_action = XitdbInfo.xitdb_lock_action!(dsl_state)
          unlock_action = XitdbInfo.xitdb_unlock_action!(dsl_state)

          dsl_state =
            if Transformer.get_persisted(dsl_state, :xitdb_lock_change) == nil and
                 (Ash.Resource.Info.action(dsl_state, lock_action) != nil or
                    Ash.Resource.Info.action(dsl_state, unlock_action) != nil) do
              Transformer.eval(
                dsl_state,
                [],
                quote do
                  _ = Application.compile_env(:xitdb, :default_lock_change)
                end
              )
            else
              dsl_state
            end

          dsl_state
          |> maybe_attach_lock_change(lock_action, lock_change_mod, :lock)
          |> maybe_attach_lock_change(unlock_action, lock_change_mod, :unlock)
          |> then(&{:ok, &1})
      end
    end

    defp define_direct_info_functions(dsl_state) do
      collection = Transformer.get_persisted(dsl_state, :xitdb_collection)
      nested_in = Transformer.get_persisted(dsl_state, :xitdb_nested_in, [])
      editable_strings = Transformer.get_persisted(dsl_state, :xitdb_editable_field_strings)
      pull_fields = Transformer.get_persisted(dsl_state, :xitdb_pull_fields)
      pull_pattern = Transformer.get_persisted(dsl_state, :xitdb_pull_pattern)
      store = Transformer.get_persisted(dsl_state, :xitdb_store)
      lock_change = Transformer.get_persisted(dsl_state, :xitdb_lock_change)
      normalized_indexes = Transformer.get_persisted(dsl_state, :xitdb_normalized_indexes)

      Transformer.eval(
        dsl_state,
        [
          collection: collection,
          nested_in: nested_in,
          editable_strings: editable_strings,
          pull_fields: pull_fields,
          pull_pattern: pull_pattern,
          store: store,
          lock_change: lock_change,
          normalized_indexes: normalized_indexes
        ],
        quote do
          @doc false
          def __xitdb_collection__, do: unquote(Macro.escape(collection))

          @doc false
          def __xitdb_nested_in__, do: unquote(Macro.escape(nested_in))

          @doc false
          def __xitdb_indexes__, do: unquote(Macro.escape(normalized_indexes))

          @doc false
          def __xitdb_editable_field_strings__, do: unquote(Macro.escape(editable_strings))

          @doc false
          def __xitdb_pull_fields__, do: unquote(Macro.escape(pull_fields))

          @doc false
          def __xitdb_pull_pattern__, do: unquote(Macro.escape(pull_pattern))

          @doc false
          def __xitdb_store__, do: unquote(Macro.escape(store))

          @doc false
          def __xitdb_lock_change__, do: unquote(Macro.escape(lock_change))
        end
      )
    end

    defp persist_xitdb_metadata(dsl_state) do
      collection =
        case XitdbInfo.xitdb_collection(dsl_state) do
          {:ok, col} -> col
          _ -> nil
        end

      nested_in = XitdbInfo.compute_nested_mappings(dsl_state)
      editable_strings = XitdbInfo.compute_editable_field_strings(dsl_state)
      pull_fields = XitdbInfo.compute_pull_fields(dsl_state)
      pull_pattern = Xitdb.Pull.compile!(pull_fields)

      store =
        case XitdbInfo.xitdb_store(dsl_state) do
          {:ok, s} -> s
          _ -> nil
        end

      lock_change =
        case XitdbInfo.xitdb_lock_change(dsl_state) do
          {:ok, mod} -> mod
          _ -> nil
        end

      normalized_indexes =
        if is_nil(collection) do
          []
        else
          for {field, idx_name} <- XitdbInfo.xitdb_indexes!(dsl_state) do
            {collection, field, idx_name}
          end
        end

      dsl_state
      |> Transformer.persist(:xitdb_collection, collection)
      |> Transformer.persist(:xitdb_nested_in, nested_in)
      |> Transformer.persist(:xitdb_editable_field_strings, editable_strings)
      |> Transformer.persist(:xitdb_pull_fields, pull_fields)
      |> Transformer.persist(:xitdb_pull_pattern, pull_pattern)
      |> Transformer.persist(:xitdb_store, store)
      |> Transformer.persist(:xitdb_lock_change, lock_change)
      |> Transformer.persist(:xitdb_normalized_indexes, normalized_indexes)
    end

    defp maybe_attach_lock_change(dsl_state, action_name, lock_change_mod, op) do
      case Ash.Resource.Info.action(dsl_state, action_name) do
        %Ash.Resource.Actions.Update{changes: changes} = action ->
          if lock_change_present?(changes, lock_change_mod) do
            dsl_state
          else
            {:ok, change} =
              Transformer.build_entity(Ash.Resource.Dsl, [:actions, :update], :change,
                change: {lock_change_mod, op: op}
              )

            updated_action = %Ash.Resource.Actions.Update{action | changes: changes ++ [change]}

            Transformer.replace_entity(
              dsl_state,
              [:actions],
              updated_action,
              &(&1.name == action_name and &1.type == :update)
            )
          end

        _ ->
          dsl_state
      end
    end

    defp lock_change_present?(changes, lock_change_mod) when is_list(changes) do
      Enum.any?(changes, fn
        %{change: {^lock_change_mod, _}} -> true
        _ -> false
      end)
    end
  end
end
