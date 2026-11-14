defmodule Xitdb.CursorRefactorTest do
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

    assert Access.fetch(Xitdb.as_of(db, 0), 0) == :error
    assert Xitdb.as_of(db, 0)["items"][0] == "first"
  end

  test "Enum.slice handles stepped and empty ranges without overshooting collection bounds" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"items" => ["a", "b", "c", "d", "e"]})

    assert Enum.slice(db["items"], 0..4//2) == ["a", "c", "e"]
    assert Enum.slice(db["items"], 1..3//2) == ["b", "d"]
    assert Enum.slice(db["items"], 4..4//2) == ["e"]
    assert Enum.slice(db["items"], 3..1//1) == []
  end

  test "Inspect renders child cursors without quotes and handles unresolved cursors safely" do
    empty_db = Xitdb.open!(backend: :memory)
    assert inspect(Xitdb.as_of(empty_db, 0)) =~ "preview: []"

    db = Xitdb.transact!(empty_db, %{"users" => %{"alice" => %{"age" => 30}}})
    assert inspect(Xitdb.as_of(db, 99)) =~ "#Xitdb.Cursor<unresolved (:moment_out_of_range)>"

    rendered = inspect(Xitdb.db(db))
    assert rendered =~ ~s({"users", <hash_map>})
    refute rendered =~ ~s(:"<hash_map>")

    closed_cur = Xitdb.as_of(db, 0)
    :ok = Xitdb.close(db)
    assert inspect(closed_cur) =~ "#Xitdb.Cursor<unresolved (:closed)>"
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
