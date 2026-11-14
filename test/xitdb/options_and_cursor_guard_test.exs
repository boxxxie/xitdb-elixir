defmodule Xitdb.OptionsAndCursorGuardTest do
  use ExUnit.Case, async: true
  use Xitdb.DSL

  alias Xitdb.Error

  test "Xitdb.Error.wrap/2 and unwrap!/1 normalize results and raise wrapped errors" do
    assert :ok == Error.wrap(:ok)
    assert {:ok, 42} == Error.wrap({:ok, 42})

    existing = %Error{reason: :already_wrapped, details: %{k: 1}}
    assert {:error, ^existing} = Error.wrap({:error, existing}, %{k: 2})
    assert ^existing = Error.wrap(existing, %{k: 2})

    assert {:error, %Error{reason: :boom, details: %{ctx: :pull}}} =
             Error.wrap({:error, :boom}, %{ctx: :pull})

    assert %Error{reason: :invalid_options, details: %{message: "bad"}} =
             Error.wrap(:invalid_options, %{message: "bad"})

    assert 42 == Error.unwrap!({:ok, 42})

    assert_raise Error, fn ->
      Error.unwrap!({:error, existing})
    end
  end

  test "NimbleOptions rejects unknown or mistyped options across compact/2, transact/3, transact_ops/3, query/3, and eager tx" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"users" => %{"alice" => %{"role" => "admin"}}})

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.compact(db, file: "/tmp/typo.xit")

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.transact(db, %{}, docs: "typo")

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.transact(db, %{}, "not_a_keyword_list")

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.transact_ops(db, [], bad: true)

    assert {:error, %Error{reason: :invalid_options}} =
             Xitdb.query(db, ~s(find ?u where .users[?u].role = "admin"), moments: 0)

    assert {:error, %Error{reason: :invalid_options}} =
             (tx db, base_moment: "bad_moment" do
                update users["alice"].role, &String.upcase/1
              end)
  end

  test "index_rules applies identically across map, %Cursor{} callback, map-returning callback, and transact_ops/tx" do
    db = Xitdb.open!(backend: :memory)
    rules = [{:index_on, :users, :email, "email->user_id"}]

    db =
      Xitdb.transact!(
        db,
        %{"users" => %{"u1" => %{"email" => "u1@acme.io"}}},
        index_rules: rules
      )

    db =
      Xitdb.transact!(
        db,
        fn root -> put_in(root["users"]["u2"], %{"email" => "u2@acme.io"}) end,
        index_rules: rules
      )

    db =
      Xitdb.transact!(
        db,
        fn _root -> %{"users" => %{"u3" => %{"email" => "u3@acme.io"}}} end,
        index_rules: rules
      )

    db =
      tx! db, index_rules: rules do
        index_on :users, :email, "email->user_id"
        put users["u4"].email, "u4@acme.io"
      end

    assert db["email->user_id"]["u1@acme.io"] == "u1"
    assert db["email->user_id"]["u2@acme.io"] == "u2"
    assert db["email->user_id"]["u3@acme.io"] == "u3"
    assert db["email->user_id"]["u4@acme.io"] == "u4"
  end

  test "Xitdb.query/3 preserves historical cursor moment when :moment option is omitted" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"users" => %{"alice" => %{"role" => "admin"}}})
    db = Xitdb.transact!(db, %{"users" => %{"bob" => %{"role" => "admin"}}})

    snap0 = Xitdb.as_of(db, 0)

    assert {:ok, %{rows: [["alice"]]}} =
             Xitdb.query(snap0, ~s(find ?u where .users[?u].role = "admin"))
  end

  test "Xitdb.select/2 allows committed root snapshots and rejects child sub-cursors and tx_mode cursors" do
    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"users" => %{"alice" => %{"role" => "admin"}}})

    assert Xitdb.select!(Xitdb.db(db), ".users.alice.role") == "admin"
    assert Xitdb.select!(Xitdb.as_of(db, 0), ".users.alice.role") == "admin"

    users_cursor = db["users"]

    assert {:error, %Error{reason: :non_root_cursor}} =
             Xitdb.select(users_cursor, ".alice.role")

    {:ok, _} =
      Xitdb.transact(db, fn tx_root ->
        assert {:error, %Error{reason: :non_root_cursor, details: %{tx_mode: true}}} =
                 Xitdb.select(tx_root, ".users.alice.role")

        tx_root
      end)
  end
end
