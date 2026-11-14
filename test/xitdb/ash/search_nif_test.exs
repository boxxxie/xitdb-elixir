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
