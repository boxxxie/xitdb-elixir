# Client-Focused Statistical Benchmark Runner (Elixir Wrapper)
# Emits benchmarks/elixir.jsonl and appends to benchmarks/history.jsonl

defmodule Xitdb.ClientBench do
  alias Xitdb

  def run(opts \\ []) do
    runs = Keyword.get(opts, :runs, 5)
    warmup = Keyword.get(opts, :warmup, 1)
    commit_sha = resolve_git_commit()
    run_id = "run-#{System.os_time(:second)}"

    {:ok, db} = Xitdb.open(backend: :memory)
    db = seed_fixture_db(db, 500)

    root = Xitdb.db(db)
    users_cur = root["users"]
    sorted_cur = root["sorted_users"]
    items_cur = root["items"]
    linked_cur = root["linked"]
    cusers_cur = root["counted_users"]
    cset_cur = root["counted_set"]
    u0_cur = users_cur["u0"]

    {:ok, hist_db} = Xitdb.open(backend: :memory)

    hist_db =
      Enum.reduce(0..99, hist_db, fn i, acc ->
        {:ok, acc} =
          Xitdb.transact(acc, %{
            "users" => %{
              "alice" => %{"score" => i},
              "bob" => %{"score" => 1000}
            }
          })

        acc
      end)

    {:ok, diff_db} = Xitdb.open(backend: :memory)
    diff_db = seed_fixture_db(diff_db, 200)
    {:ok, diff_db} = Xitdb.transact(diff_db, fn r -> put_in(r["users"]["u42"]["age"], 99) end)

    {:ok, search_db} = Xitdb.open(backend: :memory)
    search_db = seed_bm25_fixture_db(search_db, 200)
    search_root = Xitdb.db(search_db)

    bm25_opts = %{
      match: :all,
      prefix: true,
      min_prefix_length: 3,
      max_prefix_expansions: 64,
      k1: 1.2,
      b: 0.75,
      exact_boost: 1.25,
      prefix_weight: 1.0
    }

    datalog_prefix_q = """
    find ?name, ?age
    where
      $username->id[?name] = ?id
      starts_with(?name, "user_001")
      .users[?id].age = ?age
      .users[?id].dept = "eng"
    """

    datalog_agg_q = """
    find ?dept, count(?id), sum(?age)
    where
      .users[?id].dept = ?dept
      .users[?id].age = ?age
    """

    benches = [
      {1, "Access: 3-hop lazy HAMT lookup (root[users][id][name])", 500,
       fn ->
         for i <- 0..499 do
           _ = root["users"]["u#{i}"]["name"]
         end

         0
       end},
      {2, "Access: Single-call selector select(.users.<id>.name)", 500,
       fn ->
         for i <- 0..499 do
           _ = Xitdb.select!(db, ".users.u#{i}.name")
         end

         0
       end},
      {3, "Access: Sorted_Map B+Tree key lookup (sorted[key])", 500,
       fn ->
         for i <- 0..499 do
           _ = sorted_cur["u#{i}"]
         end

         0
       end},
      {4, "Access: Array_List random index lookup (items[idx])", 500,
       fn ->
         for i <- 0..499 do
           _ = items_cur[rem(i * 37, 500)]
         end

         0
       end},
      {5, "Access: Linked_Array_List random index lookup (linked[idx])", 500,
       fn ->
         for i <- 0..499 do
           _ = linked_cur[rem(i * 37, 500)]
         end

         0
       end},
      {6, "Enum: O(1) Enum.count/1 on Counted_Hash_Map (N=500)", 1000,
       fn ->
         for _ <- 1..1000 do
           _ = Enum.count(cusers_cur)
         end

         0
       end},
      {7, "Enum: O(1) Enum.member?/2 on Counted_Hash_Set (N=500)", 1000,
       fn ->
         for i <- 0..999 do
           _ = Enum.member?(cset_cur, "u#{rem(i, 500)}")
         end

         0
       end},
      {8, "Enum: O(log N) Enum.slice/2 window (offset 200, len 20)", 200,
       fn ->
         for _ <- 1..200 do
           _ = Enum.slice(items_cur, 200, 20)
         end

         0
       end},
      {9, "Stream: Lazy Stream.take(10) early-halt on Sorted_Map", 200,
       fn ->
         for _ <- 1..200 do
           _ = sorted_cur |> Stream.take(10) |> Enum.to_list()
         end

         0
       end},
      {10, "Enum: Full Enum.to_list/1 stream over Array_List (N=500)", 500,
       fn ->
         _ = Enum.to_list(items_cur)
         0
       end},
      {11, "Materialize: Eager subtree materialize/1 (user profile)", 200,
       fn ->
         for _ <- 1..200 do
           _ = Xitdb.materialize(u0_cur)
         end

         0
       end},
      {12, "Tx: Single nested entity transact commit (6 attributes)", 100,
       fn ->
         {:ok, d} = Xitdb.open(backend: :memory)
         t0 = System.monotonic_time(:nanosecond)

         for i <- 0..99 do
           uid = "u#{i}"

           {:ok, _} =
             Xitdb.transact(d, %{
               "users" => %{
                 uid => %{
                   "name" => "Alice",
                   "age" => 30,
                   "dept" => "eng",
                   "city" => "Montreal",
                   "roles" => ["admin", "staff"]
                 }
               }
             })
         end

         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         {elapsed, sz}
       end},
      {13, "Tx: Bulk batch transact (100 entities in 1 commit)", 100,
       fn ->
         {:ok, d} = Xitdb.open(backend: :memory)
         t0 = System.monotonic_time(:nanosecond)

         users =
           Map.new(0..99, fn i ->
             {"u#{i}", %{"name" => "Alice", "age" => 30, "dept" => "eng"}}
           end)

         {:ok, _} = Xitdb.transact(d, %{"users" => users})
         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         {elapsed, sz}
       end},
      {14, "Tx: Incremental put_in nested attribute commit", 100,
       fn ->
         {:ok, d} = Xitdb.open(backend: :memory)
         {:ok, d} = Xitdb.transact(d, %{"users" => %{"alice" => %{"score" => 0}}})
         t0 = System.monotonic_time(:nanosecond)

         for i <- 1..100 do
           {:ok, _} = Xitdb.transact(d, fn r -> put_in(r["users"]["alice"]["score"], i) end)
         end

         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         {elapsed, sz}
       end},
      {15, "Tx: Linked_Array_List O(log N) mid-list insert + delete", 50,
       fn ->
         {:ok, d} = Xitdb.open(backend: :memory)
         init_list = Enum.map(0..499, &"item_#{&1}")
         {:ok, d} = Xitdb.transact(d, %{"linked" => Xitdb.linked_list(init_list)})
         t0 = System.monotonic_time(:nanosecond)

         for i <- 0..49 do
           {:ok, _} =
             Xitdb.transact(d, fn r ->
               r
               |> Xitdb.insert_at(["linked"], 250, "mid_#{i}")
               |> Xitdb.delete_at(["linked"], 250)
             end)
         end

         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         {elapsed, sz}
       end},
      {16, "Tx: O(1) zero-copy subtree fork (500 entities)", 100,
       fn ->
         {:ok, d} = Xitdb.open(backend: :memory)
         d = seed_fixture_db(d, 500)
         t0 = System.monotonic_time(:nanosecond)

         for i <- 0..99 do
           {:ok, _} =
             Xitdb.transact(d, fn r ->
               Xitdb.fork(r, ".users", ".users_clone_#{i}")
             end)
         end

         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         {elapsed, sz}
       end},
      {17, "Time-Travel: Historical as_of(db, m) across 100 moments", 100,
       fn ->
         for m <- 0..99 do
           snap = Xitdb.as_of(hist_db, m)
           _ = snap["users"]["alice"]["score"]
         end

         0
       end},
      {18, "Time-Travel: history_of(db, selector) (100 moments)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _} = Xitdb.history_of(hist_db, ".users.alice.score")
         end

         0
       end},
      {19, "Time-Travel: diff_moments (1 of 200 entities mutated)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _} = Xitdb.diff_moments(diff_db, 0, 1)
         end

         0
       end},
      {20, "Lifecycle: compact/1 100-moment database deduplication", 20,
       fn ->
         max_sz =
           Enum.reduce(1..20, 0, fn _, acc_sz ->
             {:ok, comp_db} = Xitdb.compact(hist_db)
             sz = Xitdb.info!(comp_db).file_size
             Xitdb.close(comp_db)
             max(acc_sz, sz)
           end)

         max_sz
       end},
      {21, "Query: Datomic pull projection (4 attrs + nested slice)", 200,
       fn ->
         for i <- 0..199 do
           cur = users_cur["u#{i}"]
           _ = Xitdb.pull!(cur, "{name, age, roles[0..2], profile{city}}")
         end

         0
       end},
      {22, "Query: Datalog B+Tree index prefix + join (N=200)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _} = Xitdb.query(diff_db, datalog_prefix_q)
         end

         0
       end},
      {23, "Query: Datalog grouped aggregation (count + sum, N=200)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _} = Xitdb.query(diff_db, datalog_agg_q)
         end

         0
       end},
      {24, "Storage: Buffered_File transact + sync (50 commits)", 50,
       fn ->
         tmp_path = "/tmp/xitdb_bench_elixir_#{System.unique_integer([:positive])}.xit"
         {:ok, d} = Xitdb.open(backend: :buffered_file, path: tmp_path)
         t0 = System.monotonic_time(:nanosecond)

         for i <- 0..49 do
           {:ok, _} = Xitdb.transact(d, %{"events" => %{"e#{i}" => i}})
         end

         :ok = Xitdb.sync(d)
         elapsed = System.monotonic_time(:nanosecond) - t0
         sz = Xitdb.info!(d).file_size
         Xitdb.close(d)
         File.rm(tmp_path)
         {elapsed, sz}
       end},
      {25, "Search: Sorted_Map B+Tree prefix seek (limit=16)", 100,
       fn ->
         for _ <- 1..100 do
           {:ok, _entries, _next} =
             Xitdb.NIF.nif_sorted_map_seek(
               db.db_ref,
               sorted_cur.tag_id,
               sorted_cur.value,
               "u4",
               16
             )
         end

         0
       end},
      {26, "Search: BM25 corpus search (N=200, 2-term prefix, limit=10)", 50,
       fn ->
         for _ <- 1..50 do
           {:ok, _hits} =
             Xitdb.NIF.nif_bm25_search(
               search_db.db_ref,
               search_root.tag_id,
               search_root.value,
               "articles",
               ["nord", "cap"],
               10,
               bm25_opts
             )
         end

         0
       end}
    ]

    records =
      Enum.map(benches, fn {rank, name, ops, fun} ->
        for _ <- 1..warmup, do: fun.()

        {samples_ns, max_bytes} =
          Enum.reduce(1..runs, {[], 0}, fn _, {acc, max_b} ->
            t0 = System.monotonic_time(:nanosecond)

            {elapsed_ns, bytes} =
              case fun.() do
                {el, b} -> {el, b}
                b when is_integer(b) -> {System.monotonic_time(:nanosecond) - t0, b}
              end

            ns_per_op = elapsed_ns / max(ops, 1)
            {[ns_per_op | acc], max(max_b, bytes)}
          end)

        samples = Enum.reverse(samples_ns)
        rec = build_record(rank, commit_sha, run_id, name, ops, runs, warmup, samples, max_bytes)

        IO.puts(
          :stderr,
          :io_lib.format("  [Elixir #~2..0B] ~-56s ~8B ns/op", [rank, name, rec.ns_per_op])
        )

        rec
      end)

    Xitdb.close(db)
    Xitdb.close(hist_db)
    Xitdb.close(diff_db)
    Xitdb.close(search_db)

    jsonl = Enum.map_join(records, "\n", &encode_json_line/1) <> "\n"
    File.write!("benchmarks/elixir.jsonl", jsonl)
    File.write!("benchmarks/history.jsonl", jsonl, [:append])
  end

  defp seed_fixture_db(db, n) do
    users =
      Map.new(0..(n - 1), fn i ->
        uid = "u#{i}"
        uname = :io_lib.format("user_~4..0B", [i]) |> IO.iodata_to_binary()
        dept = if rem(i, 2) == 0, do: "eng", else: "design"

        {uid,
         %{
           "name" => uname,
           "username" => uname,
           "dept" => dept,
           "age" => 20 + rem(i, 40),
           "roles" => ["member", "builder"],
           "profile" => %{"city" => "Montreal"}
         }}
      end)

    counted_users =
      Map.new(0..(n - 1), fn i ->
        {"u#{i}", :io_lib.format("user_~4..0B", [i]) |> IO.iodata_to_binary()}
      end)

    counted_set = Enum.map(0..(n - 1), &"u#{&1}")

    items =
      Enum.map(0..(n - 1), fn i ->
        :io_lib.format("user_~4..0B", [i]) |> IO.iodata_to_binary()
      end)

    {:ok, db} =
      Xitdb.transact(
        db,
        %{
          "users" => users,
          "counted_users" => Xitdb.counted_map(counted_users),
          "sorted_users" => Xitdb.sorted_map(counted_users),
          "counted_set" => Xitdb.counted_set(counted_set),
          "items" => items,
          "linked" => Xitdb.linked_list(items)
        },
        index_rules: [{:index_on, "users", "username", "username->id"}]
      )

    db
  end

  defp seed_bm25_fixture_db(db, n) do
    nord_variants = ["nordic", "north", "nordstrom"]
    cap_variants = ["capital", "captain", "cap", "capsule"]
    extra_terms = ["equity", "growth", "market", "credit", "buyout", "zurich", "london", "tokyo"]

    {docs_map, terms_map, total_len} =
      Enum.reduce(0..(n - 1), {%{}, %{}, 0}, fn i, {docs_acc, terms_acc, len_acc} ->
        doc_key = Integer.to_string(i + 1)
        t1 = Enum.at(nord_variants, rem(i, length(nord_variants)))
        t2 = Enum.at(cap_variants, rem(i, length(cap_variants)))
        t3 = Enum.at(extra_terms, rem(i, length(extra_terms)))
        doc_terms = [{t1, 300}, {t2, 200}, {t3, 100}]
        doc_len = 600

        new_terms =
          Enum.reduce(doc_terms, terms_acc, fn {term, tf}, t_acc ->
            postings = Map.get(t_acc, term, %{})
            Map.put(t_acc, term, Map.put(postings, doc_key, tf))
          end)

        new_docs = Map.put(docs_acc, doc_key, %{"len" => doc_len})
        {new_docs, new_terms, len_acc + doc_len}
      end)

    {:ok, db} =
      Xitdb.transact(db, %{
        "idx" => %{
          "search" => %{
            "articles" => %{
              "meta" => %{"doc_count" => n, "total_len" => total_len},
              "docs" => docs_map,
              "terms" => Xitdb.sorted_map(terms_map)
            }
          }
        }
      })

    db
  end

  defp build_record(rank, commit, run_id, name, ops, runs, warmup, samples, bytes_used) do
    sorted = Enum.sort(samples)
    min_ns = List.first(sorted)
    max_ns = List.last(sorted)
    med_ns = percentile(sorted, 0.50)
    q1_ns = percentile(sorted, 0.25)
    q3_ns = percentile(sorted, 0.75)
    iqr_ns = q3_ns - q1_ns
    p95_ns = percentile(sorted, 0.95)
    p99_ns = percentile(sorted, 0.99)
    mean_ns = Enum.sum(sorted) / runs

    var_ns2 =
      if runs > 1 do
        Enum.reduce(sorted, 0.0, fn x, acc -> acc + (x - mean_ns) * (x - mean_ns) end) /
          (runs - 1)
      else
        0.0
      end

    stddev_ns = :math.sqrt(var_ns2)
    cv_pct = stddev_ns / max(mean_ns, 1.0e-9) * 100.0
    total_ms = med_ns * max(ops, 1) / 1.0e6
    ops_per_sec = round(1.0e9 / max(med_ns, 1.0))

    %{
      rank: rank,
      lang: "elixir",
      commit: commit,
      run_id: run_id,
      name: name,
      ops: ops,
      runs: runs,
      warmup: warmup,
      total_ms: total_ms,
      ns_per_op: round(med_ns),
      mean_ns: mean_ns,
      median_ns: med_ns,
      stddev_ns: stddev_ns,
      variance_ns2: var_ns2,
      cv_pct: cv_pct,
      min_ns: round(min_ns),
      max_ns: round(max_ns),
      iqr_ns: iqr_ns,
      p95_ns: round(p95_ns),
      p99_ns: round(p99_ns),
      ops_per_sec: ops_per_sec,
      bytes_used: bytes_used,
      samples_ns: Enum.map(samples, &round/1)
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

  defp encode_json_line(r) do
    samples_str = Enum.map_join(r.samples_ns, ",", &Integer.to_string/1)

    :io_lib.format(
      "{\"rank\":~B,\"lang\":\"~s\",\"commit\":\"~s\",\"run_id\":\"~s\",\"name\":\"~s\",\"ops\":~B,\"runs\":~B,\"warmup\":~B,\"total_ms\":~.3f,\"ns_per_op\":~B,\"mean_ns\":~.2f,\"median_ns\":~.2f,\"stddev_ns\":~.2f,\"variance_ns2\":~.2f,\"cv_pct\":~.2f,\"min_ns\":~B,\"max_ns\":~B,\"iqr_ns\":~.2f,\"p95_ns\":~B,\"p99_ns\":~B,\"ops_per_sec\":~B,\"bytes_used\":~B,\"samples_ns\":[~s]}",
      [
        r.rank,
        r.lang,
        r.commit,
        r.run_id,
        r.name,
        r.ops,
        r.runs,
        r.warmup,
        r.total_ms,
        r.ns_per_op,
        r.mean_ns,
        r.median_ns,
        r.stddev_ns,
        r.variance_ns2,
        r.cv_pct,
        r.min_ns,
        r.max_ns,
        r.iqr_ns,
        r.p95_ns,
        r.p99_ns,
        r.ops_per_sec,
        r.bytes_used,
        samples_str
      ]
    )
    |> IO.iodata_to_binary()
  end

  defp resolve_git_commit do
    case System.cmd("git", ["rev-parse", "--short=12", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end

Xitdb.ClientBench.run()
