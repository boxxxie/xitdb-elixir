defmodule Xitdb.ReadOnlyAndTxContextTest do
  use ExUnit.Case, async: true

  use Xitdb.DSL

  alias Xitdb.Error

  test "open(read_only: true) fails cleanly on missing or empty files without writing to disk" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "xitdb_ro_missing_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    missing_buffered = Path.join(tmp_dir, "missing_buffered.xit")
    missing_file = Path.join(tmp_dir, "missing_file.xit")

    assert {:error, %Error{}} =
             Xitdb.open(backend: :buffered_file, path: missing_buffered, read_only: true)

    refute File.exists?(missing_buffered)

    assert {:error, %Error{}} =
             Xitdb.open(backend: :file, path: missing_file, read_only: true)

    refute File.exists?(missing_file)

    empty_file = Path.join(tmp_dir, "empty.xit")
    File.write!(empty_file, "")

    assert {:error, %Error{}} =
             Xitdb.open(backend: :buffered_file, path: empty_file, read_only: true)

    assert File.stat!(empty_file).size == 0
  end

  test "open(read_only: true) reads chmod 0444 stores, exposes tx_meta/2, and rejects mutations" do
    tmp_dir = Path.join(System.tmp_dir!(), "xitdb_ro_perm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    path = Path.join(tmp_dir, "readonly.xit")

    on_exit(fn ->
      if File.exists?(path), do: _ = File.chmod(path, 0o644)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, rw} = Xitdb.open(backend: :buffered_file, path: path)

    {:ok, rw} =
      Xitdb.transact(rw, %{"users" => %{"1" => %{"name" => "Ada"}}},
        doc: "seed ada",
        instant: 1_700_000_000_000,
        meta: %{actor_id: "1", source_system: :seed}
      )

    {:ok, rw} =
      Xitdb.transact(rw, fn root -> put_in(root["users"]["1"]["role"], "admin") end,
        doc: "promote ada",
        instant: 1_700_000_060_000,
        meta: %{actor_id: "99", actor_email: "steward@caasa.ca", reason: "verified", skip: nil}
      )

    :ok = Xitdb.sync(rw)
    :ok = Xitdb.close(rw)

    File.chmod!(path, 0o444)

    assert {:ok, %Xitdb{read_only: true} = ro} =
             Xitdb.open(backend: :buffered_file, path: path, read_only: true)

    on_exit(fn -> Xitdb.close(ro) end)

    assert Xitdb.moment_count(ro) == 2
    assert Xitdb.db(ro)["users"]["1"]["role"] == "admin"
    assert Xitdb.as_of(ro, 0)["users"]["1"]["role"] == nil
    assert Xitdb.as_of(ro, 0)["users"]["1"]["name"] == "Ada"

    assert {:ok, [_, _]} = Xitdb.history_of(ro, ".users[\"1\"]")
    assert {:ok, [_ | _]} = Xitdb.diff_moments(ro, 0, 1)

    assert {:ok,
            %{
              "doc" => "promote ada",
              "tx_instant" => 1_700_000_060_000,
              "actor_id" => "99",
              "actor_email" => "steward@caasa.ca",
              "reason" => "verified"
            } = meta_latest} = Xitdb.tx_meta(ro)

    refute Map.has_key?(meta_latest, "skip")

    assert %{
             "doc" => "seed ada",
             "tx_instant" => 1_700_000_000_000,
             "actor_id" => "1",
             "source_system" => "seed"
           } = Xitdb.tx_meta!(ro, 0)

    assert %{
             "doc" => "seed ada",
             "tx_instant" => 1_700_000_000_000
           } = Xitdb.tx_meta!(ro, -2)

    cursor_m0 = Xitdb.as_of(ro, 0)
    assert %{"doc" => "seed ada"} = Xitdb.tx_meta!(cursor_m0)

    assert {:error, %Error{reason: :read_only}} = Xitdb.transact(ro, %{"x" => 1})
    assert {:error, %Error{reason: :read_only}} = Xitdb.transact_ops(ro, [{:put, ".x", 1}])
    assert {:error, %Error{reason: :read_only}} = Xitdb.sync(ro)
  end

  test "with_tx_context/2 propagates ambient doc, instant, and meta across transact, transact_ops, and tx DSL" do
    {:ok, db} = Xitdb.open(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    res =
      Xitdb.with_tx_context(
        [
          doc: "ambient doc",
          instant: 1_700_000_123_000,
          meta: %{
            actor_id: "u1",
            source_system: :steward_ui,
            workflow_run_id: "run-1",
            nullable: nil
          }
        ],
        fn ->
          assert %{doc: "ambient doc", instant: 1_700_000_123_000} = Xitdb.current_tx_context()

          {:ok, db} = Xitdb.transact(db, %{"a" => 1})
          {:ok, db} = Xitdb.transact_ops(db, [{:put, ".b", 2}])

          {:ok, db} =
            tx db do
              put(c, 3)
            end

          db =
            Xitdb.with_tx_context(
              [doc: "inner doc", meta: %{reason: "override", actor_id: "u2"}],
              fn ->
                {:ok, db2} =
                  Xitdb.transact(db, fn root -> put_in(root["d"], 4) end,
                    doc: "explicit call doc",
                    meta: %{"source_system" => "explicit"}
                  )

                db2
              end
            )

          assert %{doc: "ambient doc"} = Xitdb.current_tx_context()
          {:ok, db} = Xitdb.transact(db, fn root -> put_in(root["e"], 5) end)
          db
        end
      )

    assert Xitdb.current_tx_context() == nil

    m0 = Xitdb.tx_meta!(res, 0)
    assert m0["doc"] == "ambient doc"
    assert m0["tx_instant"] == 1_700_000_123_000
    assert m0["actor_id"] == "u1"
    assert m0["source_system"] == "steward_ui"
    assert m0["workflow_run_id"] == "run-1"
    refute Map.has_key?(m0, "nullable")

    m1 = Xitdb.tx_meta!(res, 1)
    assert m1["doc"] == "ambient doc"
    assert m1["actor_id"] == "u1"

    m2 = Xitdb.tx_meta!(res, 2)
    assert m2["doc"] == "ambient doc"
    assert m2["source_system"] == "steward_ui"

    m3 = Xitdb.tx_meta!(res, 3)
    assert m3["doc"] == "explicit call doc"
    assert m3["tx_instant"] == 1_700_000_123_000
    assert m3["actor_id"] == "u2"
    assert m3["reason"] == "override"
    assert m3["source_system"] == "explicit"

    m4 = Xitdb.tx_meta!(res, 4)
    assert m4["doc"] == "ambient doc"
    assert m4["actor_id"] == "u1"
    assert m4["source_system"] == "steward_ui"
    refute Map.has_key?(m4, "reason")
  end
end
