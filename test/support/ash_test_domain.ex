if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.TestSupport.MdmStore do
    @moduledoc false
    use Xitdb.Ash.Store
  end

  defmodule Xitdb.TestSupport.AppStore do
    @moduledoc false
    use Xitdb.Ash.Store
  end

  defmodule Xitdb.TestSupport.Validations.NoConsumerEmailDomain do
    @moduledoc false
    use Ash.Resource.Validation
    import Ash.Expr

    @blocked ["gmail.com", "yahoo.com"]

    @impl true
    def validate(changeset, _opts, _context) do
      case Ash.Changeset.get_attribute(changeset, :email) do
        nil ->
          :ok

        email ->
          str = email |> to_string() |> String.downcase()

          if Enum.any?(@blocked, &String.ends_with?(str, "@" <> &1)) do
            {:error, field: :email, message: "must use a corporate domain"}
          else
            :ok
          end
      end
    end

    @impl true
    def atomic(_changeset, _opts, _context) do
      {:atomic, [:email],
       expr(
         not is_nil(^atomic_ref(:email)) and
           (contains(^atomic_ref(:email), "@gmail.com") or
              contains(^atomic_ref(:email), "@yahoo.com"))
       ),
       expr(
         error(Ash.Error.Changes.InvalidAttribute,
           field: :email,
           message: "must use a corporate domain"
         )
       )}
    end
  end

  defmodule Xitdb.TestSupport.Organization do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :organizations
      search_field :name, boost: 3.0
      search_field :mandate, boost: 1.5
    end

    attributes do
      integer_primary_key(:id)
      attribute(:name, :string, allow_nil?: false, public?: true)
      attribute(:domain, :ci_string, allow_nil?: false, public?: true)
      attribute(:slug, :ci_string, allow_nil?: false, public?: true)
      attribute(:mandate, :string, public?: true)
    end

    identities do
      identity(:unique_domain, [:domain])
      identity(:unique_slug, [:slug])
    end

    relationships do
      has_many(:profiles, Xitdb.TestSupport.MemberProfile,
        destination_attribute: :organization_id
      )

      has_many(:organized_events, Xitdb.TestSupport.Event, destination_attribute: :organizer_id)
    end

    actions do
      defaults([:read, :destroy])

      create :register do
        accept([:name, :domain, :slug, :mandate])
      end

      update :rename_and_reindex do
        require_atomic?(false)
        accept([:name, :mandate])

        change(
          after_action(fn _changeset, org, _ctx ->
            profiles =
              Xitdb.TestSupport.MdmDomain.list_org_profiles!(org.id, authorize?: false)

            _ =
              Xitdb.Ash.Store.mutate(Xitdb.TestSupport.MdmStore, fn snapshot ->
                {:ok,
                 Xitdb.Ash.Search.reindex_records(
                   snapshot,
                   Xitdb.TestSupport.MemberProfile,
                   profiles
                 ), :ok}
              end)

            {:ok, org}
          end)
        )
      end
    end
  end

  defmodule Xitdb.TestSupport.MemberProfile do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :profiles

      index [:visibility, :role]

      search_field :full_name, boost: 3.0
      search_field :headline, boost: 1.5

      search_field :firm_name,
        boost: 2.0,
        resolver: fn profile, db ->
          Xitdb.Ash.Search.lookup_field(db, :organizations, profile.organization_id, "name")
        end

      search_field :firm_mandate,
        boost: 1.2,
        resolver: fn profile, db ->
          Xitdb.Ash.Search.lookup_field(db, :organizations, profile.organization_id, "mandate")
        end

      references do
        reference :organization, on_delete: :nilify
      end
    end

    attributes do
      integer_primary_key(:id)
      attribute(:email, :ci_string, allow_nil?: false, public?: true)
      attribute(:full_name, :string, allow_nil?: false, public?: true)
      attribute(:headline, :string, public?: true)

      attribute(:role, :atom,
        constraints: [one_of: [:member, :steward]],
        default: :member,
        allow_nil?: false,
        public?: true
      )

      attribute(:visibility, :atom,
        constraints: [one_of: [:public, :private]],
        default: :public,
        allow_nil?: false,
        public?: true
      )

      attribute(:compensation_band, :string, public?: true)
      attribute(:view_count, :integer, default: 0, allow_nil?: false, public?: true)
    end

    identities do
      identity(:unique_email, [:email])
    end

    relationships do
      belongs_to(:organization, Xitdb.TestSupport.Organization,
        attribute_type: :integer,
        allow_nil?: true,
        public?: true
      )

      has_many :sent_messages, Xitdb.TestSupport.DirectMessage do
        domain(Xitdb.TestSupport.AppDomain)
        destination_attribute(:sender_id)
      end
    end

    calculations do
      calculate(
        :display_badge,
        :string,
        expr(full_name <> " (" <> headline <> ")"),
        public?: true
      )
    end

    aggregates do
      count(:sent_message_count, :sent_messages, public?: true)
    end

    validations do
      validate Xitdb.TestSupport.Validations.NoConsumerEmailDomain do
        where [changing(:email)]
      end
    end

    policies do
      bypass actor_attribute_equals(:role, :steward) do
        authorize_if(always())
      end

      policy action_type(:read) do
        authorize_if(expr(visibility == :public))
        authorize_if(expr(id == ^actor(:id)))
      end

      policy action_type(:create) do
        authorize_if(always())
      end

      policy action_type([:update, :destroy]) do
        authorize_if(expr(id == ^actor(:id)))
      end
    end

    field_policies do
      field_policy :compensation_band do
        authorize_if(actor_attribute_equals(:role, :steward))
        authorize_if(expr(id == ^actor(:id)))
      end

      field_policy :* do
        authorize_if(always())
      end
    end

    actions do
      defaults([:read, :destroy])

      read :for_organization do
        argument(:organization_id, :integer, allow_nil?: false)
        filter(expr(organization_id == ^arg(:organization_id)))
      end

      create :enrol do
        accept([
          :email,
          :full_name,
          :headline,
          :role,
          :visibility,
          :compensation_band,
          :organization_id
        ])

        upsert?(true)
        upsert_identity(:unique_email)
        upsert_fields([:full_name, :headline, :visibility, :organization_id])
      end

      create :submit_application do
        accept([
          :email,
          :full_name,
          :headline,
          :visibility,
          :compensation_band,
          :organization_id
        ])
      end

      update :edit_profile do
        accept([:headline, :visibility, :compensation_band])
      end

      update :change_email do
        argument(:new_email, :ci_string, allow_nil?: false)
        change(atomic_update(:email, expr(^arg(:new_email))))
      end

      update :record_profile_view do
        accept([])
        change(atomic_update(:view_count, expr(view_count + 1)))
      end
    end
  end

  defmodule Xitdb.TestSupport.Event do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :events

      references do
        reference :organizer, on_delete: :restrict
      end
    end

    attributes do
      integer_primary_key(:id)
      attribute(:title, :string, allow_nil?: false, public?: true)
      attribute(:location_city, :string, public?: true)
      attribute(:location_name, :string, allow_nil?: false, public?: true)
    end

    relationships do
      belongs_to(:organizer, Xitdb.TestSupport.Organization,
        attribute_type: :integer,
        allow_nil?: false,
        public?: true
      )

      has_many(:sessions, Xitdb.TestSupport.AgendaSession, destination_attribute: :event_id)
    end

    calculations do
      calculate(
        :effective_location,
        :string,
        expr(if(is_nil(location_city), location_name, location_city)),
        public?: true
      )
    end

    aggregates do
      count(:session_count, :sessions, public?: true)
      sum(:total_capacity, :sessions, :capacity, default: 0, public?: true)
    end

    actions do
      defaults([:read, :destroy])

      create :schedule do
        accept([:title, :location_city, :location_name, :organizer_id])
      end
    end
  end

  defmodule Xitdb.TestSupport.AgendaSession do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :agenda_sessions
      nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many
      search_field :title, boost: 2.0
    end

    attributes do
      integer_primary_key(:id)
      attribute(:title, :string, allow_nil?: false, public?: true)
      attribute(:capacity, :integer, allow_nil?: false, default: 30, public?: true)
    end

    identities do
      identity(:unique_session_title_per_event, [:event_id, :title])
    end

    relationships do
      belongs_to(:event, Xitdb.TestSupport.Event,
        attribute_type: :integer,
        allow_nil?: false,
        public?: true
      )

      has_many(:seats, Xitdb.TestSupport.TableTalkSeat, destination_attribute: :session_id)
    end

    actions do
      defaults([:read, :destroy])

      create :add_session do
        accept([:event_id, :title, :capacity])
      end
    end
  end

  defmodule Xitdb.TestSupport.TableTalkSeat do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.MdmDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.MdmStore
      collection :table_talk_seats

      references do
        reference :session, on_delete: :delete
      end
    end

    attributes do
      integer_primary_key(:id)
      attribute(:seat_number, :integer, allow_nil?: false, public?: true)

      attribute(:status, :atom,
        constraints: [one_of: [:confirmed, :cancelled]],
        default: :confirmed,
        allow_nil?: false,
        public?: true
      )
    end

    identities do
      identity :unique_confirmed_seat, [:session_id, :seat_number] do
        where expr(status == :confirmed)
      end
    end

    relationships do
      belongs_to(:session, Xitdb.TestSupport.AgendaSession,
        attribute_type: :integer,
        allow_nil?: false,
        public?: true
      )

      belongs_to(:profile, Xitdb.TestSupport.MemberProfile,
        attribute_type: :integer,
        allow_nil?: false,
        public?: true
      )
    end

    actions do
      defaults([:read, :destroy])

      create :reserve do
        accept([:session_id, :profile_id, :seat_number, :status])
      end

      update :cancel do
        accept([])
        change(set_attribute(:status, :cancelled))
      end
    end
  end

  defmodule Xitdb.TestSupport.DirectMessage do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.AppDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.TestSupport.AppStore
      collection :direct_messages
      index [:recipient_id, :archived?]
    end

    attributes do
      integer_primary_key(:id)
      attribute(:recipient_id, :integer, allow_nil?: false, public?: true)
      attribute(:body, :string, allow_nil?: false, public?: true)
      attribute(:archived?, :boolean, default: false, allow_nil?: false, public?: true)
    end

    relationships do
      belongs_to :sender, Xitdb.TestSupport.MemberProfile do
        domain(Xitdb.TestSupport.MdmDomain)
        attribute_type(:integer)
        allow_nil?(false)
        public?(true)
      end
    end

    actions do
      defaults([:read, :destroy])

      create :send_message do
        accept([:sender_id, :recipient_id, :body])
      end

      update :archive do
        accept([])
        change(set_attribute(:archived?, true))
      end
    end
  end

  defmodule Xitdb.TestSupport.MdmDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Xitdb.TestSupport.Organization do
        define(:register_organization, action: :register)
        define(:rename_organization, action: :rename_and_reindex)
        define(:destroy_organization, action: :destroy)
        define(:get_organization, action: :read, get_by: [:id])
      end

      resource Xitdb.TestSupport.MemberProfile do
        define(:enrol_member, action: :enrol)
        define(:submit_application, action: :submit_application)
        define(:edit_profile, action: :edit_profile)
        define(:change_email, action: :change_email, args: [:new_email])
        define(:record_profile_view, action: :record_profile_view)
        define(:destroy_profile, action: :destroy)
        define(:list_profiles, action: :read)
        define(:list_org_profiles, action: :for_organization, args: [:organization_id])
        define(:get_profile, action: :read, get_by: [:id])
      end

      resource Xitdb.TestSupport.Event do
        define(:schedule_event, action: :schedule)
        define(:destroy_event, action: :destroy)
        define(:get_event, action: :read, get_by: [:id])
      end

      resource Xitdb.TestSupport.AgendaSession do
        define(:add_session, action: :add_session)
        define(:get_session, action: :read, get_by: [:id])
        define(:list_sessions, action: :read)
      end

      resource Xitdb.TestSupport.TableTalkSeat do
        define(:reserve_seat, action: :reserve)
        define(:cancel_seat, action: :cancel)
        define(:list_seats, action: :read)
      end
    end
  end

  defmodule Xitdb.TestSupport.AppDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Xitdb.TestSupport.DirectMessage do
        define(:send_message, action: :send_message)
        define(:archive_message, action: :archive)
        define(:list_messages, action: :read)
      end
    end
  end
end
