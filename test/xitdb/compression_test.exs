defmodule Xitdb.CompressionTest.EncoderBox do
  defstruct [:payload, :mode]
end

defimpl Xitdb.Encoder, for: Xitdb.CompressionTest.EncoderBox do
  def encode(%Xitdb.CompressionTest.EncoderBox{payload: payload, mode: :directive}) do
    {:compressed, payload, codec: :zstd, min_bytes: 0}
  end

  def encode(%Xitdb.CompressionTest.EncoderBox{payload: payload, mode: :plain}) do
    %{"nested_text" => payload}
  end
end

defmodule Xitdb.CompressionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Xitdb.DSL

  alias Xitdb.Compression
  alias Xitdb.Compression.Dictionary
  alias Xitdb.Error

  @html_header """
  <!DOCTYPE html><html><head><meta charset="utf-8"><style>
  body { font-family: Arial, sans-serif; color: #222222; background: #f8f9fa; }
  .header { border-bottom: 1px solid #dee2e6; padding: 12px 16px; }
  .footer { font-size: 11px; color: #6c757d; margin-top: 24px; }
  </style></head><body><div class="header">CAASA CRM Notification</div><div class="content">
  """

  @html_footer """
  </div><div class="footer">Confidentiality Notice: This email and any files transmitted with it
  are confidential and intended solely for the use of the individual or entity to whom they are addressed.
  Copyright (c) 2026 CAASA Financial Group. All rights reserved.</div></body></html>
  """

  describe "Xitdb.Compression codec framing & bounds validation" do
    test "round-trips empty and small binaries without emitting compressed tags" do
      assert Compression.compress("") == ""
      assert Compression.compress("hello world") == "hello world"
      assert Compression.decompress("") == {:ok, ""}
      assert Compression.decompress("hello world") == {:ok, "hello world"}

      below_threshold = String.duplicate("a", 127)
      assert Compression.compress(below_threshold, min_bytes: 128) == below_threshold
    end

    test "falls back to uncompressed binary for incompressible random bytes" do
      random_bytes = :crypto.strong_rand_bytes(512)
      assert Compression.compress(random_bytes, codec: :zlib) == random_bytes
      assert Compression.compress(random_bytes, codec: :zstd) == random_bytes
    end

    test "round-trips :zlib ('cz') and :zstd ('zs') on compressible UTF-8 strings and binaries" do
      text = String.duplicate("Important quarterly portfolio review & legal disclaimer. ", 40)

      cz = Compression.compress(text, codec: :zlib)
      assert {:tagged, "cz", payload_cz} = cz
      assert byte_size(payload_cz) + 16 <= byte_size(text)
      assert {:ok, ^text} = Compression.decompress(cz)
      assert Compression.decompress!(cz) == text

      zs = Compression.compress(text, codec: :zstd)
      assert {:tagged, "zs", payload_zs} = zs
      assert byte_size(payload_zs) + 16 <= byte_size(text)
      assert {:ok, ^text} = Compression.decompress(zs)
      assert Compression.decompress!(zs) == text

      bin_with_nuls = :binary.copy(<<0, 1, 2, 255, 128, 0>>, 80)
      assert {:tagged, "cz", _} = cz_bin = Compression.compress(bin_with_nuls, codec: :zlib)
      assert {:ok, ^bin_with_nuls} = Compression.decompress(cz_bin)

      assert {:tagged, "zs", _} = zs_bin = Compression.compress(bin_with_nuls, codec: :zstd)
      assert {:ok, ^bin_with_nuls} = Compression.decompress(zs_bin)
    end

    test "rejects truncated, unknown-version, forged raw_len, zip-bomb, and corrupt payloads cleanly" do
      text = String.duplicate("Corrupt test payload boilerplate! ", 20)
      {:tagged, "cz", cz_payload} = Compression.compress(text, codec: :zlib)
      {:tagged, "zs", zs_payload} = Compression.compress(text, codec: :zstd)

      # Truncated headers (< 5 bytes)
      for tag <- ["cz", "zs", "zd", "bp", "pg"] do
        assert {:error, %Error{}} = Compression.decompress({:tagged, tag, <<0x10, 1>>})
      end

      # Unknown version byte
      <<_ver, rest_cz::binary>> = cz_payload

      assert {:error, %Error{reason: :corrupt_compressed_payload}} =
               Compression.decompress({:tagged, "cz", <<0x7F, rest_cz::binary>>})

      <<_ver_zs, rest_zs::binary>> = zs_payload

      assert {:error, %Error{reason: :corrupt_compressed_payload}} =
               Compression.decompress({:tagged, "zs", <<0x7F, rest_zs::binary>>})

      # Oversized raw_len claim against max_decompressed_bytes
      huge_len = 10_000_000
      <<ver_cz, _raw_len::unsigned-little-32, deflated::binary>> = cz_payload

      assert {:error, %Error{reason: :decompressed_size_exceeded}} =
               Compression.decompress(
                 {:tagged, "cz", <<ver_cz, huge_len::unsigned-little-32, deflated::binary>>},
                 max_decompressed_bytes: 1_024
               )

      <<ver_zs, _z_len::unsigned-little-32, zframe::binary>> = zs_payload

      assert {:error, %Error{reason: :decompressed_size_exceeded}} =
               Compression.decompress(
                 {:tagged, "zs", <<ver_zs, huge_len::unsigned-little-32, zframe::binary>>},
                 max_decompressed_bytes: 1_024
               )

      # Zip-bomb: small compressed payload expanding past small raw_len / max_decompressed_bytes
      bomb_raw = :binary.copy(<<0>>, 200_000)
      bomb_deflated = :zlib.compress(bomb_raw)

      assert {:error, %Error{reason: :decompressed_size_exceeded}} =
               Compression.decompress(
                 {:tagged, "cz", <<0x10, 200_000::unsigned-little-32, bomb_deflated::binary>>},
                 max_decompressed_bytes: 65_536
               )

      assert {:error, %Error{reason: :corrupt_compressed_payload}} =
               Compression.decompress(
                 {:tagged, "cz", <<0x10, 64::unsigned-little-32, bomb_deflated::binary>>},
                 max_decompressed_bytes: 1_048_576
               )

      # Corrupt stream bytes
      assert {:error, %Error{reason: :corrupt_compressed_payload}} =
               Compression.decompress(
                 {:tagged, "cz", <<0x10, 100::unsigned-little-32, 0, 1, 2, 3>>}
               )

      assert {:error, %Error{reason: :corrupt_compressed_payload}} =
               Compression.decompress(
                 {:tagged, "zs", <<0x10, 100::unsigned-little-32, 0, 1, 2, 3>>}
               )

      # Missing dict in offline decompress
      assert {:error, %Error{reason: :missing_compression_dictionary}} =
               Compression.decompress(
                 {:tagged, "zd", <<0x10, 10::unsigned-little-32, 4, "html", "abc">>}
               )
    end

    property "lossless round-trip across arbitrary UTF-8 strings and binary blobs for :zlib and :zstd" do
      check all(
              codec <- member_of([:zlib, :zstd]),
              min_bytes <- member_of([0, 64, 128]),
              payload <-
                one_of([
                  string(:printable, min_length: 0, max_length: 2_500),
                  binary(min_length: 0, max_length: 2_500),
                  map(string(:alphanumeric, min_length: 8, max_length: 40), fn s ->
                    String.duplicate(s, 10)
                  end)
                ])
            ) do
        encoded = Compression.compress(payload, codec: codec, min_bytes: min_bytes)
        assert {:ok, ^payload} = Compression.decompress(encoded)
      end
    end
  end

  describe "Shared dictionary training & 'zd' framing" do
    test "trains dictionary from HTML email corpus and improves small-message compression" do
      samples =
        for i <- 1..60 do
          @html_header <> "Hello Customer ##{i}, your report #{i * 7} is ready." <> @html_footer
        end

      dict_bytes = Dictionary.train_dictionary(samples, target_size: 8_192)
      assert is_binary(dict_bytes)
      assert byte_size(dict_bytes) > 0 and byte_size(dict_bytes) <= 8_192

      single_email = @html_header <> "Dear Valued Client #999, balance updated." <> @html_footer

      no_dict_zs = Compression.compress(single_email, codec: :zstd)

      with_dict_zd =
        Compression.compress(single_email,
          codec: :zstd,
          dictionary: :email_html,
          dictionary_bytes: dict_bytes
        )

      assert {:tagged, "zd", zd_payload} = with_dict_zd
      assert {:tagged, "zs", zs_payload} = no_dict_zs
      assert byte_size(zd_payload) < byte_size(zs_payload)

      assert {:ok, ^single_email} =
               Compression.decompress(with_dict_zd, dictionary_bytes: dict_bytes)

      # Also verify :zlib dictionary mode (0x12)
      with_zlib_dict =
        Compression.compress(single_email,
          codec: :zlib,
          dictionary: :email_html,
          dictionary_bytes: dict_bytes
        )

      assert {:tagged, "zd", <<0x12, _::binary>>} = with_zlib_dict

      assert {:ok, ^single_email} =
               Compression.decompress(with_zlib_dict, dictionary_bytes: dict_bytes)
    end

    test "persists dictionary immutably in __dicts and resolves 'zd' transparently across snapshots" do
      samples =
        for i <- 1..30 do
          @html_header <> "Quarterly summary #{i} for account." <> @html_footer
        end

      db = Xitdb.open!(backend: :memory)

      {:ok, db, dict_bytes} =
        Dictionary.train_and_put(db, :email_html, samples, target_size: 4_096)

      assert db["__dicts"]["email_html"] == dict_bytes

      body0 = @html_header <> "Snapshot 0 message" <> @html_footer
      body1 = @html_header <> "Snapshot 1 updated message" <> @html_footer

      db =
        Xitdb.transact!(
          db,
          %{"emails" => %{"e1" => %{"body" => {:compressed, body0, dictionary: :email_html}}}}
        )

      db =
        Xitdb.transact!(
          db,
          fn root ->
            put_in(
              root["emails"]["e1"]["body"],
              {:compressed, body1, dictionary: :email_html, codec: :zlib}
            )
          end
        )

      assert Xitdb.as_of(db, 1)["emails"]["e1"]["body"] == body0
      assert db["emails"]["e1"]["body"] == body1
      assert {:tagged, "zd", _} = Xitdb.select!(db, ".emails.e1.body", raw_tagged: true)
      assert Xitdb.select!(db, ".emails.e1.body") == body1
      assert Xitdb.pull!(db, "{emails{e1{body}}}") == %{"emails" => %{"e1" => %{"body" => body1}}}
    end
  end

  describe "Content-addressed blob interning (__blobs + 'bp') and native NIF decoding" do
    test "interning deduplicates 1,000+ identical large payloads across transactions" do
      tmp_dir = Path.join(System.tmp_dir!(), "xitdb_intern_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      path_raw = Path.join(tmp_dir, "raw.xit")
      path_intern = Path.join(tmp_dir, "intern.xit")

      disclaimer = String.duplicate("CAASA Standard Legal & Compliance Disclaimer Text. ", 40)

      # Uncompressed baseline
      db_raw = Xitdb.open!(backend: :buffered_file, path: path_raw)

      raw_batch =
        Map.new(1..1_050, fn i ->
          {Integer.to_string(i), %{"header" => disclaimer, "idx" => i}}
        end)

      db_raw = Xitdb.transact!(db_raw, %{"emails" => raw_batch})
      raw_size = Xitdb.info!(db_raw).file_size
      Xitdb.close(db_raw)

      # Interned across two separate commits
      db = Xitdb.open!(backend: :buffered_file, path: path_intern)

      batch1 =
        Map.new(1..600, fn i ->
          {Integer.to_string(i), %{"header" => disclaimer, "idx" => i}}
        end)

      batch2 =
        Map.new(601..1_050, fn i ->
          {Integer.to_string(i), %{"header" => disclaimer, "idx" => i}}
        end)

      db =
        Xitdb.transact!(
          db,
          %{"emails" => batch1},
          compress: [codec: :zstd, intern: true]
        )

      db =
        Xitdb.transact!(
          db,
          fn root ->
            Enum.reduce(batch2, root, fn {k, v}, acc ->
              put_in(acc["emails"][k], v)
            end)
          end,
          compress: [codec: :zstd, intern: true]
        )

      intern_size = Xitdb.info!(db).file_size
      assert intern_size * 5 < raw_size
      assert Enum.count(db["__blobs"]) == 1
      assert db["emails"]["1"]["header"] == disclaimer
      assert db["emails"]["1050"]["header"] == disclaimer
      assert {:tagged, "bp", _} = Xitdb.select!(db, ~s(.emails["500"].header), raw_tagged: true)

      Xitdb.close(db)
    end

    test "native NIF decodes 'cz' cleanly across Access, select, pull, materialize, Datalog, and rejects corrupt 'cz'" do
      body = String.duplicate("Detailed CRM Activity HTML Content Block ", 30)
      db = Xitdb.open!(backend: :memory)

      db =
        tx! db do
          put emails["1"].subject, "Quarterly Review"
          put emails["1"].body, {:compressed, body, codec: :zlib}
          put emails["2"].body, {:compressed, body, intern: true, codec: :zlib}
        end

      assert db["emails"]["1"]["body"] == body
      assert Xitdb.select!(db, ~s(.emails["1"].body)) == body
      assert {:tagged, "cz", _} = Xitdb.select!(db, ~s(.emails["1"].body), raw_tagged: true)

      assert %{"emails" => %{"1" => %{"body" => ^body}}} =
               Xitdb.pull!(db, "{emails{1{body}}}")

      assert %{"emails" => %{"1" => %{"body" => {:tagged, "cz", _}}}} =
               Xitdb.pull!(db, "{emails{1{body}}}", raw_tagged: true)

      assert %{"emails" => %{"1" => %{"body" => ^body, "subject" => "Quarterly Review"}}} =
               Xitdb.materialize(db)
               |> Map.take(["emails"])
               |> then(&%{"emails" => %{"1" => &1["emails"]["1"]}})

      # Datalog predicate over compressed & interned values
      assert {:ok, %{rows: rows}} =
               Xitdb.query(
                 db,
                 ~s{find ?id where .emails[?id].body = ?b, contains(?b, "CRM Activity")}
               )

      assert Enum.sort(rows) == [["1"], ["2"]]

      # Corrupt "cz" in storage fails with Xitdb.Error without crashing BEAM
      db =
        Xitdb.transact!(db, %{
          "bad" => %{"payload" => {:tagged, "cz", <<0x10, 500::unsigned-little-32, 1, 2, 3>>}}
        })

      assert {:error, %Error{reason: :corrupt_compressed_payload}} =
               Xitdb.select(db, ".bad.payload")

      assert_raise Error, fn ->
        db["bad"]["payload"]
      end
    end
  end

  describe "diff_moments/3,4 and garbage-collecting compact/2" do
    test "diff_moments/3,4 compares decoded logical values across compression tags and hides internal roots by default" do
      body_head = "<!DOCTYPE html><html><body><div>"
      body_tail = "</div><footer>CAASA Legal Disclaimer Block</footer></body></html>"
      samples = for i <- 1..15, do: body_head <> "Email item ##{i}" <> body_tail
      shared_blob = String.duplicate("Shared large legal annex binary block. ", 25)

      db = Xitdb.open!(backend: :memory)
      {:ok, db, _dict} = Dictionary.train_and_put(db, :html_dict, samples, target_size: 4_096)

      # Moment 1: commit compressed values + dict values + interned blob
      db =
        tx! db do
          put emails["e1"].subject, "Statement Q1"

          put emails["e1"].body,
              {:compressed, String.duplicate("Q1 detailed cashflow line item. ", 20),
               codec: :zlib}

          put emails["e2"].body, {:compressed, hd(samples), dictionary: :html_dict}
          put emails["e3"].attachment, {:compressed, shared_blob, intern: true, codec: :zstd}
        end

      # Moment 2: add columnar rows
      db =
        Xitdb.Columnar.put_rows!(
          db,
          "col_emails",
          [
            {"1", %{"title" => "Meta 1", "body" => Enum.at(samples, 1)}},
            {"2", %{"title" => "Meta 2", "body" => Enum.at(samples, 2)}}
          ],
          columns: [:body],
          row_group_size: 64,
          codec: :zstd
        )

      # Moment 3: edit only e1.body and add e4, delete e2
      db =
        tx! db do
          put emails["e1"].body,
              {:compressed, String.duplicate("Q1 UPDATED cashflow line item. ", 20), codec: :zstd}

          put emails["e4"].body,
              {:compressed, String.duplicate("New advisory memo payload. ", 20), codec: :zlib}

          rm emails["e2"]
        end

      # Moment 1 (dict) -> Moment 3 hides unchanged e3 and internal roots
      {:ok, changes} = Xitdb.diff_moments(db, 1, 3)

      assert Enum.any?(changes, fn
               %{path: ".emails.e1.body", op: :put, new_value: v} ->
                 v == String.duplicate("Q1 UPDATED cashflow line item. ", 20)

               _ ->
                 false
             end)

      assert Enum.any?(changes, fn
               %{path: ".emails.e4.body", op: :put, new_value: v} ->
                 v == String.duplicate("New advisory memo payload. ", 20)

               %{path: ".emails.e4", op: :put, new_value: %{"body" => v}} ->
                 v == String.duplicate("New advisory memo payload. ", 20)

               _ ->
                 false
             end)

      assert Enum.any?(changes, fn
               %{path: ".col_emails", op: :put, new_value: %{"1" => %{"body" => v}}} ->
                 v == Enum.at(samples, 1)

               _ ->
                 false
             end)

      assert Enum.any?(changes, fn
               %{path: ".emails.e2", op: :remove} -> true
               _ -> false
             end)

      refute Enum.any?(changes, &String.contains?(&1.path, "__blobs"))
      refute Enum.any?(changes, &String.contains?(&1.path, "__dicts"))
      refute Enum.any?(changes, &String.contains?(&1.path, "__col_pages"))
      refute Enum.any?(changes, &(&1.path == ".emails.e3.attachment"))

      # raw_tagged: true preserves raw format_tag tuples
      {:ok, raw_changes} = Xitdb.diff_moments(db, 1, 3, raw_tagged: true)

      assert Enum.any?(raw_changes, fn
               %{path: ".emails.e1.body", op: :put, new_value: {:tagged, "zs", _}} -> true
               _ -> false
             end)

      # include_internal: true surfaces internal roots
      {:ok, internal_changes} = Xitdb.diff_moments(db, 1, 3, include_internal: true)

      assert Enum.any?(internal_changes, &String.starts_with?(&1.path, ".__col_pages"))
    end

    test "compact/2 preserves compressed format_tags without re-inflation and GCs orphaned __blobs, __dicts, and __col_pages" do
      tmp = Path.join(System.tmp_dir!(), "xitdb_gc_compact_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      src_path = Path.join(tmp, "source.xit")
      comp_path = Path.join(tmp, "compacted.xit")
      comp2_path = Path.join(tmp, "compacted_all_removed.xit")

      head = "<!DOCTYPE html><html><body><div class=\"card\">"
      tail = "</div><footer>CAASA CRM Archive Footer</footer></body></html>"

      live_samples =
        for i <- 1..15,
            do: head <> "Live dict email ##{i} quarterly advisory dispatch statement" <> tail

      page_samples =
        for i <- 1..15,
            do: head <> "Live page dict email ##{i} quarterly advisory dispatch statement" <> tail

      live_blob = String.duplicate("LIVE interned annex payload. ", 40)
      dead_blob = String.duplicate("ORPHANED interned annex payload that gets replaced. ", 120)

      db = Xitdb.open!(backend: :buffered_file, path: src_path)
      {:ok, db, _} = Dictionary.train_and_put(db, :live_dict, live_samples, target_size: 4_096)
      {:ok, db, _} = Dictionary.train_and_put(db, :page_dict, page_samples, target_size: 4_096)
      {:ok, db, _} = Dictionary.train_and_put(db, :orphan_dict, live_samples, target_size: 4_096)

      {:ok, db, _} =
        Dictionary.train_and_put(db, :old_page_dict, page_samples, target_size: 4_096)

      # Commit moment with dead blob + dead dict + live items
      live_zs_body = String.duplicate("Live zstd value body. ", 25)
      live_cz_body = String.duplicate("Live zlib value body. ", 25)
      live_zd_body = head <> "Live dict email #7 quarterly advisory dispatch statement" <> tail

      db =
        tx! db do
          put msgs["m_cz"], {:compressed, live_cz_body, codec: :zlib}
          put msgs["m_zs"], {:compressed, live_zs_body, codec: :zstd}
          put msgs["m_zd"], {:compressed, live_zd_body, dictionary: :live_dict}
          put msgs["m_bp_live"], {:compressed, live_blob, intern: true, codec: :zstd}
          put msgs["m_bp_dead"], {:compressed, dead_blob, intern: true, codec: :zstd}
          put msgs["m_zd_dead"], {:compressed, live_zd_body, dictionary: :orphan_dict}
        end

      # Write 2 columnar pages: one referencing :old_page_dict (to overwrite), one referencing :page_dict (kept)
      db =
        Xitdb.Columnar.put_rows!(
          db,
          "dead_col",
          [{"1", %{"body" => Enum.at(page_samples, 0)}}],
          columns: [{:body, encoding: :dict_block, dictionary: :old_page_dict}],
          row_group_size: 64,
          codec: :zstd
        )

      db =
        Xitdb.Columnar.put_rows!(
          db,
          "live_col",
          [
            {"1", %{"body" => Enum.at(page_samples, 1)}},
            {"2", %{"body" => Enum.at(page_samples, 2)}}
          ],
          columns: [{:body, encoding: :dict_block, dictionary: :page_dict}],
          row_group_size: 64,
          codec: :zstd
        )

      # Overwrite/remove the orphan references in HEAD
      db =
        tx! db do
          put msgs["m_bp_dead"], "tiny overwrite"
          rm msgs["m_zd_dead"]
          rm dead_col["1"]
        end

      src_size = Xitdb.info!(db).file_size
      assert Enum.count(db["__blobs"]) == 2
      assert Enum.count(db["__dicts"]) == 4

      {:ok, compacted} = Xitdb.compact(db, path: comp_path)
      Xitdb.close(db)

      comp_size = Xitdb.info!(compacted).file_size
      assert comp_size < src_size

      # Live compressed values decode identically AND kept their raw format_tags (never re-inflated!)
      assert compacted["msgs"]["m_cz"] == live_cz_body
      assert compacted["msgs"]["m_zs"] == live_zs_body
      assert compacted["msgs"]["m_zd"] == live_zd_body
      assert compacted["msgs"]["m_bp_live"] == live_blob
      assert compacted["msgs"]["m_bp_dead"] == "tiny overwrite"
      assert compacted["live_col"]["1"]["body"] == Enum.at(page_samples, 1)
      assert compacted["live_col"]["2"]["body"] == Enum.at(page_samples, 2)

      assert {:tagged, "cz", _} = Xitdb.select!(compacted, ".msgs.m_cz", raw_tagged: true)
      assert {:tagged, "zs", _} = Xitdb.select!(compacted, ".msgs.m_zs", raw_tagged: true)
      assert {:tagged, "zd", _} = Xitdb.select!(compacted, ".msgs.m_zd", raw_tagged: true)
      assert {:tagged, "bp", _} = Xitdb.select!(compacted, ".msgs.m_bp_live", raw_tagged: true)

      assert {:tagged, "pg", _} =
               Xitdb.select!(compacted, ~s(.live_col["1"].body), raw_tagged: true)

      # Dead __blobs, __dicts, and __col_pages were garbage-collected
      assert Enum.count(compacted["__blobs"]) == 1

      assert Map.keys(compacted["__dicts"] |> Xitdb.materialize()) |> Enum.sort() == [
               "live_dict",
               "page_dict"
             ]

      assert Xitdb.select!(compacted, ".__col_pages.dead_col") == nil
      assert Enum.count(compacted["__col_pages"]["live_col"]["body"]) == 1

      # When all remaining compression refs are removed, compact/2 prunes internal roots completely
      compacted =
        tx! compacted do
          rm msgs["m_zd"]
          rm msgs["m_bp_live"]
          rm live_col
        end

      {:ok, comp2} = Xitdb.compact(compacted, path: comp2_path)
      Xitdb.close(compacted)

      assert comp2["msgs"]["m_cz"] == live_cz_body
      assert comp2["msgs"]["m_zs"] == live_zs_body
      assert Xitdb.select!(comp2, ".__blobs") == nil
      assert Xitdb.select!(comp2, ".__dicts") == nil
      assert Xitdb.select!(comp2, ".__col_pages") == nil
      Xitdb.close(comp2)
    end
  end

  describe "regression coverage for datalog, GC containers, Xitdb.Encoder, and TxRuntime" do
    alias Xitdb.CompressionTest.EncoderBox

    test "Datalog predicates, joins, historical as_of, raw_tagged: true, and error propagation across all compression tags" do
      head =
        "Alpha <!DOCTYPE html><html><head><style>.mail{font-family:sans-serif;color:#1f2937}</style></head><body><div class=\"mail\">"

      tail =
        "</div><footer>Confidentiality Notice: Internal CAASA CRM Archive Disclosure.</footer></body></html>"

      dict_samples = for i <- 1..15, do: head <> " CRM Dict item ##{i}" <> tail

      cz_match = String.duplicate("Alpha CRM zlib match block. ", 15)
      zs_match = String.duplicate("Alpha CRM zstd match block. ", 15)
      zd_match = head <> " CRM dict match #3" <> tail
      bp_match = String.duplicate("Alpha CRM interned zstd blob block. ", 20)
      pg_match = String.duplicate("Alpha CRM columnar cell payload. ", 15)
      other_zs = String.duplicate("Beta archive unrelated zstd payload. ", 15)

      db = Xitdb.open!(backend: :memory)
      {:ok, db, _} = Dictionary.train_and_put(db, :dl_dict, dict_samples, target_size: 4_096)

      # Moment 1: commit cz, zs, zd, bp(zstd)
      db =
        tx! db do
          put docs["cz"].body, {:compressed, cz_match, codec: :zlib}
          put docs["zs"].body, {:compressed, zs_match, codec: :zstd}
          put docs["zd"].body, {:compressed, zd_match, dictionary: :dl_dict}
          put docs["bp"].body, {:compressed, bp_match, intern: true, codec: :zstd}
          put docs["other"].body, {:compressed, other_zs, codec: :zstd}
          put index_ref[zs_match], "zs"
        end

      # Moment 2: add columnar page row + update index_ref
      db =
        Xitdb.Columnar.put_rows!(
          db,
          "col_docs",
          [{"p1", %{"title" => "Col 1", "body" => pg_match}}],
          columns: [:body],
          codec: :zstd
        )

      m_with_bp = Xitdb.moment_count(db) - 1

      # Moment 3: overwrite bp entry in latest moment to remove bp ref (while Moment 2 retains it)
      db =
        tx! db do
          put docs["bp"].body, "replaced plaintext"
        end

      # Datalog contains / starts_with / equality predicates across cz, zs, zd, pg
      assert {:ok, %{rows: matched_ids}} =
               Xitdb.query(
                 db,
                 ~s{find ?id where .docs[?id].body = ?b, contains(?b, "CRM"), starts_with(?b, "Alpha")}
               )

      assert Enum.sort(matched_ids) == [["cz"], ["zd"], ["zs"]]

      assert {:ok, %{rows: [["p1"]]}} =
               Xitdb.query(
                 db,
                 ~s{find ?id where .col_docs[?id].body = ?b, ?b == "#{pg_match}"}
               )

      # Cross-clause join unifying compressed zs field against map key
      assert {:ok, %{rows: [["zs"]]}} =
               Xitdb.query(
                 db,
                 ~s{find ?hit where .docs["zs"].body = ?b, .index_ref[?b] = ?hit}
               )

      # Historical as_of query resolves __blobs & __dicts at target moment even after later overwrite
      assert {:ok, %{rows: [["bp"]]}} =
               Xitdb.query(
                 Xitdb.as_of(db, m_with_bp),
                 ~s{find ?id where .docs[?id].body = ?b, contains(?b, "interned zstd")},
                 []
               )

      # Verify historical bp value returns exact plaintext
      assert {:ok, %{rows: [[^bp_match]]}} =
               Xitdb.query(
                 db,
                 ~s{find ?b where @#{m_with_bp}.docs["bp"].body = ?b}
               )

      # raw_tagged: true returns {:tagged, tag, _} uniformly for cz, zs, zd, bp, and pg
      assert {:ok, %{rows: raw_rows}} =
               Xitdb.query(
                 db,
                 ~s{find ?id, ?b where @#{m_with_bp}.docs[?id].body = ?b},
                 raw_tagged: true
               )

      raw_by_id = Map.new(raw_rows, fn [k, v] -> {k, v} end)
      assert {:tagged, "cz", _} = raw_by_id["cz"]
      assert {:tagged, "zs", _} = raw_by_id["zs"]
      assert {:tagged, "zd", _} = raw_by_id["zd"]
      assert {:tagged, "bp", _} = raw_by_id["bp"]

      assert {:ok, %{rows: [["p1", {:tagged, "pg", _}]]}} =
               Xitdb.query(db, ~s{find ?id, ?b where .col_docs[?id].body = ?b}, raw_tagged: true)

      # Error propagation in Datalog: max_decompressed_bytes & corrupt payloads (not :unexpected_tag)
      assert {:error, %Error{reason: :decompressed_size_exceeded}} =
               Xitdb.query(
                 db,
                 ~s{find ?b where .docs["cz"].body = ?b},
                 max_decompressed_bytes: 16
               )

      assert {:error, %Error{reason: :decompressed_size_exceeded}} =
               Xitdb.query(
                 db,
                 ~s{find ?b where .docs["zs"].body = ?b},
                 max_decompressed_bytes: 16
               )

      db =
        Xitdb.transact!(db, %{
          "corrupt_dl" => %{
            "bad_cz" => {:tagged, "cz", <<0x10, 500::unsigned-little-32, 1, 2, 3>>},
            "bad_zs" => {:tagged, "zs", <<0x10, 500::unsigned-little-32, 1, 2, 3>>}
          }
        })

      assert {:error, %Error{reason: :corrupt_compressed_payload}} =
               Xitdb.query(db, ~s{find ?v where .corrupt_dl.bad_cz = ?v, contains(?v, "x")})

      assert {:error, %Error{reason: :corrupt_compressed_payload}} =
               Xitdb.query(db, ~s{find ?v where .corrupt_dl.bad_zs = ?v, contains(?v, "x")})

      Xitdb.close(db)
    end

    test "GC compact/2 handles nested non-default containers and leaves source handle intact" do
      tmp =
        Path.join(System.tmp_dir!(), "xitdb_gc_containers_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      live_blob = String.duplicate("Counted map live interned payload. ", 25)
      dead_blob = String.duplicate("Removed counted map dead interned payload. ", 40)

      db = Xitdb.open!(backend: :buffered_file, path: Path.join(tmp, "src.xit"))

      db =
        Xitdb.transact!(db, %{
          "bucket" =>
            Xitdb.counted_map(%{
              "keep" => {:compressed, live_blob, intern: true, codec: :zstd},
              "drop" => {:compressed, dead_blob, intern: true, codec: :zstd}
            })
        })

      db =
        tx! db do
          put bucket["drop"], "cleared"
        end

      assert Enum.count(db["__blobs"]) == 2
      assert {:ok, comp} = Xitdb.compact(db, path: Path.join(tmp, "comp.xit"))

      assert Enum.count(comp["__blobs"]) == 1
      assert comp["bucket"]["keep"] == live_blob
      assert comp["bucket"]["drop"] == "cleared"
      # Source handle remains readable and retains pre-GC blobs
      assert db["bucket"]["keep"] == live_blob
      assert Enum.count(db["__blobs"]) == 2

      Xitdb.close(comp)
      Xitdb.close(db)
    end

    test "Xitdb.transact/3 encodes Xitdb.Encoder structs before Compression.prepare_write/3 and TxRuntime materializes compressed put in staged_log" do
      long_a = String.duplicate("Encoder directive compression payload. ", 20)
      long_b = String.duplicate("Encoder plain auto-compressed payload. ", 20)
      staged_bin = String.duplicate("TxRuntime staged compression payload. ", 15)

      db = Xitdb.open!(backend: :memory)

      db =
        Xitdb.transact!(db, %{
          "dir_box" => %EncoderBox{payload: long_a, mode: :directive}
        })

      assert db["dir_box"] == long_a
      assert {:tagged, "zs", _} = Xitdb.select!(db, ".dir_box", raw_tagged: true)

      db =
        Xitdb.transact!(
          db,
          %{"plain_box" => %EncoderBox{payload: long_b, mode: :plain}},
          compress: [codec: :zstd, min_bytes: 32, min_savings: 8]
        )

      assert db["plain_box"]["nested_text"] == long_b
      assert {:tagged, "zs", _} = Xitdb.select!(db, ".plain_box.nested_text", raw_tagged: true)

      # TxRuntime.put records plaintext (not {:compressed, ...} tuple) in staged_log for subsequent update/fork
      db =
        tx! db do
          put staged.doc, {:compressed, staged_bin, codec: :zstd, min_bytes: 0}
          update staged.doc, fn current -> current <> " [UPDATED]" end
        end

      assert db["staged"]["doc"] == staged_bin <> " [UPDATED]"
      Xitdb.close(db)
    end
  end
end
