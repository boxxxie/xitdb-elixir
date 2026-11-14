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
end
