if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.IndexerTest do
    use ExUnit.Case, async: true

    alias Ash.Error.Changes.InvalidChanges
    alias Xitdb.Ash.{Codec, Indexer, Info, Search}

    defmodule DummyStore do
    end

    defmodule Article do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :articles
        index :status
        index [:category, :rank], name: :idx_cat_rank
        index [:category, :tier, :rank], name: :idx_cat_tier_rank
        search_field :title, boost: 2.0
        search_field :summary, boost: 1.0
      end

      attributes do
        integer_primary_key(:id)
        attribute(:slug, :ci_string, allow_nil?: false, public?: true)
        attribute(:status, :atom, default: :draft, public?: true)
        attribute(:category, :string, public?: true)
        attribute(:tier, :integer, public?: true)
        attribute(:rank, :integer, public?: true)
        attribute(:score, :decimal, public?: true)
        attribute(:title, :string, public?: true)
        attribute(:summary, :string, public?: true)
        attribute(:author_id, :integer, public?: true)
      end

      identities do
        identity(:unique_slug, [:slug])

        identity :unique_active_slug, [:category, :slug] do
          where expr(status == :published)
        end
      end
    end

    defmodule Author do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :authors
      end

      attributes do
        integer_primary_key(:id)
        attribute(:name, :string, allow_nil?: false, public?: true)
      end
    end

    defmodule Comment do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :comments
      end

      attributes do
        integer_primary_key(:id)
        attribute(:body, :string, public?: true)
      end

      relationships do
        belongs_to(:author, Author, attribute_type: :integer, allow_nil?: false, public?: true)
      end
    end

    defmodule ContextNote do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :context_notes
        index :tag
      end

      multitenancy do
        strategy(:context)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:code, :ci_string, allow_nil?: false, public?: true)
        attribute(:tag, :string, public?: true)
      end

      identities do
        identity(:unique_code, [:code])
      end
    end

    defmodule AttrNote do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        extensions: [Xitdb.Ash.Dsl]

      xitdb do
        store DummyStore
        collection :attr_notes
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org_id)
      end

      attributes do
        uuid_primary_key(:id)
        attribute(:org_id, :integer, allow_nil?: true, public?: true)
        attribute(:code, :string, allow_nil?: false, public?: true)
        attribute(:global_code, :string, allow_nil?: true, public?: true)
      end

      identities do
        identity(:unique_org_code, [:code])
        identity(:unique_global_code, [:global_code], all_tenants?: true)
      end
    end

    setup do
      {:ok, db} = Xitdb.open(backend: :memory)

      on_exit(fn ->
        try do
          Xitdb.close(db)
        catch
          _, _ -> :ok
        end
      end)

      {:ok, db: db}
    end

    test "put_record/4 and delete_record/4 commit atomically in 1 moment and maintain cursors", %{
      db: db
    } do
      m0 = Xitdb.moment_count(db)

      a1 =
        struct(Article,
          id: 1,
          slug: Ash.CiString.new("Alpha-One"),
          status: :published,
          category: "tech",
          tier: 1,
          rank: 10,
          title: "Distributed BTree Engines",
          summary: "Immutable indexing guide"
        )

      assert {:ok, db} = Indexer.put_record(db, Article, nil, a1)
      assert Xitdb.moment_count(db) == m0 + 1

      assert :none == Indexer.fetch_cursor(db, Article, nil)
      assert :none == Indexer.fetch_cursor(db, Article, 999)
      assert {:ok, c1} = Indexer.fetch_cursor(db, Article, 1)
      assert {:ok, loaded} = Codec.from_cursor(Article, c1)
      assert loaded.slug == Ash.CiString.new("Alpha-One")
      assert loaded.status == :published

      all = Indexer.all_cursors(db, Article)
      assert length(all) == 1
      assert [{"1", _}] = all

      # Update in place commits in 1 moment and also works via {db, moment} snapshots
      moment = Xitdb.moment_count(db) - 1

      a1_updated = %{a1 | status: :archived, rank: 20, summary: "Cold storage guide"}
      assert {:ok, {db, next_moment}} = Indexer.put_record({db, moment}, Article, a1, a1_updated)
      assert next_moment == moment + 1
      assert Xitdb.moment_count(db) == m0 + 2

      {:ok, c1_v2} = Indexer.fetch_cursor(Xitdb.as_of(db, next_moment), Article, 1)
      {:ok, loaded_v2} = Codec.from_cursor(Article, c1_v2)
      assert loaded_v2.status == :archived
      assert loaded_v2.rank == 20

      # Delete removes entity and secondary indexes in 1 moment
      assert {:ok, {db, del_moment}} =
               Indexer.delete_record({db, next_moment}, Article, a1_updated)

      assert del_moment == next_moment + 1
      assert :none == Indexer.fetch_cursor(Xitdb.as_of(db, del_moment), Article, 1)
      assert [] == Indexer.all_cursors(db, Article)
    end

    test "plan_put_ops_batched/6 and plan_delete_ops_batched/5 accumulate state in one commit",
         %{db: db} do
      m0 = Xitdb.moment_count(db)

      records = [
        struct(Article,
          id: 1,
          slug: Ash.CiString.new("one"),
          status: :published,
          category: "ai",
          tier: 1,
          rank: 5,
          title: "Neural Search"
        ),
        struct(Article,
          id: 2,
          slug: Ash.CiString.new("two"),
          status: :published,
          category: "ai",
          tier: 1,
          rank: 8,
          title: "Neural Ranking"
        )
      ]

      {ops, _final_batch} =
        Enum.reduce(records, {[], %{}}, fn rec, {acc_ops, batch} ->
          {:ok, rec_ops, next_batch} =
            Indexer.plan_put_ops_batched(db, Article, nil, rec, nil, batch)

          {acc_ops ++ rec_ops, next_batch}
        end)

      assert {:ok, db} = Xitdb.transact_ops(db, ops)
      assert Xitdb.moment_count(db) == m0 + 1

      status_idx = Enum.find(Info.indexes(Article), &(&1.fields == [:status]))

      assert MapSet.new(["1", "2"]) ==
               Indexer.lookup_secondary_eq(db, Article, status_idx, [:published])

      assert [1, 2] == Search.ids(Article, "neural", db: db) |> Enum.sort()

      # Batched delete clears both docs and corpus stats in 1 commit
      {del_ops, _} =
        Enum.reduce(records, {[], %{}}, fn rec, {acc_ops, batch} ->
          {:ok, rec_ops, next_batch} =
            Indexer.plan_delete_ops_batched(db, Article, rec, nil, batch)

          {acc_ops ++ rec_ops, next_batch}
        end)

      assert {:ok, db} = Xitdb.transact_ops(db, del_ops)
      assert Xitdb.moment_count(db) == m0 + 2
      assert MapSet.new() == Indexer.lookup_secondary_eq(db, Article, status_idx, [:published])
      assert [] == Search.ids(Article, "neural", db: db)
    end

    test "lookup_by_identity/5, collision errors, and partial where: identity semantics", %{
      db: db
    } do
      slug_ident = Ash.Resource.Info.identity(Article, :unique_slug)
      active_ident = Ash.Resource.Info.identity(Article, :unique_active_slug)

      a1 =
        struct(Article,
          id: 1,
          slug: Ash.CiString.new("Flagship"),
          status: :published,
          category: "macro"
        )

      {:ok, db} = Indexer.put_record(db, Article, nil, a1)

      # Case-insensitive identity lookup
      assert {:ok, "1"} ==
               Indexer.lookup_by_identity(db, Article, slug_ident, %{slug: "FLAGSHIP"})

      # Self-update with same identity succeeds
      assert {:ok, db} = Indexer.put_record(db, Article, a1, %{a1 | title: "Updated"})

      # Different PK with colliding slug fails with InvalidChanges
      dup =
        struct(Article,
          id: 2,
          slug: Ash.CiString.new("flagship"),
          status: :draft,
          category: "macro"
        )

      assert {:error, %InvalidChanges{fields: [:slug]}} =
               Indexer.put_record(db, Article, nil, dup)

      # Partial where: identity (`status == :published`): draft with same active key does NOT collide
      other_published =
        struct(Article,
          id: 3,
          slug: Ash.CiString.new("other"),
          status: :draft,
          category: "macro"
        )

      {:ok, db} = Indexer.put_record(db, Article, nil, other_published)

      assert :none ==
               Indexer.lookup_by_identity(db, Article, active_ident, %{
                 category: "macro",
                 slug: "other"
               })

      # Even sharing {category, slug} when one is :draft does not conflict on unique_active_slug
      # (we test with a distinct unique_slug vs same active_slug by making first :archived)
      {:ok, db} = Indexer.put_record(db, Article, a1, %{a1 | status: :archived})

      assert :none ==
               Indexer.lookup_by_identity(db, Article, active_ident, %{
                 category: "macro",
                 slug: "flagship"
               })

      reusing_active_slug =
        struct(Article,
          id: 4,
          slug: Ash.CiString.new("flagship-v2"),
          status: :published,
          category: "macro"
        )

      {:ok, db} = Indexer.put_record(db, Article, nil, reusing_active_slug)

      assert {:ok, "4"} ==
               Indexer.lookup_by_identity(db, Article, active_ident, %{
                 category: "macro",
                 slug: "flagship-v2"
               })

      # Transitioning archived a1 back to :published on same slug works, while another record with same {category, slug} if forced fails
      assert {:ok, _db} = Indexer.put_record(db, Article, %{a1 | status: :archived}, a1)
    end

    test "multitenant :context and :attribute isolation in indexes and identities", %{db: db} do
      ctx_ident = Ash.Resource.Info.identity(ContextNote, :unique_code)
      ctx_tag_idx = Enum.find(Info.indexes(ContextNote), &(&1.fields == [:tag]))

      n1 =
        struct(ContextNote,
          id: "00000000-0000-0000-0000-000000000001",
          code: Ash.CiString.new("NOTE-1"),
          tag: "urgent"
        )

      n2 =
        struct(ContextNote,
          id: "00000000-0000-0000-0000-000000000002",
          code: Ash.CiString.new("note-1"),
          tag: "urgent"
        )

      {:ok, db} = Indexer.put_record(db, ContextNote, nil, n1, "tenant_a")
      # Same code allowed in tenant_b
      assert {:ok, db} = Indexer.put_record(db, ContextNote, nil, n2, "tenant_b")

      # Collision within tenant_a
      n1_dup = %{n2 | id: "00000000-0000-0000-0000-000000000003"}

      assert {:error, %InvalidChanges{}} =
               Indexer.put_record(db, ContextNote, nil, n1_dup, "tenant_a")

      assert {:ok, "00000000-0000-0000-0000-000000000001"} ==
               Indexer.lookup_by_identity(
                 db,
                 ContextNote,
                 ctx_ident,
                 %{code: "note-1"},
                 "tenant_a"
               )

      assert {:ok, "00000000-0000-0000-0000-000000000002"} ==
               Indexer.lookup_by_identity(
                 db,
                 ContextNote,
                 ctx_ident,
                 %{code: "NOTE-1"},
                 "tenant_b"
               )

      assert MapSet.new(["00000000-0000-0000-0000-000000000001"]) ==
               Indexer.lookup_secondary_eq(db, ContextNote, ctx_tag_idx, ["urgent"], "tenant_a")

      assert MapSet.new(["00000000-0000-0000-0000-000000000002"]) ==
               Indexer.lookup_secondary_eq(db, ContextNote, ctx_tag_idx, ["urgent"], "tenant_b")

      assert [{"00000000-0000-0000-0000-000000000001", _}] =
               Indexer.all_cursors(db, ContextNote, "tenant_a")

      # :attribute multitenancy: per-tenant identity vs all_tenants?: true
      attr_local = Ash.Resource.Info.identity(AttrNote, :unique_org_code)
      attr_global = Ash.Resource.Info.identity(AttrNote, :unique_global_code)

      an1 =
        struct(AttrNote,
          id: "00000000-0000-0000-0000-000000000011",
          org_id: 10,
          code: "shared",
          global_code: "glob-1"
        )

      an2 =
        struct(AttrNote,
          id: "00000000-0000-0000-0000-000000000012",
          org_id: 20,
          code: "shared",
          global_code: "glob-1"
        )

      {:ok, db} = Indexer.put_record(db, AttrNote, nil, an1, 10)
      # Global identity blocks collision even across org_id 10 vs 20
      assert {:error, %InvalidChanges{fields: [:global_code]}} =
               Indexer.put_record(db, AttrNote, nil, an2, 20)

      an2_ok = %{an2 | global_code: "glob-2"}
      assert {:ok, db} = Indexer.put_record(db, AttrNote, nil, an2_ok, 20)

      assert {:ok, "00000000-0000-0000-0000-000000000011"} ==
               Indexer.lookup_by_identity(db, AttrNote, attr_local, %{code: "shared"}, 10)

      assert {:ok, "00000000-0000-0000-0000-000000000012"} ==
               Indexer.lookup_by_identity(db, AttrNote, attr_local, %{code: "shared"}, 20)

      assert {:ok, "00000000-0000-0000-0000-000000000012"} ==
               Indexer.lookup_by_identity(
                 db,
                 AttrNote,
                 attr_global,
                 %{global_code: "glob-2"},
                 999
               )
    end

    test "count_by_attribute/5 tracks belongs_to FK counts across creates, updates, and deletes",
         %{
           db: db
         } do
      assert 0 == Indexer.count_by_attribute(db, Comment, :author_id, 50)

      c1 = struct(Comment, id: 1, body: "First", author_id: 50)
      c2 = struct(Comment, id: 2, body: "Second", author_id: 50)
      c3 = struct(Comment, id: 3, body: "Third", author_id: 60)

      {:ok, db} = Indexer.put_record(db, Comment, nil, c1)
      {:ok, db} = Indexer.put_record(db, Comment, nil, c2)
      {:ok, db} = Indexer.put_record(db, Comment, nil, c3)

      assert 2 == Indexer.count_by_attribute(db, Comment, :author_id, 50)
      assert 1 == Indexer.count_by_attribute(db, Comment, :author_id, 60)

      {:ok, db} = Indexer.put_record(db, Comment, c1, %{c1 | author_id: 60})
      assert 1 == Indexer.count_by_attribute(db, Comment, :author_id, 50)
      assert 2 == Indexer.count_by_attribute(db, Comment, :author_id, 60)

      {:ok, db} = Indexer.delete_record(db, Comment, c2)
      assert 0 == Indexer.count_by_attribute(db, Comment, :author_id, 50)
    end

    test "scan_secondary_range/5 supports exact prefixes and partial composite bounds", %{db: db} do
      cat_rank_idx = Enum.find(Info.indexes(Article), &(&1.name == :idx_cat_rank))
      cat_tier_rank_idx = Enum.find(Info.indexes(Article), &(&1.name == :idx_cat_tier_rank))

      rows = [
        {1, "ai", nil, 1},
        {2, "ai", 1, 10},
        {3, "ai", 1, 99},
        {4, "ai", 2, 10},
        {5, "ai", 2, 50},
        {6, "ai", 3, 10},
        {7, "fin", 1, 20}
      ]

      db =
        Enum.reduce(rows, db, fn {id, cat, tier, rank}, acc ->
          rec =
            struct(Article,
              id: id,
              slug: Ash.CiString.new("art-#{id}"),
              status: :published,
              category: cat,
              tier: tier,
              rank: rank
            )

          {:ok, next} = Indexer.put_record(acc, Article, nil, rec)
          next
        end)

      # Exact equality lookup on 2-col index
      assert MapSet.new(["2", "4", "6"]) ==
               Indexer.lookup_secondary_eq(db, Article, cat_rank_idx, ["ai", 10])

      # Prefix scan without range bounds returns all rows under prefix ["ai"], including nil tier
      assert MapSet.new(["1", "2", "3", "4", "5", "6"]) ==
               Indexer.scan_secondary_range(db, Article, cat_tier_rank_idx, %{prefix: ["ai"]})

      # Bounded partial range on `:tier` (k=2 of 3 columns):
      # inclusive max 2 must include `{4, "ai", 2, 10}` and `{5, "ai", 2, 50}` AND exclude nil tier (`id=1`)!
      assert MapSet.new(["2", "3", "4", "5"]) ==
               Indexer.scan_secondary_range(db, Article, cat_tier_rank_idx, %{
                 prefix: ["ai"],
                 min: {:inclusive, 1},
                 max: {:inclusive, 2}
               })

      # exclusive lower bound on partial column 1 skips ALL entries starting with `tier == 1` (`"2"`, `"3"`)
      # exclusive upper bound on partial column 3 excludes ALL entries starting with `tier == 3` (`"6"`)
      assert MapSet.new(["4", "5"]) ==
               Indexer.scan_secondary_range(db, Article, cat_tier_rank_idx, %{
                 prefix: ["ai"],
                 min: {:exclusive, 1},
                 max: {:exclusive, 3}
               })

      # Full-depth range scan on last column `rank`
      assert MapSet.new(["2", "4", "5", "6"]) ==
               Indexer.scan_secondary_range(db, Article, cat_rank_idx, %{
                 prefix: ["ai"],
                 min: {:inclusive, 10},
                 max: {:exclusive, 99}
               })
    end

    test "BM25 stale-token cleanup on update/delete and Search.reindex_records({db, moment}) snapshot",
         %{db: db} do
      a1 =
        struct(Article,
          id: 1,
          slug: Ash.CiString.new("quant-1"),
          title: "Quantum Credit",
          summary: "Arbitrage strategies"
        )

      {:ok, db} = Indexer.put_record(db, Article, nil, a1)
      assert [1] == Search.ids(Article, "quantum", db: db)
      assert [1] == Search.ids(Article, "arbitrage", db: db)

      # Updating title/summary removes old tokens atomically in the same commit
      a1_v2 = %{a1 | title: "Venture Growth", summary: "Late stage buyouts"}
      {:ok, db} = Indexer.put_record(db, Article, a1, a1_v2)

      assert [] == Search.ids(Article, "quantum", db: db)
      assert [] == Search.ids(Article, "arbitrage", db: db)
      assert [1] == Search.ids(Article, "venture", db: db)

      # Search.reindex_records works directly on {db, moment} snapshots and clears stale terms
      moment = Xitdb.moment_count(db) - 1
      a1_v3 = %{a1_v2 | title: "Infrastructure Debt", summary: "Core renewables"}

      assert {db, reindex_moment} = Search.reindex_records({db, moment}, Article, [a1_v3])
      assert reindex_moment == moment + 1
      assert [] == Search.ids(Article, "venture", db: db)
      assert [1] == Search.ids(Article, "renewables", db: db)

      # Deleting the record clears meta/docs/terms completely
      {:ok, db} = Indexer.delete_record(db, Article, a1_v3)
      assert [] == Search.ids(Article, "renewables", db: db)
      meta = Xitdb.db(db)["idx"]["search"]["articles"]["meta"]
      assert meta["doc_count"] == 0
      assert meta["total_len"] == 0
    end
  end
end
