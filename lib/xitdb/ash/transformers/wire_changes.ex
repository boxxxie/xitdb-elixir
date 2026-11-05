if Code.ensure_loaded?(Spark.Dsl.Transformer) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Transformers.WireChanges do
    @moduledoc """
    Automatically attaches the resource's configured `lock_change` (or
    `Application.get_env(:xitdb, :default_lock_change)`) to `lock_action` and `unlock_action`.
    """
    use Spark.Dsl.Transformer

    alias Spark.Dsl.Transformer
    alias Xitdb.Ash.Info, as: XitdbInfo

    @impl true
    def after?(Ash.Resource.Transformers.SetTypes), do: true
    def after?(_), do: false

    @impl true
    def transform(dsl_state) do
      case XitdbInfo.resolve_lock_change(dsl_state) do
        nil ->
          {:ok, dsl_state}

        lock_change_mod ->
          lock_action = XitdbInfo.xitdb_lock_action!(dsl_state)
          unlock_action = XitdbInfo.xitdb_unlock_action!(dsl_state)

          dsl_state
          |> maybe_attach_lock_change(lock_action, lock_change_mod, :lock)
          |> maybe_attach_lock_change(unlock_action, lock_change_mod, :unlock)
          |> then(&{:ok, &1})
      end
    end

    defp maybe_attach_lock_change(dsl_state, action_name, lock_change_mod, op) do
      case Ash.Resource.Info.action(dsl_state, action_name) do
        nil ->
          dsl_state

        action ->
          if lock_change_present?(action.changes, lock_change_mod) do
            dsl_state
          else
            {:ok, change} =
              Transformer.build_entity(Ash.Resource.Dsl, [:actions, :update], :change,
                change: {lock_change_mod, op: op}
              )

            updated_action = %{action | changes: action.changes ++ [change]}

            Transformer.replace_entity(
              dsl_state,
              [:actions],
              updated_action,
              &(&1.name == action_name and &1.type == :update)
            )
          end
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
