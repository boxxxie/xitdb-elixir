# Reference: Ash 3 Contract Fixes & Standalone Verification Suite

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Parent Track:** [`pure_xitdb_ash_datalayer_20261111`](../pure_xitdb_ash_datalayer_20261111/)
> - **Associated Track:** [`xitdb_datalayer_1_engine_20261111`](./index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Consumer Repository:** `caasa/connect` (`/home/pauli/projects/nvestiv/caasa/connect`)
> - **Purpose:** Pre-test Ash 3 contract fixes and standalone ExUnit verification suite ensuring cross-resource joins, relational calculations (`Deal.has_materials_access`), and `%Ash.Resource.Identity{}` upsert structs work on the first run.

---

## 1. Pre-Test Fixes in `data_layer.ex` and `indexer.ex`

Before running the test suite, apply these two Ash 3 contract adaptations:

### 1.1 Implement `join/7` and Delegate `:calculate` in `lib/xitdb/ash/data_layer.ex`

1. **Remove `:calculate` from `can?/2`:**
   Leaving `:calculate` **off** the `feature in [...]` list in `can?/2` directs Ash Core's own `Ash.Actions.Read.Calculations` runner to batch-load referenced relationships and `exists(...)` subqueries in memory before evaluating expression calculations in Elixir.
2. **Add no-op `join/7` callback:**
   When `can?(resource, {:join, other})` returns `true`, Ash's query planner invokes `DataLayer.join/7` before `Ash.Filter.Runtime` evaluates cross-resource filters (such as `organization.admin_id == ^actor(:id)` or `exists(organization.profiles, ...)`). Since hydration and in-memory joining are handled by `Ash.Filter.Runtime`, `join/7` acts as a pass-through:

```elixir
# In Xitdb.Ash.DataLayer (lib/xitdb/ash/data_layer.ex):

# 1. Remove `:calculate` from the `feature in [...]` list in `can?/2`

# 2. Add the no-op `join/7` callback (Ash.Filter.Runtime hydrates the joined paths):
@impl true
def join(%Query{} = query, _opts, _current, _destination, _type, _source, _dest) do
  {:ok, query}
end
```

### 1.2 Accept `%Ash.Resource.Identity{}` Structs in `lib/xitdb/ash/indexer.ex`

Ash 3 passes the `%Ash.Resource.Identity{}` struct itself (not an atom) as the 4th argument to `DataLayer.upsert/4`. `find_upsert_existing_id/5` must handle structs, atoms, and fallback key matching:

```elixir
# In Xitdb.Ash.Indexer.find_upsert_existing_id/5:
def find_upsert_existing_id(root, resource, candidate, keys, identity_or_name) do
  col = Atom.to_string(Info.collection!(resource))
  pk = Ash.Resource.Info.primary_key(resource)

  identity =
    case identity_or_name do
      %Ash.Resource.Identity{} = id_struct -> id_struct
      name when is_atom(name) and not is_nil(name) -> Ash.Resource.Info.identity(resource, name)
      _ -> Enum.find(Ash.Resource.Info.identities(resource), &(&1.keys == keys))
    end

  cond do
    keys == pk ->
      id_val = Map.get(candidate, hd(pk))

      if not is_nil(id_val) and fetch_entity_cursor(root, resource, to_string(id_val)) != nil do
        to_string(id_val)
      else
        nil
      end

    identity != nil and identity_applies?(resource, identity, candidate) ->
      comp_key =
        resolve_identity_key(
          Enum.map(identity.keys, &Map.get(candidate, &1)),
          identity.nils_distinct?
        )

      comp_key && get_path(root, ["idx", col, "id_#{identity.name}", comp_key])

    true ->
      nil
  end
end
```

---

## 2. Standalone Verification Suite (`xitdb/test/xitdb/ash/data_layer_test.exs`)

This test suite boots two isolated Xitdb stores (`TestMdmStore` and `TestAppStore` to mirror `connect_mdm.xit` and `connect_app.xit`), exercises every CAASA Connect Ash pattern through Domain code interfaces on `async: true`, and verifies the compile-time SQL `fragment(...)` guard.

Save as `test/xitdb/ash/data_layer_test.exs` in the `xitdb` repository:

```elixir
defmodule Xitdb.Ash.DataLayerTest do
  use ExUnit.Case, async: true

  require Ash.Query

  # ===========================================================================
  # Test Stores & Domain Fixtures (Mirrors CAASA Connect MDMStore + AppStore)
  # ===========================================================================

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

  defmodule TestDomain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource Xitdb.Ash.DataLayerTest.User do
        define :create_user, action: :create
        define :get_user, action: :read, get_by: [:id]
        define :destroy_user, action: :destroy
      end

      resource Xitdb.Ash.DataLayerTest.Organization do
        define :create_org, action: :create
        define :upsert_org, action: :upsert
        define :update_org, action: :update
        define :list_orgs, action: :read
      end

      resource Xitdb.Ash.DataLayerTest.Profile do
        define :create_profile, action: :create
        define :update_profile, action: :update
      end

      resource Xitdb.Ash.DataLayerTest.Event do
        define :create_event, action: :create
        define :get_event, action: :read, get_by: [:id]
        define :destroy_event, action: :destroy
      end

      resource Xitdb.Ash.DataLayerTest.AgendaSession do
        define :create_session, action: :create
        define :get_session, action: :read, get_by: [:id]
      end

      resource Xitdb.Ash.DataLayerTest.Conference do
        define :create_conference, action: :create
        define :get_conference_by_event_id, action: :by_event_id, args: [:event_id]
        define :destroy_conference, action: :destroy
      end

      resource Xitdb.Ash.DataLayerTest.TableTalkSeat do
        define :reserve_seat, action: :create
        define :update_seat, action: :update
      end

      resource Xitdb.Ash.DataLayerTest.Deal do
        define :create_deal, action: :create
        define :update_deal, action: :update
        define :increment_views, action: :increment_views
        define :list_deals, action: :read
      end

      resource Xitdb.Ash.DataLayerTest.Message do
        define :create_message, action: :create
        define :destroy_message, action: :destroy
      end

      resource Xitdb.Ash.DataLayerTest.MessageReport do
        define :create_report, action: :create
        define :get_report, action: :read, get_by: [:id]
      end
    end
  end

  defmodule User do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestMdmStore
      collection :users
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:email, :role, :status]
      end
    end

    attributes do
      integer_primary_key :id
      attribute :email, :ci_string, allow_nil?: false, public?: true
      attribute :role, :atom, default: :member, constraints: [one_of: [:member, :admin]], public?: true
      attribute :status, :atom, default: :active, constraints: [one_of: [:active, :suspended]], public?: true
    end

    identities do
      identity :unique_email, [:email]
    end

    relationships do
      has_one :profile, Xitdb.Ash.DataLayerTest.Profile
    end
  end

  defmodule Organization do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestMdmStore
      collection :organizations
      counted_set_fields [:aliases, :initialisms]
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:name, :slug, :domain, :admin_id, :aliases, :initialisms]
      end

      create :upsert do
        accept [:name, :slug, :domain, :admin_id, :aliases, :initialisms]
        upsert? true
        upsert_identity :unique_slug
        upsert_fields [:name, :domain]
      end

      update :update do
        primary? true
        accept [:name, :domain, :aliases, :initialisms]
      end
    end

    attributes do
      integer_primary_key :id
      attribute :name, :string, allow_nil?: false, public?: true
      attribute :slug, :ci_string, allow_nil?: false, public?: true
      attribute :domain, :ci_string, public?: true
      attribute :aliases, {:array, :string}, default: [], allow_nil?: false, public?: true
      attribute :initialisms, {:array, :string}, default: [], allow_nil?: false, public?: true
    end

    identities do
      identity :unique_slug, [:slug]
      identity :unique_domain, [:domain]
    end

    relationships do
      belongs_to :admin, User, public?: true
      has_many :profiles, Xitdb.Ash.DataLayerTest.Profile
    end

    aggregates do
      count :active_roster_count, :profiles do
        filter expr(directory_visible == true)
      end
    end
  end

  defmodule Profile do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestMdmStore
      collection :profiles

      references do
        reference :user, on_delete: :delete
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:user_id, :organization_id, :first_name, :org_role, :directory_visible]
      end

      update :update do
        primary? true
        accept [:organization_id, :org_role, :directory_visible]
      end
    end

    attributes do
      integer_primary_key :id
      attribute :first_name, :string, allow_nil?: false, public?: true
      attribute :org_role, :atom, default: :member, constraints: [one_of: [:member, :contributor, :admin]], public?: true
      attribute :directory_visible, :boolean, default: true, public?: true
    end

    relationships do
      belongs_to :user, User, allow_nil?: false, public?: true
      belongs_to :organization, Organization, public?: true
    end
  end

  defmodule Event do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestMdmStore
      collection :events
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:title, :start_time]
      end
    end

    attributes do
      integer_primary_key :id
      attribute :title, :string, allow_nil?: false, public?: true
      attribute :start_time, :utc_datetime, allow_nil?: false, public?: true
    end

    calculations do
      calculate :start_date, :date, StartDateCalc, public?: true
    end

    relationships do
      has_many :sessions, Xitdb.Ash.DataLayerTest.AgendaSession
      has_one :conference, Xitdb.Ash.DataLayerTest.Conference
    end
  end

  defmodule AgendaSession do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestMdmStore
      collection :agenda_sessions

      nested_in :events,
        foreign_key: :event_id,
        path: :sessions,
        cardinality: :many

      references do
        reference :event, on_delete: :delete
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:event_id, :title, :room]
      end
    end

    attributes do
      integer_primary_key :id
      attribute :title, :string, allow_nil?: false, public?: true
      attribute :room, :string, public?: true
    end

    relationships do
      belongs_to :event, Event, allow_nil?: false, public?: true
    end
  end

  defmodule Conference do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestMdmStore
      collection :conferences

      nested_in :events,
        foreign_key: :event_id,
        path: :conference,
        cardinality: :one

      references do
        reference :organizer, on_delete: :restrict
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:event_id, :organizer_id, :title, :location_name, :location_city]
      end

      read :by_event_id do
        argument :event_id, :integer, allow_nil?: false
        get? true
        filter expr(event_id == ^arg(:event_id))
      end
    end

    attributes do
      integer_primary_key :id
      attribute :title, :string, allow_nil?: false, public?: true
      attribute :location_name, :string, public?: true
      attribute :location_city, :string, public?: true
    end

    calculations do
      calculate :location,
                :string,
                expr(if(is_nil(location_city), location_name, location_city)),
                public?: true
    end

    relationships do
      belongs_to :event, Event, allow_nil?: false, public?: true
      belongs_to :organizer, User, allow_nil?: false, public?: true
    end
  end

  defmodule TableTalkSeat do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestMdmStore
      collection :table_talk_seats

      references do
        reference :conference, on_delete: :delete
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:conference_id, :table_talk_id, :user_id, :status]
      end

      update :update do
        primary? true
        accept [:status]
      end
    end

    attributes do
      integer_primary_key :id
      attribute :table_talk_id, :integer, allow_nil?: false, public?: true
      attribute :status, :atom, default: :confirmed, constraints: [one_of: [:confirmed, :cancelled]], public?: true
    end

    identities do
      identity :unique_confirmed_seat, [:table_talk_id, :user_id] do
        where expr(status == :confirmed)
      end
    end

    relationships do
      belongs_to :conference, Conference, allow_nil?: false, public?: true
      belongs_to :user, User, allow_nil?: false, public?: true
    end
  end

  # Lives in TestAppStore while referencing Organization & User in TestMdmStore!
  defmodule Deal do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer,
      authorizers: [Ash.Policy.Authorizer]

    xitdb do
      store TestAppStore
      collection :marketplace_deals
    end

    policies do
      bypass actor_attribute_equals(:role, :admin) do
        authorize_if always()
      end

      policy action_type(:read) do
        forbid_unless actor_attribute_equals(:status, :active)

        authorize_if expr(
                       is_nil(target_audience) or
                         poster_id == ^actor(:id) or
                         organization.admin_id == ^actor(:id) or
                         exists(
                           organization.profiles,
                           user_id == ^actor(:id) and org_role in [:admin, :contributor]
                         )
                     )
      end

      policy action_type([:create, :update]) do
        forbid_unless actor_attribute_equals(:status, :active)

        authorize_if expr(
                       poster_id == ^actor(:id) or
                         exists(
                           organization.profiles,
                           user_id == ^actor(:id) and org_role in [:admin, :contributor]
                         )
                     )
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:title, :organization_id, :poster_id, :target_audience]
      end

      update :update do
        primary? true
        accept [:title]
      end

      update :increment_views do
        change atomic_update(:view_count, expr(view_count + 1))
      end
    end

    attributes do
      integer_primary_key :id
      attribute :title, :string, allow_nil?: false, public?: true
      attribute :target_audience, :atom, constraints: [one_of: [:sfo_only]], public?: true
      attribute :view_count, :integer, default: 0, allow_nil?: false, public?: true
    end

    calculations do
      calculate :has_materials_access,
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
    end

    relationships do
      belongs_to :organization, Organization, public?: true
      belongs_to :poster, User, allow_nil?: false, public?: true
    end
  end

  defmodule Message do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestAppStore
      collection :messages
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:body]
      end
    end

    attributes do
      integer_primary_key :id
      attribute :body, :string, allow_nil?: false, public?: true
    end
  end

  defmodule MessageReport do
    use Ash.Resource,
      domain: TestDomain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store TestAppStore
      collection :message_reports

      references do
        reference :message, on_delete: :nilify
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:message_id, :reason]
      end
    end

    attributes do
      integer_primary_key :id
      attribute :reason, :string, allow_nil?: false, public?: true
    end

    relationships do
      belongs_to :message, Message, allow_nil?: true, public?: true
    end
  end

  # ===========================================================================
  # Per-Test In-Memory Sandbox Setup
  # ===========================================================================

  setup do
    Xitdb.Ash.TestSandbox.checkout([TestMdmStore, TestAppStore])
    :ok
  end

  defp unique_email(prefix \\ "member") do
    "#{prefix}_#{System.unique_integer([:positive])}@polar.ca"
  end

  defp unique_slug(prefix \\ "org") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  # ===========================================================================
  # Specifications
  # ===========================================================================

  describe "sequences, CiString identities, counted sets, and upserts" do
    test "allocates monotonic integer IDs, enforces case-insensitive uniqueness, and round-trips counted sets" do
      u1 = TestDomain.create_user!(%{email: "Jane.Doe@Polar.CA"}, authorize?: false)
      u2 = TestDomain.create_user!(%{email: unique_email("bob")}, authorize?: false)

      assert u1.id == 1
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

      # Upsert on :unique_slug (case-insensitive) updates :name/:domain while preserving :id & :aliases
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

    test "enforces partial `where:` identities on create and status transitions" do
      user = TestDomain.create_user!(%{email: unique_email()}, authorize?: false)
      ev = TestDomain.create_event!(%{title: "Summit", start_time: ~U[2026-10-15 13:00:00Z]}, authorize?: false)
      conf = TestDomain.create_conference!(%{event_id: ev.id, organizer_id: user.id, title: "Summit"}, authorize?: false)

      seat1 =
        TestDomain.reserve_seat!(
          %{conference_id: conf.id, table_talk_id: 10, user_id: user.id, status: :cancelled},
          authorize?: false
        )

      # Multiple :cancelled rows for the same (table_talk_id, user_id) are allowed
      seat2 =
        TestDomain.reserve_seat!(
          %{conference_id: conf.id, table_talk_id: 10, user_id: user.id, status: :cancelled},
          authorize?: false
        )

      assert seat1.id != seat2.id

      # First :confirmed seat succeeds; second :confirmed seat is rejected
      _confirmed =
        TestDomain.reserve_seat!(
          %{conference_id: conf.id, table_talk_id: 10, user_id: user.id, status: :confirmed},
          authorize?: false
        )

      assert {:error, %Ash.Error.Invalid{}} =
               TestDomain.reserve_seat(
                 %{conference_id: conf.id, table_talk_id: 10, user_id: user.id, status: :confirmed},
                 authorize?: false
               )

      # Transitioning a :cancelled seat to :confirmed also triggers the partial identity check
      assert {:error, %Ash.Error.Invalid{}} =
               TestDomain.update_seat(seat1, %{status: :confirmed}, authorize?: false)
    end
  end

  describe "nested_in subtrees (:many and :one) & _parent direct lookup" do
    test "co-locates sessions and conference inside events[eid] while supporting direct ID & event_id lookups" do
      organizer = TestDomain.create_user!(%{email: unique_email("org")}, authorize?: false)

      ev1 =
        TestDomain.create_event!(
          %{title: "Montreal Summit", start_time: ~U[2026-10-20 14:00:00Z]},
          load: [:start_date],
          authorize?: false
        )

      ev2 =
        TestDomain.create_event!(
          %{title: "Toronto Forum", start_time: ~U[2026-11-05 14:00:00Z]},
          authorize?: false
        )

      assert ev1.start_date == ~D[2026-10-20]

      s1 = TestDomain.create_session!(%{event_id: ev1.id, title: "Macro Panel", room: "Hall A"}, authorize?: false)
      _s2 = TestDomain.create_session!(%{event_id: ev2.id, title: "Credit Panel", room: "Hall B"}, authorize?: false)

      conf =
        TestDomain.create_conference!(
          %{
            event_id: ev1.id,
            organizer_id: organizer.id,
            title: "Montreal Institutional Summit",
            location_name: "Ritz-Carlton"
          },
          load: [:location],
          authorize?: false
        )

      assert conf.location == "Ritz-Carlton"

      # 1. Direct lookup by session ID without event_id uses idx.agenda_sessions._parent
      fetched_session = TestDomain.get_session!(s1.id, authorize?: false)
      assert fetched_session.title == "Macro Panel"
      assert fetched_session.event_id == ev1.id

      # 2. Explicit get_conference_by_event_id disambiguates Event.id vs Conference.id
      fetched_conf = TestDomain.get_conference_by_event_id!(ev1.id, authorize?: false)
      assert fetched_conf.id == conf.id

      # 3. Verify physical co-location inside Xitdb `events[eid]` subtree
      root = TestMdmStore.root()
      assert root["events"][to_string(ev1.id)]["sessions"][to_string(s1.id)]["title"] == "Macro Panel"
      assert root["events"][to_string(ev1.id)]["conference"]["title"] == "Montreal Institutional Summit"
    end
  end

  describe "aggregates, cross-store joins, exists(...), and Ash.Policy.Authorizer" do
    test "evaluates filtered roster counts, cross-store Deal policies, and relational calculations" do
      admin = TestDomain.create_user!(%{email: unique_email("admin"), role: :admin}, authorize?: false)
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
        %{user_id: contrib.id, organization_id: org_a.id, first_name: " Clara", org_role: :contributor, directory_visible: true},
        authorize?: false
      )

      TestDomain.create_profile!(
        %{user_id: outsider.id, organization_id: org_a.id, first_name: "Hidden", org_role: :member, directory_visible: false},
        authorize?: false
      )

      # Aggregate filtering & loading (`active_roster_count` counts only directory_visible == true)
      orgs_with_roster =
        TestDomain.list_orgs!(
          load: [:active_roster_count],
          query: [filter: [active_roster_count: [greater_than: 0]]]
        )

      assert [loaded_org_a] = orgs_with_roster
      assert loaded_org_a.id == org_a.id
      assert loaded_org_a.active_roster_count == 1
      assert TestDomain.list_orgs!(load: [:active_roster_count]) |> Enum.find(&(&1.id == org_b.id)) |> Map.fetch!(:active_roster_count) == 0

      # Deal in TestAppStore authorized via Organization & Profile in TestMdmStore
      private_deal =
        TestDomain.create_deal!(
          %{title: "Series B Co-Invest", organization_id: org_a.id, poster_id: owner.id, target_audience: :sfo_only},
          actor: contrib
        )

      public_deal =
        TestDomain.create_deal!(
          %{title: "Open Infrastructure Fund", organization_id: org_b.id, poster_id: owner.id, target_audience: nil},
          actor: owner
        )

      # Write policy enforcement: outsider cannot update private_deal, contributor can
      refute Ash.can?({private_deal, :update}, outsider)
      assert Ash.can?({private_deal, :update}, contrib)

      assert_raise Ash.Error.Forbidden, fn ->
        TestDomain.update_deal!(private_deal, %{title: "Hijacked"}, actor: outsider)
      end

      # Read row-level filtering + `has_materials_access` relational calculation
      outsider_deals = TestDomain.list_deals!(load: [:has_materials_access], actor: outsider)
      assert Enum.map(outsider_deals, & &1.id) == [public_deal.id]
      assert hd(outsider_deals).has_materials_access == true

      contrib_deals = TestDomain.list_deals!(load: [:has_materials_access], actor: contrib)
      assert MapSet.new(contrib_deals, & &1.id) == MapSet.new([private_deal.id, public_deal.id])
      assert Enum.all?(contrib_deals, & &1.has_materials_access)

      admin_deals = TestDomain.list_deals!(load: [:has_materials_access], actor: admin)
      assert length(admin_deals) == 2
    end
  end

  describe "atomic updates, nested savepoint rollbacks, and FK on_delete rules" do
    test "executes atomic increments and supports nested savepoints + full rollbacks" do
      poster = TestDomain.create_user!(%{email: unique_email("poster")}, authorize?: false)

      deal =
        TestDomain.create_deal!(
          %{title: "Atomic Deal", poster_id: poster.id},
          authorize?: false
        )

      updated = TestDomain.increment_views!(deal, authorize?: false)
      assert updated.view_count == 1

      # Outer transaction commits u_outer while inner savepoint rolls back u_inner
      {:ok, outer_user} =
        Ash.DataLayer.transaction(User, fn ->
          u_outer = TestDomain.create_user!(%{email: unique_email("outer")}, authorize?: false)

          assert {:error, :inner_aborted} =
                   Ash.DataLayer.transaction(User, fn ->
                     _u_inner = TestDomain.create_user!(%{email: "rolled_back@polar.ca"}, authorize?: false)
                     Ash.DataLayer.rollback(User, :inner_aborted)
                   end)

          # Read-your-own-writes inside outer tx sees u_outer, not rolled-back u_inner
          assert TestDomain.get_user!(u_outer.id, authorize?: false).id == u_outer.id
          assert User |> Ash.Query.filter(email == "rolled_back@polar.ca") |> Ash.read_one!(authorize?: false) == nil

          u_outer
        end)

      assert TestDomain.get_user!(outer_user.id, authorize?: false).id == outer_user.id
    end

    test "enforces :restrict, :nilify, and cascading :delete across references" do
      organizer = TestDomain.create_user!(%{email: unique_email("organizer")}, authorize?: false)
      ev = TestDomain.create_event!(%{title: "Cascade Test", start_time: ~U[2026-10-01 12:00:00Z]}, authorize?: false)
      sess = TestDomain.create_session!(%{event_id: ev.id, title: "Keynote"}, authorize?: false)
      conf = TestDomain.create_conference!(%{event_id: ev.id, organizer_id: organizer.id, title: "Conf"}, authorize?: false)
      _seat = TestDomain.reserve_seat!(%{conference_id: conf.id, table_talk_id: 1, user_id: organizer.id}, authorize?: false)

      # 1. :restrict blocks destroying organizer while Conference references them
      assert {:error, %Ash.Error.Invalid{}} = TestDomain.destroy_user(organizer, authorize?: false)

      # 2. :delete cascades TableTalkSeat removal when Conference is destroyed, unblocking organizer deletion
      :ok = TestDomain.destroy_conference!(conf, authorize?: false)
      assert Ash.read!(TableTalkSeat, authorize?: false) == []
      :ok = TestDomain.destroy_user!(organizer, authorize?: false)

      # 3. :delete on nested_in AgendaSession removes session + _parent index when Event is destroyed
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

  describe "TestSandbox $callers isolation & VerifyNoSqlFragments verifier" do
    test "propagates sandbox state to child Task.async_stream workers via $callers" do
      created = TestDomain.create_user!(%{email: unique_email("async_parent")}, authorize?: false)

      results =
        1..4
        |> Task.async_stream(fn _ ->
          TestDomain.get_user!(created.id, authorize?: false).id
        end)
        |> Enum.map(fn {:ok, id} -> id end)

      assert results == [created.id, created.id, created.id, created.id]
    end

    test "rejects SQL fragment(...) calculations at compile time with Spark.Error.DslError" do
      assert_raise Spark.Error.DslError, ~r/SQL `fragment\(\.\.\.\)` is not supported/, fn ->
        Code.compile_string("""
        defmodule Xitdb.Ash.InvalidFragmentResource do
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
      end
    end
  end
end
```

---

## 3. Verification Loop & Cursor Seam Notes

### 3.1 Verification Commands
From the `xitdb` repository (`/home/pauli/projects/elixir/xitdb`):

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/xitdb/ash/data_layer_test.exs
```

### 3.2 Cursor API Seam Adaptation Note
Because `Indexer.put_deep/3` and `Indexer.delete_deep/2` are the only two functions that touch `Xitdb`'s internal write-cursor API inside `Xitdb.transact/3`, if your `xitdb` version uses explicit cursor functions rather than `Access` `put_in`/`pop_in` inside `Xitdb.transact/3`, those 12 lines in `lib/xitdb/ash/indexer.ex` are the **only** seam you will need to adapt.
