defmodule Xitdb.Features.EnumerableCollectionsSpec do
  use Xitdb.FeatureCase, async: true

  scenario "Enum.count/1, Enum.member?/2, and Enum.slice/2 leverage native xitdb collection structures" do
    @given memory_database()
    @given committed_moment(%{
             "counted_users" =>
               Xitdb.counted_map(%{
                 "alice" => "admin",
                 "bob" => "editor",
                 "carol" => "viewer"
               }),
             "sorted_catalog" =>
               Xitdb.sorted_map(%{
                 "cherry" => 30,
                 "apple" => 10,
                 "banana" => 20,
                 "date" => 40
               }),
             "radix_items" => ["item-0", "item-1", "item-2", "item-3", "item-4", "item-5"],
             "linked_queue" => Xitdb.linked_list(["job-a", "job-b", "job-c", "job-d", "job-e"]),
             "permissions" => Xitdb.counted_set(["read", "write", "deploy"]),
             "sorted_tags" => Xitdb.sorted_set(["zeta", "alpha", "omega", "beta"])
           })

    @then enumerable_count_is(["counted_users"], 3)
    @then enumerable_count_is(["sorted_catalog"], 4)
    @then enumerable_count_is(["radix_items"], 6)
    @then enumerable_count_is(["linked_queue"], 5)
    @then enumerable_count_is(["permissions"], 3)
    @then enumerable_count_is(["sorted_tags"], 4)

    @then enumerable_membership_is(["permissions"], "deploy", true)
    @then enumerable_membership_is(["permissions"], "delete_prod", false)
    @then enumerable_membership_is(["sorted_tags"], "alpha", true)
    @then enumerable_membership_is(["sorted_tags"], "gamma", false)
    @then enumerable_membership_is(["counted_users"], {"alice", "admin"}, true)
    @then enumerable_membership_is(["counted_users"], {"alice", "viewer"}, false)

    @then enumerable_slice_is(["radix_items"], 2..4, ["item-2", "item-3", "item-4"])
    @then enumerable_slice_is(["linked_queue"], 1..3, ["job-b", "job-c", "job-d"])
  end

  scenario "Sorted_Map and Sorted_Set stream in deterministic lexicographical order while Stream.take/2 halts early" do
    @given memory_database()
    @given committed_moment(%{
             "leaderboard" =>
               Xitdb.sorted_map(%{
                 "rank:03" => "Charlie",
                 "rank:01" => "Alice",
                 "rank:04" => "Diana",
                 "rank:02" => "Bob"
               }),
             "badges" => Xitdb.sorted_set(["gold", "bronze", "silver", "platinum"])
           })

    @then enumerable_entries_are(
            ["leaderboard"],
            [
              {"rank:01", "Alice"},
              {"rank:02", "Bob"},
              {"rank:03", "Charlie"},
              {"rank:04", "Diana"}
            ],
            ordered: true
          )

    @then enumerable_entries_are(
            ["badges"],
            ["bronze", "gold", "platinum", "silver"],
            ordered: true
          )

    @then stream_take_is(
            ["leaderboard"],
            2,
            [{"rank:01", "Alice"}, {"rank:02", "Bob"}]
          )
  end

  scenario "Xitdb.materialize/1 eagerly converts subtrees while Inspect prints a bounded summary" do
    @given memory_database()
    @given committed_moment(%{
             "team" => %{
               "name" => "Core Platform",
               "members" => ["alice", "bob"],
               "flags" => Xitdb.sorted_set(["oncall", "verified"])
             }
           })

    @then materialized_subtree_is(
            ["team"],
            %{
              "name" => "Core Platform",
              "members" => ["alice", "bob"],
              "flags" => MapSet.new(["oncall", "verified"])
            }
          )

    @then cursor_inspect_includes(["team"], ["#Xitdb.Cursor<", "members", "name"])
  end
end
