defmodule Xitdb.FallbackTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:xitdb, :fallback, :used],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:fallback_telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "run/2,3" do
    test "executes fallback, emits telemetry, and logs warning" do
      log =
        capture_log(fn ->
          assert :computed == Xitdb.Fallback.run(:cache_miss, fn -> :computed end)
        end)

      assert_receive {:fallback_telemetry, [:xitdb, :fallback, :used], %{count: 1},
                      %{reason: :cache_miss}}

      assert log =~ "cache_miss"
    end

    test "merges metadata and forces :reason to the explicit reason argument" do
      log =
        capture_log(fn ->
          assert nil ==
                   Xitdb.Fallback.run(:dict_miss, %{dict: "users", reason: :ignored}, fn ->
                     nil
                   end)
        end)

      assert_receive {:fallback_telemetry, [:xitdb, :fallback, :used], %{count: 1},
                      %{dict: "users", reason: :dict_miss}}

      assert log =~ "dict_miss"
      assert log =~ "users"
    end

    test "rejects invalid reason or non-map metadata" do
      assert_raise FunctionClauseError, fn ->
        apply(Xitdb.Fallback, :run, [123, fn -> :ok end])
      end

      assert_raise FunctionClauseError, fn ->
        apply(Xitdb.Fallback, :run, [:cache_miss, [:not_a_map], fn -> :ok end])
      end
    end
  end

  describe "try_run/3,4" do
    test "returns try_fun result without telemetry or warning log when no exception occurs" do
      log =
        capture_log(fn ->
          assert {:ok, 1} ==
                   Xitdb.Fallback.try_run(
                     :calc_load,
                     %{mod: Sample},
                     fn -> {:ok, 1} end,
                     fn -> :fallback end
                   )
        end)

      refute_receive {:fallback_telemetry, _, _, _}
      assert log == ""
    end

    test "invokes 0-arity fallback_fun with telemetry and warning log on exception" do
      log =
        capture_log(fn ->
          assert :fallback ==
                   Xitdb.Fallback.try_run(
                     :calc_load,
                     fn -> raise ArgumentError, "boom" end,
                     fn -> :fallback end
                   )
        end)

      assert_receive {:fallback_telemetry, [:xitdb, :fallback, :used], %{count: 1},
                      %{
                        reason: :calc_load,
                        exception: "boom",
                        exception_module: ArgumentError
                      }}

      assert log =~ "calc_load"
    end

    test "invokes 1-arity fallback_fun with the rescued exception" do
      log =
        capture_log(fn ->
          assert {:fallback, "bad input"} ==
                   Xitdb.Fallback.try_run(
                     :calc_select,
                     %{resource: Sample},
                     fn -> raise ArgumentError, "bad input" end,
                     fn %ArgumentError{} = err -> {:fallback, err.message} end
                   )
        end)

      assert_receive {:fallback_telemetry, [:xitdb, :fallback, :used], %{count: 1},
                      %{
                        reason: :calc_select,
                        resource: Sample,
                        exception: "bad input",
                        exception_module: ArgumentError
                      }}

      assert log =~ "calc_select"
    end
  end
end
