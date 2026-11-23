if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.QueryTest do
    use ExUnit.Case, async: true
    use ExUnitProperties

    require Ash.Query

    alias Xitdb.Ash.{Indexer, Store, TestSandbox}

    # --------------------------------------------------------------------------
    # Test Stores, Domain, Calculation & Resources
    # --------------------------------------------------------------------------

    defmodule PrimaryStore do
      use Xitdb.Ash.Store
    end

    defmodule SecondaryStore do
      use Xitdb.Ash.Store
    end

    defmodule MemberBonusCalc do
      use Ash.Resource.Calculation

      @impl true
      def load(_query, _opts, _context), do: [:score, org: [:tier]]

      @impl true
      def calculate(records, _opts, _context) do
        Enum.map(records, fn record ->
          tier_bonus =
            case record.org do
              %{tier: :platinum} -> 50
              %{tier: :gold} -> 20
              _ -> 5
            end

          (record.score || 0) + tier_bonus
        end)
      end
    end

    defmodule Tag do
      use Ash.Resource,
        domain: Xitdb.Ash.QueryTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store PrimaryStore
        collection :q_tags
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:active, :boolean, default: true, public?: true)
      end

      actions do
        defaults([:read])
      end
    end

    defmodule OrgTag do
      use Ash.Resource,
        domain: Xitdb.Ash.QueryTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store PrimaryStore
        collection :q_org_tags
      end

      attributes do
        integer_primary_key(:id)
        attribute(:weight, :integer, default: 1, public?: true)
      end

      relationships do
        belongs_to :org, Xitdb.Ash.QueryTest.Org do
          attribute_type(:integer)
          allow_nil?(false)
          public?(true)
        end

        belongs_to :tag, Tag do
          attribute_type(:integer)
          allow_nil?(false)
          public?(true)
        end
      end

      actions do
        defaults([:read])
      end
    end

    defmodule ExternalAlert do
      use Ash.Resource,
        domain: Xitdb.Ash.QueryTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store SecondaryStore
        collection :q_external_alerts
        index([:org_id])
      end

      attributes do
        integer_primary_key(:id)
        attribute(:org_id, :integer, allow_nil?: false, public?: true)
        attribute(:severity, :atom, allow_nil?: false, public?: true)
        attribute(:message, :string, public?: true)
      end

      actions do
        defaults([:read])
      end
    end

    defmodule Org do
      use Ash.Resource,
        domain: Xitdb.Ash.QueryTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store PrimaryStore
        collection :q_orgs
        index([:tier])
        index([:tier, :score])
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:slug, :ci_string, allow_nil?: false, public?: true)
        attribute(:tier, :atom, default: :silver, public?: true)
        attribute(:score, :integer, default: 0, public?: true)
        attribute(:threshold, :integer, default: 50, public?: true)
        attribute(:always_tag, :string, always_select?: true, public?: true)
        attribute(:secret_note, :string, public?: true)
      end

      identities do
        identity(:unique_slug, [:slug])
      end

      relationships do
        has_many(:members, Xitdb.Ash.QueryTest.Member, destination_attribute: :org_id)

        has_many(:org_tags, OrgTag, destination_attribute: :org_id)

        many_to_many :tags, Tag do
          through(OrgTag)
          source_attribute_on_join_resource(:org_id)
          destination_attribute_on_join_resource(:tag_id)
        end

        has_many(:alerts, ExternalAlert, destination_attribute: :org_id)
      end

      aggregates do
        count(:members_count, :members)
        exists(:has_members, :members)

        first :top_member_name, :members, :name do
          sort(score: :desc)
        end

        list :member_names, :members, :name do
          sort(name: :asc)
        end

        sum(:total_member_score, :members, :score)
        min(:min_member_score, :members, :score)
        max(:max_member_score, :members, :score)
        avg(:avg_member_score, :members, :score)

        count(:tag_count, :tags)

        count :weighted_tag_count, [:org_tags, :tag] do
          join_filter([:org_tags], expr(weight >= 10))
        end

        count :qualified_members_count, :members do
          filter(expr(score >= parent(threshold)))
        end

        count :critical_external_alerts_count, ExternalAlert do
          filter(expr(org_id == parent(id) and severity == :critical))
        end
      end

      calculations do
        calculate(:has_critical_alert, :boolean, expr(exists(alerts, severity == :critical)))
      end

      actions do
        defaults([:read])
      end
    end

    defmodule Member do
      use Ash.Resource,
        domain: Xitdb.Ash.QueryTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store PrimaryStore
        collection :q_members
        index([:score])
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:score, :integer, default: 0, public?: true)
        attribute(:role, :atom, default: :analyst, public?: true)
      end

      relationships do
        belongs_to :org, Org do
          attribute_type(:integer)
          allow_nil?(false)
          public?(true)
        end
      end

      calculations do
        calculate(:bonus, :integer, MemberBonusCalc)

        calculate(
          :tier_score,
          :integer,
          expr(score + if(org.tier == :platinum, do: 50, else: 20))
        )
      end

      actions do
        defaults([:read])
      end
    end

    defmodule ContextTenantNote do
      use Ash.Resource,
        domain: Xitdb.Ash.QueryTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store PrimaryStore
        collection :q_tenant_notes
      end

      multitenancy do
        strategy(:context)
      end

      attributes do
        integer_primary_key(:id)
        attribute(:code, :string, allow_nil?: false, public?: true)
        attribute(:body, :string, public?: true)
      end

      identities do
        identity(:unique_code, [:code])
      end

      actions do
        defaults([:read])
      end
    end

    defmodule AttrTenantItem do
      use Ash.Resource,
        domain: Xitdb.Ash.QueryTest.Domain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store PrimaryStore
        collection :q_attr_items
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org_id)
        global?(true)
      end

      attributes do
        integer_primary_key(:id)
        attribute(:org_id, :integer, allow_nil?: false, public?: true)
        attribute(:code, :string, allow_nil?: false, public?: true)
        attribute(:label, :string, public?: true)
      end

      identities do
        identity(:unique_code, [:code])
      end

      actions do
        defaults([:read])
      end
    end

    defmodule Domain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(Tag)
        resource(OrgTag)
        resource(ExternalAlert)
        resource(Org)
        resource(Member)
        resource(ContextTenantNote)
        resource(AttrTenantItem)
      end
    end

    # --------------------------------------------------------------------------
    # Sandbox Boot & Seeding Helpers (pre-Mutator via Indexer.put_record)
    # --------------------------------------------------------------------------

    setup_all do
      TestSandbox.init()
      {:ok, p_pid} = Store.start_link(name: PrimaryStore, path: :memory, domains: [Domain])
      {:ok, s_pid} = Store.start_link(name: SecondaryStore, path: :memory, domains: [Domain])

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
      :ok = TestSandbox.checkout([PrimaryStore, SecondaryStore])
      :ok
    end

    defp seed!(store, resource, attrs, tenant \\ nil) do
      record = struct!(resource, attrs)

      {:ok, ^record} =
        Store.mutate(store, fn snapshot ->
          {:ok, next_snapshot} = Indexer.put_record(snapshot, resource, nil, record, tenant)
          {:ok, next_snapshot, record}
        end)

      record
    end

    defp seed_orgs! do
      o1 =
        seed!(PrimaryStore, Org,
          id: 1,
          name: "Alpha Capital",
          slug: Ash.CiString.new("alpha"),
          tier: :platinum,
          score: 95,
          threshold: 80,
          always_tag: "always-alpha",
          secret_note: "classified-alpha"
        )

      o2 =
        seed!(PrimaryStore, Org,
          id: 2,
          name: "Beta Partners",
          slug: Ash.CiString.new("beta"),
          tier: :gold,
          score: 85,
          threshold: 50,
          always_tag: "always-beta",
          secret_note: "classified-beta"
        )

      o3 =
        seed!(PrimaryStore, Org,
          id: 3,
          name: "Gamma Fund",
          slug: Ash.CiString.new("gamma"),
          tier: :gold,
          score: 70,
          threshold: 60,
          always_tag: "always-gamma",
          secret_note: "classified-gamma"
        )

      o4 =
        seed!(PrimaryStore, Org,
          id: 4,
          name: "Delta Holdings",
          slug: Ash.CiString.new("delta"),
          tier: :silver,
          score: 40,
          threshold: 30,
          always_tag: "always-delta",
          secret_note: "classified-delta"
        )

      [o1, o2, o3, o4]
    end

    # --------------------------------------------------------------------------
    # Stage 1 Narrowing Tests
    # --------------------------------------------------------------------------

    describe "Stage 1 narrowing" do
      test "narrows by point PK equality and PK IN list" do
        [o1, o2, o3, _o4] = seed_orgs!()

        assert [%Org{id: 2, name: "Beta Partners"}] =
                 Org |> Ash.Query.filter(id == 2) |> Ash.read!()

        ids =
          Org
          |> Ash.Query.filter(id in [1, 3, 999])
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!()
          |> Enum.map(& &1.id)

        assert ids == [o1.id, o3.id]
        assert o2.id not in ids
      end

      test "narrows via unique identity lookup including case-insensitive slug" do
        seed_orgs!()

        # Insert an unindexed ghost row in raw collection storage to prove Stage 1 uses identity index
        {:ok, :ok} =
          Store.mutate(PrimaryStore, fn {db, moment} ->
            ops =
              Xitdb.TxCompiler.compile_moment_map(%{
                "q_orgs" => %{
                  "999" => %{
                    "id" => 999,
                    "name" => "Ghost Org",
                    "slug" => "BETA",
                    "tier" => "gold",
                    "score" => 90,
                    "threshold" => 50
                  }
                }
              })

            {:ok, next_db} = Xitdb.transact_ops(db, ops, base_moment: moment)
            {:ok, {next_db, Xitdb.moment_count(next_db) - 1}, :ok}
          end)

        # Unique identity lookup finds only indexed PK 2, NOT raw ghost PK 999
        assert [%Org{id: 2, name: "Beta Partners"}] =
                 Org |> Ash.Query.filter(slug == "BETA") |> Ash.read!()
      end

      test "isolates unique identity lookup across :context and :attribute multitenancy" do
        seed!(
          PrimaryStore,
          ContextTenantNote,
          [id: 1, code: "shared-code", body: "Tenant One Note"],
          "tenant_one"
        )

        seed!(
          PrimaryStore,
          ContextTenantNote,
          [id: 2, code: "shared-code", body: "Tenant Two Note"],
          "tenant_two"
        )

        assert [%ContextTenantNote{id: 1, body: "Tenant One Note"}] =
                 ContextTenantNote
                 |> Ash.Query.set_tenant("tenant_one")
                 |> Ash.Query.filter(code == "shared-code")
                 |> Ash.read!()

        assert [%ContextTenantNote{id: 2, body: "Tenant Two Note"}] =
                 ContextTenantNote
                 |> Ash.Query.set_tenant("tenant_two")
                 |> Ash.Query.filter(code == "shared-code")
                 |> Ash.read!()

        seed!(
          PrimaryStore,
          AttrTenantItem,
          [id: 10, org_id: 100, code: "c1", label: "Org 100"],
          100
        )

        seed!(
          PrimaryStore,
          AttrTenantItem,
          [id: 20, org_id: 200, code: "c1", label: "Org 200"],
          200
        )

        assert [%AttrTenantItem{id: 10, org_id: 100, label: "Org 100"}] =
                 AttrTenantItem
                 |> Ash.Query.set_tenant(100)
                 |> Ash.Query.filter(code == "c1")
                 |> Ash.read!()

        assert [%AttrTenantItem{id: 20, org_id: 200, label: "Org 200"}] =
                 AttrTenantItem
                 |> Ash.Query.filter(org_id == 200 and code == "c1")
                 |> Ash.read!()
      end

      test "narrows via single and composite B+Tree equality + range scans and falls back cleanly" do
        seed_orgs!()

        # Plant an unindexed ghost with tier: :gold and score: 90 in raw collection to verify B+Tree path
        {:ok, :ok} =
          Store.mutate(PrimaryStore, fn {db, moment} ->
            ops =
              Xitdb.TxCompiler.compile_moment_map(%{
                "q_orgs" => %{
                  "888" => %{
                    "id" => 888,
                    "name" => "Unindexed Gold",
                    "slug" => "unindexed",
                    "tier" => "gold",
                    "score" => 90,
                    "threshold" => 50
                  }
                }
              })

            {:ok, next_db} = Xitdb.transact_ops(db, ops, base_moment: moment)
            {:ok, {next_db, Xitdb.moment_count(next_db) - 1}, :ok}
          end)

        # Single secondary index equality
        gold_ids =
          Org
          |> Ash.Query.filter(tier == :gold)
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!()
          |> Enum.map(& &1.id)

        assert gold_ids == [2, 3]

        # Composite index prefix equality + range bound (tier == :gold and score >= 80)
        high_gold_ids =
          Org
          |> Ash.Query.filter(tier == :gold and score >= 80)
          |> Ash.read!()
          |> Enum.map(& &1.id)

        assert high_gold_ids == [2]

        # IN list over indexed column
        tier_in_ids =
          Org
          |> Ash.Query.filter(tier in [:platinum, :silver])
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!()
          |> Enum.map(& &1.id)

        assert tier_in_ids == [1, 4]

        # Unindexed attribute falls back to all_cursors scan (sees PK 888 too)
        assert [%Org{id: 888}] =
                 Org
                 |> Ash.Query.filter(name == "Unindexed Gold")
                 |> Ash.read!()
      end
    end

    # --------------------------------------------------------------------------
    # Stage 2 / 3 / 5 / 6 Pipeline Tests
    # --------------------------------------------------------------------------

    describe "Stages 3, 5, and 6 (prefilter, distinct, sort, slice, select projection)" do
      test "supports distinct, distinct_sort, sort, offset, limit, and select projection" do
        seed_orgs!()

        # Select keeps PK and always_selected? attributes while marking others NotLoaded
        [alpha] =
          Org
          |> Ash.Query.filter(id == 1)
          |> Ash.Query.select([:name])
          |> Ash.read!()

        assert alpha.id == 1
        assert alpha.name == "Alpha Capital"
        assert alpha.always_tag == "always-alpha"
        assert %Ash.NotLoaded{type: :attribute, field: :secret_note} = alpha.secret_note
        assert %Ash.NotLoaded{type: :attribute, field: :tier} = alpha.tier

        # Distinct by tier ordered by distinct_sort score: :desc picks Beta (score 85) over Gamma (70),
        # then final sort orders by name: :asc, offset/limit slices deterministically
        distinct_orgs =
          Org
          |> Ash.Query.distinct([:tier])
          |> Ash.Query.distinct_sort(score: :desc)
          |> Ash.Query.sort(name: :asc)
          |> Ash.Query.offset(1)
          |> Ash.Query.limit(2)
          |> Ash.read!()

        # Tiers ordered desc by score: Alpha (platinum, 95), Beta (gold, 85), Delta (silver, 40)
        # Sorted by name asc: Alpha, Beta, Delta -> offset 1, limit 2 -> [Beta, Delta]
        assert Enum.map(distinct_orgs, & &1.name) == ["Beta Partners", "Delta Holdings"]
      end

      test "narrows Stage 2 hydration on uncompressed select queries while preserving filter, sort, distinct, calc, and exists deps" do
        [o1, o2, _o3, _o4] = seed_orgs!()
        seed!(PrimaryStore, Member, id: 1, org_id: o1.id, name: "Alice", score: 90, role: :lead)
        seed!(PrimaryStore, Member, id: 2, org_id: o2.id, name: "Bob", score: 40, role: :analyst)

        # 1. Filter on unselected attribute (:tier) + select([:name])
        gold_orgs =
          Org
          |> Ash.Query.filter(tier == :gold)
          |> Ash.Query.sort(name: :asc)
          |> Ash.Query.select([:name])
          |> Ash.read!()

        assert Enum.map(gold_orgs, & &1.name) == ["Beta Partners", "Gamma Fund"]

        for org <- gold_orgs do
          assert %Ash.NotLoaded{type: :attribute, field: :tier} = org.tier
          assert %Ash.NotLoaded{type: :attribute, field: :score} = org.score
          assert %Ash.NotLoaded{type: :attribute, field: :secret_note} = org.secret_note
          assert is_binary(org.always_tag)
        end

        # 2. Distinct + distinct_sort on unselected attributes (:tier, :score) + select([:name])
        distinct_only =
          Org
          |> Ash.Query.distinct([:tier])
          |> Ash.Query.distinct_sort(score: :desc)
          |> Ash.Query.select([:name])
          |> Ash.read!()

        assert Enum.map(distinct_only, & &1.name) |> Enum.sort() == [
                 "Alpha Capital",
                 "Beta Partners",
                 "Delta Holdings"
               ]

        for org <- distinct_only do
          assert %Ash.NotLoaded{type: :attribute, field: :tier} = org.tier
          assert %Ash.NotLoaded{type: :attribute, field: :score} = org.score
          assert %Ash.NotLoaded{type: :attribute, field: :secret_note} = org.secret_note
        end

        # Sort on :score + select([:name]) (Ash retains :score for keysets, masks :tier/:secret_note)
        sorted_orgs =
          Org
          |> Ash.Query.sort(score: :desc)
          |> Ash.Query.select([:name])
          |> Ash.read!()

        assert Enum.map(sorted_orgs, & &1.name) == [
                 "Alpha Capital",
                 "Beta Partners",
                 "Gamma Fund",
                 "Delta Holdings"
               ]

        for org <- sorted_orgs do
          assert %Ash.NotLoaded{type: :attribute, field: :tier} = org.tier
          assert %Ash.NotLoaded{type: :attribute, field: :secret_note} = org.secret_note
        end

        # 3. Expression calculation referencing unselected attribute (:score) + related (:org.tier)
        [alice, bob] =
          Member
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.select([:name])
          |> Ash.Query.load(:tier_score)
          |> Ash.read!()

        assert alice.tier_score == 140
        assert bob.tier_score == 60
        assert %Ash.NotLoaded{type: :attribute, field: :score} = alice.score
        assert %Ash.NotLoaded{type: :attribute, field: :role} = alice.role

        # 4. exists/2 with parent(threshold) where :threshold is unselected
        qualified_orgs =
          Org
          |> Ash.Query.filter(exists(members, score >= parent(threshold)))
          |> Ash.Query.select([:name])
          |> Ash.read!()

        assert Enum.map(qualified_orgs, & &1.name) == ["Alpha Capital"]
        assert %Ash.NotLoaded{type: :attribute, field: :threshold} = hd(qualified_orgs).threshold
      end
    end

    # --------------------------------------------------------------------------
    # Stage 4 Aggregates & Query-Level execute_aggregates/4
    # --------------------------------------------------------------------------

    describe "Stage 4 aggregates and execute_aggregates/4" do
      test "computes batched related aggregates, many_to_many join_filters, parent/1, and unrelated cross-store aggregates" do
        [o1, o2, _o3, _o4] = seed_orgs!()

        # Members
        seed!(PrimaryStore, Member, id: 1, org_id: o1.id, name: "Alice", score: 90, role: :lead)
        seed!(PrimaryStore, Member, id: 2, org_id: o1.id, name: "Bob", score: 70, role: :analyst)
        seed!(PrimaryStore, Member, id: 3, org_id: o2.id, name: "Cara", score: 60, role: :lead)

        # Tags & OrgTags (for many_to_many + join_filters)
        t1 = seed!(PrimaryStore, Tag, id: 1, name: "ESG")
        t2 = seed!(PrimaryStore, Tag, id: 2, name: "Credit")
        seed!(PrimaryStore, OrgTag, id: 1, org_id: o1.id, tag_id: t1.id, weight: 15)
        seed!(PrimaryStore, OrgTag, id: 2, org_id: o1.id, tag_id: t2.id, weight: 3)
        seed!(PrimaryStore, OrgTag, id: 3, org_id: o2.id, tag_id: t1.id, weight: 20)

        # Cross-store ExternalAlerts in SecondaryStore
        seed!(SecondaryStore, ExternalAlert,
          id: 1,
          org_id: o1.id,
          severity: :critical,
          message: "c1"
        )

        seed!(SecondaryStore, ExternalAlert, id: 2, org_id: o1.id, severity: :info, message: "i1")
        seed!(SecondaryStore, ExternalAlert, id: 3, org_id: o2.id, severity: :info, message: "i2")

        [loaded1, loaded2, loaded3] =
          Org
          |> Ash.Query.filter(id in [1, 2, 3])
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.load([
            :members_count,
            :has_members,
            :top_member_name,
            :member_names,
            :total_member_score,
            :min_member_score,
            :max_member_score,
            :avg_member_score,
            :tag_count,
            :weighted_tag_count,
            :qualified_members_count,
            :critical_external_alerts_count
          ])
          |> Ash.read!()

        # Org 1 (threshold 80 -> only Alice 90 qualifies; weighted tags >= 10 -> 1; critical alert -> 1)
        assert loaded1.members_count == 2
        assert loaded1.has_members == true
        assert loaded1.top_member_name == "Alice"
        assert loaded1.member_names == ["Alice", "Bob"]
        assert loaded1.total_member_score == 160
        assert loaded1.min_member_score == 70
        assert loaded1.max_member_score == 90
        assert loaded1.avg_member_score == 80.0
        assert loaded1.tag_count == 2
        assert loaded1.weighted_tag_count == 1
        assert loaded1.qualified_members_count == 1
        assert loaded1.critical_external_alerts_count == 1

        # Org 2 (threshold 50 -> Cara 60 qualifies; weighted tags >= 10 -> 1; critical alert -> 0)
        assert loaded2.members_count == 1
        assert loaded2.has_members == true
        assert loaded2.top_member_name == "Cara"
        assert loaded2.member_names == ["Cara"]
        assert loaded2.total_member_score == 60
        assert loaded2.tag_count == 1
        assert loaded2.weighted_tag_count == 1
        assert loaded2.qualified_members_count == 1
        assert loaded2.critical_external_alerts_count == 0

        # Org 3 (zero members/tags/alerts)
        assert loaded3.members_count == 0
        assert loaded3.has_members == false
        assert loaded3.top_member_name == nil
        assert loaded3.member_names == []
        assert loaded3.qualified_members_count == 0
        assert loaded3.critical_external_alerts_count == 0

        # Query-level execute_aggregates/4 via Ash.aggregate!
        aggs =
          Org
          |> Ash.Query.filter(tier == :gold)
          |> Ash.aggregate!([
            {:count, :count},
            {:sum_score, :sum, field: :score},
            {:min_score, :min, field: :score},
            {:max_score, :max, field: :score},
            {:avg_score, :avg, field: :score},
            {:any_gold, :exists},
            {:first_name, :first, field: :name, query: Ash.Query.sort(Org, score: :desc)},
            {:all_names, :list, field: :name, query: Ash.Query.sort(Org, name: :asc)}
          ])

        assert aggs.count == 2
        assert aggs.sum_score == 155
        assert aggs.min_score == 70
        assert aggs.max_score == 85
        assert aggs.avg_score == 77.5
        assert aggs.any_gold == true
        assert aggs.first_name == "Beta Partners"
        assert aggs.all_names == ["Beta Partners", "Gamma Fund"]
      end
    end

    # --------------------------------------------------------------------------
    # Stage 4 Calculations (Cross-Store exists/2 & Module Calculations)
    # --------------------------------------------------------------------------

    describe "Stage 4 calculations" do
      test "evaluates relational exists/2 across stores via hydrated fallback and module calculate/3 + sort" do
        [o1, o2, _o3, _o4] = seed_orgs!()

        seed!(PrimaryStore, Member, id: 1, org_id: o1.id, name: "Alice", score: 90, role: :lead)
        seed!(PrimaryStore, Member, id: 2, org_id: o2.id, name: "Cara", score: 60, role: :analyst)

        seed!(SecondaryStore, ExternalAlert,
          id: 1,
          org_id: o1.id,
          severity: :critical,
          message: "breach"
        )

        seed!(SecondaryStore, ExternalAlert, id: 2, org_id: o2.id, severity: :info, message: "ok")

        # Relational expression calculation exists(alerts, ...) across PrimaryStore -> SecondaryStore
        critical_orgs =
          Org
          |> Ash.Query.filter(has_critical_alert == true)
          |> Ash.Query.load(:has_critical_alert)
          |> Ash.read!()

        assert [%Org{id: 1, has_critical_alert: true}] = critical_orgs

        [o1_loaded, o2_loaded] =
          Org
          |> Ash.Query.filter(id in [1, 2])
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.load(:has_critical_alert)
          |> Ash.read!()

        assert o1_loaded.has_critical_alert == true
        assert o2_loaded.has_critical_alert == false

        # Module calculation MemberBonusCalc (requires load/3 + calculate/3) via Ash.Query.load
        # and expression calculation sorting via DataLayer + Stage 5 runtime_sort
        members_loaded =
          Member
          |> Ash.Query.load(:bonus)
          |> Ash.Query.sort(tier_score: :desc)
          |> Ash.read!()

        # Alice: 90 + 50 (platinum) = 140; Cara: 60 + 20 (gold) = 80
        assert Enum.map(members_loaded, &{&1.name, &1.bonus}) == [{"Alice", 140}, {"Cara", 80}]

        # Directly exercise Xitdb.Ash.Query module Calculation path (load/3 + calculate/3 + sort)
        calc = %Ash.Query.Calculation{
          name: :bonus,
          module: MemberBonusCalc,
          opts: [],
          load: :bonus,
          type: :integer,
          constraints: [],
          context: %{}
        }

        {:ok, q1} =
          Member
          |> Xitdb.Ash.Query.new(Domain)
          |> Xitdb.Ash.Query.add_calculation(calc, nil, Member)

        {:ok, q2} = Xitdb.Ash.Query.sort(q1, [bonus: :desc], Member)
        {:ok, q_results} = Xitdb.Ash.Query.execute(Store.current_db(PrimaryStore), q2, Member)
        assert Enum.map(q_results, &{&1.name, &1.bonus}) == [{"Alice", 140}, {"Cara", 80}]
      end
    end

    describe "Stage 3 partial prefilter and post-slice projection enrichment" do
      defmodule TrackingCalc do
        use Ash.Resource.Calculation

        @impl true
        def calculate(records, _opts, context) do
          if pid = context.source_context[:tracking_pid] do
            send(pid, {:tracking_calc_batch, length(records), Enum.map(records, & &1.name)})
          end

          Enum.map(records, fn r -> String.upcase(r.name) end)
        end
      end

      defmodule SlicedDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          allow_unregistered?(true)
        end
      end

      defmodule SlicedItem do
        use Ash.Resource,
          domain: SlicedDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(PrimaryStore)
          collection(:query_sliced_items)
        end

        attributes do
          attribute(:id, :integer,
            primary_key?: true,
            allow_nil?: false,
            writable?: true,
            public?: true
          )

          attribute(:name, :string, allow_nil?: false, public?: true)
          attribute(:active, :boolean, default: true, allow_nil?: false, public?: true)
          attribute(:score, :integer, default: 0, allow_nil?: false, public?: true)
        end

        calculations do
          calculate(:doubled_score, :integer, expr(score * 2))
          calculate(:upper_name, :string, {TrackingCalc, []})
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :name, :active, :score])
          end
        end
      end

      test "splits pure-attribute AND conjuncts before Stage 4 and evaluates projection-only calcs after Stage 5 limit" do
        for {id, name, active, score} <- [
              {1, "Alpha", true, 10},
              {2, "Bravo", true, 30},
              {3, "Charlie", false, 50},
              {4, "Delta", true, 20}
            ] do
          Ash.create!(SlicedItem, %{id: id, name: name, active: active, score: score},
            domain: SlicedDomain
          )
        end

        require Ash.Query

        results =
          SlicedItem
          |> Ash.Query.set_context(%{tracking_pid: self()})
          |> Ash.Query.filter(active == true and doubled_score >= 40)
          |> Ash.Query.sort(score: :desc)
          |> Ash.Query.limit(1)
          |> Ash.Query.load(:upper_name)
          |> Ash.read!(domain: SlicedDomain)

        assert [%{id: 2, name: "Bravo", upper_name: "BRAVO"}] = results

        # TrackingCalc was only invoked on the 1 post-limit record, NOT on Delta or Charlie
        assert_received {:tracking_calc_batch, 1, ["Bravo"]}
      end
    end

    describe "Query engine edge-case regressions and indexed-vs-unindexed oracle" do
      defmodule QueryRegressionsDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          allow_unregistered?(true)
        end
      end

      defmodule CiJoinChild do
        use Ash.Resource,
          domain: QueryRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(PrimaryStore)
          collection(:q_ci_join_children)
        end

        attributes do
          integer_primary_key(:id, writable?: true)
          attribute(:parent_slug, :string, allow_nil?: false, public?: true)
          attribute(:label, :string, allow_nil?: false, public?: true)
          attribute(:priority, :integer, default: 0, allow_nil?: false, public?: true)
          attribute(:min_score, :integer, default: 0, allow_nil?: false, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :parent_slug, :label, :priority, :min_score])
          end

          update :update do
            primary?(true)
            accept([:label, :priority, :min_score])
          end
        end
      end

      defmodule CiJoinParent do
        use Ash.Resource,
          domain: QueryRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(PrimaryStore)
          collection(:q_ci_join_parents)
          index([:score])
        end

        attributes do
          integer_primary_key(:id, writable?: true)
          attribute(:slug, :ci_string, allow_nil?: false, public?: true)
          attribute(:score, :integer, default: 0, allow_nil?: false, public?: true)
        end

        relationships do
          has_many :children, CiJoinChild do
            source_attribute(:slug)
            destination_attribute(:parent_slug)
            validate_destination_attribute?(false)
            public?(true)
          end
        end

        aggregates do
          count(:child_count, :children)

          first :top_child_label, :children, :label do
            sort(priority: :desc)
          end

          count :eligible_child_count, :children do
            filter(expr(min_score <= parent(score)))
          end
        end

        calculations do
          calculate(:has_v1_child, :boolean, expr(exists(children, label == "v1")))
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :slug, :score])
          end
        end
      end

      defmodule IndexedOracleItem do
        use Ash.Resource,
          domain: QueryRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(PrimaryStore)
          collection(:q_oracle_indexed)
          index([:tag])
          index([:score])
          index([:tag, :score])
          index([:name])
        end

        attributes do
          integer_primary_key(:id, writable?: true)
          attribute(:tag, :string, public?: true)
          attribute(:score, :integer, public?: true)
          attribute(:name, :string, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :tag, :score, :name])
          end
        end
      end

      defmodule UnindexedOracleItem do
        use Ash.Resource,
          domain: QueryRegressionsDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(PrimaryStore)
          collection(:q_oracle_unindexed)
        end

        attributes do
          integer_primary_key(:id, writable?: true)
          attribute(:tag, :string, public?: true)
          attribute(:score, :integer, public?: true)
          attribute(:name, :string, public?: true)
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept([:id, :tag, :score, :name])
          end
        end
      end

      test "handles :ci_string <-> :string joins, rel.sort/parent filter aggregates, select + sum, agg sort + limit, and cross-type numeric filters" do
        p1 =
          Ash.create!(CiJoinParent, %{id: 1, slug: "Polar.CA", score: 10},
            domain: QueryRegressionsDomain
          )

        p2 =
          Ash.create!(CiJoinParent, %{id: 2, slug: "Nordic.NO", score: 25},
            domain: QueryRegressionsDomain
          )

        c1 =
          Ash.create!(
            CiJoinChild,
            %{id: 101, parent_slug: "polar.ca", label: "v1", priority: 5, min_score: 5},
            domain: QueryRegressionsDomain
          )

        _c2 =
          Ash.create!(
            CiJoinChild,
            %{id: 102, parent_slug: "POLAR.ca", label: "top-polar", priority: 20, min_score: 50},
            domain: QueryRegressionsDomain
          )

        _c3 =
          Ash.create!(
            CiJoinChild,
            %{id: 103, parent_slug: "nordic.no", label: "solo", priority: 1, min_score: 10},
            domain: QueryRegressionsDomain
          )

        loaded =
          CiJoinParent
          |> Ash.Query.load([:child_count, :top_child_label, :eligible_child_count])
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!(domain: QueryRegressionsDomain)

        assert Enum.map(
                 loaded,
                 &{&1.id, &1.child_count, &1.top_child_label, &1.eligible_child_count}
               ) ==
                 [
                   {1, 2, "top-polar", 1},
                   {2, 1, "solo", 1}
                 ]

        # Sort referencing aggregate + limit(1)
        assert [%{id: 1, child_count: 2}] =
                 CiJoinParent
                 |> Ash.Query.load(:child_count)
                 |> Ash.Query.sort(child_count: :desc)
                 |> Ash.Query.limit(1)
                 |> Ash.read!(domain: QueryRegressionsDomain)

        # Cross-type float literal vs integer attribute filter
        assert [%{id: 2}] =
                 CiJoinParent
                 |> Ash.Query.filter(score > 10.5)
                 |> Ash.read!(domain: QueryRegressionsDomain)

        assert [%{id: 1}] =
                 CiJoinParent
                 |> Ash.Query.filter(score < 10.5)
                 |> Ash.read!(domain: QueryRegressionsDomain)

        assert [] ==
                 CiJoinParent
                 |> Ash.Query.filter(score == 10.5)
                 |> Ash.read!(domain: QueryRegressionsDomain)

        assert [%{id: 1}] =
                 CiJoinParent
                 |> Ash.Query.filter(score == 10.0)
                 |> Ash.read!(domain: QueryRegressionsDomain)

        # Ash.Query.select([:id]) + Ash.sum!(query, :score)
        sum_q = Ash.Query.select(CiJoinParent, [:id])
        assert Ash.sum!(sum_q, :score, domain: QueryRegressionsDomain) == 35

        # Historical xitdb_moment in exists(...) filter and Ash.calculate!/3
        m1 = Store.root(PrimaryStore).moment
        _c1_updated = Ash.update!(c1, %{label: "v2"}, domain: QueryRegressionsDomain)

        assert [] ==
                 CiJoinParent
                 |> Ash.Query.filter(exists(children, label == "v1"))
                 |> Ash.read!(domain: QueryRegressionsDomain)

        assert [%{id: 1}] =
                 CiJoinParent
                 |> Ash.Query.set_context(%{xitdb_moment: m1})
                 |> Ash.Query.filter(exists(children, label == "v1"))
                 |> Ash.read!(domain: QueryRegressionsDomain)

        assert Ash.calculate!(p1, :has_v1_child,
                 domain: QueryRegressionsDomain,
                 context: %{xitdb_moment: m1}
               ) == true

        assert Ash.calculate!(p1, :has_v1_child, domain: QueryRegressionsDomain) == false

        assert Ash.calculate!(p2, :has_v1_child,
                 context: %{xitdb_moment: m1},
                 domain: QueryRegressionsDomain
               ) == false
      end

      test "scopes unrelated exists(ContextTenantNote, ...) to the active query tenant" do
        seed!(PrimaryStore, ContextTenantNote, [id: 1, code: "target", body: "T1"], "tenant_a")
        seed!(PrimaryStore, ContextTenantNote, [id: 2, code: "other", body: "T2"], "tenant_b")

        seed!(PrimaryStore, ContextTenantNote, [id: 10, code: "probe", body: "P1"], "tenant_a")
        seed!(PrimaryStore, ContextTenantNote, [id: 20, code: "probe", body: "P2"], "tenant_b")

        assert [%{id: 10}] =
                 ContextTenantNote
                 |> Ash.Query.set_tenant("tenant_a")
                 |> Ash.Query.filter(
                   code == "probe" and exists(ContextTenantNote, code == "target")
                 )
                 |> Ash.read!(domain: Domain)

        assert [] ==
                 ContextTenantNote
                 |> Ash.Query.set_tenant("tenant_b")
                 |> Ash.Query.filter(
                   code == "probe" and exists(ContextTenantNote, code == "target")
                 )
                 |> Ash.read!(domain: Domain)
      end

      property "indexed queries return identical IDs to unindexed full scans across filters, sorts, limits, and offsets" do
        row_gen =
          uniq_list_of(integer(1..50), min_length: 1, max_length: 8)
          |> bind(fn ids ->
            tuple_gens =
              Enum.map(ids, fn id ->
                gen all(
                      tag <- member_of(["alpha", "beta", "gamma", nil]),
                      score <- one_of([constant(nil), integer(-20..20)]),
                      name <- one_of([constant(nil), member_of(["a", "b", "c", "d"])])
                    ) do
                  %{id: id, tag: tag, score: score, name: name}
                end
              end)

            fixed_list(tuple_gens)
          end)

        op_gen =
          one_of([
            tuple({constant(:tag_eq), member_of(["alpha", "beta", "missing"])}),
            tuple(
              {constant(:tag_in),
               list_of(member_of(["alpha", "beta", "gamma"]), min_length: 1, max_length: 2)}
            ),
            tuple({constant(:tag_is_nil), boolean()}),
            tuple(
              {constant(:score_cmp), member_of([:lt, :lte, :gt, :gte, :eq]), integer(-20..20)}
            ),
            tuple({constant(:score_is_nil), boolean()}),
            tuple({constant(:combo), member_of(["alpha", "beta"]), integer(-10..10)})
          ])

        check all(
                rows <- row_gen,
                filter_spec <- op_gen,
                sort_dir <- member_of([:asc, :desc]),
                offset <- integer(0..3),
                limit <- integer(1..5),
                max_runs: 25
              ) do
          Ash.bulk_destroy!(IndexedOracleItem, :destroy, %{}, domain: QueryRegressionsDomain)
          Ash.bulk_destroy!(UnindexedOracleItem, :destroy, %{}, domain: QueryRegressionsDomain)

          for row <- rows do
            Ash.create!(IndexedOracleItem, row, domain: QueryRegressionsDomain)
            Ash.create!(UnindexedOracleItem, row, domain: QueryRegressionsDomain)
          end

          apply_oracle_query = fn resource ->
            q =
              case filter_spec do
                {:tag_eq, v} ->
                  Ash.Query.filter(resource, tag == ^v)

                {:tag_in, vs} ->
                  Ash.Query.filter(resource, tag in ^vs)

                {:tag_is_nil, true} ->
                  Ash.Query.filter(resource, is_nil(tag))

                {:tag_is_nil, false} ->
                  Ash.Query.filter(resource, not is_nil(tag))

                {:score_cmp, :lt, v} ->
                  Ash.Query.filter(resource, score < ^v)

                {:score_cmp, :lte, v} ->
                  Ash.Query.filter(resource, score <= ^v)

                {:score_cmp, :gt, v} ->
                  Ash.Query.filter(resource, score > ^v)

                {:score_cmp, :gte, v} ->
                  Ash.Query.filter(resource, score >= ^v)

                {:score_cmp, :eq, v} ->
                  Ash.Query.filter(resource, score == ^v)

                {:score_is_nil, true} ->
                  Ash.Query.filter(resource, is_nil(score))

                {:score_is_nil, false} ->
                  Ash.Query.filter(resource, not is_nil(score))

                {:combo, t, s} ->
                  Ash.Query.filter(resource, tag == ^t and score >= ^s)
              end

            q
            |> Ash.Query.sort([{:score, sort_dir}, {:id, :asc}])
            |> Ash.Query.offset(offset)
            |> Ash.Query.limit(limit)
            |> Ash.read!(domain: QueryRegressionsDomain)
            |> Enum.map(& &1.id)
          end

          assert apply_oracle_query.(IndexedOracleItem) ==
                   apply_oracle_query.(UnindexedOracleItem)
        end
      end
    end

    describe "UnsignedInteger and custom xitdb_index_key/2 Ash.Type B+Tree range queries" do
      defmodule CustomCentsType do
        use Ash.Type

        @impl true
        def storage_type(_), do: :binary

        @impl true
        def matches_type?(v, _), do: is_integer(v)

        @impl true
        def cast_input(nil, _), do: {:ok, nil}
        def cast_input(v, _) when is_integer(v), do: {:ok, v}
        def cast_input(_, _), do: :error

        @impl true
        def cast_stored(nil, _), do: {:ok, nil}
        def cast_stored({:tagged, "ct", <<v::signed-big-64>>}, _), do: {:ok, v}
        def cast_stored(v, _) when is_integer(v), do: {:ok, v}
        def cast_stored(_, _), do: :error

        @impl true
        def dump_to_native(nil, _), do: {:ok, nil}

        def dump_to_native(v, _) when is_integer(v),
          do: {:ok, {:tagged, "ct", <<v::signed-big-64>>}}

        def dump_to_native(_, _), do: :error

        def xitdb_index_key(v, _constraints) when is_integer(v),
          do: Xitdb.Key.encode_i64_be(v)

        def xitdb_fixed_width?(_constraints), do: true
      end

      defmodule UnsignedDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          allow_unregistered?(true)
        end
      end

      defmodule RangeHookItem do
        use Ash.Resource,
          domain: UnsignedDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(PrimaryStore)
          collection(:query_range_hook_items)
          index([:big_uint])
          index([:cents])
        end

        attributes do
          integer_primary_key(:id)
          attribute(:big_uint, Xitdb.Ash.Types.UnsignedInteger, public?: true)
          attribute(:cents, CustomCentsType, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end

      @max_i64 9_223_372_036_854_775_807
      @max_u64 18_446_744_073_709_551_615

      test "supports <, <=, ==, >=, > range scans on UnsignedInteger (> max(i64)) and custom xitdb_index_key/2 types" do
        values = [
          {10, -500},
          {@max_i64, -1},
          {@max_i64 + 1, 0},
          {@max_u64 - 10, 250},
          {@max_u64, 1000}
        ]

        for {u, c} <- values do
          Ash.create!(RangeHookItem, %{big_uint: u, cents: c}, domain: UnsignedDomain)
        end

        above_i64 =
          RangeHookItem
          |> Ash.Query.filter(big_uint > ^@max_i64)
          |> Ash.Query.sort(big_uint: :asc)
          |> Ash.read!(domain: UnsignedDomain)

        assert Enum.map(above_i64, & &1.big_uint) == [@max_i64 + 1, @max_u64 - 10, @max_u64]

        window_u64 =
          RangeHookItem
          |> Ash.Query.filter(big_uint >= ^@max_i64 and big_uint < ^@max_u64)
          |> Ash.Query.sort(big_uint: :asc)
          |> Ash.read!(domain: UnsignedDomain)

        assert Enum.map(window_u64, & &1.big_uint) == [@max_i64, @max_i64 + 1, @max_u64 - 10]

        assert [%{big_uint: @max_u64}] =
                 RangeHookItem
                 |> Ash.Query.filter(big_uint == ^@max_u64)
                 |> Ash.read!(domain: UnsignedDomain)

        cents_window =
          RangeHookItem
          |> Ash.Query.filter(cents > -500 and cents <= 250)
          |> Ash.Query.sort(cents: :asc)
          |> Ash.read!(domain: UnsignedDomain)

        assert Enum.map(cents_window, & &1.cents) == [-1, 0, 250]
      end
    end

    describe "Chained expression calculations with read preparations (Ash 3.37.5+ recursion regression)" do
      defmodule PrepDomain do
        use Ash.Domain, validate_config_inclusion?: false

        resources do
          allow_unregistered?(true)
        end
      end

      defmodule PrepOrg do
        use Ash.Resource,
          domain: PrepDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(PrimaryStore)
          collection(:query_prep_orgs)
        end

        attributes do
          integer_primary_key(:id)
          attribute(:name, :string, allow_nil?: false, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end

      defmodule PrepAlert do
        use Ash.Resource,
          domain: PrepDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(SecondaryStore)
          collection(:query_prep_alerts)
        end

        attributes do
          integer_primary_key(:id)
          attribute(:profile_id, :integer, allow_nil?: false, public?: true)
          attribute(:severity, :atom, default: :info, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end

      defmodule PrepProfile do
        use Ash.Resource,
          domain: PrepDomain,
          data_layer: Xitdb.Ash.DataLayer

        require Ash.Query

        xitdb do
          store(PrimaryStore)
          collection(:query_prep_profiles)
        end

        preparations do
          prepare(build(load: [:name, :display_name]))
        end

        attributes do
          integer_primary_key(:id)
          attribute(:first_name, :string, allow_nil?: false, public?: true)
          attribute(:last_name, :string, default: "", allow_nil?: false, public?: true)
          attribute(:preferred_name, :string, public?: true)
          attribute(:score, :integer, default: 10, allow_nil?: false, public?: true)
          attribute(:org_id, :integer, public?: true)
        end

        relationships do
          belongs_to :org, PrepOrg do
            attribute_type(:integer)
            source_attribute(:org_id)
            destination_attribute(:id)
            allow_nil?(true)
            public?(true)
          end

          has_many :alerts, PrepAlert do
            destination_attribute(:profile_id)
            public?(true)
          end
        end

        calculations do
          calculate(
            :name,
            :string,
            expr(
              if is_nil(last_name) or last_name == "" do
                if is_nil(first_name), do: "", else: first_name
              else
                if is_nil(first_name) or first_name == "" do
                  last_name
                else
                  first_name <> " " <> last_name
                end
              end
            )
          )

          calculate(
            :display_name,
            :string,
            expr(
              if not is_nil(preferred_name) and preferred_name != "" do
                preferred_name
              else
                name
              end
            )
          )

          calculate(
            :org_label,
            :string,
            expr(display_name <> " @ " <> if(is_nil(org.name), do: "none", else: org.name))
          )

          calculate :scaled, :integer, expr(score * ^arg(:factor)) do
            argument(:factor, :integer, allow_nil?: false)
          end

          calculate(
            :combined_scaled,
            :integer,
            expr(scaled(factor: 2) + scaled(factor: 3))
          )

          calculate(:inner_has_alert, :boolean, expr(exists(alerts, true)))
          calculate(:outer_has_alert, :boolean, expr(inner_has_alert))
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end

      defmodule PrepUser do
        use Ash.Resource,
          domain: PrepDomain,
          data_layer: Xitdb.Ash.DataLayer

        xitdb do
          store(PrimaryStore)
          collection(:query_prep_users)
        end

        attributes do
          integer_primary_key(:id)
          attribute(:email, :string, allow_nil?: false, public?: true)
          attribute(:profile_id, :integer, public?: true)
        end

        relationships do
          belongs_to :profile, PrepProfile do
            attribute_type(:integer)
            source_attribute(:profile_id)
            destination_attribute(:id)
            allow_nil?(true)
            public?(true)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end

      defmodule PrepRelationalProfile do
        use Ash.Resource,
          domain: PrepDomain,
          data_layer: Xitdb.Ash.DataLayer

        require Ash.Query

        xitdb do
          store(PrimaryStore)
          collection(:query_prep_rel_profiles)
        end

        preparations do
          prepare(build(load: [:org_label]))
        end

        attributes do
          integer_primary_key(:id)
          attribute(:label, :string, allow_nil?: false, public?: true)
          attribute(:org_id, :integer, public?: true)
        end

        relationships do
          belongs_to :org, PrepOrg do
            attribute_type(:integer)
            source_attribute(:org_id)
            destination_attribute(:id)
            allow_nil?(true)
            public?(true)
          end
        end

        calculations do
          calculate(
            :org_label,
            :string,
            expr(label <> ":" <> if(is_nil(org.name), do: "none", else: org.name))
          )
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end
      end

      @tag timeout: 5_000
      test "evaluates chained expression calculations under prepare build(load: ...) without recursion" do
        org = Ash.create!(PrepOrg, %{name: "Acme Capital"}, domain: PrepDomain)

        p1 =
          Ash.create!(
            PrepProfile,
            %{first_name: "Alice", last_name: "Smith", score: 10, org_id: org.id},
            domain: PrepDomain
          )

        p2 =
          Ash.create!(
            PrepProfile,
            %{
              first_name: "Robert",
              last_name: "Jones",
              preferred_name: "Bob",
              score: 7,
              org_id: nil
            },
            domain: PrepDomain
          )

        Ash.create!(PrepUser, %{email: "alice@example.com", profile_id: p1.id},
          domain: PrepDomain
        )

        Ash.create!(PrepAlert, %{profile_id: p1.id, severity: :critical}, domain: PrepDomain)

        # 1. Direct read triggering `prepare build(load: [:name, :display_name])`
        profiles =
          PrepProfile
          |> Ash.Query.sort(display_name: :asc)
          |> Ash.read!(domain: PrepDomain)

        assert Enum.map(profiles, &{&1.name, &1.display_name}) == [
                 {"Alice Smith", "Alice Smith"},
                 {"Robert Jones", "Bob"}
               ]

        # 2. Filter on chained expression calculation
        assert [%{id: id_p1, display_name: "Alice Smith"}] =
                 PrepProfile
                 |> Ash.Query.filter(display_name == "Alice Smith")
                 |> Ash.read!(domain: PrepDomain)

        assert id_p1 == p1.id

        # 3. Loading via parent relationship
        [user] =
          PrepUser
          |> Ash.Query.load(:profile)
          |> Ash.read!(domain: PrepDomain)

        assert user.profile.display_name == "Alice Smith"

        # 4. Ash.load!/2 for chained + relational expression calcs (both populated and nil org)
        [loaded_p1, loaded_p2] =
          Ash.load!(profiles, [:display_name, :org_label], domain: PrepDomain)

        assert loaded_p1.org_label == "Alice Smith @ Acme Capital"
        assert loaded_p2.org_label == "Bob @ none"

        # 5. Ash.calculate!/2 (DataLayer.calculate/3)
        assert Ash.calculate!(p1, :display_name, domain: PrepDomain) == "Alice Smith"
        assert Ash.calculate!(p2, :display_name, domain: PrepDomain) == "Bob"

        # 6. Repeated parameterized calc (`scaled(factor: 2) + scaled(factor: 3)`) alongside
        #    explicitly loaded `scaled(factor: 10)` in the same query (must not collide)
        [calc_p1] =
          PrepProfile
          |> Ash.Query.filter(id == ^p1.id)
          |> Ash.Query.load([{:scaled, %{factor: 10}}, :combined_scaled])
          |> Ash.read!(domain: PrepDomain)

        assert calc_p1.scaled == 100
        assert calc_p1.combined_scaled == 50

        # 7. Nested exists/2 inside a chained expression calculation
        [alert_p1, alert_p2] =
          PrepProfile
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.load(:outer_has_alert)
          |> Ash.read!(domain: PrepDomain)

        assert alert_p1.outer_has_alert == true
        assert alert_p2.outer_has_alert == false
      end

      @tag timeout: 5_000
      test "evaluates preparation-loaded relationship expression calculations without re-entering read preparations" do
        org = Ash.create!(PrepOrg, %{name: "Northleaf"}, domain: PrepDomain)

        Ash.create!(PrepRelationalProfile, %{label: "Lead", org_id: org.id}, domain: PrepDomain)
        Ash.create!(PrepRelationalProfile, %{label: "Solo", org_id: nil}, domain: PrepDomain)

        rows =
          PrepRelationalProfile
          |> Ash.Query.sort(id: :asc)
          |> Ash.read!(domain: PrepDomain)

        assert Enum.map(rows, & &1.org_label) == ["Lead:Northleaf", "Solo:none"]
      end
    end
  end
end
