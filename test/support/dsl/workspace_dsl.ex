if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.TestDSL.WorkspaceDSL do
    @moduledoc false
    import ExUnit.Assertions

    alias Xitdb.TestDrivers.WorkspaceDriver

    defmodule World do
      @moduledoc false
      defstruct [
        :test_id,
        orgs: %{},
        members: %{},
        events: %{},
        sessions: %{},
        seats: %{},
        last_result: nil,
        search_hits: [],
        bulk_stats: nil
      ]

      @type t :: %__MODULE__{
              test_id: pos_integer(),
              orgs: map(),
              members: map(),
              events: map(),
              sessions: map(),
              seats: map(),
              last_result: term(),
              search_hits: list(),
              bulk_stats: map() | nil
            }
    end

    @spec new_world(map()) :: World.t()
    def new_world(ex_unit_ctx) when is_map(ex_unit_ctx) do
      %World{test_id: Map.get(ex_unit_ctx, :test_id, System.unique_integer([:positive]))}
    end

    # -- @given Steps --

    def firm(%World{} = ctx, label, opts \\ []) do
      domain = unique_domain(ctx, Keyword.get(opts, :domain, "#{slugify(label)}.ca"))
      slug = "#{slugify(label)}-#{ctx.test_id}"

      org =
        WorkspaceDriver.seed_organization(%{
          name: label,
          domain: domain,
          slug: slug,
          mandate: Keyword.get(opts, :mandate)
        })

      %World{ctx | orgs: Map.put(ctx.orgs, label, org)}
    end

    def member(%World{} = ctx, label, opts \\ []) do
      firm_id =
        case Keyword.get(opts, :firm) do
          nil -> nil
          firm_label -> Map.fetch!(ctx.orgs, firm_label).id
        end

      raw_email = Keyword.get(opts, :email, "#{slugify(label)}@allocator.ca")

      profile =
        WorkspaceDriver.enrol_member(%{
          email: unique_email(ctx, raw_email),
          full_name: label,
          headline: Keyword.get(opts, :headline, "Allocator"),
          role: Keyword.get(opts, :role, :member),
          visibility: Keyword.get(opts, :visibility, :public),
          compensation_band: Keyword.get(opts, :compensation_band),
          organization_id: firm_id
        })

      %World{ctx | members: Map.put(ctx.members, label, profile)}
    end

    def direct_message(%World{} = ctx, opts) do
      sender = Map.fetch!(ctx.members, Keyword.fetch!(opts, :from))
      recipient = Map.fetch!(ctx.members, Keyword.fetch!(opts, :to))
      body = Keyword.fetch!(opts, :body)
      _ = WorkspaceDriver.send_direct_message(sender.id, recipient.id, body)
      ctx
    end

    def conference_event(%World{} = ctx, title, opts) do
      organizer = Map.fetch!(ctx.orgs, Keyword.fetch!(opts, :organizer))
      session_specs = Keyword.get(opts, :sessions, [])

      event_attrs = %{
        title: title,
        location_city: Keyword.get(opts, :city),
        location_name: Keyword.fetch!(opts, :venue)
      }

      {event, sessions} =
        WorkspaceDriver.schedule_event_with_sessions(organizer.id, event_attrs, session_specs)

      sessions_by_title =
        Enum.reduce(sessions, ctx.sessions, fn s, acc -> Map.put(acc, s.title, s) end)

      %World{
        ctx
        | events: Map.put(ctx.events, title, event),
          sessions: sessions_by_title
      }
    end

    def confirmed_seat(%World{} = ctx, opts) do
      session = Map.fetch!(ctx.sessions, Keyword.fetch!(opts, :session))
      member = Map.fetch!(ctx.members, Keyword.fetch!(opts, :member))
      seat_no = Keyword.fetch!(opts, :seat)

      {:ok, seat} = WorkspaceDriver.reserve_seat(session.id, member.id, seat_no)
      %World{ctx | seats: Map.put(ctx.seats, {session.title, member.full_name, seat_no}, seat)}
    end

    # -- @upon Steps --

    def updating_profile_headline(%World{} = ctx, target_label, opts) do
      actor = Map.fetch!(ctx.members, Keyword.fetch!(opts, :as))
      target = Map.fetch!(ctx.members, target_label)
      headline = Keyword.fetch!(opts, :to)
      result = WorkspaceDriver.edit_profile(target, %{headline: headline}, actor)
      %World{ctx | last_result: result}
    end

    def changing_member_email(%World{} = ctx, target_label, opts) do
      actor = Map.fetch!(ctx.members, Keyword.fetch!(opts, :as))
      target = Map.fetch!(ctx.members, target_label)
      new_email = unique_email(ctx, Keyword.fetch!(opts, :to))

      case WorkspaceDriver.change_member_email(target, new_email, actor) do
        {:ok, updated} = ok ->
          %World{ctx | members: Map.put(ctx.members, target_label, updated), last_result: ok}

        {:error, _} = err ->
          %World{ctx | last_result: err}
      end
    end

    def viewing_profile_counter(%World{} = ctx, target_label, opts) do
      actor = Map.fetch!(ctx.members, Keyword.fetch!(opts, :as))
      target = Map.fetch!(ctx.members, target_label)
      result = WorkspaceDriver.increment_profile_view(target, actor)
      %World{ctx | last_result: result}
    end

    def cancelling_and_reassigning_seat(%World{} = ctx, opts) do
      session_title = Keyword.fetch!(opts, :session)
      seat_no = Keyword.fetch!(opts, :seat)
      prev_holder = Keyword.fetch!(opts, :from)
      next_holder = Keyword.fetch!(opts, :to)

      existing_seat = Map.fetch!(ctx.seats, {session_title, prev_holder, seat_no})
      _cancelled = WorkspaceDriver.cancel_seat!(existing_seat)

      session = Map.fetch!(ctx.sessions, session_title)
      next_member = Map.fetch!(ctx.members, next_holder)
      result = WorkspaceDriver.reserve_seat(session.id, next_member.id, seat_no)

      %World{ctx | last_result: result}
    end

    def attempting_duplicate_seat(%World{} = ctx, opts) do
      session = Map.fetch!(ctx.sessions, Keyword.fetch!(opts, :session))
      member = Map.fetch!(ctx.members, Keyword.fetch!(opts, :member))
      seat_no = Keyword.fetch!(opts, :seat)

      result = WorkspaceDriver.reserve_seat(session.id, member.id, seat_no)
      %World{ctx | last_result: result}
    end

    def reserving_with_aborted_nested_savepoint(%World{} = ctx, opts) do
      session = Map.fetch!(ctx.sessions, Keyword.fetch!(opts, :session))
      kept_member = Map.fetch!(ctx.members, Keyword.fetch!(opts, :keep_member))
      kept_seat = Keyword.fetch!(opts, :keep_seat)
      rolled_member = Map.fetch!(ctx.members, Keyword.fetch!(opts, :rollback_member))
      rolled_seat = Keyword.fetch!(opts, :rollback_seat)

      {:ok, kept} =
        WorkspaceDriver.run_outer_tx_with_aborted_nested_savepoint(
          fn ->
            {:ok, s} = WorkspaceDriver.reserve_seat(session.id, kept_member.id, kept_seat)
            s
          end,
          fn ->
            {:ok, s} = WorkspaceDriver.reserve_seat(session.id, rolled_member.id, rolled_seat)
            s
          end
        )

      %World{ctx | last_result: {:ok, kept}}
    end

    def renaming_firm(%World{} = ctx, firm_label, opts) do
      org = Map.fetch!(ctx.orgs, firm_label)

      updated =
        WorkspaceDriver.rename_organization(org, %{
          name: Keyword.fetch!(opts, :name),
          mandate: Keyword.fetch!(opts, :mandate)
        })

      %World{ctx | orgs: Map.put(ctx.orgs, firm_label, updated)}
    end

    def searching_directory(%World{} = ctx, query_text, opts) do
      actor = Map.fetch!(ctx.members, Keyword.fetch!(opts, :as))
      hits = WorkspaceDriver.search_member_directory(query_text, actor)
      %World{ctx | search_hits: hits}
    end

    def archiving_and_pruning_inbox(%World{} = ctx, recipient_label) do
      recipient = Map.fetch!(ctx.members, recipient_label)
      stats = WorkspaceDriver.bulk_archive_and_prune_messages(recipient.id)
      %World{ctx | bulk_stats: stats}
    end

    def submitting_membership_form(%World{} = ctx, params) do
      raw_email = Map.fetch!(params, :email)
      scoped_params = Map.put(params, :email, unique_email(ctx, raw_email))
      result = WorkspaceDriver.submit_profile_form(scoped_params)
      %World{ctx | last_result: result}
    end

    # -- @then Steps (`line: __CALLER__.line` attribution) --

    defmacro directory_visible_to(ctx_ast, viewer_label, expected_names, opts \\ []) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        viewer = Map.fetch!(ctx.members, unquote(viewer_label))
        opts = unquote(opts)

        recipient_id =
          case Keyword.get(opts, :who_messaged) do
            nil -> nil
            label -> Map.fetch!(ctx.members, label).id
          end

        profiles =
          WorkspaceDriver.list_visible_profiles(viewer, messaged_recipient_id: recipient_id)

        assert Enum.map(profiles, & &1.full_name) == unquote(expected_names)
        ctx
      end
    end

    defmacro compensation_band_for(ctx_ast, target_label, opts) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        viewer = Map.fetch!(ctx.members, Keyword.fetch!(unquote(opts), :viewed_by))
        expected = Keyword.fetch!(unquote(opts), :is)

        profiles = WorkspaceDriver.list_visible_profiles(viewer, load: [])
        found = Enum.find(profiles, &(&1.full_name == unquote(target_label)))
        assert found != nil

        case expected do
          :redacted -> assert %Ash.ForbiddenField{} = found.compensation_band
          value -> assert found.compensation_band == value
        end

        ctx
      end
    end

    defmacro action_is_forbidden(ctx_ast) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        assert {:error, %Ash.Error.Forbidden{}} = ctx.last_result
        ctx
      end
    end

    defmacro action_fails_with_invalid_field(ctx_ast, expected_field, snippet) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        expected_field = unquote(expected_field)
        assert {:error, error} = ctx.last_result
        assert Exception.message(error) =~ unquote(snippet)

        errors = Map.get(error, :errors, [])

        assert Enum.any?(errors, fn e ->
                 Map.get(e, :field) == expected_field or
                   expected_field in List.wrap(Map.get(e, :fields))
               end)

        ctx
      end
    end

    defmacro profile_summary_matches(ctx_ast, member_label, opts) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        member = Map.fetch!(ctx.members, unquote(member_label))
        opts = unquote(opts)

        [loaded] =
          WorkspaceDriver.list_visible_profiles(member,
            load: [:display_badge, :sent_message_count]
          )
          |> Enum.filter(&(&1.id == member.id))

        if badge = opts[:badge], do: assert(loaded.display_badge == badge)
        if sent = opts[:sent_messages], do: assert(loaded.sent_message_count == sent)
        if views = opts[:views], do: assert(loaded.view_count == views)
        ctx
      end
    end

    defmacro event_rollup_matches(ctx_ast, event_title, opts) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        event = Map.fetch!(ctx.events, unquote(event_title))
        opts = unquote(opts)

        assert event.effective_location == Keyword.fetch!(opts, :location)
        assert event.session_count == Keyword.fetch!(opts, :sessions)
        assert event.total_capacity == Keyword.fetch!(opts, :total_capacity)
        ctx
      end
    end

    defmacro confirmed_seats_for_session(ctx_ast, session_title, expected_seat_numbers) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        session = Map.fetch!(ctx.sessions, unquote(session_title))

        assert WorkspaceDriver.confirmed_seat_numbers(session.id) ==
                 unquote(expected_seat_numbers)

        ctx
      end
    end

    defmacro search_results_ordered(ctx_ast, expected_names) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        assert Enum.map(ctx.search_hits, & &1.full_name) == unquote(expected_names)
        ctx
      end
    end

    defmacro inbox_prune_counts(ctx_ast, opts) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        opts = unquote(opts)

        assert ctx.bulk_stats == %{
                 archived_count: Keyword.fetch!(opts, :archived),
                 destroyed_count: Keyword.fetch!(opts, :destroyed)
               }

        ctx
      end
    end

    defmacro form_created_member(ctx_ast, expected_name) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        assert {:ok, created} = ctx.last_result
        assert created.full_name == unquote(expected_name)
        %World{ctx | members: Map.put(ctx.members, created.full_name, created)}
      end
    end

    defmacro member_email_has_domain(ctx_ast, member_label, expected_domain) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        member = Map.fetch!(ctx.members, unquote(member_label))

        [loaded] =
          WorkspaceDriver.list_visible_profiles(member, load: [])
          |> Enum.filter(&(&1.id == member.id))

        assert String.ends_with?(
                 String.downcase(to_string(loaded.email)),
                 "@" <> unquote(expected_domain)
               )

        ctx
      end
    end

    defmacro form_rejected_field(ctx_ast, field, expected_message) do
      quote line: __CALLER__.line do
        %World{} = ctx = unquote(ctx_ast)
        assert {:error, form} = ctx.last_result
        errors = AshPhoenix.Form.errors(form)

        assert Enum.any?(errors, fn {f, msg} ->
                 f == unquote(field) and msg =~ unquote(expected_message)
               end)

        ctx
      end
    end

    # -- Unique Identity Helpers --

    defp unique_domain(%World{test_id: tid}, domain), do: "#{tid}-#{domain}"

    defp unique_email(%World{test_id: tid}, email) do
      case String.split(email, "@", parts: 2) do
        [local, host] -> "#{local}+#{tid}@#{host}"
        [single] -> "#{single}+#{tid}@allocator.ca"
      end
    end

    defp slugify(text) do
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
    end
  end
end
