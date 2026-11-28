defmodule Xitdb.HardeningTest do
  use ExUnit.Case, async: true

  alias Xitdb.{Cursor, Error}

  test "open/0 defaults, compact/1 memory vs file backend, and max_decompressed_bytes boundaries" do
    {:ok, db} = Xitdb.open()
    on_exit(fn -> Xitdb.close(db) end)
    assert db.backend == :memory

    {:ok, db} = Xitdb.transact(db, %{"k" => "v"})
    {:ok, mem_compacted} = Xitdb.compact(db)
    on_exit(fn -> Xitdb.close(mem_compacted) end)
    assert mem_compacted.backend == :memory
    assert mem_compacted["k"] == "v"

    # max_decompressed_bytes exact boundary: 0 and non-integer rejected, 1 accepted
    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.select(db, ".k", max_decompressed_bytes: 0)

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.select(db, ".k", max_decompressed_bytes: "100")

    assert {:ok, "v"} = Xitdb.select(db, ".k", max_decompressed_bytes: 1)
  end

  test "transact/3 handles compressed maps, base_moment < -1 and >= 0, compressed callback ops, and struct returns" do
    db = Xitdb.open!(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    payload = String.duplicate("compressible payload text ", 20)

    # 1. Default opts [] with compressed value
    {:ok, db} = Xitdb.transact(db, %{"c1" => {:compressed, payload, min_bytes: 0}})
    assert db["c1"] == payload

    # 2. Explicit opts with base_moment: 0 and compressed value
    {:ok, db} =
      Xitdb.transact(db, %{"c2" => {:compressed, payload, min_bytes: 0}},
        doc: "m1",
        base_moment: 0
      )

    assert db["c2"] == payload

    # 3. Callback transact with default opts [] staging a compressed value (dispatch_transact_ops :default)
    {:ok, db} =
      Xitdb.transact(db, fn root ->
        put_in(root["c3"], {:compressed, payload, min_bytes: 0})
      end)

    assert db["c3"] == payload

    # 4. Callback transact with base_moment: -2 and base_moment: 0
    {:ok, db} =
      Xitdb.transact(
        db,
        fn root -> put_in(root["from_neg2"], "yes") end,
        base_moment: -2
      )

    assert db["from_neg2"] == "yes"

    {:ok, db} =
      Xitdb.transact(
        db,
        fn root -> put_in(root["from_m0"], "yes") end,
        base_moment: 0
      )

    assert db["from_m0"] == "yes"

    # 5. Callback returning a struct (is_map but is_struct) is rejected as :invalid_transaction_return
    assert {:error, %Error{reason: :invalid_transaction_return}} =
             Xitdb.transact(db, fn _root -> Decimal.new("1.5") end)
  end

  test "materialize/2 on scalars and select/3 + select!/3 on empty_root, non-root, and @-1/@0 selectors" do
    db = Xitdb.open!(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    # Scalar materialize passthrough
    assert Xitdb.materialize("hello") == "hello"
    assert Xitdb.materialize(42, raw_tagged: true) == 42

    # Empty root cursor select & select!
    empty_root = Cursor.empty_root(db.db_ref)
    assert {:ok, ^empty_root} = Xitdb.select(empty_root, "")
    assert {:ok, ^empty_root} = Xitdb.select(empty_root, [])
    assert {:ok, nil} = Xitdb.select(empty_root, ".missing")
    assert ^empty_root = Xitdb.select!(empty_root, "")
    assert nil == Xitdb.select!(empty_root, ".missing")

    db =
      db
      |> Xitdb.transact!(%{"users" => %{"a" => 1}})
      |> Xitdb.transact!(%{"users" => %{"a" => 2}})

    # @-1 and @0 pinning on select
    assert {:ok, 2} = Xitdb.select(db, "@-1.users.a")
    assert {:ok, 1} = Xitdb.select(db, "@0.users.a")
    assert {:ok, 2} = Xitdb.select(db, [{:at_moment, -1}, "users", "a"])
    assert {:ok, 1} = Xitdb.select(db, [{:at_moment, 0}, "users", "a"])

    # Non-root cursor raises/returns :non_root_cursor
    child = Xitdb.db(db)["users"]
    assert {:error, %Error{reason: :non_root_cursor}} = Xitdb.select(child, ".a")

    err = assert_raise Error, fn -> Xitdb.select!(child, ".a") end
    assert err.reason == :non_root_cursor

    # Wildcard + nested pull on %Xitdb{} (moment -1) and on pinned root cursor (moment 0)
    assert {:ok, %{"users" => %{"a" => 2}}} = Xitdb.pull(db, "{*, users{a}}")
    assert {:ok, %{"users" => %{"a" => 1}}} = Xitdb.pull(Xitdb.as_of(db, 0), "{*, users{a}}")
  end

  test "Xitdb.at/1 lens handles in-bounds, negative, out-of-bounds, and :pop on plain Elixir lists" do
    list = ["a", "b", "c"]

    assert get_in(list, [Xitdb.at(0)]) == "a"
    assert get_in(list, [Xitdb.at(-1)]) == "c"
    assert get_in(list, [Xitdb.at(3)]) == nil
    assert get_in(list, [Xitdb.at(-4)]) == nil

    assert {"a", ["A", "b", "c"]} = get_and_update_in(list, [Xitdb.at(0)], &{&1, "A"})
    assert {"c", ["a", "b", "C"]} = get_and_update_in(list, [Xitdb.at(-1)], &{&1, "C"})
    assert {"b", ["a", "c"]} = pop_in(list, [Xitdb.at(1)])

    # Out-of-bounds positive (idx == len) and negative (resolved < 0) leave list unchanged
    assert {nil, ^list} = get_and_update_in(list, [Xitdb.at(3)], &{&1, "X"})
    assert {nil, ^list} = get_and_update_in(list, [Xitdb.at(-4)], &{&1, "X"})
    assert {nil, ^list} = pop_in(list, [Xitdb.at(3)])
    assert {nil, ^list} = pop_in(list, [Xitdb.at(-4)])
  end

  @tag :tmp_dir
  test "compact/2 file backend, pinned select on moment 0, empty_root query, wildcard pull, and nested with_tx_context",
       %{tmp_dir: tmp_dir} do
    payload = String.duplicate("compressible payload text ", 20)
    db = Xitdb.open!(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    db =
      db
      |> Xitdb.transact!(%{"users" => %{"a" => 1, "b" => 99}, "other" => "ok"})
      |> Xitdb.transact!(%{"users" => %{"a" => 2, "b" => 88}, "other" => "ok2"})

    # 1. compact/2 to file backend sets :buffered_file and path
    compact_path = Path.join(tmp_dir, "compacted.xdb")
    {:ok, file_compacted} = Xitdb.compact(db, path: compact_path)
    on_exit(fn -> Xitdb.close(file_compacted) end)
    assert file_compacted.backend == :buffered_file
    assert file_compacted.path == compact_path
    assert file_compacted["other"] == "ok2"

    # 2. select/3 on as_of(db, 0) and as_of(db, 1) with @0
    snap0 = Xitdb.as_of(db, 0)
    assert {:ok, 1} = Xitdb.select(snap0, ".users.a")
    assert {:ok, 1} = Xitdb.select(snap0, ["users", "a"])
    assert {:ok, 1} = Xitdb.select(Xitdb.as_of(db, 1), "@0.users.a")

    # 3. select!(db, "") returns a pinned root cursor
    root_sel = Xitdb.select!(db, "")
    assert %Cursor{root: true, moment: m} = root_sel
    assert m >= 0

    # 4. query/3 on Cursor.empty_root/1 queries an isolated empty memory DB
    empty_root = Cursor.empty_root(db.db_ref)
    assert {:ok, %{rows: []}} = Xitdb.query(empty_root, "find ?e\nwhere\n  .users[?e].a = ?v")

    # 5. wildcard pull with sibling keys + nested spec + compressed value
    {:ok, db} =
      Xitdb.transact(db, %{
        "users" => %{"a" => {:compressed, payload, min_bytes: 0}, "b" => 7},
        "other" => "ok3"
      })

    assert {:ok, %{"other" => "ok3", "users" => %{"a" => ^payload}}} =
             Xitdb.pull(db, "{*, users{a}}")

    # 6. nested with_tx_context preserves outer meta and ignores empty doc ""
    Xitdb.with_tx_context([doc: "outer-doc", meta: %{"actor" => "alice"}], fn ->
      Xitdb.with_tx_context([doc: "", meta: %{"trace" => "t1"}], fn ->
        ctx = Xitdb.current_tx_context()
        assert ctx.doc == "outer-doc"
        assert ctx.meta == %{"actor" => "alice", "trace" => "t1"}

        {:ok, db2} = Xitdb.transact(db, %{"ctx_key" => "v"})
        {:ok, tx_meta} = Xitdb.tx_meta(db2)
        assert tx_meta["actor"] == "alice"
        assert tx_meta["trace"] == "t1"
      end)
    end)

    # 7. diff_moments include_internal: true vs false
    {:ok, db} = Xitdb.transact(db, %{"big" => {:compressed, payload, min_bytes: 0}})
    {:ok, without_internal} = Xitdb.diff_moments(db, 0, 3)
    {:ok, with_internal} = Xitdb.diff_moments(db, 0, 3, include_internal: true)
    assert length(with_internal) >= length(without_internal)
    refute Enum.any?(without_internal, &String.starts_with?(&1.path, ".__blobs"))
  end

  test "open/1 rejects empty file path, select!/2 pins non-root moment, pull raw_tagged wildcard, and nested tx_meta" do
    assert {:error, %Error{reason: :missing_path}} = Xitdb.open(backend: :file, path: "")
    assert {:error, %Error{reason: :missing_path}} = Xitdb.open(backend: :buffered_file, path: "")

    payload = String.duplicate("compressible payload text ", 20)

    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(
        %{"users" => %{"a" => {:compressed, payload, min_bytes: 0}}, "other" => "ok"},
        meta: %{count: 42}
      )

    on_exit(fn -> Xitdb.close(db) end)

    # Non-root select! pins moment >= 0 and keeps root: false
    users_cur = Xitdb.select!(db, ".users")
    assert %Cursor{root: false, moment: m} = users_cur
    assert m >= 0

    # pull with raw_tagged: true preserves {:tagged, "zs", _} inside wildcard + nested spec
    assert {:ok, %{"other" => "ok", "users" => %{"a" => {:tagged, "zs", _}}}} =
             Xitdb.pull(db, "{*, users{a}}", raw_tagged: true)

    # number in tx_meta
    {:ok, meta} = Xitdb.tx_meta(db)
    assert meta["count"] == 42
  end
end
