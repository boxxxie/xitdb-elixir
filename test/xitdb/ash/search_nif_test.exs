defmodule Xitdb.Ash.SearchNifTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xitdb.Ash.Search
  alias Xitdb.Ash.Search.Storage
  alias Xitdb.Ash.TestSandbox
  alias Xitdb.TestSupport.{AppStore, MdmDomain, MdmStore, Organization}

  defmodule IntDoc do
    use Ash.Resource,
      domain: Xitdb.Ash.SearchNifTest.Domain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store Xitdb.Ash.SearchNifTest.DummyStore
      collection :int_docs
      search_field :title, boost: 2.0
      search_field :body, boost: 0.75
    end

    attributes do
      attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
      attribute(:title, :string, public?: true)
      attribute(:body, :string, public?: true)
    end
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(IntDoc)
    end
  end

  test "nif_sorted_map_seek/5 returns lazy cursor tuples and lookahead continuation key" do
    {:ok, db} = Xitdb.open(backend: :memory)

    db =
      Enum.reduce(
        [
          %IntDoc{id: 1, title: "capital alpha", body: "cap"},
          %IntDoc{id: 2, title: "captain beta", body: "capstone"},
          %IntDoc{id: 10, title: "capture gamma", body: "delta"}
        ],
        db,
        &Search.index_record(&2, IntDoc, &1)
      )

    {entries, next_key} = Storage.scan_prefix_cursors(db, "int_docs", "cap", 2)
    assert Enum.map(entries, &elem(&1, 0)) == ["cap", "capital"]
    assert Enum.all?(entries, fn {_term, cur} -> match?(%Xitdb.Cursor{}, cur) end)
    assert next_key == "capstone"

    {rest, exhausted} = Storage.scan_prefix_cursors(db, "int_docs", next_key, 10)
    assert Enum.map(rest, &elem(&1, 0)) == ["capstone"]
    assert exhausted == nil

    # Arity-6 with prefix_only: false continues past the initial prefix boundary
    btree = Xitdb.db(db)["idx"]["search"]["int_docs"]["terms"]

    assert {:ok, all_after_cap, nil} =
             Xitdb.NIF.nif_sorted_map_seek(
               btree.db_ref,
               btree.tag_id,
               btree.value,
               "cap",
               20,
               false
             )

    assert Enum.all?(all_after_cap, fn
             {term, tag_id, slot_val}
             when is_binary(term) and is_integer(tag_id) and is_integer(slot_val) ->
               Xitdb.Cursor.tag_atom_for(tag_id) in [:hash_map, :counted_hash_map]

             _ ->
               false
           end)

    terms = Enum.map(all_after_cap, &elem(&1, 0))
    assert "cap" in terms
    assert "delta" in terms
    assert "gamma" in terms
  end

  test "nif_sorted_map_seek/5,6 packs containers as 3-tuples and scalars as 2-tuples" do
    {:ok, db} = Xitdb.open(backend: :memory)

    {:ok, db} =
      Xitdb.transact(db, %{
        "containers" =>
          Xitdb.sorted_map(%{
            "k1" => Xitdb.counted_map(%{"a" => 10, "b" => 20}),
            "k2" => Xitdb.counted_set(["doc_1", "doc_2"])
          }),
        "scalars" =>
          Xitdb.sorted_map(%{
            "s1" => 42,
            "s2" => "hello",
            "s3" => 3.5,
            "s4" => true
          })
      })

    root = Xitdb.db(db)
    c_btree = root["containers"]
    s_btree = root["scalars"]

    assert {:ok, [{"k1", 12, k1_val}, {"k2", 13, k2_val}], nil} =
             Xitdb.NIF.nif_sorted_map_seek(c_btree.db_ref, c_btree.tag_id, c_btree.value, "k", 10)

    assert {:ok, k1_entries} = Xitdb.NIF.nif_slot_entries(c_btree.db_ref, 12, k1_val, 0, -1)
    assert Enum.sort(k1_entries) == [{"a", 10}, {"b", 20}]

    assert {:ok, k2_entries} = Xitdb.NIF.nif_slot_entries(c_btree.db_ref, 13, k2_val, 0, -1)
    assert Enum.sort(k2_entries) == ["doc_1", "doc_2"]

    assert {:ok, [{"s1", 42}, {"s2", "hello"}, {"s3", 3.5}, {"s4", true}], nil} =
             Xitdb.NIF.nif_sorted_map_seek(s_btree.db_ref, s_btree.tag_id, s_btree.value, "s", 10)

    # Also verify Storage.scan_prefix_cursors/4 and Storage.scan_prefix/5 on search terms
    {:ok, search_db} = Xitdb.open(backend: :memory)

    search_db =
      Enum.reduce(
        [
          %IntDoc{id: 1, title: "capital alpha", body: "cap"},
          %IntDoc{id: 2, title: "captain beta", body: "capstone"}
        ],
        search_db,
        &Search.index_record(&2, IntDoc, &1)
      )

    {cursor_entries, next_key} = Storage.scan_prefix_cursors(search_db, "int_docs", "cap", 2)
    assert next_key == "capstone"

    assert [{"cap", %Xitdb.Cursor{} = cap_cur}, {"capital", %Xitdb.Cursor{} = capital_cur}] =
             cursor_entries

    assert Map.new(cap_cur) == %{"1" => 75}
    assert Map.new(capital_cur) == %{"1" => 200}

    scanned = Storage.scan_prefix(search_db, "int_docs", "cap", 10, :nif)
    assert Enum.map(scanned, &elem(&1, 0)) == ["cap", "capital", "capstone", "captain"]
    assert Enum.find(scanned, &(elem(&1, 0) == "capstone")) == {"capstone", [{"2", 75}]}
  end

  test "honors Xitdb.as_of/2 historical moments and UTF-8 doc_key tie-breaking on integer PKs" do
    {:ok, db} = Xitdb.open(backend: :memory)

    # Identical content on IDs 2 and 10 -> identical BM25 scores; "10" < "2" in UTF-8 bytes
    db = Search.index_record(db, IntDoc, %IntDoc{id: 2, title: "nordic Zürich", body: "fond"})
    db = Search.index_record(db, IntDoc, %IntDoc{id: 10, title: "nordic Zürich", body: "fond"})
    snap_before_delete = Xitdb.as_of(db, -1)

    db = Search.remove_record(db, IntDoc, 10)

    assert Search.ids(IntDoc, "zür", db: snap_before_delete, backend: :nif) == [10, 2]
    assert Search.ids(IntDoc, "zür", db: snap_before_delete, backend: :elixir) == [10, 2]
    assert Search.ids(IntDoc, "zür", db: db, backend: :nif) == [2]
  end

  test "supports custom :exact_boost and :prefix_weight identically across backends" do
    {:ok, db} = Xitdb.open(backend: :memory)

    db =
      Enum.reduce(
        [
          %IntDoc{id: 1, title: "cap fund", body: "overview"},
          %IntDoc{id: 2, title: "capital capital fund", body: "overview"}
        ],
        db,
        &Search.index_record(&2, IntDoc, &1)
      )

    opts = [
      db: db,
      prefix?: true,
      exact_boost: 3.0,
      prefix_weight: 0.25,
      match: :any
    ]

    nif_hits = Search.query(IntDoc, "cap", Keyword.put(opts, :backend, :nif))
    ex_hits = Search.query(IntDoc, "cap", Keyword.put(opts, :backend, :elixir))

    assert Enum.map(nif_hits, &elem(&1, 0)) == [1, 2]
    assert Enum.map(ex_hits, &elem(&1, 0)) == [1, 2]

    Enum.zip(nif_hits, ex_hits)
    |> Enum.each(fn {{id_a, score_a}, {id_b, score_b}} ->
      assert id_a == id_b
      assert_in_delta score_a, score_b, 1.0e-5
    end)
  end

  test "honors TestSandbox concurrent snapshot isolation under backend: :nif" do
    parent = self()
    uid = System.unique_integer([:positive])
    token_a = "sandboxalphatok#{uid}"
    token_b = "sandboxbetatok#{uid}"

    task_a =
      Task.async(fn ->
        :ok = TestSandbox.checkout([MdmStore, AppStore])

        org =
          MdmDomain.register_organization!(
            %{
              name: "SandboxAlpha Capital",
              domain: "sandbox-alpha-#{uid}.example",
              slug: "sandbox-alpha-#{uid}",
              mandate: token_a
            },
            authorize?: false
          )

        send(parent, {:ready, :a})

        receive do
          :proceed -> :ok
        end

        {org.id, Search.ids(Organization, token_a, backend: :nif),
         Search.ids(Organization, token_b, backend: :nif)}
      end)

    task_b =
      Task.async(fn ->
        :ok = TestSandbox.checkout([MdmStore, AppStore])

        _filler =
          MdmDomain.register_organization!(
            %{
              name: "SandboxFiller Org",
              domain: "sandbox-filler-#{uid}.example",
              slug: "sandbox-filler-#{uid}",
              mandate: "unrelated"
            },
            authorize?: false
          )

        org =
          MdmDomain.register_organization!(
            %{
              name: "SandboxBeta Ventures",
              domain: "sandbox-beta-#{uid}.example",
              slug: "sandbox-beta-#{uid}",
              mandate: token_b
            },
            authorize?: false
          )

        send(parent, {:ready, :b})

        receive do
          :proceed -> :ok
        end

        {org.id, Search.ids(Organization, token_b, backend: :nif),
         Search.ids(Organization, token_a, backend: :nif)}
      end)

    assert_receive {:ready, :a}, 5_000
    assert_receive {:ready, :b}, 5_000
    send(task_a.pid, :proceed)
    send(task_b.pid, :proceed)

    {id_a, own_a, cross_a} = Task.await(task_a, 5_000)
    {id_b, own_b, cross_b} = Task.await(task_b, 5_000)

    assert id_a != id_b
    assert own_a == [id_a]
    assert cross_a == []
    assert own_b == [id_b]
    assert cross_b == []
  end

  property "backend: :nif matches backend: :elixir within 1.0e-5 across randomized corpora & params" do
    vocab = ["cap", "capital", "captain", "zürich", "über", "东京", "market", "fund", "equity"]

    doc_gen =
      tuple({
        integer(1..40),
        list_of(member_of(vocab), min_length: 0, max_length: 6),
        list_of(member_of(vocab), min_length: 0, max_length: 8)
      })

    check all(
            docs <- list_of(doc_gen, min_length: 0, max_length: 25),
            q_words <- list_of(member_of(vocab), min_length: 1, max_length: 3),
            match_mode <- member_of([:all, :any]),
            prefix? <- boolean(),
            max_exp <- integer(1..8),
            limit <- integer(1..15),
            k1 <- float(min: 0.5, max: 2.0),
            b <- float(min: 0.0, max: 1.0),
            exact_boost <- float(min: 1.0, max: 2.5),
            prefix_weight <- float(min: 0.25, max: 1.5),
            max_runs: 60
          ) do
      {:ok, db} = Xitdb.open(backend: :memory)

      db =
        Enum.reduce(docs, db, fn {id, t_words, b_words}, acc ->
          rec = %IntDoc{id: id, title: Enum.join(t_words, " "), body: Enum.join(b_words, " ")}
          Search.index_record(acc, IntDoc, rec)
        end)

      q = Enum.join(q_words, " ")

      common_opts = [
        db: db,
        match: match_mode,
        prefix?: prefix?,
        max_prefix_expansions: max_exp,
        limit: limit,
        k1: k1,
        b: b,
        exact_boost: exact_boost,
        prefix_weight: prefix_weight
      ]

      nif_hits = Search.query(IntDoc, q, Keyword.put(common_opts, :backend, :nif))
      ex_hits = Search.query(IntDoc, q, Keyword.put(common_opts, :backend, :elixir))

      assert Enum.map(nif_hits, &elem(&1, 0)) == Enum.map(ex_hits, &elem(&1, 0))

      Enum.zip(nif_hits, ex_hits)
      |> Enum.each(fn {{id_a, score_a}, {id_b, score_b}} ->
        assert id_a == id_b
        assert_in_delta score_a, score_b, 1.0e-5
      end)
    end
  end

  test "nif_sorted_map_seek/7 fuses child container entry decoding while 6-arity/false returns lazy slots" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "btree" =>
          Xitdb.sorted_map(%{
            "k10" => Xitdb.counted_set(["d1", "d2"]),
            "k11" => Xitdb.counted_map(%{"docA" => 3, "docB" => 5}),
            "k12" => Xitdb.counted_set([]),
            "k20" => 99,
            "m01" => Xitdb.counted_set(["other"])
          })
      })

    btree = Xitdb.db(db)["btree"]

    # Fused prefix_only: true, decode_children: true
    assert {:ok, fused_prefix, nil} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               btree.tag_id,
               btree.value,
               "k",
               16,
               true,
               true
             )

    assert [
             {"k10", k10_members},
             {"k11", k11_postings},
             {"k12", []},
             {"k20", 99}
           ] = fused_prefix

    assert Enum.sort(k10_members) == ["d1", "d2"]
    assert Enum.sort(k11_postings) == [{"docA", 3}, {"docB", 5}]

    # Fused prefix_only: false, decode_children: true (stops at limit with next cursor)
    assert {:ok, fused_range, "m01"} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               btree.tag_id,
               btree.value,
               "k10",
               4,
               false,
               true
             )

    assert length(fused_range) == 4

    # Non-fused decode_children: false returns 3-tuples for container slots
    assert {:ok, lazy_entries, nil} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               btree.tag_id,
               btree.value,
               "k",
               16,
               true,
               false
             )

    assert [
             {"k10", t10, v10},
             {"k11", t11, v11},
             {"k12", t12, v12},
             {"k20", 99}
           ] = lazy_entries

    assert is_integer(t10) and is_integer(v10)
    assert is_integer(t11) and is_integer(v11)
    assert is_integer(t12) and is_integer(v12)
  end

  test "handles keys and tagged .Bytes > 128 bytes, > 32 child entries, and empty/large .Bytes" do
    long_key = "long_" <> String.duplicate("k", 200)
    long_child_key = "child_" <> String.duplicate("c", 200)
    long_tagged_val = String.duplicate("t", 200)
    short_tagged_val = "short_tag_val"
    large_bytes = :binary.copy(<<0xAB, 0xCD, 0xEF, 0x00>>, 64)
    nul_bytes = <<0, 1, 0, 2>>

    large_set_members =
      Enum.map(1..50, fn i -> "m_#{String.pad_leading(Integer.to_string(i), 3, "0")}" end)

    large_map_entries =
      Map.new(1..45, fn i -> {"k_#{String.pad_leading(Integer.to_string(i), 3, "0")}", i * 10} end)

    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "btree" =>
          Xitdb.sorted_map(%{
            "b_empty" => "",
            "b_large" => large_bytes,
            "b_nul" => nul_bytes,
            "b_tagged_long" => {:tagged, "md", long_tagged_val},
            "b_tagged_short" => {:tagged, "tx", short_tagged_val},
            long_key => Xitdb.counted_map(%{long_child_key => large_bytes}),
            "spill_map" => Xitdb.counted_map(large_map_entries),
            "spill_set" => Xitdb.counted_set(large_set_members)
          })
      })

    btree = Xitdb.db(db)["btree"]

    # Binary edge cases: empty <<>>, NUL bytes, > 64 byte refc binary, and tagged > 128 bytes
    assert {:ok, b_entries, nil} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               btree.tag_id,
               btree.value,
               "b_",
               16,
               true,
               true
             )

    assert Map.new(b_entries) == %{
             "b_empty" => "",
             "b_large" => large_bytes,
             "b_nul" => nul_bytes,
             "b_tagged_long" => {:tagged, "md", long_tagged_val},
             "b_tagged_short" => {:tagged, "tx", short_tagged_val}
           }

    # Key > 128 bytes in both outer sorted_map and inner counted_map
    assert {:ok, [{^long_key, [{^long_child_key, ^large_bytes}]}], nil} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               btree.tag_id,
               btree.value,
               "long_",
               10,
               true,
               true
             )

    assert {:ok, [{^long_key, child_tag_id, child_val}], nil} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               btree.tag_id,
               btree.value,
               "long_",
               10,
               true,
               false
             )

    assert {:ok, [{^long_child_key, ^large_bytes}]} =
             Xitdb.NIF.nif_slot_entries(db.db_ref, child_tag_id, child_val, 0, -1)

    # Child containers > 32 entries exercising stack_buf -> dyn_items spillover and cleanup
    assert {:ok, [{"spill_map", decoded_map_list}, {"spill_set", decoded_set_list}], nil} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               btree.tag_id,
               btree.value,
               "spill_",
               10,
               true,
               true
             )

    assert Map.new(decoded_map_list) == large_map_entries
    assert Enum.sort(decoded_set_list) == Enum.sort(large_set_members)

    # Same > 32-entry spillover via nif_slot_entries/5
    assert Enum.sort(Enum.to_list(btree["spill_set"])) == Enum.sort(large_set_members)
    assert Map.new(Enum.to_list(btree["spill_map"])) == large_map_entries
    assert db["btree"]["b_tagged_long"] == {:tagged, "md", long_tagged_val}
    assert db["btree"]["b_large"] == large_bytes
    assert db["btree"]["b_empty"] == ""
  end

  test "rejects .Bytes slots below HEADER_LENGTH and handles nil/scalar entries in scan_prefix_cursors" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "idx" => %{
          "search" => %{
            "int_docs" => %{
              "terms" =>
                Xitdb.sorted_map(%{
                  "alpha_scalar" => 123,
                  "alpha_set" => Xitdb.counted_map(%{"1" => 200})
                })
            }
          }
        }
      })

    {:ok, db} = Xitdb.transact_ops(db, [{:put, ".idx.search.int_docs.terms$alpha_nil", nil}])

    # Tag 6 (.Bytes) with offset < HEADER_LENGTH (20) or near i64 max must return an error, never read magic bytes or overflow
    for bad_offset <- [0, 4, 19, 9_223_372_036_854_775_800, 9_223_372_036_854_775_807],
        full <- [0, 1] do
      assert {:error, _} = Xitdb.NIF.nif_slot_materialize(db.db_ref, 6, bad_offset, full)
    end

    # scan_prefix_cursors/4 skips non-container 2-tuples without FunctionClauseError
    {cursors, nil} = Storage.scan_prefix_cursors(db, "int_docs", "alpha_", 10)
    assert [{"alpha_set", %Xitdb.Cursor{} = cur}] = cursors
    assert Map.new(cur) == %{"1" => 200}

    # scan_prefix/5 decodes container and maps non-list slots safely
    assert [
             {"alpha_nil", []},
             {"alpha_scalar", []},
             {"alpha_set", [{"1", 200}]}
           ] = Storage.scan_prefix(db, "int_docs", "alpha_", 10, :nif)
  end

  test "bm25 prefix search handles 9..128 byte and > 128 byte terms identically across backends" do
    mid_term = "pre_" <> String.duplicate("m", 40)
    long_term = "pre_" <> String.duplicate("x", 160)

    db =
      Xitdb.open!(backend: :memory)
      |> Search.index_record(IntDoc, %IntDoc{id: 1, title: mid_term, body: "overview"})
      |> Search.index_record(IntDoc, %IntDoc{id: 2, title: long_term, body: "overview"})

    assert Search.ids(IntDoc, "pre_", db: db, prefix?: true, backend: :nif) ==
             Search.ids(IntDoc, "pre_", db: db, prefix?: true, backend: :elixir)

    assert Search.ids(IntDoc, long_term, db: db, prefix?: true, backend: :nif) == [2]
    assert Search.ids(IntDoc, mid_term, db: db, prefix?: true, backend: :nif) == [1]
  end

  test "Indexer.Storage.stream_index_from/4 yields lazy %Xitdb.Cursor{} sets for range termination" do
    alias Xitdb.Ash.Indexer

    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "idx" => %{
          "items" => %{
            "attr_k" =>
              Xitdb.sorted_map(%{
                Base.encode16("a", case: :lower) => Xitdb.counted_set(["doc1", "doc2"]),
                Base.encode16("b", case: :lower) => Xitdb.counted_set(["doc3"]),
                Base.encode16("c", case: :lower) => Xitdb.counted_set(["doc4"])
              })
          }
        }
      })

    entries =
      db
      |> Indexer.Storage.stream_index_from("items", "attr_k", "a")
      |> Stream.take_while(fn {key, _ids} -> key < "c" end)
      |> Enum.to_list()

    assert [{"a", %Xitdb.Cursor{} = cur_a}, {"b", %Xitdb.Cursor{} = cur_b}] = entries
    assert Enum.sort(Enum.to_list(cur_a)) == ["doc1", "doc2"]
    assert Enum.to_list(cur_b) == ["doc3"]
  end

  test "nif_sorted_map_seek/7 caps fused child decoding at 256 entries, validates slot args when limit <= 0, and supports tag -1" do
    small_members = Enum.map(1..10, &"s_#{&1}")
    large_members = Enum.map(1..300, &"l_#{String.pad_leading(Integer.to_string(&1), 3, "0")}")
    large_postings = Map.new(1..300, fn i -> {"doc_#{i}", i} end)

    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "idx" => %{
          "items" => %{
            "attr_tag" =>
              Xitdb.sorted_map(%{
                Base.encode16("a_small", case: :lower) => Xitdb.counted_set(small_members),
                Base.encode16("b_large", case: :lower) => Xitdb.counted_set(large_members),
                Base.encode16("c_nested", case: :lower) => [%{"inner" => "ok"}]
              })
          },
          "search" => %{
            "items" => %{
              "terms" =>
                Xitdb.sorted_map(%{
                  "t_small" => Xitdb.counted_map(%{"doc_1" => 10}),
                  "t_large" => Xitdb.counted_map(large_postings)
                })
            }
          }
        }
      })

    btree = Xitdb.db(db)["idx"]["items"]["attr_tag"]

    assert {:ok, seek_entries, nil} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               btree.tag_id,
               btree.value,
               "",
               16,
               false,
               true
             )

    small_hex = Base.encode16("a_small", case: :lower)
    large_hex = Base.encode16("b_large", case: :lower)
    nested_hex = Base.encode16("c_nested", case: :lower)

    assert [
             {^small_hex, decoded_small},
             {^large_hex, set_tag_id, set_val},
             {^nested_hex, [{:cursor, _, _}]}
           ] = seek_entries

    assert Enum.sort(decoded_small) == Enum.sort(small_members)
    assert Xitdb.Cursor.tag_atom_for(set_tag_id) == :counted_hash_set
    assert is_integer(set_val) and set_val > 0

    # Indexer.Storage.stream_index_from yields lazy %Xitdb.Cursor{} that enumerates both small and oversized sets
    indexed_rows =
      db
      |> Xitdb.Ash.Indexer.Storage.stream_index_from("items", "attr_tag", "a_small")
      |> Enum.map(fn {k, cur} -> {k, Enum.to_list(cur)} end)

    assert [
             {"a_small", streamed_small},
             {"b_large", streamed_large},
             {"c_nested", [%Xitdb.Cursor{} = nested_cur]}
           ] = indexed_rows

    assert Enum.sort(streamed_small) == Enum.sort(small_members)
    assert Enum.sort(streamed_large) == Enum.sort(large_members)
    assert nested_cur["inner"] == "ok"

    # Search.Storage.scan_prefix handles both fused small maps and oversized fallback maps
    scanned = Storage.scan_prefix(db, "items", "t_", 10, :nif)
    assert [{"t_large", scanned_large}, {"t_small", [{"doc_1", 10}]}] = scanned
    assert Enum.sort(scanned_large) == Enum.sort(Map.to_list(large_postings))

    # BUG-02-07: limit <= 0 validates slot first and tag_int == -1 resolves cleanly
    assert {:error, :invalid_slot} =
             Xitdb.NIF.nif_sorted_map_seek(db.db_ref, btree.tag_id, -99, "", 0, true, false)

    assert {:error, :unsupported} =
             Xitdb.NIF.nif_sorted_map_seek(db.db_ref, -1, 0, "", 10, true, false)
  end

  test "BUG-02-02, BUG-02-03, BUG-02-04: non-binary keys, scalar postings in :elixir backend, and closed errors" do
    db =
      Xitdb.open!(backend: :memory)
      |> Xitdb.transact!(%{
        "sub" => %{"n" => "one"},
        "idx" => %{
          "kdocs" => %{
            "attr_k" =>
              Xitdb.sorted_map(%{Base.encode16("k1", case: :lower) => Xitdb.counted_set(["d1"])})
          },
          "search" => %{
            "kdocs" => %{
              "terms" =>
                Xitdb.sorted_map(%{
                  "alpha" => 42,
                  "alpha_ok" => Xitdb.counted_map(%{"doc_1" => 7, "nested" => %{"inner" => 1}})
                })
            }
          }
        }
      })

    # Bare 2-tuple stay data; non-binary keys unwrap cleanly
    assert Xitdb.Cursor.unwrap_nif_value(db.db_ref, {4, 123}, -1, []) == {4, 123}
    sub = Xitdb.db(db)["sub"]
    cur_tuple = {:cursor, sub.tag_id, sub.value}

    assert [{%Xitdb.Cursor{}, %Xitdb.Cursor{}}, {10, %Xitdb.Cursor{}}] =
             Xitdb.Cursor.unwrap_nif_entries(
               db.db_ref,
               [{cur_tuple, cur_tuple}, {10, cur_tuple}],
               -1
             )

    # BUG-02-03 & BUG-02-02: stream_prefix_from handles scalar entries and unwraps nested cursor postings
    assert [{"alpha", []}, {"alpha_ok", [{"doc_1", 7}, {"nested", %Xitdb.Cursor{}}]}] =
             Storage.scan_prefix(db, "kdocs", "alpha", 10, :elixir)
             |> Enum.map(fn {t, entries} -> {t, Enum.sort_by(entries, &elem(&1, 0))} end)

    assert [{"alpha", []}, {"alpha_ok", [{"doc_1", 7}, {"nested", %Xitdb.Cursor{}}]}] =
             Storage.scan_prefix(db, "kdocs", "alpha", 10, :nif)
             |> Enum.map(fn {t, entries} -> {t, Enum.sort_by(entries, &elem(&1, 0))} end)

    # BUG-02-04: closed db raises Xitdb.Error instead of silently returning []
    :ok = Xitdb.close(db)

    assert_raise Xitdb.Error, ~r/closed/, fn ->
      Storage.scan_prefix_cursors(db, "kdocs", "alpha", 10)
    end

    assert_raise Xitdb.Error, ~r/closed/, fn ->
      Storage.scan_prefix(db, "kdocs", "alpha", 10, :nif)
    end

    assert_raise Xitdb.Error, ~r/closed/, fn ->
      Xitdb.Ash.Indexer.Storage.stream_index_from(db, "kdocs", "attr_k", "k1")
    end
  end

  test "BM25 search preserves >8-byte .Bytes doc IDs and >8-byte prefix-matched terms" do
    {:ok, db} = Xitdb.open(backend: :memory)
    on_exit(fn -> Xitdb.close(db) end)

    id1 = "11111111-1111-1111-1111-111111111111"
    id2 = "22222222-2222-2222-2222-222222222222"
    id3 = "33333333-3333-3333-3333-333333333333"

    db =
      Enum.reduce(
        [
          %IntDoc{id: id1, title: "cryptographic verification", body: "algorithm"},
          %IntDoc{id: id2, title: "cryptography benchmarks", body: "algorithm"},
          %IntDoc{id: id3, title: "unrelated document", body: "placeholder"}
        ],
        db,
        &Search.index_record(&2, IntDoc, &1)
      )

    root = Xitdb.db(db)

    opts = %{
      match: :all,
      prefix: true,
      min_prefix_length: 3,
      max_prefix_expansions: 64,
      k1: 1.2,
      b: 0.75,
      exact_boost: 1.25,
      prefix_weight: 1.0
    }

    assert {:ok, hits} =
             Xitdb.NIF.nif_bm25_search(
               db.db_ref,
               root.tag_id,
               root.value,
               "int_docs",
               ["cryptograph", "algor"],
               10,
               opts
             )

    ids = Enum.map(hits, &elem(&1, 0))
    assert Enum.sort(ids) == [id1, id2]
  end
end

defmodule Xitdb.Ash.SearchNifLeakTest do
  use ExUnit.Case, async: false

  alias Xitdb.Ash.Search
  alias Xitdb.Ash.SearchNifTest.IntDoc

  test "10,000 nif_bm25_search/7 invocations complete with bounded memory (no arena leak)" do
    {:ok, db} = Xitdb.open(backend: :memory)

    db =
      Enum.reduce(1..20, db, fn i, acc ->
        Search.index_record(acc, IntDoc, %IntDoc{
          id: i,
          title: "nordic capital fund #{i}",
          body: "growth buyout infrastructure zürich"
        })
      end)

    root = Xitdb.db(db)

    opts = %{
      match: :all,
      prefix: true,
      min_prefix_length: 3,
      max_prefix_expansions: 64,
      k1: 1.2,
      b: 0.75,
      exact_boost: 1.25,
      prefix_weight: 1.0
    }

    # Warmup NIF & BEAM scheduler arenas
    for _ <- 1..200 do
      assert {:ok, hits} =
               Xitdb.NIF.nif_bm25_search(
                 db.db_ref,
                 root.tag_id,
                 root.value,
                 "int_docs",
                 ["nordic", "zür"],
                 10,
                 opts
               )

      assert length(hits) == 10
    end

    :erlang.garbage_collect()
    rss_before_kb = current_rss_kb()

    for _ <- 1..10_000 do
      {:ok, hits} =
        Xitdb.NIF.nif_bm25_search(
          db.db_ref,
          root.tag_id,
          root.value,
          "int_docs",
          ["nordic", "zür"],
          10,
          opts
        )

      assert length(hits) == 10
    end

    :erlang.garbage_collect()
    rss_after_kb = current_rss_kb()

    if rss_before_kb > 0 and rss_after_kb > 0 do
      # Zero per-call C/Odin heap retention across 10,000 invocations (allow < 8 MB OS variance)
      assert rss_after_kb - rss_before_kb < 8_192
    end
  end

  defp current_rss_kb do
    case File.read("/proc/self/statm") do
      {:ok, content} ->
        case String.split(content) do
          [_, resident_pages | _] -> String.to_integer(resident_pages) * 4
          _ -> 0
        end

      _ ->
        0
    end
  end
end
