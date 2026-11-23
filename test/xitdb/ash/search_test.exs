defmodule Xitdb.Ash.SearchTest do
  use ExUnit.Case, async: true

  alias Xitdb.Ash.Search
  alias Xitdb.TestSupport.AshFixtures.TestSearchProfile, as: SearchProfile

  setup do
    {:ok, db} = Xitdb.open(backend: :memory)

    # Seed an organization for resolver lookup testing
    org_ops = [
      {:put, ".organizations.org_1.name", "Northleaf Capital Partners"}
    ]

    {:ok, db} = Xitdb.transact_ops(db, org_ops)
    {:ok, db: db}
  end

  test "tokenize normalizes casing, splits unicode, and copies sub-binaries" do
    assert Search.tokenize("Alice M. Smith-Jones & Co.") == [
             "alice",
             "m",
             "smith",
             "jones",
             "co"
           ]

    assert Search.tokenize(nil) == []

    ci = Ash.CiString.new("Toronto, ON")
    assert Search.tokenize(ci) == ["toronto", "on"]
  end

  test "index_record populates idx.search with meta, docs, and B+Tree terms", %{db: db} do
    p1 = %SearchProfile{
      id: "p1",
      full_name: "Alice Smith",
      headline: "Managing Director",
      organization_id: "org_1"
    }

    db = Search.index_record(db, SearchProfile, p1)
    root = Xitdb.db(db)

    # Verify corpus statistics
    meta = root["idx"]["search"]["search_profiles"]["meta"]
    assert meta["doc_count"] == 1
    assert meta["total_len"] > 0

    # Verify document terms and length
    doc = root["idx"]["search"]["search_profiles"]["docs"]["p1"]
    assert doc["len"] == meta["total_len"]
    assert doc["terms"]["alice"] == 300
    assert doc["terms"]["managing"] == 100
    # From resolver on organization:
    assert doc["terms"]["northleaf"] == 200

    # Verify B+Tree terms mapping to postings
    terms = root["idx"]["search"]["search_profiles"]["terms"]
    assert terms["alice"]["p1"] == 300
    assert terms["northleaf"]["p1"] == 200
  end

  test "query and ids rank results by BM25 score with field boosting", %{db: db} do
    p1 = %SearchProfile{
      id: "p1",
      full_name: "Alice Capital",
      headline: "Senior Associate",
      organization_id: nil
    }

    p2 = %SearchProfile{
      id: "p2",
      full_name: "Bob Jones",
      headline: "Chief Capital Officer",
      organization_id: nil
    }

    db = Search.index_record(db, SearchProfile, p1)
    db = Search.index_record(db, SearchProfile, p2)

    # Query for "capital":
    # p1 has "capital" in full_name (boost 3.0 = weight 300)
    # p2 has "capital" in headline (boost 1.0 = weight 100)
    hits = Search.query(SearchProfile, "capital", db: db)
    assert length(hits) == 2

    [{id1, score1}, {id2, score2}] = hits
    assert id1 == "p1"
    assert id2 == "p2"
    assert score1 > score2

    assert Search.ids(SearchProfile, "capital", db: db) == ["p1", "p2"]
  end

  test "prefix search matches B+Tree prefix expansions", %{db: db} do
    p1 = %SearchProfile{
      id: "p1",
      full_name: "Alicia Vikander",
      headline: "Actress",
      organization_id: nil
    }

    p2 = %SearchProfile{
      id: "p2",
      full_name: "Alison Wonderland",
      headline: "DJ",
      organization_id: nil
    }

    p3 = %SearchProfile{
      id: "p3",
      full_name: "Bob Dylan",
      headline: "Musician",
      organization_id: nil
    }

    db = Search.index_record(db, SearchProfile, p1)
    db = Search.index_record(db, SearchProfile, p2)
    db = Search.index_record(db, SearchProfile, p3)

    hits = Search.ids(SearchProfile, "ali", db: db, prefix?: true, min_prefix_length: 3)
    assert "p1" in hits
    assert "p2" in hits
    refute "p3" in hits
  end

  test "updating a record diffs terms and preserves corpus statistics", %{db: db} do
    p1 = %SearchProfile{
      id: "p1",
      full_name: "Alice Smith",
      headline: "Associate",
      organization_id: nil
    }

    db = Search.index_record(db, SearchProfile, p1)

    # Update headline from "Associate" to "Vice President"
    p1_updated = %{p1 | headline: "Vice President"}
    db = Search.index_record(db, SearchProfile, p1_updated)

    root = Xitdb.db(db)
    meta = root["idx"]["search"]["search_profiles"]["meta"]
    assert meta["doc_count"] == 1

    # Old term "associate" is removed from terms
    terms = root["idx"]["search"]["search_profiles"]["terms"]
    assert is_nil(terms["associate"])

    # New terms are present
    assert terms["president"]["p1"] == 100

    # Old term does not return hits
    assert Search.ids(SearchProfile, "associate", db: db) == []
    assert Search.ids(SearchProfile, "president", db: db) == ["p1"]
  end

  test "remove_record cleans up docs and empty terms from index", %{db: db} do
    p1 = %SearchProfile{
      id: "p1",
      full_name: "Alice Smith",
      headline: "Associate",
      organization_id: nil
    }

    db = Search.index_record(db, SearchProfile, p1)
    assert Search.ids(SearchProfile, "alice", db: db) == ["p1"]

    db = Search.remove_record(db, SearchProfile, "p1")
    root = Xitdb.db(db)

    meta = root["idx"]["search"]["search_profiles"]["meta"]
    assert meta["doc_count"] == 0
    assert meta["total_len"] == 0

    assert is_nil(root["idx"]["search"]["search_profiles"]["docs"]["p1"])
    assert Search.ids(SearchProfile, "alice", db: db) == []
  end

  test "sort_by_rank orders Ash.Query via expression sort" do
    ash_query = Ash.Query.new(SearchProfile)
    sorted_query = Search.sort_by_rank(ash_query, ["p2", "p1"])

    assert [{expr_calc, :asc}] = sorted_query.sort
    assert is_struct(expr_calc)
  end

  test "query rejects negative as_of moment indexes", %{db: db} do
    assert_raise NimbleOptions.ValidationError, ~r/as_of/, fn ->
      Search.query(SearchProfile, "alice", db: db, as_of: -1)
    end
  end

  test "query rejects non-db values passed to :db" do
    assert_raise NimbleOptions.ValidationError, ~r/db/, fn ->
      Search.query(SearchProfile, "alice", db: MyApp.Store)
    end
  end

  test "ASCII fast-path tokenizer matches Unicode NFC regex path across ASCII and Unicode inputs" do
    unicode_ref = fn text ->
      valid = if String.valid?(text), do: text, else: String.replace_invalid(text)

      nfc =
        case :unicode.characters_to_nfc_binary(valid) do
          bin when is_binary(bin) -> bin
          {_, prefix, _} when is_binary(prefix) -> prefix
        end

      nfc
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    end

    samples = [
      "",
      "   ---___...@@@   ",
      "A",
      "Hello_World-2026! Foo+Bar/Baz",
      "VP, Northleaf Capital Partners (Toronto)",
      "a_b_c 123 XYZ",
      "Café Müller & Söhne",
      "résumé naïve façade №1 東京",
      <<0x41, 0xFF, 0x42>>
    ]

    for sample <- samples do
      assert Search.tokenize(sample) == unicode_ref.(sample)
    end
  end

  describe "rebuild_index!/3" do
    defmodule SearchRebuildStore do
      use Xitdb.Ash.Store
    end

    defmodule SearchRebuildOrg do
      use Ash.Resource,
        domain: Xitdb.Ash.SearchTest.SearchRebuildDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store SearchRebuildStore
        collection :sr_orgs
        search_field :name, boost: 4.0
        search_field :mandate, boost: 1.0
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
        attribute(:mandate, :string, public?: true)
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:id, :name, :mandate])
        end
      end
    end

    defmodule SearchRebuildProfile do
      use Ash.Resource,
        domain: Xitdb.Ash.SearchTest.SearchRebuildDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store SearchRebuildStore
        collection :sr_profiles
        search_field :full_name, boost: 4.0
        search_field :title, boost: 2.0

        search_field :firm_name,
          boost: 8.0,
          resolver: &__MODULE__.resolve_firm_name/2
      end

      attributes do
        attribute(:id, :integer,
          primary_key?: true,
          allow_nil?: false,
          generated?: true,
          writable?: true,
          public?: true
        )

        attribute(:full_name, :string, allow_nil?: false, public?: true)
        attribute(:title, :string, public?: true)
        attribute(:org_id, :integer, public?: true)
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:id, :full_name, :title, :org_id])
        end
      end

      def resolve_firm_name(record, db) do
        case Process.get(:sr_org_cache) do
          %{root: cached_root, names: names} when cached_root.moment == db.moment ->
            Map.get(names, record.org_id)

          _ ->
            with %{} = root <- Xitdb.Ash.Search.Storage.root_cursor(db),
                 %{} = orgs <- root["sr_orgs"],
                 %{} = org <- orgs[Integer.to_string(record.org_id || 0)] do
              org["name"]
            else
              _ -> nil
            end
        end
      end
    end

    defmodule SearchRebuildAttrTenant do
      use Ash.Resource,
        domain: Xitdb.Ash.SearchTest.SearchRebuildDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store SearchRebuildStore
        collection :sr_attr_tenants
        search_field :name, boost: 2.0
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org_id)
      end

      attributes do
        attribute(:id, :integer,
          primary_key?: true,
          allow_nil?: false,
          generated?: true,
          writable?: true,
          public?: true
        )

        attribute(:org_id, :string, allow_nil?: false, public?: true)
        attribute(:name, :string, allow_nil?: false, public?: true)
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:id, :org_id, :name])
        end
      end
    end

    defmodule SearchRebuildDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(SearchRebuildOrg)
        resource(SearchRebuildProfile)
        resource(SearchRebuildAttrTenant)
      end
    end

    setup do
      {:ok, pid} =
        Xitdb.Ash.Store.start_link(
          name: SearchRebuildStore,
          path: :memory,
          domains: [SearchRebuildDomain]
        )

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      :ok
    end

    test "rebuilds deferred search index on Store in parallel with worker_wrapper and on %Xitdb{} / {db, moment}" do
      org_inputs = [
        %{id: 1, name: "Northleaf Capital", mandate: "Infrastructure Credit"},
        %{id: 2, name: "HarbourVest Partners", mandate: "Private Equity"}
      ]

      Ash.bulk_create!(org_inputs, SearchRebuildOrg, :create,
        domain: SearchRebuildDomain,
        context: %{xitdb: %{skip_search_index?: true}}
      )

      profile_inputs =
        for i <- 1..150 do
          %{
            id: i,
            full_name: if(i == 42, do: "Zara Quantum", else: "Member #{i}"),
            title: if(i <= 2, do: "Managing Director", else: "Associate"),
            org_id: if(rem(i, 2) == 0, do: 1, else: 2)
          }
        end

      Ash.bulk_create!(profile_inputs, SearchRebuildProfile, :create,
        domain: SearchRebuildDomain,
        context: %{xitdb: %{skip_search_index?: true}}
      )

      # Search was deferred during bulk_create!
      assert Search.ids(SearchRebuildOrg, "northleaf") == []
      assert Search.ids(SearchRebuildProfile, "quantum") == []

      parent = self()

      :ok = Search.rebuild_index!(SearchRebuildStore, SearchRebuildOrg, parallel: true)
      assert Search.ids(SearchRebuildOrg, "northleaf") == [1]
      assert Search.ids(SearchRebuildOrg, "harbourvest") == [2]

      wrapper = fn cursor_root, work ->
        names =
          for {id_str, org_cur} <- Enum.to_list(cursor_root["sr_orgs"]), into: %{} do
            {String.to_integer(id_str), org_cur["name"]}
          end

        Process.put(:sr_org_cache, %{root: cursor_root, names: names})
        send(parent, {:wrapped_shard, self()})

        try do
          work.()
        after
          Process.delete(:sr_org_cache)
        end
      end

      :ok =
        Search.rebuild_index!(SearchRebuildStore, SearchRebuildProfile,
          parallel: true,
          only_attrs: [:full_name, :title, :org_id],
          worker_wrapper: wrapper
        )

      assert_received {:wrapped_shard, _pid}
      assert Search.ids(SearchRebuildProfile, "quantum") == [42]
      assert 42 in Search.ids(SearchRebuildProfile, "northleaf", limit: 200)
      refute 41 in Search.ids(SearchRebuildProfile, "northleaf", limit: 200)

      assert Search.ids(SearchRebuildProfile, "harbourvest", limit: 200) |> Enum.sort() ==
               Enum.filter(1..150, &(rem(&1, 2) == 1))

      # Also verify %Xitdb{} and {db, moment} entrypoints + empty corpus cleanup
      {:ok, raw_db} = Xitdb.open(backend: :memory)

      {:ok, raw_db} =
        Xitdb.transact_ops(raw_db, [
          {:put, ".organizations.org_1.name", "Northleaf Capital Partners"}
        ])

      p1 = %SearchProfile{
        id: "p1",
        full_name: "Alice Smith",
        headline: "Principal",
        organization_id: "org_1"
      }

      {:ok, raw_db} =
        Xitdb.Ash.Indexer.put_record(
          raw_db,
          SearchProfile,
          nil,
          p1
        )

      raw_db = Search.rebuild_index!(raw_db, SearchProfile, parallel: false)
      assert Search.ids(SearchProfile, "northleaf", db: raw_db) == ["p1"]

      m = Xitdb.moment_count(raw_db) - 1

      {:ok, raw_db, m2} =
        Xitdb.transact_ops_with_moment(raw_db, [{:rm, ".search_profiles.p1"}], base_moment: m)

      {raw_db, m3} = Search.rebuild_index!({raw_db, m2}, SearchProfile)
      assert Search.ids(SearchProfile, "northleaf", db: Xitdb.as_of(raw_db, m3)) == []
      assert is_nil(Xitdb.as_of(raw_db, m3)["idx"]["search"]["search_profiles"])
      assert :ok = Xitdb.close(raw_db)
    end

    test "rebuild_index!/3 preserves all tenants on :attribute-multitenant resources" do
      Ash.bulk_create!(
        [%{id: 1, name: "Shared Alpha"}],
        SearchRebuildAttrTenant,
        :create,
        domain: SearchRebuildDomain,
        tenant: "tenant_a",
        context: %{xitdb: %{skip_search_index?: true}}
      )

      Ash.bulk_create!(
        [%{id: 2, name: "Shared Beta"}],
        SearchRebuildAttrTenant,
        :create,
        domain: SearchRebuildDomain,
        tenant: "tenant_b",
        context: %{xitdb: %{skip_search_index?: true}}
      )

      assert Search.ids(SearchRebuildAttrTenant, "shared", tenant: "tenant_a") == []
      assert Search.ids(SearchRebuildAttrTenant, "shared", tenant: "tenant_b") == []

      :ok = Search.rebuild_index!(SearchRebuildStore, SearchRebuildAttrTenant, parallel: false)

      assert Search.ids(SearchRebuildAttrTenant, "shared", tenant: "tenant_a") == [1]
      assert Search.ids(SearchRebuildAttrTenant, "shared", tenant: "tenant_b") == [2]

      # Rebuilding with a specific :tenant option must not wipe other tenants from the shared index
      :ok =
        Search.rebuild_index!(
          SearchRebuildStore,
          SearchRebuildAttrTenant,
          tenant: "tenant_a",
          parallel: false
        )

      assert Search.ids(SearchRebuildAttrTenant, "shared", tenant: "tenant_a") == [1]
      assert Search.ids(SearchRebuildAttrTenant, "shared", tenant: "tenant_b") == [2]
    end

    test "rebuild_index!/3 raises unwrapped Xitdb.Error on read-only commit failure" do
      tmp = Path.join(System.tmp_dir!(), "xitdb_ro_search_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      db_path = Path.join(tmp, "ro.xit")
      on_exit(fn -> File.rm_rf(tmp) end)

      {:ok, rw_db} = Xitdb.open(backend: :file, path: db_path)

      p1 = %SearchProfile{
        id: "p1",
        full_name: "Alice Smith",
        headline: "Principal",
        organization_id: nil
      }

      {:ok, rw_db} = Xitdb.Ash.Indexer.put_record(rw_db, SearchProfile, nil, p1)
      :ok = Xitdb.close(rw_db)

      {:ok, ro_db} = Xitdb.open(backend: :file, path: db_path, read_only: true)

      try do
        err =
          assert_raise Xitdb.Error, fn ->
            Search.rebuild_index!(ro_db, SearchProfile, parallel: false)
          end

        assert err.reason == :read_only
      after
        Xitdb.close(ro_db)
      end
    end
  end
end
