if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.IndexerAndSearchPropertiesTest do
    use Xitdb.AshCase
    use ExUnitProperties

    require Ash.Query

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

    property "Search.rebuild_index!/3 (parallel: false and true) matches incremental search index across arbitrary streams" do
      vocab = ["polar", "asset", "macro", "credit", "quant", "infrastructure", "yield"]

      op_gen =
        one_of([
          tuple(
            {constant(:upsert), integer(1..8),
             list_of(member_of(vocab), min_length: 1, max_length: 6)}
          ),
          tuple({constant(:delete), integer(1..8)})
        ])

      check all(ops <- list_of(op_gen, min_length: 5, max_length: 25), max_runs: 40) do
        :ok = Xitdb.Ash.TestSandbox.checkout([MdmStore])
        _live_orgs = apply_search_ops(ops, %{})
        db_before = Store.current_db(MdmStore)
        stats_before = SearchStorage.read_corpus_stats(db_before, "organizations")

        terms_before =
          case db_before["idx"]["search"]["organizations"] do
            %Xitdb.Cursor{} = sc -> Xitdb.materialize(sc["terms"])
            _ -> %{}
          end

        queries = ["polar", "macro credit", "pol", "infra yield"]

        scores_before =
          Map.new(queries, fn q ->
            {q, Search.query(Organization, q, match: :any, limit: 20)}
          end)

        for parallel? <- [false, true] do
          :ok = Search.rebuild_index!(MdmStore, Organization, parallel: parallel?)
          db_after = Store.current_db(MdmStore)
          assert SearchStorage.read_corpus_stats(db_after, "organizations") == stats_before

          terms_after =
            case db_after["idx"]["search"]["organizations"] do
              %Xitdb.Cursor{} = sc -> Xitdb.materialize(sc["terms"])
              _ -> %{}
            end

          assert terms_after == terms_before

          for q <- queries do
            hits_before = Map.fetch!(scores_before, q)
            hits_after = Search.query(Organization, q, match: :any, limit: 20)
            assert length(hits_after) == length(hits_before)

            for {{id_b, sc_b}, {id_a, sc_a}} <- Enum.zip(hits_before, hits_after) do
              assert id_a == id_b
              assert_in_delta sc_a, sc_b, 1.0e-9
            end
          end
        end
      end
    end

    defmodule PropStore do
      use Xitdb.Ash.Store
    end

    defmodule PropOrg do
      use Ash.Resource,
        domain: Xitdb.Ash.IndexerAndSearchPropertiesTest.PropDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store PropStore
        collection :prop_orgs
        index([:sector])
        search_field(:name, boost: 2.0)
        search_field(:mandate, boost: 1.0)
      end

      attributes do
        attribute(:id, :integer,
          primary_key?: true,
          allow_nil?: false,
          generated?: true,
          writable?: true,
          public?: true
        )

        attribute(:name, :string, allow_nil?: false, public?: true)
        attribute(:slug, :string, allow_nil?: false, public?: true)
        attribute(:sector, :string, allow_nil?: false, public?: true)
        attribute(:mandate, :string, public?: true)
      end

      identities do
        identity(:unique_slug, [:slug])
      end

      actions do
        defaults([:read, :destroy])

        create :register do
          primary?(true)
          accept([:id, :name, :slug, :sector, :mandate])
        end
      end
    end

    defmodule PropDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource PropOrg do
          define(:register_prop_org, action: :register)
        end
      end
    end

    property "coalesced Ash.bulk_create! across initial and populated-table append matches sequential Ash.create!" do
      vocab = ["polar", "asset", "macro", "credit", "quant", "yield"]
      sectors = ["tech", "finance", "health"]

      row_gen =
        gen all(
              explicit_pk? <- boolean(),
              name_words <- list_of(member_of(vocab), min_length: 1, max_length: 3),
              mandate_words <- list_of(member_of(vocab), min_length: 0, max_length: 3),
              sector <- member_of(sectors),
              suffix <- integer(1..10_000)
            ) do
          {explicit_pk?, Enum.join(name_words, " "), sector,
           if(mandate_words == [], do: nil, else: Enum.join(mandate_words, " ")), suffix}
        end

      check all(
              batch1 <- list_of(row_gen, min_length: 1, max_length: 8),
              batch2 <- list_of(row_gen, min_length: 1, max_length: 8),
              max_runs: 30
            ) do
        uid = System.unique_integer([:positive])

        to_inputs = fn rows, tag ->
          rows
          |> Enum.with_index(1)
          |> Enum.map(fn {{explicit_pk?, name, sector, mandate, suffix}, idx} ->
            base = %{
              name: "#{name} #{uid}-#{tag}-#{idx}",
              slug: "#{tag}-#{idx}-#{suffix}-#{uid}",
              sector: sector,
              mandate: mandate
            }

            if explicit_pk? do
              Map.put(base, :id, 100 + idx + if(tag == :b2, do: 50, else: 0))
            else
              base
            end
          end)
        end

        inputs1 = to_inputs.(batch1, :b1)
        inputs2 = to_inputs.(batch2, :b2)

        # Sequential Ash.create! reference
        {seq_all, seq_sector, seq_slug, seq_search} =
          with_prop_store(fn ->
            _s1 = Enum.map(inputs1, &PropDomain.register_prop_org!/1)
            _s2 = Enum.map(inputs2, &PropDomain.register_prop_org!/1)

            all =
              PropOrg
              |> Ash.read!(domain: PropDomain)
              |> Enum.sort_by(& &1.slug)

            slug_by_id = Map.new(all, &{&1.id, &1.slug})

            sec =
              PropOrg
              |> Ash.Query.filter(sector == ^hd(inputs2).sector)
              |> Ash.read!(domain: PropDomain)
              |> Enum.sort_by(& &1.slug)

            slg =
              PropOrg
              |> Ash.Query.filter(slug == ^hd(inputs2).slug)
              |> Ash.read!(domain: PropDomain)

            srch =
              PropOrg
              |> Search.query("polar macro", match: :any, limit: 50)
              |> Enum.map(fn {id, sc} -> {Map.fetch!(slug_by_id, id), Float.round(sc, 6)} end)
              |> Enum.sort_by(fn {slug, sc} -> {-sc, slug} end)

            {all, sec, slg, srch}
          end)

        # Coalesced Ash.bulk_create! across two commits (empty -> populated append)
        with_prop_store(fn ->
          res1 =
            Ash.bulk_create!(inputs1, PropOrg, :register,
              domain: PropDomain,
              batch_size: 50,
              return_records?: true
            )

          res2 =
            Ash.bulk_create!(inputs2, PropOrg, :register,
              domain: PropDomain,
              batch_size: 50,
              return_records?: true
            )

          assert res1.status == :success
          assert res2.status == :success
          all_ids = Enum.map(res1.records ++ res2.records, & &1.id)
          assert length(Enum.uniq(all_ids)) == length(inputs1) + length(inputs2)

          bulk_all =
            PropOrg
            |> Ash.read!(domain: PropDomain)
            |> Enum.sort_by(& &1.slug)

          bulk_slug_by_id = Map.new(bulk_all, &{&1.id, &1.slug})
          take_fields = &Map.take(&1, [:name, :slug, :sector, :mandate])
          assert Enum.map(bulk_all, take_fields) == Enum.map(seq_all, take_fields)

          bulk_sector =
            PropOrg
            |> Ash.Query.filter(sector == ^hd(inputs2).sector)
            |> Ash.read!(domain: PropDomain)
            |> Enum.sort_by(& &1.slug)

          assert Enum.map(bulk_sector, take_fields) == Enum.map(seq_sector, take_fields)

          bulk_slug =
            PropOrg
            |> Ash.Query.filter(slug == ^hd(inputs2).slug)
            |> Ash.read!(domain: PropDomain)

          assert Enum.map(bulk_slug, take_fields) == Enum.map(seq_slug, take_fields)

          bulk_search =
            PropOrg
            |> Search.query("polar macro", match: :any, limit: 50)
            |> Enum.map(fn {id, sc} -> {Map.fetch!(bulk_slug_by_id, id), Float.round(sc, 6)} end)
            |> Enum.sort_by(fn {slug, sc} -> {-sc, slug} end)

          assert bulk_search == seq_search
        end)
      end
    end

    property "Search.index_records!/4 (parallel: false and true) across deferred creates, appends, and overwrites matches rebuild_index!/3" do
      vocab = ["polar", "asset", "macro", "credit", "quant", "yield"]

      row_gen =
        gen all(
              name_words <- list_of(member_of(vocab), min_length: 1, max_length: 3),
              mandate_words <- list_of(member_of(vocab), min_length: 0, max_length: 3)
            ) do
          {Enum.join(name_words, " "),
           if(mandate_words == [], do: nil, else: Enum.join(mandate_words, " "))}
        end

      check all(
              batch1 <- list_of(row_gen, min_length: 2, max_length: 8),
              batch2 <- list_of(row_gen, min_length: 2, max_length: 8),
              overwrite <- list_of(row_gen, min_length: 1, max_length: 4),
              parallel? <- boolean(),
              max_runs: 25
            ) do
        uid = System.unique_integer([:positive])

        to_inputs = fn rows, offset ->
          rows
          |> Enum.with_index(offset)
          |> Enum.map(fn {{name, mandate}, id} ->
            %{
              id: id,
              name: name,
              slug: "idx-#{id}-#{uid}",
              sector: "tech",
              mandate: mandate
            }
          end)
        end

        inputs1 = to_inputs.(batch1, 1)
        inputs2 = to_inputs.(batch2, length(batch1) + 1)
        overwrite_inputs = to_inputs.(overwrite, 1)

        with_prop_store(fn ->
          %{records: r1} =
            Ash.bulk_create!(inputs1, PropOrg, :register,
              domain: PropDomain,
              batch_size: 50,
              return_records?: true,
              context: %{xitdb: %{skip_search_index?: true}}
            )

          :ok =
            Search.index_records!(PropStore, PropOrg, r1,
              parallel: parallel?,
              assume_new?: true
            )

          %{records: r2} =
            Ash.bulk_create!(inputs2, PropOrg, :register,
              domain: PropDomain,
              batch_size: 50,
              return_records?: true,
              context: %{xitdb: %{skip_search_index?: true}}
            )

          :ok = Search.index_records!(PropStore, PropOrg, r2, parallel: parallel?)

          %{records: r3} =
            Ash.bulk_create!(overwrite_inputs, PropOrg, :register,
              domain: PropDomain,
              batch_size: 50,
              return_records?: true,
              context: %{xitdb: %{allow_existing_cursor?: true, skip_search_index?: true}}
            )

          :ok = Search.index_records!(PropStore, PropOrg, r3, parallel: parallel?)

          db_inc = Store.current_db(PropStore)
          meta_inc = SearchStorage.read_corpus_stats(db_inc, "prop_orgs")

          terms_inc =
            case db_inc["idx"]["search"]["prop_orgs"] do
              %Xitdb.Cursor{} = sc -> Xitdb.materialize(sc["terms"])
              _ -> %{}
            end

          queries = ["polar", "macro credit", "pol", "quant yield"]

          scores_inc =
            Map.new(queries, fn q ->
              {q, Search.query(PropOrg, q, match: :any, limit: 20)}
            end)

          :ok = Search.rebuild_index!(PropStore, PropOrg, parallel: parallel?)
          db_reb = Store.current_db(PropStore)
          assert SearchStorage.read_corpus_stats(db_reb, "prop_orgs") == meta_inc

          terms_reb =
            case db_reb["idx"]["search"]["prop_orgs"] do
              %Xitdb.Cursor{} = sc -> Xitdb.materialize(sc["terms"])
              _ -> %{}
            end

          assert terms_reb == terms_inc

          for q <- queries do
            hits_inc = Map.fetch!(scores_inc, q)
            hits_reb = Search.query(PropOrg, q, match: :any, limit: 20)
            assert length(hits_reb) == length(hits_inc)

            for {{id_i, sc_i}, {id_r, sc_r}} <- Enum.zip(hits_inc, hits_reb) do
              assert id_r == id_i
              assert_in_delta sc_r, sc_i, 1.0e-9
            end
          end
        end)
      end
    end

    defp with_prop_store(fun) do
      {:ok, pid} = Store.start_link(name: PropStore, path: :memory, domains: [PropDomain])

      try do
        fun.()
      after
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
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
