defmodule Xitdb.Features.AshSparkSpec do
  use ExUnit.Case, async: true

  use Xitdb.DSL

  alias Ash.Resource.Info, as: ResourceInfo
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError
  alias Xitdb.Ash.Info, as: XitdbInfo
  alias Xitdb.Ash.Verifiers.VerifySyncProjection
  alias Xitdb.TestSupport.AshFixtures.{PlainIndexedSchema, TestLockChange, TestOrg}

  describe "Xitdb.Ash.Info introspection" do
    test "exposes collection, editable fields, pull fields, pull pattern, and store resolution" do
      assert XitdbInfo.xitdb_collection!(TestOrg) == :organizations
      assert XitdbInfo.xitdb_merge_redirect_collection!(TestOrg) == :org_merged_into
      assert XitdbInfo.xitdb_locked_ids_set!(TestOrg) == :locked_org_ids

      assert XitdbInfo.editable_field_strings(TestOrg) == [
               "name",
               "domain",
               "headquarters",
               "normalized_name",
               "activity_count"
             ]

      assert XitdbInfo.pull_fields(TestOrg) == [
               :id,
               :name,
               :domain,
               :headquarters,
               :creatio_id,
               :parent_org_id
             ]

      assert XitdbInfo.pull_pattern_for(TestOrg) ==
               "{id, name, domain, headquarters, creatio_id, parent_org_id}"

      fake_pid = self()
      assert XitdbInfo.resolve_store(TestOrg, %{xitdb_store: fake_pid}) == fake_pid
      assert XitdbInfo.resolve_store(TestOrg, store: :custom_store) == :custom_store
      assert XitdbInfo.resolve_store(TestOrg, %{}) == :default_mdm_store
    end
  end

  describe "WireChanges transformer" do
    test "attaches configured lock_change to :lock_field and :unlock_field and executes them" do
      lock_action = ResourceInfo.action(TestOrg, :lock_field)
      unlock_action = ResourceInfo.action(TestOrg, :unlock_field)

      assert Enum.any?(
               lock_action.changes,
               &match?(%{change: {TestLockChange, op: :lock}}, &1)
             )

      assert Enum.any?(
               unlock_action.changes,
               &match?(%{change: {TestLockChange, op: :unlock}}, &1)
             )

      org =
        TestOrg
        |> Ash.Changeset.for_create(:create, %{name: "Northleaf Capital"})
        |> Ash.create!()

      locked =
        org
        |> Ash.Changeset.for_update(:lock_field, %{field: "headquarters"})
        |> Ash.update!()

      assert locked.locked_fields == ["headquarters"]

      unlocked =
        locked
        |> Ash.Changeset.for_update(:unlock_field, %{field: "headquarters"})
        |> Ash.update!()

      assert unlocked.locked_fields == []
    end
  end

  describe "VerifySyncProjection compile-time verifier" do
    test "passes for valid resource configuration" do
      assert VerifySyncProjection.verify(TestOrg.spark_dsl_config()) == :ok
    end

    test "fails when :mdm_sync_update accepts an attribute missing from editable_fields or passthru_fields" do
      dsl_state = TestOrg.spark_dsl_config()

      trimmed_dsl =
        Transformer.set_option(
          dsl_state,
          [:xitdb],
          :editable_fields,
          [:name]
        )

      assert {:error, %DslError{message: msg}} = VerifySyncProjection.verify(trimmed_dsl)
      assert msg =~ ":domain"
      assert msg =~ ":headquarters"
    end

    test "fails when editable_fields declares a non-existent attribute" do
      dsl_state = TestOrg.spark_dsl_config()

      bad_dsl =
        Transformer.set_option(
          dsl_state,
          [:xitdb],
          :editable_fields,
          [:name, :non_existent_field]
        )

      assert {:error, %DslError{message: msg}} = VerifySyncProjection.verify(bad_dsl)
      assert msg =~ ":non_existent_field"
      assert msg =~ "does not exist as an attribute"
    end

    test "fails when indexes references an unprojected field" do
      dsl_state = TestOrg.spark_dsl_config()

      bad_dsl =
        Transformer.set_option(
          dsl_state,
          [:xitdb],
          :indexes,
          unmapped_slot: "unmapped->org_id"
        )

      assert {:error, %DslError{message: msg}} = VerifySyncProjection.verify(bad_dsl)
      assert msg =~ ":unmapped_slot"
      assert msg =~ "is not in editable_fields, passthru_fields, or computed_xitdb_fields"
    end
  end

  describe "Xitdb.DSL.tx_for and tx_for! macros" do
    test "automatically injects secondary B+Tree indexes for Ash resources and plain schemas" do
      {:ok, db} = Xitdb.open(backend: :memory)

      db =
        tx_for! db, [TestOrg, PlainIndexedSchema], doc: "init and insert indexed records" do
          init_col organizations, :hash_map
          init_col items, :hash_map
          put organizations["101"].id, "101"
          put organizations["101"].domain, "northleafcapital.com"
          put organizations["101"].normalized_name, "northleaf capital"
          put organizations["101"].creatio_id, "CRM-ORG-101"
          put items["i-1"].sku, "SKU-900"
        end

      root = Xitdb.db(db)
      assert root["domain->org_id"]["northleafcapital.com"] == "101"
      assert root["norm_name->org_id"]["northleaf capital"] == "101"
      assert root["creatio_id->org_id"]["CRM-ORG-101"] == "101"
      assert root["sku->item_id"]["SKU-900"] == "i-1"

      {:ok, db} =
        tx_for db, [TestOrg, PlainIndexedSchema] do
          rm organizations["101"]
          rm items["i-1"]
        end

      root = Xitdb.db(db)
      assert is_nil(root["domain->org_id"]["northleafcapital.com"])
      assert is_nil(root["norm_name->org_id"]["northleaf capital"])
      assert is_nil(root["creatio_id->org_id"]["CRM-ORG-101"])
      assert is_nil(root["sku->item_id"]["SKU-900"])
    end
  end
end
