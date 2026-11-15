if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.AshCase do
    @moduledoc false
    use ExUnit.CaseTemplate

    using do
      quote do
        use ExUnit.Case, async: true
        import Xitdb.FeatureScenario, only: [scenario: 2]
      end
    end

    setup tags do
      :ok =
        Xitdb.Ash.TestSandbox.checkout(
          [Xitdb.TestSupport.MdmStore, Xitdb.TestSupport.AppStore],
          shared: not Map.get(tags, :async, true)
        )

      :ok
    end
  end
end
