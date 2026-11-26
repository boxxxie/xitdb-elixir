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
end
