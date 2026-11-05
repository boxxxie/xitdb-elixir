defmodule Xitdb.TestSupport.AshFixtures do
  @moduledoc false

  defmodule TestLockChange do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, opts, _context) do
      field = Ash.Changeset.get_argument(changeset, :field) |> to_string()
      current = Ash.Changeset.get_attribute(changeset, :locked_fields) || []

      updated =
        case Keyword.fetch!(opts, :op) do
          :lock -> Enum.uniq(current ++ [field])
          :unlock -> List.delete(current, field)
        end

      Ash.Changeset.change_attribute(changeset, :locked_fields, updated)
    end
  end

  defmodule TestOrg do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.AshFixtures.TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [Xitdb.Ash.Resource]

    ets do
      private?(true)
    end

    xitdb do
      store :default_mdm_store
      collection :organizations
      merge_redirect_collection :org_merged_into
      locked_ids_set :locked_org_ids
      lock_change TestLockChange

      editable_fields [:name, :domain, :headquarters]
      passthru_fields [:creatio_id, :parent_organization_id]
      computed_xitdb_fields [:normalized_name, :activity_count]
      field_aliases parent_organization_id: :parent_org_id

      indexes(
        domain: "domain->org_id",
        normalized_name: "norm_name->org_id",
        creatio_id: "creatio_id->org_id"
      )
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, allow_nil?: false, public?: true)
      attribute(:domain, :string, public?: true)
      attribute(:headquarters, :string, public?: true)
      attribute(:creatio_id, :string, public?: true)
      attribute(:parent_organization_id, :uuid, public?: true)
      attribute(:locked_fields, {:array, :string}, default: [], public?: true)
      attribute(:status, :atom, default: :active, public?: true)
    end

    actions do
      defaults([:read, create: :*])

      update :mdm_sync_update do
        require_atomic?(false)

        accept([
          :name,
          :domain,
          :headquarters,
          :creatio_id,
          :parent_organization_id,
          :locked_fields,
          :status
        ])
      end

      update :lock_field do
        require_atomic?(false)
        argument(:field, :string, allow_nil?: false)
      end

      update :unlock_field do
        require_atomic?(false)
        argument(:field, :string, allow_nil?: false)
      end
    end
  end

  defmodule TestDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(TestOrg)
      resource(Xitdb.TestSupport.AshFixtures.TestOrgProfile)
    end
  end

  defmodule TestOrgProfile do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.AshFixtures.TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [Xitdb.Ash.Resource]

    ets do
      private?(true)
    end

    xitdb do
      collection :organizations
      companion_resource Xitdb.TestSupport.AshFixtures.TestOrg
      lock_change TestLockChange

      editable_fields [:website, :industry]
      passthru_fields [:linkedin_url]
      computed_xitdb_fields [:normalized_name]

      indexes(website: "website->org_id")
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:website, :string, public?: true)
      attribute(:industry, :string, public?: true)
      attribute(:linkedin_url, :string, public?: true)
      attribute(:locked_fields, {:array, :string}, default: [], public?: true)
      attribute(:status, :atom, default: :active, public?: true)
    end

    actions do
      defaults([:read, create: :*])

      update :mdm_sync_update do
        require_atomic?(false)
        accept([:website, :industry, :linkedin_url, :status])
      end

      update :lock_field do
        require_atomic?(false)
        argument(:field, :string, allow_nil?: false)
        change({TestLockChange, op: :custom_lock})
      end
    end
  end

  defmodule PlainIndexedSchema do
    @moduledoc false
    def __xitdb_collection__, do: :items
    def __xitdb_indexes__, do: [sku: "sku->item_id"]
  end

  defmodule ExplicitTripleIndexedSchema do
    @moduledoc false
    def __xitdb_indexes__, do: [{:events, :external_id, "ext_id->event_id"}]
  end
end
