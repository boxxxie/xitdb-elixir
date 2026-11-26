defmodule Credo.Check.Warning.NoBusinessLogicRescueTest do
  use ExUnit.Case, async: true

  setup_all do
    case Application.ensure_all_started(:credo) do
      {:ok, _} -> :ok
      {:error, {:credo, {{:already_started, _}, _}}} -> :ok
    end

    unless Code.ensure_loaded?(Credo.Check.Warning.NoBusinessLogicRescue) do
      Code.require_file("../../credo/checks/no_business_logic_rescue.ex", __DIR__)
    end

    :ok
  end

  defp run_check(source, filename) do
    source_file = Credo.SourceFile.parse(source, filename)

    apply(Credo.Check.Warning.NoBusinessLogicRescue, :run, [
      source_file,
      [allowed_paths: ["lib/xitdb/fallback.ex"]]
    ])
  end

  test "flags try/rescue outside allowlisted boundary modules" do
    source = """
    defmodule Xitdb.SomeFeature do
      def fetch(x) do
        try do
          x
        rescue
          _ -> :ok
        end
      end
    end
    """

    assert [_issue] = run_check(source, "lib/xitdb/some_feature.ex")
  end

  test "flags def-level rescue and catch outside allowlisted boundary modules" do
    source = """
    defmodule Xitdb.SomeFeature do
      def foo do
        :ok
      rescue
        _ -> nil
      end

      def bar do
        :ok
      catch
        _, _ -> :error
      end
    end
    """

    assert [_, _] = run_check(source, "lib/xitdb/some_feature.ex")
  end

  test "allows rescue inside allowlisted boundary modules" do
    source = """
    defmodule Xitdb.Fallback do
      def try_run(fun) do
        try do
          fun.()
        rescue
          e -> e
        end
      end
    end
    """

    assert [] = run_check(source, "lib/xitdb/fallback.ex")
  end

  test "allows observe-and-reraise telemetry spans" do
    source = """
    defmodule Xitdb.Ash.Mutator do
      def wrap(fun) do
        try do
          fun.()
        rescue
          exception ->
            emit(exception)
            reraise exception, __STACKTRACE__
        catch
          kind, reason ->
            emit(kind, reason)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
      end
    end
    """

    assert [] = run_check(source, "lib/xitdb/ash/mutator.ex")
  end

  test "flags mixed rescue where one clause swallows instead of reraising" do
    source = """
    defmodule Xitdb.Ash.Mutator do
      def wrap(fun) do
        try do
          fun.()
        rescue
          ArgumentError -> :ok
          exception -> reraise exception, __STACKTRACE__
        end
      end
    end
    """

    assert [_issue] = run_check(source, "lib/xitdb/ash/mutator.ex")
  end
end
