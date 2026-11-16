defmodule Xitdb.Features.AshSparkSpec do
  use Xitdb.FeatureCase, async: true

  require Xitdb.Ash.Tx

  alias Xitdb.TestSupport.AshFixtures.{
    ExplicitTripleIndexedSchema,
    PlainIndexedSchema,
    TestIndexedOrg
  }

  scenario "tx_for, tx_for!, and Xitdb.Ash.Tx macros maintain secondary B+Tree indexes across Ash resources, 2-tuple schemas, and 3-tuple schemas" do
    @given memory_database()

    @upon executing_dsl_transaction(fn db ->
            updated_db =
              tx_for! db,
                      [TestIndexedOrg, PlainIndexedSchema, ExplicitTripleIndexedSchema],
                      doc: "init and insert indexed records" do
                init_col organizations, :hash_map
                init_col items, :hash_map
                init_col events, :hash_map
                put organizations["101"].id, "101"
                put organizations["101"].name, "Northleaf Capital"
                put organizations["101"].domain, "northleafcapital.com"
                put organizations["101"].creatio_id, "CRM-ORG-101"
                put items["i-1"].sku, "SKU-900"
                put events["ev-1"].external_id, "EXT-42"
              end

            {:ok, updated_db}
          end)

    # Exercise `Xitdb.Ash.Tx.tx_for/3` and single-module (non-list) resource argument
    @upon executing_dsl_transaction(fn db ->
            Xitdb.Ash.Tx.tx_for db, TestIndexedOrg do
              put organizations["102"].id, "102"
              put organizations["102"].domain, "southridge.ca"
            end
          end)

    @then database_moment_count_is(2)
    @then access_path_equals(["domain->org_id", "northleafcapital.com"], "101")
    @then access_path_equals(["domain->org_id", "southridge.ca"], "102")
    @then access_path_equals(["creatio_id->org_id", "CRM-ORG-101"], "101")
    @then access_path_equals(["sku->item_id", "SKU-900"], "i-1")
    @then access_path_equals(["ext_id->event_id", "EXT-42"], "ev-1")

    @upon executing_dsl_transaction(fn db ->
            Xitdb.Ash.Tx.tx_for db,
                                [
                                  TestIndexedOrg,
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
    @then access_path_equals(["creatio_id->org_id", "CRM-ORG-101"], nil)
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
