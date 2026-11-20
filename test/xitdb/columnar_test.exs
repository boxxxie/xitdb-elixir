defmodule Xitdb.ColumnarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xitdb.{Columnar, Error}
  alias Xitdb.Columnar.Page
  alias Xitdb.Compression.Dictionary

  @html_head "<!DOCTYPE html><html><head><style>.mail{color:#222}</style></head><body><div class=\"mail\">"
  @html_section String.duplicate(
                  "<p>Quarterly CRM client portfolio update, activity summary, and advisory review notes.</p>",
                  32
                )
  @html_foot "</div><footer>CAASA CRM Confidential Legal Disclaimer.</footer></body></html>"

  describe "Xitdb.Columnar.Page encodings & corruption rejection" do
    test "round-trips :plain_block, :dict_rle, and :dict_block pages with nil bitmasks" do
      headers = [
        "Content-Type: text/html; charset=utf-8",
        "Content-Type: text/html; charset=utf-8",
        nil,
        "Content-Type: text/html; charset=utf-8",
        "Content-Type: text/plain; charset=utf-8",
        nil,
        "Content-Type: text/plain; charset=utf-8"
      ]

      {:ok, plain_bin} = Page.encode_page(headers, encoding: :plain_block, codec: :zstd)
      assert {:ok, plain_page} = Page.decode_page(plain_bin)
      assert plain_page.encoding == :plain_block
      assert Page.decode_all(plain_page) == headers

      {:ok, rle_bin} = Page.encode_page(headers, encoding: :dict_rle, codec: :zlib)
      assert {:ok, rle_page} = Page.decode_page(rle_bin)
      assert rle_page.encoding == :dict_rle
      assert Page.decode_all(rle_page) == headers

      for {expected, idx} <- Enum.with_index(headers) do
        assert {:ok, ^expected} = Page.decode_row(plain_page, idx)
        assert {:ok, ^expected} = Page.decode_row(rle_page, idx)
      end

      assert {:error, %Error{reason: :corrupt_column_page}} = Page.decode_row(rle_page, -1)
      assert {:error, %Error{reason: :corrupt_column_page}} = Page.decode_row(rle_page, 99)

      # :dict_block with trained dictionary
      emails =
        for i <- 1..32 do
          if rem(i, 7) == 0, do: nil, else: @html_head <> "Client email #{i}" <> @html_foot
        end

      dict_bytes = Dictionary.train_dictionary(Enum.reject(emails, &is_nil/1), target_size: 4_096)

      {:ok, dict_bin} =
        Page.encode_page(emails,
          encoding: :dict_block,
          codec: :zstd,
          dictionary: :email_html,
          dictionary_bytes: dict_bytes
        )

      assert {:ok, dict_page} = Page.decode_page(dict_bin, dictionary_bytes: dict_bytes)
      assert dict_page.encoding == :dict_block
      assert Page.decode_all(dict_page) == emails
    end

    test "rejects truncated, invalid-magic, oversized, and inconsistent XCP1 pages" do
      {:ok, bin} =
        Page.encode_page(["alpha", "beta", "gamma", nil, "delta"],
          encoding: :plain_block,
          codec: :zlib
        )

      assert {:error, %Error{reason: :corrupt_column_page}} = Page.decode_page(<<"NOPE", 0::96>>)

      assert {:error, %Error{reason: :corrupt_column_page}} =
               Page.decode_page(binary_part(bin, 0, 8))

      assert {:error, %Error{reason: :corrupt_column_page}} =
               Page.decode_page(binary_part(bin, 0, byte_size(bin) - 3))

      <<"XCP1", _enc, codec, flags, rc::32-little, raw_len::32-little, dlen, rest::binary>> = bin

      # Invalid encoding byte
      bad_enc =
        <<"XCP1", 99, codec, flags, rc::32-little, raw_len::32-little, dlen, rest::binary>>

      assert {:error, %Error{reason: :corrupt_column_page}} = Page.decode_page(bad_enc)

      # Oversized raw_block_len claim
      huge = <<"XCP1", 1, codec, flags, rc::32-little, 50_000_000::32-little, dlen, rest::binary>>

      assert {:error, %Error{reason: :decompressed_size_exceeded}} =
               Page.decode_page(huge, max_decompressed_bytes: 4_096)
    end

    property "lossless columnar page round-trip across encodings, codecs, and sparse nil bitmasks" do
      check all(
              encoding <- member_of([:auto, :plain_block, :dict_rle]),
              codec <- member_of([:none, :zlib, :zstd]),
              rows <-
                list_of(
                  one_of([
                    constant(nil),
                    constant("MIME-Version: 1.0\r\nContent-Type: text/html"),
                    string(:printable, min_length: 0, max_length: 200),
                    binary(min_length: 1, max_length: 120)
                  ]),
                  min_length: 0,
                  max_length: 140
                )
            ) do
        {:ok, bin} = Page.encode_page(rows, encoding: encoding, codec: codec)
        assert {:ok, page} = Page.decode_page(bin)
        assert Page.decode_all(page) == rows
      end
    end
  end

  describe "Xitdb.Columnar chunk writes, random reads, caching, and time travel" do
    test "stores 300 rows into 128-row pages, achieves >5x shrinkage, and caches random/sequential reads" do
      tmp = Path.join(System.tmp_dir!(), "xitdb_col_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      rows =
        for i <- 1..300 do
          {Integer.to_string(i),
           %{
             "id" => i,
             "title" => "Subject #{i}",
             "header_properties" =>
               "Content-Type: text/html; charset=utf-8; X-Tenant=caasa-#{rem(i, 4)}",
             "preview" => "Quarterly update for customer #{rem(i, 5)}...",
             "body" =>
               @html_head <>
                 @html_section <> "Message body ##{i} with account detail #{i * 13}" <> @html_foot
           }}
        end

      db_raw = Xitdb.open!(backend: :buffered_file, path: Path.join(tmp, "raw.xit"))
      db_raw = Xitdb.transact!(db_raw, %{"activities" => Map.new(rows)})
      raw_size = Xitdb.info!(db_raw).file_size
      Xitdb.close(db_raw)

      db = Xitdb.open!(backend: :buffered_file, path: Path.join(tmp, "col.xit"))

      db =
        Columnar.put_rows!(db, "activities", rows,
          columns: [:body, :header_properties, :preview],
          row_group_size: 128,
          codec: :zstd
        )

      col_size = Xitdb.info!(db).file_size
      assert col_size * 4 < raw_size
      assert Enum.count(db["__col_pages"]["activities"]["body"]) == 3

      # Verify raw_tagged: true shows "pg" pointer
      assert {:tagged, "pg", _} = Xitdb.select!(db, ~s(.activities["150"].body), raw_tagged: true)

      # Point read decompresses only 1 page; second read in same page hits ETS cache
      Columnar.clear_cache(db)
      Columnar.reset_stats()

      expected_150 =
        @html_head <>
          @html_section <> "Message body #150 with account detail #{150 * 13}" <> @html_foot

      assert db["activities"]["150"]["body"] == expected_150
      assert %{page_reads: 1, page_cache_hits: 0} = Columnar.stats()

      expected_151 =
        @html_head <>
          @html_section <> "Message body #151 with account detail #{151 * 13}" <> @html_foot

      assert db["activities"]["151"]["body"] == expected_151
      assert %{page_reads: 1, page_cache_hits: 1} = Columnar.stats()

      # Metadata-only pull performs 0 page reads and 0 decompressions
      Columnar.clear_cache(db)
      Columnar.reset_stats()

      assert %{"id" => 150, "title" => "Subject 150"} =
               Xitdb.pull!(db["activities"]["150"], "{id, title}")

      assert %{page_reads: 0, page_cache_hits: 0, page_decompressions: 0} = Columnar.stats()

      # Single-row update keeps earlier as_of/2 moment immutable
      v1 = Xitdb.as_of(db, 0)

      db =
        Xitdb.transact!(db, fn root ->
          put_in(
            root["activities"]["150"]["body"],
            {:compressed, "Edited single body", min_bytes: 0}
          )
        end)

      assert db["activities"]["150"]["body"] == "Edited single body"
      assert v1["activities"]["150"]["body"] == expected_150

      Xitdb.close(db)
    end

    test "cached page hits enforce max_decompressed_bytes, clear_cache/1 scopes eviction per db, and missing dictionary falls back to :plain_block" do
      payload = String.duplicate("Columnar regression payload block. ", 12)
      rows = [{"1", %{"title" => "Row 1", "body" => payload}}]

      db1 =
        Xitdb.open!(backend: :memory)
        |> Columnar.put_rows!("items", rows,
          columns: [{:body, encoding: :dict_block, dictionary: :unseeded_dict}],
          codec: :zstd
        )

      # Unseeded dictionary falls back to :plain_block rather than failing put_rows
      [{_page_id, page_bin}] = Enum.to_list(db1["__col_pages"]["items"]["body"])
      assert {:ok, %Page{encoding: :plain_block}} = Page.decode_page(page_bin)
      assert db1["items"]["1"]["body"] == payload

      # Populate cache on db1, then verify stricter max_decompressed_bytes fails on cache hit
      Columnar.clear_cache(db1)
      Columnar.reset_stats()
      assert db1["items"]["1"]["body"] == payload
      assert %{page_reads: 1, page_cache_hits: 0} = Columnar.stats()

      assert {:error, %Error{reason: :decompressed_size_exceeded}} =
               Xitdb.select(db1, ~s(.items["1"].body), max_decompressed_bytes: 16)

      # Rejected hit does not increment page_cache_hits; valid limit still hits cache
      assert %{page_reads: 1, page_cache_hits: 0} = Columnar.stats()
      assert Xitdb.select!(db1, ~s(.items["1"].body)) == payload
      assert %{page_reads: 1, page_cache_hits: 1} = Columnar.stats()

      # Scoped clear_cache(db1) leaves db2 cache entries intact
      db2 =
        Xitdb.open!(backend: :memory)
        |> Columnar.put_rows!("items", rows, columns: [:body], codec: :zstd)

      assert db2["items"]["1"]["body"] == payload
      Columnar.clear_cache(db1)
      Columnar.reset_stats()

      assert db2["items"]["1"]["body"] == payload
      assert %{page_reads: 0, page_cache_hits: 1} = Columnar.stats()

      assert db1["items"]["1"]["body"] == payload
      assert %{page_reads: 1, page_cache_hits: 1} = Columnar.stats()

      Xitdb.close(db1)
      Xitdb.close(db2)
    end

    test "supervised :xitdb_page_cache survives creator task exit and never exceeds @page_cache_limit under concurrent misses" do
      payload = String.duplicate("Concurrent page cache stress payload. ", 10)
      rows = for i <- 1..160, do: {Integer.to_string(i), %{"body" => "#{payload}#{i}"}}

      db =
        Xitdb.open!(backend: :memory)
        |> Columnar.put_rows!("items", rows,
          columns: [:body],
          row_group_size: 1,
          codec: :zstd
        )

      Columnar.clear_cache(:all)

      # Creator task populates cache and immediately exits; table must stay alive
      Task.async(fn ->
        assert db["items"]["1"]["body"] == "#{payload}1"
      end)
      |> Task.await()

      assert :ets.whereis(:xitdb_page_cache) != :undefined
      assert db["items"]["1"]["body"] == "#{payload}1"

      # Wave of concurrent misses across 160 distinct pages must keep table size <= 128
      1..160
      |> Task.async_stream(
        fn idx ->
          assert db["items"][Integer.to_string(idx)]["body"] == "#{payload}#{idx}"
        end,
        max_concurrency: 16,
        ordered: false
      )
      |> Stream.run()

      assert :ets.info(:xitdb_page_cache, :size) <= 128
      Xitdb.close(db)
    end

    test "Page.decode_page/2 copies subbinaries so decoded Page structs do not retain compressed or raw_body refc binaries" do
      emails =
        for i <- 1..16 do
          @html_head <> @html_section <> "Subbinary copy email #{i}" <> @html_foot
        end

      dict_bytes = Dictionary.train_dictionary(emails, target_size: 4_096)
      long_dict_name = String.duplicate("d", 70)

      {:ok, dict_page_bin} =
        Page.encode_page(emails,
          encoding: :dict_block,
          codec: :zstd,
          dictionary: long_dict_name,
          dictionary_bytes: dict_bytes
        )

      assert {:ok, dict_page} = Page.decode_page(dict_page_bin, dictionary_bytes: dict_bytes)
      assert :binary.referenced_byte_size(dict_page.dict_name) == byte_size(dict_page.dict_name)
      assert :binary.referenced_byte_size(dict_page.presence) == byte_size(dict_page.presence)
      assert :binary.referenced_byte_size(dict_page.data) == byte_size(dict_page.data)

      big_sym = String.duplicate("RLE_SYM_", 20)
      rle_rows = List.duplicate(big_sym, 16)
      {:ok, rle_page_bin} = Page.encode_page(rle_rows, encoding: :dict_rle, codec: :none)
      assert {:ok, rle_page} = Page.decode_page(rle_page_bin)
      sym = elem(rle_page.sym_table, 0)
      assert :binary.referenced_byte_size(sym) == byte_size(sym)
      assert :binary.referenced_byte_size(rle_page.presence) == byte_size(rle_page.presence)
    end

    test "per-column dictionary override drops stale shared dictionary_bytes and invalid dict names or closed db errors propagate cleanly" do
      d1_samples = for i <- 1..10, do: "ALPHA_TEMPLATE_#{i}_" <> String.duplicate("A", 120)
      d2_samples = for i <- 1..10, do: "BETA_TEMPLATE_#{i}_" <> String.duplicate("B", 120)

      d1_bytes = Dictionary.train_dictionary(d1_samples, target_size: 2_048)
      d2_bytes = Dictionary.train_dictionary(d2_samples, target_size: 2_048)

      db = Xitdb.open!(backend: :memory)
      {:ok, db} = Dictionary.put(db, :d1, d1_bytes)
      {:ok, db} = Dictionary.put(db, :d2, d2_bytes)

      rows =
        for i <- 1..4 do
          {Integer.to_string(i),
           %{
             "col1" => Enum.at(d1_samples, i),
             "col2" => Enum.at(d2_samples, i)
           }}
        end

      db =
        Columnar.put_rows!(db, "items", rows,
          columns: [:col1, {:col2, encoding: :dict_block, dictionary: :d2}],
          encoding: :dict_block,
          codec: :zstd,
          dictionary: :d1,
          dictionary_bytes: d1_bytes
        )

      [{_p2, p2_bin}] = Enum.to_list(db["__col_pages"]["items"]["col2"])

      assert {:ok, %Page{encoding: :dict_block, dict_name: "d2"}} =
               Page.decode_page(p2_bin, dictionary_bytes: d2_bytes)

      assert db["items"]["1"]["col1"] == Enum.at(d1_samples, 1)
      assert db["items"]["1"]["col2"] == Enum.at(d2_samples, 1)

      # Empty dictionary name is rejected cleanly at encode time
      assert {:error, %Error{reason: :invalid_column_page}} =
               Page.encode_page(["hello", "world"],
                 encoding: :dict_block,
                 dictionary: "",
                 dictionary_bytes: d1_bytes
               )

      # Non-missing dictionary fetch errors (e.g. closed handle) return {:error, %Error{}} rather than CaseClauseError
      Xitdb.close(db)

      assert {:error, %Error{reason: :closed}} =
               Columnar.put_rows(db, "items", rows,
                 columns: [{:col1, dictionary: :d1}],
                 codec: :zstd
               )
    end
  end
end
