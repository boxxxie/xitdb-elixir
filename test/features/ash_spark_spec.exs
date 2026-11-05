defmodule Xitdb.Features.AshSparkSpec do
  use Xitdb.FeatureCase, async: true

  require Xitdb.Ash.Tx

  alias Xitdb.Ash.Info, as: XitdbInfo

  alias Xitdb.TestSupport.AshFixtures.{
    ExplicitTripleIndexedSchema,
    PlainIndexedSchema,
    TestLockChange,
    TestOrg,
    TestOrgProfile
  }

  scenario "Xitdb.Ash.Info introspects single and companion resources, field aliases, Pull patterns, and store precedence" do
    @upon inspecting_ash_resource_info(
            :org_info,
            TestOrg,
            store_queries: [
              from_context_map: %{xitdb_store: :context_override_store},
              from_nil_context_map: %{xitdb_store: nil},
              from_keyword_opts: [store: :keyword_override_store],
              from_resource_default: %{}
            ]
          )
    @upon inspecting_ash_resource_info(
            :profile_info,
            TestOrgProfile,
            store_queries: [
              from_app_env_fallback: %{}
            ]
          )
    @upon inspecting_ash_resource_info(:combined_info, [TestOrg, TestOrgProfile])

    @then resolved_value_is(:org_info, %{
            collection: :organizations,
            merge_redirect_collection: :org_merged_into,
            locked_ids_set: :locked_org_ids,
            companion_resource: nil,
            editable_field_strings: [
              "name",
              "domain",
              "headquarters",
              "normalized_name",
              "activity_count"
            ],
            pull_fields: [
              :id,
              :name,
              :domain,
              :headquarters,
              :creatio_id,
              :parent_org_id
            ],
            pull_pattern: "{id, name, domain, headquarters, creatio_id, parent_org_id}",
            resolved_stores: %{
              from_context_map: :context_override_store,
              from_nil_context_map: :default_mdm_store,
              from_keyword_opts: :keyword_override_store,
              from_resource_default: :default_mdm_store
            }
          })

    @then resolved_value_is(:profile_info, %{
            collection: :organizations,
            merge_redirect_collection: nil,
            locked_ids_set: nil,
            companion_resource: TestOrg,
            editable_field_strings: [
              "website",
              "industry",
              "normalized_name"
            ],
            pull_fields: [
              :id,
              :website,
              :industry,
              :linkedin_url
            ],
            pull_pattern: "{id, website, industry, linkedin_url}",
            resolved_stores: %{
              from_app_env_fallback: nil
            }
          })

    @then resolved_value_is(:combined_info, %{
            editable_field_strings: [
              "name",
              "domain",
              "headquarters",
              "normalized_name",
              "activity_count",
              "website",
              "industry"
            ],
            pull_fields: [
              :id,
              :name,
              :domain,
              :headquarters,
              :creatio_id,
              :parent_org_id,
              :website,
              :industry,
              :linkedin_url
            ],
            pull_pattern:
              "{id, name, domain, headquarters, creatio_id, parent_org_id, website, industry, linkedin_url}"
          })
  end

  scenario "WireChanges Spark transformer attaches lock_change, preserves pre-existing changes idempotently, and skips missing actions" do
    @upon creating_ash_record(:org, TestOrg, :create, %{name: "Northleaf Capital"})
    @upon updating_ash_record(:org, :lock_field, %{field: "headquarters"})
    @upon updating_ash_record(:org, :lock_field, %{field: "domain"})

    @then ash_action_includes_change(TestOrg, :lock_field, {TestLockChange, op: :lock})
    @then ash_action_includes_change(TestOrg, :unlock_field, {TestLockChange, op: :unlock})
    # TestOrgProfile already declared `{TestLockChange, op: :custom_lock}` on `:lock_field` and has no `:unlock_field`
    @then ash_action_includes_change(
            TestOrgProfile,
            :lock_field,
            {TestLockChange, op: :custom_lock}
          )
    @then ash_record_attribute_equals(:org, :locked_fields, ["headquarters", "domain"])

    @upon updating_ash_record(:org, :unlock_field, %{field: "headquarters"})

    @then ash_record_attribute_equals(:org, :locked_fields, ["domain"])
  end

  scenario "VerifySyncProjection passes valid resources (including aliased indexes and missing sync actions) and rejects invalid projections" do
    @upon verifying_ash_sync_projection(:valid_org, TestOrg)
    @upon verifying_ash_sync_projection(:valid_profile, TestOrgProfile)
    @upon verifying_ash_sync_projection(:aliased_index_field, TestOrg,
            indexes: [parent_org_id: "parent->org_id"]
          )
    @upon verifying_ash_sync_projection(:missing_sync_action, TestOrg,
            sync_update_action: :non_existent_sync_action
          )
    @upon verifying_ash_sync_projection(:unprojected_sync_attrs, TestOrg,
            editable_fields: [:name]
          )
    @upon verifying_ash_sync_projection(:unknown_editable_attr, TestOrg,
            editable_fields: [:name, :non_existent_field]
          )
    @upon verifying_ash_sync_projection(:unknown_passthru_attr, TestOrg,
            passthru_fields: [:creatio_id, :non_existent_passthru]
          )
    @upon verifying_ash_sync_projection(:unmapped_index_field, TestOrg,
            indexes: [unmapped_slot: "unmapped->org_id"]
          )

    @then ash_verifier_succeeded(:valid_org)
    @then ash_verifier_succeeded(:valid_profile)
    @then ash_verifier_succeeded(:aliased_index_field)
    @then ash_verifier_succeeded(:missing_sync_action)

    @then ash_verifier_failed_with(:unprojected_sync_attrs,
            path: [:actions, :update, :mdm_sync_update],
            message_includes: [":domain", ":headquarters", "editable_fields"]
          )

    @then ash_verifier_failed_with(:unknown_editable_attr,
            path: [:xitdb],
            message_includes: [":non_existent_field", "does not exist as an attribute"]
          )

    @then ash_verifier_failed_with(:unknown_passthru_attr,
            path: [:xitdb],
            message_includes: [":non_existent_passthru", "does not exist as an attribute"]
          )

    @then ash_verifier_failed_with(:unmapped_index_field,
            path: [:xitdb, :indexes],
            message_includes: [
              ":unmapped_slot",
              "is not in editable_fields, passthru_fields, or computed_xitdb_fields"
            ]
          )
  end

  scenario "tx_for, tx_for!, and Xitdb.Ash.Tx macros maintain secondary B+Tree indexes across Ash resources, 2-tuple schemas, and 3-tuple schemas" do
    @given memory_database()

    @upon executing_dsl_transaction(fn db ->
            updated_db =
              tx_for! db,
                      [TestOrg, PlainIndexedSchema, ExplicitTripleIndexedSchema],
                      doc: "init and insert indexed records" do
                init_col organizations, :hash_map
                init_col items, :hash_map
                init_col events, :hash_map
                put organizations["101"].id, "101"
                put organizations["101"].name, "Northleaf Capital"
                put organizations["101"].domain, "northleafcapital.com"
                put organizations["101"].headquarters, "Toronto"
                put organizations["101"].creatio_id, "CRM-ORG-101"
                put organizations["101"].parent_org_id, "parent-99"
                put organizations["101"].normalized_name, "northleaf capital"
                put organizations["101"].internal_scratch, "ephemeral"
                put items["i-1"].sku, "SKU-900"
                put events["ev-1"].external_id, "EXT-42"
              end

            {:ok, updated_db}
          end)

    # Exercise `Xitdb.Ash.Tx.tx_for/3` and single-module (non-list) resource argument
    @upon executing_dsl_transaction(fn db ->
            Xitdb.Ash.Tx.tx_for db, TestOrgProfile do
              put organizations["101"].website, "https://northleafcapital.com"
            end
          end)

    @upon pulling_projection(
            :pulled_org,
            path(organizations["101"]),
            XitdbInfo.pull_pattern_for([TestOrg, TestOrgProfile])
          )

    @then database_moment_count_is(2)
    @then access_path_equals(["domain->org_id", "northleafcapital.com"], "101")
    @then access_path_equals(["norm_name->org_id", "northleaf capital"], "101")
    @then access_path_equals(["creatio_id->org_id", "CRM-ORG-101"], "101")
    @then access_path_equals(["website->org_id", "https://northleafcapital.com"], "101")
    @then access_path_equals(["sku->item_id", "SKU-900"], "i-1")
    @then access_path_equals(["ext_id->event_id", "EXT-42"], "ev-1")
    @then resolved_value_is(:pulled_org, %{
            "id" => "101",
            "name" => "Northleaf Capital",
            "domain" => "northleafcapital.com",
            "headquarters" => "Toronto",
            "creatio_id" => "CRM-ORG-101",
            "parent_org_id" => "parent-99",
            "website" => "https://northleafcapital.com"
          })

    @upon executing_dsl_transaction(fn db ->
            Xitdb.Ash.Tx.tx_for db,
                                [
                                  TestOrg,
                                  TestOrgProfile,
                                  PlainIndexedSchema,
                                  ExplicitTripleIndexedSchema
                                ],
                                doc: "remove indexed records" do
              rm organizations["101"]
              rm items["i-1"]
              rm events["ev-1"]
            end
          end)

    @then database_moment_count_is(3)
    @then access_path_equals(["domain->org_id", "northleafcapital.com"], nil)
    @then access_path_equals(["norm_name->org_id", "northleaf capital"], nil)
    @then access_path_equals(["creatio_id->org_id", "CRM-ORG-101"], nil)
    @then access_path_equals(["website->org_id", "https://northleafcapital.com"], nil)
    @then access_path_equals(["sku->item_id", "SKU-900"], nil)
    @then access_path_equals(["ext_id->event_id", "EXT-42"], nil)
  end

  scenario "tx_for raises descriptive CompileError when given a non-module expression or an unconfigured module" do
    @upon evaluating_quoted_ast(
            :non_module_arg,
            quote(
              do:
                (
                  use Xitdb.DSL
                  tx_for(db, 123, do: :ok)
                )
            )
          )
    @upon evaluating_quoted_ast(
            :unconfigured_module_arg,
            quote(
              do:
                (
                  use Xitdb.DSL
                  tx_for(db, String, do: :ok)
                )
            )
          )

    @then compile_error_raised_with(:non_module_arg, [
            "tx_for expects a compile-time module or list of modules"
          ])

    @then compile_error_raised_with(:unconfigured_module_arg, [
            "Module String does not declare Xitdb indexes"
          ])
  end
end
