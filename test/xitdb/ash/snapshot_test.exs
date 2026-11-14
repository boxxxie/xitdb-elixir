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

    # By default, returns committed_db
    assert Snapshot.current_db(MockStore) == db

    # Process dict override simulates active transaction writer lease
    {:ok, tx_db} = Xitdb.open(backend: :memory)
    Process.put({:xitdb_tx_db, MockStore}, tx_db)

    assert Snapshot.current_db(MockStore) == tx_db

    Process.delete({:xitdb_tx_db, MockStore})
    assert Snapshot.current_db(MockStore) == db
  end

  test "swap_compacted_base replaces base_db while preserving reverse_fks", %{db: db} do
    reverse_fks = %{MockResource => [%{on_delete: :nilify}]}
    Snapshot.put_base(MockStore, db, reverse_fks: reverse_fks)

    {:ok, compacted_db} = Xitdb.open(backend: :memory)
    assert :ok == Snapshot.swap_compacted_base(MockStore, compacted_db, 5)

    assert Snapshot.current_moment(MockStore) == 5
    assert [%{on_delete: :nilify}] = Snapshot.reverse_fks(MockStore, MockResource)
  end
end
