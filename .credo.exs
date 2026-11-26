%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "credo/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/native/"]
      },
      requires: ["credo/checks/*.ex"],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.NoBusinessLogicRescue,
           allowed_paths: [
             # Standardized fallback helper itself
             "lib/xitdb/fallback.ex",
             # Top-level transaction exception -> {:error, %Xitdb.Error{}} boundary
             "lib/xitdb.ex",
             # Pull pattern compile/1 ArgumentError -> {:error, %Xitdb.Error{}} boundary
             "lib/xitdb/pull.ex",
             # Virtual probe & Inspect.Xitdb.Cursor protocol boundary
             "lib/xitdb/cursor.ex",
             # :zlib stream cleanup / corrupt-payload boundary & selector ArgumentError guard
             "lib/xitdb/compression.ex",
             # tx DSL runtime abort catch & exception -> {:error, %Xitdb.Error{}} boundary
             "lib/xitdb/dsl/tx_rewriter.ex",
             # Ash Store savepoint/rollback throw & GenServer lease-abort :exit boundary
             "lib/xitdb/ash/store.ex",
             # ExUnit.Callbacks / ETS / GenServer cleanup boundary in TestSandbox
             "lib/xitdb/ash/test_sandbox.ex",
             # String.to_existing_atom/1 ArgumentError guard in RangedUnit
             "lib/xitdb/ash/types/ranged_unit.ex"
           ]}
        ],
        disabled: []
      }
    }
  ]
}
