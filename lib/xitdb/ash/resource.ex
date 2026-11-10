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

    ## Nested sub-collections

    A resource that has no top-level collection of its own can be stored inside a
    parent entity with `nested_in` (see `Xitdb.Ash.NestedIn`):

        defmodule MyApp.Accounts.PhoneNumber do
          use Ash.Resource, extensions: [Xitdb.Ash.Resource]

          xitdb do
            nested_in MyApp.Accounts.User, as: :phones, parent_key: :user_id, key: :e164
            editable_fields [:number_type, :is_primary]
            passthru_fields [:e164, :user_id]
          end
        end

    Use `Xitdb.Ash.Info.entity_paths/2` to resolve where a record is stored.
    """

    @default_ignored_sync_attributes [
      :locked_by_user,
      :locked_fields,
      :dirty_for_upstream_sync,
      :local_overrides,
      :status
    ]

    @nested_in %Spark.Dsl.Entity{
      name: :nested_in,
      describe: """
      Stores this resource inside a parent entity (`<parent collection>[parent_id].<as>[key]`)
      instead of a top-level collection. Repeat the entity to allow several parents.
      """,
      examples: [
        "nested_in MyApp.Accounts.User, as: :phones, parent_key: :user_id, key: :e164",
        "nested_in MyApp.Events.Event, as: :conference, parent_key: :event_id, cardinality: :one"
      ],
      target: Xitdb.Ash.NestedIn,
      args: [:parent],
      identifier: {:auto, :unique_integer},
      schema: [
        parent: [
          type: :atom,
          required: true,
          doc: "Parent `Xitdb.Ash.Resource`, which must declare a top-level `collection`."
        ],
        as: [
          type: :atom,
          required: true,
          doc: "Slot name under the parent entity (e.g. `:phones`, `:sessions`)."
        ],
        parent_key: [
          type: :atom,
          required: true,
          doc: "Attribute on this resource that holds the parent entity id."
        ],
        key: [
          type: :atom,
          doc:
            "Attribute whose value is the entry key inside the sub-collection. Required for `cardinality: :many`."
        ],
        cardinality: [
          type: {:in, [:one, :many]},
          default: :many,
          doc: "`:many` stores a map of entries; `:one` stores a single map at the slot."
        ]
      ]
    }

    @xitdb_section %Spark.Dsl.Section{
      name: :xitdb,
      describe: "Configures Xitdb MDM projection, survivorship locks, and secondary indexes.",
      entities: [@nested_in],
      schema: [
        store: [
          type: :atom,
          doc:
            "Default Xitdb Store GenServer name (overridable via `context[:xitdb_store]` or `config :xitdb, :default_store`)."
        ],
        collection: [
          type: :atom,
          doc:
            "Primary Xitdb hash_map collection (`:organizations`, `:people`, `:events`). Required unless the resource declares `nested_in`."
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
