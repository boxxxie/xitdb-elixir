defmodule Xitdb.Features.TransactionsAndTimeTravelSpec.CustomPayload do
  @moduledoc false
  defstruct [:label, :amount]
end

defimpl Xitdb.Encoder, for: Xitdb.Features.TransactionsAndTimeTravelSpec.CustomPayload do
  def encode(%{label: label, amount: amount}) do
    %{"label" => label, "amount" => amount}
  end
end

defmodule Xitdb.Features.TransactionsAndTimeTravelSpec.UnencodedPayload do
  @moduledoc false
  defstruct [:raw]
end

defmodule Xitdb.Features.TransactionsAndTimeTravelSpec do
  use Xitdb.FeatureCase, async: true

  alias Xitdb.Features.TransactionsAndTimeTravelSpec.{CustomPayload, UnencodedPayload}

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

  scenario "Xitdb.Encoder encodes Decimal, temporal structs, and custom structs across transact/3, put_in/3, and insert_at/4" do
    @given memory_database()
    @given committed_moment(%{
             "dec" => Decimal.new("199.950"),
             "date" => ~D[2026-11-19],
             "time" => ~T[09:15:30],
             "dt" => ~U[2026-11-19 09:15:30Z],
             "ndt" => ~N[2026-11-19 09:15:30],
             "custom" => %CustomPayload{label: "invoice", amount: Decimal.new("10.00")},
             "queue" => Xitdb.linked_list([~D[2026-11-20]])
           })

    @upon transacting_with_cursor(fn root ->
            root
            |> put_in(["cursor_dec"], Decimal.new("55.25"))
            |> put_in(
              ["cursor_custom"],
              %CustomPayload{label: "cursor", amount: Decimal.new("1.50")}
            )
            |> Xitdb.insert_at(["queue"], 0, ~D[2026-11-18])
          end)

    @upon attempting_failing_moment(%{"bad" => %UnencodedPayload{raw: :nope}})

    @then access_path_equals(["dec"], {:tagged, "dc", "199.950"})
    @then access_path_equals(["date"], {:tagged, "dt", "2026-11-19"})
    @then access_path_equals(["time"], {:tagged, "tm", "09:15:30"})
    @then access_path_equals(
            ["dt"],
            {:tagged, "ts",
             <<DateTime.to_unix(~U[2026-11-19 09:15:30Z], :microsecond)::signed-big-64>>}
          )
    @then access_path_equals(["ndt"], {:tagged, "nt", "2026-11-19T09:15:30"})
    @then materialized_subtree_is(
            ["custom"],
            %{"label" => "invoice", "amount" => {:tagged, "dc", "10.00"}}
          )
    @then access_path_equals(["cursor_dec"], {:tagged, "dc", "55.25"})
    @then materialized_subtree_is(
            ["cursor_custom"],
            %{"label" => "cursor", "amount" => {:tagged, "dc", "1.50"}}
          )
    @then access_path_equals(
            ["queue"],
            [{:tagged, "dt", "2026-11-18"}, {:tagged, "dt", "2026-11-20"}]
          )
    @then last_transaction_failed_with(:transaction_exception)
  end
end
