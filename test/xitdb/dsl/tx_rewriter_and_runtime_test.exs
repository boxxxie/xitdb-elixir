defmodule Xitdb.DSL.TxRewriterAndRuntimeTest do
  use ExUnit.Case, async: true

  defmodule PlainCatalogSchema do
    def __xitdb_collection__, do: :items
    def __xitdb_indexes__, do: [sku: "sku->item_id"]
  end

  test "Xitdb.Ash.Tx.tx_for! works standalone with module-attribute schema lists" do
    defmodule StandaloneCaller do
      require Xitdb.Ash.Tx
      @schemas [PlainCatalogSchema]

      def seed(db) do
        Xitdb.Ash.Tx.tx_for! db, @schemas do
          put items["i1"].sku, "KB-01"
        end
      end
    end

    db = Xitdb.open!(backend: :memory) |> StandaloneCaller.seed()
    assert db["sku->item_id"]["KB-01"] == "i1"
  end

  test "read-your-own-writes stays consistent across ancestors, descendants, %Collection{}, lists, and fork" do
    use Xitdb.DSL

    db = Xitdb.open!(backend: :memory)

    db =
      tx! db do
        put users["alice"], %{"name" => "Alice", "role" => "viewer"}
      end

    db =
      tx! db do
        # 1a. Child put on committed ancestor -> update ancestor preserves sibling keys + staged child
        put users["alice"].role, "admin"
        update users["alice"], fn m -> Map.put(m, "tier", "gold") end

        # 1b. Child put on uncommitted parent -> update parent auto-vivifies and preserves child
        put users["bob"].role, "editor"
        update users["bob"], fn m -> Map.put(m, "name", "Bob") end

        # 1c. Overwriting a parent map evicts stale staged child values
        put users["carol"], %{"login_count" => 10, "role" => "member"}
        put users["carol"], %{"role" => "admin"}
        update users["carol"].login_count, 0, &(&1 + 1)

        # 2. %Xitdb.Collection{} wrappers unwrap to native maps/lists/MapSets on update
        put org.counted(:depts), Xitdb.counted_map(%{"eng" => %{"headcount" => 5}})

        update org.counted(:depts), fn m ->
          assert is_map(m) and not is_struct(m)
          put_in(m, ["eng", "headcount"], m["eng"]["headcount"] + 2)
        end

        # 3. append, insert, and slice update staged list state before update
        put queue, Xitdb.linked_list(["b", "c"])
        insert queue[[0]], "a"
        append queue, "d"
        slice queue, 1..2

        update queue, fn list ->
          assert list == ["b", "c"]
          list ++ ["done"]
        end

        # 4. fork snapshots staged source state and isolates subsequent edits
        fork users["alice"], backups["alice"]
        put users["alice"].role, "superadmin"

        update backups["alice"].role, fn role ->
          assert role == "admin"
          role <> "-snapshot"
        end
      end

    assert Xitdb.materialize(db["users"]["alice"]) == %{
             "name" => "Alice",
             "role" => "superadmin",
             "tier" => "gold"
           }

    assert Xitdb.materialize(db["users"]["bob"]) == %{"name" => "Bob", "role" => "editor"}
    assert Xitdb.materialize(db["users"]["carol"]) == %{"login_count" => 1, "role" => "admin"}
    assert db["org"]["depts"]["eng"]["headcount"] == 7
    assert Enum.to_list(db["queue"]) == ["b", "c", "done"]

    assert Xitdb.materialize(db["backups"]["alice"]) == %{
             "name" => "Alice",
             "role" => "admin-snapshot",
             "tier" => "gold"
           }
  end

  test "BUG-035/036/055: negative/positive list index RYOW, array_list rm RYOW, and tx inline options" do
    use Xitdb.DSL

    db = Xitdb.open!(backend: :memory)
    db = Xitdb.transact!(db, %{"items" => ["a", "b", "c"], "k" => "old"})

    # BUG-055: tx! 2-arity with keyword option + inline do:
    db = tx!(db, meta: %{src: "inline"}, do: put(k, "new"))
    assert db["k"] == "new"

    # BUG-035: put via negative index then update via positive index (and vice versa)
    db =
      tx! db do
        put items[-1], "Z"
        update items[2], &String.downcase/1
        put items[0], "A"
        update items[-3], &(&1 <> "!")
      end

    assert Enum.to_list(db["items"]) == ["A!", "b", "z"]

    # BUG-036: rm on :array_list element followed by update/fork does not raise FunctionClauseError in rm_at_steps/2
    res =
      tx db do
        rm items[1]

        update items, fn list ->
          send(self(), {:ryow_after_rm, list})
          list ++ ["tail"]
        end

        fork items, backup_items
      end

    assert_received {:ryow_after_rm, ["A!", "z"]}
    assert {:error, %Xitdb.Error{reason: "Write_Not_Allowed"}} = res
    :ok = Xitdb.close(db)
  end
end
