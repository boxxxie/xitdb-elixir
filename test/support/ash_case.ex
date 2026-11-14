if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.FeatureScenario do
    @moduledoc """
    Compiles `@given`, `@upon`, `@whenever`, and `@then` steps into a piped `ctx` test
    while preserving caller line metadata.
    """

    defmacro scenario(description, do: block) do
      lines =
        case block do
          {:__block__, _, exprs} -> exprs
          single -> [single]
        end

      ctx_var = Macro.unique_var(:ctx, __MODULE__)

      # Calls `new_world/1` imported from the active Layer 2 DSL module
      init_ctx =
        quote do
          new_world(unquote(ctx_var))
        end

      piped_steps =
        Enum.reduce(lines, init_ctx, fn
          {:@, step_meta, [{step_kind, _, [call]}]}, acc
          when step_kind in [:given, :upon, :whenever, :then] ->
            step_line = Keyword.get(step_meta, :line, __CALLER__.line)
            piped = Macro.pipe(acc, call, 0)
            Macro.update_meta(piped, &Keyword.put(&1, :line, step_line))

          other_ast, _acc ->
            err_line =
              case other_ast do
                {_, meta, _} when is_list(meta) -> Keyword.get(meta, :line, __CALLER__.line)
                _ -> __CALLER__.line
              end

            raise CompileError,
              file: __CALLER__.file,
              line: err_line,
              description:
                "Only @given, @upon, @whenever, and @then steps are allowed inside scenario/2. Got: #{Macro.to_string(other_ast)}"
        end)

      quote line: __CALLER__.line do
        test unquote(description), unquote(ctx_var) do
          _ = unquote(piped_steps)
          :ok
        end
      end
    end
  end

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
