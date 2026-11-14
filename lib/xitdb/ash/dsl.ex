if Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Dsl do
    @moduledoc """
    Spark DSL extension alias for `Xitdb.Ash.Resource`.
    """
    defdelegate sections(), to: Xitdb.Ash.Resource
    defdelegate transformers(), to: Xitdb.Ash.Resource
    defdelegate verifiers(), to: Xitdb.Ash.Resource
    defdelegate dsl_patches(), to: Xitdb.Ash.Resource
    defdelegate module_imports(), to: Xitdb.Ash.Resource
    defdelegate persisters(), to: Xitdb.Ash.Resource
    defdelegate add_extensions(), to: Xitdb.Ash.Resource
  end
end
