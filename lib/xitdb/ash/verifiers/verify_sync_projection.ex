if Code.ensure_loaded?(Spark.Dsl.Verifier) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Verifiers.VerifySyncProjection do
    @moduledoc """
    Verifies at compile time that:
    1. Every attribute accepted by `xitdb.sync_update_action` (that is not in
       `xitdb.ignored_sync_attributes`) is declared in `xitdb.editable_fields`
       or `xitdb.passthru_fields` (preventing silent field drops during Xitdb ingestion).
    2. Every declared `editable_fields` / `passthru_fields` entry exists on the resource.
    3. Every `indexes` key maps to a known projected or computed field.
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

      with :ok <- verify_attributes_exist(dsl_state, module, projected_set),
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
      end)
    end
  end
end
