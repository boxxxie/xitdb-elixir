defmodule Xitdb.FeatureCase do
  @moduledoc """
  ExUnit CaseTemplate for Layer 1 ATDD Executable Specifications.

  Provides the `scenario/2` macro which compiles `@given`, `@upon`, and `@then`
  steps into a functional context pipeline (`ctx |> step1() |> step2()`) and
  rejects raw implementation plumbing at compile time.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Xitdb.FeatureCase, only: [scenario: 2]
      import Xitdb.TestDSL.ClientDSL
      import Xitdb.Sigils
    end
  end

  defmacro scenario(description, do: block) do
    lines =
      case block do
        {:__block__, _meta, exprs} -> exprs
        single -> [single]
      end

    piped_steps =
      Enum.reduce(lines, quote(do: Xitdb.TestDrivers.ClientDriver.new_context()), fn
        {:@, _, [{step_kind, _, [call]}]}, acc when step_kind in [:given, :upon, :then] ->
          Macro.pipe(acc, call, 0)

        other_ast, _acc ->
          raise CompileError,
            description:
              "Only @given, @upon, and @then steps are allowed inside scenario/2. Got: #{Macro.to_string(other_ast)}"
      end)

    quote do
      test unquote(description) do
        ctx = unquote(piped_steps)
        Xitdb.TestDrivers.ClientDriver.cleanup_context(ctx)
      end
    end
  end
end
