if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.IndexerAndSearchPropertiesTest do
    use Xitdb.AshCase
    use ExUnitProperties

    alias Spark.Error.DslError
    alias Xitdb.Ash.{Indexer, Search, Store}
    alias Xitdb.Ash.Search.Storage, as: SearchStorage
    alias Xitdb.TestSupport.{AgendaSession, MdmDomain, MdmStore, Organization}

    property "BM25 corpus doc_count and total_len never drift across arbitrary insert/update/delete streams" do
      vocab = ["polar", "asset", "macro", "credit", "quant", "infrastructure", "yield"]

      op_gen =
        one_of([
          tuple(
            {constant(:upsert), integer(1..6),
             list_of(member_of(vocab), min_length: 1, max_length: 5)}
          ),
          tuple({constant(:delete), integer(1..6)})
        ])

      check all(ops <- list_of(op_gen, min_length: 5, max_length: 25)) do
        :ok = Xitdb.Ash.TestSandbox.checkout([MdmStore])
        live_orgs = apply_search_ops(ops, %{})
        db = Store.current_db(MdmStore)

        stats = SearchStorage.read_corpus_stats(db, "organizations")
        assert stats.doc_count == map_size(live_orgs)

        # Deleting every remaining record restores corpus stats and term B+Tree to exact zero
        Enum.each(Map.values(live_orgs), &MdmDomain.destroy_organization!(&1))
        empty_db = Store.current_db(MdmStore)

        assert SearchStorage.read_corpus_stats(empty_db, "organizations") == %{
                 doc_count: 0,
                 total_len: 0
               }

        assert Search.ids(Organization, "polar macro credit", match: :any) == []
      end
    end

    test "destroying an Event purges nested AgendaSession _parent, identity, and BM25 search slots" do
      uid = System.unique_integer([:positive])

      org =
        MdmDomain.register_organization!(%{
          name: "Summit Host #{uid}",
          domain: "host-#{uid}.ca",
          slug: "host-#{uid}"
        })

      other_org =
        MdmDomain.register_organization!(%{
          name: "Other Host #{uid}",
          domain: "other-#{uid}.ca",
          slug: "other-#{uid}"
        })

      event =
        MdmDomain.schedule_event!(%{
          title: "Fall Allocators Forum",
          location_name: "Fairmont Queen Elizabeth",
          organizer_id: other_org.id
        })

      session =
        MdmDomain.add_session!(%{
          event_id: event.id,
          title: "Sovereign Wealth Co-Investments #{uid}",
          capacity: 45
        })

      # Direct O(log N) lookup by session ID without passing event_id
      assert MdmDomain.get_session!(session.id).title =~ "Sovereign Wealth"
      assert Search.ids(AgendaSession, "sovereign") == [session.id]

      # Parent `on_delete: :restrict` blocks deleting `other_org` while `event` exists
      assert_raise Ash.Error.Invalid, fn ->
        MdmDomain.destroy_organization!(other_org)
      end

      :ok = MdmDomain.destroy_event!(event)

      db = Store.current_db(MdmStore)
      assert Indexer.fetch_cursor(db, AgendaSession, session.id) == :none
      assert Search.ids(AgendaSession, "sovereign") == []

      # Destroying `event` releases the `on_delete: :restrict` constraint on `other_org`
      assert :ok = MdmDomain.destroy_organization!(other_org)
      assert :ok = MdmDomain.destroy_organization!(org)
    end

    test "VerifyNoSqlFragments rejects SQL fragment(...) calculations at compile time" do
      uid = System.unique_integer([:positive])
      res_mod = Module.concat(Xitdb.TestSupport, "InvalidFragmentResource#{uid}")

      # Spark runs verifiers in `@after_verify`, so errors surface as compiler diagnostics.
      {compiled, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string("""
          defmodule Xitdb.TestSupport.InvalidFragmentDomain#{uid} do
            use Ash.Domain, validate_config_inclusion?: false

            resources do
              resource Xitdb.TestSupport.InvalidFragmentResource#{uid}
            end
          end

          defmodule Xitdb.TestSupport.InvalidFragmentResource#{uid} do
            use Ash.Resource,
              domain: Xitdb.TestSupport.InvalidFragmentDomain#{uid},
              data_layer: Xitdb.Ash.DataLayer

            xitdb do
              store Xitdb.TestSupport.MdmStore
              collection :invalid_fragments
            end

            attributes do
              integer_primary_key :id
              attribute :city, :string
            end

            calculations do
              calculate :bad_loc, :string, expr(fragment("COALESCE(?, 'N/A')", city))
            end
          end
          """)
        end)

      assert Enum.any?(
               diagnostics,
               &(&1.message =~ ~r/SQL `fragment\(\.\.\.\)` .*is not supported/)
             )

      assert Enum.any?(compiled, fn {m, _} -> m == res_mod end)

      assert {:error, %DslError{message: msg}} =
               Xitdb.Ash.Verifiers.VerifyNoSqlFragments.verify(res_mod.spark_dsl_config())

      assert msg =~ ~r/SQL `fragment\(\.\.\.\)` .*is not supported/
    end

    test "VerifyCrossStoreReferences rejects on_delete cascades across distinct .xit stores" do
      uid = System.unique_integer([:positive])
      res_mod = Module.concat(Xitdb.TestSupport, "InvalidCrossStoreRef#{uid}")

      # Spark runs verifiers in `@after_verify`, so errors surface as compiler diagnostics.
      {compiled, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string("""
          defmodule Xitdb.TestSupport.InvalidCrossStoreDomain#{uid} do
            use Ash.Domain, validate_config_inclusion?: false

            resources do
              resource Xitdb.TestSupport.InvalidCrossStoreRef#{uid}
            end
          end

          defmodule Xitdb.TestSupport.InvalidCrossStoreRef#{uid} do
            use Ash.Resource,
              domain: Xitdb.TestSupport.InvalidCrossStoreDomain#{uid},
              data_layer: Xitdb.Ash.DataLayer

            xitdb do
              store Xitdb.TestSupport.AppStore
              collection :invalid_cross_refs

              references do
                reference :sender, on_delete: :delete
              end
            end

            attributes do
              integer_primary_key :id
            end

            relationships do
              belongs_to :sender, Xitdb.TestSupport.MemberProfile do
                domain Xitdb.TestSupport.MdmDomain
                attribute_type :integer
              end
            end
          end
          """)
        end)

      assert Enum.any?(
               diagnostics,
               &(&1.message =~ ~r/[Cc]ross-store .*`?on_delete: :delete`?/)
             )

      assert Enum.any?(compiled, fn {m, _} -> m == res_mod end)

      assert {:error, %DslError{message: msg}} =
               Xitdb.Ash.Verifiers.VerifyCrossStoreReferences.verify(res_mod.spark_dsl_config())

      assert msg =~ ~r/[Cc]ross-store .*`?on_delete: :delete`?/
    end

    defp apply_search_ops(ops, state) do
      uid = System.unique_integer([:positive])

      Enum.reduce(ops, state, fn
        {:upsert, slot, words}, acc ->
          phrase = Enum.join(words, " ")

          case Map.get(acc, slot) do
            nil ->
              org =
                MdmDomain.register_organization!(%{
                  name: phrase,
                  domain: "slot-#{slot}-#{uid}.ca",
                  slug: "slot-#{slot}-#{uid}",
                  mandate: phrase
                })

              Map.put(acc, slot, org)

            existing ->
              updated = MdmDomain.rename_organization!(existing, %{name: phrase, mandate: phrase})
              Map.put(acc, slot, updated)
          end

        {:delete, slot}, acc ->
          case Map.pop(acc, slot) do
            {nil, unchanged} ->
              unchanged

            {existing, rest} ->
              :ok = MdmDomain.destroy_organization!(existing)
              rest
          end
      end)
    end
  end
end
