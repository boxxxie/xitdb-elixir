defmodule Xitdb.CursorStagingAndGuardsTest do
  use ExUnit.Case, async: true

  test "Access pipeline preserves op ordering and read-your-own-writes" do
    db = Xitdb.open!(backend: :memory)

    db =
      Xitdb.transact!(db, %{
        "users" => %{
          "alice" => %{
            "age" => 30,
            "temp" => "secret",
            "roles" => Xitdb.linked_list(["staff"])
          }
        }
      })

    db =
      Xitdb.transact!(db, fn root ->
        {"secret", root} = pop_in(root["users"]["alice"]["temp"])
        assert root["users"]["alice"]["temp"] == nil

        root = put_in(root["users"]["alice"]["age"], 31)
        assert root["users"]["alice"]["age"] == 31

        root
        |> update_in(["users", "alice", "age"], &(&1 + 1))
        |> Xitdb.insert_at(["users", "alice", "roles"], 0, "owner")
        |> Xitdb.fork(".users.alice", ".backups.alice")
      end)

    assert db["users"]["alice"]["temp"] == nil
    assert db["users"]["alice"]["age"] == 32
    assert Enum.to_list(db["users"]["alice"]["roles"]) == ["owner", "staff"]
    assert db["backups"]["alice"]["age"] == 32
  end

  test "fetch/2 resolves tag_id: -1 before integer index lookup when tx_mode: false" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"items" => ["first", "second"]})

    # Unresolved moment cursor with integer lookup returns :error cleanly on map root
    assert Access.fetch(Xitdb.as_of(db, 0), 0) == :error
    assert Xitdb.as_of(db, 0)["items"][0] == "first"
  end

  test "mutating %Xitdb{} directly outside transact/3 raises ArgumentError" do
    db = Xitdb.open!(backend: :memory)

    assert_raise ArgumentError, ~r/cannot mutate %Xitdb{} directly/, fn ->
      put_in(db["users"], %{})
    end

    assert_raise ArgumentError, ~r/cannot mutate %Xitdb{} directly/, fn ->
      pop_in(db["users"])
    end
  end
end
