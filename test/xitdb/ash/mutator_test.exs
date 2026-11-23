if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.MutatorTest do
    use ExUnit.Case, async: true

    require Ash.Query

    alias Xitdb.Ash.{Indexer, Search, Store, TestSandbox}

    # --------------------------------------------------------------------------
    # Test Stores, Domain, Validations & Resources
    # --------------------------------------------------------------------------

    defmodule MutatorPrimaryStore do
      use Xitdb.Ash.Store
    end

    defmodule MutatorSecondaryStore do
      use Xitdb.Ash.Store
    end

    defmodule CorporateEmailValidation do
      use Ash.Resource.Validation
      import Ash.Expr

      @impl true
      def validate(changeset, _opts, _context) do
        case Ash.Changeset.get_attribute(changeset, :email) do
          nil ->
            :ok

          email ->
            str = email |> to_string() |> String.downcase()

            if String.ends_with?(str, "@gmail.com") do
              {:error, field: :email, message: "must use a corporate domain"}
            else
              :ok
            end
        end
      end

      @impl true
      def atomic(_changeset, _opts, _context) do
        {:atomic, [:email],
         expr(not is_nil(^atomic_ref(:email)) and contains(^atomic_ref(:email), "@gmail.com")),
         expr(
           error(Ash.Error.Changes.InvalidAttribute,
             field: :email,
             message: "must use a corporate domain"
           )
         )}
      end
    end

    defmodule Actor do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_actors
      end

      attributes do
        attribute(:id, :integer,
          primary_key?: true,
          allow_nil?: false,
          generated?: true,
          writable?: true,
          public?: true
        )

        attribute(:email, :ci_string, allow_nil?: false, public?: true)
        attribute(:name, :string, allow_nil?: false, public?: true)
      end

      identities do
        identity(:unique_email, [:email])
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:id, :email, :name])
        end

        update :update do
          primary?(true)
          accept([:email, :name])
        end
      end
    end

    defmodule Org do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_orgs
        search_field :name, boost: 2.0
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:slug, :ci_string, allow_nil?: false, public?: true)
        attribute(:owner_id, :integer, public?: true)
      end

      identities do
        identity(:unique_slug, [:slug])
      end

      relationships do
        belongs_to :owner, Actor do
          attribute_type(:integer)
          define_attribute?(false)
          source_attribute(:owner_id)
          public?(true)
        end

        has_many :memberships, Xitdb.Ash.MutatorTest.Membership do
          domain(Xitdb.Ash.MutatorTest.Domain)
          destination_attribute(:org_id)
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:name, :slug, :owner_id])
        end

        create :upsert_replace_all do
          accept([:name, :slug, :owner_id])
          upsert?(true)
          upsert_identity(:unique_slug)
          upsert_fields(:replace_all)
        end
      end
    end

    defmodule Membership do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorSecondaryStore
        collection :m_memberships
        index([:org_id])
      end

      attributes do
        integer_primary_key(:id)

        attribute(:role, :atom,
          default: :member,
          constraints: [one_of: [:member, :contributor, :admin]],
          public?: true
        )
      end

      relationships do
        belongs_to :org, Org do
          domain(Xitdb.Ash.MutatorTest.Domain)
          attribute_type(:integer)
          allow_nil?(false)
          public?(true)
        end

        belongs_to :actor, Actor do
          domain(Xitdb.Ash.MutatorTest.Domain)
          attribute_type(:integer)
          allow_nil?(false)
          public?(true)
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:org_id, :actor_id, :role])
        end
      end
    end

    defmodule Deal do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer,
        authorizers: [Ash.Policy.Authorizer]

      xitdb do
        store MutatorPrimaryStore
        collection :m_deals
        index([:state])
        index([:org_id])
        search_field :title, boost: 2.0

        references do
          reference :org, on_delete: :restrict
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:email, :ci_string, public?: true)
        attribute(:score_a, :integer, default: 10, allow_nil?: false, public?: true)
        attribute(:score_b, :integer, default: 20, allow_nil?: false, public?: true)
        attribute(:version, :integer, default: 1, allow_nil?: false, public?: true)

        attribute(:state, :atom,
          default: :draft,
          constraints: [one_of: [:draft, :published, :archived]],
          allow_nil?: false,
          public?: true
        )
      end

      relationships do
        belongs_to :org, Org do
          attribute_type(:integer)
          allow_nil?(true)
          public?(true)
        end
      end

      validations do
        validate CorporateEmailValidation do
          where [changing(:email)]
        end
      end

      policies do
        policy action_type([:read, :create, :destroy]) do
          authorize_if(always())
        end

        policy action(:update) do
          authorize_if(
            expr(
              exists(org.memberships, actor_id == ^actor(:id) and role in [:contributor, :admin])
            )
          )
        end

        policy action([:swap_scores, :publish, :change_email, :optimistic_rename]) do
          authorize_if(always())
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:title, :email, :score_a, :score_b, :version, :state, :org_id])
        end

        update :update do
          primary?(true)
          accept([:title])
        end

        update :swap_scores do
          accept([])
          change(atomic_update(:score_a, expr(score_b)))
          change(atomic_update(:score_b, expr(score_a)))
        end

        update :publish do
          accept([:title])
          require_atomic?(true)

          validate(attribute_equals(:state, :draft), message: "must be in draft")

          change(set_attribute(:state, :published))
        end

        update :change_email do
          argument(:new_email, :ci_string, allow_nil?: false)
          change(atomic_update(:email, expr(^arg(:new_email))))
        end

        update :optimistic_rename do
          accept([:title])
          argument(:expected_version, :integer, allow_nil?: false)
          change(filter(expr(version == ^arg(:expected_version))))
          change(atomic_update(:version, expr(version + 1)))
        end
      end
    end

    defmodule Badge do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_badges
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:code, :ci_string, allow_nil?: false, public?: true)
        attribute(:label, :string, allow_nil?: false, public?: true)
        attribute(:note, :string, default: "initial", public?: true)
        attribute(:locked, :boolean, default: false, allow_nil?: false, public?: true)
        attribute(:touch_tag, :string, update_default: "touched", public?: true)
      end

      identities do
        identity(:unique_code, [:code])
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:code, :label, :note, :locked])
        end

        create :upsert_nil do
          accept([:code, :label, :note, :locked])
          upsert?(true)
          upsert_identity(:unique_code)
        end

        create :upsert_replace_all do
          accept([:code, :label, :note, :locked])
          upsert?(true)
          upsert_identity(:unique_code)
          upsert_fields(:replace_all)
        end

        create :upsert_replace_tuple do
          accept([:code, :label, :note, :locked])
          upsert?(true)
          upsert_identity(:unique_code)
          upsert_fields({:replace, [:label]})
        end

        create :upsert_except do
          accept([:code, :label, :note, :locked])
          upsert?(true)
          upsert_identity(:unique_code)
          upsert_fields({:replace_all_except, [:note, :locked]})
        end

        create :upsert_list do
          accept([:code, :label, :note, :locked])
          upsert?(true)
          upsert_identity(:unique_code)
          upsert_fields([:label])
        end

        create :upsert_if_unlocked do
          accept([:code, :label, :note, :locked])
          upsert?(true)
          upsert_identity(:unique_code)
          upsert_fields({:replace, [:label]})
          upsert_condition(expr(locked == false))
        end
      end
    end

    defmodule ContextTenantDoc do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_tenant_docs
        index([:tag])
      end

      multitenancy do
        strategy(:context)
      end

      attributes do
        integer_primary_key(:id)
        attribute(:slug, :ci_string, allow_nil?: false, public?: true)
        attribute(:body, :string, allow_nil?: false, public?: true)
        attribute(:tag, :string, default: "general", public?: true)
      end

      identities do
        identity(:unique_slug, [:slug])
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:slug, :body, :tag])
        end

        create :upsert_by_slug do
          accept([:slug, :body, :tag])
          upsert?(true)
          upsert_identity(:unique_slug)
          upsert_fields([:body, :tag])
        end
      end
    end

    defmodule AttrTenantSeat do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_seats
        index([:status])
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org_id)
      end

      attributes do
        integer_primary_key(:id)
        attribute(:org_id, :integer, public?: true)
        attribute(:seat_no, :integer, allow_nil?: false, public?: true)

        attribute(:status, :atom,
          default: :confirmed,
          constraints: [one_of: [:confirmed, :cancelled]],
          allow_nil?: false,
          public?: true
        )
      end

      identities do
        identity :unique_confirmed_seat, [:seat_no] do
          where expr(status == :confirmed)
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:org_id, :seat_no, :status])
        end
      end
    end

    defmodule CascadeParent do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_cascade_parents
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:name])
        end
      end
    end

    defmodule CascadeDeleteChild do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_cascade_delete_children
        index([:parent_id])
        index([:tag])
        search_field :title, boost: 1.5

        references do
          reference :parent, on_delete: :delete
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:tag, :string, default: "child", public?: true)
      end

      relationships do
        belongs_to :parent, CascadeParent do
          attribute_type(:integer)
          allow_nil?(false)
          public?(true)
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:parent_id, :title, :tag])
        end
      end
    end

    defmodule CascadeNilifyChild do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_cascade_nilify_children
        index([:parent_id])
        search_field :label, boost: 1.0

        search_field :parent_name,
          boost: 2.0,
          resolver: fn child, db ->
            Search.lookup_field(db, :m_cascade_parents, child.parent_id, "name")
          end

        references do
          reference :parent, on_delete: :nilify
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:label, :string, allow_nil?: false, public?: true)
      end

      relationships do
        belongs_to :parent, CascadeParent do
          attribute_type(:integer)
          allow_nil?(true)
          public?(true)
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:parent_id, :label])
        end
      end
    end

    defmodule CascadeNothingChild do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_cascade_nothing_children
        index([:parent_id])

        references do
          reference :parent, on_delete: :nothing
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:label, :string, allow_nil?: false, public?: true)
      end

      relationships do
        belongs_to :parent, CascadeParent do
          attribute_type(:integer)
          allow_nil?(false)
          public?(true)
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:parent_id, :label])
        end
      end
    end

    defmodule CyclicNode do
      use Ash.Resource,
        domain: Xitdb.Ash.MutatorTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store MutatorPrimaryStore
        collection :m_cyclic_nodes
        index([:parent_id])

        references do
          reference :parent, on_delete: :delete
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
      end

      relationships do
        belongs_to :parent, CyclicNode do
          attribute_type(:integer)
          allow_nil?(true)
          public?(true)
        end
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:name, :parent_id])
        end

        update :update do
          primary?(true)
          accept([:parent_id])
        end
      end
    end

    defmodule Domain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(Actor)
        resource(Org)
        resource(Membership)
        resource(Deal)
        resource(Badge)
        resource(ContextTenantDoc)
        resource(AttrTenantSeat)
        resource(CascadeParent)
        resource(CascadeDeleteChild)
        resource(CascadeNilifyChild)
        resource(CascadeNothingChild)
        resource(CyclicNode)
      end
    end

    # --------------------------------------------------------------------------
    # Sandbox Setup
    # --------------------------------------------------------------------------

    setup_all do
      TestSandbox.init()
      {:ok, p_pid} = Store.start_link(name: MutatorPrimaryStore, path: :memory, domains: [Domain])

      {:ok, s_pid} =
        Store.start_link(name: MutatorSecondaryStore, path: :memory, domains: [Domain])

      on_exit(fn ->
        for pid <- [p_pid, s_pid], Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok
    end

    setup do
      :ok = TestSandbox.checkout([MutatorPrimaryStore, MutatorSecondaryStore])
      :ok
    end

    # --------------------------------------------------------------------------
    # Phase 1: Single-Commit Sequences, Create & Bulk Create
    # --------------------------------------------------------------------------

    describe "create/2 and Mutator.Sequences" do
      test "allocates monotonic integer PKs and indexes in a single commit, advancing high-water mark on explicit IDs" do
        m0 = Store.root(MutatorPrimaryStore).moment
        a1 = Ash.create!(Actor, %{email: "First@Corp.CA", name: "First"}, domain: Domain)
        m1 = Store.root(MutatorPrimaryStore).moment

        assert m1 == m0 + 1
        assert a1.id == 1

        a2 = Ash.create!(Actor, %{email: "second@corp.ca", name: "Second"}, domain: Domain)
        assert a2.id == 2

        # Explicit ID smaller than current high-water mark rejected if collided, higher advances sequence
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.create(Actor, %{id: 2, email: "dup-pk@corp.ca", name: "Dup"}, domain: Domain)

        a10 =
          Ash.create!(Actor, %{id: 10, email: "ten@corp.ca", name: "Ten"}, domain: Domain)

        assert a10.id == 10

        a11 = Ash.create!(Actor, %{email: "eleven@corp.ca", name: "Eleven"}, domain: Domain)
        assert a11.id == 11

        # Unique identity conflict on ci_string email is rejected
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.create(Actor, %{email: "FIRST@corp.ca", name: "DupEmail"}, domain: Domain)
      end
    end

    describe "bulk_create/3 single-commit atomicity" do
      test "commits all valid records in 1 moment and rolls back entire batch on intra-batch PK or identity collision" do
        m0 = Store.root(MutatorPrimaryStore).moment

        inputs = [
          %{email: "b1@corp.ca", name: "Bulk 1"},
          %{email: "b2@corp.ca", name: "Bulk 2"},
          %{email: "b3@corp.ca", name: "Bulk 3"}
        ]

        %Ash.BulkResult{status: :success, records: created} =
          Ash.bulk_create!(inputs, Actor, :create, domain: Domain, return_records?: true)

        m1 = Store.root(MutatorPrimaryStore).moment
        assert m1 == m0 + 1
        assert Enum.map(created, & &1.id) == [1, 2, 3]

        # Intra-batch duplicate email rolls back with 0 new moments written
        m_before_id_err = Store.root(MutatorPrimaryStore).moment

        dup_id_result =
          Ash.bulk_create(
            [
              %{email: "good1@corp.ca", name: "Good"},
              %{email: "GOOD1@corp.ca", name: "Dup"}
            ],
            Actor,
            :create,
            domain: Domain,
            return_errors?: true
          )

        assert dup_id_result.status == :error
        assert Store.root(MutatorPrimaryStore).moment == m_before_id_err
        assert length(Ash.read!(Actor, domain: Domain)) == 3

        # Intra-batch duplicate PK also leaves 0 new moments
        dup_pk_result =
          Ash.bulk_create(
            [
              %{id: 50, email: "pk50a@corp.ca", name: "PK50A"},
              %{id: 50, email: "pk50b@corp.ca", name: "PK50B"}
            ],
            Actor,
            :create,
            domain: Domain,
            return_errors?: true
          )

        assert dup_pk_result.status == :error
        assert Store.root(MutatorPrimaryStore).moment == m_before_id_err
        assert length(Ash.read!(Actor, domain: Domain)) == 3
      end
    end

    # --------------------------------------------------------------------------
    # Phase 2: Atomic Updates, Pre/Post-Update Semantics & `:unknown` Policies
    # --------------------------------------------------------------------------

    describe "update/2 and update_query/4 atomic semantics" do
      test "evaluates pre-update swap atomics, state-transition validations, atomic_ref validations, and optimistic locks" do
        deal =
          Ash.create!(
            Deal,
            %{
              title: "Bridge Loan",
              email: "team@polar.ca",
              score_a: 10,
              score_b: 99,
              version: 1,
              state: :draft
            },
            domain: Domain,
            authorize?: false
          )

        m0 = Store.root(MutatorPrimaryStore).moment
        swapped = Ash.update!(deal, %{}, action: :swap_scores, domain: Domain, authorize?: false)
        m1 = Store.root(MutatorPrimaryStore).moment

        assert m1 == m0 + 1
        assert swapped.score_a == 99
        assert swapped.score_b == 10

        # Pre-update state == :draft passes while setting :published
        published =
          Ash.update!(swapped, %{title: "Published Loan"},
            action: :publish,
            domain: Domain,
            authorize?: false
          )

        assert published.state == :published
        assert published.title == "Published Loan"

        # Repeating publish fails atomic_validation (pre-update state != :draft)
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.update(published, %{title: "Re-Publish"},
                   action: :publish,
                   domain: Domain,
                   authorize?: false
                 )

        # Post-update atomic_ref(:email) rejects consumer domain without mutating record
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.update(published, %{new_email: "bad@gmail.com"},
                   action: :change_email,
                   domain: Domain,
                   authorize?: false
                 )

        reloaded = Ash.get!(Deal, published.id, domain: Domain, authorize?: false)
        assert to_string(reloaded.email) == "team@polar.ca"

        # Valid atomic email update succeeds
        updated_email =
          Ash.update!(published, %{new_email: "deals@maplecapital.ca"},
            action: :change_email,
            domain: Domain,
            authorize?: false
          )

        assert to_string(updated_email.email) == "deals@maplecapital.ca"

        # Changeset filter / optimistic lock enforces expected_version
        assert {:error, %Ash.Error.Invalid{errors: errs}} =
                 Ash.update(updated_email, %{title: "Stale", expected_version: 999},
                   action: :optimistic_rename,
                   domain: Domain,
                   authorize?: false
                 )

        assert Enum.any?(errs, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

        bumped =
          Ash.update!(updated_email, %{title: "Fresh", expected_version: 1},
            action: :optimistic_rename,
            domain: Domain,
            authorize?: false
          )

        assert bumped.version == 2
        assert bumped.title == "Fresh"
      end

      test "evaluates cross-store relational :unknown policy filters without silent bypass on update and update_query" do
        contrib =
          Ash.create!(Actor, %{email: "contrib@polar.ca", name: "Contrib"}, domain: Domain)

        outsider =
          Ash.create!(Actor, %{email: "outsider@polar.ca", name: "Outsider"}, domain: Domain)

        org =
          Ash.create!(
            Org,
            %{name: "Polar Cap", slug: "polar-cap", owner_id: contrib.id},
            domain: Domain
          )

        Ash.create!(
          Membership,
          %{org_id: org.id, actor_id: contrib.id, role: :contributor},
          domain: Domain
        )

        deal =
          Ash.create!(
            Deal,
            %{title: "Co-Invest A", org_id: org.id},
            domain: Domain,
            authorize?: false
          )

        other_deal =
          Ash.create!(
            Deal,
            %{title: "Orphan Deal", org_id: nil},
            domain: Domain,
            authorize?: false
          )

        # Cross-store exists(org.memberships, ...) triggers :unknown -> Runtime.filter_matches
        refute Ash.can?({deal, :update}, outsider)
        assert Ash.can?({deal, :update}, contrib)

        assert_raise Ash.Error.Forbidden, fn ->
          Ash.update!(deal, %{title: "Hijacked"}, domain: Domain, actor: outsider)
        end

        assert Ash.get!(Deal, deal.id, domain: Domain).title == "Co-Invest A"

        updated = Ash.update!(deal, %{title: "Authorized Edit"}, domain: Domain, actor: contrib)
        assert updated.title == "Authorized Edit"

        # Bulk update_query updates only matching records and skips filtered ones
        %Ash.BulkResult{status: :success, records: bulk_updated} =
          Deal
          |> Ash.Query.filter(state == :draft)
          |> Ash.bulk_update!(:optimistic_rename, %{title: "Bulk Renamed", expected_version: 1},
            domain: Domain,
            authorize?: false,
            return_records?: true
          )

        assert MapSet.new(bulk_updated, & &1.id) == MapSet.new([deal.id, other_deal.id])
        assert Enum.all?(bulk_updated, &(&1.version == 2 and &1.title == "Bulk Renamed"))
      end
    end

    # --------------------------------------------------------------------------
    # Phase 3: Primary-Key-Safe Upserts & Multitenancy
    # --------------------------------------------------------------------------

    describe "upsert/4 across all Ash 3 upsert_fields shapes and identities" do
      test "preserves uuid_primary_key and handles nil, :replace_all, {:replace, ...}, {:replace_all_except, ...}, lists, and upsert_condition" do
        created =
          Ash.create!(
            Badge,
            %{code: "VIP-01", label: "Original", note: "keep-note", locked: false},
            domain: Domain
          )

        orig_id = created.id

        # 1. {:replace, [:label]} preserves :id and :note and :locked
        m0 = Store.root(MutatorPrimaryStore).moment

        u1 =
          Ash.create!(
            Badge,
            %{code: "vip-01", label: "Tuple Updated", note: "ignored", locked: true},
            action: :upsert_replace_tuple,
            domain: Domain
          )

        assert Store.root(MutatorPrimaryStore).moment == m0 + 1
        assert u1.id == orig_id
        assert u1.label == "Tuple Updated"
        assert u1.note == "keep-note"
        assert u1.locked == false

        # 2. {:replace_all_except, [:note, :locked]} preserves :id, :note, :locked
        u2 =
          Ash.create!(
            Badge,
            %{code: "VIP-01", label: "Except Updated", note: "still-ignored", locked: true},
            action: :upsert_except,
            domain: Domain
          )

        assert u2.id == orig_id
        assert u2.label == "Except Updated"
        assert u2.note == "keep-note"
        assert u2.locked == false

        # 3. Explicit list [:label] preserves :id and :note
        u3 =
          Ash.create!(
            Badge,
            %{code: "vip-01", label: "List Updated", note: "list-ignored", locked: true},
            action: :upsert_list,
            domain: Domain
          )

        assert u3.id == orig_id
        assert u3.label == "List Updated"
        assert u3.note == "keep-note"

        # 4. Omitted upsert_fields (nil): replaces explicit attrs + update_defaults while preserving :id
        u4 =
          Ash.create!(
            Badge,
            %{code: "VIP-01", label: "Nil Default"},
            action: :upsert_nil,
            domain: Domain
          )

        assert u4.id == orig_id
        assert u4.label == "Nil Default"
        assert u4.touch_tag == "touched"
        assert u4.note == "keep-note"

        # 5. :replace_all updates :label, :note, :locked while NEVER overwriting :id
        u5 =
          Ash.create!(
            Badge,
            %{code: "vip-01", label: "Replaced All", note: "new-note", locked: true},
            action: :upsert_replace_all,
            domain: Domain
          )

        assert u5.id == orig_id
        assert u5.label == "Replaced All"
        assert u5.note == "new-note"
        assert u5.locked == true

        # 6. upsert_condition (`locked == false`) skips mutating locked row (`StaleRecord` by default, `:upsert_skipped` with `return_skipped_upsert?: true`)
        assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
                 Ash.create(
                   Badge,
                   %{code: "VIP-01", label: "Should Skip"},
                   action: :upsert_if_unlocked,
                   domain: Domain
                 )

        skipped =
          Ash.create!(
            Badge,
            %{code: "VIP-01", label: "Should Skip"},
            action: :upsert_if_unlocked,
            return_skipped_upsert?: true,
            domain: Domain
          )

        assert skipped.id == orig_id
        assert skipped.label == "Replaced All"
        assert Ash.Resource.get_metadata(skipped, :upsert_skipped) == true
      end

      test "isolates :context and :attribute multitenancy and partial where: identities across create and upsert" do
        d1 =
          Ash.create!(
            ContextTenantDoc,
            %{slug: "intro", body: "Alpha v1", tag: "v1"},
            domain: Domain,
            tenant: "t_alpha"
          )

        d2 =
          Ash.create!(
            ContextTenantDoc,
            %{slug: "INTRO", body: "Beta v1", tag: "v1"},
            domain: Domain,
            tenant: "t_beta"
          )

        assert d1.id == 1
        assert d2.id == 1

        # Upsert within t_alpha updates only d1 without affecting t_beta
        d1_up =
          Ash.create!(
            ContextTenantDoc,
            %{slug: "Intro", body: "Alpha v2", tag: "v2"},
            action: :upsert_by_slug,
            domain: Domain,
            tenant: "t_alpha"
          )

        assert d1_up.id == 1
        assert d1_up.body == "Alpha v2"
        assert Ash.get!(ContextTenantDoc, 1, domain: Domain, tenant: "t_beta").body == "Beta v1"

        # Bulk upsert via bulk_create
        %Ash.BulkResult{status: :success, records: bulk_docs} =
          Ash.bulk_create!(
            [
              %{slug: "intro", body: "Beta v2", tag: "v2"},
              %{slug: "second", body: "Beta new", tag: "new"}
            ],
            ContextTenantDoc,
            :upsert_by_slug,
            domain: Domain,
            tenant: "t_beta",
            upsert?: true,
            upsert_identity: :unique_slug,
            upsert_fields: [:body, :tag],
            return_records?: true
          )

        assert Enum.map(bulk_docs, &{&1.id, &1.body}) == [{1, "Beta v2"}, {2, "Beta new"}]

        # Partial where: identity scoped by :attribute multitenancy
        _c1 =
          Ash.create!(
            AttrTenantSeat,
            %{seat_no: 7, status: :cancelled},
            domain: Domain,
            tenant: 10
          )

        _c2 =
          Ash.create!(
            AttrTenantSeat,
            %{seat_no: 7, status: :cancelled},
            domain: Domain,
            tenant: 10
          )

        conf10 =
          Ash.create!(
            AttrTenantSeat,
            %{seat_no: 7, status: :confirmed},
            domain: Domain,
            tenant: 10
          )

        # Same seat_no confirmed is allowed in different attribute tenant 20
        conf20 =
          Ash.create!(
            AttrTenantSeat,
            %{seat_no: 7, status: :confirmed},
            domain: Domain,
            tenant: 20
          )

        assert conf10.id != conf20.id

        # Duplicate confirmed seat_no in same tenant 10 is rejected
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.create(
                   AttrTenantSeat,
                   %{seat_no: 7, status: :confirmed},
                   domain: Domain,
                   tenant: 10
                 )
      end
    end

    # --------------------------------------------------------------------------
    # Phase 4: Destroy, Reverse FK Cascades & Savepoints
    # --------------------------------------------------------------------------

    describe "destroy/2, destroy_query/4, cascades and rollback" do
      test "enforces :restrict, :nilify, :delete, :nothing, cyclic safety, and cleans BM25 + secondary indexes" do
        org =
          Ash.create!(Org, %{name: "Cascade Org", slug: "cascade-org"}, domain: Domain)

        deal =
          Ash.create!(
            Deal,
            %{title: "Restricted Deal", org_id: org.id, state: :draft},
            domain: Domain,
            authorize?: false
          )

        # :restrict blocks org destroy while deal references it
        assert {:error, %Ash.Error.Invalid{}} = Ash.destroy(org, domain: Domain)

        # Destroying leaf deal removes BM25 + secondary index entries in a single commit
        assert Search.ids(Deal, "restricted") == [deal.id]
        m0 = Store.root(MutatorPrimaryStore).moment
        :ok = Ash.destroy!(deal, domain: Domain, authorize?: false)
        assert Store.root(MutatorPrimaryStore).moment == m0 + 1
        assert Search.ids(Deal, "restricted") == []

        assert Indexer.lookup_secondary_eq(
                 Store.current_db(MutatorPrimaryStore),
                 Deal,
                 %{fields: [:state]},
                 [:draft]
               )
               |> MapSet.size() == 0

        # Now org can be destroyed
        :ok = Ash.destroy!(org, domain: Domain)

        # Parent with :delete, :nilify, and :nothing children
        parent = Ash.create!(CascadeParent, %{name: "Root"}, domain: Domain)

        del_child =
          Ash.create!(
            CascadeDeleteChild,
            %{parent_id: parent.id, title: "Sovereign Mandate", tag: "keep-clean"},
            domain: Domain
          )

        nil_child =
          Ash.create!(
            CascadeNilifyChild,
            %{parent_id: parent.id, label: "Audit Log"},
            domain: Domain
          )

        noth_child =
          Ash.create!(
            CascadeNothingChild,
            %{parent_id: parent.id, label: "Historical"},
            domain: Domain
          )

        assert Search.ids(CascadeDeleteChild, "sovereign") == [del_child.id]
        assert Search.ids(CascadeNilifyChild, "root") == [nil_child.id]

        assert is_nil(
                 Search.lookup_field(
                   Store.current_db(MutatorPrimaryStore),
                   :m_cascade_parents,
                   nil,
                   "name"
                 )
               )

        :ok = Ash.destroy!(parent, domain: Domain)

        # :delete removed child + BM25 + secondary index
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.get(CascadeDeleteChild, del_child.id, domain: Domain)

        assert Search.ids(CascadeDeleteChild, "sovereign") == []

        assert Indexer.lookup_secondary_eq(
                 Store.current_db(MutatorPrimaryStore),
                 CascadeDeleteChild,
                 %{fields: [:tag]},
                 ["keep-clean"]
               )
               |> MapSet.size() == 0

        # :nilify cleared FK, updated secondary index, and purged stale cross-resource BM25 postings
        reloaded_nil = Ash.get!(CascadeNilifyChild, nil_child.id, domain: Domain)
        assert is_nil(reloaded_nil.parent_id)
        assert Search.ids(CascadeNilifyChild, "root") == []
        assert Search.ids(CascadeNilifyChild, "audit") == [nil_child.id]

        assert Indexer.lookup_secondary_eq(
                 Store.current_db(MutatorPrimaryStore),
                 CascadeNilifyChild,
                 %{fields: [:parent_id]},
                 [parent.id]
               )
               |> MapSet.size() == 0

        # :nothing left record untouched
        reloaded_noth = Ash.get!(CascadeNothingChild, noth_child.id, domain: Domain)
        assert reloaded_noth.parent_id == parent.id

        # Cyclic self-reference deletes cleanly without infinite recursion
        n1 = Ash.create!(CyclicNode, %{name: "N1"}, domain: Domain)
        n2 = Ash.create!(CyclicNode, %{name: "N2", parent_id: n1.id}, domain: Domain)
        Ash.update!(n1, %{parent_id: n2.id}, domain: Domain)

        :ok = Ash.destroy!(n1, domain: Domain)
        assert Ash.read!(CyclicNode, domain: Domain) == []
      end

      test "bulk destroy_query cascades and Store.transact rolls back on explicit rollback or error" do
        p1 = Ash.create!(CascadeParent, %{name: "Batch 1"}, domain: Domain)
        p2 = Ash.create!(CascadeParent, %{name: "Batch 2"}, domain: Domain)

        c1 =
          Ash.create!(
            CascadeDeleteChild,
            %{parent_id: p1.id, title: "Child One Alpha"},
            domain: Domain
          )

        c2 =
          Ash.create!(
            CascadeDeleteChild,
            %{parent_id: p2.id, title: "Child Two Beta"},
            domain: Domain
          )

        %Ash.BulkResult{status: :success, records: destroyed} =
          CascadeParent
          |> Ash.Query.filter(name == "Batch 1")
          |> Ash.bulk_destroy!(:destroy, %{}, domain: Domain, return_records?: true)

        assert Enum.map(destroyed, & &1.id) == [p1.id]
        assert Search.ids(CascadeDeleteChild, "alpha") == []
        assert Search.ids(CascadeDeleteChild, "beta") == [c2.id]
        assert {:error, _} = Ash.get(CascadeDeleteChild, c1.id, domain: Domain)

        # Savepoint rollback inside Store.transact restores p2
        assert {:error, :aborted} =
                 Store.transact(MutatorPrimaryStore, fn ->
                   :ok = Ash.destroy!(p2, domain: Domain)
                   assert Ash.read!(CascadeParent, domain: Domain) == []
                   Store.rollback(MutatorPrimaryStore, :aborted)
                 end)

        assert [reloaded_p2] = Ash.read!(CascadeParent, domain: Domain)
        assert reloaded_p2.id == p2.id
        assert Search.ids(CascadeDeleteChild, "beta") == [c2.id]
      end
    end

    describe "update freshness and create_atomics" do
      defmodule ProfileCalcDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          allow_unregistered?(true)
        end
      end

      defmodule ProfileCalcResource do
        use Ash.Resource,
          domain: ProfileCalcDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(MutatorPrimaryStore)
          collection(:mutator_profile_calcs)
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            allow_nil?: false,
            writable?: true,
            public?: true
          )

          attribute(:slug, :string, allow_nil?: false, public?: true)
          attribute(:headline, :string, allow_nil?: false, public?: true)
        end

        identities do
          identity(:unique_slug, [:slug])
        end

        calculations do
          calculate(:display_badge, :string, expr("Badge: " <> headline))
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :slug, :headline])
          end

          update :update do
            primary?(true)
            accept([:headline])
          end
        end
      end

      test "update does not leak stale calculations from changeset.data" do
        created =
          ProfileCalcResource
          |> Ash.Changeset.for_create(
            :create,
            %{id: 1, slug: "alice", headline: "Old Headline"},
            domain: ProfileCalcDomain
          )
          |> Ash.create!(domain: ProfileCalcDomain)

        loaded = Ash.load!(created, :display_badge, domain: ProfileCalcDomain)
        assert loaded.display_badge == "Badge: Old Headline"

        updated =
          loaded
          |> Ash.Changeset.for_update(:update, %{headline: "New Headline"},
            domain: ProfileCalcDomain
          )
          |> Ash.update!(domain: ProfileCalcDomain)

        assert updated.headline == "New Headline"
        assert %Ash.NotLoaded{type: :calculation, field: :display_badge} = updated.display_badge

        reloaded = Ash.load!(updated, :display_badge, domain: ProfileCalcDomain)
        assert reloaded.display_badge == "Badge: New Headline"
      end

      test "create_atomics populates allow_nil?: false attributes in create and upsert" do
        import Ash.Expr

        cs_create =
          ProfileCalcResource
          |> Ash.Changeset.for_create(:create, %{id: 10, slug: "bob"}, domain: ProfileCalcDomain)
          |> Map.put(:create_atomics, headline: expr(slug <> " Atomic"))

        assert {:ok, created} = Xitdb.Ash.Mutator.create(ProfileCalcResource, cs_create)
        assert created.headline == "bob Atomic"

        # Upsert matching existing record via upsert key computed in create_atomics
        cs_upsert =
          ProfileCalcResource
          |> Ash.Changeset.for_create(:create, %{id: 10, headline: "Updated Via Upsert"},
            domain: ProfileCalcDomain
          )
          |> Map.put(:create_atomics, slug: expr("b" <> "ob"))

        assert {:ok, upserted} =
                 Xitdb.Ash.Mutator.upsert(
                   ProfileCalcResource,
                   cs_upsert,
                   [:slug],
                   Ash.Resource.Info.identity(ProfileCalcResource, :unique_slug)
                 )

        assert upserted.id == 10
        assert upserted.slug == "bob"
        assert upserted.headline == "Updated Via Upsert"
      end
    end

    describe "Mutator FK cascades, diamond priority, upserts, nested_in :one, and i64 bounds" do
      defmodule FkRegressionsStore do
        use Xitdb.Ash.Store
      end

      defmodule MaxScoreValidation do
        use Ash.Resource.Validation
        import Ash.Expr

        @impl true
        def atomic(_changeset, _opts, _context) do
          {:atomic, [:score], expr(^atomic_ref(:score) > 150),
           expr(
             error(Ash.Error.Changes.InvalidAttribute,
               field: :score,
               message: "score cannot exceed 150"
             )
           )}
        end
      end

      defmodule RegUser do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_users)
        end

        attributes do
          integer_primary_key(:id)
          attribute(:email, :string, allow_nil?: false, public?: true)
          attribute(:version, :integer, default: 1, allow_nil?: false, public?: true)
          attribute(:score, :integer, default: 0, allow_nil?: false, public?: true)
          attribute(:bio, :string, public?: true)
        end

        identities do
          identity(:unique_email, [:email])
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:email, :version, :score, :bio])
            validate(CorporateEmailValidation)
          end

          create :upsert_version do
            accept([:email, :version, :score, :bio])
            upsert?(true)
            upsert_identity(:unique_email)
            upsert_condition(expr(version < 2))
            change(atomic_update(:score, expr(score + 10)))
            validate(CorporateEmailValidation)
          end

          create :upsert_atomic_score do
            accept([:email, :version, :bio])
            upsert?(true)
            upsert_identity(:unique_email)
            change(atomic_update(:score, expr(score + 100)))

            change(fn cs, _ ->
              import Ash.Expr

              %{
                cs
                | atomic_validations: [
                    {expr(^atomic_ref(:score) > 150),
                     expr(
                       error(Ash.Error.Changes.InvalidAttribute,
                         field: :score,
                         message: "score cannot exceed 150"
                       )
                     )}
                    | cs.atomic_validations
                  ]
              }
            end)
          end

          update :add_score do
            accept([])
            change(atomic_update(:score, expr(score + 100)))
            validate(MaxScoreValidation)
          end
        end
      end

      defmodule RegMessage do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_messages)

          references do
            reference(:sender, on_delete: :nilify)
            reference(:recipient, on_delete: :nilify)
          end
        end

        attributes do
          integer_primary_key(:id)
          attribute(:body, :string, allow_nil?: false, public?: true)
        end

        relationships do
          belongs_to(:sender, RegUser, attribute_type: :integer, allow_nil?: true, public?: true)

          belongs_to(:recipient, RegUser,
            attribute_type: :integer,
            allow_nil?: true,
            public?: true
          )
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:body, :sender_id, :recipient_id])
          end
        end
      end

      defmodule SelfNode do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_self_nodes)
          index([:parent_id])

          references do
            reference(:parent, on_delete: :nilify)
          end
        end

        attributes do
          integer_primary_key(:id)
          attribute(:name, :string, allow_nil?: false, public?: true)
        end

        relationships do
          belongs_to :parent, Xitdb.Ash.MutatorTest.SelfNode do
            attribute_type(:integer)
            allow_nil?(true)
            public?(true)
          end
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:name, :parent_id])
          end
        end
      end

      defmodule DiamondRoot do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_diamond_roots)
        end

        attributes do
          integer_primary_key(:id)
          attribute(:name, :string, allow_nil?: false, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:name])
          end
        end
      end

      defmodule DiamondMid do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_diamond_mids)

          references do
            reference(:root, on_delete: :delete)
          end
        end

        attributes do
          integer_primary_key(:id)
          attribute(:label, :string, public?: true)
        end

        relationships do
          belongs_to(:root, DiamondRoot,
            attribute_type: :integer,
            allow_nil?: false,
            public?: true
          )
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:label, :root_id])
          end
        end
      end

      defmodule DiamondLeaf do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_diamond_leaves)

          references do
            reference(:mid, on_delete: :delete)
            reference(:root, on_delete: :restrict)
          end
        end

        attributes do
          integer_primary_key(:id)
          attribute(:label, :string, public?: true)
        end

        relationships do
          belongs_to(:mid, DiamondMid, attribute_type: :integer, allow_nil?: true, public?: true)

          belongs_to(:root, DiamondRoot,
            attribute_type: :integer,
            allow_nil?: false,
            public?: true
          )
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:label, :mid_id, :root_id])
          end
        end
      end

      defmodule TenantGlobalSlug do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_tenant_global_slugs)
        end

        multitenancy do
          strategy(:context)
        end

        attributes do
          integer_primary_key(:id)
          attribute(:slug, :string, allow_nil?: false, public?: true)
        end

        identities do
          identity(:unique_global_slug, [:slug], all_tenants?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:slug])
          end
        end
      end

      defmodule NestedParent do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_nested_parents)
        end

        attributes do
          integer_primary_key(:id)
          attribute(:name, :string, allow_nil?: false, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:name])
          end
        end
      end

      defmodule NestedOneConfig do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_nested_configs)

          nested_in(:reg_nested_parents,
            foreign_key: :parent_id,
            path: :config,
            cardinality: :one
          )

          references do
            reference(:parent, on_delete: :delete)
          end
        end

        attributes do
          integer_primary_key(:id)
          attribute(:theme, :string, allow_nil?: false, public?: true)
        end

        relationships do
          belongs_to(:parent, NestedParent,
            attribute_type: :integer,
            allow_nil?: false,
            public?: true
          )
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:theme, :parent_id])
          end

          update :update do
            primary?(true)
            accept([:theme])
          end
        end
      end

      defmodule ExplicitPkItem do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.FkRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(FkRegressionsStore)
          collection(:reg_explicit_pks)
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            generated?: false,
            allow_nil?: false,
            writable?: true,
            public?: true
          )

          attribute(:big_num, :integer, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :big_num])
          end
        end
      end

      defmodule FkRegressionsDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          resource(RegUser)
          resource(RegMessage)
          resource(SelfNode)
          resource(DiamondRoot)
          resource(DiamondMid)
          resource(DiamondLeaf)
          resource(TenantGlobalSlug)
          resource(NestedParent)
          resource(NestedOneConfig)
          resource(ExplicitPkItem)
        end
      end

      setup do
        {:ok, fk_pid} =
          Store.start_link(
            name: FkRegressionsStore,
            path: :memory,
            domains: [FkRegressionsDomain]
          )

        on_exit(fn ->
          if Process.alive?(fk_pid) do
            try do
              GenServer.stop(fk_pid, :normal, 1_000)
            catch
              :exit, _ -> :ok
            end
          end
        end)

        :ok
      end

      test "create and bulk_create enforce atomic validations; upsert honors omitted upsert_fields, upsert_condition, and post-atomic validation" do
        assert {:error, _} =
                 Ash.create(RegUser, %{email: "bad@gmail.com"}, domain: FkRegressionsDomain)

        bulk_res =
          Ash.bulk_create([%{email: "bad@gmail.com"}], RegUser, :create,
            domain: FkRegressionsDomain,
            return_errors?: true
          )

        assert bulk_res.status == :error

        u1 =
          Ash.create!(RegUser, %{email: "ok@corp.ca", version: 1, score: 5, bio: "v1"},
            domain: FkRegressionsDomain
          )

        # Upsert with upsert_fields omitted + atomic_update(:score, score + 10)
        u2 =
          Ash.create!(RegUser, %{email: "ok@corp.ca", version: 2, bio: "v2"},
            action: :upsert_version,
            domain: FkRegressionsDomain
          )

        assert u2.id == u1.id
        assert u2.bio == "v2"
        assert u2.score == 15
        assert u2.version == 2

        # version is now 2, so upsert_condition expr(version < 2) skips the upsert
        skipped =
          Ash.create!(
            RegUser,
            %{email: "ok@corp.ca", version: 3, bio: "ignored"},
            action: :upsert_version,
            return_skipped_upsert?: true,
            domain: FkRegressionsDomain
          )

        assert Ash.Resource.get_metadata(skipped, :upsert_skipped) == true
        assert Ash.get!(RegUser, u1.id, domain: FkRegressionsDomain).bio == "v2"

        # Atomic validation after atomic_update: first +100 -> 115 succeeds, second +100 -> 215 fails MaxScoreValidation (> 150)
        u3 =
          Ash.create!(RegUser, %{email: "ok@corp.ca", version: 2, bio: "v2"},
            action: :upsert_atomic_score,
            domain: FkRegressionsDomain
          )

        assert u3.score == 115

        assert {:error, _} =
                 Ash.create(RegUser, %{email: "ok@corp.ca", version: 2, bio: "v2"},
                   action: :upsert_atomic_score,
                   domain: FkRegressionsDomain
                 )

        assert {:error, _} =
                 Ash.update(u3, %{},
                   action: :add_score,
                   domain: FkRegressionsDomain
                 )

        assert Ash.get!(RegUser, u1.id, domain: FkRegressionsDomain).score == 115
      end

      test "multi-FK :nilify clears both sender_id and recipient_id on the same child in one destroy" do
        u = Ash.create!(RegUser, %{email: "self@corp.ca"}, domain: FkRegressionsDomain)

        msg =
          Ash.create!(RegMessage, %{body: "note to self", sender_id: u.id, recipient_id: u.id},
            domain: FkRegressionsDomain
          )

        :ok = Ash.destroy!(u, domain: FkRegressionsDomain)

        reloaded = Ash.get!(RegMessage, msg.id, domain: FkRegressionsDomain)
        assert reloaded.sender_id == nil
        assert reloaded.recipient_id == nil
      end

      test "self-referential bulk_destroy cleans parent_id nil index entries without leaving ghosts" do
        root = Ash.create!(SelfNode, %{name: "root"}, domain: FkRegressionsDomain)

        child =
          Ash.create!(SelfNode, %{name: "child", parent_id: root.id}, domain: FkRegressionsDomain)

        _leaf =
          Ash.create!(SelfNode, %{name: "leaf", parent_id: child.id}, domain: FkRegressionsDomain)

        %Ash.BulkResult{status: :success} =
          Ash.bulk_destroy!(SelfNode, :destroy, %{}, domain: FkRegressionsDomain)

        assert Ash.read!(SelfNode, domain: FkRegressionsDomain) == []

        assert Indexer.count_by_attribute(
                 Store.root(FkRegressionsStore),
                 SelfNode,
                 :parent_id,
                 nil
               ) == 0
      end

      test "diamond FK priority runs :delete before :restrict and still blocks when independent :restrict child survives" do
        r1 = Ash.create!(DiamondRoot, %{name: "r1"}, domain: FkRegressionsDomain)
        m1 = Ash.create!(DiamondMid, %{label: "m1", root_id: r1.id}, domain: FkRegressionsDomain)

        _l1 =
          Ash.create!(
            DiamondLeaf,
            %{label: "cascade-clears-restrict", mid_id: m1.id, root_id: r1.id},
            domain: FkRegressionsDomain
          )

        # m1 cascades delete to l1 before r1's :restrict check against l1 runs
        :ok = Ash.destroy!(r1, domain: FkRegressionsDomain)
        assert Ash.read!(DiamondLeaf, domain: FkRegressionsDomain) == []

        r2 = Ash.create!(DiamondRoot, %{name: "r2"}, domain: FkRegressionsDomain)

        _independent_guard =
          Ash.create!(DiamondLeaf, %{label: "blocks-delete", mid_id: nil, root_id: r2.id},
            domain: FkRegressionsDomain
          )

        assert {:error, _} = Ash.destroy(r2, domain: FkRegressionsDomain)
        assert Ash.get!(DiamondRoot, r2.id, domain: FkRegressionsDomain).name == "r2"
      end

      test "enforces all_tenants?: true across :context tenants, overwrites nested_in :one cleanly, and rejects missing explicit PK or >64-bit integer" do
        _t1 =
          Ash.create!(TenantGlobalSlug, %{slug: "shared"},
            tenant: "tenant_a",
            domain: FkRegressionsDomain
          )

        assert {:error, _} =
                 Ash.create(TenantGlobalSlug, %{slug: "shared"},
                   tenant: "tenant_b",
                   domain: FkRegressionsDomain
                 )

        parent = Ash.create!(NestedParent, %{name: "P1"}, domain: FkRegressionsDomain)

        cfg1 =
          Ash.create!(NestedOneConfig, %{theme: "light", parent_id: parent.id},
            domain: FkRegressionsDomain
          )

        assert Store.root(FkRegressionsStore)["reg_nested_parents"][Integer.to_string(parent.id)][
                 "config"
               ]["theme"] == "light"

        cfg2 =
          Ash.create!(NestedOneConfig, %{theme: "dark", parent_id: parent.id},
            domain: FkRegressionsDomain
          )

        assert cfg2.theme == "dark"

        assert Store.root(FkRegressionsStore)["reg_nested_parents"][Integer.to_string(parent.id)][
                 "config"
               ]["theme"] == "dark"

        updated_cfg = Ash.update!(cfg2, %{theme: "solarized"}, domain: FkRegressionsDomain)
        assert updated_cfg.theme == "solarized"
        assert cfg1.id != cfg2.id

        # Non-generated explicit PK rejects missing id instead of sequence allocation
        assert {:error, _} =
                 Ash.create(ExplicitPkItem, %{big_num: 1}, domain: FkRegressionsDomain)

        # >64-bit signed integer returns structured Ash.Error.Invalid instead of NIF crash
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.create(ExplicitPkItem, %{id: 1, big_num: Bitwise.bsl(1, 64)},
                   domain: FkRegressionsDomain
                 )
      end
    end

    describe "Coalesced Bulk Create Engine, nested_in :many, allow_existing_cursor?, and skip_search_index?" do
      defmodule BulkStore do
        use Xitdb.Ash.Store
      end

      defmodule BulkParent do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.BulkDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(BulkStore)
          collection(:bulk_parents)
          index([:sector])
          search_field(:name, boost: 2.0)
          search_field(:notes, boost: 1.0)
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            allow_nil?: false,
            generated?: true,
            writable?: true,
            public?: true
          )

          attribute(:name, :string, allow_nil?: false, public?: true)
          attribute(:slug, :string, allow_nil?: false, public?: true)
          attribute(:sector, :string, allow_nil?: false, public?: true)
          attribute(:notes, :string, public?: true)
        end

        identities do
          identity(:unique_slug, [:slug])
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :name, :slug, :sector, :notes])
          end
        end
      end

      defmodule BulkChild do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.BulkDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(BulkStore)
          collection(:bulk_children)
          nested_in(:bulk_parents, foreign_key: :parent_id, path: :children, cardinality: :many)
          index([:tag])
          search_field(:label, boost: 1.5)
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            allow_nil?: false,
            generated?: true,
            writable?: true,
            public?: true
          )

          attribute(:parent_id, :integer, allow_nil?: false, public?: true)
          attribute(:code, :string, allow_nil?: false, public?: true)
          attribute(:tag, :string, allow_nil?: false, public?: true)
          attribute(:label, :string, public?: true)
        end

        identities do
          identity(:unique_code, [:code])
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :parent_id, :code, :tag, :label])
          end
        end
      end

      defmodule BulkCompressedDoc do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.BulkDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(BulkStore)
          collection(:bulk_compressed_docs)
          compress([:body], mode: :value, codec: :zstd, min_bytes: 32, intern_above: 64)
          search_field(:title, boost: 1.0)
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            allow_nil?: false,
            generated?: true,
            writable?: true,
            public?: true
          )

          attribute(:title, :string, allow_nil?: false, public?: true)
          attribute(:body, :string, allow_nil?: false, public?: true)
          attribute(:meta, :map, default: %{}, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :title, :body, :meta])
          end
        end
      end

      defmodule BulkNestedOne do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.BulkDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(BulkStore)
          collection(:bulk_nested_ones)
          nested_in(:bulk_parents, foreign_key: :parent_id, path: :profile, cardinality: :one)
          search_field(:bio, boost: 1.0)
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            allow_nil?: false,
            generated?: true,
            writable?: true,
            public?: true
          )

          attribute(:parent_id, :integer, allow_nil?: false, public?: true)
          attribute(:bio, :string, allow_nil?: false, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :parent_id, :bio])
          end
        end
      end

      defmodule BulkRowGroupDoc do
        use Ash.Resource,
          domain: Xitdb.Ash.MutatorTest.BulkDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(BulkStore)
          collection(:bulk_row_group_docs)
          compress([:body], mode: :row_group, codec: :zstd, row_group_size: 4, min_bytes: 16)
          search_field(:title, boost: 1.0)
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            allow_nil?: false,
            generated?: true,
            writable?: true,
            public?: true
          )

          attribute(:title, :string, allow_nil?: false, public?: true)
          attribute(:body, :string, allow_nil?: false, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :title, :body])
          end
        end
      end

      defmodule BulkDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          resource(BulkParent)
          resource(BulkChild)
          resource(BulkCompressedDoc)
          resource(BulkNestedOne)
          resource(BulkRowGroupDoc)
        end
      end

      setup do
        {:ok, pid} =
          Store.start_link(
            name: BulkStore,
            path: :memory,
            domains: [BulkDomain]
          )

        on_exit(fn ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, 1_000)
            catch
              :exit, _ -> :ok
            end
          end
        end)

        :ok
      end

      test "handles mixed explicit/nil PK sequences, nested_in :many, sibling preservation, identities, and skip_search_index?" do
        # 1. Mixed nil and explicit integer IDs must never collide within batch or sequence floor
        parents_res =
          Ash.bulk_create!(
            [
              %{name: "Alpha Corp", slug: "alpha", sector: "tech", notes: "legacy notes"},
              %{id: 100, name: "Beta Fund", slug: "beta", sector: "finance"},
              %{name: "Gamma Group", slug: "gamma", sector: "tech", notes: "cloud"},
              %{id: 50, name: "Delta Partners", slug: "delta", sector: "finance"},
              %{name: "Epsilon Bio", slug: "epsilon", sector: "health"}
            ],
            BulkParent,
            :create,
            domain: BulkDomain,
            return_records?: true
          )

        parent_ids = Enum.map(parents_res.records, & &1.id)
        assert parent_ids == [101, 100, 102, 50, 103]
        assert Store.root(BulkStore)["meta"]["sequences"]["bulk_parents"] == 103

        # Duplicate unique identity inside a batch rejects cleanly
        dup_res =
          Ash.bulk_create(
            [
              %{name: "One", slug: "dup-slug", sector: "tech"},
              %{name: "Two", slug: "dup-slug", sector: "tech"}
            ],
            BulkParent,
            :create,
            domain: BulkDomain,
            return_errors?: true
          )

        assert dup_res.status == :error

        # Secondary index and BM25 work immediately after coalesced bulk_create
        require Ash.Query

        tech_parents =
          BulkParent
          |> Ash.Query.filter(sector == "tech")
          |> Ash.read!(domain: BulkDomain)
          |> Enum.map(& &1.slug)
          |> Enum.sort()

        assert tech_parents == ["alpha", "gamma"]
        assert Xitdb.Ash.Search.ids(BulkParent, "legacy") == [101]

        # 2. nested_in :many bulk create populates nested subtree, _parent locator, secondary, search
        children_res =
          Ash.bulk_create!(
            [
              %{parent_id: 101, code: "c1", tag: "core", label: "Primary Partner"},
              %{parent_id: 101, code: "c2", tag: "core", label: "Managing Partner"},
              %{parent_id: 100, code: "c3", tag: "ops", label: "Operations Lead"}
            ],
            BulkChild,
            :create,
            domain: BulkDomain,
            return_records?: true
          )

        assert length(children_res.records) == 3
        root = Store.root(BulkStore)
        assert root["bulk_parents"]["101"]["children"]["1"]["code"] == "c1"
        assert root["bulk_parents"]["101"]["children"]["2"]["code"] == "c2"
        assert root["bulk_parents"]["100"]["children"]["3"]["code"] == "c3"

        assert {:ok, c1_cur} = Xitdb.Ash.Indexer.fetch_cursor(root, BulkChild, 1)
        assert c1_cur["code"] == "c1"
        assert length(Xitdb.Ash.Indexer.all_cursors(root, BulkChild)) == 3
        assert 1 in Xitdb.Ash.Search.ids(BulkChild, "primary")

        core_children =
          BulkChild
          |> Ash.Query.filter(tag == "core")
          |> Ash.read!(domain: BulkDomain)
          |> Enum.map(& &1.code)
          |> Enum.sort()

        assert core_children == ["c1", "c2"]

        # Missing parent rejects cleanly
        missing_parent_res =
          Ash.bulk_create(
            [%{parent_id: 999_999, code: "orphan", tag: "ops"}],
            BulkChild,
            :create,
            domain: BulkDomain,
            return_errors?: true
          )

        assert missing_parent_res.status == :error

        # 3. allow_existing_cursor? preserves nested .children subtree, drops removed fields, updates BM25
        Ash.bulk_create!(
          [
            %{id: 101, name: "Alpha Renamed", slug: "alpha", sector: "tech", notes: nil}
          ],
          BulkParent,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{allow_existing_cursor?: true}},
          return_records?: false
        )

        root_after = Store.root(BulkStore)
        assert root_after["bulk_parents"]["101"]["name"] == "Alpha Renamed"
        assert is_nil(root_after["bulk_parents"]["101"]["notes"])
        assert root_after["bulk_parents"]["101"]["children"]["1"]["code"] == "c1"
        assert root_after["bulk_parents"]["101"]["children"]["2"]["code"] == "c2"
        assert Xitdb.Ash.Search.ids(BulkParent, "legacy") == []
        assert Xitdb.Ash.Search.ids(BulkParent, "renamed") == [101]

        # 4. skip_search_index?: true skips BM25 writes until Search.rebuild_index!
        Ash.bulk_create!(
          [%{id: 200, name: "Deferred Zeta", slug: "zeta", sector: "ai"}],
          BulkParent,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{skip_search_index?: true}},
          return_records?: false
        )

        assert Xitdb.Ash.Search.ids(BulkParent, "zeta") == []
        :ok = Xitdb.Ash.Search.rebuild_index!(BulkStore, BulkParent, parallel: false)
        assert Xitdb.Ash.Search.ids(BulkParent, "zeta") == [200]
      end

      test "coalesced bulk_create handles mode: :value compression with __blobs deduplication and Xitdb.Encoder structs in :map" do
        shared_body = String.duplicate("CAASA bulk compressed payload block.", 5)

        ru = %Xitdb.Ash.Types.RangedUnit{
          bound_kind: :closed_range,
          dimension: :currency,
          currency: :usd,
          min_val: Decimal.new("100"),
          max_val: Decimal.new("500")
        }

        meta = %{
          "date" => ~D[2026-11-19],
          "dec" => Decimal.new("199.95"),
          "ru" => ru
        }

        res =
          Ash.bulk_create!(
            [
              %{title: "First Doc", body: shared_body, meta: meta},
              %{title: "Second Doc", body: shared_body, meta: meta}
            ],
            BulkCompressedDoc,
            :create,
            domain: BulkDomain,
            return_records?: true
          )

        assert length(res.records) == 2

        root = Store.root(BulkStore)
        assert Enum.count(root["__blobs"]) == 1

        loaded =
          BulkCompressedDoc
          |> Ash.read!(domain: BulkDomain)
          |> Enum.sort_by(& &1.id)

        assert Enum.map(loaded, & &1.body) == [shared_body, shared_body]

        for doc <- loaded do
          assert doc.meta["date"] == {:tagged, "dt", "2026-11-19"}
          assert doc.meta["dec"] == {:tagged, "dc", "199.95"}

          assert {:ok, loaded_ru} =
                   Ash.Type.cast_stored(Xitdb.Ash.Types.RangedUnit, doc.meta["ru"], [])

          assert Xitdb.Ash.Types.RangedUnit.equal?(loaded_ru, ru)
        end
      end

      test "skip_search_index?: true is honored on nested_in :one (legacy) and :row_group (columnar) bulk_create" do
        parent =
          Ash.create!(
            BulkParent,
            %{id: 1, name: "Host Org", slug: "host-org", sector: "tech"},
            domain: BulkDomain
          )

        Ash.bulk_create!(
          [%{id: 10, parent_id: parent.id, bio: "Unique NestedBioToken"}],
          BulkNestedOne,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{skip_search_index?: true}},
          return_records?: false
        )

        Ash.bulk_create!(
          [
            %{
              id: 20,
              title: "Columnar DeferredAlpha",
              body: String.duplicate("Columnar body content ", 4)
            },
            %{
              id: 21,
              title: "Columnar DeferredBeta",
              body: String.duplicate("Columnar body content ", 4)
            }
          ],
          BulkRowGroupDoc,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{skip_search_index?: true}},
          return_records?: false
        )

        assert Search.ids(BulkNestedOne, "nestedbiotoken") == []
        assert Search.ids(BulkRowGroupDoc, "deferredalpha") == []

        :ok = Search.rebuild_index!(BulkStore, BulkNestedOne, parallel: false)
        :ok = Search.rebuild_index!(BulkStore, BulkRowGroupDoc, parallel: false)

        assert Search.ids(BulkNestedOne, "nestedbiotoken") == [10]
        assert Search.ids(BulkRowGroupDoc, "deferredalpha") == [20]
        assert Search.ids(BulkRowGroupDoc, "deferredbeta") == [21]
      end

      test "coalesced bulk_create with allow_existing_cursor?: true cleans up stale unique identity keys and secondary index buckets" do
        Ash.bulk_create!(
          [
            %{id: 10, name: "Ten", slug: "old-slug", sector: "legacy"},
            %{id: 11, name: "Eleven", slug: "keep-slug", sector: "shared"},
            %{id: 12, name: "Twelve", slug: "other-slug", sector: "shared"}
          ],
          BulkParent,
          :create,
          domain: BulkDomain
        )

        # Overwrite id 10 (releasing "old-slug" and leaving "legacy" empty), overwrite id 11
        # (removing it from "shared" while keeping id 12), and claim "old-slug" on id 13 in the same batch.
        Ash.bulk_create!(
          [
            %{id: 10, name: "Ten Updated", slug: "new-slug", sector: "modern"},
            %{id: 11, name: "Eleven Updated", slug: "keep-slug", sector: "modern"},
            %{id: 13, name: "Thirteen", slug: "old-slug", sector: "ai"}
          ],
          BulkParent,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{allow_existing_cursor?: true}}
        )

        require Ash.Query

        old_slug_ids =
          BulkParent
          |> Ash.Query.filter(slug == "old-slug")
          |> Ash.read!(domain: BulkDomain)
          |> Enum.map(& &1.id)

        assert old_slug_ids == [13]

        new_slug_ids =
          BulkParent
          |> Ash.Query.filter(slug == "new-slug")
          |> Ash.read!(domain: BulkDomain)
          |> Enum.map(& &1.id)

        assert new_slug_ids == [10]

        assert [] ==
                 BulkParent
                 |> Ash.Query.filter(sector == "legacy")
                 |> Ash.read!(domain: BulkDomain)

        root = Store.root(BulkStore)
        legacy_hex = Base.encode16(<<1>> <> "legacy", case: :lower)
        assert is_nil(root["idx"]["bulk_parents"]["attr_sector"][legacy_hex])

        shared_ids =
          BulkParent
          |> Ash.Query.filter(sector == "shared")
          |> Ash.read!(domain: BulkDomain)
          |> Enum.map(& &1.id)

        assert shared_ids == [12]

        modern_ids =
          BulkParent
          |> Ash.Query.filter(sector == "modern")
          |> Ash.read!(domain: BulkDomain)
          |> Enum.map(& &1.id)
          |> Enum.sort()

        assert modern_ids == [10, 11]
      end

      test "coalesced bulk_create with allow_existing_cursor?: true populates missing secondary indexes on pre-existing raw cursors" do
        {:ok, :ok} =
          Store.mutate(BulkStore, fn {db, _m} ->
            Xitdb.transact_ops_with_moment(db, [
              {:put, ["bulk_parents", "99"],
               %{"id" => 99, "name" => "Raw Org", "slug" => "raw-org", "sector" => "fintech"}}
            ])
            |> then(fn {:ok, next_db, next_m} -> {:ok, {next_db, next_m}, :ok} end)
          end)

        Ash.bulk_create!(
          [%{id: 99, name: "Raw Org", slug: "raw-org", sector: "fintech"}],
          BulkParent,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{allow_existing_cursor?: true}}
        )

        require Ash.Query

        assert [99] ==
                 BulkParent
                 |> Ash.Query.filter(sector == "fintech")
                 |> Ash.read!(domain: BulkDomain)
                 |> Enum.map(& &1.id)

        assert [99] ==
                 BulkParent
                 |> Ash.Query.filter(slug == "raw-org")
                 |> Ash.read!(domain: BulkDomain)
                 |> Enum.map(& &1.id)

        Ash.bulk_create!(
          [%{id: 99, name: "Raw Org", slug: "raw-org", sector: "clean"}],
          BulkParent,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{allow_existing_cursor?: true}}
        )

        assert [] ==
                 BulkParent
                 |> Ash.Query.filter(sector == "fintech")
                 |> Ash.read!(domain: BulkDomain)

        assert [99] ==
                 BulkParent
                 |> Ash.Query.filter(sector == "clean")
                 |> Ash.read!(domain: BulkDomain)
                 |> Enum.map(& &1.id)

        Ash.bulk_create!(
          [%{id: 99, name: "Raw Org", slug: "raw-org", sector: "clean"}],
          BulkParent,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{allow_existing_cursor?: true}}
        )

        assert [99] ==
                 BulkParent
                 |> Ash.Query.filter(sector == "clean")
                 |> Ash.read!(domain: BulkDomain)
                 |> Enum.map(& &1.id)
      end

      test "coalesced bulk_create with allow_existing_cursor?: true clears nil'd fields and reparents nested :many children cleanly" do
        Ash.bulk_create!(
          [
            %{id: 1, name: "Parent One", slug: "p1", sector: "tech"},
            %{id: 2, name: "Parent Two", slug: "p2", sector: "tech"}
          ],
          BulkParent,
          :create,
          domain: BulkDomain
        )

        Ash.bulk_create!(
          [%{id: 50, parent_id: 1, code: "c-old", tag: "t1", label: "initial"}],
          BulkChild,
          :create,
          domain: BulkDomain
        )

        # In-place overwrite under parent 1 with label cleared to nil, new code, and new tag
        Ash.bulk_create!(
          [%{id: 50, parent_id: 1, code: "c-mid", tag: "t2", label: nil}],
          BulkChild,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{allow_existing_cursor?: true}}
        )

        root_mid = Store.root(BulkStore)
        assert is_nil(root_mid["bulk_parents"]["1"]["children"]["50"]["label"])

        old_code_hex = Base.encode16("c-old", case: :lower)
        assert is_nil(root_mid["idx"]["bulk_children"]["id_unique_code"][old_code_hex])

        require Ash.Query

        assert [] ==
                 BulkChild
                 |> Ash.Query.filter(tag == "t1")
                 |> Ash.read!(domain: BulkDomain)

        # Reparent id 50 from parent 1 to parent 2
        Ash.bulk_create!(
          [%{id: 50, parent_id: 2, code: "c-new", tag: "t3", label: "moved"}],
          BulkChild,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{allow_existing_cursor?: true}}
        )

        root_after = Store.root(BulkStore)
        assert is_nil(root_after["bulk_parents"]["1"]["children"]["50"])
        assert root_after["bulk_parents"]["2"]["children"]["50"]["label"] == "moved"
        assert length(Xitdb.Ash.Indexer.all_cursors(root_after, BulkChild)) == 1

        assert [] ==
                 BulkChild
                 |> Ash.Query.filter(tag == "t2")
                 |> Ash.read!(domain: BulkDomain)
      end

      test "skip_search_index?: true is propagated to nested_in :one eviction in bulk_create" do
        parent =
          Ash.create!(
            BulkParent,
            %{id: 1, name: "Evict Host", slug: "evict-host", sector: "tech"},
            domain: BulkDomain
          )

        Ash.create!(
          BulkNestedOne,
          %{id: 10, parent_id: parent.id, bio: "OriginalAlpha"},
          domain: BulkDomain
        )

        assert Search.ids(BulkNestedOne, "originalalpha") == [10]

        Ash.bulk_create!(
          [
            %{id: 11, parent_id: parent.id, bio: "MiddleBeta"},
            %{id: 12, parent_id: parent.id, bio: "FinalGamma"}
          ],
          BulkNestedOne,
          :create,
          domain: BulkDomain,
          context: %{xitdb: %{skip_search_index?: true}},
          return_records?: false
        )

        # idx.search.bulk_nested_ones must remain untouched during skipped bulk create
        assert Search.ids(BulkNestedOne, "originalalpha") == [10]
        assert Search.ids(BulkNestedOne, "middlebeta") == []
        assert Search.ids(BulkNestedOne, "finalgamma") == []

        :ok = Search.rebuild_index!(BulkStore, BulkNestedOne, parallel: false)

        assert Search.ids(BulkNestedOne, "finalgamma") == [12]
        assert Search.ids(BulkNestedOne, "originalalpha") == []
        assert Search.ids(BulkNestedOne, "middlebeta") == []
      end

      test "coalesced eager bulk_create with allow_existing_cursor?: true and >= 500 parallel: :auto rows matches rebuild_index!" do
        Ash.bulk_create!(
          [
            %{id: 1, name: "Alpha Legacy", slug: "s1", sector: "tech"},
            %{id: 2, name: "Beta Shared", slug: "s2", sector: "tech"}
          ],
          BulkParent,
          :create,
          domain: BulkDomain,
          return_records?: false
        )

        # Overwrite id 1 (removing "legacy" and adding "rebranded") and id 2 (punctuation-only name clears doc)
        Ash.bulk_create!(
          [
            %{id: 1, name: "Alpha Rebranded", slug: "s1", sector: "tech"},
            %{id: 2, name: "---", slug: "s2", sector: "tech"}
          ],
          BulkParent,
          :create,
          domain: BulkDomain,
          return_records?: false,
          context: %{xitdb: %{allow_existing_cursor?: true}}
        )

        assert Search.ids(BulkParent, "legacy") == []
        assert Search.ids(BulkParent, "shared") == []
        assert Search.ids(BulkParent, "rebranded") == [1]

        root_mid = Store.root(BulkStore)
        assert root_mid["idx"]["search"]["bulk_parents"]["meta"]["doc_count"] == 1
        assert is_nil(root_mid["idx"]["search"]["bulk_parents"]["docs"]["2"])
        assert is_nil(root_mid["idx"]["search"]["bulk_parents"]["terms"]["legacy"])
        assert is_nil(root_mid["idx"]["search"]["bulk_parents"]["terms"]["shared"])

        # >= 500 rows exercises parallel: :auto inside Mutator coalesced bulk_create!
        large_inputs =
          for i <- 10..529 do
            %{
              id: i,
              name: "Enterprise #{i} ParallelToken#{rem(i, 17)}",
              slug: "ent-#{i}",
              sector: "sector_#{rem(i, 4)}"
            }
          end

        Ash.bulk_create!(large_inputs, BulkParent, :create,
          domain: BulkDomain,
          batch_size: 600,
          return_records?: false
        )

        root_after = Store.root(BulkStore)
        meta_eager = Xitdb.materialize(root_after["idx"]["search"]["bulk_parents"]["meta"])
        terms_eager = Xitdb.materialize(root_after["idx"]["search"]["bulk_parents"]["terms"])
        hits_eager = Search.query(BulkParent, "enterprise paralleltoken5", limit: 40)

        assert meta_eager["doc_count"] == 521

        :ok = Search.rebuild_index!(BulkStore, BulkParent, parallel: true)
        root_rebuilt = Store.root(BulkStore)

        assert Xitdb.materialize(root_rebuilt["idx"]["search"]["bulk_parents"]["meta"]) ==
                 meta_eager

        assert Xitdb.materialize(root_rebuilt["idx"]["search"]["bulk_parents"]["terms"]) ==
                 terms_eager

        assert Search.query(BulkParent, "enterprise paralleltoken5", limit: 40) == hits_eager
      end
    end
  end
end
