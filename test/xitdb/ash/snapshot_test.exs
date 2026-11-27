defmodule Xitdb.Ash.SnapshotTest do
  use ExUnit.Case, async: false

  alias Xitdb.Ash.Store.Snapshot

  defmodule MockStore do
  end

  defmodule MockResource do
  end

  setup do
    on_exit(fn ->
      Snapshot.erase(MockStore)
    end)

    {:ok, db} = Xitdb.open(backend: :memory)
    {:ok, db: db}
  end

  test "put_base, advance_moment, and current_moment maintain moment via :atomics", %{db: db} do
    reverse_fks = %{
      MockResource => [
        %{
          source_resource: MockResource,
          source_collection: :profiles,
          source_attribute: :org_id,
          destination_attribute: :id,
          on_delete: :delete
        }
      ]
    }

    assert :ok == Snapshot.put_base(MockStore, db, moment: -1, reverse_fks: reverse_fks)
    assert Snapshot.current_moment(MockStore) == -1

    assert :ok == Snapshot.advance_moment(MockStore, 3)
    assert Snapshot.current_moment(MockStore) == 3

    assert [%{on_delete: :delete}] = Snapshot.reverse_fks(MockStore, MockResource)
  end

  test "current_db resolves process dictionary transaction handle over committed db", %{db: db} do
    Snapshot.put_base(MockStore, db)

    # By default, returns inert empty_root cursor for uncommitted store
    assert Snapshot.current_db(MockStore) == Xitdb.Cursor.empty_root(db.db_ref)

    # Process dict override simulates active transaction writer lease
    {:ok, tx_db} = Xitdb.open(backend: :memory)
    Process.put({:xitdb_tx_db, MockStore}, tx_db)

    assert Snapshot.current_db(MockStore) == tx_db

    Process.delete({:xitdb_tx_db, MockStore})
    assert Snapshot.current_db(MockStore) == Xitdb.Cursor.empty_root(db.db_ref)
  end

  test "swap_compacted_base replaces base_db while preserving reverse_fks", %{db: db} do
    reverse_fks = %{MockResource => [%{on_delete: :nilify}]}
    Snapshot.put_base(MockStore, db, reverse_fks: reverse_fks)

    {:ok, compacted_db} = Xitdb.open(backend: :memory)
    assert :ok == Snapshot.swap_compacted_base(MockStore, compacted_db, 5)

    assert Snapshot.current_moment(MockStore) == 5
    assert [%{on_delete: :nilify}] = Snapshot.reverse_fks(MockStore, MockResource)
  end

  test "as_of/2 isolates uncommitted moments on empty stores and positive offsets", %{db: db} do
    # Empty store (visible_moment == -1) with an uncommitted moment 0 staged on disk
    Snapshot.put_base(MockStore, db)
    {:ok, _staged_db} = Xitdb.transact(db, %{"uncommitted" => true})

    for bad_moment <- [-2, -1, 0, 1] do
      assert_raise Xitdb.Error, fn ->
        Snapshot.as_of(MockStore, bad_moment)
      end
    end

    # Advance committed moment to 0, stage uncommitted moment 1
    Snapshot.advance_moment(MockStore, 0)
    {:ok, _staged_db2} = Xitdb.transact(db, %{"second_uncommitted" => true})

    assert Snapshot.as_of(MockStore, 0)["uncommitted"] == true
    assert Snapshot.as_of(MockStore, -1)["uncommitted"] == true

    for bad_moment <- [-2, 1] do
      assert_raise Xitdb.Error, fn ->
        Snapshot.as_of(MockStore, bad_moment)
      end
    end
  end

  test "guards reject invalid argument types on Snapshot API functions", %{db: db} do
    Snapshot.put_base(MockStore, db)

    assert_raise FunctionClauseError, fn -> apply(Snapshot, :put_base, ["not_atom", db, []]) end
    assert_raise FunctionClauseError, fn -> apply(Snapshot, :put_base, [MockStore, db, :bad]) end

    assert_raise FunctionClauseError, fn ->
      apply(Snapshot, :swap_compacted_base, ["not_atom", db, 0])
    end

    assert_raise FunctionClauseError, fn ->
      apply(Snapshot, :swap_compacted_base, [MockStore, db, :bad])
    end

    assert_raise FunctionClauseError, fn ->
      apply(Snapshot, :swap_compacted_base, [MockStore, db, -2])
    end

    assert_raise FunctionClauseError, fn -> apply(Snapshot, :advance_moment, ["not_atom", 0]) end

    assert_raise FunctionClauseError, fn ->
      apply(Snapshot, :advance_moment, [MockStore, :bad])
    end

    assert_raise FunctionClauseError, fn -> apply(Snapshot, :advance_moment, [MockStore, -1]) end

    assert_raise FunctionClauseError, fn -> apply(Snapshot, :as_of, ["not_atom", 0]) end
    assert_raise FunctionClauseError, fn -> apply(Snapshot, :as_of, [MockStore, "0"]) end

    assert_raise FunctionClauseError, fn ->
      apply(Snapshot, :reverse_fks, ["not_atom", MockResource])
    end

    assert_raise FunctionClauseError, fn ->
      apply(Snapshot, :reverse_fks, [MockStore, "not_atom"])
    end
  end

  test "current_db_or_nil/1 returns nil for unstarted store, committed db for started store, and sandbox db when checked out",
       %{db: db} do
    assert Snapshot.current_db_or_nil(MockStore) == nil

    # Sandbox checkout on a store whose :persistent_term entry is absent
    Snapshot.put_base(MockStore, db)
    Xitdb.Ash.TestSandbox.checkout([MockStore])
    Snapshot.erase(MockStore)

    try do
      assert %Xitdb.Cursor{} = Snapshot.current_db_or_nil(MockStore)
    after
      Xitdb.Ash.TestSandbox.checkin([MockStore])
    end

    assert Snapshot.current_db_or_nil(MockStore) == nil

    # Started store resolves committed db
    Snapshot.put_base(MockStore, db)
    assert Snapshot.current_db_or_nil(MockStore) == Xitdb.Cursor.empty_root(db.db_ref)
  end

  test "caller_dict_lookup inherits :xitdb_as_of_db and :xitdb_tx_db from pid and registered atom $callers",
       %{db: db} do
    Snapshot.put_base(MockStore, db)
    {:ok, db1} = Xitdb.open(backend: :memory)
    {:ok, db2} = Xitdb.open(backend: :memory)

    reg_name = :"xitdb_snapshot_caller_#{System.unique_integer([:positive])}"
    Process.register(self(), reg_name)

    on_exit(fn ->
      if Process.whereis(reg_name) == self(), do: Process.unregister(reg_name)
    end)

    # 1. Inherits :xitdb_as_of_db via registered atom name, skipping nil and unregistered atoms
    Process.put({:xitdb_as_of_db, MockStore}, db1)

    child_res =
      Task.async(fn ->
        Process.put(:"$callers", [nil, :unregistered_xitdb_caller_xyz, reg_name])
        {Snapshot.current_db(MockStore), Snapshot.current_db_or_nil(MockStore)}
      end)
      |> Task.await()

    assert child_res == {db1, db1}

    # 2. Falls back to :xitdb_tx_db when :xitdb_as_of_db is nil
    Process.put({:xitdb_as_of_db, MockStore}, nil)
    Process.put({:xitdb_tx_db, MockStore}, db2)

    child_tx_res =
      Task.async(fn ->
        Process.put(:"$callers", [reg_name])
        Snapshot.current_db(MockStore)
      end)
      |> Task.await()

    assert child_tx_res == db2

    Process.delete({:xitdb_as_of_db, MockStore})
    Process.delete({:xitdb_tx_db, MockStore})
  end
end
