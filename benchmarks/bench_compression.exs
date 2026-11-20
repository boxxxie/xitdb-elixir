# Simulated CRM Email Corpus Compression & Projection Benchmark (N = 50,000 rows)
#
# Run:
#   mix run benchmarks/bench_compression.exs
#   ROWS=10000 mix run benchmarks/bench_compression.exs

defmodule Xitdb.CompressionBench do
  alias Xitdb.Columnar
  alias Xitdb.Compression.Dictionary

  @default_rows 50_000
  @batch_size 1_024
  @row_group_size 128

  @html_header """
  <!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8" />
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; color: #1e293b; background: #f8fafc; }
      .wrapper { max-width: 640px; margin: 0 auto; background: #ffffff; border: 1px solid #e2e8f0; border-radius: 6px; padding: 24px; }
      .header { border-bottom: 1px solid #e2e8f0; padding-bottom: 12px; margin-bottom: 16px; font-size: 13px; color: #475569; }
      .cta { display: inline-block; background: #0f172a; color: #ffffff; padding: 10px 18px; border-radius: 4px; text-decoration: none; }
      .footer { margin-top: 24px; padding-top: 12px; border-top: 1px solid #e2e8f0; font-size: 11px; color: #64748b; }
    </style>
  </head>
  <body><div class="wrapper">
    <div class="header">CAASA Alternative Investments CRM &bull; Confidential Institutional Correspondence</div>
  """

  @html_table """
    <table>
      <thead><tr><th>Mandate</th><th>Quarter</th><th>Commitment</th><th>Distribution</th><th>Status</th></tr></thead>
      <tbody>
        <tr><td>Northleaf Senior Private Credit IV</td><td>Q4 2026</td><td>$25,000,000</td><td>$1,420,500</td><td>Active</td></tr>
        <tr><td>Polar Asset Management Macro Fund</td><td>Q4 2026</td><td>$15,000,000</td><td>$890,250</td><td>Active</td></tr>
        <tr><td>harbourVest Global Secondaries IX</td><td>Q4 2026</td><td>$10,000,000</td><td>$640,000</td><td>Pending Signoff</td></tr>
      </tbody>
    </table>
    <p>Please review the updated capital call schedule, fee attribution memo, and counterparty KYC attestation inside the CAASA Connect portal before Friday 17:00 EST.</p>
  """

  @html_footer """
    <a class="cta" href="https://connect.caasa.org/activities/review">Open Institutional Data Room</a>
    <div class="footer">
      CONFIDENTIALITY NOTICE: This communication and any attached institutional allocation schedules are intended solely for designated recipients of the Canadian Association of Alternative Strategies &amp; Assets (CAASA). Unauthorized reproduction or distribution is strictly prohibited.
    </div>
  </div></body></html>
  """

  @headers_pool {
    "MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\nX-CAASA-Tenant: northleaf\r\nX-Folder: Sent Items",
    "MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\nX-CAASA-Tenant: polar\r\nX-Folder: Inbox",
    "MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\nX-CAASA-Tenant: harbour\r\nX-Folder: DealFlow",
    "MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\nX-CAASA-Tenant: maple\r\nX-Folder: Compliance"
  }

  @previews_pool {
    "Updated Q4 private credit distribution schedule & partner capital notice enclosed.",
    "Action required: review quarterly institutional allocation memo and fee attestation.",
    "Reminder: upcoming co-investment data room briefing on Thursday at 10:00 EST.",
    "Confirmation: counterparty subscription documents verified and archived."
  }

  def run do
    total_rows =
      case System.get_env("ROWS") do
        nil -> @default_rows
        val -> String.to_integer(val)
      end

    tmp = Path.join(System.tmp_dir!(), "xitdb_comp_bench_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    try do
      sample_bodies = for i <- 1..64, do: build_email_row(i) |> elem(1) |> Map.fetch!("body")
      dict_bytes = Dictionary.train_dictionary(sample_bodies, target_size: 16_384)
      raw_payload_bytes = estimate_raw_payload_bytes(total_rows)

      IO.puts("\n=== Xitdb Email Corpus Compression Benchmark (#{total_rows} rows) ===")

      IO.puts(
        "Simulated payload size (uncompressed strings only): #{format_mb(raw_payload_bytes)}\n"
      )

      raw_res = run_mode(tmp, :raw, total_rows, dict_bytes)
      zlib_res = run_mode(tmp, :zlib, total_rows, dict_bytes)
      dict_res = run_mode(tmp, :dict, total_rows, dict_bytes)
      rg_res = run_mode(tmp, :row_group, total_rows, dict_bytes)

      results = [raw_res, zlib_res, dict_res, rg_res]
      print_summary_table(results, raw_res.file_size, raw_payload_bytes)
    after
      File.rm_rf!(tmp)
    end
  end

  defp estimate_raw_payload_bytes(total_rows) do
    sample =
      1..16
      |> Enum.map(fn i ->
        {_k, map} = build_email_row(i)

        byte_size(map["title"]) + byte_size(map["header_properties"]) +
          byte_size(map["preview"]) + byte_size(map["body"]) + byte_size(map["html_edit_body"])
      end)
      |> Enum.sum()

    div(sample * total_rows, 16)
  end

  defp build_email_row(i) do
    hdr = elem(@headers_pool, rem(i, tuple_size(@headers_pool)))
    prev = elem(@previews_pool, rem(i, tuple_size(@previews_pool)))
    account = "ACC-#{100_000 + rem(i * 37, 900_000)}"
    partner = "Partner ##{rem(i, 400) + 1}"

    body =
      IO.iodata_to_binary([
        @html_header,
        "<p>Dear ",
        partner,
        ", reference mandate <strong>",
        account,
        "</strong> activity #",
        Integer.to_string(i),
        ":</p>",
        @html_table,
        @html_footer
      ])

    edit_body =
      IO.iodata_to_binary([
        @html_header,
        "<div class=\"editor\" data-seq=\"",
        Integer.to_string(i),
        "\">Draft revision for ",
        account,
        "</div>",
        @html_table,
        @html_footer
      ])

    row = %{
      "id" => i,
      "title" => "Mandate Activity #{account} ##{i}",
      "header_properties" => hdr,
      "preview" => prev,
      "body" => body,
      "html_edit_body" => edit_body
    }

    {Integer.to_string(i), row}
  end

  defp run_mode(tmp, mode, total_rows, dict_bytes) do
    path = Path.join(tmp, "#{mode}.xit")
    db = Xitdb.open!(backend: :buffered_file, path: path)

    db =
      if mode in [:dict, :row_group] do
        Dictionary.put!(db, :email_html, dict_bytes)
      else
        db
      end

    {ingest_us, db} =
      :timer.tc(fn ->
        1..total_rows
        |> Stream.chunk_every(@batch_size)
        |> Enum.reduce(db, fn chunk_ids, acc_db ->
          rows = Enum.map(chunk_ids, &build_email_row/1)
          ingest_batch(acc_db, rows, mode)
        end)
      end)

    :ok = Xitdb.sync(db)
    file_size = Xitdb.info!(db).file_size

    # Warm / random point-read latency on `body`
    Columnar.clear_cache()
    Columnar.reset_stats()
    sample_ids = for k <- 1..200, do: Integer.to_string(rem(k * 7_919, total_rows) + 1)

    body_latencies_us =
      Enum.map(sample_ids, fn id ->
        {t, val} = :timer.tc(fn -> db["emails"][id]["body"] end)
        true = is_binary(val) and byte_size(val) > 500
        t
      end)

    # Zero-decompression metadata-only projection (`{id, title}`)
    Columnar.clear_cache()
    Columnar.reset_stats()
    meta_ids = for k <- 1..500, do: Integer.to_string(rem(k * 3_571, total_rows) + 1)

    meta_latencies_us =
      Enum.map(meta_ids, fn id ->
        {t, projected} = :timer.tc(fn -> Xitdb.pull!(db["emails"][id], "{id, title}") end)
        true = is_integer(projected["id"]) and is_binary(projected["title"])
        t
      end)

    col_stats = Columnar.stats()

    if mode == :row_group do
      true = col_stats.page_reads == 0 and col_stats.page_decompressions == 0
    end

    Xitdb.close(db)

    %{
      mode: mode,
      total_rows: total_rows,
      file_size: file_size,
      ingest_s: ingest_us / 1_000_000.0,
      rows_per_sec: total_rows / max(ingest_us / 1_000_000.0, 0.0001),
      body_p50_us: percentile(body_latencies_us, 0.50),
      body_p95_us: percentile(body_latencies_us, 0.95),
      meta_p50_us: percentile(meta_latencies_us, 0.50),
      meta_p95_us: percentile(meta_latencies_us, 0.95),
      meta_page_reads: col_stats.page_reads
    }
  end

  defp ingest_batch(db, rows, :raw) do
    ops =
      Enum.map(rows, fn {id, map} ->
        {:put, ["emails", id], map}
      end)

    {:ok, next_db} = Xitdb.transact_ops(db, ops)
    next_db
  end

  defp ingest_batch(db, rows, :zlib) do
    ops =
      Enum.map(rows, fn {id, map} ->
        compressed_map = %{
          "id" => map["id"],
          "title" => map["title"],
          "header_properties" =>
            {:compressed, map["header_properties"], codec: :zlib, min_bytes: 32},
          "preview" => {:compressed, map["preview"], codec: :zlib, min_bytes: 32},
          "body" => {:compressed, map["body"], codec: :zlib},
          "html_edit_body" => {:compressed, map["html_edit_body"], codec: :zlib}
        }

        {:put, ["emails", id], compressed_map}
      end)

    {:ok, next_db} = Xitdb.transact_ops(db, ops, compress: [codec: :zlib])
    next_db
  end

  defp ingest_batch(db, rows, :dict) do
    ops =
      Enum.map(rows, fn {id, map} ->
        compressed_map = %{
          "id" => map["id"],
          "title" => map["title"],
          "header_properties" =>
            {:compressed, map["header_properties"], codec: :zstd, min_bytes: 32},
          "preview" => {:compressed, map["preview"], codec: :zstd, min_bytes: 32},
          "body" => {:compressed, map["body"], dictionary: :email_html},
          "html_edit_body" => {:compressed, map["html_edit_body"], dictionary: :email_html}
        }

        {:put, ["emails", id], compressed_map}
      end)

    {:ok, next_db} = Xitdb.transact_ops(db, ops)
    next_db
  end

  defp ingest_batch(db, rows, :row_group) do
    Columnar.put_rows!(
      db,
      "emails",
      rows,
      columns: [
        {:body, encoding: :dict_block, dictionary: :email_html, codec: :zstd},
        {:html_edit_body, encoding: :dict_block, dictionary: :email_html, codec: :zstd},
        {:header_properties, encoding: :dict_rle, codec: :zstd},
        {:preview, encoding: :dict_rle, codec: :zstd}
      ],
      row_group_size: @row_group_size,
      codec: :zstd
    )
  end

  defp percentile([], _p), do: 0.0

  defp percentile(samples, p) do
    sorted = Enum.sort(samples)
    idx = min(length(sorted) - 1, trunc(p * length(sorted)))
    Enum.at(sorted, idx) * 1.0
  end

  defp format_mb(bytes) do
    :erlang.float_to_binary(bytes / (1024.0 * 1024.0), decimals: 2) <> " MB"
  end

  defp print_summary_table(results, raw_file_bytes, raw_payload_bytes) do
    IO.puts(
      "| Mode | File Size | File Ratio vs Raw | Payload Ratio | Ingest Throughput | Body Read p50 / p95 | Meta Select p50 / p95 | Meta Page Reads |"
    )

    IO.puts("| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")

    Enum.each(results, fn r ->
      file_ratio = raw_file_bytes / max(r.file_size, 1)
      payload_ratio = raw_payload_bytes / max(r.file_size, 1)

      IO.puts(
        "| `:#{r.mode}` | #{format_mb(r.file_size)} | #{:erlang.float_to_binary(file_ratio, decimals: 2)}x | #{:erlang.float_to_binary(payload_ratio, decimals: 2)}x | #{round(r.rows_per_sec)} rows/s (#{:erlang.float_to_binary(r.ingest_s, decimals: 2)}s) | #{round(r.body_p50_us)} / #{round(r.body_p95_us)} us | #{round(r.meta_p50_us)} / #{round(r.meta_p95_us)} us | #{r.meta_page_reads} |"
      )
    end)

    IO.puts("")
  end
end

Xitdb.CompressionBench.run()
