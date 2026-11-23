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
    require Ash.Sort

    alias Xitdb.Ash.{Codec, Indexer, Info, Store}
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
                      type: {:or, [{:struct, Xitdb}, {:struct, Xitdb.Cursor}, {:in, [nil]}]},
                      default: nil,
                      doc:
                        "Explicit `%Xitdb{}` or `%Xitdb.Cursor{}` handle; defaults to `Xitdb.Ash.Store.current_db/1`."
                    ],
                    as_of: [
                      type: {:or, [:non_neg_integer, {:in, [nil]}]},
                      default: nil,
                      doc:
                        "Optional historical moment index (`Xitdb.as_of/2`); ignored when `:db` is set."
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
                    ],
                    tenant: [
                      type: :any,
                      default: nil,
                      doc: "Optional Ash tenant for `:context`-multitenant resources."
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

    def sort_by_rank(%Ash.Query{resource: resource} = ash_query, ranked_ids)
        when is_list(ranked_ids) do
      [pk_field | _] = Ash.Resource.Info.primary_key(resource)
      unique_ids = Enum.uniq(ranked_ids)
      max_rank = length(unique_ids)

      rank_expr =
        Enum.reduce(Enum.with_index(unique_ids), Ash.Expr.expr(^max_rank), fn {id, rank}, acc ->
          Ash.Expr.expr(if(^Ash.Expr.ref(pk_field) == ^id, ^rank, ^acc))
        end)

      Ash.Query.sort(ash_query, [{Ash.Sort.expr_sort(^rank_expr), :asc}], prepend?: true)
    end

    @doc """
    Reads a raw attribute from another collection on the same working `%Xitdb{}` handle
    for cross-entity `search_field` `resolver:` callbacks (e.g., `Profile` -> `Organization`).
    """
    @spec lookup_field(term(), atom(), term(), String.t() | atom(), term()) :: term()
    def lookup_field(db, collection, id, attr_key, tenant \\ nil)
    def lookup_field(_db, _collection, nil, _attr_key, _tenant), do: nil

    def lookup_field(db, collection, id, attr_key, tenant)
        when is_atom(collection) and (is_binary(attr_key) or is_atom(attr_key)) do
      {col_str, doc_key} =
        if Ash.Resource.Info.resource?(collection) do
          [pk_name | _] = Ash.Resource.Info.primary_key(collection)
          pk_attr = Ash.Resource.Info.attribute(collection, pk_name)
          {Codec.scoped_collection(collection, tenant), Codec.encode_pk_doc_id(pk_attr, id)}
        else
          scoped =
            if is_nil(tenant) do
              Atom.to_string(collection)
            else
              "t:" <> Codec.encode_doc_id(tenant) <> ":" <> Atom.to_string(collection)
            end

          {scoped, Codec.encode_doc_id(id)}
        end

      Storage.read_entity_field(db, col_str, doc_key, attr_key)
    end

    @doc """
    Tokenizes UTF-8 strings or `%Ash.CiString{}` values into normalized lowercase terms,
    copying slices so retained index keys never pin large source binaries.
    """
    @spec tokenize(String.t() | Ash.CiString.t() | nil) :: [String.t()]
    def tokenize(nil), do: []
    def tokenize(%Ash.CiString{} = ci), do: ci |> Ash.CiString.value() |> tokenize()
    def tokenize(""), do: []

    def tokenize(text) when is_binary(text) do
      tokenize_ascii_scan(text, [], [], text)
    end

    defp tokenize_ascii_scan(<<c, rest::binary>>, cur, acc, orig) do
      cond do
        c >= ?a and c <= ?z ->
          tokenize_ascii_scan(rest, [c | cur], acc, orig)

        c >= ?0 and c <= ?9 ->
          tokenize_ascii_scan(rest, [c | cur], acc, orig)

        c >= ?A and c <= ?Z ->
          tokenize_ascii_scan(rest, [c + 32 | cur], acc, orig)

        c < 128 ->
          if cur == [] do
            tokenize_ascii_scan(rest, [], acc, orig)
          else
            token = cur |> :lists.reverse() |> :erlang.list_to_binary()
            tokenize_ascii_scan(rest, [], [token | acc], orig)
          end

        true ->
          tokenize_unicode(orig)
      end
    end

    defp tokenize_ascii_scan(<<>>, [], acc, _orig), do: :lists.reverse(acc)

    defp tokenize_ascii_scan(<<>>, cur, acc, _orig) do
      token = cur |> :lists.reverse() |> :erlang.list_to_binary()
      :lists.reverse([token | acc])
    end

    defp tokenize_unicode(text) do
      valid_utf8 = if String.valid?(text), do: text, else: String.replace_invalid(text)

      nfc =
        case :unicode.characters_to_nfc_binary(valid_utf8) do
          bin when is_binary(bin) -> bin
          {_, prefix, _} when is_binary(prefix) -> prefix
        end

      nfc
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.map(&:binary.copy/1)
    end

    @doc """
    Rebuilds `idx.search.<collection>` for `resource` in a single atomic transaction
    (`Xitdb.Ash.Store` module, `{db, moment}`, or `%Xitdb{}`), scanning all live records,
    extracting BM25 term weights (optionally in parallel across worker processes), and writing
    `.meta`, `.docs`, and sorted `.terms` postings in bulk.

    ## Options
    - `:tenant` (`term()`) — optional multitenant scope (defaults to `nil`).
    - `:parallel` (`boolean()`) — enable parallel worker extraction when at least 128 records
      are indexed (defaults to `true`).
    - `:only_attrs` (`:auto | :all | [atom()] | MapSet.t(atom())`) — restricts hydrated attributes;
      `:auto` inspects `Info.search_fields(resource)` and loads `:all` when any search field
      declares a `resolver`, otherwise only declared search fields (plus tenant attribute).
    - `:worker_wrapper` (`(-> result) | (Xitdb.Cursor.t(), (-> result) -> result)`) — optional
      wrapper invoked once per worker slice (for example, initializing process-local lookup caches).
    """
    @spec rebuild_index!(
            module() | {Xitdb.t(), integer()} | Xitdb.t(),
            module(),
            keyword()
          ) :: :ok | {Xitdb.t(), integer()} | Xitdb.t()
    def rebuild_index!(store_or_db, resource, opts \\ [])

    def rebuild_index!(store, resource, opts)
        when is_atom(store) and is_atom(resource) and is_list(opts) do
      if Info.search_fields(resource) == [] do
        :ok
      else
        mutate_opts = Keyword.take(opts, [:timeout, :lease_timeout])

        case Store.mutate(
               store,
               fn {db, moment} ->
                 next_snapshot = do_rebuild_snapshot({db, moment}, resource, opts)
                 {:ok, next_snapshot, :ok}
               end,
               mutate_opts
             ) do
          {:ok, :ok} -> :ok
          {:error, %_{} = err} when is_exception(err) -> raise err
          {:error, reason} -> raise Xitdb.Error, reason: reason
        end
      end
    end

    def rebuild_index!({%Xitdb{} = db, moment}, resource, opts)
        when is_integer(moment) and is_atom(resource) and is_list(opts) do
      if Info.search_fields(resource) == [] do
        {db, moment}
      else
        do_rebuild_snapshot({db, moment}, resource, opts)
      end
    end

    def rebuild_index!(%Xitdb{} = db, resource, opts)
        when is_atom(resource) and is_list(opts) do
      if Info.search_fields(resource) == [] do
        db
      else
        moment = max(Xitdb.moment_count(db) - 1, -1)
        {next_db, _next_moment} = do_rebuild_snapshot({db, moment}, resource, opts)
        next_db
      end
    end

    @doc """
    Incrementally indexes or updates a batch of `records` in `idx.search.<collection>`
    inside a single atomic transaction (`Xitdb.Ash.Store` module, `{db, moment}`, or `%Xitdb{}`).

    Useful after deferred bulk writes (`context: %{xitdb: %{skip_search_index?: true}}` with
    `return_records?: true`) when appending to an already-populated collection where re-scanning
    all existing rows via `rebuild_index!/3` is unnecessary.

    ## Options
    - `:tenant` (`term()`) — optional multitenant scope (defaults to `nil`).
    - `:parallel` (`boolean()`) — enable parallel worker term extraction when at least 128
      records are indexed (defaults to `true`).
    - `:assume_new?` (`boolean()`) — skip reading prior `idx.search.<collection>.docs` entries
      when callers know the records are newly inserted (defaults to `false`).
    - `:worker_wrapper` (`(-> result) | (Xitdb.Cursor.t(), (-> result) -> result)`) — optional
      wrapper invoked once per worker slice (for example, initializing process-local lookup caches).
    """
    @spec index_records!(
            module() | {Xitdb.t(), integer()} | Xitdb.t(),
            module(),
            Enumerable.t(),
            keyword()
          ) :: :ok | {Xitdb.t(), integer()} | Xitdb.t()
    def index_records!(store_or_db, resource, records, opts \\ [])

    def index_records!(store, resource, records, opts)
        when is_atom(store) and is_atom(resource) and is_list(opts) do
      search_fields = Info.search_fields(resource)
      records_list = Enum.to_list(records)

      if search_fields == [] or records_list == [] do
        :ok
      else
        mutate_opts = Keyword.take(opts, [:timeout, :lease_timeout])

        case Store.mutate(
               store,
               fn {db, moment} ->
                 next_snapshot =
                   do_index_records_snapshot(
                     {db, moment},
                     resource,
                     search_fields,
                     records_list,
                     opts
                   )

                 {:ok, next_snapshot, :ok}
               end,
               mutate_opts
             ) do
          {:ok, :ok} -> :ok
          {:error, %_{} = err} when is_exception(err) -> raise err
          {:error, reason} -> raise Xitdb.Error, reason: reason
        end
      end
    end

    def index_records!({%Xitdb{} = db, moment}, resource, records, opts)
        when is_integer(moment) and is_atom(resource) and is_list(opts) do
      search_fields = Info.search_fields(resource)
      records_list = Enum.to_list(records)

      if search_fields == [] or records_list == [] do
        {db, moment}
      else
        do_index_records_snapshot({db, moment}, resource, search_fields, records_list, opts)
      end
    end

    def index_records!(%Xitdb{} = db, resource, records, opts)
        when is_atom(resource) and is_list(opts) do
      search_fields = Info.search_fields(resource)
      records_list = Enum.to_list(records)

      if search_fields == [] or records_list == [] do
        db
      else
        moment = max(Xitdb.moment_count(db) - 1, -1)

        {next_db, _next_moment} =
          do_index_records_snapshot({db, moment}, resource, search_fields, records_list, opts)

        next_db
      end
    end

    @doc false
    def extract_weighted_terms_for_record(record, search_fields, db) do
      extract_weighted_terms(record, search_fields, db)
    end

    @doc false
    def compile_search_plan(search_fields) do
      Enum.map(search_fields, fn %{field: field, boost: boost, resolver: resolver} ->
        {field, max(1, round(boost * @weight_scale)), resolver}
      end)
    end

    @doc false
    def extract_weighted_terms_and_len(record, search_plan, db) do
      do_extract_weighted_terms(search_plan, record, db, %{}, 0)
    end

    @doc false
    def plan_bulk_index_ops(cursor_root, search_fields, items, opts \\ [])

    def plan_bulk_index_ops(_cursor_root, [], _items, _opts), do: []
    def plan_bulk_index_ops(_cursor_root, _search_fields, [], _opts), do: []

    def plan_bulk_index_ops(cursor_root, search_fields, items, opts) do
      search_plan = compile_search_plan(search_fields)

      has_resolver? =
        Enum.any?(search_plan, fn {_field, _weight, resolver} -> resolver != nil end)

      parallel_opt = Keyword.get(opts, :parallel, :auto)
      worker_wrapper = Keyword.get(opts, :worker_wrapper)

      {col_order_rev, by_col_rev} =
        Enum.reduce(items, {[], %{}}, fn {scoped_col, _doc_id, _record, _check_existing?} = item,
                                         {order_acc, map_acc} ->
          case Map.fetch(map_acc, scoped_col) do
            {:ok, list} -> {order_acc, Map.put(map_acc, scoped_col, [item | list])}
            :error -> {[scoped_col | order_acc], Map.put(map_acc, scoped_col, [item])}
          end
        end)

      col_order_rev
      |> Enum.reverse()
      |> Enum.flat_map(fn scoped_col ->
        col_items = by_col_rev |> Map.fetch!(scoped_col) |> Enum.reverse()

        plan_bulk_index_col_ops(
          cursor_root,
          scoped_col,
          search_plan,
          has_resolver?,
          col_items,
          parallel_opt,
          worker_wrapper
        )
      end)
    end

    @doc """
    Incrementally updates `idx.search.<collection>` for `record` inside a write transaction.
    No-ops when `resource` declares zero `search_field` entities.
    """
    @spec index_record(term(), module(), struct(), term()) :: term()
    def index_record(db, resource, %_{} = record, tenant \\ nil) when is_atom(resource) do
      case Info.search_fields(resource) do
        [] ->
          db

        search_fields ->
          collection = Codec.scoped_collection(resource, tenant)
          [pk_name | _] = Ash.Resource.Info.primary_key(resource)
          pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
          doc_key = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(record, pk_name))
          new_terms = extract_weighted_terms(record, search_fields, db)
          apply_doc_diff(db, collection, doc_key, new_terms)
      end
    end

    @doc """
    Re-indexes a list of dependent structs in one working `%Xitdb{}` transaction
    (for example, re-indexing `Profile` records when their parent `Organization` updates).
    """
    @spec reindex_records(term(), module(), Enumerable.t(), term()) :: term()
    def reindex_records(db, resource, records, tenant \\ nil) when is_atom(resource) do
      Enum.reduce(records, db, fn record, acc_db ->
        index_record(acc_db, resource, record, tenant)
      end)
    end

    @doc """
    Removes `doc_id` from `idx.search.<collection>` inside a `destroy` transaction.
    """
    @spec remove_record(term(), module(), term(), term()) :: term()
    def remove_record(db, resource, doc_id, tenant \\ nil) when is_atom(resource) do
      case Info.search_fields(resource) do
        [] ->
          db

        _fields ->
          collection = Codec.scoped_collection(resource, tenant)
          [pk_name | _] = Ash.Resource.Info.primary_key(resource)
          pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
          apply_doc_diff(db, collection, Codec.encode_pk_doc_id(pk_attr, doc_id), %{})
      end
    end

    # -- Internal Query & BM25 Execution --

    defp execute_ranked_query(resource, tokens, opts) do
      collection_atom = Info.collection!(resource)
      collection = Codec.scoped_collection(resource, opts[:tenant])
      meta = %{resource: resource, collection: collection_atom}

      :telemetry.span([:xitdb, :ash, :search], meta, fn ->
        db =
          cond do
            opts[:db] != nil -> opts[:db]
            is_integer(opts[:as_of]) -> resolve_as_of_db(resource, opts[:as_of])
            true -> resolve_active_db(resource)
          end

        hits = score_collection(db, collection, tokens, opts, resource)

        {hits,
         meta
         |> Map.put(:result_count, length(hits))
         |> Map.put(:status, :ok)}
      end)
    end

    defp resolve_as_of_db(resource, moment) do
      store = Info.store!(resource)

      if Code.ensure_loaded?(Xitdb.Ash.Store.Snapshot) do
        Xitdb.Ash.Store.Snapshot.as_of(store, moment)
      else
        raise ArgumentError, "No database handle provided and Snapshot module is not loaded"
      end
    end

    defp resolve_active_db(resource) do
      store = Info.store!(resource)

      if Code.ensure_loaded?(Xitdb.Ash.Store.Snapshot) do
        Xitdb.Ash.Store.Snapshot.current_db(store)
      else
        raise ArgumentError, "No database handle provided and Snapshot module is not loaded"
      end
    end

    defp score_collection(db, collection, tokens, opts, resource) do
      case Storage.root_cursor(db) do
        %Xitdb.Cursor{tag: :none} ->
          []

        nil ->
          []

        _root ->
          filter_tenant? = attribute_tenant_filter_needed?(resource, opts[:tenant])

          effective_opts =
            if filter_tenant? do
              %{doc_count: doc_count} = Storage.read_corpus_stats(db, collection)
              Keyword.put(opts, :limit, max(opts[:limit], doc_count))
            else
              opts
            end

          hits =
            case resolve_backend(effective_opts[:backend], db) do
              :nif -> score_collection_nif(db, collection, tokens, effective_opts, resource)
              :elixir -> score_collection_elixir(db, collection, tokens, effective_opts, resource)
            end

          if filter_tenant? do
            hits
            |> Enum.filter(fn {pk_val, _score} ->
              with {:ok, cur} <-
                     Xitdb.Ash.Indexer.fetch_cursor(db, resource, pk_val, opts[:tenant]),
                   {:ok, record} <- Codec.from_cursor(resource, cur, opts[:tenant]) do
                Codec.matches_tenant?(resource, record, opts[:tenant])
              else
                _ -> false
              end
            end)
            |> Enum.take(opts[:limit])
          else
            hits
          end
      end
    end

    defp attribute_tenant_filter_needed?(resource, tenant) do
      Ash.Resource.Info.multitenancy_strategy(resource) == :attribute and
        not (is_nil(tenant) and Ash.Resource.Info.multitenancy_global?(resource))
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

    defp score_collection_nif(db, collection, tokens, opts, resource) do
      case Storage.root_cursor(db) do
        %Xitdb.Cursor{tag: :none} ->
          []

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
                {decode_doc_key(resource, doc_key), score}
              end)

            {:error, :invalid_moment} ->
              []

            {:error, reason} ->
              raise Xitdb.Error, reason: reason, details: %{collection: collection}
          end

        _ ->
          raise ArgumentError,
                "backend: :nif requires a committed Xitdb handle or snapshot cursor"
      end
    end

    defp score_collection_elixir(db, collection, tokens, opts, resource) do
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
          resource
        )
      end
    end

    # Merges exact hits + bounded B+Tree prefix hits into a single virtual term per query token
    # so morphological variants ("cap", "capital") never double-count IDF on the same token.
    defp collect_token_postings(db, collection, token, opts) do
      exact_boost = opts[:exact_boost]
      prefix_weight = opts[:prefix_weight]

      prefix_postings =
        if opts[:prefix?] and length(String.to_charlist(token)) >= opts[:min_prefix_length] do
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

      if prefix_postings == [] do
        db
        |> Storage.lookup_term(collection, token)
        |> Map.new(fn {doc_key, scaled_tf} ->
          {doc_key, scaled_tf / @weight_scale * exact_boost}
        end)
      else
        Enum.reduce(prefix_postings, %{}, fn {matched_term, postings}, acc ->
          multiplier = if matched_term == token, do: exact_boost, else: prefix_weight

          Enum.reduce(postings, acc, fn {doc_key, scaled_tf}, inner ->
            tf = scaled_tf / @weight_scale * multiplier
            Map.update(inner, doc_key, tf, &(&1 + tf))
          end)
        end)
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
           resource
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
      |> Enum.map(fn {doc_key, score} -> {decode_doc_key(resource, doc_key), score} end)
    end

    # -- Internal Indexing & Diff Calculation --

    defp extract_weighted_terms(record, search_fields, db) do
      {terms, _len} =
        extract_weighted_terms_and_len(record, compile_search_plan(search_fields), db)

      terms
    end

    defp do_extract_weighted_terms([], _record, _db, acc, total_len), do: {acc, total_len}

    defp do_extract_weighted_terms([{field, weight, resolver} | rest], record, db, acc, total_len) do
      raw_value =
        case resolver do
          fun when is_function(fun, 2) -> fun.(record, db)
          nil -> Map.get(record, field)
        end

      {next_acc, next_len} = add_field_tokens(raw_value, weight, acc, total_len)
      do_extract_weighted_terms(rest, record, db, next_acc, next_len)
    end

    defp add_field_tokens(value, weight, acc, len) when is_binary(value) do
      add_token_list(tokenize(value), weight, acc, len)
    end

    defp add_field_tokens(%Ash.CiString{} = value, weight, acc, len) do
      add_token_list(tokenize(value), weight, acc, len)
    end

    defp add_field_tokens(values, weight, acc, len) when is_list(values) do
      Enum.reduce(values, {acc, len}, fn v, {a, l} ->
        add_field_tokens(v, weight, a, l)
      end)
    end

    defp add_field_tokens(value, weight, acc, len)
         when is_atom(value) and not is_nil(value) and not is_boolean(value) do
      add_token_list(value |> Atom.to_string() |> tokenize(), weight, acc, len)
    end

    defp add_field_tokens(_other, _weight, acc, len), do: {acc, len}

    defp add_token_list([], _weight, acc, len), do: {acc, len}

    defp add_token_list([token | rest], weight, acc, len) do
      next_acc =
        case acc do
          %{^token => cur} -> Map.put(acc, token, cur + weight)
          _ -> Map.put(acc, token, weight)
        end

      add_token_list(rest, weight, next_acc, len + weight)
    end

    defp do_index_records_snapshot(
           {%Xitdb{} = db, moment},
           resource,
           search_fields,
           records,
           opts
         ) do
      tenant = opts[:tenant]
      collection = Codec.scoped_collection(resource, tenant)
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
      check_existing? = not Keyword.get(opts, :assume_new?, false)
      parallel? = Keyword.get(opts, :parallel, true)
      worker_wrapper = Keyword.get(opts, :worker_wrapper)
      cursor_root = Xitdb.as_of(db, moment)

      # Deduplicate by doc_id keeping the last occurrence to remain idempotent
      {deduped_items, _seen} =
        records
        |> Enum.reverse()
        |> Enum.reduce({[], MapSet.new()}, fn record, {acc, seen} ->
          doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(record, pk_name))

          if MapSet.member?(seen, doc_id) do
            {acc, seen}
          else
            {[{collection, doc_id, record, check_existing?} | acc], MapSet.put(seen, doc_id)}
          end
        end)

      ops =
        plan_bulk_index_ops(
          cursor_root,
          search_fields,
          deduped_items,
          parallel: parallel?,
          worker_wrapper: worker_wrapper
        )

      commit_bulk_search_ops({db, moment}, collection, ops)
    end

    defp plan_bulk_index_col_ops(
           cursor_root,
           scoped_col,
           search_plan,
           has_resolver?,
           col_items,
           parallel_opt,
           worker_wrapper
         ) do
      stats = Storage.read_corpus_stats(cursor_root, scoped_col)
      docs_cur = Storage.get_docs_cursor(cursor_root, scoped_col)

      old_docs_map =
        if docs_cur != nil do
          existing_ids = for {_col, doc_id, _rec, true} <- col_items, do: doc_id

          if existing_ids == [] do
            %{}
          else
            Storage.read_docs_from_cursor(docs_cur, existing_ids)
          end
        else
          %{}
        end

      total = length(col_items)

      run_parallel? =
        case parallel_opt do
          true -> total >= 128
          :auto -> not has_resolver? and total >= 500
          false -> false
        end

      {dc_delta, len_delta, changed?, doc_entries, deleted_docs, term_postings, deleted_terms} =
        if run_parallel? do
          concurrency = min(System.schedulers_online(), 8)
          slice_size = max(div(total + concurrency - 1, concurrency), 1)
          has_old_docs? = map_size(old_docs_map) > 0

          slice_pairs =
            col_items
            |> Enum.chunk_every(slice_size)
            |> Enum.map(fn slice ->
              slice_old =
                if has_old_docs? do
                  Enum.reduce(slice, %{}, fn {_c, doc_id, _rec, check?}, acc ->
                    if check? do
                      case Map.fetch(old_docs_map, doc_id) do
                        {:ok, doc} -> Map.put(acc, doc_id, doc)
                        :error -> acc
                      end
                    else
                      acc
                    end
                  end)
                else
                  %{}
                end

              {slice, slice_old}
            end)

          slice_pairs
          |> Task.async_stream(
            fn {slice, slice_old} ->
              run_with_worker_wrapper(worker_wrapper, cursor_root, fn ->
                extract_bulk_index_slice(slice, cursor_root, search_plan, slice_old)
              end)
            end,
            max_concurrency: concurrency,
            ordered: false,
            timeout: :infinity
          )
          |> Enum.reduce({0, 0, false, [], [], %{}, []}, fn
            {:ok, {sdc, slen, sch?, sdocs, sdel_docs, sterms, sdel_terms}},
            {adc, alen, ach?, adocs, adel_docs, aterms, adel_terms} ->
              merged_terms =
                if map_size(aterms) == 0 do
                  sterms
                else
                  merge_term_postings(aterms, sterms)
                end

              {
                adc + sdc,
                alen + slen,
                ach? or sch?,
                sdocs ++ adocs,
                sdel_docs ++ adel_docs,
                merged_terms,
                sdel_terms ++ adel_terms
              }
          end)
        else
          run_with_worker_wrapper(worker_wrapper, cursor_root, fn ->
            extract_bulk_index_slice(col_items, cursor_root, search_plan, old_docs_map)
          end)
        end

      if not changed? do
        []
      else
        new_doc_count = max(0, stats.doc_count + dc_delta)
        new_total_len = max(0, stats.total_len + len_delta)

        meta_op =
          {:put, ["idx", "search", scoped_col, "meta"],
           %{"doc_count" => new_doc_count, "total_len" => new_total_len}}

        rm_doc_ops =
          Enum.map(deleted_docs, fn doc_id ->
            {:rm, ["idx", "search", scoped_col, "docs", doc_id]}
          end)

        doc_put_ops =
          if doc_entries == [] do
            []
          else
            [{:bulk_put_maps, ["idx", "search", scoped_col, "docs"], doc_entries}]
          end

        term_put_ops =
          if map_size(term_postings) == 0 do
            []
          else
            sorted_terms = :lists.keysort(1, :maps.to_list(term_postings))

            [
              {:bulk_index_puts, ["idx", "search", scoped_col, "terms"], :hash_map_merge,
               sorted_terms}
            ]
          end

        term_rm_ops =
          if deleted_terms == [] do
            []
          else
            deleted_terms
            |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
            |> Enum.flat_map(fn {term, doc_ids} ->
              removed_set = MapSet.new(doc_ids)

              has_remaining? =
                Map.has_key?(term_postings, term) or
                  Storage.term_has_doc_outside?(cursor_root, scoped_col, term, removed_set)

              if has_remaining? do
                Enum.map(removed_set, fn doc_id ->
                  {:rm, ["idx", "search", scoped_col, "terms", {:sorted_map, term}, doc_id]}
                end)
              else
                [{:rm, ["idx", "search", scoped_col, "terms", {:sorted_map, term}]}]
              end
            end)
          end

        [meta_op | rm_doc_ops] ++ doc_put_ops ++ term_put_ops ++ term_rm_ops
      end
    end

    defp extract_bulk_index_slice(slice, cursor_root, search_plan, old_docs_map) do
      {dc, len, ch?, docs_rev, del_docs_rev, terms, del_terms} =
        Enum.reduce(slice, {0, 0, false, [], [], %{}, []}, fn item, acc ->
          diff_bulk_index_item(item, cursor_root, search_plan, old_docs_map, acc)
        end)

      {dc, len, ch?, Enum.reverse(docs_rev), Enum.reverse(del_docs_rev), terms, del_terms}
    end

    defp diff_bulk_index_item(
           {_col, doc_id, record, check_existing?},
           cursor_root,
           search_plan,
           old_docs_map,
           {dc_acc, len_acc, ch?, docs_rev, del_docs_rev, terms_acc, del_terms_acc}
         ) do
      {new_terms, new_len} = extract_weighted_terms_and_len(record, search_plan, cursor_root)

      old_doc =
        if check_existing? and map_size(old_docs_map) > 0 do
          Map.get(old_docs_map, doc_id, %{len: 0, terms: %{}})
        else
          %{len: 0, terms: %{}}
        end

      if old_doc.terms == new_terms do
        {dc_acc, len_acc, ch?, docs_rev, del_docs_rev, terms_acc, del_terms_acc}
      else
        old_len = old_doc.len
        was_indexed? = old_len > 0
        now_indexed? = new_len > 0

        dc_delta =
          cond do
            not was_indexed? and now_indexed? -> 1
            was_indexed? and not now_indexed? -> -1
            true -> 0
          end

        next_docs_rev =
          if now_indexed? do
            [{doc_id, %{"len" => new_len, "terms" => new_terms}, []} | docs_rev]
          else
            docs_rev
          end

        next_del_docs_rev =
          if not now_indexed? and was_indexed? do
            [doc_id | del_docs_rev]
          else
            del_docs_rev
          end

        next_terms =
          if was_indexed? do
            add_changed_term_postings(
              :maps.next(:maps.iterator(new_terms)),
              doc_id,
              old_doc.terms,
              terms_acc
            )
          else
            add_term_postings(:maps.next(:maps.iterator(new_terms)), doc_id, terms_acc)
          end

        next_del_terms =
          if was_indexed? do
            collect_deleted_terms(
              :maps.next(:maps.iterator(old_doc.terms)),
              doc_id,
              new_terms,
              del_terms_acc
            )
          else
            del_terms_acc
          end

        {
          dc_acc + dc_delta,
          len_acc + (new_len - old_len),
          true,
          next_docs_rev,
          next_del_docs_rev,
          next_terms,
          next_del_terms
        }
      end
    end

    defp add_changed_term_postings(:none, _doc_id, _old_terms, acc), do: acc

    defp add_changed_term_postings({term, new_w, iter}, doc_id, old_terms, acc) do
      next_acc =
        case old_terms do
          %{^term => ^new_w} ->
            acc

          _ ->
            case acc do
              %{^term => existing} -> Map.put(acc, term, [{doc_id, new_w} | existing])
              _ -> Map.put(acc, term, [{doc_id, new_w}])
            end
        end

      add_changed_term_postings(:maps.next(iter), doc_id, old_terms, next_acc)
    end

    defp collect_deleted_terms(:none, _doc_id, _new_terms, acc), do: acc

    defp collect_deleted_terms({old_term, _old_w, iter}, doc_id, new_terms, acc) do
      next_acc =
        if Map.has_key?(new_terms, old_term) do
          acc
        else
          [{old_term, doc_id} | acc]
        end

      collect_deleted_terms(:maps.next(iter), doc_id, new_terms, next_acc)
    end

    defp commit_bulk_search_ops({db, moment}, _collection, []), do: {db, moment}

    defp commit_bulk_search_ops({db, moment}, collection, ops) do
      base_opts = Storage.search_reindex_tx_opts(collection)

      tx_opts =
        if moment >= 0 do
          Keyword.put(base_opts, :base_moment, moment)
        else
          base_opts
        end

      case Xitdb.transact_ops_with_moment(db, ops, tx_opts) do
        {:ok, next_db, next_moment} -> {next_db, next_moment}
        {:error, %_{} = err} when is_exception(err) -> raise err
        {:error, reason} -> raise Xitdb.Error, reason: reason
      end
    end

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

    defp do_rebuild_snapshot({%Xitdb{} = db, moment}, resource, opts) do
      search_fields = Info.search_fields(resource)
      tenant = opts[:tenant]
      collection = Codec.scoped_collection(resource, tenant)
      cursor_root = Xitdb.as_of(db, moment)
      parallel? = Keyword.get(opts, :parallel, true)
      worker_wrapper = Keyword.get(opts, :worker_wrapper)

      only_attrs =
        resolve_rebuild_only_attrs(resource, search_fields, Keyword.get(opts, :only_attrs, :auto))

      cursors = Indexer.all_cursors(cursor_root, resource, tenant)

      {doc_count, total_len, doc_entries, term_postings_map} =
        extract_corpus_entries(
          cursor_root,
          cursors,
          resource,
          tenant,
          only_attrs,
          search_fields,
          parallel?,
          worker_wrapper
        )

      existing_search? =
        case cursor_root["idx"] do
          %Xitdb.Cursor{} = idx ->
            case idx["search"] do
              %Xitdb.Cursor{} = s -> s[collection] != nil
              _ -> false
            end

          _ ->
            false
        end

      if doc_count == 0 and not existing_search? do
        {db, moment}
      else
        rm_op = {:rm_if_exists, ["idx", "search", collection]}

        ops =
          if doc_count == 0 do
            [rm_op]
          else
            sorted_terms = :lists.keysort(1, :maps.to_list(term_postings_map))

            [
              rm_op,
              {:put, ["idx", "search", collection, "meta"],
               %{"doc_count" => doc_count, "total_len" => total_len}},
              {:bulk_put_maps, ["idx", "search", collection, "docs"], doc_entries},
              {:bulk_index_puts, ["idx", "search", collection, "terms"], :hash_map_merge,
               sorted_terms}
            ]
          end

        base_opts = Storage.search_reindex_tx_opts(collection)

        tx_opts =
          if moment >= 0 do
            Keyword.put(base_opts, :base_moment, moment)
          else
            base_opts
          end

        case Xitdb.transact_ops_with_moment(db, ops, tx_opts) do
          {:ok, next_db, next_moment} -> {next_db, next_moment}
          {:error, %_{} = err} when is_exception(err) -> raise err
          {:error, reason} -> raise Xitdb.Error, reason: reason
        end
      end
    end

    defp resolve_rebuild_only_attrs(resource, search_fields, :auto) do
      if Enum.any?(search_fields, &(&1.resolver != nil)) do
        :all
      else
        search_fields
        |> Enum.map(& &1.field)
        |> maybe_add_tenant_attr(resource)
        |> MapSet.new()
      end
    end

    defp resolve_rebuild_only_attrs(_resource, _search_fields, :all), do: :all

    defp resolve_rebuild_only_attrs(resource, _search_fields, %MapSet{} = set) do
      set |> MapSet.to_list() |> maybe_add_tenant_attr(resource) |> MapSet.new()
    end

    defp resolve_rebuild_only_attrs(resource, _search_fields, list) when is_list(list) do
      list |> maybe_add_tenant_attr(resource) |> MapSet.new()
    end

    defp maybe_add_tenant_attr(attrs, resource) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
        [Ash.Resource.Info.multitenancy_attribute(resource) | attrs]
      else
        attrs
      end
    end

    defp extract_corpus_entries(
           _cursor_root,
           [],
           _resource,
           _tenant,
           _only_attrs,
           _search_fields,
           _parallel?,
           _worker_wrapper
         ) do
      {0, 0, [], %{}}
    end

    defp extract_corpus_entries(
           cursor_root,
           cursors,
           resource,
           tenant,
           only_attrs,
           search_fields,
           parallel?,
           worker_wrapper
         ) do
      total = length(cursors)
      read_plan = Codec.compile_read_plan(resource, only_attrs, tenant)
      search_plan = compile_search_plan(search_fields)

      if parallel? and total >= 128 do
        concurrency = min(System.schedulers_online(), 8)
        slice_size = max(div(total + concurrency - 1, concurrency), 1)

        cursors
        |> Enum.chunk_every(slice_size)
        |> Task.async_stream(
          fn slice ->
            run_with_worker_wrapper(worker_wrapper, cursor_root, fn ->
              extract_corpus_slice(
                slice,
                cursor_root,
                resource,
                tenant,
                read_plan,
                search_plan
              )
            end)
          end,
          max_concurrency: concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce({0, 0, [], %{}}, fn {:ok, {sc, sl, sdocs, sterms}},
                                           {ac, al, adocs, aterms} ->
          merged_docs = sdocs ++ adocs

          merged_terms =
            if map_size(aterms) == 0 do
              sterms
            else
              merge_term_postings(aterms, sterms)
            end

          {ac + sc, al + sl, merged_docs, merged_terms}
        end)
      else
        run_with_worker_wrapper(worker_wrapper, cursor_root, fn ->
          extract_corpus_slice(cursors, cursor_root, resource, tenant, read_plan, search_plan)
        end)
      end
    end

    defp run_with_worker_wrapper(nil, _cursor_root, fun), do: fun.()

    defp run_with_worker_wrapper(wrapper, _cursor_root, fun) when is_function(wrapper, 1),
      do: wrapper.(fun)

    defp run_with_worker_wrapper(wrapper, cursor_root, fun) when is_function(wrapper, 2),
      do: wrapper.(cursor_root, fun)

    defp extract_corpus_slice(slice, cursor_root, resource, tenant, read_plan, search_plan) do
      filter_tenant? = Ash.Resource.Info.multitenancy_strategy(resource) != :attribute

      Enum.reduce(slice, {0, 0, [], %{}}, fn {doc_id, cursor},
                                             {c_acc, l_acc, docs_acc, terms_acc} ->
        with {:ok, record} <- Codec.from_cursor_fast(read_plan, cursor, tenant),
             true <- not filter_tenant? or Codec.matches_tenant?(resource, record, tenant) do
          {terms, len} = extract_weighted_terms_and_len(record, search_plan, cursor_root)

          if len > 0 do
            doc_entry = {doc_id, %{"len" => len, "terms" => terms}, []}
            next_terms = add_term_postings(:maps.next(:maps.iterator(terms)), doc_id, terms_acc)
            {c_acc + 1, l_acc + len, [doc_entry | docs_acc], next_terms}
          else
            {c_acc, l_acc, docs_acc, terms_acc}
          end
        else
          _ -> {c_acc, l_acc, docs_acc, terms_acc}
        end
      end)
    end

    defp add_term_postings(:none, _doc_id, acc), do: acc

    defp add_term_postings({term, weight, iter}, doc_id, acc) do
      next_acc =
        case acc do
          %{^term => existing} -> Map.put(acc, term, [{doc_id, weight} | existing])
          _ -> Map.put(acc, term, [{doc_id, weight}])
        end

      add_term_postings(:maps.next(iter), doc_id, next_acc)
    end

    defp merge_term_postings(target, source) when map_size(target) < map_size(source) do
      merge_term_postings(source, target)
    end

    defp merge_term_postings(target, source) do
      do_merge_term_postings(:maps.next(:maps.iterator(source)), target)
    end

    defp do_merge_term_postings(:none, acc), do: acc

    defp do_merge_term_postings({term, postings, iter}, acc) do
      next_acc =
        case acc do
          %{^term => existing} -> Map.put(acc, term, postings ++ existing)
          _ -> Map.put(acc, term, postings)
        end

      do_merge_term_postings(:maps.next(iter), next_acc)
    end

    defp decode_doc_key(resource, key) do
      case Codec.decode_doc_id(resource, key) do
        {:ok, pk_val} -> pk_val
        _ -> key
      end
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
           entity when not is_nil(entity) <-
             read_path(root, [{:hash_map, collection}, {:hash_map, doc_key}]) do
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
      with root when not is_nil(root) <- root_cursor(db),
           doc when not is_nil(doc) <-
             read_path(root, [
               {:hash_map, "idx"},
               {:hash_map, "search"},
               {:hash_map, collection},
               {:hash_map, "docs"},
               {:hash_map, doc_key}
             ]) do
        decode_search_doc_val(doc)
      else
        _ -> %{len: 0, terms: %{}}
      end
    end

    @doc false
    @spec get_docs_cursor(term(), String.t()) :: Xitdb.Cursor.t() | nil
    def get_docs_cursor(db, collection) do
      case get_in_search(db, collection, "docs") do
        %Xitdb.Cursor{} = docs -> docs
        _ -> nil
      end
    end

    @doc false
    @spec read_docs_from_cursor(term(), [String.t()]) :: %{
            optional(String.t()) => %{
              len: non_neg_integer(),
              terms: %{optional(String.t()) => pos_integer()}
            }
          }
    def read_docs_from_cursor(nil, _doc_ids), do: %{}
    def read_docs_from_cursor(_docs_cur, []), do: %{}

    def read_docs_from_cursor(%Xitdb.Cursor{tx_mode: false} = raw_cur, doc_ids)
        when is_list(doc_ids) do
      cur = if raw_cur.tag_id == -1, do: Xitdb.Cursor.ensure_resolved(raw_cur), else: raw_cur

      if cur.tag in [:hash_map, :counted_hash_map, :sorted_map] do
        doc_ids
        |> Enum.uniq()
        |> Enum.chunk_every(2048)
        |> Enum.reduce(%{}, fn chunk, acc ->
          case Xitdb.NIF.nif_slot_get_keys(cur.db_ref, cur.tag_id, cur.value, chunk) do
            {:ok, hits} when is_map(hits) ->
              Enum.reduce(hits, acc, fn {doc_id, raw_doc}, doc_acc ->
                doc_val = Xitdb.Cursor.unwrap_nif_value(cur.db_ref, raw_doc, cur.moment)
                Map.put(doc_acc, doc_id, decode_search_doc_val(doc_val))
              end)

            {:error, _reason} ->
              fallback_read_docs_from_cursor(cur, chunk, acc)
          end
        end)
      else
        %{}
      end
    end

    def read_docs_from_cursor(docs_cur, doc_ids) when is_list(doc_ids) do
      fallback_read_docs_from_cursor(docs_cur, Enum.uniq(doc_ids), %{})
    end

    defp fallback_read_docs_from_cursor(docs_cur, doc_ids, acc) do
      Enum.reduce(doc_ids, acc, fn doc_id, m ->
        case docs_cur[doc_id] do
          nil -> m
          doc -> Map.put(m, doc_id, decode_search_doc_val(doc))
        end
      end)
    end

    defp decode_search_doc_val(%Xitdb.Cursor{tx_mode: false} = raw_doc_cur) do
      doc_cur =
        if raw_doc_cur.tag_id == -1,
          do: Xitdb.Cursor.ensure_resolved(raw_doc_cur),
          else: raw_doc_cur

      if doc_cur.tag in [:hash_map, :counted_hash_map, :sorted_map] do
        case Xitdb.NIF.nif_slot_get_keys(doc_cur.db_ref, doc_cur.tag_id, doc_cur.value, [
               "len",
               "terms"
             ]) do
          {:ok, fields} when is_map(fields) ->
            len = Map.get(fields, "len") || 0

            terms =
              case Map.get(fields, "terms") do
                nil ->
                  %{}

                raw_terms ->
                  doc_cur.db_ref
                  |> Xitdb.Cursor.unwrap_nif_value(raw_terms, doc_cur.moment)
                  |> unwrap_search_doc_terms()
              end

            %{len: len, terms: terms}

          {:error, _reason} ->
            %{len: doc_cur["len"] || 0, terms: unwrap_search_doc_terms(doc_cur["terms"])}
        end
      else
        %{len: 0, terms: %{}}
      end
    end

    defp decode_search_doc_val(doc) when is_map(doc) and not is_struct(doc) do
      %{len: doc["len"] || 0, terms: unwrap_search_doc_terms(doc["terms"])}
    end

    defp decode_search_doc_val(doc) do
      %{len: doc["len"] || 0, terms: unwrap_search_doc_terms(doc["terms"])}
    end

    defp unwrap_search_doc_terms(nil), do: %{}

    defp unwrap_search_doc_terms(%Xitdb.Collection{data: data}) do
      Map.new(data, fn {k, v} -> {to_string(k), v} end)
    end

    defp unwrap_search_doc_terms(raw_terms)
         when is_map(raw_terms) and not is_struct(raw_terms) do
      raw_terms
    end

    defp unwrap_search_doc_terms(%Xitdb.Cursor{} = terms_cur), do: Map.new(terms_cur)
    defp unwrap_search_doc_terms(_other), do: %{}

    @spec read_doc_len(term(), String.t(), String.t()) :: non_neg_integer()
    def read_doc_len(db, collection, doc_key) do
      with root when not is_nil(root) <- root_cursor(db),
           doc when not is_nil(doc) <-
             read_path(root, [
               {:hash_map, "idx"},
               {:hash_map, "search"},
               {:hash_map, collection},
               {:hash_map, "docs"},
               {:hash_map, doc_key}
             ]) do
        doc["len"] || 0
      else
        _ -> 0
      end
    end

    @spec lookup_term(term(), String.t(), String.t()) :: [{String.t(), pos_integer()}]
    def lookup_term(db, collection, term) do
      with root when not is_nil(root) <- root_cursor(db),
           postings when not is_nil(postings) <-
             read_path(root, [
               {:hash_map, "idx"},
               {:hash_map, "search"},
               {:hash_map, collection},
               {:hash_map, "terms"},
               {:sorted_map, term}
             ]) do
        Enum.to_list(postings)
      else
        _ -> []
      end
    end

    @doc false
    @spec term_has_doc_outside?(term(), String.t(), String.t(), MapSet.t(String.t())) ::
            boolean()
    def term_has_doc_outside?(db, collection, term, %MapSet{} = excluded) do
      with root when not is_nil(root) <- root_cursor(db),
           postings when not is_nil(postings) <-
             read_path(root, [
               {:hash_map, "idx"},
               {:hash_map, "search"},
               {:hash_map, collection},
               {:hash_map, "terms"},
               {:sorted_map, term}
             ]) do
        postings_has_other_doc?(postings, excluded)
      else
        _ -> false
      end
    end

    defp postings_has_other_doc?(
           %Xitdb.Cursor{
             tx_mode: false,
             db_ref: db_ref,
             tag_id: tag_id,
             value: val,
             moment: moment
           },
           excluded
         )
         when tag_id > 0 do
      limit = max(MapSet.size(excluded) + 1, 1)

      case Xitdb.NIF.nif_slot_entries(db_ref, tag_id, val, 0, limit) do
        {:ok, raw_entries} ->
          db_ref
          |> Xitdb.Cursor.unwrap_nif_entries(raw_entries, moment)
          |> Enum.any?(fn {k, _v} -> not MapSet.member?(excluded, to_string(k)) end)

        {:error, _reason} ->
          false
      end
    end

    defp postings_has_other_doc?(postings, excluded) do
      Enum.any?(postings, fn {k, _v} -> not MapSet.member?(excluded, to_string(k)) end)
    end

    @spec scan_prefix_cursors(term(), String.t(), String.t(), pos_integer()) ::
            {[{String.t(), Xitdb.Cursor.t()}], String.t() | nil}
    def scan_prefix_cursors(db, collection, prefix, limit) do
      case get_in_search(db, collection, "terms") do
        %Xitdb.Cursor{
          db_ref: db_ref,
          tag: :sorted_map,
          tag_id: tag_id,
          value: val,
          moment: moment
        }
        when tag_id > 0 ->
          case Xitdb.NIF.nif_sorted_map_seek(db_ref, tag_id, val, prefix, limit) do
            {:ok, entries, next_cursor} ->
              cursors =
                Enum.flat_map(entries, fn
                  {term, p_tag_id, p_val} when is_integer(p_tag_id) and is_integer(p_val) ->
                    [{term, Xitdb.Cursor.from_compact_slot(db_ref, p_tag_id, p_val, moment)}]

                  {term, {:cursor, _, _} = slot_tuple} ->
                    [{term, Xitdb.Cursor.from_nif_tuple(db_ref, slot_tuple, moment)}]

                  {_term, _scalar_or_nil} ->
                    []
                end)

              {cursors, next_cursor}

            {:error, reason} ->
              raise Xitdb.Error, reason: reason
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
      case get_in_search(db, collection, "terms") do
        %Xitdb.Cursor{tx_mode: false, tag: :sorted_map} = terms ->
          scan_prefix_via_slot_entries_cursor(terms, prefix, limit)

        other ->
          scan_prefix_from_map_or_cursor(other, prefix, limit)
      end
    end

    def scan_prefix(db, collection, prefix, limit, _backend) do
      case get_in_search(db, collection, "terms") do
        %Xitdb.Cursor{
          db_ref: db_ref,
          tag: :sorted_map,
          tag_id: tag_id,
          value: val,
          moment: moment,
          tx_mode: false
        } ->
          if tag_id > 0 do
            case Xitdb.NIF.nif_sorted_map_seek(db_ref, tag_id, val, prefix, limit, true, true) do
              {:ok, entries, _next} ->
                Enum.map(entries, fn
                  {term, postings} when is_list(postings) ->
                    {term, Xitdb.Cursor.unwrap_nif_entries(db_ref, postings, moment)}

                  {term, p_tag_id, p_val} when is_integer(p_tag_id) and is_integer(p_val) ->
                    {term,
                     db_ref
                     |> Xitdb.Cursor.from_compact_slot(p_tag_id, p_val, moment)
                     |> Enum.to_list()}

                  {term, {:cursor, _, _} = slot_tuple} ->
                    {term,
                     db_ref
                     |> Xitdb.Cursor.from_nif_tuple(slot_tuple, moment)
                     |> Enum.to_list()}

                  {term, _other} ->
                    {term, []}
                end)

              {:error, reason} ->
                raise Xitdb.Error, reason: reason
            end
          else
            []
          end

        other ->
          scan_prefix_from_map_or_cursor(other, prefix, limit)
      end
    end

    defp scan_prefix_from_map_or_cursor(nil, _prefix, _limit), do: []

    defp scan_prefix_from_map_or_cursor(%Xitdb.Collection{data: data}, prefix, limit) do
      data
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> scan_prefix_from_entries(prefix, limit)
    end

    defp scan_prefix_from_map_or_cursor(terms, prefix, limit) when is_map(terms) do
      terms
      |> Enum.to_list()
      |> scan_prefix_from_entries(prefix, limit)
    end

    defp scan_prefix_from_entries(entries, prefix, limit) do
      entries
      |> Enum.filter(fn {term, _postings} -> String.starts_with?(term, prefix) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(limit)
      |> Enum.map(fn {term, raw_postings} ->
        {term, materialize_postings_list(raw_postings)}
      end)
    end

    defp materialize_postings_list(%Xitdb.Collection{data: data}), do: Enum.to_list(data)
    defp materialize_postings_list(postings) when is_map(postings), do: Enum.to_list(postings)
    defp materialize_postings_list(postings) when is_list(postings), do: postings
    defp materialize_postings_list(_), do: []

    defp scan_prefix_via_slot_entries_cursor(%Xitdb.Cursor{} = terms, prefix, limit) do
      case Xitdb.NIF.nif_slot_count(terms.db_ref, terms.tag_id, terms.value) do
        {:ok, total_count} when total_count > 0 and limit > 0 ->
          start_idx = find_prefix_start_index(terms, prefix, 0, total_count)
          stream_prefix_from(terms, prefix, start_idx, limit)

        {:ok, _} ->
          []

        {:error, reason} ->
          raise Xitdb.Error, reason: reason
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

        {:ok, _} ->
          low

        {:error, reason} ->
          raise Xitdb.Error, reason: reason
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

          {:error, reason} ->
            raise Xitdb.Error, reason: reason
        end
      end)
      |> Stream.flat_map(& &1)
      |> Stream.take_while(fn {term, _} -> String.starts_with?(term, prefix) end)
      |> Stream.take(limit)
      |> Enum.map(fn {term, raw_postings} ->
        postings =
          case raw_postings do
            {:cursor, c_tag_id, c_val} ->
              decode_slot_entries!(terms.db_ref, c_tag_id, c_val, terms.moment)

            list when is_list(list) ->
              Xitdb.Cursor.unwrap_nif_entries(terms.db_ref, list, terms.moment)

            _other ->
              []
          end

        {term, postings}
      end)
    end

    defp decode_slot_entries!(db_ref, tag_id, val, moment) do
      case Xitdb.NIF.nif_slot_entries(db_ref, tag_id, val, 0, -1) do
        {:ok, entries} ->
          Xitdb.Cursor.unwrap_nif_entries(db_ref, entries, moment)

        {:error, reason} ->
          raise Xitdb.Error, reason: reason
      end
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

            if term_has_doc_outside?(db, collection, term, MapSet.new([doc_key])) do
              [{:rm, terms_prefix <> "$" <> term_str <> "." <> doc_str}]
            else
              [{:rm, terms_prefix <> "$" <> term_str}]
            end
        end)

      ops = meta_ops ++ doc_ops ++ term_ops
      base_opts = search_reindex_tx_opts(collection)

      case db do
        {%Xitdb{} = raw_db, moment} when is_integer(moment) ->
          {:ok, new_db, next_moment} =
            Xitdb.transact_ops_with_moment(
              raw_db,
              ops,
              Keyword.put(base_opts, :base_moment, moment)
            )

          {new_db, next_moment}

        %Xitdb.Cursor{db_ref: db_ref, moment: moment, tx_mode: false} ->
          raw_db = %Xitdb{db_ref: db_ref, backend: :memory}

          opts =
            if is_integer(moment) and moment >= 0 do
              Keyword.put(base_opts, :base_moment, moment)
            else
              base_opts
            end

          {:ok, new_db, next_moment} = Xitdb.transact_ops_with_moment(raw_db, ops, opts)
          Xitdb.as_of(new_db, next_moment)

        %Xitdb.Cursor{tx_mode: true} = cursor ->
          stage_search_ops(cursor, ops)

        %Xitdb{} = raw_db ->
          {:ok, new_db} = Xitdb.transact_ops(raw_db, ops, base_opts)
          new_db
      end
    end

    @doc false
    def search_reindex_tx_opts(collection) do
      ctx = Xitdb.current_tx_context()

      doc =
        case ctx && ctx.doc do
          d when is_binary(d) and d != "" -> d
          _ -> "reindex search #{collection}"
        end

      instant = (ctx && ctx.instant) || System.os_time(:millisecond)

      meta =
        %{
          "source_system" => "xitdb_indexer",
          "action_name" => "reindex",
          "actor_id" => "system"
        }
        |> Map.merge((ctx && ctx.meta) || %{})

      [doc: doc, instant: instant, meta: meta]
    end

    @doc false
    def root_cursor({%Xitdb{} = db, moment}) when is_integer(moment), do: Xitdb.as_of(db, moment)
    def root_cursor(%Xitdb.Cursor{} = cursor), do: cursor
    def root_cursor(%Xitdb{} = db), do: Xitdb.db(db)
    def root_cursor(_), do: nil

    defp get_in_search(db, collection, slot) do
      case root_cursor(db) do
        %Xitdb.Cursor{} = root ->
          read_path(root, [
            {:hash_map, "idx"},
            {:hash_map, "search"},
            {:hash_map, collection},
            {:hash_map, slot}
          ])

        _ ->
          nil
      end
    end

    defp read_path(%Xitdb.Cursor{tx_mode: false} = root, steps) do
      Enum.reduce_while(steps, root, fn
        {_kind, key}, %Xitdb.Cursor{} = cur ->
          case cur[key] do
            nil -> {:halt, nil}
            next -> {:cont, next}
          end

        _, _ ->
          {:halt, nil}
      end)
    end

    defp read_path(%Xitdb.Cursor{tx_mode: true} = root, steps) do
      if map_size(root.staged_overrides) == 0 and MapSet.size(root.deleted_paths) == 0 do
        read_path(%{root | tx_mode: false}, steps)
      else
        read_staged_path(root, steps)
      end
    end

    defp read_staged_path(root, steps) do
      full_steps = :lists.reverse(steps, root.path_steps)
      sel = Xitdb.Cursor.steps_to_selector(full_steps)

      cond do
        path_or_ancestor_deleted?(root.deleted_paths, full_steps) ->
          nil

        Map.has_key?(root.staged_overrides, sel) ->
          base = unwrap_staged(Map.fetch!(root.staged_overrides, sel))
          overlay_descendants_if_needed(root, full_steps, sel, base)

        true ->
          base =
            case find_ancestor_override(root.staged_overrides, full_steps) do
              {:ok, anc_val, rem_steps} ->
                walk_overlay_steps(unwrap_staged(anc_val), rem_steps)

              :none ->
                read_path(%{root | tx_mode: false}, steps)
            end

          overlay_descendants_if_needed(root, full_steps, sel, base)
      end
    end

    defp overlay_descendants_if_needed(%Xitdb.Cursor{} = root, full_steps, sel, base) do
      has_desc? =
        Enum.any?(root.staged_overrides, fn {k, _} -> selector_descendant?(k, sel) end) or
          Enum.any?(root.deleted_paths, fn k -> selector_descendant?(k, sel) end)

      cond do
        not has_desc? ->
          base

        match?(%Xitdb.Cursor{}, base) ->
          %Xitdb.Cursor{} = base_cur = base

          staged_cur = %Xitdb.Cursor{
            base_cur
            | tx_mode: true,
              staged_ops: root.staged_ops,
              staged_overrides: root.staged_overrides,
              deleted_paths: root.deleted_paths
          }

          case base_cur.tag do
            tag when tag in [:hash_map, :counted_hash_map, :sorted_map] ->
              Xitdb.Cursor.apply_staged_overlay(staged_cur, Xitdb.materialize(base_cur))

            _ ->
              base
          end

        is_map(base) and not is_struct(base) ->
          Xitdb.Cursor.apply_staged_overlay(synthetic_map_cursor(root, full_steps), base)

        is_nil(base) ->
          case Xitdb.Cursor.apply_staged_overlay(synthetic_map_cursor(root, full_steps), %{}) do
            empty when empty == %{} -> nil
            non_empty -> non_empty
          end

        true ->
          base
      end
    end

    defp synthetic_map_cursor(%Xitdb.Cursor{} = root, full_steps) do
      %Xitdb.Cursor{
        root
        | tag: :hash_map,
          tag_id: Xitdb.Cursor.tag_id_for(:hash_map),
          value: 0,
          path_steps: full_steps
      }
    end

    defp path_or_ancestor_deleted?(deleted_paths, rev_steps) do
      MapSet.size(deleted_paths) > 0 and
        Stream.iterate(rev_steps, &tl/1)
        |> Stream.take_while(&(&1 != []))
        |> Enum.any?(fn prefix_steps ->
          MapSet.member?(deleted_paths, Xitdb.Cursor.steps_to_selector(prefix_steps))
        end)
    end

    defp find_ancestor_override(staged_overrides, rev_steps) do
      do_find_ancestor_override(staged_overrides, tl_or_empty(rev_steps), [hd(rev_steps)])
    end

    defp tl_or_empty([]), do: []
    defp tl_or_empty([_ | rest]), do: rest

    defp do_find_ancestor_override(_overrides, [], _rem), do: :none

    defp do_find_ancestor_override(overrides, anc_rev_steps, rem_fwd) do
      sel = Xitdb.Cursor.steps_to_selector(anc_rev_steps)

      case Map.fetch(overrides, sel) do
        {:ok, val} ->
          {:ok, val, rem_fwd}

        :error ->
          do_find_ancestor_override(overrides, tl(anc_rev_steps), [hd(anc_rev_steps) | rem_fwd])
      end
    end

    defp walk_overlay_steps(val, []), do: val
    defp walk_overlay_steps(nil, _), do: nil

    defp walk_overlay_steps(%Xitdb.Collection{data: data}, [{_kind, key} | rest])
         when is_map(data) do
      next_val =
        case Map.fetch(data, key) do
          {:ok, v} -> v
          :error -> Map.get(data, to_string(key))
        end

      walk_overlay_steps(next_val, rest)
    end

    defp walk_overlay_steps(map, [{_kind, key} | rest]) when is_map(map) and not is_struct(map) do
      next_val =
        case Map.fetch(map, key) do
          {:ok, v} -> v
          :error -> Map.get(map, to_string(key))
        end

      walk_overlay_steps(next_val, rest)
    end

    defp walk_overlay_steps(_val, _steps), do: nil

    defp unwrap_staged(%Xitdb.Collection{kind: kind, data: data})
         when kind in [:hash_map, :counted_hash_map, :sorted_map] do
      Map.new(data, fn {k, v} -> {to_string(k), unwrap_staged(v)} end)
    end

    defp unwrap_staged(other), do: other

    defp selector_descendant?(sel, ""), do: is_binary(sel) and sel != ""

    defp selector_descendant?(sel, prefix) do
      plen = byte_size(prefix)

      byte_size(sel) > plen and binary_part(sel, 0, plen) == prefix and
        :binary.at(sel, plen) in [?., ?#, ?$, ?[, ?%, ?^]
    end

    defp stage_search_ops(%Xitdb.Cursor{tx_mode: true} = cursor, ops) do
      {next_overrides, next_deleted} =
        Enum.reduce(ops, {cursor.staged_overrides, cursor.deleted_paths}, fn
          {:put, path, val}, {ov, del} ->
            {next_ov, next_del} = clear_deleted_for_write(ov, del, path)
            {Map.put(next_ov, path, val), next_del}

          {:reset_col, path, kind}, {ov, del} ->
            col_val =
              case kind do
                "sorted_map" -> Xitdb.sorted_map(%{})
                "counted_hash_map" -> Xitdb.counted_map(%{})
                _ -> %{}
              end

            next_ov =
              ov
              |> Enum.reject(fn {k, _v} -> k == path or selector_descendant?(k, path) end)
              |> Map.new()

            {seeded_ov, next_del} = clear_deleted_for_write(next_ov, del, path)
            {Map.put(seeded_ov, path, col_val), next_del}

          {:rm, path}, {ov, del} ->
            next_ov =
              ov
              |> Enum.reject(fn {k, _v} -> k == path or selector_descendant?(k, path) end)
              |> Map.new()

            next_del =
              del
              |> Enum.reject(fn k -> selector_descendant?(k, path) end)
              |> MapSet.new()
              |> MapSet.put(path)

            {next_ov, next_del}
        end)

      %Xitdb.Cursor{
        cursor
        | staged_ops: :lists.reverse(ops, cursor.staged_ops),
          staged_overrides: next_overrides,
          deleted_paths: next_deleted
      }
    end

    defp clear_deleted_for_write(ov, del, path) do
      Enum.reduce(del, {ov, MapSet.new()}, fn k, {ov_acc, del_acc} ->
        cond do
          k == path or selector_descendant?(k, path) ->
            {ov_acc, del_acc}

          selector_descendant?(path, k) ->
            {Map.put_new(ov_acc, k, %{}), del_acc}

          true ->
            {ov_acc, MapSet.put(del_acc, k)}
        end
      end)
    end
  end
end
