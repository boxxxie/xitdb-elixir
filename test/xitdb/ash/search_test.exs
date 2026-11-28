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

  describe "index_records!/4" do
    alias Xitdb.Ash.SearchTest.{
      SearchRebuildAttrTenant,
      SearchRebuildDomain,
      SearchRebuildOrg,
      SearchRebuildProfile,
      SearchRebuildStore
    }

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

    test "incrementally indexes deferred batches into a populated store and handles updates, clears, and duplicates" do
      # Seed initial batch eagerly
      Ash.bulk_create!(
        [
          %{id: 1, name: "Northleaf Capital", mandate: "Infrastructure Credit"},
          %{id: 2, name: "HarbourVest Partners", mandate: "Private Equity"}
        ],
        SearchRebuildOrg,
        :create,
        domain: SearchRebuildDomain,
        return_records?: false
      )

      # Append a deferred batch with skip_search_index?: true
      %{records: appended} =
        Ash.bulk_create!(
          [
            %{id: 3, name: "Polar Asset Management", mandate: "Macro Credit"},
            %{id: 4, name: "Brookfield Credit", mandate: "Direct Lending"}
          ],
          SearchRebuildOrg,
          :create,
          domain: SearchRebuildDomain,
          return_records?: true,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      assert Search.ids(SearchRebuildOrg, "polar") == []

      :ok =
        Search.index_records!(SearchRebuildStore, SearchRebuildOrg, appended, assume_new?: true)

      assert Search.ids(SearchRebuildOrg, "polar") == [3]
      assert Search.ids(SearchRebuildOrg, "credit", limit: 10) |> Enum.sort() == [1, 3, 4]

      # Duplicate PKs keep the last occurrence, and clearing searchable text prunes emptied terms
      updated_1 = %SearchRebuildOrg{id: 1, name: "Northleaf Renamed", mandate: "Venture"}
      updated_1_final = %SearchRebuildOrg{id: 1, name: "Northleaf Final", mandate: nil}
      cleared_2 = %SearchRebuildOrg{id: 2, name: "---", mandate: nil}

      :ok =
        Search.index_records!(
          SearchRebuildStore,
          SearchRebuildOrg,
          [updated_1, updated_1_final, cleared_2],
          parallel: false
        )

      assert Search.ids(SearchRebuildOrg, "infrastructure") == []
      assert Search.ids(SearchRebuildOrg, "renamed") == []
      assert Search.ids(SearchRebuildOrg, "harbourvest") == []
      assert Search.ids(SearchRebuildOrg, "final") == [1]

      db = Xitdb.Ash.Store.current_db(SearchRebuildStore)
      meta = db["idx"]["search"]["sr_orgs"]["meta"]
      assert meta["doc_count"] == 3
      assert is_nil(db["idx"]["search"]["sr_orgs"]["docs"]["2"])
      assert is_nil(db["idx"]["search"]["sr_orgs"]["terms"]["harbourvest"])

      # Empty records list is a clean no-op
      assert :ok = Search.index_records!(SearchRebuildStore, SearchRebuildOrg, [])
    end

    test "supports parallel: true with worker_wrapper, attribute multitenancy, {db, moment}, %Xitdb{}, and read-only errors" do
      Ash.bulk_create!(
        [
          %{id: 1, name: "Northleaf Capital", mandate: "Infrastructure Credit"},
          %{id: 2, name: "HarbourVest Partners", mandate: "Private Equity"}
        ],
        SearchRebuildOrg,
        :create,
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

      %{records: profiles} =
        Ash.bulk_create!(profile_inputs, SearchRebuildProfile, :create,
          domain: SearchRebuildDomain,
          return_records?: true,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      parent = self()

      wrapper = fn cursor_root, work ->
        names =
          for {id_str, org_cur} <- Enum.to_list(cursor_root["sr_orgs"]), into: %{} do
            {String.to_integer(id_str), org_cur["name"]}
          end

        Process.put(:sr_org_cache, %{root: cursor_root, names: names})
        send(parent, {:index_wrapped_shard, self()})

        try do
          work.()
        after
          Process.delete(:sr_org_cache)
        end
      end

      :ok =
        Search.index_records!(SearchRebuildStore, SearchRebuildProfile, profiles,
          parallel: true,
          worker_wrapper: wrapper
        )

      assert_received {:index_wrapped_shard, _pid}
      assert Search.ids(SearchRebuildProfile, "quantum") == [42]
      assert 42 in Search.ids(SearchRebuildProfile, "northleaf", limit: 200)
      refute 41 in Search.ids(SearchRebuildProfile, "northleaf", limit: 200)

      # Attribute multitenancy
      %{records: t_a} =
        Ash.bulk_create!([%{id: 1, name: "Shared Alpha"}], SearchRebuildAttrTenant, :create,
          domain: SearchRebuildDomain,
          tenant: "tenant_a",
          return_records?: true,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      %{records: t_b} =
        Ash.bulk_create!([%{id: 2, name: "Shared Beta"}], SearchRebuildAttrTenant, :create,
          domain: SearchRebuildDomain,
          tenant: "tenant_b",
          return_records?: true,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      :ok =
        Search.index_records!(SearchRebuildStore, SearchRebuildAttrTenant, t_a,
          tenant: "tenant_a"
        )

      :ok =
        Search.index_records!(SearchRebuildStore, SearchRebuildAttrTenant, t_b,
          tenant: "tenant_b"
        )

      assert Search.ids(SearchRebuildAttrTenant, "shared", tenant: "tenant_a") == [1]
      assert Search.ids(SearchRebuildAttrTenant, "shared", tenant: "tenant_b") == [2]

      # %Xitdb{} and {db, moment} handles + read-only error unwrapping
      tmp = Path.join(System.tmp_dir!(), "xitdb_ro_idx_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      db_path = Path.join(tmp, "ro.xit")
      on_exit(fn -> File.rm_rf(tmp) end)

      {:ok, raw_db} = Xitdb.open(backend: :file, path: db_path)

      p1 = %SearchProfile{
        id: "p1",
        full_name: "Alice Smith",
        headline: "Principal",
        organization_id: nil
      }

      raw_db = Search.index_records!(raw_db, SearchProfile, [p1], parallel: false)
      assert Search.ids(SearchProfile, "alice", db: raw_db) == ["p1"]

      m = Xitdb.moment_count(raw_db) - 1
      p1_new = %{p1 | headline: "Partner"}
      {raw_db, m2} = Search.index_records!({raw_db, m}, SearchProfile, [p1_new], parallel: false)
      assert Search.ids(SearchProfile, "partner", db: Xitdb.as_of(raw_db, m2)) == ["p1"]
      assert Search.ids(SearchProfile, "principal", db: Xitdb.as_of(raw_db, m2)) == []
      assert :ok = Xitdb.close(raw_db)

      {:ok, ro_db} = Xitdb.open(backend: :file, path: db_path, read_only: true)

      try do
        err =
          assert_raise Xitdb.Error, fn ->
            Search.index_records!(ro_db, SearchProfile, [p1], parallel: false)
          end

        assert err.reason == :read_only
      after
        Xitdb.close(ro_db)
      end
    end

    test "covers query/2 defaults, empty query_text, sort_by_rank empty list, lookup_field resource & nil id, and parallel reindex with existing docs",
         %{db: db} do
      # Empty / punctuation-only query returns []
      assert Search.query(SearchProfile, "", db: db) == []
      assert Search.query(SearchProfile, "   !!!   ", db: db) == []
      assert Search.query(SearchProfile, nil, db: db) == []

      # sort_by_rank with empty list returns query unchanged
      q = Ash.Query.new(SearchProfile)
      assert Search.sort_by_rank(q, []) == q

      # lookup_field with nil id returns nil; with resource module resolves PK/collection
      assert Search.lookup_field(db, :organizations, nil, "name") == nil

      assert Search.lookup_field(db, :organizations, "org_1", "name") ==
               "Northleaf Capital Partners"

      assert Search.lookup_field(db, :organizations, "org_1", :name) ==
               "Northleaf Capital Partners"

      {:ok, db} =
        Xitdb.transact_ops(db, [
          {:put, ".search_profiles.p99.full_name", "Resource Lookup Test"}
        ])

      assert Search.lookup_field(db, SearchProfile, "p99", "full_name") == "Resource Lookup Test"

      # Parallel reindex (>= 128 records) with existing indexed docs (covers old_docs_map slice path)
      records =
        for i <- 1..130 do
          %SearchProfile{
            id: "par_#{i}",
            full_name: "Parallel Person #{i}",
            headline: "Analyst #{rem(i, 5)}",
            organization_id: nil
          }
        end

      db = Search.index_records!(db, SearchProfile, records, parallel: true)
      assert length(Search.ids(SearchProfile, "parallel", db: db, limit: 200)) == 130

      # Re-index same 130 records in parallel with updated headlines (old_docs_map non-empty)
      updated_records =
        Enum.map(records, fn r -> %{r | headline: "Director #{r.id}"} end)

      db = Search.index_records!(db, SearchProfile, updated_records, parallel: true)
      assert Search.ids(SearchProfile, "analyst", db: db) == []
      assert length(Search.ids(SearchProfile, "director", db: db, limit: 200)) == 130
    end

    test "hardens tx_mode cursor staging/overlay reads, {db, moment} indexing at moment >= 1, rebuild_index! parallel threshold, and tx_opts",
         %{db: db} do
      # 1. tx_mode: true cursor staging (put + update + delete + overlay read inside Xitdb.transact)
      p1 = %SearchProfile{
        id: "tx_1",
        full_name: "Alpha Stag",
        headline: "Founder",
        organization_id: nil
      }

      p2 = %SearchProfile{
        id: "tx_2",
        full_name: "Beta Stag",
        headline: "Engineer",
        organization_id: nil
      }

      {:ok, db} =
        Xitdb.transact(db, fn tx ->
          tx = Search.index_record(tx, SearchProfile, p1)
          tx = Search.index_record(tx, SearchProfile, p2)
          assert "tx_1" in Search.ids(SearchProfile, "alpha", db: tx)
          assert "tx_2" in Search.ids(SearchProfile, "beta", db: tx)

          tx = Search.remove_record(tx, SearchProfile, "tx_2")
          assert Search.ids(SearchProfile, "beta", db: tx) == []
          assert "tx_1" in Search.ids(SearchProfile, "alpha", db: tx)
          tx
        end)

      assert Search.ids(SearchProfile, "alpha", db: db) == ["tx_1"]
      assert Search.ids(SearchProfile, "beta", db: db) == []

      # 2. {db, moment} at moment >= 1 preserves moment >= 0 branch
      m = Xitdb.moment_count(db) - 1
      assert m >= 1

      p3 = %SearchProfile{
        id: "snap_3",
        full_name: "Gamma Snap",
        headline: "Advisor",
        organization_id: nil
      }

      {next_db, m2} = Search.index_records!({db, m}, SearchProfile, [p3], parallel: false)
      assert m2 > m
      assert Search.ids(SearchProfile, "gamma", db: Xitdb.as_of(next_db, m2)) == ["snap_3"]
      assert Search.ids(SearchProfile, "gamma", db: Xitdb.as_of(next_db, m)) == []

      # 3. rebuild_index! parallel threshold (< 128 runs sequentially on caller pid)
      parent = self()

      wrapper = fn _root, fun ->
        send(parent, {:worker_pid, self()})
        fun.()
      end

      small_db = Xitdb.open!()

      {:ok, small_db} =
        Xitdb.transact_ops(
          small_db,
          for i <- 1..10 do
            {:put, ".search_profiles.s_#{i}",
             %{"id" => "s_#{i}", "full_name" => "Small #{i}", "headline" => "Role"}}
          end
        )

      _ = Search.rebuild_index!(small_db, SearchProfile, parallel: true, worker_wrapper: wrapper)
      assert_received {:worker_pid, ^parent}

      # 4. empty doc in tx_context falls back to default reindex doc
      next_db2 =
        Xitdb.with_tx_context([doc: ""], fn ->
          Search.index_records!(next_db, SearchProfile, [p3], parallel: false)
        end)

      assert Xitdb.tx_meta!(next_db2)["doc"] == "reindex search search_profiles"
    end

    test "hardens prefix/exact Search.query inside tx_mode and on persisted db",
         %{db: db} do
      p1 = %SearchProfile{
        id: "rd_1",
        full_name: "Zephyr Alpha",
        headline: "Principal",
        organization_id: nil
      }

      db = Search.index_records!(db, SearchProfile, [p1], parallel: false)

      assert [{"rd_1", score}] = Search.query(SearchProfile, "zeph*", db: db)
      assert score > 0.0

      {:ok, db} =
        Xitdb.transact(db, fn tx ->
          Search.index_record(tx, SearchProfile, %{p1 | id: "rd_2", full_name: "Zephyr Beta"})
        end)

      assert "rd_1" in Search.ids(SearchProfile, "zephyr", db: db)
      assert "rd_2" in Search.ids(SearchProfile, "zephyr", db: db)
      assert Search.ids(SearchProfile, "beta", db: db) == ["rd_2"]

      # rebuild_index! on {db, moment} at moment >= 1 preserves moment >= 0 branch (kills L1273)
      {:ok, db} =
        Xitdb.transact_ops(db, [
          {:put, ".search_profiles.rd_2",
           %{"id" => "rd_2", "full_name" => "Zephyr Beta", "headline" => "Principal"}}
        ])

      m_cur = Xitdb.moment_count(db) - 1
      assert m_cur >= 1
      {rebuilt_db, m_rebuilt} = Search.rebuild_index!({db, m_cur}, SearchProfile, parallel: false)
      assert m_rebuilt > m_cur
      assert "rd_2" in Search.ids(SearchProfile, "beta", db: Xitdb.as_of(rebuilt_db, m_rebuilt))

      # rebuild_index! on :attribute multitenancy resource WITH actual records (kills L1309)
      %{records: [rt_rec]} =
        Ash.bulk_create!(
          [%{id: 99, name: "Rebuild Attr Tenant"}],
          SearchRebuildAttrTenant,
          :create,
          domain: SearchRebuildDomain,
          tenant: "tenant_rt",
          return_records?: true,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      :ok =
        Search.rebuild_index!(SearchRebuildStore, SearchRebuildAttrTenant,
          tenant: "tenant_rt",
          parallel: false
        )

      assert Search.ids(SearchRebuildAttrTenant, "rebuild", tenant: "tenant_rt") == [rt_rec.id]

      # index_records! with empty records does NOT bump Store moment (kills L332)
      m_before_empty = Xitdb.Ash.Store.root(SearchRebuildStore).moment

      :ok =
        Search.index_records!(SearchRebuildStore, SearchRebuildAttrTenant, [],
          tenant: "tenant_rt"
        )

      assert Xitdb.Ash.Store.root(SearchRebuildStore).moment == m_before_empty

      # remove_record followed by index_record on the SAME id inside tx_mode (kills L2065, L2151, L2271)
      p_readd = %SearchProfile{
        id: "readd_1",
        full_name: "Readd Token",
        headline: "Role",
        organization_id: nil
      }

      {:ok, db} =
        Xitdb.transact(db, fn tx ->
          tx = Search.index_record(tx, SearchProfile, p_readd)
          tx = Search.remove_record(tx, SearchProfile, "readd_1")
          tx = Search.index_record(tx, SearchProfile, p_readd)
          tx
        end)

      assert Search.ids(SearchProfile, "readd", db: db) == ["readd_1"]
    end
  end
end
