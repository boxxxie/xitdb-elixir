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
          accept([:title, :start_time, :notes])
        end

        update :update do
          primary?(true)
          accept([:title, :start_time, :notes])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:start_time, :utc_datetime, allow_nil?: false, public?: true)
        attribute(:notes, :string, public?: true)
      end

      calculations do
        calculate(:start_date, :date, StartDateCalc, public?: true)
      end

      relationships do
        has_many(:sessions, Xitdb.Ash.DataLayerTest.AgendaSession)
        has_one(:conference, Xitdb.Ash.DataLayerTest.Conference)
      end
    end

    defmodule AgendaSession do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :agenda_sessions
        nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many
        index :room
        search_field :title, boost: 2.0
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:event_id, :title, :room])
        end

        update :update do
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
        nested_in :events, foreign_key: :event_id, path: :conference, cardinality: :one

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

    defmodule CiParent do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :ci_parents
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:domain_key, :amount_key])
        end

        update :update_with_failing_after_action do
          primary?(true)
          accept([:domain_key])
          require_atomic?(false)

          change(fn changeset, _ctx ->
            Ash.Changeset.after_action(changeset, fn _cs, _rec ->
              {:error, "boom after_action"}
            end)
          end)
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:domain_key, :ci_string, allow_nil?: false, public?: true)
        attribute(:amount_key, :decimal, public?: true)
      end

      relationships do
        has_many(:children, Xitdb.Ash.DataLayerTest.CiChild,
          source_attribute: :domain_key,
          destination_attribute: :parent_domain_key
        )

        has_many(:decimal_children, Xitdb.Ash.DataLayerTest.CiChild,
          source_attribute: :amount_key,
          destination_attribute: :parent_amount_key
        )
      end

      aggregates do
        count(:unique_child_emails, :children, field: :tag, uniq?: true, public?: true)

        count(:unique_child_amounts, :children,
          field: :parent_amount_key,
          uniq?: true,
          public?: true
        )
      end
    end

    defmodule CiChild do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :ci_children
        index :parent_domain_key
        index :parent_amount_key
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:parent_domain_key, :parent_amount_key, :tag])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:parent_domain_key, :ci_string, allow_nil?: false, public?: true)
        attribute(:parent_amount_key, :decimal, public?: true)
        attribute(:tag, :ci_string, public?: true)
      end

      defmodule TagUpperCalc do
        use Ash.Resource.Calculation

        @impl true
        def calculate(records, _opts, _context) do
          Enum.map(records, fn r -> String.upcase(to_string(r.tag)) end)
        end
      end

      calculations do
        calculate(:tag_upper, :string, TagUpperCalc, public?: true)
      end
    end

    defmodule CiTenantItem do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.TestDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :ci_tenant_items
      end

      multitenancy do
        strategy(:attribute)
        attribute(:tenant_slug)
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:label, :tenant_slug])
        end

        update :update do
          primary?(true)
          accept([:label])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:tenant_slug, :ci_string, allow_nil?: false, public?: true)
        attribute(:label, :string, allow_nil?: false, public?: true)
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
          define(:update_session, action: :update)
          define(:get_session, action: :read, get_by: [:id])
          define(:list_sessions, action: :read)
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

        resource(CiParent)
        resource(CiChild)
        resource(CiTenantItem)

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

    def handle_telemetry_with_measurements(event, measurements, meta, parent) do
      send(parent, {:telemetry_detailed, event, measurements, meta})
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

      test "emits [:xitdb, :tx, :commit], [:xitdb, :ash, :mutation, *], and narrowing_strategy on [:xitdb, :ash, :query, :stop]" do
        handler_id = "datalayer-detailed-telemetry-#{System.unique_integer([:positive])}"

        :telemetry.attach_many(
          handler_id,
          [
            [:xitdb, :tx, :commit],
            [:xitdb, :ash, :mutation, :start],
            [:xitdb, :ash, :mutation, :stop],
            [:xitdb, :ash, :query, :stop]
          ],
          &__MODULE__.handle_telemetry_with_measurements/4,
          self()
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        u1 = TestDomain.create_user!(%{email: unique_email("mut-tel")}, authorize?: false)

        assert_received {:telemetry_detailed, [:xitdb, :tx, :commit],
                         %{duration: tx_dur, op_count: tx_ops}, %{backend: :memory, doc: _}}

        assert is_integer(tx_dur) and tx_dur >= 0 and is_integer(tx_ops) and tx_ops > 0

        assert_received {:telemetry_detailed, [:xitdb, :ash, :mutation, :start],
                         %{monotonic_time: _, system_time: _},
                         %{resource: User, collection: :users, action: :create}}

        assert_received {:telemetry_detailed, [:xitdb, :ash, :mutation, :stop],
                         %{
                           duration: m_dur,
                           plan_duration: plan_dur,
                           commit_duration: commit_dur,
                           op_count: m_ops,
                           record_count: 1
                         }, %{resource: User, collection: :users, action: :create, status: :ok}}

        assert m_dur >= 0 and plan_dur >= 0 and commit_dur >= 0 and m_ops > 0

        # Query narrowing strategies: :pk, :secondary_index, and :full_scan
        ev =
          TestDomain.create_event!(
            %{title: "Tel Event", start_time: ~U[2026-11-20 12:00:00Z]},
            authorize?: false
          )

        _ =
          TestDomain.create_session!(
            %{event_id: ev.id, title: "Tel Session", room: "Suite-42"},
            authorize?: false
          )

        _ = User |> Ash.Query.filter(id == ^u1.id) |> Ash.read!(authorize?: false)

        assert_received {:telemetry_detailed, [:xitdb, :ash, :query, :stop], %{duration: _},
                         %{
                           resource: User,
                           collection: :users,
                           status: :ok,
                           narrowing_strategy: :pk,
                           candidate_count: 1,
                           result_count: 1
                         }}

        _ = AgendaSession |> Ash.Query.filter(room == "Suite-42") |> Ash.read!(authorize?: false)

        assert_received {:telemetry_detailed, [:xitdb, :ash, :query, :stop], %{duration: _},
                         %{
                           resource: AgendaSession,
                           collection: :agenda_sessions,
                           status: :ok,
                           narrowing_strategy: :secondary_index,
                           candidate_count: 1,
                           result_count: 1
                         }}

        _ = Ash.read!(User, domain: TestDomain, authorize?: false)

        assert_received {:telemetry_detailed, [:xitdb, :ash, :query, :stop], %{duration: _},
                         %{
                           resource: User,
                           collection: :users,
                           status: :ok,
                           narrowing_strategy: :full_scan,
                           candidate_count: _,
                           result_count: _
                         }}
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

      test "stores nested_in (:many and :one) subtrees physically under events, supports parent-jump queries, Ash reparenting, and event destroy BM25 cleanup" do
        organizer =
          TestDomain.create_user!(%{email: unique_email("nested_org")}, authorize?: false)

        ev1 =
          TestDomain.create_event!(
            %{title: "Vancouver Summit", start_time: ~U[2026-11-01 09:00:00Z]},
            authorize?: false
          )

        ev2 =
          TestDomain.create_event!(
            %{title: "Zurich Forum", start_time: ~U[2026-12-01 09:00:00Z]},
            authorize?: false
          )

        s1 =
          TestDomain.create_session!(
            %{event_id: ev1.id, title: "Helios Private Credit", room: "Oak"},
            authorize?: false
          )

        s2 =
          TestDomain.create_session!(
            %{event_id: ev2.id, title: "Helios Venture Equity", room: "Pine"},
            authorize?: false
          )

        conf =
          TestDomain.create_conference!(
            %{event_id: ev1.id, organizer_id: organizer.id, title: "CAASA West"},
            authorize?: false
          )

        # Physical co-location under TestMdmStore root["events"]
        root = Xitdb.Ash.Store.root(TestMdmStore)
        assert root["agenda_sessions"] == nil
        assert root["conferences"] == nil

        assert root["events"][to_string(ev1.id)]["sessions"][to_string(s1.id)]["title"] ==
                 s1.title

        assert root["events"][to_string(ev1.id)]["conference"]["title"] == conf.title

        # Direct PK lookup via _parent & parent-jump FK query + secondary intersection
        assert TestDomain.get_session!(s1.id, authorize?: false).id == s1.id
        assert TestDomain.get_conference_by_event_id!(ev1.id, authorize?: false).id == conf.id

        ev1_sessions =
          AgendaSession
          |> Ash.Query.filter(event_id == ^ev1.id and room == "Oak")
          |> Ash.read!(authorize?: false)

        assert Enum.map(ev1_sessions, & &1.id) == [s1.id]

        # Ash update reparenting moves physical slot from ev1 -> ev2
        moved =
          TestDomain.update_session!(s1, %{event_id: ev2.id, room: "Pine"}, authorize?: false)

        assert moved.event_id == ev2.id

        root_after_move = Xitdb.Ash.Store.root(TestMdmStore)
        assert root_after_move["events"][to_string(ev1.id)]["sessions"][to_string(s1.id)] == nil

        assert root_after_move["events"][to_string(ev2.id)]["sessions"][to_string(s1.id)]["room"] ==
                 "Pine"

        ev2_sessions =
          AgendaSession
          |> Ash.Query.filter(event_id == ^ev2.id and room == "Pine")
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.id)
          |> Enum.sort()

        assert ev2_sessions == Enum.sort([s1.id, s2.id])

        # Destroying ev2 purges both moved s1 and s2 + their BM25 search entries
        assert Enum.sort(Xitdb.Ash.Search.ids(AgendaSession, "helios")) ==
                 Enum.sort([s1.id, s2.id])

        :ok = TestDomain.destroy_event!(ev2, authorize?: false)
        assert TestDomain.list_sessions!(authorize?: false) == []
        assert Xitdb.Ash.Search.ids(AgendaSession, "helios") == []
      end

      test "updating a parent resource preserves its nested_in children and removes nilified attributes" do
        organizer =
          TestDomain.create_user!(%{email: unique_email("parent_upd_org")}, authorize?: false)

        ev =
          TestDomain.create_event!(
            %{
              title: "Original Summit",
              start_time: ~U[2026-11-01 09:00:00Z],
              notes: "Initial notes"
            },
            authorize?: false
          )

        session =
          TestDomain.create_session!(
            %{event_id: ev.id, title: "Preserved Session", room: "Cedar"},
            authorize?: false
          )

        conf =
          TestDomain.create_conference!(
            %{event_id: ev.id, organizer_id: organizer.id, title: "Preserved Conf"},
            authorize?: false
          )

        updated_ev =
          ev
          |> Ash.Changeset.for_update(:update, %{title: "Renamed Summit", notes: nil})
          |> Ash.update!(authorize?: false)

        assert updated_ev.title == "Renamed Summit"
        assert is_nil(updated_ev.notes)

        root = Xitdb.Ash.Store.root(TestMdmStore)
        assert root["events"][to_string(ev.id)]["title"] == "Renamed Summit"
        assert root["events"][to_string(ev.id)]["notes"] == nil

        assert root["events"][to_string(ev.id)]["sessions"][to_string(session.id)]["title"] ==
                 "Preserved Session"

        assert root["events"][to_string(ev.id)]["conference"]["title"] == "Preserved Conf"

        assert TestDomain.get_session!(session.id, authorize?: false).title ==
                 "Preserved Session"

        assert TestDomain.get_conference_by_event_id!(ev.id, authorize?: false).id == conf.id
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
    end

    describe "time-travel as_of & xitdb_db queries" do
      test "reads historical Ash records, aggregates, and BM25 search hits at prior moments" do
        org =
          TestDomain.create_org!(
            %{name: "Helios Alpha", slug: unique_slug("helios-alpha")},
            authorize?: false
          )

        event =
          TestDomain.create_event!(
            %{title: "Helios Summit", start_time: ~U[2026-10-01 09:00:00Z]},
            authorize?: false
          )

        session =
          TestDomain.create_session!(
            %{event_id: event.id, title: "Helios Opening", room: "Main"},
            authorize?: false
          )

        moment_v1 = TestMdmStore.root().moment
        assert is_integer(moment_v1)

        # Mutate records + add a second organization after moment_v1
        updated_org =
          TestDomain.update_org!(org, %{name: "Helios Beta"}, authorize?: false)

        assert updated_org.name == "Helios Beta"

        _org2 =
          TestDomain.create_org!(
            %{name: "Polar Second", slug: unique_slug("polar-second")},
            authorize?: false
          )

        _updated_session =
          TestDomain.update_session!(session, %{title: "Solar Closing"}, authorize?: false)

        # Latest reads reflect v2 state
        assert length(TestDomain.list_orgs!(authorize?: false)) == 2

        assert Enum.find(TestDomain.list_orgs!(authorize?: false), &(&1.id == org.id)).name ==
                 "Helios Beta"

        assert Xitdb.Ash.Search.ids(AgendaSession, "helios") == []
        assert Xitdb.Ash.Search.ids(AgendaSession, "solar") == [session.id]

        # 1. Per-query `context: %{xitdb_moment: moment_v1}` and `context: %{xitdb: %{as_of: moment_v1}}`
        v1_via_query =
          Organization
          |> Ash.Query.set_context(%{xitdb_moment: moment_v1})
          |> Ash.read!(authorize?: false)

        assert Enum.map(v1_via_query, &{&1.id, &1.name}) == [{org.id, "Helios Alpha"}]

        v1_via_opts =
          Ash.read!(Organization, context: %{xitdb: %{as_of: moment_v1}}, authorize?: false)

        assert Enum.map(v1_via_opts, &{&1.id, &1.name}) == [{org.id, "Helios Alpha"}]

        v1_via_shared =
          Ash.read!(Organization,
            context: %{shared: %{xitdb: %{as_of: moment_v1}}},
            authorize?: false
          )

        assert Enum.map(v1_via_shared, &{&1.id, &1.name}) == [{org.id, "Helios Alpha"}]

        # Relationship `load:` propagates `context[:shared][:xitdb_moment]` to child queries
        [v1_event_with_sessions] =
          Event
          |> Ash.Query.filter(id == ^event.id)
          |> Ash.Query.load(:sessions)
          |> Ash.Query.set_context(%{shared: %{xitdb_moment: moment_v1}})
          |> Ash.read!(authorize?: false)

        assert Enum.map(v1_event_with_sessions.sessions, & &1.title) == ["Helios Opening"]

        # 2. Explicit `context: %{xitdb_db: Store.as_of(moment_v1)}`
        v1_cursor = TestMdmStore.as_of(moment_v1)
        v1_via_db = Ash.read!(Organization, context: %{xitdb_db: v1_cursor}, authorize?: false)
        assert Enum.map(v1_via_db, &{&1.id, &1.name}) == [{org.id, "Helios Alpha"}]

        # 3. Aggregate queries respect `xitdb_moment`
        assert Ash.count!(Organization, authorize?: false) == 2

        assert Ash.count!(Organization, context: %{xitdb_moment: moment_v1}, authorize?: false) ==
                 1

        # 4. BM25 search respects `as_of: moment_v1`
        assert Xitdb.Ash.Search.ids(AgendaSession, "helios", as_of: moment_v1) == [session.id]
        assert Xitdb.Ash.Search.ids(AgendaSession, "solar", as_of: moment_v1) == []

        # 5. Scoped `Store.with_as_of/2` pins Ash.read, Ash.get, Ash.count, Search, and `$callers`
        TestMdmStore.with_as_of(moment_v1, fn ->
          assert Enum.map(TestDomain.list_orgs!(authorize?: false), & &1.name) == [
                   "Helios Alpha"
                 ]

          assert TestDomain.get_session!(session.id, authorize?: false).title == "Helios Opening"
          assert Ash.count!(Organization, authorize?: false) == 1
          assert Xitdb.Ash.Search.ids(AgendaSession, "helios") == [session.id]

          async_names =
            1..2
            |> Task.async_stream(fn _ ->
              TestDomain.list_orgs!(authorize?: false) |> Enum.map(& &1.name)
            end)
            |> Enum.map(fn {:ok, names} -> names end)

          assert async_names == [["Helios Alpha"], ["Helios Alpha"]]
        end)

        # Outside `with_as_of`, reads return to the latest state
        assert length(TestDomain.list_orgs!(authorize?: false)) == 2
        assert TestDomain.get_session!(session.id, authorize?: false).title == "Solar Closing"
      end
    end

    describe "second-pass integrity, query-engine, and atomicity fixes" do
      test "joins and uniq?: true aggregates normalize :ci_string casing and :decimal scale" do
        parent =
          CiParent
          |> Ash.Changeset.for_create(:create, %{
            domain_key: "Polar.CA",
            amount_key: Decimal.new("10.0")
          })
          |> Ash.create!(authorize?: false)

        _c1 =
          CiChild
          |> Ash.Changeset.for_create(:create, %{
            parent_domain_key: "polar.ca",
            parent_amount_key: Decimal.new("10.00"),
            tag: "Alice@Polar.ca"
          })
          |> Ash.create!(authorize?: false)

        _c2 =
          CiChild
          |> Ash.Changeset.for_create(:create, %{
            parent_domain_key: "POLAR.CA",
            parent_amount_key: Decimal.new("10.000"),
            tag: "alice@polar.ca"
          })
          |> Ash.create!(authorize?: false)

        loaded =
          Ash.load!(
            parent,
            [:children, :decimal_children, :unique_child_emails, :unique_child_amounts],
            authorize?: false
          )

        assert length(loaded.children) == 2
        assert length(loaded.decimal_children) == 2
        assert loaded.unique_child_emails == 1
        assert loaded.unique_child_amounts == 1
      end

      test "join_filter matching on relationship aggregates survives calculation hydration" do
        require Ash.Query

        parent =
          CiParent
          |> Ash.Changeset.for_create(:create, %{domain_key: "joinfilter.ca"})
          |> Ash.create!(authorize?: false)

        _c1 =
          CiChild
          |> Ash.Changeset.for_create(:create, %{
            parent_domain_key: "joinfilter.ca",
            tag: "keep"
          })
          |> Ash.create!(authorize?: false)

        _c2 =
          CiChild
          |> Ash.Changeset.for_create(:create, %{
            parent_domain_key: "joinfilter.ca",
            tag: "drop"
          })
          |> Ash.create!(authorize?: false)

        # Evaluate a join_filter that uses a calculation on CiChild (which hydrates :tag_upper)
        join_filter = Ash.Filter.parse!(CiChild, tag_upper: "KEEP")

        agg = %Ash.Query.Aggregate{
          name: :kept_children,
          relationship_path: [:children],
          kind: :count,
          resource: CiChild,
          query: %Ash.Query{filter: nil, sort: nil},
          join_filters: %{[:children] => join_filter}
        }

        {:ok, [enriched]} =
          Xitdb.Ash.Query.execute(
            Xitdb.Ash.Store.root(TestMdmStore),
            %Xitdb.Ash.Query{
              resource: CiParent,
              domain: TestDomain,
              filter: Ash.Filter.parse!(CiParent, id: parent.id),
              aggregates: [agg]
            },
            CiParent
          )

        assert enriched.aggregates[:kept_children] == 1
      end

      test "Mutator enforces global?: false and case-insensitive :ci_string attribute multitenancy" do
        item =
          CiTenantItem
          |> Ash.Changeset.for_create(:create, %{label: "initial", tenant_slug: "Polar.CA"},
            tenant: "Polar.CA"
          )
          |> Ash.create!(authorize?: false)

        # nil tenant must fail when global?: false
        item_no_tenant_meta = put_in(item.__metadata__[:tenant], nil)

        assert {:error, _} =
                 item_no_tenant_meta
                 |> Ash.Changeset.for_update(:update, %{label: "hacked"}, tenant: nil)
                 |> Ash.update(authorize?: false)

        # Different casing binary tenant must match :ci_string tenant_slug
        updated =
          item_no_tenant_meta
          |> Ash.Changeset.for_update(:update, %{label: "updated"}, tenant: "polar.ca")
          |> Ash.update!(authorize?: false)

        assert updated.label == "updated"
      end

      test "prefer_transaction?/1 is true and rolls back primary write when after_action fails" do
        assert Xitdb.Ash.DataLayer.prefer_transaction?(CiParent) == true

        parent =
          CiParent
          |> Ash.Changeset.for_create(:create, %{domain_key: "atomic.ca"})
          |> Ash.create!(authorize?: false)

        assert {:error, _} =
                 parent
                 |> Ash.Changeset.for_update(:update_with_failing_after_action, %{
                   domain_key: "rolled_back.ca"
                 })
                 |> Ash.update(authorize?: false)

        reloaded = Ash.get!(CiParent, parent.id, authorize?: false)
        assert to_string(reloaded.domain_key) == "atomic.ca"
      end
    end

    defmodule RegLoadCheckCalc do
      use Ash.Resource.Calculation

      @impl true
      def load(%Ash.Query{} = query, _opts, _ctx) do
        send(self(), {:calc_load_query, query})
        [:organization]
      end

      @impl true
      def calculate(records, _opts, _ctx) do
        Enum.map(records, fn rec ->
          case rec.organization do
            %{name: name} -> "org:" <> name
            _ -> "none"
          end
        end)
      end
    end

    defmodule RegDualFallbackCalc do
      use Ash.Resource.Calculation
      import Ash.Expr

      @impl true
      def expression(opts, _ctx) do
        case Keyword.get(opts, :mode) do
          :nil_expr -> nil
          :normal -> expr(title <> "!")
          _ -> expr(organization.name)
        end
      end

      @impl true
      def calculate(records, opts, _ctx) do
        suffix = if Keyword.get(opts, :mode) == :nil_expr, do: "-nil-fb", else: "-unk-fb"
        Enum.map(records, &(&1.title <> suffix))
      end
    end

    defmodule RegAccount do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.RegDomainA,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestMdmStore
        collection :reg_accounts
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:email, :name, :handle, :due_on])
          validate(string_length(:name, min: 3))
        end

        update :update do
          primary?(true)
          accept([:name, :handle, :due_on])
        end
      end

      identities do
        identity(:unique_email, [:email])
        identity(:unique_handle, [:handle])
      end

      attributes do
        integer_primary_key(:id)
        attribute(:email, :string, allow_nil?: false, public?: true)
        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:handle, :string, public?: true)
        attribute(:due_on, :date, public?: true)
        create_timestamp(:inserted_at, type: :utc_datetime_usec)
        update_timestamp(:updated_at, type: :utc_datetime_usec)
      end
    end

    defmodule RegCrossTarget do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.RegDomainB,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestAppStore
        collection :reg_cross_targets
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:tag, :score, :account_id])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:tag, :ci_string, public?: true)
        attribute(:score, :integer, public?: true)
        attribute(:account_id, :integer, public?: true)
      end

      relationships do
        has_many(:notes, Xitdb.Ash.DataLayerTest.RegCrossNote,
          destination_attribute: :target_id,
          public?: true
        )
      end
    end

    defmodule RegCrossNote do
      use Ash.Resource,
        domain: Xitdb.Ash.DataLayerTest.RegDomainB,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store TestAppStore
        collection :reg_cross_notes
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:target_id, :label])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:target_id, :integer, public?: true)
        attribute(:label, :ci_string, public?: true)
      end
    end

    defmodule RegDomainA do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(RegAccount)
        resource(Deal)
        resource(Organization)
        resource(User)
        resource(Profile)
      end
    end

    defmodule RegDomainB do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(RegCrossTarget)
        resource(RegCrossNote)
      end
    end

    describe "Regression fixes (BUG-001..005, 019, 024..027, 038..043)" do
      import Ash.Expr

      test "BUG-043: LeaseQueue and Store tolerate lease_timeout == 0 without CaseClauseError" do
        queue = Xitdb.Ash.Store.LeaseQueue.new()

        {:granted, _lease_ref, next_queue} =
          Xitdb.Ash.Store.LeaseQueue.acquire(
            queue,
            :owner,
            make_ref(),
            {self(), make_ref()},
            0,
            100,
            :snap
          )

        assert Xitdb.Ash.Store.LeaseQueue.verify_holder(next_queue, next_queue.active.ref, self()) ==
                 :ok

        assert Xitdb.Ash.Store.min_timeout(0, 50) == 0
      end

      test "BUG-041/042: Search staged cursor sees re-indexed document after :reset_col and :rm in same tx" do
        db = Xitdb.open!(backend: :memory)

        assert {:ok, _} =
                 Xitdb.transact(db, fn root ->
                   diff1 = %{
                     doc_count_delta: 1,
                     len_delta: 2,
                     new_doc: %{len: 2, terms: %{"quantum" => 100, "beam" => 100}},
                     term_ops: [{:put, "quantum", 100}, {:put, "beam", 100}]
                   }

                   root = Xitdb.Ash.Search.Storage.apply_diff(root, "messages", "doc1", diff1)
                   # Staged :reset_col on terms + :put children is visible via read_staged_path
                   doc_entry = Xitdb.Ash.Search.Storage.read_doc(root, "messages", "doc1")
                   assert doc_entry.terms["quantum"] == 100

                   # Delete doc1 (:rm doc + :rm terms) then re-insert doc1 in same transaction
                   del_diff = %{
                     doc_count_delta: -1,
                     len_delta: -2,
                     new_doc: :delete,
                     term_ops: [{:delete, "quantum"}, {:delete, "beam"}]
                   }

                   root = Xitdb.Ash.Search.Storage.apply_diff(root, "messages", "doc1", del_diff)
                   root = Xitdb.Ash.Search.Storage.apply_diff(root, "messages", "doc1", diff1)

                   reloaded = Xitdb.Ash.Search.Storage.read_doc(root, "messages", "doc1")
                   assert reloaded.terms["quantum"] == 100
                   assert reloaded.terms["beam"] == 100
                   assert reloaded.len == 2
                   root
                 end)

        :ok = Xitdb.close(db)
      end

      test "BUG-019 & BUG-025: bulk_create upsert is atomic on mid-batch failure and honors touch_update_defaults?: false" do
        initial =
          RegAccount
          |> Ash.Changeset.for_create(:create, %{email: "keep@x.io", name: "Keep", handle: "keep"})
          |> Ash.create!(authorize?: false)

        old_updated_at = initial.updated_at

        # BUG-019: collision in item 2 inside Mutator rolls back item 1 atomically
        bulk_inputs = [
          %{email: "atomic1@x.io", name: "Valid One", handle: "dup_handle"},
          %{email: "atomic2@x.io", name: "Valid Two", handle: "dup_handle"}
        ]

        assert %Ash.BulkResult{status: :error} =
                 Ash.bulk_create(bulk_inputs, RegAccount, :create,
                   upsert?: true,
                   upsert_identity: :unique_email,
                   upsert_fields: [:name, :handle],
                   stop_on_error?: true,
                   authorize?: false
                 )

        assert Ash.read!(RegAccount, authorize?: false) |> length() == 1

        # BUG-025: touch_update_defaults?: false preserves updated_at on conflict
        Process.sleep(10)

        upserted =
          RegAccount
          |> Ash.Changeset.for_create(:create, %{
            email: "keep@x.io",
            name: "Renamed",
            handle: "keep"
          })
          |> Ash.create!(
            upsert?: true,
            upsert_identity: :unique_email,
            touch_update_defaults?: false,
            authorize?: false
          )

        assert upserted.name == "Renamed"
        assert DateTime.compare(upserted.updated_at, old_updated_at) == :eq
      end

      test "BUG-004: :min and :max aggregates compare Date and CiString semantically" do
        a1 =
          RegAccount
          |> Ash.Changeset.for_create(:create, %{
            email: "d1@x.io",
            name: "One",
            due_on: ~D[2025-01-01]
          })
          |> Ash.create!(authorize?: false)

        _a2 =
          RegAccount
          |> Ash.Changeset.for_create(:create, %{
            email: "d2@x.io",
            name: "Two",
            due_on: ~D[2024-12-31]
          })
          |> Ash.create!(authorize?: false)

        # In Erlang term ordering, day 1 < day 31 puts 2025-01-01 < 2024-12-31; semantic Date.compare must pick 2024-12-31
        min_agg = %Ash.Query.Aggregate{
          name: :min_due,
          relationship_path: [],
          kind: :min,
          field: :due_on,
          resource: RegAccount,
          related?: false
        }

        max_agg = %Ash.Query.Aggregate{
          name: :max_due,
          relationship_path: [],
          kind: :max,
          field: :due_on,
          resource: RegAccount,
          related?: false
        }

        t1 =
          RegCrossTarget
          |> Ash.Changeset.for_create(:create, %{tag: "Beta", account_id: a1.id})
          |> Ash.create!(authorize?: false)

        _t2 =
          RegCrossTarget
          |> Ash.Changeset.for_create(:create, %{tag: "alpha", account_id: a1.id})
          |> Ash.create!(authorize?: false)

        min_ci = %Ash.Query.Aggregate{
          name: :min_tag,
          relationship_path: [],
          kind: :min,
          field: :tag,
          resource: RegCrossTarget,
          related?: false
        }

        max_ci = %Ash.Query.Aggregate{
          name: :max_tag,
          relationship_path: [],
          kind: :max,
          field: :tag,
          resource: RegCrossTarget,
          related?: false
        }

        {:ok, [res]} =
          Xitdb.Ash.Query.execute(
            Xitdb.Ash.Store.root(TestAppStore),
            %Xitdb.Ash.Query{
              resource: RegCrossTarget,
              domain: RegDomainB,
              filter: Ash.Filter.parse!(RegCrossTarget, id: t1.id),
              aggregates: [min_agg, max_agg, min_ci, max_ci]
            },
            RegCrossTarget
          )

        assert res.aggregates[:min_due] == ~D[2024-12-31]
        assert res.aggregates[:max_due] == ~D[2025-01-01]
        assert Ash.CiString.value(res.aggregates[:min_tag]) == "alpha"
        assert Ash.CiString.value(res.aggregates[:max_tag]) == "Beta"
      end

      test "BUG-001/002/003/039: scoped nested exists/parent, cross-domain unrelated agg, and non-Xitdb guard" do
        acc =
          RegAccount
          |> Ash.Changeset.for_create(:create, %{email: "cross@x.io", name: "CrossTarget"})
          |> Ash.create!(authorize?: false)

        target =
          RegCrossTarget
          |> Ash.Changeset.for_create(:create, %{
            tag: "CrossTarget",
            score: 42,
            account_id: acc.id
          })
          |> Ash.create!(authorize?: false)

        _note =
          RegCrossNote
          |> Ash.Changeset.for_create(:create, %{target_id: target.id, label: "CrossTarget"})
          |> Ash.create!(authorize?: false)

        # BUG-003: inner exists referencing parent(tag) must keep inner parent scoped to RegCrossTarget
        expr_with_nested_parent =
          expr(
            exists(
              RegCrossTarget,
              account_id == parent(id) and exists(notes, label == parent(tag))
            )
          )

        matched =
          RegAccount
          |> Ash.Query.filter(^expr_with_nested_parent)
          |> Ash.read!(authorize?: false)

        assert Enum.map(matched, & &1.id) == [acc.id]

        # BUG-002 & BUG-039: cross-domain unrelated aggregate works and non-Xitdb target returns default cleanly
        cross_agg = %Ash.Query.Aggregate{
          name: :cross_count,
          relationship_path: [],
          kind: :count,
          resource: RegCrossTarget,
          related?: false
        }

        ext_agg = %Ash.Query.Aggregate{
          name: :ext_count,
          relationship_path: [],
          kind: :count,
          resource: ExternalSimpleResource,
          related?: false
        }

        {:ok, [enriched]} =
          Xitdb.Ash.Query.execute(
            Xitdb.Ash.Store.root(TestMdmStore),
            %Xitdb.Ash.Query{
              resource: RegAccount,
              domain: RegDomainA,
              filter: Ash.Filter.parse!(RegAccount, id: acc.id),
              aggregates: [cross_agg, ext_agg]
            },
            RegAccount
          )

        assert enriched.aggregates[:cross_count] == 1
        assert enriched.aggregates[:ext_count] == 0
      end

      test "BUG-005/024/027/038/040: calc load receives Ash.Query, dual calc falls back, DataLayer.calculate preserves values & snapshot" do
        user =
          User
          |> Ash.Changeset.for_create(:create, %{email: unique_email("calc"), role: :member})
          |> Ash.create!(authorize?: false)

        org =
          Organization
          |> Ash.Changeset.for_create(:create, %{
            name: "OrgOne",
            slug: unique_slug("org-calc"),
            admin_id: user.id
          })
          |> Ash.create!(authorize?: false)

        %Deal{} =
          deal =
          Deal
          |> Ash.Changeset.for_create(:create, %{
            title: "DealOne",
            organization_id: org.id,
            poster_id: user.id
          })
          |> Ash.create!(authorize?: false)

        # BUG-005 & BUG-027: module calc load/3 receives %Ash.Query{} with context[:shared]
        calc_loaded = %Ash.Query.Calculation{
          name: :org_tag,
          module: RegLoadCheckCalc,
          opts: [],
          context: %Ash.Resource.Calculation.Context{resource: Deal, domain: TestDomain},
          type: :string
        }

        # BUG-040: dual calc returning nil from expression/2 falls back to calculate/3
        calc_dual = %Ash.Query.Calculation{
          name: :dual_fb,
          module: RegDualFallbackCalc,
          opts: [mode: :nil_expr],
          context: %Ash.Resource.Calculation.Context{resource: Deal, domain: TestDomain},
          type: :string
        }

        app_db = Xitdb.Ash.Store.current_db(TestAppStore)
        mdm_db = Xitdb.Ash.Store.current_db(TestMdmStore)

        {:ok, [enriched_deal]} =
          Xitdb.Ash.Query.execute(
            app_db,
            %Xitdb.Ash.Query{
              resource: Deal,
              domain: TestDomain,
              filter: Ash.Filter.parse!(Deal, id: deal.id),
              calculations: [{calc_loaded, nil}, {calc_dual, nil}],
              context: %{shared: %{marker: :preserved}}
            },
            Deal
          )

        assert_received {:calc_load_query, %Ash.Query{context: %{shared: %{marker: :preserved}}}}
        assert enriched_deal.calculations[:org_tag] == "org:OrgOne"
        assert enriched_deal.calculations[:dual_fb] == "DealOne-nil-fb"

        # BUG-024: non-boolean relational expression returns actual value, not coerced boolean; nil record returns error
        unloaded_deal = %{deal | organization: %Ash.NotLoaded{field: :organization}}
        non_bool_expr = expr(organization.name)

        assert {:ok, ["OrgOne"]} =
                 Xitdb.Ash.DataLayer.calculate(Deal, [non_bool_expr], %{
                   record: unloaded_deal,
                   domain: TestDomain,
                   calculation_context: %Ash.Resource.Calculation.Context{
                     domain: TestDomain,
                     resource: Deal
                   }
                 })

        unknown_call = %Ash.Query.Call{name: :nonexistent_fn, args: [1]}

        assert {:error, _} =
                 Xitdb.Ash.DataLayer.calculate(Deal, [unknown_call], %{
                   record: unloaded_deal,
                   domain: TestDomain
                 })

        # BUG-038: %Ash.Resource.Calculation.Context{source_context: %{shared: %{xitdb_moment: ...}}} respected
        snapshot_moment =
          Xitdb.moment_count(%Xitdb{db_ref: mdm_db.db_ref, backend: :memory}) - 1

        _org_v2 =
          org
          |> Ash.Changeset.for_update(:update, %{name: "OrgTwo"})
          |> Ash.update!(authorize?: false)

        rel_exists_expr = expr(exists(Organization, id == ^org.id and name == "OrgOne"))

        assert {:ok, [true]} =
                 Xitdb.Ash.DataLayer.calculate(
                   Organization,
                   [rel_exists_expr],
                   %Ash.Resource.Calculation.Context{
                     domain: TestDomain,
                     resource: Organization,
                     source_context: %{shared: %{xitdb_moment: snapshot_moment}}
                   }
                 )
      end

      test "DataLayer.calculate/3 relational fallback evaluates exists/boolean filters and loads 1-hop, 2-hop, and calculation refs" do
        user =
          User
          |> Ash.Changeset.for_create(:create, %{email: "calc@acme.io", role: :admin})
          |> Ash.create!(authorize?: false)

        org =
          Organization
          |> Ash.Changeset.for_create(:create, %{name: "CalcOrg", slug: "calc-org"})
          |> Ash.create!(authorize?: false)

        profile =
          Profile
          |> Ash.Changeset.for_create(:create, %{
            user_id: user.id,
            organization_id: org.id,
            first_name: "Alice"
          })
          |> Ash.create!(authorize?: false)

        event =
          Event
          |> Ash.Changeset.for_create(:create, %{
            title: "Calc Summit",
            start_time: ~U[2026-11-11 10:00:00Z]
          })
          |> Ash.create!(authorize?: false)

        conf =
          Conference
          |> Ash.Changeset.for_create(:create, %{
            event_id: event.id,
            organizer_id: user.id,
            title: "Main Conf",
            location_name: "Hall"
          })
          |> Ash.create!(authorize?: false)

        seat =
          TableTalkSeat
          |> Ash.Changeset.for_create(:create, %{
            conference_id: conf.id,
            table_talk_id: 1,
            user_id: user.id
          })
          |> Ash.create!(authorize?: false)

        session =
          AgendaSession
          |> Ash.Changeset.for_create(:create, %{
            event_id: event.id,
            title: "Keynote",
            room: "A"
          })
          |> Ash.create!(authorize?: false)

        # 1. Boolean relational filter fallback (true and false branches)
        assert {:ok, [true, false]} =
                 Xitdb.Ash.DataLayer.calculate(
                   Organization,
                   [
                     expr(exists(profiles, first_name == "Alice")),
                     expr(exists(profiles, first_name == "Nobody"))
                   ],
                   %{record: org, domain: TestDomain}
                 )

        # 2. 1-hop unloaded relationship ref (nest_load_path [last], [])
        assert {:ok, [email]} =
                 Xitdb.Ash.DataLayer.calculate(
                   Profile,
                   [expr(user.email)],
                   %{record: profile, domain: TestDomain}
                 )

        assert Ash.CiString.value(email) == "calc@acme.io"

        # 3. 2-hop unloaded relationship ref (nest_load_path [head | rest], leaf)
        assert {:ok, ["Calc Summit"]} =
                 Xitdb.Ash.DataLayer.calculate(
                   TableTalkSeat,
                   [expr(conference.event.title)],
                   %{record: seat, domain: TestDomain}
                 )

        # 4. 1-hop relationship + calculation leaf (nest_load_path [last], [calc])
        assert {:ok, [~D[2026-11-11]]} =
                 Xitdb.Ash.DataLayer.calculate(
                   AgendaSession,
                   [expr(event.start_date)],
                   %{record: session, domain: TestDomain}
                 )

        # 5. 0-hop calculation ref (do_collect_refs_to_load relationship_path: [])
        assert {:ok, [~D[2026-11-11]]} =
                 Xitdb.Ash.DataLayer.calculate(
                   Event,
                   [expr(start_date)],
                   %{record: event, domain: TestDomain}
                 )
      end
    end
  end
end
