if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.CompressionTest do
    use ExUnit.Case, async: true

    require Ash.Query

    alias Spark.Error.DslError
    alias Xitdb.Ash.{Compress, Info, Search, Store}
    alias Xitdb.Columnar
    alias Xitdb.Compression.Dictionary

    @html_head "<!DOCTYPE html><html><head><style>.mail{font-family:Inter,sans-serif;color:#1f2937}</style></head><body><div class=\"mail\">"
    @html_block String.duplicate(
                  "<p>CAASA CRM advisory digest: quarterly allocation notes, fee schedule review, and compliance disclosure.</p>",
                  28
                )
    @html_foot "</div><footer>Confidentiality Notice: CAASA CRM Privileged Communication.</footer></body></html>"

    defp sample_body(i, extra \\ "") do
      @html_head <>
        @html_block <>
        "<p>Activity ##{i} #{extra} client_ref=#{rem(i, 7)}</p>" <>
        @html_foot
    end

    defp sample_edit_body(i) do
      @html_head <>
        @html_block <>
        "<div class=\"draft\">Edited draft ##{i} for partner review</div>" <>
        @html_foot
    end

    # =========================================================================
    # Isolated Sandbox Store, Raw/Compressed Resources & Domain
    # =========================================================================

    defmodule CompMemStore do
      use Xitdb.Ash.Store
    end

    defmodule RawFileStore do
      use Xitdb.Ash.Store
    end

    defmodule CompFileStore do
      use Xitdb.Ash.Store
    end

    defmodule EmailActivity do
      use Ash.Resource,
        domain: Xitdb.Ash.CompressionTest.MailDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store CompMemStore
        collection :email_activities

        compress([:body, :html_edit_body],
          mode: :row_group,
          row_group_size: 64,
          codec: :zstd,
          encoding: :dict_block,
          dictionary: :email_html
        )

        compress([:header_properties],
          mode: :row_group,
          row_group_size: 64,
          encoding: :dict_rle
        )

        compress(:attachment_blob,
          mode: :value,
          codec: :zstd,
          intern_above: 256
        )

        search_field :title, boost: 3.0
        search_field :body, boost: 2.0
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:title, :header_properties, :body, :html_edit_body, :attachment_blob])
        end

        update :update do
          primary?(true)
          accept([:title, :header_properties, :body, :html_edit_body, :attachment_blob])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:header_properties, :string, public?: true)
        attribute(:body, :string, public?: true)
        attribute(:html_edit_body, :string, public?: true)
        attribute(:attachment_blob, :string, public?: true)
      end
    end

    defmodule FileCompEmail do
      use Ash.Resource,
        domain: Xitdb.Ash.CompressionTest.FileDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store CompFileStore
        collection :emails

        compress([:body, :html_edit_body],
          mode: :row_group,
          row_group_size: 64,
          codec: :zstd,
          encoding: :dict_block,
          dictionary: :email_html
        )

        compress([:header_properties],
          mode: :row_group,
          row_group_size: 64,
          encoding: :dict_rle
        )
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:title, :header_properties, :body, :html_edit_body])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:header_properties, :string, public?: true)
        attribute(:body, :string, public?: true)
        attribute(:html_edit_body, :string, public?: true)
      end
    end

    defmodule FileRawEmail do
      use Ash.Resource,
        domain: Xitdb.Ash.CompressionTest.FileDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store RawFileStore
        collection :emails
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:title, :header_properties, :body, :html_edit_body])
        end
      end

      attributes do
        integer_primary_key(:id)
        attribute(:title, :string, allow_nil?: false, public?: true)
        attribute(:header_properties, :string, public?: true)
        attribute(:body, :string, public?: true)
        attribute(:html_edit_body, :string, public?: true)
      end
    end

    defmodule MailDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(EmailActivity)
      end
    end

    defmodule FileDomain do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(FileCompEmail)
        resource(FileRawEmail)
      end
    end

    setup_all do
      :ok = Xitdb.Ash.TestSandbox.init()
      start_supervised!({CompMemStore, path: :memory, domains: [MailDomain]})
      :ok
    end

    setup do
      :ok = Xitdb.Ash.TestSandbox.checkout([CompMemStore])
      :ok
    end

    describe "Xitdb.Ash.Dsl compress configuration & validation" do
      test "introspects compress entities and rejects unknown, PK, duplicate, or nested_in row_group configs" do
        configs = Info.compression_configs(EmailActivity)
        assert length(configs) == 3

        %Compress{
          mode: :row_group,
          row_group_size: 64,
          encoding: :dict_block,
          dictionary: :email_html
        } =
          Info.compression_for_field(EmailActivity, :body)

        %Compress{mode: :value, intern_above: 256} =
          Info.compression_for_field(EmailActivity, :attachment_blob)

        assert Info.compression_for_field(EmailActivity, :title) == nil

        assert_raise DslError, ~r/unknown attribute :missing_col/, fn ->
          defmodule BadUnknownCompress do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [Xitdb.Ash.Dsl]

            xitdb do
              store CompMemStore
              collection :bad_u
              compress(:missing_col)
            end

            attributes do
              integer_primary_key(:id)
              attribute(:title, :string, public?: true)
            end
          end
        end

        assert_raise DslError, ~r/primary key attribute :id cannot be compressed/, fn ->
          defmodule BadPkCompress do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [Xitdb.Ash.Dsl]

            xitdb do
              store CompMemStore
              collection :bad_pk
              compress(:id)
            end

            attributes do
              integer_primary_key(:id)
              attribute(:title, :string, public?: true)
            end
          end
        end

        assert_raise DslError, ~r/duplicate `compress`/, fn ->
          defmodule BadDupCompress do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [Xitdb.Ash.Dsl]

            xitdb do
              store CompMemStore
              collection :bad_dup
              compress(:title, codec: :zstd)
              compress(:title, codec: :zlib)
            end

            attributes do
              integer_primary_key(:id)
              attribute(:title, :string, public?: true)
            end
          end
        end

        assert_raise DslError, ~r/row_group.*top-level/, fn ->
          defmodule BadNestedRowGroup do
            use Ash.Resource,
              domain: nil,
              validate_domain_inclusion?: false,
              extensions: [Xitdb.Ash.Dsl]

            xitdb do
              store CompMemStore
              collection :bad_nested
              nested_in :parents, foreign_key: :parent_id, path: :children
              compress(:body, mode: :row_group)
            end

            attributes do
              integer_primary_key(:id)
              attribute(:parent_id, :integer, public?: true)
              attribute(:body, :string, public?: true)
            end
          end
        end
      end
    end

    describe "Ash bulk_create!, select projection skipping, BM25 Search, single-row CRUD & history" do
      test "bulk_create writes row-group pages, select skips decompression, BM25 searches plaintext, and create/update preserve history" do
        samples = for i <- 1..24, do: sample_body(i)

        {:ok, _db, dict_bytes} =
          Dictionary.train_and_put(CompMemStore, :email_html, samples, target_size: 4_096)

        assert is_binary(dict_bytes) and byte_size(dict_bytes) > 0
        assert Dictionary.get(CompMemStore, :email_html) == dict_bytes

        shared_attachment =
          String.duplicate("Signed CAASA Term Sheet PDF Attachment Binary Block.", 20)

        inputs =
          for i <- 1..150 do
            keyword_marker = if i == 77, do: "xenolith_alpha_marker", else: "regular_dispatch"

            %{
              title: "Deal Memo ##{i}",
              header_properties:
                "Content-Type: text/html; charset=utf-8; Tenant=tenant_#{rem(i, 3)}",
              body: sample_body(i, keyword_marker),
              html_edit_body: sample_edit_body(i),
              attachment_blob: shared_attachment
            }
          end

        %Ash.BulkResult{status: :success, records: created} =
          Ash.bulk_create!(inputs, EmailActivity, :create, return_records?: true)

        assert length(created) == 150

        # Columnar pages & deduplicated __blobs created
        root = CompMemStore.root()
        # 150 rows / 64 row_group_size => 3 pages
        assert Enum.count(root["__col_pages"]["email_activities"]["body"]) == 3
        assert Enum.count(root["__col_pages"]["email_activities"]["html_edit_body"]) == 3
        assert Enum.count(root["__col_pages"]["email_activities"]["header_properties"]) == 3
        assert Enum.count(root["__blobs"]) == 1

        # Raw wire pointer check
        assert {:tagged, "pg", _} =
                 Xitdb.select!(root, ~s(.email_activities["77"].body), raw_tagged: true)

        assert {:tagged, "bp", _} =
                 Xitdb.select!(root, ~s(.email_activities["77"].attachment_blob),
                   raw_tagged: true
                 )

        # Full hydration via Ash.get! decodes compressed columnar + interned fields cleanly
        rec_77 = Ash.get!(EmailActivity, 77)
        assert rec_77.body == sample_body(77, "xenolith_alpha_marker")
        assert rec_77.html_edit_body == sample_edit_body(77)
        assert rec_77.attachment_blob == shared_attachment

        # Selective read omitting compressed columns performs ZERO page reads & decompressions
        Columnar.clear_cache()
        Columnar.reset_stats()

        projected =
          EmailActivity
          |> Ash.Query.select([:id, :title])
          |> Ash.Query.sort(:id)
          |> Ash.read!()

        assert length(projected) == 150
        first = hd(projected)
        assert first.id == 1
        assert first.title == "Deal Memo #1"
        assert %Ash.NotLoaded{type: :attribute, field: :body} = first.body
        assert %Ash.NotLoaded{type: :attribute, field: :html_edit_body} = first.html_edit_body

        assert %Ash.NotLoaded{type: :attribute, field: :header_properties} =
                 first.header_properties

        assert %Ash.NotLoaded{type: :attribute, field: :attachment_blob} = first.attachment_blob
        assert %{page_reads: 0, page_cache_hits: 0, page_decompressions: 0} = Columnar.stats()

        # BM25 Search matches keyword tokenized BEFORE body compression
        Columnar.clear_cache()
        Columnar.reset_stats()

        hits = Search.ids(EmailActivity, "xenolith_alpha_marker")
        assert hits == [77]

        matched_meta =
          EmailActivity
          |> Ash.Query.filter(id in ^hits)
          |> Ash.Query.select([:id, :title])
          |> Ash.read!()

        assert [%EmailActivity{id: 77, title: "Deal Memo #77", body: %Ash.NotLoaded{}}] =
                 matched_meta

        assert %{page_reads: 0, page_decompressions: 0} = Columnar.stats()

        # Pin snapshot cursor before single-row create & update
        snapshot_before_edit = CompMemStore.root()

        # Single-row Ash.create! compresses fields & reuses existing __blobs entry
        single =
          Ash.create!(
            Ash.Changeset.for_create(EmailActivity, :create, %{
              title: "Ad-hoc Urgent Notice",
              header_properties: "Content-Type: text/plain",
              body: sample_body(999, "single_create_keyword"),
              html_edit_body: sample_edit_body(999),
              attachment_blob: shared_attachment
            })
          )

        assert Enum.count(CompMemStore.root()["__blobs"]) == 1
        assert Search.ids(EmailActivity, "single_create_keyword") == [single.id]

        assert Ash.get!(EmailActivity, single.id).body ==
                 sample_body(999, "single_create_keyword")

        # Single-row Ash.update! compresses updated body, updates BM25, and preserves history
        updated =
          single
          |> Ash.Changeset.for_update(:update, %{
            body: sample_body(999, "revised_update_keyword")
          })
          |> Ash.update!()

        assert updated.body == sample_body(999, "revised_update_keyword")
        assert Search.ids(EmailActivity, "revised_update_keyword") == [single.id]
        assert Search.ids(EmailActivity, "single_create_keyword") == []

        # Historical snapshot retains row 77 unmodified
        old_77 =
          Store.with_as_of(CompMemStore, snapshot_before_edit, fn ->
            Ash.get!(EmailActivity, 77)
          end)

        assert old_77.body == sample_body(77, "xenolith_alpha_marker")
      end

      test "file-backed Ash store achieves >4x file shrinkage on compressed email rows vs raw" do
        tmp = Path.join(System.tmp_dir!(), "xitdb_ash_comp_#{System.unique_integer([:positive])}")
        File.mkdir_p!(tmp)
        on_exit(fn -> File.rm_rf(tmp) end)

        comp_path = Path.join(tmp, "comp.xit")
        raw_path = Path.join(tmp, "raw.xit")

        start_supervised!({CompFileStore, path: comp_path, domains: [FileDomain]})
        start_supervised!({RawFileStore, path: raw_path, domains: [FileDomain]})

        samples = for i <- 1..20, do: sample_body(i)

        {:ok, _db, _dict} =
          Dictionary.train_and_put(CompFileStore, :email_html, samples, target_size: 4_096)

        inputs =
          for i <- 1..150 do
            %{
              title: "Newsletter ##{i}",
              header_properties: "Content-Type: text/html; X-Tenant=firm-#{rem(i, 4)}",
              body: sample_body(i),
              html_edit_body: sample_edit_body(i)
            }
          end

        %Ash.BulkResult{status: :success} = Ash.bulk_create!(inputs, FileCompEmail, :create)
        %Ash.BulkResult{status: :success} = Ash.bulk_create!(inputs, FileRawEmail, :create)

        :ok = stop_supervised(CompFileStore)
        :ok = stop_supervised(RawFileStore)

        comp_bytes = File.stat!(comp_path).size
        raw_bytes = File.stat!(raw_path).size

        assert comp_bytes * 4 < raw_bytes
      end
    end
  end
end
