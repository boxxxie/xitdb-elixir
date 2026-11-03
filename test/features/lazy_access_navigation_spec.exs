defmodule Xitdb.Features.LazyAccessNavigationSpec do
  use Xitdb.FeatureCase, async: true

  scenario "client navigates nested maps and lists using standard Elixir Access brackets and get_in/2" do
    @given memory_database()
    @given committed_moment(%{
             "users" => %{
               "alice" => %{
                 "name" => "Alice Liddell",
                 "age" => 30,
                 "score" => -42,
                 "ratio" => 3.14159,
                 "active" => true,
                 "bio" => {:tagged, "md", "# Wonderland"},
                 "roles" => ["admin", "architect", "reviewer"]
               },
               "bob" => %{
                 "name" => "Bob Builder",
                 "roles" => ["member"]
               }
             }
           })

    @upon navigating_access_path(:alice_name, ["users", "alice", "name"])
    @upon navigating_access_path(:alice_age, ["users", "alice", "age"])
    @upon navigating_access_path(:alice_score, ["users", "alice", "score"])
    @upon navigating_access_path(:alice_ratio, ["users", "alice", "ratio"])
    @upon navigating_access_path(:alice_active, ["users", "alice", "active"])
    @upon navigating_access_path(:alice_bio, ["users", "alice", "bio"])
    @upon navigating_access_path(:first_role, ["users", "alice", "roles", 0])
    @upon navigating_access_path(:last_role, ["users", "alice", "roles", -1])
    @upon navigating_access_path(:missing_user, ["users", "charlie", "name"])
    @upon navigating_get_in(:via_get_in, ["users", "alice", "roles", Xitdb.at(1)])

    @then resolved_value_is(:alice_name, "Alice Liddell")
    @then resolved_value_is(:alice_age, 30)
    @then resolved_value_is(:alice_score, -42)
    @then resolved_value_is(:alice_ratio, 3.14159)
    @then resolved_value_is(:alice_active, true)
    @then resolved_value_is(:alice_bio, {:tagged, "md", "# Wonderland"})
    @then resolved_value_is(:first_role, "admin")
    @then resolved_value_is(:last_role, "reviewer")
    @then resolved_value_is(:missing_user, nil)
    @then resolved_value_is(:via_get_in, "architect")
  end

  scenario "intermediate containers remain lazy 9-byte Slot cursors rather than eagerly materializing" do
    @given memory_database()
    @given committed_moment(%{
             "org" => %{
               "departments" => Xitdb.counted_map(%{"engineering" => %{"headcount" => 42}}),
               "directory" => Xitdb.sorted_map(%{"alice" => "staff", "bob" => "senior"}),
               "backlog" => Xitdb.linked_list(["task-1", "task-2", "task-3"]),
               "events" => ["deploy-1", "deploy-2"]
             }
           })

    @upon navigating_access_path(:depts_node, ["org", "departments"])
    @upon navigating_access_path(:dir_node, ["org", "directory"])
    @upon navigating_access_path(:backlog_node, ["org", "backlog"])
    @upon navigating_access_path(:events_node, ["org", "events"])

    @then resolved_node_is_lazy_cursor(:depts_node, kind: :counted_hash_map)
    @then resolved_node_is_lazy_cursor(:dir_node, kind: :sorted_map)
    @then resolved_node_is_lazy_cursor(:backlog_node, kind: :linked_array_list)
    @then resolved_node_is_lazy_cursor(:events_node, kind: :array_list)
  end

  scenario "lazy Cursor structs are pure values that can be passed across concurrent BEAM Tasks safely" do
    @given memory_database()
    @given committed_moment(%{
             "profiles" => %{
               "u1" => "Ada",
               "u2" => "Grace",
               "u3" => "Edsger",
               "u4" => "Barbara",
               "u5" => "Leslie",
               "u6" => "Donald"
             }
           })

    @upon reading_cursor_across_tasks(
            :task_values,
            ["profiles"],
            ["u1", "u2", "u3", "u4", "u5", "u6"]
          )

    @then resolved_value_is(
            :task_values,
            ["Ada", "Grace", "Edsger", "Barbara", "Leslie", "Donald"]
          )
  end
end
