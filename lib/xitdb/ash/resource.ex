if Code.ensure_loaded?(Spark.Dsl.Extension) and Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Resource do
    @moduledoc """
    Spark DSL extension declaring Xitdb MDM collection mappings, synced field
    projections, secondary B+Tree indexes, and lock actions on an `Ash.Resource`.

    ## Example

        defmodule MyApp.Accounts.Organization do
          use Ash.Resource,
            domain: MyApp.Accounts,
            extensions: [Xitdb.Ash.Resource]

          xitdb do
            store MyApp.MDM.Store
            collection :organizations
            merge_redirect_collection :org_merged_into
            locked_ids_set :locked_org_ids

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
        end
    """

    @default_ignored_sync_attributes [
      :locked_by_user,
      :locked_fields,
      :dirty_for_upstream_sync,
      :local_overrides,
      :status
    ]

    @xitdb_section %Spark.Dsl.Section{
      name: :xitdb,
      describe: "Configures Xitdb MDM projection, survivorship locks, and secondary indexes.",
      schema: [
        store: [
          type: :atom,
          doc:
            "Default Xitdb Store GenServer name (overridable via `context[:xitdb_store]` or `config :xitdb, :default_store`)."
        ],
        collection: [
          type: :atom,
          required: true,
          doc: "Primary Xitdb hash_map collection (`:organizations`, `:people`, `:events`)."
        ],
        merge_redirect_collection: [
          type: :atom,
          doc:
            "Sorted map storing loser -> winner redirects (`:org_merged_into`, `:merged_into`)."
        ],
        locked_ids_set: [
          type: :atom,
          doc: "Curation counted_hash_set tracking locked entity IDs (`:locked_org_ids`, etc.)."
        ],
        companion_resource: [
          type: :atom,
          doc:
            "Optional companion resource sharing the same Xitdb entity (e.g. `Profile` <-> `User`)."
        ],
        editable_fields: [
          type: {:list, :atom},
          default: [],
          doc:
            "Canonical attributes subject to per-field survivorship locks and conflict detection."
        ],
        passthru_fields: [
          type: {:list, :atom},
          default: [],
          doc:
            "Attributes projected into Xitdb without per-field conflict logging (e.g. `:creatio_id`)."
        ],
        computed_xitdb_fields: [
          type: {:list, :atom},
          default: [],
          doc:
            "Derived Xitdb-only fields maintained by the engine (e.g. `:normalized_name`, `:activity_count`)."
        ],
        field_aliases: [
          type: :keyword_list,
          default: [],
          doc:
            "Maps Ash attribute names to Xitdb slot names (e.g. `[parent_organization_id: :parent_org_id]`)."
        ],
        indexes: [
          type: :keyword_list,
          default: [],
          doc: "Secondary B+Tree index declarations (`[domain: \"domain->org_id\", ...]`)."
        ],
        sync_update_action: [
          type: :atom,
          default: :mdm_sync_update,
          doc: "Ash update action invoked by reconciler projectors."
        ],
        ignored_sync_attributes: [
          type: {:list, :atom},
          default: @default_ignored_sync_attributes,
          doc:
            "Attributes accepted by `sync_update_action` that are bookkeeping metadata rather than projected Xitdb fields."
        ],
        lock_action: [
          type: :atom,
          default: :lock_field,
          doc: "Ash update action that locks a single field."
        ],
        unlock_action: [
          type: :atom,
          default: :unlock_field,
          doc: "Ash update action that unlocks a single field."
        ],
        lock_change: [
          type: :atom,
          doc:
            "`Ash.Resource.Change` module automatically wired into `lock_action` and `unlock_action` (defaults to `config :xitdb, :default_lock_change`)."
        ]
      ]
    }

    use Spark.Dsl.Extension,
      sections: [@xitdb_section],
      transformers: [Xitdb.Ash.Transformers.WireChanges],
      verifiers: [Xitdb.Ash.Verifiers.VerifySyncProjection]
  end
end
