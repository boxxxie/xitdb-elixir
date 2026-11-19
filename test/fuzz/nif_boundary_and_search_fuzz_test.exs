defmodule Xitdb.Fuzz.NifBoundaryAndSearchFuzzTest do
  use ExUnit.Case, async: true
  use ExFuzz

  alias Xitdb
  alias Xitdb.Ash.Search

  @moduletag timeout: 1000

  if Code.ensure_loaded?(Ash.DataLayer) do
    defmodule FuzzDoc do
      @moduledoc false
      use Ash.Resource,
        domain: Xitdb.Fuzz.NifBoundaryAndSearchFuzzTest.FuzzDomain,
        data_layer: Xitdb.Ash.DataLayer

      xitdb do
        store Xitdb.Fuzz.NifBoundaryAndSearchFuzzTest.DummyStore
        collection :fuzz_docs
        search_field :title, boost: 2.0
        search_field :body, boost: 0.75
      end

      attributes do
        attribute(:id, :integer, primary_key?: true, allow_nil?: false, public?: true)
        attribute(:title, :string, public?: true)
        attribute(:body, :string, public?: true)
      end
    end

    defmodule FuzzDomain do
      @moduledoc false
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(Xitdb.Fuzz.NifBoundaryAndSearchFuzzTest.FuzzDoc)
      end
    end
  end

  setup_all do
    {:ok, db} = Xitdb.open(backend: :memory)

    {:ok, db} =
      Xitdb.transact(
        db,
        %{
          "users" => %{
            "alice" => %{
              "name" => "Alice",
              "age" => 31,
              "active" => true,
              "roles" => ["admin", "ops"],
              "tags" => Xitdb.counted_set(["core", "elixir"])
            },
            "bob" => %{
              "name" => "Bob",
              "age" => 28,
              "active" => false,
              "roles" => ["viewer"]
            }
          }
        },
        doc: "seed moment 1"
      )

    {:ok, db} =
      Xitdb.transact(
        db,
        fn root ->
          root
          |> put_in(["users", "alice", "age"], 32)
          |> put_in(["users", "alice", "roles"], ["admin", "ops", "lead"])
        end,
        doc: "seed moment 2"
      )

    on_exit(fn ->
      Xitdb.close(db)
    end)

    %{ro_db: db}
  end

  fuzz "NIF query/select/pull/history_of/transact_ops boundaries reject malformed inputs cleanly",
       data <- binary(),
       %{ro_db: ro_db},
       seeds: [
         ".users.alice",
         "{*, roles[0..2]}",
         "find ?x where .users[?id].name = ?x",
         "@0.users[0]",
         <<0, 255, 91, 93, 123, 125>>
       ] do
    assert_nif_result(fn -> Xitdb.select(ro_db, data) end)
    assert_nif_result(fn -> Xitdb.pull(ro_db, data) end)
    assert_nif_result(fn -> Xitdb.query(ro_db, data) end)
    assert_nif_result(fn -> Xitdb.history_of(ro_db, data) end)

    {:ok, tx_db} = Xitdb.open(backend: :memory)

    try do
      ops = decode_fuzz_tx_ops(data)
      assert_nif_result(fn -> Xitdb.transact_ops(tx_db, ops) end)
    after
      Xitdb.close(tx_db)
    end
  end

  if Code.ensure_loaded?(Ash.DataLayer) do
    fuzz "Ash.Search BM25 :nif and :elixir backends return identical ranked results",
         data <- binary(),
         seeds: [
           "capital alpha|cap|capstone beta|cap|all|prefix",
           "elixir xitdb|search nif|odin xitdb|search|any|exact",
           <<1, 0, 2, 124, 97, 98, 99, 124, 97, 98>>
         ] do
      {docs, query_text, match_mode, prefix?} = decode_search_scenario(data)
      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        db =
          Enum.reduce(docs, db, fn doc, acc ->
            Search.index_record(acc, __MODULE__.FuzzDoc, doc)
          end)

        nif_hits =
          Search.query(__MODULE__.FuzzDoc, query_text,
            db: db,
            backend: :nif,
            match: match_mode,
            prefix?: prefix?,
            limit: 10
          )

        ex_hits =
          Search.query(__MODULE__.FuzzDoc, query_text,
            db: db,
            backend: :elixir,
            match: match_mode,
            prefix?: prefix?,
            limit: 10
          )

        assert length(nif_hits) == length(ex_hits)

        for {{nif_id, nif_score}, {ex_id, ex_score}} <- Enum.zip(nif_hits, ex_hits) do
          assert nif_id == ex_id
          assert_in_delta nif_score, ex_score, 1.0e-6
        end
      after
        Xitdb.close(db)
      end
    end
  end

  defp assert_nif_result(fun) do
    case fun.() do
      {:ok, _val} -> :ok
      {:error, %Xitdb.Error{}} -> :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp decode_fuzz_tx_ops(<<>>), do: [{:put, ".empty", ""}]

  defp decode_fuzz_tx_ops(data) do
    parts =
      data
      |> :binary.bin_to_list()
      |> Enum.chunk_every(6)
      |> Enum.take(4)

    Enum.with_index(parts, fn bytes, idx ->
      selector = safe_selector_from_bytes(bytes)
      val = :erlang.list_to_binary(bytes)

      case rem((hd(bytes) + idx) |> abs(), 6) do
        0 -> {:put, selector, val}
        1 -> {:rm, selector}
        2 -> {:merge_map, %{"k#{idx}" => val}}
        3 -> {:append, ".items", val}
        4 -> {:slice, ".items", 0, max(rem(hd(bytes), 5), 0)}
        5 -> {:put, val, hd(bytes)}
      end
    end)
  end

  defp safe_selector_from_bytes([b | rest]) do
    case rem(b, 4) do
      0 -> "." <> sanitize_token(rest)
      1 -> ".[" <> inspect(sanitize_token(rest)) <> "]"
      2 -> ".[0]"
      3 -> :erlang.list_to_binary([b | rest])
    end
  end

  defp sanitize_token([]), do: "k"

  defp sanitize_token(bytes) do
    bytes
    |> Enum.map(fn b -> ?a + rem(b, 26) end)
    |> :erlang.list_to_binary()
  end

  defp decode_search_scenario(<<>>), do: {[], "", :all, false}

  defp decode_search_scenario(data) do
    vocab = ["alpha", "alpine", "beta", "cap", "capital", "capstone", "delta", "gamma", "xitdb"]
    bytes = :binary.bin_to_list(data)
    [first | rest] = bytes

    match_mode = if Bitwise.band(first, 1) == 0, do: :all, else: :any
    prefix? = Bitwise.band(first, 2) != 0
    doc_count = 1 + rem(first, 6)

    {doc_chunks, query_bytes} = Enum.split(rest, doc_count * 4)

    docs =
      doc_chunks
      |> Enum.chunk_every(4)
      |> Enum.with_index(1)
      |> Enum.map(fn {chunk, idx} ->
        b0 = Enum.at(chunk, 0, idx)
        b1 = Enum.at(chunk, 1, 0)
        b2 = Enum.at(chunk, 2, 1)
        b3 = Enum.at(chunk, 3, 2)

        id = 1 + rem(b0, 4)
        title = "#{Enum.at(vocab, rem(b1, 9))} #{Enum.at(vocab, rem(b2, 9))}"

        body =
          "#{Enum.at(vocab, rem(b3, 9))} #{binary_part(data, 0, min(byte_size(data), 8))}"

        struct(__MODULE__.FuzzDoc, id: id, title: title, body: body)
      end)

    query_text =
      case query_bytes do
        [] ->
          Enum.at(vocab, rem(first, 9))

        q_bytes ->
          q_words =
            q_bytes
            |> Enum.take(3)
            |> Enum.map(&Enum.at(vocab, rem(&1, 9)))
            |> Enum.join(" ")

          if prefix? and byte_size(data) > 4 do
            String.slice(q_words, 0, 3)
          else
            q_words
          end
      end

    {docs, query_text, match_mode, prefix?}
  end
end
