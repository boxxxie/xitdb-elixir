defmodule Xitdb.TestSupport.AshFixtures do
  @moduledoc false

  defmodule TestDomain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Xitdb.TestSupport.AshFixtures.TestIndexedOrg)
      resource(Xitdb.TestSupport.AshFixtures.TestSearchProfile)
    end
  end

  defmodule MockSearchStore do
    @moduledoc false
  end

  defmodule TestIndexedOrg do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.AshFixtures.TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [Xitdb.Ash.Dsl]

    ets do
      private?(true)
    end

    xitdb do
      store Xitdb.TestSupport.AshFixtures.MockSearchStore
      collection :organizations
      index :domain, name: "domain->org_id"
      index :creatio_id, name: "creatio_id->org_id"
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:name, :string, public?: true)
      attribute(:domain, :string, public?: true)
      attribute(:creatio_id, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
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

  defmodule TestSearchProfile do
    @moduledoc false
    use Ash.Resource,
      domain: Xitdb.TestSupport.AshFixtures.TestDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [Xitdb.Ash.Dsl]

    ets do
      private?(true)
    end

    xitdb do
      store Xitdb.TestSupport.AshFixtures.MockSearchStore
      collection :search_profiles

      search_field :full_name, boost: 3.0
      search_field :headline, boost: 1.0

      search_field :firm_name,
        boost: 2.0,
        resolver: fn profile, db ->
          Xitdb.Ash.Search.lookup_field(db, :organizations, profile.organization_id, "name")
        end
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:full_name, :string, public?: true)
      attribute(:headline, :string, public?: true)
      attribute(:organization_id, :string, public?: true)
    end

    actions do
      defaults([:read, create: :*])
    end
  end
end
