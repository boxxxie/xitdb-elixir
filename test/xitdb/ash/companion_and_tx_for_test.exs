defmodule Xitdb.Ash.CompanionAndTxForTest do
  use ExUnit.Case, async: true

  test "tx_for raises CompileError with caller line on missing module or missing __xitdb_collection__" do
    assert_raise CompileError, ~r/could not load schema module/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Xitdb.Ash.CompanionAndTxForTest.MissingSchemaCaller do
            use Xitdb.DSL
            def run(db), do: tx_for(db, NonExistentSchemaModule, do: :ok)
          end
        end
      )
    end
  end
end
