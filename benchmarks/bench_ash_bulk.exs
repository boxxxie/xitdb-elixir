# Ash Coalesced Bulk Create, Fast Attr Plan, Read Plan, ASCII Tokenizer & BM25 Rebuild Benchmark
#
# Run:
#   MIX_ENV=test mix run benchmarks/bench_ash_bulk.exs
#   ROWS=5000 RUNS=5 WARMUP=1 MIX_ENV=test mix run benchmarks/bench_ash_bulk.exs

defmodule Xitdb.AshBulkBench do
  alias Xitdb.Ash.{Codec, Indexer, Search, Store}

  @default_rows 2_000
  @default_runs 5
  @default_warmup 1
  @tokenize_iters 10_000
  @codec_iters 5_000

  defmodule BenchStore do
    use Xitdb.Ash.Store
  end

  defmodule Domain do
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource(Xitdb.AshBulkBench.Organization)
      resource(Xitdb.AshBulkBench.Affiliation)
      resource(Xitdb.AshBulkBench.ResolvedAffiliation)
    end
  end

  defmodule Organization do
    use Ash.Resource,
      domain: Xitdb.AshBulkBench.Domain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store(BenchStore)
      collection(:bench_orgs)
      index([:tier])
      search_field(:name, boost: 4.0)
      search_field(:mandate, boost: 1.0)
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
      attribute(:slug, :string, allow_nil?: false, public?: true)
      attribute(:tier, :string, allow_nil?: false, public?: true)
      attribute(:mandate, :string, public?: true)
      attribute(:active, :boolean, default: true, allow_nil?: false, public?: true)
    end

    identities do
      identity(:unique_slug, [:slug])
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        primary?(true)
        accept([:id, :name, :slug, :tier, :mandate, :active])
      end
    end
  end

  defmodule Affiliation do
    use Ash.Resource,
      domain: Xitdb.AshBulkBench.Domain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store(BenchStore)
      collection(:bench_affiliations)
      nested_in(:bench_orgs, foreign_key: :org_id, path: :affiliations, cardinality: :many)
      index([:department])
      search_field(:role, boost: 2.0)
    end

    attributes do
      attribute(:id, :integer,
        primary_key?: true,
        allow_nil?: false,
        generated?: true,
        writable?: true,
        public?: true
      )

      attribute(:org_id, :integer, allow_nil?: false, public?: true)
      attribute(:role, :string, allow_nil?: false, public?: true)
      attribute(:department, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        primary?(true)
        accept([:id, :org_id, :role, :department])
      end
    end
  end

  defmodule ResolvedAffiliation do
    use Ash.Resource,
      domain: Xitdb.AshBulkBench.Domain,
      data_layer: Xitdb.Ash.DataLayer

    xitdb do
      store(BenchStore)
      collection(:bench_resolved_affiliations)
      search_field(:role, boost: 2.0)

      search_field(:org_name,
        boost: 1.5,
        resolver: fn record, db ->
          case Process.get(:bench_org_names) do
            names when is_map(names) ->
              Map.get(names, record.org_id)

            _ ->
              Search.lookup_field(db, Organization, record.org_id, "name")
          end
        end
      )
    end

    attributes do
      attribute(:id, :integer,
        primary_key?: true,
        allow_nil?: false,
        generated?: true,
        writable?: true,
        public?: true
      )

      attribute(:org_id, :integer, allow_nil?: false, public?: true)
      attribute(:role, :string, allow_nil?: false, public?: true)
    end

    actions do
      defaults([:read, :destroy])

      create :create do
        primary?(true)
        accept([:id, :org_id, :role])
      end
    end
  end

  def run do
    total_rows = env_int("ROWS", @default_rows, 10)
    runs = env_int("RUNS", @default_runs, 1)
    warmup = env_int("WARMUP", @default_warmup, 0)

    IO.puts(
      "\n=== Xitdb v2.3.0 Ash & Search Bulk Benchmark (ROWS=#{total_rows}, RUNS=#{runs}, WARMUP=#{warmup}) ===\n"
    )

    warm_ash_runtime()

    bench_tokenizer(runs, warmup)
    bench_codec_plan(runs, warmup)
    bench_hydration(total_rows, runs, warmup)
    bench_fresh_bulk_create_and_rebuild(total_rows, runs, warmup)
    bench_populated_append(total_rows, runs, warmup)
    bench_allow_existing_overwrite(total_rows, runs, warmup)
    bench_resolver_rebuild(total_rows, runs, warmup)
    bench_buffered_file_bulk(total_rows, runs, warmup)
  end

  defp env_int(name, default, min_val) do
    case System.get_env(name) do
      nil -> default
      val -> max(String.to_integer(val), min_val)
    end
  end

  defp warm_ash_runtime do
    with_store(:memory, fn ->
      orgs = build_org_inputs(1..8)

      %{status: :success, records: recs} =
        Ash.bulk_create!(orgs, Organization, :create,
          domain: Domain,
          batch_size: 8,
          return_records?: true
        )

      %{status: :success} =
        Ash.bulk_create!(build_aff_inputs(1..8, 4), Affiliation, :create,
          domain: Domain,
          batch_size: 8,
          return_records?: false,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      :ok = Search.index_records!(BenchStore, Organization, recs, parallel: false)
      :ok = Search.rebuild_index!(BenchStore, Organization, parallel: false)
      _ = Ash.read!(Organization, domain: Domain)

      _ =
        Organization
        |> Ash.Query.select([:id, :name])
        |> Ash.read!(domain: Domain)

      _ = Search.ids(Organization, "northleaf", limit: 5)
    end)
  end

  defp bench_tokenizer(runs, warmup) do
    ascii_samples = {
      "Northleaf Senior Private Credit IV (Toronto)",
      "VP, Institutional Capital & Alternative Investments 2026",
      "HarbourVest Global Secondaries IX - Pending Signoff",
      "Polar Asset Management Macro Fund: Q4 Allocation Memo"
    }

    unicode_samples = {
      "Café Müller & Söhne — Private Credit №1",
      "Société Générale résumé façade naïve Zürich"
    }

    ascii_stats =
      measure_runs(runs, warmup, @tokenize_iters, fn ->
        for i <- 1..@tokenize_iters do
          _ = Search.tokenize(elem(ascii_samples, rem(i, 4)))
        end
      end)

    unicode_stats =
      measure_runs(runs, warmup, @tokenize_iters, fn ->
        for i <- 1..@tokenize_iters do
          _ = Search.tokenize(elem(unicode_samples, rem(i, 2)))
        end
      end)

    ascii_ns = ascii_stats.median_us * 1_000 / @tokenize_iters
    unicode_ns = unicode_stats.median_us * 1_000 / @tokenize_iters

    IO.puts("## 1. Search.tokenize/1 (#{@tokenize_iters} calls/run)")

    IO.puts(
      "  ASCII fast-path : #{round(ascii_ns)} ns/call (CV #{fmt_pct(ascii_stats.cv_pct)}, #{ascii_stats.rate_per_sec} calls/s)"
    )

    IO.puts(
      "  Unicode fallback: #{round(unicode_ns)} ns/call (CV #{fmt_pct(unicode_stats.cv_pct)}, #{unicode_stats.rate_per_sec} calls/s)"
    )

    IO.puts(
      "  Speedup         : #{:erlang.float_to_binary(unicode_ns / max(ascii_ns, 1.0), decimals: 2)}x\n"
    )
  end

  defp bench_codec_plan(runs, warmup) do
    plan = Codec.compile_attr_plan(Organization)

    sample_org = %Organization{
      id: 42,
      name: "Northleaf Capital Partners",
      slug: "northleaf-42",
      tier: "institutional",
      mandate: "Senior Private Credit & Infrastructure",
      active: true
    }

    slow_stats =
      measure_runs(runs, warmup, @codec_iters, fn ->
        for _ <- 1..@codec_iters do
          {:ok, _} = Codec.to_cursor_map(Organization, sample_org)
        end
      end)

    fast_stats =
      measure_runs(runs, warmup, @codec_iters, fn ->
        for _ <- 1..@codec_iters do
          {:ok, _} = Codec.to_cursor_map_fast(plan, sample_org)
        end
      end)

    slow_ns = slow_stats.median_us * 1_000 / @codec_iters
    fast_ns = fast_stats.median_us * 1_000 / @codec_iters

    IO.puts("## 2. Codec Attribute Plan (#{@codec_iters} structs/run)")

    IO.puts(
      "  to_cursor_map/2      : #{round(slow_ns)} ns/struct (CV #{fmt_pct(slow_stats.cv_pct)}, #{slow_stats.rate_per_sec} structs/s)"
    )

    IO.puts(
      "  to_cursor_map_fast/2 : #{round(fast_ns)} ns/struct (CV #{fmt_pct(fast_stats.cv_pct)}, #{fast_stats.rate_per_sec} structs/s)"
    )

    IO.puts(
      "  Speedup              : #{:erlang.float_to_binary(slow_ns / max(fast_ns, 1.0), decimals: 2)}x\n"
    )
  end

  defp bench_hydration(total_rows, runs, warmup) do
    org_inputs = build_org_inputs(1..total_rows)

    with_store(:memory, fn ->
      %{status: :success} =
        Ash.bulk_create!(org_inputs, Organization, :create,
          domain: Domain,
          batch_size: min(total_rows, 1_000),
          return_records?: false,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      root = Store.root(BenchStore)
      cursors = Indexer.all_cursors(root, Organization)
      read_plan = Codec.compile_read_plan(Organization, :all)
      read_plan_sel = Codec.compile_read_plan(Organization, [:id, :name])

      from_cursor_stats =
        measure_runs(runs, warmup, total_rows, fn ->
          Enum.each(cursors, fn {_doc_id, cur} ->
            {:ok, _rec} = Codec.from_cursor(Organization, cur)
          end)
        end)

      from_cursor_fast_stats =
        measure_runs(runs, warmup, total_rows, fn ->
          Enum.each(cursors, fn {_doc_id, cur} ->
            {:ok, _rec} = Codec.from_cursor_fast(read_plan, cur)
          end)
        end)

      from_cursor_sel_stats =
        measure_runs(runs, warmup, total_rows, fn ->
          Enum.each(cursors, fn {_doc_id, cur} ->
            {:ok, _rec} = Codec.from_cursor_fast(read_plan_sel, cur)
          end)
        end)

      ash_read_stats =
        measure_runs(runs, warmup, total_rows, fn ->
          recs = Ash.read!(Organization, domain: Domain)
          true = length(recs) == total_rows
        end)

      ash_read_sel_stats =
        measure_runs(runs, warmup, total_rows, fn ->
          recs =
            Organization
            |> Ash.Query.select([:id, :name])
            |> Ash.read!(domain: Domain)

          true = length(recs) == total_rows
        end)

      speedup = from_cursor_stats.median_us / max(from_cursor_fast_stats.median_us, 1)

      IO.puts("## 3. Cursor Hydration & Ash.read! (#{total_rows} rows)")
      print_table_header()
      print_stats_row("Codec.from_cursor/4 (:all)", from_cursor_stats)
      print_stats_row("Codec.from_cursor_fast/3 (:all)", from_cursor_fast_stats)
      print_stats_row("Codec.from_cursor_fast/3 (select: [:id, :name])", from_cursor_sel_stats)
      print_stats_row("Ash.read!(Organization)", ash_read_stats)
      print_stats_row("Ash.read!(Organization, select: [:id, :name])", ash_read_sel_stats)
      IO.puts("  from_cursor_fast speedup: #{:erlang.float_to_binary(speedup, decimals: 2)}x\n")
    end)
  end

  defp bench_fresh_bulk_create_and_rebuild(total_rows, runs, warmup) do
    org_inputs = build_org_inputs(1..total_rows)
    aff_inputs = build_aff_inputs(1..total_rows, max(div(total_rows, 4), 1))
    batch_size = min(total_rows, 1_000)

    eager_stats =
      measure_runs(runs, warmup, total_rows, fn ->
        with_store(:memory, fn ->
          {t_us, %{status: :success}} =
            :timer.tc(fn ->
              Ash.bulk_create!(org_inputs, Organization, :create,
                domain: Domain,
                batch_size: batch_size,
                return_records?: false
              )
            end)

          {:timed, t_us}
        end)
      end)

    deferred_stats =
      measure_runs(runs, warmup, total_rows, fn ->
        with_store(:memory, fn ->
          {t_us, %{status: :success}} =
            :timer.tc(fn ->
              Ash.bulk_create!(org_inputs, Organization, :create,
                domain: Domain,
                batch_size: batch_size,
                return_records?: false,
                context: %{xitdb: %{skip_search_index?: true}}
              )
            end)

          {:timed, t_us}
        end)
      end)

    {seq_stats, par_stats} =
      with_store(:memory, fn ->
        %{status: :success} =
          Ash.bulk_create!(org_inputs, Organization, :create,
            domain: Domain,
            batch_size: batch_size,
            return_records?: false,
            context: %{xitdb: %{skip_search_index?: true}}
          )

        seq =
          measure_runs(runs, warmup, total_rows, fn ->
            :ok = Search.rebuild_index!(BenchStore, Organization, parallel: false)
          end)

        par =
          measure_runs(runs, warmup, total_rows, fn ->
            :ok = Search.rebuild_index!(BenchStore, Organization, parallel: true)
          end)

        hits = Search.ids(Organization, "northleaf", limit: 10)
        true = length(hits) == min(10, total_rows)
        {seq, par}
      end)

    org_count = max(div(total_rows, 4), 1)
    parent_inputs = build_org_inputs(1..org_count)

    nested_stats =
      measure_runs(runs, warmup, total_rows, fn ->
        with_store(:memory, fn ->
          %{status: :success} =
            Ash.bulk_create!(parent_inputs, Organization, :create,
              domain: Domain,
              batch_size: min(org_count, 1_000),
              return_records?: false,
              context: %{xitdb: %{skip_search_index?: true}}
            )

          {t_us, %{status: :success}} =
            :timer.tc(fn ->
              Ash.bulk_create!(aff_inputs, Affiliation, :create,
                domain: Domain,
                batch_size: batch_size,
                return_records?: false,
                context: %{xitdb: %{skip_search_index?: true}}
              )
            end)

          {:timed, t_us}
        end)
      end)

    nested_rebuild_stats =
      with_store(:memory, fn ->
        %{status: :success} =
          Ash.bulk_create!(parent_inputs, Organization, :create,
            domain: Domain,
            batch_size: min(org_count, 1_000),
            return_records?: false,
            context: %{xitdb: %{skip_search_index?: true}}
          )

        %{status: :success} =
          Ash.bulk_create!(aff_inputs, Affiliation, :create,
            domain: Domain,
            batch_size: batch_size,
            return_records?: false,
            context: %{xitdb: %{skip_search_index?: true}}
          )

        s =
          measure_runs(runs, warmup, total_rows, fn ->
            :ok = Search.rebuild_index!(BenchStore, Affiliation, parallel: true)
          end)

        nhits = Search.ids(Affiliation, "partner", limit: 10)
        true = length(nhits) == min(10, total_rows)
        s
      end)

    IO.puts(
      "## 4. Fresh Coalesced Ash.bulk_create! & Search.rebuild_index!/3 (#{total_rows} rows, :memory)"
    )

    print_table_header()
    print_stats_row("Ash.bulk_create! (standard, eager search)", eager_stats)
    print_stats_row("Ash.bulk_create! (standard, skip_search_index?: true)", deferred_stats)
    print_stats_row("Search.rebuild_index! (parallel: false)", seq_stats)
    print_stats_row("Search.rebuild_index! (parallel: true)", par_stats)
    print_stats_row("Ash.bulk_create! (nested_in :many, skip_search_index?: true)", nested_stats)

    print_stats_row(
      "Search.rebuild_index! (nested_in :many, parallel: true)",
      nested_rebuild_stats
    )

    IO.puts("")
  end

  defp bench_populated_append(total_rows, runs, warmup) do
    seed_inputs = build_org_inputs(1..total_rows)
    append_batch_size = max(div(total_rows, 10), 10)
    append_rows = append_batch_size * 10
    append_inputs = build_org_inputs((total_rows + 1)..(total_rows + append_rows))

    tmp =
      Path.join(System.tmp_dir!(), "xitdb_ash_append_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    try do
      eager_seed_path = Path.join(tmp, "eager_seed.xit")
      def_seed_path = Path.join(tmp, "def_seed.xit")

      with_store(eager_seed_path, fn ->
        %{status: :success} =
          Ash.bulk_create!(seed_inputs, Organization, :create,
            domain: Domain,
            batch_size: min(total_rows, 1_000),
            return_records?: false
          )

        :ok = Xitdb.NIF.nif_sync(Store.root(BenchStore).db_ref)
      end)

      with_store(def_seed_path, fn ->
        %{status: :success} =
          Ash.bulk_create!(seed_inputs, Organization, :create,
            domain: Domain,
            batch_size: min(total_rows, 1_000),
            return_records?: false,
            context: %{xitdb: %{skip_search_index?: true}}
          )

        :ok = Xitdb.NIF.nif_sync(Store.root(BenchStore).db_ref)
      end)

      eager_append_stats =
        measure_runs(runs, warmup, append_rows, fn ->
          run_path = Path.join(tmp, "run_eager_#{System.unique_integer([:positive])}.xit")
          File.cp!(eager_seed_path, run_path)

          with_store(run_path, fn ->
            {t_us, %{status: :success}} =
              :timer.tc(fn ->
                Ash.bulk_create!(append_inputs, Organization, :create,
                  domain: Domain,
                  batch_size: append_batch_size,
                  return_records?: false
                )
              end)

            {:timed, t_us}
          end)
        end)

      deferred_append_stats =
        measure_runs(runs, warmup, append_rows, fn ->
          run_path = Path.join(tmp, "run_def_#{System.unique_integer([:positive])}.xit")
          File.cp!(def_seed_path, run_path)

          with_store(run_path, fn ->
            {t_us, :ok} =
              :timer.tc(fn ->
                %{status: :success} =
                  Ash.bulk_create!(append_inputs, Organization, :create,
                    domain: Domain,
                    batch_size: append_batch_size,
                    return_records?: false,
                    context: %{xitdb: %{skip_search_index?: true}}
                  )

                :ok = Search.rebuild_index!(BenchStore, Organization, parallel: true)
              end)

            {:timed, t_us}
          end)
        end)

      inc_append_stats =
        measure_runs(runs, warmup, append_rows, fn ->
          run_path = Path.join(tmp, "run_inc_#{System.unique_integer([:positive])}.xit")
          File.cp!(def_seed_path, run_path)

          with_store(run_path, fn ->
            {t_us, :ok} =
              :timer.tc(fn ->
                %{status: :success, records: appended_records} =
                  Ash.bulk_create!(append_inputs, Organization, :create,
                    domain: Domain,
                    batch_size: append_batch_size,
                    return_records?: true,
                    context: %{xitdb: %{skip_search_index?: true}}
                  )

                :ok =
                  Search.index_records!(BenchStore, Organization, appended_records,
                    parallel: true
                  )
              end)

            {:timed, t_us}
          end)
        end)

      IO.puts(
        "## 5. Populated-Table Append (#{total_rows} existing -> +#{append_rows} in 10×#{append_batch_size} batches)"
      )

      print_table_header()
      print_stats_row("Append 10×#{append_batch_size} (eager search)", eager_append_stats)

      print_stats_row(
        "Append 10×#{append_batch_size} (skip_search + parallel rebuild)",
        deferred_append_stats
      )

      print_stats_row(
        "Append 10×#{append_batch_size} (skip_search + Search.index_records!)",
        inc_append_stats
      )

      IO.puts("")
    after
      File.rm_rf!(tmp)
    end
  end

  defp bench_allow_existing_overwrite(total_rows, runs, warmup) do
    overwrite_rows = min(total_rows, 1_000)

    seed_inputs =
      Enum.map(1..overwrite_rows, fn i ->
        %{
          id: i,
          name: "Organization #{i} Northleaf Credit Mandate",
          slug: "org-#{i}",
          tier: "tier_#{rem(i, 8)}",
          mandate: "Initial mandate ##{i}",
          active: rem(i, 2) == 0
        }
      end)

    overwrite_inputs =
      Enum.map(1..overwrite_rows, fn i ->
        %{
          id: i,
          name: "Updated Org #{i} Northleaf Capital",
          slug: "org-#{i}",
          tier: "tier_#{rem(i + 1, 8)}",
          mandate: nil,
          active: rem(i, 2) == 1
        }
      end)

    with_store(:memory, fn ->
      %{status: :success} =
        Ash.bulk_create!(seed_inputs, Organization, :create,
          domain: Domain,
          batch_size: overwrite_rows,
          return_records?: false,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      overwrite_stats =
        measure_runs(runs, warmup, overwrite_rows, fn ->
          %{status: :success} =
            Ash.bulk_create!(overwrite_inputs, Organization, :create,
              domain: Domain,
              batch_size: overwrite_rows,
              return_records?: false,
              context: %{xitdb: %{allow_existing_cursor?: true, skip_search_index?: true}}
            )
        end)

      IO.puts("## 6. Bulk Overwrite (allow_existing_cursor?: true, #{overwrite_rows} rows)")
      print_table_header()
      print_stats_row("Ash.bulk_create! (overwrite, skip_search_index?: true)", overwrite_stats)
      IO.puts("")
    end)
  end

  defp bench_resolver_rebuild(total_rows, runs, warmup) do
    org_count = max(div(total_rows, 4), 1)
    org_inputs = build_org_inputs(1..org_count)

    resolved_inputs =
      Enum.map(1..total_rows, fn i ->
        %{
          org_id: rem(i - 1, org_count) + 1,
          role: "Principal #{rem(i, 25)} Credit"
        }
      end)

    with_store(:memory, fn ->
      %{status: :success} =
        Ash.bulk_create!(org_inputs, Organization, :create,
          domain: Domain,
          batch_size: min(org_count, 1_000),
          return_records?: false,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      %{status: :success} =
        Ash.bulk_create!(resolved_inputs, ResolvedAffiliation, :create,
          domain: Domain,
          batch_size: min(total_rows, 1_000),
          return_records?: false,
          context: %{xitdb: %{skip_search_index?: true}}
        )

      wrapper = fn cursor_root, work ->
        names =
          for {id_str, org_cur} <- Enum.to_list(cursor_root["bench_orgs"]), into: %{} do
            {String.to_integer(id_str), org_cur["name"]}
          end

        Process.put(:bench_org_names, names)

        try do
          work.()
        after
          Process.delete(:bench_org_names)
        end
      end

      resolver_stats =
        measure_runs(runs, warmup, total_rows, fn ->
          :ok =
            Search.rebuild_index!(BenchStore, ResolvedAffiliation,
              parallel: true,
              only_attrs: [:org_id, :role],
              worker_wrapper: wrapper
            )
        end)

      hits = Search.ids(ResolvedAffiliation, "northleaf", limit: 10)
      true = length(hits) == min(10, total_rows)

      IO.puts("## 7. Search.rebuild_index! with resolver + worker_wrapper (#{total_rows} rows)")
      print_table_header()
      print_stats_row("Search.rebuild_index! (resolver, parallel: true)", resolver_stats)
      IO.puts("")
    end)
  end

  defp bench_buffered_file_bulk(total_rows, runs, warmup) do
    org_inputs = build_org_inputs(1..total_rows)
    batch_size = min(total_rows, 500)

    tmp =
      Path.join(System.tmp_dir!(), "xitdb_ash_disk_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    try do
      eager_stats =
        measure_runs(runs, warmup, total_rows, fn ->
          path = Path.join(tmp, "eager_#{System.unique_integer([:positive])}.xit")

          with_store(path, fn ->
            {t_us, :ok} =
              :timer.tc(fn ->
                %{status: :success} =
                  Ash.bulk_create!(org_inputs, Organization, :create,
                    domain: Domain,
                    batch_size: batch_size,
                    return_records?: false
                  )

                :ok = Xitdb.NIF.nif_sync(Store.root(BenchStore).db_ref)
              end)

            {:timed, t_us}
          end)
        end)

      deferred_stats =
        measure_runs(runs, warmup, total_rows, fn ->
          path = Path.join(tmp, "def_#{System.unique_integer([:positive])}.xit")

          with_store(path, fn ->
            {t_us, :ok} =
              :timer.tc(fn ->
                %{status: :success} =
                  Ash.bulk_create!(org_inputs, Organization, :create,
                    domain: Domain,
                    batch_size: batch_size,
                    return_records?: false,
                    context: %{xitdb: %{skip_search_index?: true}}
                  )

                :ok = Search.rebuild_index!(BenchStore, Organization, parallel: true)
                :ok = Xitdb.NIF.nif_sync(Store.root(BenchStore).db_ref)
              end)

            {:timed, t_us}
          end)
        end)

      IO.puts(
        "## 8. On-Disk :buffered_file Store + sync/1 (#{total_rows} rows, batch_size=#{batch_size})"
      )

      print_table_header()
      print_stats_row("Buffered_File eager + sync/1", eager_stats)
      print_stats_row("Buffered_File skip_search + parallel rebuild + sync/1", deferred_stats)
      IO.puts("")
    after
      File.rm_rf!(tmp)
    end
  end

  defp build_org_inputs(range) do
    Enum.map(range, fn i ->
      %{
        name: "Organization #{i} Northleaf Credit Mandate",
        slug: "org-#{i}",
        tier: "tier_#{rem(i, 8)}",
        mandate: "Private credit institutional allocation strategy ##{rem(i, 25)}",
        active: rem(i, 2) == 0
      }
    end)
  end

  defp build_aff_inputs(range, org_count) do
    Enum.map(range, fn i ->
      %{
        org_id: rem(i - 1, org_count) + 1,
        role: "Managing Partner #{rem(i, 20)} Credit Committee",
        department: "dept_#{rem(i, 6)}"
      }
    end)
  end

  defp with_store(path, fun) do
    {:ok, pid} = Store.start_link(name: BenchStore, path: path, domains: [Domain])

    try do
      fun.()
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp measure_runs(runs, warmup, count, fun) do
    if warmup > 0 do
      for _ <- 1..warmup, do: fun.()
    end

    samples_us =
      for _ <- 1..runs do
        {t_us, ret} = :timer.tc(fun)

        case ret do
          {:timed, inner_us} -> inner_us * 1.0
          _ -> t_us * 1.0
        end
      end

    sorted = Enum.sort(samples_us)
    med = percentile(sorted, 0.50)
    mean = Enum.sum(sorted) / runs

    var =
      if runs > 1 do
        Enum.reduce(sorted, 0.0, fn x, acc -> acc + (x - mean) * (x - mean) end) / (runs - 1)
      else
        0.0
      end

    stddev = :math.sqrt(var)
    cv_pct = stddev / max(mean, 1.0e-9) * 100.0
    rate = round(count / max(med / 1_000_000.0, 1.0e-9))

    %{
      median_us: med,
      mean_us: mean,
      stddev_us: stddev,
      cv_pct: cv_pct,
      rate_per_sec: rate
    }
  end

  defp percentile(sorted, p) do
    n = length(sorted)

    if n <= 1 do
      List.first(sorted) || 0.0
    else
      pos = p * (n - 1)
      lo = floor(pos)
      hi = min(lo + 1, n - 1)
      frac = pos - lo
      Enum.at(sorted, lo) + frac * (Enum.at(sorted, hi) - Enum.at(sorted, lo))
    end
  end

  defp print_table_header do
    IO.puts("| Workload | Median | Mean ± σ (CV) | Throughput |")
    IO.puts("| :--- | ---: | ---: | ---: |")
  end

  defp print_stats_row(label, s) do
    med_ms = :erlang.float_to_binary(s.median_us / 1_000.0, decimals: 2)
    mean_ms = :erlang.float_to_binary(s.mean_us / 1_000.0, decimals: 2)
    sd_ms = :erlang.float_to_binary(s.stddev_us / 1_000.0, decimals: 2)

    IO.puts(
      "| #{label} | #{med_ms} ms | #{mean_ms} ± #{sd_ms} ms (#{fmt_pct(s.cv_pct)}) | #{s.rate_per_sec} rows/s |"
    )
  end

  defp fmt_pct(v), do: :erlang.float_to_binary(v, decimals: 1) <> "%"
end

Xitdb.AshBulkBench.run()
