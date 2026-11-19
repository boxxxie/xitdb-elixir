if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.TxAttributionTest do
    use Xitdb.AshCase

    alias Xitdb.Ash.Store
    alias Xitdb.TestSupport.{AppDomain, DirectMessage, MdmDomain, MdmStore, Organization}

    test "Ash create, update, and destroy stamp standardized __tx attribution and actor metadata" do
      actor = %{id: 42, email: "ada@example.com"}

      org =
        MdmDomain.register_organization!(
          %{
            name: "Acme Holdings",
            domain: "acme.com",
            slug: "acme-holdings",
            mandate: "Direct private credit"
          },
          actor: actor
        )

      db = Store.current_db(MdmStore)
      create_meta = Xitdb.tx_meta!(db)

      assert is_integer(create_meta["tx_instant"]) and create_meta["tx_instant"] > 0
      assert create_meta["doc"] != ""
      assert create_meta["source_system"] == "ash_action"
      assert create_meta["action_name"] == "register"
      assert create_meta["actor_id"] == "42"
      assert create_meta["actor_email"] == "ada@example.com"

      updated =
        MdmDomain.rename_organization!(
          org,
          %{name: "Acme Capital", mandate: "Updated mandate"},
          actor: actor,
          context: %{
            xitdb: %{
              doc: "steward rename",
              instant: 1_700_000_999_000,
              meta: %{
                "source_system" => "creatio",
                "reason" => "backfill",
                "workflow_run_id" => "sync-7"
              }
            }
          }
        )

      db = Store.current_db(MdmStore)
      update_meta = Xitdb.tx_meta!(db)

      assert update_meta["doc"] == "steward rename"
      assert update_meta["tx_instant"] == 1_700_000_999_000
      assert update_meta["source_system"] == "creatio"
      assert update_meta["reason"] == "backfill"
      assert update_meta["workflow_run_id"] == "sync-7"
      assert update_meta["action_name"] == "rename_and_reindex"
      assert update_meta["actor_id"] == "42"
      assert update_meta["actor_email"] == "ada@example.com"

      Xitdb.with_tx_context(
        [
          doc: "ambient delete doc",
          meta: %{actor_id: "99", source_system: "steward_ui", reason: "duplicate"}
        ],
        fn ->
          :ok = MdmDomain.destroy_organization!(updated)
        end
      )

      db = Store.current_db(MdmStore)
      destroy_meta = Xitdb.tx_meta!(db)

      assert destroy_meta["doc"] == "ambient delete doc"
      assert destroy_meta["actor_id"] == "99"
      assert destroy_meta["source_system"] == "steward_ui"
      assert destroy_meta["reason"] == "duplicate"
      assert destroy_meta["action_name"] == "destroy"
    end

    test "Ash bulk_create, bulk_update, and bulk_destroy stamp __tx attribution" do
      actor = %{id: 7, email: "ops@caasa.ca"}

      %Ash.BulkResult{records: [org1, org2]} =
        Ash.bulk_create!(
          [
            %{name: "Alpha Partners", domain: "alpha.example", slug: "alpha"},
            %{name: "Beta Partners", domain: "beta.example", slug: "beta"}
          ],
          Organization,
          :register,
          domain: MdmDomain,
          actor: actor,
          return_records?: true
        )

      bulk_create_meta = Xitdb.tx_meta!(Store.current_db(MdmStore))
      assert is_integer(bulk_create_meta["tx_instant"]) and bulk_create_meta["tx_instant"] > 0
      assert bulk_create_meta["doc"] != ""
      assert bulk_create_meta["source_system"] == "ash_action"
      assert bulk_create_meta["action_name"] == "register"
      assert bulk_create_meta["actor_id"] == "7"
      assert bulk_create_meta["actor_email"] == "ops@caasa.ca"

      require Ash.Query

      msg =
        AppDomain.send_message!(
          %{sender_id: org1.id, recipient_id: org2.id, body: "Hello"},
          actor: actor
        )

      %Ash.BulkResult{status: :success} =
        DirectMessage
        |> Ash.Query.filter(id == ^msg.id)
        |> Ash.bulk_update!(:archive, %{},
          domain: AppDomain,
          actor: actor,
          context: %{xitdb: %{meta: %{"reason" => "cleanup"}}}
        )

      bulk_update_meta = Xitdb.tx_meta!(Store.current_db(Xitdb.TestSupport.AppStore))
      assert bulk_update_meta["action_name"] == "archive"
      assert bulk_update_meta["reason"] == "cleanup"
      assert bulk_update_meta["actor_id"] == "7"
      assert bulk_update_meta["tx_instant"] > 0

      %Ash.BulkResult{status: :success} =
        Organization
        |> Ash.Query.filter(id in [^org1.id, ^org2.id])
        |> Ash.bulk_destroy!(:destroy, %{}, domain: MdmDomain, actor: actor)

      bulk_destroy_meta = Xitdb.tx_meta!(Store.current_db(MdmStore))
      assert bulk_destroy_meta["action_name"] == "destroy"
      assert bulk_destroy_meta["actor_id"] == "7"
      assert bulk_destroy_meta["tx_instant"] > 0
    end

    test "Ash.create with mdm_materializer: true projects onto pre-existing cursor in-place preserving non-Ash fields" do
      {:ok, :seeded} =
        Store.mutate(MdmStore, fn {db, moment} ->
          {:ok, db2, m2} =
            Xitdb.transact_ops_with_moment(
              db,
              [
                {:init_col, ".organizations", "hash_map"},
                {:init_col, ".organizations[\"901\"]", "hash_map"},
                {:put, ".organizations[\"901\"].id", "901"},
                {:put, ".organizations[\"901\"].name", "Pre-Seeded Capital"},
                {:put, ".organizations[\"901\"].normalized_name", "pre seeded capital"},
                {:init_col, ".organizations[\"901\"].sources", "counted_hash_set"},
                {:put, ".organizations[\"901\"].sources", Xitdb.counted_set(["creatio:acc-901"])}
              ],
              base_moment: moment,
              doc: "seed pre-existing MDM org cursor",
              instant: System.os_time(:millisecond)
            )

          {:ok, {db2, m2}, :seeded}
        end)

      org =
        Organization
        |> Ash.Changeset.for_create(
          :register,
          %{
            name: "Pre-Seeded Capital",
            domain: "preseeded.example",
            slug: "pre-seeded-capital",
            mandate: "Direct lending"
          },
          context: %{mdm_materializer: true}
        )
        |> Ash.Changeset.force_change_attribute(:id, 901)
        |> Ash.create!(authorize?: false)

      assert org.id == 901

      root = Store.root(MdmStore)
      cur = root["organizations"]["901"]
      assert cur["normalized_name"] == "pre seeded capital"
      assert Enum.to_list(cur["sources"]) == ["creatio:acc-901"]
      assert cur["slug"] == "pre-seeded-capital"

      meta = Xitdb.tx_meta!(Store.current_db(MdmStore))
      assert meta["actor_id"] == "system"
      assert meta["source_system"] == "ash_action"
      assert meta["action_name"] == "register"
    end
  end
end
