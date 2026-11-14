if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Verifiers.VerifyNoSqlFragments do
    @moduledoc false
    use Spark.Dsl.Verifier

    alias Spark.Dsl.Verifier
    alias Spark.Error.DslError

    @impl Spark.Dsl.Verifier
    def verify(dsl_state) do
      module = Verifier.get_persisted(dsl_state, :module)

      with :ok <- check_calculations(module, dsl_state),
           :ok <- check_aggregates(module, dsl_state),
           :ok <- check_relationships(module, dsl_state),
           :ok <- check_identities(module, dsl_state),
           :ok <- check_resource_validations_changes_and_preparations(module, dsl_state),
           :ok <- check_actions(module, dsl_state) do
        check_policies(module, dsl_state)
      end
    end

    defp check_calculations(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.calculations()
      |> Enum.reduce_while(:ok, fn calc, :ok ->
        if contains_sql_fragment?(calc.calculation) do
          {:halt,
           fragment_error(
             module,
             [:calculations, calc.name],
             "calculation #{inspect(calc.name)}"
           )}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_aggregates(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.aggregates()
      |> Enum.reduce_while(:ok, fn agg, :ok ->
        agg_terms = [Map.get(agg, :filter), Map.get(agg, :join_filters)]

        if contains_sql_fragment?(agg_terms) do
          {:halt,
           fragment_error(
             module,
             [:aggregates, agg.name],
             "aggregate #{inspect(agg.name)}"
           )}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_relationships(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.relationships()
      |> Enum.reduce_while(:ok, fn rel, :ok ->
        if contains_sql_fragment?(Map.get(rel, :filter)) do
          {:halt,
           fragment_error(
             module,
             [:relationships, rel.name],
             "relationship #{inspect(rel.name)} `filter`"
           )}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_identities(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.identities()
      |> Enum.reduce_while(:ok, fn identity, :ok ->
        if contains_sql_fragment?(Map.get(identity, :where)) do
          {:halt,
           fragment_error(
             module,
             [:identities, identity.name],
             "identity #{inspect(identity.name)} `where` clause"
           )}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_resource_validations_changes_and_preparations(module, dsl_state) do
      validations = Ash.Resource.Info.validations(dsl_state)
      changes = Ash.Resource.Info.changes(dsl_state)
      preparations = Ash.Resource.Info.preparations(dsl_state)

      cond do
        Enum.any?(validations, &contains_sql_fragment?/1) ->
          fragment_error(module, [:validations], "resource `validations` block")

        Enum.any?(changes, &contains_sql_fragment?/1) ->
          fragment_error(module, [:changes], "resource `changes` block")

        Enum.any?(preparations, &contains_sql_fragment?/1) ->
          fragment_error(module, [:preparations], "resource `preparations` block")

        true ->
          :ok
      end
    end

    defp check_actions(module, dsl_state) do
      dsl_state
      |> Ash.Resource.Info.actions()
      |> Enum.reduce_while(:ok, fn action, :ok ->
        action_terms = [
          Map.get(action, :filter),
          Map.get(action, :changes),
          Map.get(action, :validations),
          Map.get(action, :preparations)
        ]

        if contains_sql_fragment?(action_terms) do
          {:halt,
           fragment_error(module, [:actions, action.name], "action #{inspect(action.name)}")}
        else
          {:cont, :ok}
        end
      end)
    end

    defp check_policies(module, dsl_state) do
      if Code.ensure_loaded?(Ash.Policy.Info) and
           Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(dsl_state) do
        policies = Ash.Policy.Info.policies(dsl_state)

        field_policies =
          if function_exported?(Ash.Policy.Info, :field_policies, 1) do
            Ash.Policy.Info.field_policies(dsl_state)
          else
            []
          end

        cond do
          contains_sql_fragment?(policies) ->
            fragment_error(module, [:policies], "`policies` block")

          contains_sql_fragment?(field_policies) ->
            fragment_error(module, [:field_policies], "`field_policies` block")

          true ->
            :ok
        end
      else
        :ok
      end
    end

    # Specific fragment struct/call/AST matches MUST appear before generic `%_{} = struct`
    defp contains_sql_fragment?(%Ash.Query.Function.Fragment{}), do: true
    defp contains_sql_fragment?(%Ash.Query.Call{name: :fragment}), do: true
    defp contains_sql_fragment?({:fragment, _meta, args}) when is_list(args), do: true

    defp contains_sql_fragment?(%_{} = struct) do
      struct
      |> Map.from_struct()
      |> Map.delete(:__spark_metadata__)
      |> Map.values()
      |> Enum.any?(&contains_sql_fragment?/1)
    end

    defp contains_sql_fragment?(map) when is_map(map) do
      Enum.any?(map, fn {k, v} -> contains_sql_fragment?(k) or contains_sql_fragment?(v) end)
    end

    defp contains_sql_fragment?(list) when is_list(list) do
      Enum.any?(list, &contains_sql_fragment?/1)
    end

    defp contains_sql_fragment?(tuple) when is_tuple(tuple) do
      tuple
      |> Tuple.to_list()
      |> Enum.any?(&contains_sql_fragment?/1)
    end

    defp contains_sql_fragment?(_scalar), do: false

    defp fragment_error(module, path, location_desc) do
      {:error,
       DslError.exception(
         module: module,
         path: path,
         message:
           "SQL `fragment(...)` is not supported by `Xitdb.Ash.DataLayer` (found in #{location_desc}). " <>
             "Replace it with a portable `Ash.Expr` expression or an `Ash.Resource.Calculation` module."
       )}
    end
  end
end
