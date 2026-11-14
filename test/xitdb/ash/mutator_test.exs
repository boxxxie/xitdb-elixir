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

        # :nilify cleared FK and updated secondary index
        reloaded_nil = Ash.get!(CascadeNilifyChild, nil_child.id, domain: Domain)
        assert is_nil(reloaded_nil.parent_id)

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
  end
end
