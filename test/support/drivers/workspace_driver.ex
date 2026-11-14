if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.TestDrivers.WorkspaceDriver do
    @moduledoc false

    require Ash.Query

    alias Xitdb.Ash.Search

    alias Xitdb.TestSupport.{
      AppDomain,
      AppStore,
      DirectMessage,
      MdmDomain,
      MdmStore,
      MemberProfile,
      TableTalkSeat
    }

    def capture_checkpoint do
      %{
        mdm_moment: MdmStore.root().moment,
        app_moment: AppStore.root().moment
      }
    end

    def with_checkpoint(%{mdm_moment: mdm_m, app_moment: app_m}, fun) when is_function(fun, 0) do
      MdmStore.with_as_of(mdm_m, fn ->
        if is_integer(app_m) and app_m >= 0 do
          AppStore.with_as_of(app_m, fun)
        else
          fun.()
        end
      end)
    end

    def seed_organization(attrs) do
      MdmDomain.register_organization!(attrs)
    end

    def rename_organization(org, attrs) do
      MdmDomain.rename_organization!(org, attrs)
    end

    def enrol_member(attrs) do
      MdmDomain.enrol_member!(attrs, authorize?: false)
    end

    def list_visible_profiles(actor, opts \\ []) do
      run = fn ->
        load_fields = Keyword.get(opts, :load, [:display_badge, :sent_message_count])

        query =
          MemberProfile
          |> Ash.Query.for_read(:read, %{}, actor: actor)
          |> maybe_filter_messaged_recipient(opts[:messaged_recipient_id])
          |> Ash.Query.load(load_fields)
          |> Ash.Query.sort(full_name: :asc)

        query =
          case Keyword.get(opts, :at_moment) do
            moment when is_integer(moment) ->
              Ash.Query.set_context(query, %{shared: %{xitdb_moment: moment}})

            nil ->
              query
          end

        Ash.read!(query, domain: MdmDomain)
      end

      case Keyword.get(opts, :checkpoint) do
        nil -> run.()
        checkpoint -> with_checkpoint(checkpoint, run)
      end
    end

    def edit_profile(target_profile, attrs, actor) do
      MdmDomain.edit_profile(target_profile, attrs, actor: actor)
    end

    def change_member_email(target_profile, new_email, actor) do
      MdmDomain.change_email(target_profile, new_email, actor: actor)
    end

    def increment_profile_view(target_profile, actor) do
      MdmDomain.record_profile_view(target_profile, actor: actor)
    end

    def send_direct_message(sender_id, recipient_id, body) do
      AppDomain.send_message!(%{
        sender_id: sender_id,
        recipient_id: recipient_id,
        body: body
      })
    end

    def bulk_archive_and_prune_messages(recipient_id) do
      %Ash.BulkResult{status: :success, records: archived} =
        DirectMessage
        |> Ash.Query.filter(recipient_id == ^recipient_id and archived? == false)
        |> Ash.bulk_update!(:archive, %{}, domain: AppDomain, return_records?: true)

      %Ash.BulkResult{status: :success, records: destroyed} =
        DirectMessage
        |> Ash.Query.filter(recipient_id == ^recipient_id and archived? == true)
        |> Ash.bulk_destroy!(:destroy, %{}, domain: AppDomain, return_records?: true)

      %{archived_count: length(archived), destroyed_count: length(destroyed)}
    end

    def schedule_event_with_sessions(organizer_id, event_attrs, sessions) do
      event =
        MdmDomain.schedule_event!(Map.put(event_attrs, :organizer_id, organizer_id))

      created_sessions =
        Enum.map(sessions, fn s ->
          MdmDomain.add_session!(Map.put(s, :event_id, event.id))
        end)

      reloaded =
        MdmDomain.get_event!(event.id,
          load: [:effective_location, :session_count, :total_capacity]
        )

      {reloaded, created_sessions}
    end

    def reserve_seat(session_id, profile_id, seat_number) do
      MdmDomain.reserve_seat(%{
        session_id: session_id,
        profile_id: profile_id,
        seat_number: seat_number
      })
    end

    def cancel_seat!(%TableTalkSeat{} = seat) do
      MdmDomain.cancel_seat!(seat)
    end

    def confirmed_seat_numbers(session_id, opts \\ []) do
      run = fn ->
        query =
          Ash.Query.filter(TableTalkSeat, session_id == ^session_id and status == :confirmed)

        query =
          case Keyword.get(opts, :at_moment) do
            moment when is_integer(moment) ->
              Ash.Query.set_context(query, %{xitdb_moment: moment})

            nil ->
              query
          end

        query
        |> Ash.read!(domain: MdmDomain)
        |> Enum.map(& &1.seat_number)
        |> Enum.sort()
      end

      case Keyword.get(opts, :checkpoint) do
        nil -> run.()
        checkpoint -> with_checkpoint(checkpoint, run)
      end
    end

    def run_outer_tx_with_aborted_nested_savepoint(confirmed_fn, aborted_nested_fn) do
      MdmStore.transact(fn ->
        outer_val = confirmed_fn.()

        {:error, :nested_aborted} =
          MdmStore.transact(fn ->
            _ = aborted_nested_fn.()
            MdmStore.rollback(:nested_aborted)
          end)

        outer_val
      end)
    end

    # Over-fetches BM25 candidates so authorization filtering cannot starve the page, then
    # applies the final limit *after* `Ash.Policy.Authorizer` has filtered the candidate set.
    @search_page_size 20
    @search_overfetch 10

    def search_member_directory(query_text, actor, opts \\ []) do
      run = fn ->
        search_opts =
          [limit: @search_page_size * @search_overfetch]
          |> then(fn s_opts ->
            case Keyword.get(opts, :at_moment) do
              moment when is_integer(moment) -> Keyword.put(s_opts, :as_of, moment)
              nil -> s_opts
            end
          end)

        ranked_ids = Search.ids(MemberProfile, query_text, search_opts)

        if ranked_ids == [] do
          []
        else
          query =
            MemberProfile
            |> Ash.Query.for_read(:read, %{}, actor: actor)
            |> Ash.Query.filter(id in ^ranked_ids)
            |> Search.sort_by_rank(ranked_ids)
            |> Ash.Query.limit(@search_page_size)

          query =
            case Keyword.get(opts, :at_moment) do
              moment when is_integer(moment) ->
                Ash.Query.set_context(query, %{shared: %{xitdb: %{as_of: moment}}})

              nil ->
                query
            end

          Ash.read!(query, domain: MdmDomain)
        end
      end

      case Keyword.get(opts, :checkpoint) do
        nil -> run.()
        checkpoint -> with_checkpoint(checkpoint, run)
      end
    end

    def submit_profile_form(params, opts \\ []) do
      form =
        case Keyword.get(opts, :editing) do
          nil ->
            AshPhoenix.Form.for_create(MemberProfile, :submit_application,
              domain: MdmDomain,
              actor: opts[:actor],
              authorize?: Keyword.get(opts, :authorize?, false)
            )

          %MemberProfile{} = existing ->
            AshPhoenix.Form.for_update(existing, :edit_profile,
              domain: MdmDomain,
              actor: opts[:actor]
            )
        end

      validated = AshPhoenix.Form.validate(form, params)
      AshPhoenix.Form.submit(validated, params: params)
    end

    defp maybe_filter_messaged_recipient(query, nil), do: query

    defp maybe_filter_messaged_recipient(query, recipient_id) do
      Ash.Query.filter(query, exists(sent_messages, recipient_id == ^recipient_id))
    end
  end
end
