defmodule Xitdb.Features.TransactionsAndTimeTravelSpec do
  use Xitdb.FeatureCase, async: true

  scenario "client mutates nested structures using put_in/3, update_in/3, and pop_in/2 inside Xitdb.transact/2" do
    @given memory_database()
    @given committed_moment(%{
             "users" => %{
               "alice" => %{"name" => "Alice", "logins" => 1, "temp_token" => "xyz-987"},
               "bob" => %{"name" => "Bob", "logins" => 5}
             },
             "queue" => Xitdb.linked_list(["first", "third"])
           })

    @upon transacting_with_cursor(fn root ->
            {_, root} = pop_in(root["users"]["alice"]["temp_token"])

            root
            |> put_in(["users", "alice", "role"], "staff")
            |> update_in(["users", "alice", "logins"], &(&1 + 1))
            |> Xitdb.insert_at(["queue"], 1, "second")
          end)

    @then database_moment_count_is(2)
    @then access_path_equals(["users", "alice", "role"], "staff")
    @then access_path_equals(["users", "alice", "logins"], 2)
    @then access_path_equals(["users", "alice", "temp_token"], nil)
    @then access_path_equals(["users", "bob", "logins"], 5)
    @then access_path_equals(["queue"], ["first", "second", "third"])
  end

  scenario "failed or aborted transactions roll back atomically without corrupting prior moments" do
    @given memory_database()
    @given committed_moment(%{
             "account" => %{"balance" => 500, "status" => "open"}
           })

    @upon attempting_failing_transaction(fn _root ->
            {:abort, :insufficient_funds}
          end)

    @then last_transaction_failed_with(:insufficient_funds)
    @then database_moment_count_is(1)
    @then access_path_equals(["account", "balance"], 500)
  end

  scenario "historical snapshots pinned via Xitdb.as_of/2 remain immutable across subsequent transactions" do
    @given memory_database()
    @given committed_moment(
             %{"config" => %{"version" => 1, "env" => "staging"}},
             doc: "Initial config"
           )
    @given pinned_snapshot(:v1_snapshot, 0)
    @given committed_moment(
             %{"config" => %{"version" => 2, "env" => "production"}},
             doc: "Promote to prod"
           )
    @given committed_moment(
             %{"config" => %{"version" => 3, "env" => "production", "region" => "us-east"}},
             doc: "Add region"
           )

    @upon diffing_moments(:diff_0_to_2, 0, 2)
    @upon inspecting_history_of(:version_history, ".config.version")

    @then snapshot_access_path_equals(:v1_snapshot, ["config", "version"], 1)
    @then snapshot_access_path_equals(:v1_snapshot, ["config", "env"], "staging")
    @then access_path_equals(["config", "version"], 3)
    @then access_path_equals(["config", "region"], "us-east")

    @then diff_changes_are(:diff_0_to_2, [
            {:put, ".config.version", 3},
            {:put, ".config.env", "production"},
            {:put, ".config.region", "us-east"}
          ])

    @then history_lineage_is(:version_history, [
            %{moment: 0, value: 1, doc: "Initial config"},
            %{moment: 1, value: 2, doc: "Promote to prod"},
            %{moment: 2, value: 3, doc: "Add region"}
          ])
  end
end
