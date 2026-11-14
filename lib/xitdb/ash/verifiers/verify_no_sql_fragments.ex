if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Verifiers.VerifyNoSqlFragments do
    @moduledoc false
    use Spark.Dsl.Verifier

    @impl true
    def verify(_dsl_state), do: :ok
  end
end
