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

  test "as_of/2 handles negative and positive out-of-bounds moments consistently" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{"k" => "v"})

    err_neg =
      assert_raise Xitdb.Error, fn ->
        Xitdb.as_of(db, -99)
      end

    assert err_neg.reason == :moment_out_of_range

    oob = Xitdb.as_of(db, 99)
    assert inspect(oob) == "#Xitdb.Cursor<unresolved (:moment_out_of_range)>"

    for op <- [
          fn -> oob["k"] end,
          fn -> Xitdb.materialize(oob) end,
          fn -> Enum.to_list(oob) end
        ] do
      err = assert_raise Xitdb.Error, op
      assert err.reason == :moment_out_of_range
    end
  end

  test "Access auto-vivification and staged %Xitdb.Collection{} read-your-own-writes inside transact!" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{"existing" => %{"old" => 1}})

    test_pid = self()

    db =
      Xitdb.transact!(db, fn root ->
        root = put_in(root["a"]["b"]["c"], 42)
        assert root["a"]["b"]["c"] == 42

        root = put_in(root["existing"]["nested"]["leaf"], 7)
        assert root["existing"]["old"] == 1
        assert root["existing"]["nested"]["leaf"] == 7

        {1, root} = pop_in(root["existing"]["old"])
        assert root["existing"]["old"] == nil

        {_, root} = pop_in(root["existing"])
        root = put_in(root["existing"]["fresh"]["leaf"], 9)
        assert root["existing"]["old"] == nil
        assert root["existing"]["nested"] == nil
        assert root["existing"]["fresh"]["leaf"] == 9

        root = put_in(root["s"], Xitdb.sorted_map(%{"b" => 2, "a" => 1}))
        send(test_pid, {:in_tx_sorted, root["s"]["a"], Enum.to_list(root["s"])})
        root
      end)

    assert_receive {:in_tx_sorted, 1, [{"a", 1}, {"b", 2}]}
    assert Xitdb.db(db)["a"]["b"]["c"] == 42
    assert Xitdb.db(db)["existing"]["old"] == nil
    assert Xitdb.db(db)["existing"]["fresh"]["leaf"] == 9
    assert Xitdb.db(db)["s"].tag == :sorted_map
    assert Enum.to_list(Xitdb.db(db)["s"]) == [{"a", 1}, {"b", 2}]
  end

  test "Enum.slice on :array_list respects non-zero offset and step" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{"nums" => [10, 20, 30, 40, 50, 60]})

    nums_cursor = Xitdb.db(db)["nums"]
    assert nums_cursor.tag == :array_list
    assert Enum.slice(nums_cursor, 2..4) == [30, 40, 50]
    assert Enum.slice(nums_cursor, 1..5//2) == [20, 40, 60]
  end

  test "Enumerable.member?/2 enforces strict type and scalar equality for maps and sets" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "nums" => %{"n" => 1},
        "tags" => Xitdb.counted_set(["tag1", "tag2"])
      })

    nums_cur = Xitdb.db(db)["nums"]
    tags_cur = Xitdb.db(db)["tags"]

    assert Enum.member?(nums_cur, {"n", 1}) == true
    assert Enum.member?(nums_cur, {"n", 1.0}) == false
    assert Enum.member?(nums_cur, {:n, 1}) == false

    assert Enum.member?(tags_cur, "tag1") == true
    assert Enum.member?(tags_cur, 123) == false
  end
end
