if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.DataLayerTest do
    use ExUnit.Case, async: true

    require Ash.Query

    # =========================================================================
    # Test Stores & Domain Fixtures (Mirrors CAASA Connect MDMStore + AppStore)
    # =========================================================================

    defmodule TestMdmStore do
      use Xitdb.Ash.Store
    end

    defmodule TestAppStore do
      use Xitdb.Ash.Store
    end

    defmodule StartDateCalc do
      use Ash.Resource.Calculation

      @impl true
      def load(_query, _opts, _context), do: [:start_time]

      @impl true
      def calculate(records, _opts, _context) do
        Enum.map(records, fn
          %{start_time: %DateTime{} = dt} -> DateTime.to_date(dt)
          _ -> nil
        end)
      end
    end

    defmodule ExternalSimpleResource do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Ash.DataLayer.Simple

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, public?: true)
      end

      actions do
        defaults([:read])
      end
    end

    defmodule User do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :users
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:email, :role, :status])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:email, :ci_string, allow_nil?: false, public?: true)

        attribute(:role, :atom,
          default: :member,
          constraints: [one_of: [:member, :admin]],
          public?: true
        )

        attribute(:status, :atom,
          default: :active,
          constraints: [one_of: [:active, :suspended]],
          public?: true
        )
      end

      identities do
        identity(:unique_email, [:email])
      end

      relationships do
        has_one(:profile, Xitdb.Ash.DataLayerTest.Profile)
      end
    end

    defmodule Organization do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :organizations
        counted_set_fields([:aliases, :initialisms])
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:name, :slug, :domain, :admin_id, :aliases, :initialisms])
        end

        create :upsert do
          accept([:name, :slug, :domain, :admin_id, :aliases, :initialisms])
          upsert?(true)
          upsert_identity(:unique_slug)
          upsert_fields([:name, :domain])
        end

        update :update do
          primary?(true)
          accept([:name, :domain, :aliases, :initialisms])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:slug, :ci_string, allow_nil?: false, public?: true)
        attribute(:domain, :ci_string, public?: true)
        attribute(:aliases, {:array, :string}, default: [], allow_nil?: false, public?: true)
        attribute(:initialisms, {:array, :string}, default: [], allow_nil?: false, public?: true)
      end

      identities do
        identity(:unique_slug, [:slug])
        identity(:unique_domain, [:domain])
      end

      relationships do
        belongs_to(:admin, User, attribute_type: :integer, public?: true)
        has_many(:profiles, Xitdb.Ash.DataLayerTest.Profile)
      end

      aggregates do
        count :active_roster_count, :profiles do
          filter(expr(directory_visible == true))
        end
      end
    end

    defmodule UuidBadge do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :uuid_badges
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:code, :label, :note])
        end

        create :upsert_replace_all do
          accept([:code, :label, :note])
          upsert?(true)
          upsert_identity(:unique_code)
          upsert_fields(:replace_all)
        end

        create :upsert_replace_tuple do
          accept([:code, :label, :note])
          upsert?(true)
          upsert_identity(:unique_code)
          upsert_fields({:replace, [:label]})
        end

        create :upsert_except do
          accept([:code, :label, :note])
          upsert?(true)
          upsert_identity(:unique_code)
          upsert_fields({:replace_all_except, [:note]})
        end
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:code, :ci_string, allow_nil?: false, public?: true)
        attribute(:label, :string, allow_nil?: false, public?: true)
        attribute(:note, :string, default: "initial", public?: true)
      end

      identities do
        identity(:unique_code, [:code])
      end
    end

    defmodule Profile do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :profiles

        references do
          reference :user, on_delete: :delete
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:user_id, :organization_id, :first_name, :org_role, :directory_visible])
        end

        update :update do
          primary?(true)
          accept([:organization_id, :org_role, :directory_visible])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:first_name, :string, allow_nil?: false, public?: true)

        attribute(:org_role, :atom,
          default: :member,
          constraints: [one_of: [:member, :contributor, :admin]],
          public?: true
        )

        attribute(:directory_visible, :boolean, default: true, public?: true)
      end

      relationships do
        belongs_to(:user, User, attribute_type: :integer, allow_nil?: false, public?: true)
        belongs_to(:organization, Organization, attribute_type: :integer, public?: true)
      end
    end

    defmodule Event do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :events
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:title, :start_time])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:start_time, :utc_datetime, allow_nil?: false, public?: true)
      end

      calculations do
        calculate(:start_date, :date, StartDateCalc, public?: true)
      end

      relationships do
        has_many(:sessions, Xitdb.Ash.DataLayerTest.AgendaSession)
        has_one(:conference, Xitdb.Ash.DataLayerTest.Conference)
      end
    end

    # Flat top-level collection in Wave 2 (physical `nested_in` subtrees move to Wave 3 Track 11B)
    defmodule AgendaSession do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :agenda_sessions

        references do
          reference :event, on_delete: :delete
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:event_id, :title, :room])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:room, :string, public?: true)
      end

      relationships do
        belongs_to(:event, Event, attribute_type: :integer, allow_nil?: false, public?: true)
      end
    end

    defmodule Conference do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :conferences

        references do
          reference :event, on_delete: :delete
          reference :organizer, on_delete: :restrict
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:event_id, :organizer_id, :title, :location_name, :location_city])
        end

        read :by_event_id do
          argument(:event_id, :integer, allow_nil?: false)
          get?(true)
          filter(expr(event_id == ^arg(:event_id)))
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:location_name, :string, public?: true)
        attribute(:location_city, :string, public?: true)
      end

      calculations do
        calculate(
          :location,
          :string,
          expr(if(is_nil(location_city), location_name, location_city)),
          public?: true
        )
      end

      relationships do
        belongs_to(:event, Event, attribute_type: :integer, allow_nil?: false, public?: true)
        belongs_to(:organizer, User, attribute_type: :integer, allow_nil?: false, public?: true)
      end
    end

    defmodule TableTalkSeat do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :table_talk_seats

        references do
          reference :conference, on_delete: :delete
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:conference_id, :table_talk_id, :user_id, :status])
        end

        update :update do
          primary?(true)
          accept([:status])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:table_talk_id, :integer, allow_nil?: false, public?: true)

        attribute(:status, :atom,
          default: :confirmed,
          constraints: [one_of: [:confirmed, :cancelled]],
          public?: true
        )
      end

      identities do
        identity :unique_confirmed_seat, [:table_talk_id, :user_id] do
          where(expr(status == :confirmed))
        end
      end

      relationships do
        belongs_to(:conference, Conference,
          attribute_type: :integer,
          allow_nil?: false,
          public?: true
        )

        belongs_to(:user, User, attribute_type: :integer, allow_nil?: false, public?: true)
      end
    end

    defmodule TenantDoc do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      multitenancy do
        strategy(:context)
      end

      xitdb do
        store TestMdmStore
        collection :tenant_docs
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:slug, :body])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:slug, :ci_string, allow_nil?: false, public?: true)
        attribute(:body, :string, allow_nil?: false, public?: true)
      end

      identities do
        identity(:unique_slug, [:slug])
      end
    end

    # Lives in TestAppStore while referencing Organization & User in TestMdmStore!
    defmodule Deal do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      xitdb do
        store TestAppStore
        collection :marketplace_deals
      end

      policies do
        bypass actor_attribute_equals(:role, :admin) do
          authorize_if(always())
        end

        policy action_type(:read) do
          forbid_unless(actor_attribute_equals(:status, :active))

          authorize_if(
            expr(
              is_nil(target_audience) or
                poster_id == ^actor(:id) or
                organization.admin_id == ^actor(:id) or
                exists(
                  organization.profiles,
                  user_id == ^actor(:id) and org_role in [:admin, :contributor]
                )
            )
          )
        end

        policy action_type([:create, :update]) do
          forbid_unless(actor_attribute_equals(:status, :active))

          authorize_if(
            expr(
              poster_id == ^actor(:id) or
                exists(
                  organization.profiles,
                  user_id == ^actor(:id) and org_role in [:admin, :contributor]
                )
            )
          )
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)

          accept([
            :title,
            :organization_id,
            :poster_id,
            :target_audience,
            :score_a,
            :score_b,
            :state
          ])
        end

        update :update do
          primary?(true)
          accept([:title])
        end

        update :increment_views do
          change(atomic_update(:view_count, expr(view_count + 1)))
        end

        update :swap_scores do
          change(atomic_update(:score_a, expr(score_b)))
          change(atomic_update(:score_b, expr(score_a)))
        end

        update :publish do
          accept([:title])

          validate(attribute_equals(:state, :draft),
            message: "only draft deals can be published"
          )

          change(set_attribute(:state, :published))
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:target_audience, :atom, constraints: [one_of: [:sfo_only]], public?: true)
        attribute(:view_count, :integer, default: 0, allow_nil?: false, public?: true)
        attribute(:score_a, :integer, default: 10, allow_nil?: false, public?: true)
        attribute(:score_b, :integer, default: 99, allow_nil?: false, public?: true)

        attribute(:state, :atom,
          default: :draft,
          constraints: [one_of: [:draft, :published]],
          public?: true
        )
      end

      calculations do
        calculate(
          :has_materials_access,
          :boolean,
          expr(
            is_nil(target_audience) or
              ^actor(:role) == :admin or
              poster_id == ^actor(:id) or
              organization.admin_id == ^actor(:id) or
              exists(
                organization.profiles,
                user_id == ^actor(:id) and org_role in [:admin, :contributor]
              )
          ),
          public?: true
        )
      end

      relationships do
        belongs_to(:organization, Organization, attribute_type: :integer, public?: true)
        belongs_to(:poster, User, attribute_type: :integer, allow_nil?: false, public?: true)
      end
    end

    defmodule Message do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestAppStore
        collection :messages
        search_field :body, boost: 2.0
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:body])
        end

        update :update do
          primary?(true)
          accept([:body])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:body, :string, allow_nil?: false, public?: true)
      end
    end

    defmodule MessageReport do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestAppStore
        collection :message_reports

        references do
          reference :message, on_delete: :nilify
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:message_id, :reason])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:reason, :string, allow_nil?: false, public?: true)
      end

      relationships do
        belongs_to(:message, Message, attribute_type: :integer, allow_nil?: true, public?: true)
      end
    end

    defmodule TestDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(ExternalSimpleResource)

        resource User do
          define(:create_user, action: :create)
          define(:get_user, action: :read, get_by: [:id])
          define(:destroy_user, action: :destroy)
        end

        resource Organization do
          define(:create_org, action: :create)
          define(:upsert_org, action: :upsert)
          define(:update_org, action: :update)
          define(:list_orgs, action: :read)
        end

        resource UuidBadge do
          define(:create_badge, action: :create)
          define(:upsert_badge_replace_all, action: :upsert_replace_all)
          define(:upsert_badge_replace_tuple, action: :upsert_replace_tuple)
          define(:upsert_badge_except, action: :upsert_except)
        end

        resource Profile do
          define(:create_profile, action: :create)
          define(:update_profile, action: :update)
        end

        resource Event do
          define(:create_event, action: :create)
          define(:get_event, action: :read, get_by: [:id])
          define(:destroy_event, action: :destroy)
        end

        resource AgendaSession do
          define(:create_session, action: :create)
          define(:get_session, action: :read, get_by: [:id])
        end

        resource Conference do
          define(:create_conference, action: :create)
          define(:get_conference_by_event_id, action: :by_event_id, args: [:event_id])
          define(:destroy_conference, action: :destroy)
        end

        resource TableTalkSeat do
          define(:reserve_seat, action: :create)
          define(:update_seat, action: :update)
        end

        resource TenantDoc do
          define(:create_tenant_doc, action: :create)
          define(:list_tenant_docs, action: :read)
        end

        resource Deal do
          define(:create_deal, action: :create)
          define(:update_deal, action: :update)
          define(:increment_views, action: :increment_views)
          define(:swap_scores, action: :swap_scores)
          define(:publish_deal, action: :publish)
          define(:list_deals, action: :read)
        end

        resource Message do
          define(:create_message, action: :create)
          define(:update_message, action: :update)
          define(:destroy_message, action: :destroy)
        end

        resource MessageReport do
          define(:create_report, action: :create)
          define(:get_report, action: :read, get_by: [:id])
        end
      end
    end

    # =========================================================================
    # Store Supervision & Per-Test Isolated `:memory` Sandbox Setup
    # =========================================================================

    setup_all do
      :ok = Xitdb.Ash.TestSandbox.init()
      start_supervised!({TestMdmStore, path: :memory, domains: [TestDomain]})
      start_supervised!({TestAppStore, path: :memory, domains: [TestDomain]})
      :ok
    end

    setup do
      :ok = Xitdb.Ash.TestSandbox.checkout([TestMdmStore, TestAppStore])
      :ok
    end

    defp unique_email(prefix \\ "member") do
      "#{prefix}_#{System.unique_integer([:positive])}@polar.ca"
    end

    defp unique_slug(prefix) do
      "#{prefix}-#{System.unique_integer([:positive])}"
    end

    # =========================================================================
    # Specifications
    # =========================================================================

    def handle_telemetry(event, _measurements, meta, parent) do
      send(parent, {:telemetry_event, event, meta})
    end

    describe "can?/2 hybrid boundary guards and telemetry spans" do
      test "scopes join/filter/aggregate relationship capabilities to Xitdb.Ash.DataLayer, rejects :composite_primary_key, and emits telemetry" do
        assert Xitdb.Ash.DataLayer.can?(User, {:join, Profile}) == true
        assert Xitdb.Ash.DataLayer.can?(User, {:join, ExternalSimpleResource}) == false

        assert Xitdb.Ash.DataLayer.can?(
                 User,
                 {:filter_relationship, %{destination: Profile}}
               ) == true

        assert Xitdb.Ash.DataLayer.can?(
                 User,
                 {:filter_relationship, %{destination: ExternalSimpleResource}}
               ) == false

        assert Xitdb.Ash.DataLayer.can?(
                 User,
                 {:aggregate_relationship, %{destination: Profile}}
               ) == true

        assert Xitdb.Ash.DataLayer.can?(
                 User,
                 {:aggregate_relationship, %{destination: ExternalSimpleResource}}
               ) == false

        assert Xitdb.Ash.DataLayer.can?(User, :composite_primary_key) == false
        assert Xitdb.Ash.DataLayer.can?(User, {:aggregate, :unrelated}) == true
        assert Xitdb.Ash.DataLayer.can?(User, {:exists, :unrelated}) == true

        handler_id = "datalayer-telemetry-#{System.unique_integer([:positive])}"

        :telemetry.attach_many(
          handler_id,
          [
            [:xitdb, :ash, :query, :stop],
            [:xitdb, :ash, :aggregate_query, :stop]
          ],
          &__MODULE__.handle_telemetry/4,
          self()
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        _ = TestDomain.create_user!(%{email: unique_email("tel")}, authorize?: false)
        _ = Ash.read!(User, domain: TestDomain, authorize?: false)
        assert 1 = Ash.count!(User, domain: TestDomain, authorize?: false)

        assert_received {:telemetry_event, [:xitdb, :ash, :query, :stop],
                         %{resource: User, collection: :users, status: :ok}}

        assert_received {:telemetry_event, [:xitdb, :ash, :aggregate_query, :stop],
                         %{resource: User, collection: :users, status: :ok}}
      end
    end

    describe "sequences, single-commit atomicity, CiString identities, counted sets, and upserts" do
      test "allocates monotonic integer IDs in a single commit, enforces case-insensitive uniqueness, and round-trips counted sets" do
        m0 = TestMdmStore.root().moment
        u1 = TestDomain.create_user!(%{email: "Jane.Doe@Polar.CA"}, authorize?: false)
        m1 = TestMdmStore.root().moment

        # Single-commit guarantee: sequence allocation + entity write + unique identity index = 1 moment!
        assert m1 == m0 + 1
        assert u1.id == 1

        u2 = TestDomain.create_user!(%{email: unique_email("bob")}, authorize?: false)
        assert u2.id == 2

        assert {:error, %Ash.Error.Invalid{}} =
                 TestDomain.create_user(%{email: "jane.doe@polar.ca"}, authorize?: false)

        found =
          User
          |> Ash.Query.filter(email == "JANE.DOE@polar.ca")
          |> Ash.read_one!(authorize?: false)

        assert found.id == u1.id

        slug = unique_slug("polar-am")

        org =
          TestDomain.create_org!(
            %{
              name: "Polar Asset Management",
              slug: slug,
              domain: "Polar.CA",
              aliases: ["Polar AM", "Gestion d'actifs Polar"],
              initialisms: ["PAM"]
            },
            authorize?: false
          )

        assert Enum.sort(org.aliases) == ["Gestion d'actifs Polar", "Polar AM"]
        assert org.initialisms == ["PAM"]

        upserted =
          TestDomain.upsert_org!(
            %{
              name: "Polar Asset Management Partners",
              slug: String.upcase(slug),
              domain: "polaramp.com",
              aliases: ["Should Be Ignored By upsert_fields"]
            },
            authorize?: false
          )

        assert upserted.id == org.id
        assert upserted.name == "Polar Asset Management Partners"
        assert to_string(upserted.domain) == "polaramp.com"
        assert Enum.sort(upserted.aliases) == ["Gestion d'actifs Polar", "Polar AM"]
      end

      test "preserves existing uuid_primary_key across :replace_all, {:replace, ...}, and {:replace_all_except, ...} upserts" do
        badge =
          TestDomain.create_badge!(
            %{code: "VIP-2026", label: "Original VIP", note: "keep-note"},
            authorize?: false
          )

        original_id = badge.id
        assert is_binary(original_id)

        # 1. {:replace, [:label]} updates :label while preserving :id and :note
        b1 =
          TestDomain.upsert_badge_replace_tuple!(
            %{code: "vip-2026", label: "Updated VIP", note: "ignored-note"},
            authorize?: false
          )

        assert b1.id == original_id
        assert b1.label == "Updated VIP"
        assert b1.note == "keep-note"

        # 2. {:replace_all_except, [:note]} updates :label while preserving :id and :note
        b2 =
          TestDomain.upsert_badge_except!(
            %{code: "VIP-2026", label: "Except VIP", note: "still-ignored"},
            authorize?: false
          )

        assert b2.id == original_id
        assert b2.label == "Except VIP"
        assert b2.note == "keep-note"

        # 3. :replace_all updates both :label and :note while NEVER overwriting :id!
        b3 =
          TestDomain.upsert_badge_replace_all!(
            %{code: "vip-2026", label: "Replaced All VIP", note: "new-note"},
            authorize?: false
          )

        assert b3.id == original_id
        assert b3.label == "Replaced All VIP"
        assert b3.note == "new-note"
      end

      test "enforces partial `where:` identities on create and status transitions" do
        user = TestDomain.create_user!(%{email: unique_email()}, authorize?: false)

        ev =
          TestDomain.create_event!(
            %{title: "Summit", start_time: ~U[2026-10-15 13:00:00Z]},
            authorize?: false
          )

        conf =
          TestDomain.create_conference!(
            %{event_id: ev.id, organizer_id: user.id, title: "Summit"},
            authorize?: false
          )

        seat1 =
          TestDomain.reserve_seat!(
            %{conference_id: conf.id, table_talk_id: 10, user_id: user.id, status: :cancelled},
            authorize?: false
          )

        seat2 =
          TestDomain.reserve_seat!(
            %{conference_id: conf.id, table_talk_id: 10, user_id: user.id, status: :cancelled},
            authorize?: false
          )

        assert seat1.id != seat2.id

        _confirmed =
          TestDomain.reserve_seat!(
            %{conference_id: conf.id, table_talk_id: 10, user_id: user.id, status: :confirmed},
            authorize?: false
          )

        assert {:error, %Ash.Error.Invalid{}} =
                 TestDomain.reserve_seat(
                   %{
                     conference_id: conf.id,
                     table_talk_id: 10,
                     user_id: user.id,
                     status: :confirmed
                   },
                   authorize?: false
                 )

        assert {:error, %Ash.Error.Invalid{}} =
                 TestDomain.update_seat(seat1, %{status: :confirmed}, authorize?: false)
      end
    end

    describe "module & expression calculations, multitenancy, and BM25 stale-token cleanup" do
      test "sorts and filters by StartDateCalc module calculation and evaluates expression calculations" do
        organizer = TestDomain.create_user!(%{email: unique_email("org")}, authorize?: false)

        ev_late =
          TestDomain.create_event!(
            %{title: "November Forum", start_time: ~U[2026-11-05 14:00:00Z]},
            load: [:start_date],
            authorize?: false
          )

        ev_early =
          TestDomain.create_event!(
            %{title: "October Summit", start_time: ~U[2026-10-20 14:00:00Z]},
            load: [:start_date],
            authorize?: false
          )

        assert ev_early.start_date == ~D[2026-10-20]
        assert ev_late.start_date == ~D[2026-11-05]

        oct_only =
          Event
          |> Ash.Query.filter(start_date == ^~D[2026-10-20])
          |> Ash.Query.load(:start_date)
          |> Ash.read!(authorize?: false)

        assert Enum.map(oct_only, & &1.id) == [ev_early.id]

        conf1 =
          TestDomain.create_conference!(
            %{
              event_id: ev_early.id,
              organizer_id: organizer.id,
              title: "Montreal Institutional Summit",
              location_name: "Ritz-Carlton"
            },
            load: [:location],
            authorize?: false
          )

        conf2 =
          TestDomain.create_conference!(
            %{
              event_id: ev_late.id,
              organizer_id: organizer.id,
              title: "Calgary Energy Forum",
              location_city: "Calgary"
            },
            load: [:location],
            authorize?: false
          )

        assert conf1.location == "Ritz-Carlton"
        assert conf2.location == "Calgary"

        sorted_confs =
          Conference
          |> Ash.Query.sort(location: :asc)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.id)

        assert sorted_confs == [conf2.id, conf1.id]

        assert TestDomain.get_conference_by_event_id!(ev_early.id, authorize?: false).id ==
                 conf1.id
      end

      test "isolates `:context` multitenant records, sequences, and unique identities per tenant" do
        t1 = TestDomain.create_tenant_doc!(%{slug: "welcome", body: "Tenant A"}, tenant: "org_a")
        t2 = TestDomain.create_tenant_doc!(%{slug: "welcome", body: "Tenant B"}, tenant: "org_b")

        assert t1.id == 1
        assert t2.id == 1

        assert [%{body: "Tenant A"}] = TestDomain.list_tenant_docs!(tenant: "org_a")
        assert [%{body: "Tenant B"}] = TestDomain.list_tenant_docs!(tenant: "org_b")
      end

      test "purges stale BM25 tokens on update and destroy in a single commit" do
        msg =
          TestDomain.create_message!(
            %{body: "alpha quantum allocation"},
            authorize?: false
          )

        assert Xitdb.Ash.Search.ids(Message, "quantum") == [msg.id]

        updated =
          TestDomain.update_message!(
            msg,
            %{body: "alpha macro credit"},
            authorize?: false
          )

        assert Xitdb.Ash.Search.ids(Message, "quantum") == []
        assert Xitdb.Ash.Search.ids(Message, "macro") == [updated.id]

        _updated2 =
          TestDomain.update_message!(
            updated,
            %{body: "sovereign yield"},
            authorize?: false
          )

        assert Xitdb.Ash.Search.ids(Message, "macro") == []
        assert Xitdb.Ash.Search.ids(Message, "sovereign") == [msg.id]

        :ok = TestDomain.destroy_message!(updated, authorize?: false)
        assert Xitdb.Ash.Search.ids(Message, "sovereign") == []
      end
    end

    describe "aggregates, cross-store joins, exists(...), and `:unknown`-safe Ash.Policy.Authorizer" do
      test "evaluates filtered roster counts, cross-store Deal write policies without `:unknown` bypass, and relational calculations" do
        admin =
          TestDomain.create_user!(%{email: unique_email("admin"), role: :admin},
            authorize?: false
          )

        owner = TestDomain.create_user!(%{email: unique_email("owner")}, authorize?: false)
        contrib = TestDomain.create_user!(%{email: unique_email("contrib")}, authorize?: false)
        outsider = TestDomain.create_user!(%{email: unique_email("outsider")}, authorize?: false)

        org_a =
          TestDomain.create_org!(
            %{name: "Alpha SFO", slug: unique_slug("alpha"), admin_id: owner.id},
            authorize?: false
          )

        org_b =
          TestDomain.create_org!(
            %{name: "Beta Partners", slug: unique_slug("beta")},
            authorize?: false
          )

        TestDomain.create_profile!(
          %{
            user_id: contrib.id,
            organization_id: org_a.id,
            first_name: "Clara",
            org_role: :contributor,
            directory_visible: true
          },
          authorize?: false
        )

        TestDomain.create_profile!(
          %{
            user_id: outsider.id,
            organization_id: org_a.id,
            first_name: "Hidden",
            org_role: :member,
            directory_visible: false
          },
          authorize?: false
        )

        orgs_with_roster =
          TestDomain.list_orgs!(
            load: [:active_roster_count],
            query: [filter: [active_roster_count: [greater_than: 0]]]
          )

        assert [loaded_org_a] = orgs_with_roster
        assert loaded_org_a.id == org_a.id
        assert loaded_org_a.active_roster_count == 1

        assert TestDomain.list_orgs!(load: [:active_roster_count])
               |> Enum.find(&(&1.id == org_b.id))
               |> Map.fetch!(:active_roster_count) == 0

        private_deal =
          TestDomain.create_deal!(
            %{
              title: "Series B Co-Invest",
              organization_id: org_a.id,
              poster_id: owner.id,
              target_audience: :sfo_only
            },
            actor: contrib
          )

        public_deal =
          TestDomain.create_deal!(
            %{
              title: "Open Infrastructure Fund",
              organization_id: org_b.id,
              poster_id: owner.id,
              target_audience: nil
            },
            actor: owner
          )

        refute Ash.can?({private_deal, :update}, outsider)
        assert Ash.can?({private_deal, :update}, contrib)

        assert_raise Ash.Error.Forbidden, fn ->
          TestDomain.update_deal!(private_deal, %{title: "Hijacked"}, actor: outsider)
        end

        updated_by_contrib =
          TestDomain.update_deal!(private_deal, %{title: "Authorized Co-Invest"}, actor: contrib)

        assert updated_by_contrib.title == "Authorized Co-Invest"

        outsider_deals = TestDomain.list_deals!(load: [:has_materials_access], actor: outsider)
        assert Enum.map(outsider_deals, & &1.id) == [public_deal.id]
        assert hd(outsider_deals).has_materials_access == true

        contrib_deals = TestDomain.list_deals!(load: [:has_materials_access], actor: contrib)

        assert MapSet.new(contrib_deals, & &1.id) ==
                 MapSet.new([private_deal.id, public_deal.id])

        assert Enum.all?(contrib_deals, & &1.has_materials_access)

        admin_deals = TestDomain.list_deals!(load: [:has_materials_access], actor: admin)
        assert length(admin_deals) == 2
      end
    end

    describe "pre-update atomics, state-transition atomic_validations, savepoints, and FK cascades" do
      test "evaluates atomic swaps against pre-update row, enforces state-transition validations, and supports nested savepoints" do
        poster = TestDomain.create_user!(%{email: unique_email("poster")}, authorize?: false)

        deal =
          TestDomain.create_deal!(
            %{
              title: "Atomic Deal",
              poster_id: poster.id,
              score_a: 10,
              score_b: 99,
              state: :draft
            },
            authorize?: false
          )

        inc = TestDomain.increment_views!(deal, authorize?: false)
        assert inc.view_count == 1

        swapped = TestDomain.swap_scores!(inc, authorize?: false)
        assert swapped.score_a == 99
        assert swapped.score_b == 10

        published =
          TestDomain.publish_deal!(swapped, %{title: "Published Deal"}, authorize?: false)

        assert published.state == :published

        assert {:error, %Ash.Error.Invalid{}} =
                 TestDomain.publish_deal(published, %{title: "Re-Publish"}, authorize?: false)

        {:ok, outer_user} =
          Ash.DataLayer.transaction(User, fn ->
            u_outer = TestDomain.create_user!(%{email: unique_email("outer")}, authorize?: false)

            assert {:error, :inner_aborted} =
                     TestMdmStore.transact(fn ->
                       _u_inner =
                         TestDomain.create_user!(
                           %{email: "rolled_back@polar.ca"},
                           authorize?: false
                         )

                       Ash.DataLayer.rollback(User, :inner_aborted)
                     end)

            assert TestDomain.get_user!(u_outer.id, authorize?: false).id == u_outer.id

            assert User
                   |> Ash.Query.filter(email == "rolled_back@polar.ca")
                   |> Ash.read_one!(authorize?: false) == nil

            u_outer
          end)

        assert TestDomain.get_user!(outer_user.id, authorize?: false).id == outer_user.id
      end

      test "enforces :restrict, :nilify, and cascading :delete across same-store references" do
        organizer =
          TestDomain.create_user!(%{email: unique_email("organizer")}, authorize?: false)

        ev =
          TestDomain.create_event!(
            %{title: "Cascade Test", start_time: ~U[2026-10-01 12:00:00Z]},
            authorize?: false
          )

        sess =
          TestDomain.create_session!(%{event_id: ev.id, title: "Keynote"}, authorize?: false)

        conf =
          TestDomain.create_conference!(
            %{event_id: ev.id, organizer_id: organizer.id, title: "Conf"},
            authorize?: false
          )

        _seat =
          TestDomain.reserve_seat!(
            %{conference_id: conf.id, table_talk_id: 1, user_id: organizer.id},
            authorize?: false
          )

        # 1. :restrict blocks destroying organizer while Conference references them
        assert {:error, %Ash.Error.Invalid{}} =
                 TestDomain.destroy_user(organizer, authorize?: false)

        # 2. :delete cascades TableTalkSeat removal when Conference is destroyed, unblocking organizer deletion
        :ok = TestDomain.destroy_conference!(conf, authorize?: false)
        assert Ash.read!(TableTalkSeat, authorize?: false) == []
        :ok = TestDomain.destroy_user!(organizer, authorize?: false)

        # 3. :delete on AgendaSession removes session when Event is destroyed
        :ok = TestDomain.destroy_event!(ev, authorize?: false)
        assert {:error, %Ash.Error.Invalid{}} = TestDomain.get_session(sess.id, authorize?: false)

        # 4. :nilify clears MessageReport.message_id when Message is destroyed
        msg = TestDomain.create_message!(%{body: "Questionable pitch"}, authorize?: false)
        rep = TestDomain.create_report!(%{message_id: msg.id, reason: "spam"}, authorize?: false)

        :ok = TestDomain.destroy_message!(msg, authorize?: false)
        reloaded_rep = TestDomain.get_report!(rep.id, authorize?: false)
        assert is_nil(reloaded_rep.message_id)
      end
    end

    describe "TestSandbox `$callers` isolation & VerifyNoSqlFragments verifier" do
      test "propagates sandbox state to child Task.async_stream workers via `$callers`" do
        created =
          TestDomain.create_user!(%{email: unique_email("async_parent")}, authorize?: false)

        results =
          1..4
          |> Task.async_stream(fn _ ->
            TestDomain.get_user!(created.id, authorize?: false).id
          end)
          |> Enum.map(fn {:ok, id} -> id end)

        assert results == [created.id, created.id, created.id, created.id]
      end

      test "rejects SQL fragment(...) calculations via VerifyNoSqlFragments with Spark.Error.DslError" do
        uid = System.unique_integer([:positive])
        res_mod = Module.concat(Xitdb.Ash, "InvalidFragmentResource#{uid}")

        {result, diagnostics} =
          Code.with_diagnostics(fn ->
            Code.compile_string("""
            defmodule Xitdb.Ash.InvalidFragmentResource#{uid} do
              use Ash.Resource,
                domain: nil,
                validate_domain_inclusion?: false,
                data_layer: Xitdb.Ash.DataLayer

              xitdb do
                store Xitdb.Ash.DataLayerTest.TestMdmStore
                collection :invalid_fragments
              end

              attributes do
                integer_primary_key :id
                attribute :start_time, :utc_datetime, public?: true
              end

              calculations do
                calculate :bad_date, :date, expr(fragment("?::date", start_time))
              end
            end
            """)
          end)

        assert Enum.any?(diagnostics, fn d ->
                 d.message =~ "SQL `fragment(...)` is not supported"
               end)

        {compiled_mod, _bytecode} = Enum.find(result, fn {mod, _} -> mod == res_mod end)

        assert {:error, %Spark.Error.DslError{message: msg}} =
                 Xitdb.Ash.Verifiers.VerifyNoSqlFragments.verify(compiled_mod.spark_dsl_config())

        assert msg =~ "SQL `fragment(...)` is not supported"
      end
    end
  end
end
