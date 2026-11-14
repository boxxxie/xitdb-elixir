if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Transformers.BuildIndexPlan do
    @moduledoc false
    use Spark.Dsl.Transformer

    @impl true
    def transform(dsl_state), do: {:ok, dsl_state}
  end
end
