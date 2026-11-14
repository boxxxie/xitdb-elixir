if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Search do
    @moduledoc """
    Transactional in-Xitdb BM25 and B+Tree prefix search for `Xitdb.Ash.DataLayer` resources.

    Maintains inverted postings directly inside `idx.search.<collection>` on the resource's
    configured `.xit` store so search queries, `Ash.read` hydrations, `Xitdb.as_of/2`
    time-travel, and `Xitdb.Ash.TestSandbox` checkouts observe the exact same snapshot.

    ## Telemetry

    * `[:xitdb, :ash, :search, :start | :stop | :exception]` — emitted by `query/3`,
      carrying `%{resource: module(), collection: atom(), result_count: non_neg_integer(), status: :ok}`.
    """

    require Ash.Expr
    require Ash.Query
    require Ash.Sort

    alias Xitdb.Ash.Info
    alias Xitdb.Ash.Search.Storage

    @weight_scale 100
    @exact_match_boost 1.25

    @query_schema NimbleOptions.new!(
                    limit: [
                      type: :pos_integer,
                      default: 50,
                      doc: "Maximum number of ranked hits to return."
                    ],
                    match: [
                      type: {:in, [:all, :any]},
                      default: :all,
                      doc: "Whether documents must match `:all` query tokens or `:any` token."
                    ],
                    prefix?: [
                      type: :boolean,
                      default: true,
                      doc:
                        "Enables B+Tree prefix expansion on tokens meeting `:min_prefix_length`."
                    ],
                    min_prefix_length: [
                      type: :pos_integer,
                      default: 3,
                      doc: "Minimum character length required before prefix-scanning a token."
                    ],
                    max_prefix_expansions: [
                      type: :pos_integer,
                      default: 64,
                      doc: "Maximum B+Tree terms scanned per prefix token."
                    ],
                    k1: [
                      type: :float,
                      default: 1.2,
                      doc: "BM25 term-frequency saturation parameter."
                    ],
                    b: [
                      type: :float,
                      default: 0.75,
                      doc: "BM25 document-length normalization parameter."
                    ],
                    db: [
                      type: :any,
                      default: nil,
                      doc: "Explicit `%Xitdb{}` handle; defaults to `Snapshot.current_db/1`."
                    ],
                    exact_boost: [
                      type: :float,
                      default: @exact_match_boost,
                      doc:
                        "Term-frequency multiplier when a matched index term equals the query token."
                    ],
                    prefix_weight: [
                      type: :float,
                      default: 1.0,
                      doc: "Term-frequency multiplier for non-exact B+Tree prefix expansions."
                    ],
                    backend: [
                      type: {:in, [:auto, :nif, :elixir]},
                      default: :auto,
                      doc:
                        "Selects native Odin NIF pushdown (`:nif`), cursor-backed Elixir baseline (`:elixir`), or automatic NIF dispatch (`:auto`)."
                    ]
                  )

    @type doc_key :: String.t()
    @type hit :: {id :: integer() | String.t(), score :: float()}

    @doc """
    Searches `resource`'s `idx.search.<collection>` index and returns ranked `{id, score}` hits.

    ## Options
    #{NimbleOptions.docs(@query_schema)}
    """
    @spec query(module(), String.t() | nil, keyword()) :: [hit()]
    def query(resource, query_text, opts \\ []) when is_atom(resource) and is_list(opts) do
      opts = NimbleOptions.validate!(opts, @query_schema)
      tokens = query_text |> tokenize() |> Enum.uniq()

      if tokens == [] do
        []
      else
        execute_ranked_query(resource, tokens, opts)
      end
    end

    @doc """
    Convenience wrapper around `query/3` returning only ranked primary keys.
    """
    @spec ids(module(), String.t() | nil, keyword()) :: [integer() | String.t()]
    def ids(resource, query_text, opts \\ []) do
      resource
      |> query(query_text, opts)
      |> Enum.map(&elem(&1, 0))
    end

    @doc """
    Applies deterministic BM25 rank ordering to an `Ash.Query` filtered by `ranked_ids`.
    """
    @spec sort_by_rank(Ash.Query.t(), [integer() | String.t()]) :: Ash.Query.t()
    def sort_by_rank(%Ash.Query{} = ash_query, []), do: ash_query

    def sort_by_rank(%Ash.Query{} = ash_query, ranked_ids) when is_list(ranked_ids) do
      max_rank = length(ranked_ids)

      rank_expr =
        Enum.reduce(Enum.with_index(ranked_ids), Ash.Expr.expr(^max_rank), fn {id, rank}, acc ->
          Ash.Expr.expr(if(id == ^id, ^rank, ^acc))
        end)

      Ash.Query.sort(ash_query, [{Ash.Sort.expr_sort(^rank_expr), :asc}])
    end

    @doc """
    Reads a raw attribute from another collection on the same working `%Xitdb{}` handle
    for cross-entity `search_field` `resolver:` callbacks (e.g., `Profile` -> `Organization`).
    """
    @spec lookup_field(term(), atom(), term(), String.t() | atom()) :: term()
    def lookup_field(_db, _collection, nil, _attr_key), do: nil

    def lookup_field(db, collection, id, attr_key)
        when is_atom(collection) and (is_binary(attr_key) or is_atom(attr_key)) do
      Storage.read_entity_field(db, Atom.to_string(collection), encode_doc_key(id), attr_key)
    end

    @doc """
    Tokenizes UTF-8 strings or `%Ash.CiString{}` values into normalized lowercase terms,
    copying slices so retained index keys never pin large source binaries.
    """
    @spec tokenize(String.t() | Ash.CiString.t() | nil) :: [String.t()]
    def tokenize(nil), do: []
    def tokenize(%Ash.CiString{} = ci), do: ci |> Ash.CiString.value() |> tokenize()

    def tokenize(text) when is_binary(text) do
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.map(&:binary.copy/1)
    end

    @doc """
    Incrementally updates `idx.search.<collection>` for `record` inside a write transaction.
    No-ops when `resource` declares zero `search_field` entities.
    """
    @spec index_record(term(), module(), struct()) :: term()
    def index_record(db, resource, %_{} = record) when is_atom(resource) do
      case Info.search_fields(resource) do
        [] ->
          db

        search_fields ->
          collection = Info.collection!(resource) |> Atom.to_string()
          pk_attr = resource |> Ash.Resource.Info.primary_key() |> hd()
          doc_key = record |> Map.fetch!(pk_attr) |> encode_doc_key()
          new_terms = extract_weighted_terms(record, search_fields, db)
          apply_doc_diff(db, collection, doc_key, new_terms)
      end
    end

    @doc """
    Re-indexes a list of dependent structs in one working `%Xitdb{}` transaction
    (for example, re-indexing `Profile` records when their parent `Organization` updates).
    """
    @spec reindex_records(term(), module(), Enumerable.t()) :: term()
    def reindex_records(db, resource, records) when is_atom(resource) do
      Enum.reduce(records, db, fn record, acc_db ->
        index_record(acc_db, resource, record)
      end)
    end

    @doc """
    Removes `doc_id` from `idx.search.<collection>` inside a `destroy` transaction.
    """
    @spec remove_record(term(), module(), term()) :: term()
    def remove_record(db, resource, doc_id) when is_atom(resource) do
      case Info.search_fields(resource) do
        [] ->
          db

        _fields ->
          collection = Info.collection!(resource) |> Atom.to_string()
          apply_doc_diff(db, collection, encode_doc_key(doc_id), %{})
      end
    end

    # -- Internal Query & BM25 Execution --

    defp execute_ranked_query(resource, tokens, opts) do
      collection_atom = Info.collection!(resource)
      collection = Atom.to_string(collection_atom)
      meta = %{resource: resource, collection: collection_atom}

      :telemetry.span([:xitdb, :ash, :search], meta, fn ->
        db = opts[:db] || resolve_active_db(resource)
        hits = score_collection(db, collection, tokens, opts, pk_type(resource))

        {hits,
         meta
         |> Map.put(:result_count, length(hits))
         |> Map.put(:status, :ok)}
      end)
    end

    defp resolve_active_db(resource) do
      store = Info.store!(resource)

      if Code.ensure_loaded?(Xitdb.Ash.Store.Snapshot) do
        Xitdb.Ash.Store.Snapshot.current_db(store)
      else
        raise ArgumentError, "No database handle provided and Snapshot module is not loaded"
      end
    end

    defp score_collection(db, collection, tokens, opts, pk_kind) do
      case resolve_backend(opts[:backend], db) do
        :nif -> score_collection_nif(db, collection, tokens, opts, pk_kind)
        :elixir -> score_collection_elixir(db, collection, tokens, opts, pk_kind)
      end
    end

    defp resolve_backend(:elixir, _db), do: :elixir
    defp resolve_backend(:nif, _db), do: :nif

    defp resolve_backend(:auto, db) do
      case Storage.root_cursor(db) do
        %Xitdb.Cursor{tx_mode: false} ->
          if function_exported?(Xitdb.NIF, :nif_bm25_search, 7), do: :nif, else: :elixir

        _ ->
          :elixir
      end
    end

    defp score_collection_nif(db, collection, tokens, opts, pk_kind) do
      case Storage.root_cursor(db) do
        %Xitdb.Cursor{tx_mode: false, db_ref: db_ref, tag_id: root_tag_id, value: root_val_int} ->
          nif_opts = %{
            match: opts[:match],
            prefix: opts[:prefix?],
            min_prefix_length: opts[:min_prefix_length],
            max_prefix_expansions: opts[:max_prefix_expansions],
            k1: opts[:k1] * 1.0,
            b: opts[:b] * 1.0,
            exact_boost: opts[:exact_boost] * 1.0,
            prefix_weight: opts[:prefix_weight] * 1.0
          }

          case Xitdb.NIF.nif_bm25_search(
                 db_ref,
                 root_tag_id,
                 root_val_int,
                 collection,
                 tokens,
                 opts[:limit],
                 nif_opts
               ) do
            {:ok, raw_hits} ->
              Enum.map(raw_hits, fn {doc_key, score} ->
                {decode_doc_key(doc_key, pk_kind), score}
              end)

            {:error, reason} ->
              raise Xitdb.Error, reason: reason, details: %{collection: collection}
          end

        _ ->
          raise ArgumentError,
                "backend: :nif requires a committed Xitdb handle or snapshot cursor"
      end
    end

    defp score_collection_elixir(db, collection, tokens, opts, pk_kind) do
      %{doc_count: doc_count, total_len: total_len} = Storage.read_corpus_stats(db, collection)

      if doc_count <= 0 or total_len <= 0 do
        []
      else
        avg_dl = total_len / doc_count / @weight_scale
        token_postings = Enum.map(tokens, &collect_token_postings(db, collection, &1, opts))
        candidate_keys = resolve_candidate_keys(token_postings, opts[:match])

        score_candidates(
          db,
          collection,
          candidate_keys,
          token_postings,
          doc_count,
          avg_dl,
          opts,
          pk_kind
        )
      end
    end

    # Merges exact hits + bounded B+Tree prefix hits into a single virtual term per query token
    # so morphological variants ("cap", "capital") never double-count IDF on the same token.
    defp collect_token_postings(db, collection, token, opts) do
      exact_boost = opts[:exact_boost]
      prefix_weight = opts[:prefix_weight]
      exact_postings = Storage.lookup_term(db, collection, token)

      prefix_postings =
        if opts[:prefix?] and String.length(token) >= opts[:min_prefix_length] do
          Storage.scan_prefix(
            db,
            collection,
            token,
            opts[:max_prefix_expansions],
            opts[:backend]
          )
        else
          []
        end

      merged =
        Enum.reduce(prefix_postings, %{}, fn {matched_term, postings}, acc ->
          multiplier = if matched_term == token, do: exact_boost, else: prefix_weight

          Enum.reduce(postings, acc, fn {doc_key, scaled_tf}, inner ->
            tf = scaled_tf / @weight_scale * multiplier
            Map.update(inner, doc_key, tf, &(&1 + tf))
          end)
        end)

      if prefix_postings == [] do
        Map.new(exact_postings, fn {doc_key, scaled_tf} ->
          {doc_key, scaled_tf / @weight_scale * exact_boost}
        end)
      else
        merged
      end
    end

    defp resolve_candidate_keys([], _mode), do: MapSet.new()

    defp resolve_candidate_keys([first | rest], :all) do
      Enum.reduce(rest, MapSet.new(Map.keys(first)), fn postings, acc ->
        if MapSet.size(acc) == 0 do
          acc
        else
          MapSet.intersection(acc, MapSet.new(Map.keys(postings)))
        end
      end)
    end

    defp resolve_candidate_keys(token_postings, :any) do
      Enum.reduce(token_postings, MapSet.new(), fn postings, acc ->
        Enum.reduce(Map.keys(postings), acc, &MapSet.put(&2, &1))
      end)
    end

    defp score_candidates(
           db,
           collection,
           candidate_keys,
           token_postings,
           doc_count,
           avg_dl,
           opts,
           pk_kind
         ) do
      k1 = opts[:k1]
      b = opts[:b]

      idfs =
        Enum.map(token_postings, fn postings ->
          df = map_size(postings)
          :math.log(1.0 + (doc_count - df + 0.5) / (df + 0.5))
        end)

      weighted_tokens = Enum.zip(token_postings, idfs)

      candidate_keys
      |> Enum.reduce([], fn doc_key, acc ->
        doc_len = Storage.read_doc_len(db, collection, doc_key) / @weight_scale
        norm = k1 * (1.0 - b + b * (doc_len / max(avg_dl, 1.0e-6)))

        score =
          Enum.reduce(weighted_tokens, 0.0, fn {postings, idf}, sum ->
            case Map.fetch(postings, doc_key) do
              {:ok, tf} when tf > 0.0 -> sum + idf * (tf * (k1 + 1.0)) / (tf + norm)
              _ -> sum
            end
          end)

        if score > 0.0 do
          [{doc_key, score} | acc]
        else
          acc
        end
      end)
      |> Enum.sort_by(fn {doc_key, score} -> {-score, doc_key} end)
      |> Enum.take(opts[:limit])
      |> Enum.map(fn {doc_key, score} -> {decode_doc_key(doc_key, pk_kind), score} end)
    end

    # -- Internal Indexing & Diff Calculation --

    defp extract_weighted_terms(record, search_fields, db) do
      Enum.reduce(search_fields, %{}, fn %{field: field, boost: boost, resolver: resolver}, acc ->
        weight = max(1, round(boost * @weight_scale))

        raw_value =
          case resolver do
            fun when is_function(fun, 2) -> fun.(record, db)
            nil -> Map.get(record, field)
          end

        raw_value
        |> extract_tokens()
        |> Enum.reduce(acc, fn token, term_acc ->
          Map.update(term_acc, token, weight, &(&1 + weight))
        end)
      end)
    end

    defp extract_tokens(values) when is_list(values) do
      Enum.flat_map(values, &extract_tokens/1)
    end

    defp extract_tokens(value) when is_binary(value) or is_struct(value, Ash.CiString) do
      tokenize(value)
    end

    defp extract_tokens(value)
         when is_atom(value) and not is_nil(value) and not is_boolean(value) do
      value |> Atom.to_string() |> tokenize()
    end

    defp extract_tokens(_other), do: []

    defp apply_doc_diff(db, collection, doc_key, new_terms) do
      %{len: old_len, terms: old_terms} = Storage.read_doc(db, collection, doc_key)
      new_len = Enum.reduce(new_terms, 0, fn {_term, weight}, sum -> sum + weight end)

      if old_terms == new_terms do
        db
      else
        was_indexed? = old_len > 0
        now_indexed? = new_len > 0

        doc_count_delta =
          cond do
            not was_indexed? and now_indexed? -> 1
            was_indexed? and not now_indexed? -> -1
            true -> 0
          end

        len_delta = new_len - old_len
        term_ops = compute_term_ops(old_terms, new_terms)

        Storage.apply_diff(db, collection, doc_key, %{
          doc_count_delta: doc_count_delta,
          len_delta: len_delta,
          new_doc: if(now_indexed?, do: %{len: new_len, terms: new_terms}, else: :delete),
          term_ops: term_ops
        })
      end
    end

    defp compute_term_ops(old_terms, new_terms) do
      deletes_and_updates =
        Enum.reduce(old_terms, [], fn {term, old_w}, acc ->
          case Map.fetch(new_terms, term) do
            {:ok, ^old_w} -> acc
            {:ok, new_w} -> [{:put, term, new_w} | acc]
            :error -> [{:delete, term} | acc]
          end
        end)

      Enum.reduce(new_terms, deletes_and_updates, fn {term, new_w}, acc ->
        if Map.has_key?(old_terms, term) do
          acc
        else
          [{:put, term, new_w} | acc]
        end
      end)
    end

    defp pk_type(resource) do
      pk_name = resource |> Ash.Resource.Info.primary_key() |> hd()
      attr = Ash.Resource.Info.attribute(resource, pk_name)

      if attr && attr.type in [:integer, Ash.Type.Integer], do: :integer, else: :string
    end

    defp encode_doc_key(id) when is_integer(id), do: Integer.to_string(id)
    defp encode_doc_key(id) when is_binary(id), do: id
    defp encode_doc_key(id), do: to_string(id)

    defp decode_doc_key(key, :integer), do: String.to_integer(key)
    defp decode_doc_key(key, :string), do: key
  end

  defmodule Xitdb.Ash.Search.RankCalculation do
    @moduledoc false
    use Ash.Resource.Calculation

    @impl true
    def calculate(records, opts, _context) do
      ranks = Keyword.fetch!(opts, :ranks)
      default = Keyword.fetch!(opts, :default)

      Enum.map(records, fn record ->
        Map.get(ranks, record.id, default)
      end)
    end
  end

  defmodule Xitdb.Ash.Search.Storage do
    @moduledoc false
    # Slot-tree adapter over `idx.search.<collection>`:
    #   ├── "meta"  (:hash_map -> %{"doc_count" => int, "total_len" => int})
    #   ├── "docs"  (:hash_map -> doc_key => %{"len" => int, "terms" => %{term => weight}})
    #   └── "terms" (:sorted_map -> term => %{doc_key => weight})

    alias Xitdb.Selector

    @spec read_entity_field(term(), String.t(), String.t(), String.t() | atom()) :: term()
    def read_entity_field(db, collection, doc_key, attr_key) do
      attr_str = to_string(attr_key)

      with root when not is_nil(root) <- root_cursor(db),
           col when not is_nil(col) <- root[collection],
           entity when not is_nil(entity) <- col[doc_key] do
        entity[attr_str] || entity[attr_key]
      else
        _ -> nil
      end
    end

    @spec read_corpus_stats(term(), String.t()) :: %{
            doc_count: non_neg_integer(),
            total_len: non_neg_integer()
          }
    def read_corpus_stats(db, collection) do
      case get_in_search(db, collection, "meta") do
        nil -> %{doc_count: 0, total_len: 0}
        meta -> %{doc_count: meta["doc_count"] || 0, total_len: meta["total_len"] || 0}
      end
    end

    @spec read_doc(term(), String.t(), String.t()) :: %{
            len: non_neg_integer(),
            terms: %{optional(String.t()) => pos_integer()}
          }
    def read_doc(db, collection, doc_key) do
      with docs when not is_nil(docs) <- get_in_search(db, collection, "docs"),
           doc when not is_nil(doc) <- docs[doc_key] do
        terms =
          case doc["terms"] do
            nil -> %{}
            raw_terms when is_map(raw_terms) and not is_struct(raw_terms) -> raw_terms
            %Xitdb.Cursor{} = terms_cur -> Map.new(terms_cur)
            _ -> %{}
          end

        %{len: doc["len"] || 0, terms: terms}
      else
        _ -> %{len: 0, terms: %{}}
      end
    end

    @spec read_doc_len(term(), String.t(), String.t()) :: non_neg_integer()
    def read_doc_len(db, collection, doc_key) do
      with docs when not is_nil(docs) <- get_in_search(db, collection, "docs"),
           doc when not is_nil(doc) <- docs[doc_key] do
        doc["len"] || 0
      else
        _ -> 0
      end
    end

    @spec lookup_term(term(), String.t(), String.t()) :: [{String.t(), pos_integer()}]
    def lookup_term(db, collection, term) do
      with terms when not is_nil(terms) <- get_in_search(db, collection, "terms"),
           postings when not is_nil(postings) <- terms[term] do
        Enum.to_list(postings)
      else
        _ -> []
      end
    end

    @spec scan_prefix_cursors(term(), String.t(), String.t(), pos_integer()) ::
            {[{String.t(), Xitdb.Cursor.t()}], String.t() | nil}
    def scan_prefix_cursors(db, collection, prefix, limit) do
      case get_in_search(db, collection, "terms") do
        %Xitdb.Cursor{db_ref: db_ref, tag_id: tag_id, value: val, moment: moment} ->
          case Xitdb.NIF.nif_sorted_map_seek(db_ref, tag_id, val, prefix, limit) do
            {:ok, entries, next_cursor} ->
              cursors =
                Enum.map(entries, fn {term, slot_tuple} ->
                  {term, Xitdb.Cursor.from_nif_tuple(db_ref, slot_tuple, moment)}
                end)

              {cursors, next_cursor}

            _ ->
              {[], nil}
          end

        _ ->
          {[], nil}
      end
    end

    @spec scan_prefix(term(), String.t(), String.t(), pos_integer(), :auto | :nif | :elixir) :: [
            {String.t(), [{String.t(), pos_integer()}]}
          ]
    def scan_prefix(db, collection, prefix, limit, backend \\ :auto)

    def scan_prefix(db, collection, prefix, limit, :elixir) do
      scan_prefix_via_slot_entries(db, collection, prefix, limit)
    end

    def scan_prefix(db, collection, prefix, limit, _backend) do
      if function_exported?(Xitdb.NIF, :nif_sorted_map_seek, 5) do
        {cursor_entries, _next} = scan_prefix_cursors(db, collection, prefix, limit)
        Enum.map(cursor_entries, fn {term, cur} -> {term, Enum.to_list(cur)} end)
      else
        scan_prefix_via_slot_entries(db, collection, prefix, limit)
      end
    end

    defp scan_prefix_via_slot_entries(db, collection, prefix, limit) do
      case get_in_search(db, collection, "terms") do
        nil ->
          []

        %Xitdb.Cursor{} = terms ->
          case Xitdb.NIF.nif_slot_count(terms.db_ref, terms.tag_id, terms.value) do
            {:ok, total_count} when total_count > 0 ->
              start_idx = find_prefix_start_index(terms, prefix, 0, total_count)
              stream_prefix_from(terms, prefix, start_idx, limit)

            _ ->
              []
          end
      end
    end

    defp find_prefix_start_index(terms, prefix, low, high) when low < high do
      mid = div(low + high, 2)

      case Xitdb.NIF.nif_slot_entries(terms.db_ref, terms.tag_id, terms.value, mid, 1) do
        {:ok, [{key, _}]} ->
          if key < prefix do
            find_prefix_start_index(terms, prefix, mid + 1, high)
          else
            find_prefix_start_index(terms, prefix, low, mid)
          end

        _ ->
          low
      end
    end

    defp find_prefix_start_index(_terms, _prefix, low, _high), do: low

    defp stream_prefix_from(terms, prefix, start_idx, limit) do
      Stream.unfold(start_idx, fn idx ->
        case Xitdb.NIF.nif_slot_entries(
               terms.db_ref,
               terms.tag_id,
               terms.value,
               idx,
               min(limit, 32)
             ) do
          {:ok, []} ->
            nil

          {:ok, chunk} ->
            {chunk, idx + length(chunk)}

          _ ->
            nil
        end
      end)
      |> Stream.flat_map(& &1)
      |> Stream.take_while(fn {term, _} -> String.starts_with?(term, prefix) end)
      |> Stream.take(limit)
      |> Enum.map(fn {term, raw_postings} ->
        postings =
          case raw_postings do
            {:cursor, _tag, _tag_id, _val, _full} = c_tuple ->
              terms.db_ref
              |> Xitdb.Cursor.from_nif_tuple(c_tuple, terms.moment)
              |> Enum.to_list()

            %Xitdb.Cursor{} = cur ->
              Enum.to_list(cur)

            list when is_list(list) ->
              list
          end

        {term, postings}
      end)
    end

    @spec apply_diff(term(), String.t(), String.t(), map()) :: term()
    def apply_diff(db, _collection, _doc_key, %{doc_count_delta: 0, len_delta: 0, term_ops: []}) do
      db
    end

    def apply_diff(db, collection, doc_key, diff) do
      col_str = Selector.format_key(collection)
      doc_str = Selector.format_key(doc_key)

      meta_prefix = ".idx.search." <> col_str <> ".meta"
      docs_prefix = ".idx.search." <> col_str <> ".docs"
      terms_prefix = ".idx.search." <> col_str <> ".terms"

      %{doc_count: cur_doc_count, total_len: cur_total_len} = read_corpus_stats(db, collection)
      new_doc_count = max(0, cur_doc_count + diff.doc_count_delta)
      new_total_len = max(0, cur_total_len + diff.len_delta)

      meta_ops = [
        {:put, meta_prefix <> ".doc_count", new_doc_count},
        {:put, meta_prefix <> ".total_len", new_total_len}
      ]

      doc_path = docs_prefix <> "." <> doc_str

      doc_ops =
        case diff.new_doc do
          :delete ->
            [{:rm, doc_path}]

          %{len: len, terms: doc_terms} ->
            put_terms =
              Enum.map(doc_terms, fn {term, weight} ->
                {:put, doc_path <> ".terms." <> Selector.format_key(term), weight}
              end)

            [
              {:put, doc_path <> ".len", len},
              {:reset_col, doc_path <> ".terms", "hash_map"} | put_terms
            ]
        end

      term_ops =
        Enum.flat_map(diff.term_ops, fn
          {:put, term, weight} ->
            term_str = Selector.format_key(term)
            [{:put, terms_prefix <> "$" <> term_str <> "." <> doc_str, weight}]

          {:delete, term} ->
            term_str = Selector.format_key(term)
            postings = lookup_term(db, collection, term)

            if length(postings) <= 1 do
              [{:rm, terms_prefix <> "$" <> term_str}]
            else
              [{:rm, terms_prefix <> "$" <> term_str <> "." <> doc_str}]
            end
        end)

      ops = meta_ops ++ doc_ops ++ term_ops

      case db do
        {%Xitdb{} = raw_db, moment} when is_integer(moment) ->
          {:ok, new_db} = Xitdb.transact_ops(raw_db, ops, base_moment: moment)
          {new_db, Xitdb.moment_count(new_db) - 1}

        %Xitdb{} = raw_db ->
          {:ok, new_db} = Xitdb.transact_ops(raw_db, ops)
          new_db
      end
    end

    @doc false
    def root_cursor({%Xitdb{} = db, moment}) when is_integer(moment), do: Xitdb.as_of(db, moment)
    def root_cursor(%Xitdb.Cursor{} = cursor), do: cursor
    def root_cursor(%Xitdb{} = db), do: Xitdb.db(db)
    def root_cursor(_), do: nil

    defp get_in_search(db, collection, slot) do
      with %Xitdb.Cursor{} = root <- root_cursor(db),
           %Xitdb.Cursor{} = idx <- root["idx"],
           %Xitdb.Cursor{} = search <- idx["search"],
           %Xitdb.Cursor{} = col <- search[collection] do
        col[slot]
      else
        _ -> nil
      end
    end
  end
end
