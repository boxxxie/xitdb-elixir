if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Mutator do
    @moduledoc """
    Transactional write engine (`create`, `bulk_create`, `update`, `update_query`,
    `upsert`, `destroy`, `destroy_query`), staged monotonic integer sequence allocator,
    Ash 3 atomic policy/validation evaluator, and same-store `on_delete` cascade enforcer.
    """

    alias Ash.Error.Changes.{InvalidAttribute, InvalidChanges, StaleRecord}
    alias Xitdb.Ash.{Codec, Compress, Indexer, Info, Query, Search, Store}
    alias Xitdb.Ash.Indexer.Storage, as: IndexStorage
    alias Xitdb.Ash.Mutator.Sequences
    alias Xitdb.Columnar

    @type snapshot :: {Xitdb.t(), non_neg_integer()}

    @mutation_stats_key :xitdb_ash_mutation_stats

    # -- Public DataLayer Mutation Entrypoints --

    @doc """
    Inserts a new entity cursor in a single atomic `Xitdb.transact_ops/3` commit,
    allocating `meta.sequences[scoped_collection]` when `:id` is `nil` on generated
    integer primary keys and rejecting duplicate primary keys or unique identities.
    """
    @spec create(module(), Ash.Changeset.t()) :: {:ok, struct()} | {:error, term()}
    def create(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      emit_mutation_telemetry(resource, :create, fn ->
        case Store.mutate(store, fn snapshot ->
               create_in_snapshot(snapshot, resource, changeset)
             end) do
          {:ok, _record} = ok ->
            put_mutation_record_count(1)
            ok

          {:error, _} = err ->
            err
        end
      end)
    end

    @doc """
    Inserts or upserts a stream of changesets inside the store writer lease.
    Non-upsert batches stage sequence counters, PK uniqueness, identity uniqueness,
    secondary indexes, and BM25 search postings into a single `Xitdb.transact_ops/3` commit.
    """
    @spec bulk_create(module(), Enumerable.t(), map() | keyword()) ::
            :ok | {:ok, [struct()]} | {:error, term()}
    def bulk_create(resource, stream, options) when is_atom(resource) do
      store = Info.store!(resource)
      opts = Map.new(options)
      return_records? = Map.get(opts, :return_records?, false)
      upsert? = Map.get(opts, :upsert?, false)
      upsert_keys = Map.get(opts, :upsert_keys) || Ash.Resource.Info.primary_key(resource)
      identity = Map.get(opts, :identity)
      tenant = Map.get(opts, :tenant)
      action_kind = if upsert?, do: :bulk_upsert, else: :bulk_create

      emit_mutation_telemetry(resource, action_kind, fn ->
        result =
          Store.mutate(store, fn initial_snapshot ->
            if upsert? do
              run_bulk_upserts(
                initial_snapshot,
                resource,
                stream,
                upsert_keys,
                identity,
                tenant,
                opts
              )
            else
              run_bulk_creates_single_commit(initial_snapshot, resource, stream, tenant, opts)
            end
          end)

        case result do
          {:ok, records} ->
            put_mutation_record_count(length(records))
            if return_records?, do: {:ok, records}, else: :ok

          {:error, _} = err ->
            err
        end
      end)
    end

    @doc """
    Atomically updates an existing entity in a single `Xitdb.transact_ops/3` commit inside
    the store writer lease, enforcing `changeset.filter` (row-level policies + optimistic locks),
    pre-update `changeset.atomics`, and `changeset.atomic_validations`.
    """
    @spec update(module(), Ash.Changeset.t()) :: {:ok, struct()} | {:error, term()}
    def update(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      emit_mutation_telemetry(resource, :update, fn ->
        case Store.mutate(store, fn snapshot ->
               update_in_snapshot(snapshot, resource, changeset)
             end) do
          {:ok, _record} = ok ->
            put_mutation_record_count(1)
            ok

          {:error, _} = err ->
            err
        end
      end)
    end

    @doc """
    Executes an atomic bulk `update_query/4` across all records matching `query`.
    """
    @spec update_query(Query.t(), Ash.Changeset.t(), module(), map() | keyword()) ::
            :ok | {:ok, [struct()]} | {:error, term()}
    def update_query(%Query{} = query, %Ash.Changeset{} = changeset, resource, options)
        when is_atom(resource) do
      store = Info.store!(resource)
      opts = Map.new(options)
      return_records? = Map.get(opts, :return_records?, false)
      effective_tenant = changeset.tenant || query.tenant || Map.get(opts, :tenant)
      scoped_query = %Query{query | select: nil, tenant: effective_tenant}
      scoped_changeset = %Ash.Changeset{changeset | tenant: effective_tenant}

      emit_mutation_telemetry(resource, :update_query, fn ->
        result =
          Store.mutate(store, fn {db, moment} = initial_snapshot ->
            cursor_root = Xitdb.as_of(db, moment)

            with {:ok, candidates} <- Query.execute(cursor_root, scoped_query, resource) do
              apply_bulk_updates(initial_snapshot, candidates, resource, scoped_changeset, opts)
            end
          end)

        case result do
          {:ok, updated_records} ->
            put_mutation_record_count(length(updated_records))
            if return_records?, do: {:ok, updated_records}, else: :ok

          {:error, _} = err ->
            err
        end
      end)
    end

    @doc """
    Executes a tenant-scoped atomic upsert by explicit `identity` or `keys` in a single
    `Xitdb.transact_ops/3` commit, preserving existing primary keys across all `upsert_fields` shapes.
    """
    @spec upsert(module(), Ash.Changeset.t(), [atom()], Ash.Resource.Identity.t() | atom() | nil) ::
            {:ok, struct()} | {:error, term()}
    def upsert(resource, %Ash.Changeset{} = changeset, keys, identity \\ nil)
        when is_atom(resource) and is_list(keys) do
      store = Info.store!(resource)

      emit_mutation_telemetry(resource, :upsert, fn ->
        case Store.mutate(store, fn snapshot ->
               upsert_in_snapshot(snapshot, resource, changeset, keys, identity, %{})
             end) do
          {:ok, record} = ok ->
            count = if Ash.Resource.get_metadata(record, :upsert_skipped) == true, do: 0, else: 1
            put_mutation_record_count(count)
            ok

          {:error, _} = err ->
            err
        end
      end)
    end

    @doc """
    Atomically destroys an entity after verifying `changeset.filter`, `changeset.atomic_validations`,
    and incoming same-store foreign-key `on_delete` rules (`:restrict`, `:nilify`, `:delete`).
    """
    @spec destroy(module(), Ash.Changeset.t()) :: :ok | {:error, term()}
    def destroy(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      emit_mutation_telemetry(resource, :destroy, fn ->
        case Store.mutate(store, fn snapshot ->
               destroy_in_snapshot(snapshot, resource, changeset)
             end) do
          {:ok, _deleted_record} ->
            put_mutation_record_count(1)
            :ok

          {:error, _} = err ->
            err
        end
      end)
    end

    @doc """
    Executes an atomic bulk `destroy_query/4` across all records matching `query`.
    """
    @spec destroy_query(Query.t(), Ash.Changeset.t(), module(), map() | keyword()) ::
            :ok | {:ok, [struct()]} | {:error, term()}
    def destroy_query(%Query{} = query, %Ash.Changeset{} = changeset, resource, options)
        when is_atom(resource) do
      store = Info.store!(resource)
      opts = Map.new(options)
      return_records? = Map.get(opts, :return_records?, false)
      effective_tenant = changeset.tenant || query.tenant || Map.get(opts, :tenant)
      scoped_query = %Query{query | select: nil, tenant: effective_tenant}
      scoped_changeset = %Ash.Changeset{changeset | tenant: effective_tenant}

      emit_mutation_telemetry(resource, :destroy_query, fn ->
        result =
          Store.mutate(store, fn {db, moment} = initial_snapshot ->
            cursor_root = Xitdb.as_of(db, moment)

            with {:ok, candidates} <- Query.execute(cursor_root, scoped_query, resource) do
              apply_bulk_destroys(initial_snapshot, candidates, resource, scoped_changeset, opts)
            end
          end)

        case result do
          {:ok, destroyed_records} ->
            put_mutation_record_count(length(destroyed_records))
            if return_records?, do: {:ok, destroyed_records}, else: :ok

          {:error, _} = err ->
            err
        end
      end)
    end

    # -- Internal Snapshot Create / Bulk Create / Update / Upsert / Destroy --

    defp create_in_snapshot({db, moment}, resource, %Ash.Changeset{} = changeset) do
      cursor_root = Xitdb.as_of(db, moment)
      tenant = changeset.tenant
      allow_existing? = allow_existing_cursor?(changeset)

      with {:ok, after_atomics} <- apply_create_record(resource, changeset),
           {:ok, record_with_pk, seq_ops, _seq_map} <-
             Sequences.plan_pk(cursor_root, resource, after_atomics, tenant, %{}),
           :ok <-
             verify_pk_unused(
               cursor_root,
               resource,
               record_with_pk,
               tenant,
               MapSet.new(),
               allow_existing?
             ),
           record <- finalize_loaded_record(resource, record_with_pk, tenant),
           :ok <- verify_atomic_validations(record, record, resource, changeset),
           :ok <- verify_create_filter(record, resource, changeset),
           {:ok, index_ops} <-
             Indexer.plan_put_ops(cursor_root, resource, nil, record, tenant)
             |> normalize_plan_error(),
           {:ok, next_snapshot} <-
             commit_ops(
               {db, moment},
               seq_ops ++ index_ops,
               build_commit_opts(resource, :create, changeset, nil)
             ) do
        {:ok, next_snapshot, record}
      end
    end

    defp run_bulk_creates_single_commit(
           {db, moment},
           resource,
           stream,
           fallback_tenant,
           options
         ) do
      row_group_configs =
        resource
        |> Info.compression_configs()
        |> Enum.filter(&(&1.mode == :row_group))

      if row_group_configs == [] do
        run_bulk_creates_standard({db, moment}, resource, stream, fallback_tenant, options)
      else
        run_bulk_creates_columnar(
          {db, moment},
          resource,
          stream,
          fallback_tenant,
          row_group_configs,
          options
        )
      end
    end

    defp run_bulk_creates_standard({db, moment}, resource, stream, fallback_tenant, options) do
      nested_spec = Indexer.resolve_nested_spec(resource)

      if match?(%{cardinality: :one}, nested_spec) do
        run_bulk_creates_legacy({db, moment}, resource, stream, fallback_tenant, options)
      else
        changesets = Enum.to_list(stream)

        case changesets do
          [] ->
            {:ok, {db, moment}, []}

          _ ->
            run_bulk_creates_coalesced(
              {db, moment},
              resource,
              changesets,
              nested_spec,
              fallback_tenant,
              options
            )
        end
      end
    end

    defp run_bulk_creates_coalesced(
           {db, moment},
           resource,
           changesets,
           nested_spec,
           fallback_tenant,
           options
         ) do
      cursor_root = Xitdb.as_of(db, moment)
      pk_list = Ash.Resource.Info.primary_key(resource)
      [pk_name | _] = pk_list
      pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
      single_pk? = match?([_], pk_list)
      int_pk? = single_pk? and Sequences.integer_attribute?(pk_attr)
      gen_int_pk? = int_pk? and Sequences.generated_int_pk?(pk_attr)

      attr_plan = Codec.compile_attr_plan(resource)
      identities = Ash.Resource.Info.identities(resource)

      indexes =
        resource
        |> Info.indexes()
        |> Enum.map(fn %{fields: fields} = spec ->
          %{
            slot: Indexer.index_slot_name(spec),
            fields: fields,
            attrs: Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
          }
        end)

      search_fields = Info.search_fields(resource)
      has_compress? = map_size(Info.compression_by_field(resource)) > 0
      need_existing_record? = identities != [] or indexes != []

      pass1 =
        changesets
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, [], %{}, nil}, fn {%Ash.Changeset{} = raw_cs, idx},
                                                     {:ok, rev_items, max_exp, sample_cs} ->
          cs =
            if is_nil(raw_cs.tenant) and fallback_tenant != nil do
              %Ash.Changeset{raw_cs | tenant: fallback_tenant}
            else
              raw_cs
            end

          tenant = cs.tenant
          scoped_col = Codec.scoped_collection(resource, tenant)

          case apply_create_record(resource, cs) do
            {:ok, after_atomics} ->
              next_max_exp =
                if int_pk? do
                  case Map.get(after_atomics, pk_name) do
                    v when is_integer(v) ->
                      Map.update(max_exp, scoped_col, v, &max(&1, v))

                    _ ->
                      max_exp
                  end
                else
                  max_exp
                end

              {:cont,
               {:ok, [{cs, idx, scoped_col, after_atomics} | rev_items], next_max_exp,
                sample_cs || cs}}

            {:error, _} = err ->
              {:halt, err}
          end
        end)

      with {:ok, rev_items, max_explicit_by_col, sample_cs} <- pass1 do
        items = Enum.reverse(rev_items)

        seq_state =
          if int_pk? do
            items
            |> Enum.map(&elem(&1, 2))
            |> Enum.uniq()
            |> Map.new(fn scoped_col ->
              initial = Sequences.read_current(cursor_root, scoped_col)
              seeded = max(initial, Map.get(max_explicit_by_col, scoped_col, 0))
              {scoped_col, %{initial: initial, current: seeded}}
            end)
          else
            %{}
          end

        init_state = %{
          rev_records: [],
          seq_state: seq_state,
          seen_pks: MapSet.new(),
          col_exists: %{},
          col_cursors: %{},
          parent_col_cache: %{},
          verified_parents: MapSet.new(),
          idx_slots: %{},
          unique_seen: %{},
          unique_released: MapSet.new(),
          unique_removals: %{},
          comp_batch: %{},
          blob_ops_rev: [],
          entity_buckets: %{},
          nested_buckets: %{},
          nested_removals: [],
          unique_buckets: %{},
          set_buckets: %{},
          set_removals: %{},
          search_acc: %{}
        }

        staged =
          Enum.reduce_while(items, {:ok, init_state}, fn {cs, idx, scoped_col, after_atomics},
                                                         {:ok, st} ->
            tenant = cs.tenant
            allow_existing? = allow_existing_cursor?(cs)
            skip_search? = skip_search_index?(cs, options)

            with {:ok, record_with_pk, next_seq_state} <-
                   allocate_bulk_pk(
                     after_atomics,
                     scoped_col,
                     pk_name,
                     int_pk?,
                     gen_int_pk?,
                     st.seq_state
                   ),
                 pk_val = Map.get(record_with_pk, pk_name),
                 {:ok, doc_id, next_seen_pks, st_after_pk} <-
                   verify_bulk_pk_unused(
                     cursor_root,
                     resource,
                     nested_spec,
                     scoped_col,
                     pk_name,
                     pk_attr,
                     pk_val,
                     tenant,
                     allow_existing?,
                     %{st | seq_state: next_seq_state}
                   ),
                 record <- finalize_loaded_record(resource, record_with_pk, tenant),
                 :ok <- verify_atomic_validations(record, record, resource, cs),
                 :ok <- verify_create_filter(record, resource, cs),
                 {existing_cur, existing_record, old_parent_doc_id, st_after_existing} <-
                   resolve_bulk_existing(
                     cursor_root,
                     resource,
                     nested_spec,
                     scoped_col,
                     pk_attr,
                     pk_val,
                     doc_id,
                     tenant,
                     allow_existing?,
                     need_existing_record?,
                     st_after_pk
                   ),
                 {:ok, st_after_id} <-
                   accumulate_bulk_identities(
                     cursor_root,
                     resource,
                     identities,
                     existing_record,
                     record,
                     scoped_col,
                     doc_id,
                     tenant,
                     st_after_existing
                   ),
                 {:ok, cursor_map, blob_ops, next_comp_batch} <-
                   build_bulk_cursor_map(
                     cursor_root,
                     resource,
                     attr_plan,
                     record,
                     has_compress?,
                     st_after_id.comp_batch
                   )
                   |> normalize_plan_error(),
                 {:ok, st_after_entity} <-
                   accumulate_bulk_entity(
                     cursor_root,
                     resource,
                     nested_spec,
                     attr_plan,
                     existing_cur,
                     old_parent_doc_id,
                     record,
                     scoped_col,
                     pk_attr,
                     pk_val,
                     doc_id,
                     cursor_map,
                     tenant,
                     %{
                       st_after_id
                       | comp_batch: next_comp_batch,
                         blob_ops_rev: Enum.reverse(blob_ops, st_after_id.blob_ops_rev),
                         seen_pks: next_seen_pks
                     }
                   ) do
              st_after_sec =
                accumulate_bulk_secondary(
                  indexes,
                  scoped_col,
                  doc_id,
                  existing_record,
                  record,
                  st_after_entity
                )

              st_after_search =
                accumulate_bulk_search(
                  cursor_root,
                  scoped_col,
                  doc_id,
                  record,
                  search_fields,
                  skip_search?,
                  allow_existing?,
                  st_after_sec
                )

              tagged = attach_bulk_metadata(record, cs, idx)

              {:cont,
               {:ok, %{st_after_search | rev_records: [tagged | st_after_search.rev_records]}}}
            else
              {:error, _} = err -> {:halt, err}
            end
          end)

        case staged do
          {:ok, final_st} ->
            all_ops = compile_coalesced_bulk_ops(cursor_root, final_st)
            commit_opts = build_commit_opts(resource, :bulk_create, sample_cs, options)

            with {:ok, next_snapshot} <- commit_ops({db, moment}, all_ops, commit_opts) do
              {:ok, next_snapshot, Enum.reverse(final_st.rev_records)}
            end

          {:error, _} = err ->
            err
        end
      end
    end

    defp allocate_bulk_pk(record, scoped_col, pk_name, true, gen_int_pk?, seq_state) do
      current_val = Map.get(record, pk_name)
      %{initial: initial, current: cur} = entry = Map.fetch!(seq_state, scoped_col)

      cond do
        is_nil(current_val) and gen_int_pk? ->
          allocated = cur + 1
          next_seq = Map.put(seq_state, scoped_col, %{entry | current: allocated})
          {:ok, Map.put(record, pk_name, allocated), next_seq}

        is_integer(current_val) and current_val > cur ->
          next_seq = Map.put(seq_state, scoped_col, %{entry | current: current_val})
          {:ok, record, next_seq}

        true ->
          {:ok, record,
           %{initial: initial, current: cur} |> then(&Map.put(seq_state, scoped_col, &1))}
      end
    end

    defp allocate_bulk_pk(record, _scoped_col, _pk_name, false, _gen_int_pk?, seq_state) do
      {:ok, record, seq_state}
    end

    defp verify_bulk_pk_unused(
           _cursor_root,
           _resource,
           _nested_spec,
           _scoped_col,
           pk_name,
           _pk_attr,
           nil,
           _tenant,
           _allow_existing?,
           _st
         ) do
      {:error, InvalidChanges.exception(fields: [pk_name], message: "is required")}
    end

    defp verify_bulk_pk_unused(
           cursor_root,
           resource,
           nested_spec,
           scoped_col,
           pk_name,
           pk_attr,
           pk_val,
           tenant,
           allow_existing?,
           st
         ) do
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)

      if MapSet.member?(st.seen_pks, {scoped_col, doc_id}) do
        {:error, InvalidChanges.exception(fields: [pk_name], message: "has already been taken")}
      else
        next_seen_pks = MapSet.put(st.seen_pks, {scoped_col, doc_id})

        if allow_existing? do
          {:ok, doc_id, next_seen_pks, st}
        else
          {col_exists?, st1} = check_bulk_col_exists(cursor_root, nested_spec, scoped_col, st)

          if not col_exists? do
            {:ok, doc_id, next_seen_pks, st1}
          else
            existing? =
              case nested_spec do
                nil ->
                  col_cur = Map.fetch!(st1.col_cursors, scoped_col)
                  col_cur[doc_id] != nil

                %{cardinality: :many} ->
                  Indexer.fetch_cursor(cursor_root, resource, pk_val, tenant) != :none
              end

            if existing? do
              {:error,
               InvalidChanges.exception(fields: [pk_name], message: "has already been taken")}
            else
              {:ok, doc_id, next_seen_pks, st1}
            end
          end
        end
      end
    end

    defp check_bulk_col_exists(cursor_root, nil, scoped_col, st) do
      case Map.fetch(st.col_exists, scoped_col) do
        {:ok, exists?} ->
          {exists?, st}

        :error ->
          col_cur = cursor_root[scoped_col]
          exists? = match?(%Xitdb.Cursor{}, col_cur)

          {exists?,
           %{
             st
             | col_exists: Map.put(st.col_exists, scoped_col, exists?),
               col_cursors: Map.put(st.col_cursors, scoped_col, col_cur)
           }}
      end
    end

    defp check_bulk_col_exists(cursor_root, %{cardinality: :many}, scoped_col, st) do
      slot_key = {:parent_slot, scoped_col}

      case Map.fetch(st.col_exists, slot_key) do
        {:ok, exists?} ->
          {exists?, st}

        :error ->
          exists? =
            IndexStorage.get_index_slot(cursor_root, scoped_col, Indexer.parent_slot()) != nil

          {exists?, %{st | col_exists: Map.put(st.col_exists, slot_key, exists?)}}
      end
    end

    defp resolve_bulk_existing(
           _cursor_root,
           _resource,
           _nested_spec,
           _scoped_col,
           _pk_attr,
           _pk_val,
           _doc_id,
           _tenant,
           false,
           _need_existing_record?,
           st
         ) do
      {nil, nil, nil, st}
    end

    defp resolve_bulk_existing(
           cursor_root,
           resource,
           nil,
           scoped_col,
           _pk_attr,
           _pk_val,
           doc_id,
           tenant,
           true,
           need_existing_record?,
           st
         ) do
      {col_exists?, st1} = check_bulk_col_exists(cursor_root, nil, scoped_col, st)

      existing_cur =
        if col_exists? do
          col_cur = Map.fetch!(st1.col_cursors, scoped_col)

          case col_cur[doc_id] do
            %Xitdb.Cursor{} = c -> c
            _ -> nil
          end
        else
          nil
        end

      existing_record =
        if existing_cur != nil and need_existing_record? do
          hydrate_existing_record(resource, existing_cur, tenant)
        else
          nil
        end

      {existing_cur, existing_record, nil, st1}
    end

    defp resolve_bulk_existing(
           cursor_root,
           resource,
           %{cardinality: :many} = nested,
           scoped_col,
           pk_attr,
           pk_val,
           doc_id,
           tenant,
           true,
           need_existing_record?,
           st
         ) do
      pk_hex = pk_attr |> Codec.encode_scalar_key(pk_val) |> IndexStorage.encode_btree_key()

      {parent_slot_cur, st1} =
        fetch_cached_idx_slot(cursor_root, scoped_col, Indexer.parent_slot(), st)

      old_parent_doc_id =
        case parent_slot_cur do
          %Xitdb.Cursor{} -> parent_slot_cur[pk_hex]
          _ -> nil
        end

      if is_binary(old_parent_doc_id) do
        parent_col = Indexer.resolve_parent_collection(nested, tenant, resource)
        {parent_col_cur, st2} = fetch_cached_parent_col(cursor_root, parent_col, st1)

        existing_cur =
          with %Xitdb.Cursor{} = pcol <- parent_col_cur,
               %Xitdb.Cursor{} = pcur <- pcol[old_parent_doc_id],
               %Xitdb.Cursor{} = sub <- pcur[nested.path],
               %Xitdb.Cursor{} = c <- sub[doc_id] do
            c
          else
            _ -> nil
          end

        existing_record =
          if existing_cur != nil and need_existing_record? do
            hydrate_existing_record(resource, existing_cur, tenant)
          else
            nil
          end

        {existing_cur, existing_record, old_parent_doc_id, st2}
      else
        {nil, nil, nil, st1}
      end
    end

    defp hydrate_existing_record(resource, existing_cur, tenant) do
      case Codec.from_cursor(resource, existing_cur, tenant) do
        {:ok, rec} -> rec
        _ -> nil
      end
    end

    defp accumulate_bulk_identities(
           _cursor_root,
           _resource,
           [],
           _existing_record,
           _record,
           _scoped_col,
           _doc_id,
           _tenant,
           st
         ),
         do: {:ok, st}

    defp accumulate_bulk_identities(
           cursor_root,
           resource,
           identities,
           existing_record,
           record,
           scoped_col,
           doc_id,
           tenant,
           st
         ) do
      Enum.reduce_while(identities, {:ok, st}, fn identity, {:ok, acc_st} ->
        old_key = Indexer.active_identity_key(resource, identity, existing_record, tenant)
        new_key = Indexer.active_identity_key(resource, identity, record, tenant)

        if is_nil(old_key) and is_nil(new_key) do
          {:cont, {:ok, acc_st}}
        else
          id_col = Indexer.identity_collection(resource, identity, tenant)
          slot = Indexer.identity_slot_name(identity.name)
          owner_id = Indexer.encode_identity_owner(resource, identity, scoped_col, doc_id)
          {slot_cur, acc_st1} = fetch_cached_idx_slot(cursor_root, id_col, slot, acc_st)

          acc_st2 =
            if old_key != nil and old_key != new_key do
              old_hex = IndexStorage.encode_btree_key(old_key)

              if match?(%Xitdb.Cursor{}, slot_cur) and slot_cur[old_hex] == owner_id do
                old_seen_key = {id_col, identity.name, old_key}
                bucket_key = {id_col, slot}

                next_removals =
                  Map.update(
                    acc_st1.unique_removals,
                    bucket_key,
                    MapSet.new([old_hex]),
                    &MapSet.put(&1, old_hex)
                  )

                %{
                  acc_st1
                  | unique_released: MapSet.put(acc_st1.unique_released, old_seen_key),
                    unique_removals: next_removals
                }
              else
                acc_st1
              end
            else
              acc_st1
            end

          if is_nil(new_key) do
            {:cont, {:ok, acc_st2}}
          else
            seen_key = {id_col, identity.name, new_key}
            err_fields = Map.get(identity, :field_names) || identity.keys
            err_msg = Map.get(identity, :message) || "has already been taken"

            case Map.fetch(acc_st2.unique_seen, seen_key) do
              {:ok, _other_owner} ->
                {:halt, {:error, InvalidChanges.exception(fields: err_fields, message: err_msg)}}

              :error ->
                hex_key = IndexStorage.encode_btree_key(new_key)

                db_collision? =
                  case slot_cur do
                    %Xitdb.Cursor{} ->
                      case slot_cur[hex_key] do
                        nil -> false
                        ^owner_id -> false
                        _other -> not MapSet.member?(acc_st2.unique_released, seen_key)
                      end

                    nil ->
                      false
                  end

                if db_collision? do
                  {:halt,
                   {:error, InvalidChanges.exception(fields: err_fields, message: err_msg)}}
                else
                  bucket_key = {id_col, slot}
                  entry = {hex_key, owner_id}

                  next_buckets =
                    Map.update(acc_st2.unique_buckets, bucket_key, [entry], &[entry | &1])

                  {:cont,
                   {:ok,
                    %{
                      acc_st2
                      | unique_seen: Map.put(acc_st2.unique_seen, seen_key, owner_id),
                        unique_buckets: next_buckets
                    }}}
                end
            end
          end
        end
      end)
    end

    defp fetch_cached_idx_slot(cursor_root, id_col, slot, st) do
      key = {id_col, slot}

      case Map.fetch(st.idx_slots, key) do
        {:ok, cached} ->
          {cached, st}

        :error ->
          slot_cur =
            case IndexStorage.get_index_slot(cursor_root, id_col, slot) do
              %Xitdb.Cursor{} = c -> c
              _ -> nil
            end

          {slot_cur, %{st | idx_slots: Map.put(st.idx_slots, key, slot_cur)}}
      end
    end

    defp build_bulk_cursor_map(
           cursor_root,
           resource,
           attr_plan,
           record,
           has_compress?,
           comp_batch
         ) do
      with {:ok, raw_map} <- Codec.to_cursor_map_fast(attr_plan, record) do
        encoded_map = Xitdb.TxCompiler.encode_value(raw_map)

        if has_compress? do
          Indexer.compress_cursor_map(cursor_root, resource, encoded_map, comp_batch, :all)
        else
          {:ok, encoded_map, [], comp_batch}
        end
      end
    end

    defp compute_removed_fields(_attr_plan, existing_cur, _cursor_map)
         when not is_struct(existing_cur, Xitdb.Cursor),
         do: []

    defp compute_removed_fields(attr_plan, %Xitdb.Cursor{} = existing_cur, cursor_map) do
      Enum.reduce(attr_plan, [], fn {_attr, _name, key, _cs?, _fk}, acc ->
        if not Map.has_key?(cursor_map, key) and not is_nil(existing_cur[key]) do
          [key | acc]
        else
          acc
        end
      end)
    end

    defp accumulate_bulk_entity(
           _cursor_root,
           _resource,
           nil,
           attr_plan,
           existing_cur,
           _old_parent_doc_id,
           _record,
           scoped_col,
           _pk_attr,
           _pk_val,
           doc_id,
           cursor_map,
           _tenant,
           st
         ) do
      removed_fields = compute_removed_fields(attr_plan, existing_cur, cursor_map)
      entry = {doc_id, cursor_map, removed_fields}
      next_buckets = Map.update(st.entity_buckets, scoped_col, [entry], &[entry | &1])
      {:ok, %{st | entity_buckets: next_buckets}}
    end

    defp accumulate_bulk_entity(
           cursor_root,
           resource,
           %{cardinality: :many} = nested,
           attr_plan,
           existing_cur,
           old_parent_doc_id,
           record,
           scoped_col,
           pk_attr,
           pk_val,
           doc_id,
           cursor_map,
           tenant,
           st
         ) do
      fk_attr = nested.foreign_key
      parent_val = Map.get(record, fk_attr)

      if is_nil(parent_val) do
        {:error,
         InvalidChanges.exception(
           fields: [fk_attr],
           message: "is required for nested Xitdb resource"
         )}
      else
        parent_col = Indexer.resolve_parent_collection(nested, tenant, resource)
        parent_doc_id = Indexer.encode_parent_doc_id(resource, nested, parent_val)

        with {:ok, st1} <-
               verify_bulk_parent_exists(cursor_root, parent_col, parent_doc_id, fk_attr, st) do
          reparented? = is_binary(old_parent_doc_id) and old_parent_doc_id != parent_doc_id

          next_nested_removals =
            if reparented? and existing_cur != nil do
              [{parent_col, old_parent_doc_id, nested.path, doc_id} | st1.nested_removals]
            else
              st1.nested_removals
            end

          removed_fields =
            if reparented? do
              []
            else
              compute_removed_fields(attr_plan, existing_cur, cursor_map)
            end

          nested_entry = {parent_doc_id, nested.path, doc_id, cursor_map, removed_fields}

          next_nested =
            Map.update(st1.nested_buckets, parent_col, [nested_entry], &[nested_entry | &1])

          pk_hex = pk_attr |> Codec.encode_scalar_key(pk_val) |> IndexStorage.encode_btree_key()
          parent_idx_key = {scoped_col, Indexer.parent_slot()}
          parent_idx_entry = {pk_hex, parent_doc_id}

          next_unique =
            Map.update(
              st1.unique_buckets,
              parent_idx_key,
              [parent_idx_entry],
              &[parent_idx_entry | &1]
            )

          {:ok,
           %{
             st1
             | nested_buckets: next_nested,
               nested_removals: next_nested_removals,
               unique_buckets: next_unique
           }}
        end
      end
    end

    defp fetch_cached_parent_col(cursor_root, parent_col, st) do
      case Map.fetch(st.parent_col_cache, parent_col) do
        {:ok, cur} ->
          {cur, st}

        :error ->
          cur = cursor_root[parent_col]
          {cur, %{st | parent_col_cache: Map.put(st.parent_col_cache, parent_col, cur)}}
      end
    end

    defp verify_bulk_parent_exists(cursor_root, parent_col, parent_doc_id, fk_attr, st) do
      key = {parent_col, parent_doc_id}

      if MapSet.member?(st.verified_parents, key) do
        {:ok, st}
      else
        {parent_col_cur, st1} = fetch_cached_parent_col(cursor_root, parent_col, st)

        exists? = match?(%Xitdb.Cursor{}, parent_col_cur) and parent_col_cur[parent_doc_id] != nil

        if exists? do
          {:ok, %{st1 | verified_parents: MapSet.put(st1.verified_parents, key)}}
        else
          {:error, InvalidChanges.exception(fields: [fk_attr], message: "does not exist")}
        end
      end
    end

    defp accumulate_bulk_secondary([], _scoped_col, _doc_id, _existing_record, _record, st),
      do: st

    defp accumulate_bulk_secondary(indexes, scoped_col, doc_id, existing_record, record, st) do
      {next_sets, next_removals} =
        Enum.reduce(indexes, {st.set_buckets, st.set_removals}, fn %{
                                                                     slot: slot,
                                                                     fields: fields,
                                                                     attrs: attrs
                                                                   },
                                                                   {add_acc, rm_acc} ->
          old_raw = Indexer.encode_record_index_key(attrs, fields, existing_record)
          new_raw = Indexer.encode_record_index_key(attrs, fields, record)

          if old_raw == new_raw do
            {add_acc, rm_acc}
          else
            bucket_key = {scoped_col, slot}

            next_rm_acc =
              if old_raw != nil do
                old_hex = IndexStorage.encode_btree_key(old_raw)
                inner_rm = Map.get(rm_acc, bucket_key, %{})
                next_inner_rm = Map.update(inner_rm, old_hex, [doc_id], &[doc_id | &1])
                Map.put(rm_acc, bucket_key, next_inner_rm)
              else
                rm_acc
              end

            next_add_acc =
              if new_raw != nil do
                new_hex = IndexStorage.encode_btree_key(new_raw)
                inner_add = Map.get(add_acc, bucket_key, %{})
                next_inner_add = Map.update(inner_add, new_hex, [doc_id], &[doc_id | &1])
                Map.put(add_acc, bucket_key, next_inner_add)
              else
                add_acc
              end

            {next_add_acc, next_rm_acc}
          end
        end)

      %{st | set_buckets: next_sets, set_removals: next_removals}
    end

    defp accumulate_bulk_search(
           _cursor_root,
           _scoped_col,
           _doc_id,
           _record,
           [],
           _skip_search?,
           _allow_existing?,
           st
         ),
         do: st

    defp accumulate_bulk_search(
           _cursor_root,
           _scoped_col,
           _doc_id,
           _record,
           _search_fields,
           true,
           _allow_existing?,
           st
         ),
         do: st

    defp accumulate_bulk_search(
           cursor_root,
           scoped_col,
           doc_id,
           record,
           search_fields,
           false,
           allow_existing?,
           st
         ) do
      new_terms = Search.extract_weighted_terms_for_record(record, search_fields, cursor_root)
      new_len = Enum.reduce(new_terms, 0, fn {_t, w}, sum -> sum + w end)

      col_state =
        Map.get_lazy(st.search_acc, scoped_col, fn ->
          stats = Search.Storage.read_corpus_stats(cursor_root, scoped_col)
          docs_cur = get_search_docs_cursor(cursor_root, scoped_col)

          %{
            doc_count: stats.doc_count,
            total_len: stats.total_len,
            docs_cur: docs_cur,
            changed?: false,
            doc_entries: [],
            deleted_docs: [],
            term_postings: %{},
            deleted_terms: []
          }
        end)

      old_doc =
        if col_state.docs_cur != nil and allow_existing? do
          Search.Storage.read_doc(cursor_root, scoped_col, doc_id)
        else
          %{len: 0, terms: %{}}
        end

      if old_doc.terms == new_terms do
        %{st | search_acc: Map.put(st.search_acc, scoped_col, col_state)}
      else
        was_indexed? = old_doc.len > 0
        now_indexed? = new_len > 0

        doc_count_delta =
          cond do
            not was_indexed? and now_indexed? -> 1
            was_indexed? and not now_indexed? -> -1
            true -> 0
          end

        next_doc_entries =
          if now_indexed? do
            [{doc_id, %{"len" => new_len, "terms" => new_terms}, []} | col_state.doc_entries]
          else
            col_state.doc_entries
          end

        next_deleted_docs =
          if not now_indexed? and was_indexed? do
            [doc_id | col_state.deleted_docs]
          else
            col_state.deleted_docs
          end

        next_postings =
          Enum.reduce(new_terms, col_state.term_postings, fn {term, new_w}, acc ->
            if Map.get(old_doc.terms, term) == new_w do
              acc
            else
              Map.update(acc, term, [{doc_id, new_w}], &[{doc_id, new_w} | &1])
            end
          end)

        next_deleted_terms =
          if was_indexed? do
            Enum.reduce(old_doc.terms, col_state.deleted_terms, fn {old_term, _old_w}, acc ->
              if Map.has_key?(new_terms, old_term) do
                acc
              else
                [{old_term, doc_id} | acc]
              end
            end)
          else
            col_state.deleted_terms
          end

        updated_col = %{
          col_state
          | doc_count: max(0, col_state.doc_count + doc_count_delta),
            total_len: max(0, col_state.total_len + (new_len - old_doc.len)),
            changed?: true,
            doc_entries: next_doc_entries,
            deleted_docs: next_deleted_docs,
            term_postings: next_postings,
            deleted_terms: next_deleted_terms
        }

        %{st | search_acc: Map.put(st.search_acc, scoped_col, updated_col)}
      end
    end

    defp get_search_docs_cursor(cursor_root, scoped_col) do
      with %Xitdb.Cursor{} = idx <- cursor_root["idx"],
           %Xitdb.Cursor{} = search <- idx["search"],
           %Xitdb.Cursor{} = col <- search[scoped_col],
           %Xitdb.Cursor{} = docs <- col["docs"] do
        docs
      else
        _ -> nil
      end
    end

    defp compile_coalesced_bulk_ops(cursor_root, st) do
      {seq_ops, _cached_meta?} =
        Enum.reduce(st.seq_state, {[], false}, fn
          {scoped_col, %{initial: initial, current: current}}, {ops_acc, cached?}
          when current > initial ->
            ops = Sequences.compile_sequence_ops(cursor_root, scoped_col, current, cached?)
            {ops_acc ++ ops, true}

          _, acc ->
            acc
        end)

      blob_ops = Enum.reverse(st.blob_ops_rev)

      entity_ops =
        Enum.map(st.entity_buckets, fn {scoped_col, entries} ->
          {:bulk_put_maps, [scoped_col], Enum.reverse(entries)}
        end)

      nested_rm_ops =
        st.nested_removals
        |> Enum.reverse()
        |> Enum.map(fn {parent_col, old_parent_doc_id, path, doc_id} ->
          {:rm, [parent_col, old_parent_doc_id, path, doc_id]}
        end)

      nested_ops =
        Enum.map(st.nested_buckets, fn {parent_col, entries} ->
          sorted = Enum.sort_by(entries, &{elem(&1, 0), elem(&1, 1), elem(&1, 2)})
          {:bulk_put_nested_maps, [parent_col], sorted}
        end)

      unique_rm_ops =
        Enum.flat_map(st.unique_removals, fn {{id_col, slot} = bucket_key, hex_set} ->
          written_hexes =
            st.unique_buckets
            |> Map.get(bucket_key, [])
            |> MapSet.new(&elem(&1, 0))

          hex_set
          |> Enum.reject(&MapSet.member?(written_hexes, &1))
          |> Enum.sort()
          |> Enum.map(fn hex_key ->
            {:rm, ["idx", id_col, slot, {:sorted_map, hex_key}]}
          end)
        end)

      unique_ops =
        Enum.map(st.unique_buckets, fn {{id_col, slot}, entries} ->
          {:bulk_index_puts, ["idx", id_col, slot], :unique, :lists.keysort(1, entries)}
        end)

      set_rm_ops =
        Enum.flat_map(st.set_removals, fn {{scoped_col, slot} = bucket_key, by_hex} ->
          case IndexStorage.get_index_slot(cursor_root, scoped_col, slot) do
            %Xitdb.Cursor{} = slot_cur ->
              added_by_hex = Map.get(st.set_buckets, bucket_key, %{})

              by_hex
              |> Enum.sort_by(&elem(&1, 0))
              |> Enum.flat_map(fn {old_hex, doc_ids} ->
                case slot_cur[old_hex] do
                  nil ->
                    []

                  set_cur ->
                    present_ids =
                      doc_ids
                      |> Enum.uniq()
                      |> Enum.filter(&IndexStorage.set_container_member?(set_cur, &1))

                    if present_ids == [] do
                      []
                    else
                      has_remaining? =
                        Map.has_key?(added_by_hex, old_hex) or
                          IndexStorage.set_has_member_outside?(set_cur, MapSet.new(present_ids))

                      if has_remaining? do
                        Enum.map(present_ids, fn doc_id ->
                          {:rm,
                           [
                             "idx",
                             scoped_col,
                             slot,
                             {:sorted_map, old_hex},
                             {:counted_hash_set, doc_id}
                           ]}
                        end)
                      else
                        [{:rm, ["idx", scoped_col, slot, {:sorted_map, old_hex}]}]
                      end
                    end
                end
              end)

            _ ->
              []
          end
        end)

      set_ops =
        Enum.map(st.set_buckets, fn {{scoped_col, slot}, by_hex} ->
          entries = :lists.keysort(1, :maps.to_list(by_hex))
          {:bulk_index_puts, ["idx", scoped_col, slot], :counted_set_add, entries}
        end)

      search_ops =
        Enum.flat_map(st.search_acc, fn
          {_col, %{changed?: false}} ->
            []

          {col, col_st} ->
            meta_op =
              {:put, ["idx", "search", col, "meta"],
               %{"doc_count" => col_st.doc_count, "total_len" => col_st.total_len}}

            rm_doc_ops =
              Enum.map(col_st.deleted_docs, fn doc_id ->
                {:rm, ["idx", "search", col, "docs", doc_id]}
              end)

            doc_put_ops =
              if col_st.doc_entries == [] do
                []
              else
                [
                  {:bulk_put_maps, ["idx", "search", col, "docs"],
                   Enum.reverse(col_st.doc_entries)}
                ]
              end

            term_put_ops =
              if map_size(col_st.term_postings) == 0 do
                []
              else
                sorted_terms = :lists.keysort(1, :maps.to_list(col_st.term_postings))

                [
                  {:bulk_index_puts, ["idx", "search", col, "terms"], :hash_map_merge,
                   sorted_terms}
                ]
              end

            term_rm_ops =
              col_st.deleted_terms
              |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
              |> Enum.flat_map(fn {term, doc_ids} ->
                removed_set = MapSet.new(doc_ids)

                has_remaining? =
                  Map.has_key?(col_st.term_postings, term) or
                    Search.Storage.term_has_doc_outside?(cursor_root, col, term, removed_set)

                if has_remaining? do
                  Enum.map(removed_set, fn doc_id ->
                    {:rm, ["idx", "search", col, "terms", {:sorted_map, term}, doc_id]}
                  end)
                else
                  [{:rm, ["idx", "search", col, "terms", {:sorted_map, term}]}]
                end
              end)

            [meta_op | rm_doc_ops] ++ doc_put_ops ++ term_put_ops ++ term_rm_ops
        end)

      seq_ops ++
        blob_ops ++
        entity_ops ++
        nested_rm_ops ++
        nested_ops ++ unique_rm_ops ++ unique_ops ++ set_rm_ops ++ set_ops ++ search_ops
    end

    defp run_bulk_creates_legacy({db, moment}, resource, stream, fallback_tenant, options) do
      cursor_root = Xitdb.as_of(db, moment)

      staged =
        stream
        |> Enum.with_index()
        |> Enum.reduce_while(
          {:ok, [], [], %{}, %{}, MapSet.new(), MapSet.new(), nil},
          fn {%Ash.Changeset{} = raw_cs, idx},
             {:ok, rev_records, ops_chunks, seq_state, idx_batch_state, seen_pks, seen_identities,
              sample_cs} ->
            cs =
              if is_nil(raw_cs.tenant) and fallback_tenant != nil do
                %Ash.Changeset{raw_cs | tenant: fallback_tenant}
              else
                raw_cs
              end

            tenant = cs.tenant
            scoped_col = Codec.scoped_collection(resource, tenant)

            with {:ok, after_atomics} <- apply_create_record(resource, cs),
                 {:ok, record_with_pk, seq_ops, next_seq_state} <-
                   Sequences.plan_pk(cursor_root, resource, after_atomics, tenant, seq_state),
                 :ok <-
                   verify_pk_unused(
                     cursor_root,
                     resource,
                     record_with_pk,
                     tenant,
                     seen_pks,
                     allow_existing_cursor?(cs)
                   ),
                 record <- finalize_loaded_record(resource, record_with_pk, tenant),
                 :ok <- verify_atomic_validations(record, record, resource, cs),
                 :ok <- verify_create_filter(record, resource, cs),
                 {:ok, next_seen_identities} <-
                   track_batch_identities(resource, record, tenant, seen_identities),
                 {:ok, index_ops, next_idx_batch_state} <-
                   Indexer.plan_put_ops_batched(
                     cursor_root,
                     resource,
                     nil,
                     record,
                     tenant,
                     idx_batch_state,
                     skip_search_index?: skip_search_index?(cs, options)
                   )
                   |> normalize_plan_error() do
              [pk_name | _] = Ash.Resource.Info.primary_key(resource)
              pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
              doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(record, pk_name))
              next_seen_pks = MapSet.put(seen_pks, {scoped_col, doc_id})
              tagged = attach_bulk_metadata(record, cs, idx)

              {:cont,
               {:ok, [tagged | rev_records], [seq_ops ++ index_ops | ops_chunks], next_seq_state,
                next_idx_batch_state, next_seen_pks, next_seen_identities, sample_cs || cs}}
            else
              {:error, _} = err ->
                {:halt, err}
            end
          end
        )

      case staged do
        {:ok, rev_records, ops_chunks, _seq_state, _idx_batch_state, _seen_pks, _seen_identities,
         sample_cs} ->
          all_ops = ops_chunks |> Enum.reverse() |> List.flatten()
          commit_opts = build_commit_opts(resource, :bulk_create, sample_cs, options)

          with {:ok, next_snapshot} <- commit_ops({db, moment}, all_ops, commit_opts) do
            {:ok, next_snapshot, Enum.reverse(rev_records)}
          end

        {:error, _} = err ->
          err
      end
    end

    defp skip_search_index?(cs, options) do
      cs_ctx =
        case cs do
          %Ash.Changeset{context: ctx} when is_map(ctx) -> ctx
          _ -> %{}
        end

      opts_map =
        cond do
          is_map(options) -> options
          is_list(options) -> Map.new(options)
          true -> %{}
        end

      override = extract_xitdb_override(cs_ctx, opts_map)
      fetch_map_opt(override, :skip_search_index?) == true
    end

    defp run_bulk_creates_columnar(
           {db, moment},
           resource,
           stream,
           fallback_tenant,
           row_group_configs,
           options
         ) do
      cursor_root = Xitdb.as_of(db, moment)
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_attr = Ash.Resource.Info.attribute(resource, pk_name)

      staged =
        stream
        |> Enum.with_index()
        |> Enum.reduce_while(
          {:ok, [], [], %{}, %{}, MapSet.new(), MapSet.new()},
          fn {%Ash.Changeset{} = raw_cs, idx},
             {:ok, rev_items, blob_ops_rev, seq_state, comp_batch_state, seen_pks,
              seen_identities} ->
            cs =
              if is_nil(raw_cs.tenant) and fallback_tenant != nil do
                %Ash.Changeset{raw_cs | tenant: fallback_tenant}
              else
                raw_cs
              end

            tenant = cs.tenant
            scoped_col = Codec.scoped_collection(resource, tenant)

            with {:ok, after_atomics} <- apply_create_record(resource, cs),
                 {:ok, record_with_pk, seq_ops, next_seq_state} <-
                   Sequences.plan_pk(cursor_root, resource, after_atomics, tenant, seq_state),
                 :ok <-
                   verify_pk_unused(
                     cursor_root,
                     resource,
                     record_with_pk,
                     tenant,
                     seen_pks,
                     allow_existing_cursor?(cs)
                   ),
                 record <- finalize_loaded_record(resource, record_with_pk, tenant),
                 :ok <- verify_atomic_validations(record, record, resource, cs),
                 :ok <- verify_create_filter(record, resource, cs),
                 {:ok, next_seen_identities} <-
                   track_batch_identities(resource, record, tenant, seen_identities),
                 {:ok, raw_cursor_map} <-
                   resource |> Codec.to_cursor_map(record) |> normalize_plan_error(),
                 {:ok, val_cursor_map, item_blob_ops, next_comp_batch} <-
                   Indexer.compress_cursor_map(
                     cursor_root,
                     resource,
                     raw_cursor_map,
                     comp_batch_state,
                     :value
                   ) do
              doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(record, pk_name))
              next_seen_pks = MapSet.put(seen_pks, {scoped_col, doc_id})

              item = %{
                idx: idx,
                cs: cs,
                tenant: tenant,
                scoped_col: scoped_col,
                doc_id: doc_id,
                seq_ops: seq_ops,
                record: record,
                cursor_map: val_cursor_map
              }

              {:cont,
               {:ok, [item | rev_items], Enum.reverse(item_blob_ops, blob_ops_rev),
                next_seq_state, next_comp_batch, next_seen_pks, next_seen_identities}}
            else
              {:error, _} = err ->
                {:halt, err}
            end
          end
        )

      with {:ok, rev_items, blob_ops_rev, _seq_state, _comp_batch, _seen_pks, _seen_identities} <-
             staged,
           staged_items = Enum.reverse(rev_items),
           {:ok, page_ops, updated_cursors_by_key} <-
             encode_bulk_row_groups(staged_items, row_group_configs, db.db_ref, moment),
           {:ok, indexed_ops_chunks, rev_records} <-
             plan_bulk_columnar_items(
               cursor_root,
               resource,
               staged_items,
               updated_cursors_by_key,
               options
             ) do
        all_ops =
          page_ops ++
            Enum.reverse(blob_ops_rev) ++ (indexed_ops_chunks |> Enum.reverse() |> List.flatten())

        sample_cs =
          case staged_items do
            [first | _] -> first.cs
            [] -> nil
          end

        commit_opts = build_commit_opts(resource, :bulk_create, sample_cs, options)

        with {:ok, next_snapshot} <- commit_ops({db, moment}, all_ops, commit_opts) do
          {:ok, next_snapshot, Enum.reverse(rev_records)}
        end
      end
    end

    defp encode_bulk_row_groups(staged_items, row_group_configs, db_ref, moment) do
      grouped = Enum.group_by(staged_items, & &1.scoped_col, &{&1.doc_id, &1.cursor_map})

      Enum.reduce_while(grouped, {:ok, [], %{}}, fn {scoped_col, pairs},
                                                    {:ok, ops_rev, map_acc} ->
        col_res =
          Enum.reduce_while(row_group_configs, {:ok, ops_rev, pairs}, fn %Compress{} = rg_cfg,
                                                                         {:ok, p_ops_rev,
                                                                          cur_pairs} ->
            col_specs =
              Enum.map(rg_cfg.fields, fn field ->
                {field,
                 [
                   encoding: rg_cfg.encoding,
                   codec: rg_cfg.codec,
                   level: rg_cfg.level,
                   dictionary: rg_cfg.dictionary
                 ]}
              end)

            case Columnar.build_columnar_ops_for_groups(scoped_col, cur_pairs, col_specs,
                   row_group_size: rg_cfg.row_group_size,
                   db_ref: db_ref,
                   moment: moment
                 ) do
              {:ok, cfg_page_ops, next_pairs} ->
                {:cont, {:ok, Enum.reverse(cfg_page_ops, p_ops_rev), next_pairs}}

              {:error, _} = err ->
                {:halt, err}
            end
          end)

        case col_res do
          {:ok, next_ops_rev, updated_pairs} ->
            next_map =
              Enum.reduce(updated_pairs, map_acc, fn {doc_id, updated_cursor_map}, acc ->
                Map.put(acc, {scoped_col, doc_id}, updated_cursor_map)
              end)

            {:cont, {:ok, next_ops_rev, next_map}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, ops_rev, map_acc} -> {:ok, Enum.reverse(ops_rev), map_acc}
        {:error, _} = err -> err
      end
    end

    defp plan_bulk_columnar_items(
           cursor_root,
           resource,
           staged_items,
           updated_cursors_by_key,
           options
         ) do
      Enum.reduce_while(staged_items, {:ok, [], [], %{}}, fn item,
                                                             {:ok, ops_chunks, rev_records,
                                                              idx_batch_state} ->
        updated_cursor_map = Map.fetch!(updated_cursors_by_key, {item.scoped_col, item.doc_id})

        case Indexer.plan_put_ops_batched(
               cursor_root,
               resource,
               nil,
               item.record,
               item.tenant,
               idx_batch_state,
               prebuilt_cursor_map: updated_cursor_map,
               skip_search_index?: skip_search_index?(item.cs, options)
             )
             |> normalize_plan_error() do
          {:ok, index_ops, next_idx_batch_state} ->
            tagged = attach_bulk_metadata(item.record, item.cs, item.idx)

            {:cont,
             {:ok, [item.seq_ops ++ index_ops | ops_chunks], [tagged | rev_records],
              next_idx_batch_state}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, ops_chunks, rev_records, _idx_batch_state} -> {:ok, ops_chunks, rev_records}
        {:error, _} = err -> err
      end
    end

    defp run_bulk_upserts(
           {db, moment} = initial_snapshot,
           resource,
           stream,
           upsert_keys,
           identity,
           fallback_tenant,
           opts
         ) do
      cursor_root = Xitdb.as_of(db, moment)
      pk_fields = Ash.Resource.Info.primary_key(resource)
      pk_attr = Ash.Resource.Info.attribute(resource, hd(pk_fields))

      staged =
        stream
        |> Enum.with_index()
        |> Enum.reduce_while(
          {:ok, [], [], %{}, %{}, MapSet.new(), %{}, nil},
          fn {%Ash.Changeset{} = raw_cs, idx},
             {:ok, rev_records, ops_chunks, seq_state, idx_batch_state, seen_pks, staged_records,
              sample_cs} ->
            cs =
              if is_nil(raw_cs.tenant) and fallback_tenant != nil do
                %Ash.Changeset{raw_cs | tenant: fallback_tenant}
              else
                raw_cs
              end

            tenant = cs.tenant
            scoped_col = Codec.scoped_collection(resource, tenant)

            case stage_single_upsert(
                   cursor_root,
                   resource,
                   pk_attr,
                   scoped_col,
                   cs,
                   upsert_keys,
                   identity,
                   opts,
                   seq_state,
                   idx_batch_state,
                   seen_pks,
                   staged_records
                 ) do
              {:ok, :skipped, next_seq, next_idx_batch, next_seen_pks, next_staged} ->
                {:cont,
                 {:ok, rev_records, ops_chunks, next_seq, next_idx_batch, next_seen_pks,
                  next_staged, sample_cs || cs}}

              {:ok, record, item_ops, next_seq, next_idx_batch, next_seen_pks, next_staged} ->
                tagged = attach_bulk_metadata(record, cs, idx)

                {:cont,
                 {:ok, [tagged | rev_records], [item_ops | ops_chunks], next_seq, next_idx_batch,
                  next_seen_pks, next_staged, sample_cs || cs}}

              {:error, _} = err ->
                {:halt, err}
            end
          end
        )

      case staged do
        {:ok, rev_records, ops_chunks, _seq_state, _idx_batch_state, _seen_pks, _staged_records,
         sample_cs} ->
          all_ops = ops_chunks |> Enum.reverse() |> List.flatten()
          commit_opts = build_commit_opts(resource, :bulk_upsert, sample_cs, opts)

          with {:ok, final_snap} <- commit_ops(initial_snapshot, all_ops, commit_opts) do
            {:ok, final_snap, Enum.reverse(rev_records)}
          end

        {:error, _} = err ->
          err
      end
    end

    defp stage_single_upsert(
           cursor_root,
           resource,
           pk_attr,
           scoped_col,
           %Ash.Changeset{} = cs,
           upsert_keys,
           identity,
           bulk_opts,
           seq_state,
           idx_batch_state,
           seen_pks,
           staged_records
         ) do
      tenant = cs.tenant

      with {:ok, candidate_record} <- apply_create_record(resource, cs) do
        case find_upsert_target_staged(
               cursor_root,
               staged_records,
               resource,
               candidate_record,
               upsert_keys,
               identity,
               tenant
             ) do
          :none ->
            with {:ok, after_pk, seq_ops, next_seq_state} <-
                   Sequences.plan_pk(cursor_root, resource, candidate_record, tenant, seq_state),
                 :ok <- verify_pk_unused(cursor_root, resource, after_pk, tenant, seen_pks),
                 record <-
                   resource
                   |> finalize_loaded_record(after_pk, tenant)
                   |> Ash.Resource.put_metadata(:upsert_action, :create),
                 :ok <- verify_atomic_validations(record, record, resource, cs),
                 :ok <- verify_create_filter(record, resource, cs),
                 {:ok, index_ops, next_idx_batch} <-
                   Indexer.plan_put_ops_batched(
                     cursor_root,
                     resource,
                     nil,
                     record,
                     tenant,
                     idx_batch_state
                   )
                   |> normalize_plan_error() do
              doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(record, pk_attr.name))
              doc_key = {scoped_col, doc_id}

              {:ok, record, seq_ops ++ index_ops, next_seq_state, next_idx_batch,
               MapSet.put(seen_pks, doc_key), Map.put(staged_records, doc_key, record)}
            end

          {:ok, existing_record} ->
            allowed_fields =
              resolve_upsert_allowed_fields(resource, cs, upsert_keys, bulk_opts)

            case build_updated_record(
                   existing_record,
                   resource,
                   cs,
                   {:upsert, allowed_fields, candidate_record}
                 ) do
              {:ok, updated_record} ->
                final_record =
                  resource
                  |> finalize_loaded_record(updated_record, tenant)
                  |> Ash.Resource.put_metadata(:upsert_action, :update)

                with {:ok, index_ops, next_idx_batch} <-
                       Indexer.plan_put_ops_batched(
                         cursor_root,
                         resource,
                         existing_record,
                         final_record,
                         tenant,
                         idx_batch_state
                       )
                       |> normalize_plan_error() do
                  doc_id =
                    Codec.encode_pk_doc_id(pk_attr, Map.fetch!(final_record, pk_attr.name))

                  doc_key = {scoped_col, doc_id}

                  {:ok, final_record, index_ops, seq_state, next_idx_batch,
                   MapSet.put(seen_pks, doc_key), Map.put(staged_records, doc_key, final_record)}
                end

              :filtered_out ->
                {:ok, :skipped, seq_state, idx_batch_state, seen_pks, staged_records}

              {:error, _} = err ->
                err
            end
        end
      end
    end

    defp find_upsert_target_staged(
           cursor_root,
           staged_records,
           resource,
           candidate_record,
           keys,
           identity,
           tenant
         )
         when map_size(staged_records) == 0 do
      find_upsert_target(cursor_root, resource, candidate_record, keys, identity, tenant)
    end

    defp find_upsert_target_staged(
           cursor_root,
           staged_records,
           resource,
           candidate_record,
           keys,
           identity,
           tenant
         ) do
      pk_fields = Ash.Resource.Info.primary_key(resource)
      pk_attr = Ash.Resource.Info.attribute(resource, hd(pk_fields))
      scoped_col = Codec.scoped_collection(resource, tenant)

      resolved_identity =
        cond do
          match?(%Ash.Resource.Identity{}, identity) ->
            identity

          is_atom(identity) and not is_nil(identity) ->
            Ash.Resource.Info.identity(resource, identity)

          Enum.sort(keys) == Enum.sort(pk_fields) ->
            :primary_key

          true ->
            resource
            |> Ash.Resource.Info.identities()
            |> Enum.find(fn id -> Enum.sort(id.keys) == Enum.sort(keys) end)
        end

      case resolved_identity do
        :primary_key ->
          case Map.get(candidate_record, pk_attr.name) do
            nil ->
              :none

            pk_val ->
              doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)

              case Map.fetch(staged_records, {scoped_col, doc_id}) do
                {:ok, staged_rec} -> {:ok, staged_rec}
                :error -> load_existing_record(cursor_root, resource, pk_val, tenant)
              end
          end

        %Ash.Resource.Identity{} = id_struct ->
          case encoded_active_identity_key(resource, id_struct, candidate_record, tenant) do
            {:ok, target_key} ->
              staged_match =
                find_staged_by_identity(
                  staged_records,
                  resource,
                  id_struct,
                  scoped_col,
                  target_key
                )

              case staged_match do
                {:ok, _} = hit ->
                  hit

                :none ->
                  case lookup_existing_by_identity(
                         cursor_root,
                         resource,
                         id_struct,
                         candidate_record,
                         tenant
                       ) do
                    {:ok, db_rec} ->
                      guard_stale_db_target(
                        db_rec,
                        staged_records,
                        resource,
                        pk_attr,
                        tenant,
                        scoped_col
                      )

                    :none ->
                      :none
                  end
              end

            :skip ->
              :none
          end

        nil ->
          if Enum.any?(keys, &is_nil(Map.get(candidate_record, &1))) do
            :none
          else
            case find_staged_by_keys(staged_records, resource, scoped_col, candidate_record, keys) do
              {:ok, _} = hit ->
                hit

              :none ->
                case find_existing_by_arbitrary_keys(
                       cursor_root,
                       resource,
                       candidate_record,
                       keys,
                       tenant
                     ) do
                  {:ok, db_rec} ->
                    guard_stale_db_target(
                      db_rec,
                      staged_records,
                      resource,
                      pk_attr,
                      tenant,
                      scoped_col
                    )

                  :none ->
                    :none
                end
            end
          end
      end
    end

    defp guard_stale_db_target(db_rec, staged_records, _resource, pk_attr, _tenant, scoped_col) do
      doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(db_rec, pk_attr.name))

      if Map.has_key?(staged_records, {scoped_col, doc_id}) do
        :none
      else
        {:ok, db_rec}
      end
    end

    defp encoded_active_identity_key(resource, identity, record, tenant) do
      if candidate_matches_identity_where?(resource, record, Map.get(identity, :where), tenant) do
        Codec.encode_identity_key(resource, identity, record, tenant)
      else
        :skip
      end
    end

    defp find_staged_by_identity(staged_records, resource, identity, scoped_col, target_key) do
      all_tenants? = Map.get(identity, :all_tenants?, false)

      Enum.find_value(staged_records, :none, fn {{sc, _doc_id}, staged_rec} ->
        if all_tenants? or sc == scoped_col do
          rec_tenant = Ash.Resource.get_metadata(staged_rec, :tenant)

          if encoded_active_identity_key(resource, identity, staged_rec, rec_tenant) ==
               {:ok, target_key} do
            {:ok, staged_rec}
          end
        end
      end)
    end

    defp find_staged_by_keys(staged_records, resource, scoped_col, candidate_record, keys) do
      attrs = Map.new(keys, fn k -> {k, Ash.Resource.Info.attribute(resource, k)} end)

      Enum.find_value(staged_records, :none, fn {{sc, _doc_id}, staged_rec} ->
        if sc == scoped_col and
             Enum.all?(keys, fn k ->
               values_equal?(
                 Map.fetch!(attrs, k),
                 Map.get(staged_rec, k),
                 Map.get(candidate_record, k)
               )
             end) do
          {:ok, staged_rec}
        end
      end)
    end

    defp update_in_snapshot({db, moment}, resource, %Ash.Changeset{} = changeset) do
      cursor_root = Xitdb.as_of(db, moment)
      tenant = changeset.tenant
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_val = Map.get(changeset.data, pk_name) || Ash.Changeset.get_attribute(changeset, pk_name)

      case load_existing_record(cursor_root, resource, pk_val, tenant) do
        :none ->
          {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

        {:ok, current_record} ->
          case build_updated_record(current_record, resource, changeset, :all_non_upsert) do
            {:ok, updated_record} ->
              synced_record = finalize_loaded_record(resource, updated_record, tenant)

              with {:ok, synced_with_seq, seq_ops, _} <-
                     Sequences.plan_pk(cursor_root, resource, synced_record, tenant, %{}),
                   {:ok, index_ops} <-
                     Indexer.plan_put_ops(
                       cursor_root,
                       resource,
                       current_record,
                       synced_with_seq,
                       tenant
                     )
                     |> normalize_plan_error(),
                   {:ok, next_snapshot} <-
                     commit_ops(
                       {db, moment},
                       seq_ops ++ index_ops,
                       build_commit_opts(resource, :update, changeset, nil)
                     ) do
                {:ok, next_snapshot, synced_with_seq}
              end

            :filtered_out ->
              {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

            {:error, _} = err ->
              err
          end
      end
    end

    defp upsert_in_snapshot(
           {db, moment} = snapshot,
           resource,
           %Ash.Changeset{} = changeset,
           keys,
           identity,
           bulk_opts
         ) do
      cursor_root = Xitdb.as_of(db, moment)
      tenant = changeset.tenant

      with {:ok, candidate_record} <- apply_create_record(resource, changeset) do
        case find_upsert_target(cursor_root, resource, candidate_record, keys, identity, tenant) do
          :none ->
            case create_in_snapshot(snapshot, resource, changeset) do
              {:ok, next_snap, created} ->
                {:ok, next_snap, Ash.Resource.put_metadata(created, :upsert_action, :create)}

              {:error, _} = err ->
                err
            end

          {:ok, existing_record} ->
            allowed_fields = resolve_upsert_allowed_fields(resource, changeset, keys, bulk_opts)

            case build_updated_record(
                   existing_record,
                   resource,
                   changeset,
                   {:upsert, allowed_fields, candidate_record}
                 ) do
              {:ok, updated_record} ->
                final_record =
                  resource
                  |> finalize_loaded_record(updated_record, tenant)
                  |> Ash.Resource.put_metadata(:upsert_action, :update)

                with {:ok, index_ops} <-
                       Indexer.plan_put_ops(
                         cursor_root,
                         resource,
                         existing_record,
                         final_record,
                         tenant
                       )
                       |> normalize_plan_error(),
                     {:ok, next_snapshot} <-
                       commit_ops(
                         snapshot,
                         index_ops,
                         build_commit_opts(resource, :upsert, changeset, bulk_opts)
                       ) do
                  {:ok, next_snapshot, final_record}
                end

              :filtered_out ->
                # When an `upsert_condition` filter rejects the conflict update, Ash marks the
                # existing tenant-matching record with `:upsert_skipped` without mutating it.
                skipped =
                  existing_record
                  |> Ash.Resource.put_metadata(:upsert_skipped, true)

                {:ok, snapshot, skipped}

              {:error, _} = err ->
                err
            end
        end
      end
    end

    defp destroy_in_snapshot({db, moment} = snapshot, resource, %Ash.Changeset{} = changeset) do
      cursor_root = Xitdb.as_of(db, moment)
      tenant = changeset.tenant
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_val = Map.get(changeset.data, pk_name)

      case load_existing_record(cursor_root, resource, pk_val, tenant) do
        :none ->
          {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

        {:ok, current_record} ->
          with :ok <- verify_changeset_filter(current_record, changeset, nil),
               :ok <-
                 verify_atomic_validations(current_record, current_record, resource, changeset),
               {:ok, next_snapshot} <-
                 cascade_and_delete(
                   snapshot,
                   resource,
                   current_record,
                   tenant,
                   MapSet.new(),
                   build_commit_opts(resource, :destroy, changeset, nil)
                 ) do
            {:ok, next_snapshot, current_record}
          else
            :filtered_out ->
              {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

            {:error, _} = err ->
              err
          end
      end
    end

    defp apply_bulk_updates(
           {db, moment} = initial_snapshot,
           candidates,
           resource,
           %Ash.Changeset{} = changeset,
           options
         ) do
      tenant = changeset.tenant
      cursor_root = Xitdb.as_of(db, moment)

      candidates
      |> Enum.reduce_while({:ok, [], %{}, []}, fn current_record,
                                                  {:ok, ops_chunks, batch_state, acc_records} ->
        case build_updated_record(current_record, resource, changeset, :all_non_upsert) do
          {:ok, updated_record} ->
            final_record = finalize_loaded_record(resource, updated_record, tenant)

            case Indexer.plan_put_ops_batched(
                   cursor_root,
                   resource,
                   current_record,
                   final_record,
                   tenant,
                   batch_state
                 )
                 |> normalize_plan_error() do
              {:ok, index_ops, next_batch} ->
                tagged =
                  Ash.Actions.Helpers.Bulk.put_metadata(
                    final_record,
                    %Ash.Changeset{changeset | data: current_record}
                  )

                {:cont, {:ok, [index_ops | ops_chunks], next_batch, [tagged | acc_records]}}

              {:error, _} = err ->
                {:halt, err}
            end

          :filtered_out ->
            {:cont, {:ok, ops_chunks, batch_state, acc_records}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, ops_chunks, _batch_state, rev_records} ->
          all_ops = ops_chunks |> Enum.reverse() |> List.flatten()
          commit_opts = build_commit_opts(resource, :bulk_update, changeset, options)

          with {:ok, final_snap} <- commit_ops(initial_snapshot, all_ops, commit_opts) do
            {:ok, final_snap, Enum.reverse(rev_records)}
          end

        {:error, _} = err ->
          err
      end
    end

    defp apply_bulk_destroys(
           {db, moment} = initial_snapshot,
           candidates,
           resource,
           %Ash.Changeset{} = changeset,
           options
         ) do
      tenant = changeset.tenant
      cursor_root = Xitdb.as_of(db, moment)

      candidates
      |> Enum.reduce_while(
        {:ok, [], MapSet.new(), %{}, %{}, []},
        fn current_record, {:ok, ops_chunks, visited, batch_state, staged_records, acc_records} ->
          with :ok <- verify_changeset_filter(current_record, changeset, nil),
               :ok <-
                 verify_atomic_validations(current_record, current_record, resource, changeset),
               {:ok, del_ops, next_visited, next_batch, next_staged} <-
                 stage_cascade_delete(
                   cursor_root,
                   resource,
                   current_record,
                   tenant,
                   visited,
                   batch_state,
                   staged_records
                 ) do
            tagged =
              Ash.Actions.Helpers.Bulk.put_metadata(
                current_record,
                %Ash.Changeset{changeset | data: current_record}
              )

            {:cont,
             {:ok, [del_ops | ops_chunks], next_visited, next_batch, next_staged,
              [tagged | acc_records]}}
          else
            :filtered_out ->
              {:cont, {:ok, ops_chunks, visited, batch_state, staged_records, acc_records}}

            {:error, _} = err ->
              {:halt, err}
          end
        end
      )
      |> case do
        {:ok, ops_chunks, _visited, _batch_state, _staged_records, rev_records} ->
          all_ops = ops_chunks |> Enum.reverse() |> List.flatten()
          commit_opts = build_commit_opts(resource, :bulk_destroy, changeset, options)

          with {:ok, final_snap} <- commit_ops(initial_snapshot, all_ops, commit_opts) do
            {:ok, final_snap, Enum.reverse(rev_records)}
          end

        {:error, _} = err ->
          err
      end
    end

    # -- Atomic Filter, Expression & Validation Evaluation --

    defp build_updated_record(current_record, resource, %Ash.Changeset{} = changeset, mode) do
      {allowed_attrs, allowed_atomic_set, conflicting_upsert_values} =
        prepare_update_inputs(current_record, resource, changeset, mode)

      current_struct = ensure_resource_struct(resource, current_record)

      case mode do
        {:upsert, _, _} ->
          {post_filters, pre_filters} = split_upsert_filters(changeset.filter)

          with :ok <-
                 verify_filter_list(
                   pre_filters,
                   current_struct,
                   current_struct,
                   changeset,
                   conflicting_upsert_values
                 ),
               {:ok, evaluated_atomics} <-
                 evaluate_update_atomics(
                   current_record,
                   allowed_attrs,
                   allowed_atomic_set,
                   resource,
                   changeset,
                   conflicting_upsert_values
                 ) do
            post_record =
              current_record
              |> Map.merge(allowed_attrs)
              |> Map.merge(evaluated_atomics)

            post_struct = ensure_resource_struct(resource, post_record)

            with :ok <-
                   verify_filter_list(
                     post_filters,
                     post_struct,
                     current_struct,
                     changeset,
                     conflicting_upsert_values
                   ),
                 :ok <-
                   verify_atomic_validations(
                     current_record,
                     post_record,
                     resource,
                     changeset,
                     conflicting_upsert_values
                   ) do
              {:ok, post_record}
            end
          end

        :all_non_upsert ->
          with :ok <-
                 verify_changeset_filter(current_record, changeset, conflicting_upsert_values),
               {:ok, evaluated_atomics} <-
                 evaluate_update_atomics(
                   current_record,
                   allowed_attrs,
                   allowed_atomic_set,
                   resource,
                   changeset,
                   conflicting_upsert_values
                 ) do
            post_record =
              current_record
              |> Map.merge(allowed_attrs)
              |> Map.merge(evaluated_atomics)

            case verify_atomic_validations(
                   current_record,
                   post_record,
                   resource,
                   changeset,
                   conflicting_upsert_values
                 ) do
              :ok -> {:ok, post_record}
              {:error, _} = err -> err
            end
          end
      end
    end

    defp prepare_update_inputs(
           _current_record,
           _resource,
           %Ash.Changeset{} = changeset,
           :all_non_upsert
         ) do
      {changeset.attributes, :all, nil}
    end

    defp prepare_update_inputs(
           _current_record,
           resource,
           %Ash.Changeset{} = changeset,
           {:upsert, allowed_fields, candidate_record}
         )
         when is_list(allowed_fields) do
      pk_set = MapSet.new(Ash.Resource.Info.primary_key(resource))
      safe_set = MapSet.difference(MapSet.new(allowed_fields), pk_set)

      base_attrs =
        changeset.attributes
        |> Map.filter(fn {k, _v} -> MapSet.member?(safe_set, k) end)
        |> apply_upsert_update_defaults(resource, changeset, safe_set)

      {base_attrs, safe_set, candidate_record}
    end

    defp apply_upsert_update_defaults(attrs_map, resource, %Ash.Changeset{} = changeset, safe_set) do
      touch_defaults? =
        case get_in(changeset.context, [:private, :touch_update_defaults?]) do
          false -> false
          _ -> MapSet.size(safe_set) > 0
        end

      if not touch_defaults? do
        attrs_map
      else
        pk_set = MapSet.new(Ash.Resource.Info.primary_key(resource))

        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(&(&1.update_default != nil and not MapSet.member?(pk_set, &1.name)))
        |> Enum.reduce(attrs_map, fn attr, acc ->
          if Map.has_key?(acc, attr.name) do
            acc
          else
            val = eval_update_default(attr.update_default)
            Map.put(acc, attr.name, val)
          end
        end)
      end
    end

    defp eval_update_default(fun) when is_function(fun, 0), do: fun.()

    defp eval_update_default({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a),
      do: apply(m, f, a)

    defp eval_update_default(value), do: value

    defp resolve_upsert_allowed_fields(resource, %Ash.Changeset{} = changeset, keys, bulk_opts) do
      pk_set = MapSet.new(Ash.Resource.Info.primary_key(resource))

      raw_upsert_fields =
        case get_in(changeset.context, [:private, :upsert_fields]) do
          nil -> Map.get(bulk_opts, :upsert_fields)
          configured -> configured
        end

      candidate_fields =
        case raw_upsert_fields do
          nil ->
            # Ash default when `upsert_fields` is omitted: explicitly changing attributes
            # (minus create defaults unless part of `keys`) plus `update_default` attributes.
            defaults = Map.get(changeset, :defaults, []) -- keys
            explicit = Map.keys(changeset.attributes) -- defaults
            atomic_keys = Keyword.keys(Map.get(changeset, :atomics, []))

            touch_defaults? =
              case get_in(changeset.context, [:private, :touch_update_defaults?]) do
                false -> false
                _ -> Map.get(bulk_opts, :touch_update_defaults?, true) != false
              end

            update_defaults =
              if touch_defaults? do
                resource
                |> Ash.Resource.Info.attributes()
                |> Enum.filter(&(&1.update_default != nil))
                |> Enum.map(& &1.name)
              else
                []
              end

            Enum.uniq(explicit ++ atomic_keys ++ update_defaults)

          :replace_all ->
            Ash.Changeset.expand_upsert_fields(:replace_all, resource)

          {:replace, fields} when is_list(fields) ->
            fields

          {:replace_all_except, except} when is_list(except) ->
            Ash.Changeset.expand_upsert_fields({:replace_all_except, except}, resource)

          fields when is_list(fields) ->
            fields
        end

      Enum.reject(candidate_fields, &MapSet.member?(pk_set, &1))
    end

    defp normalize_plan_error({:error, {:integer_out_of_i64_range, field}}) do
      {:error,
       InvalidAttribute.exception(
         field: field,
         message: "must fit within a signed 64-bit integer (-2^63..2^63-1)"
       )}
    end

    defp normalize_plan_error({:error, {:integer_out_of_u64_range, field}}) do
      {:error,
       InvalidAttribute.exception(
         field: field,
         message: "must fit within an unsigned 64-bit integer (0..2^64-1)"
       )}
    end

    defp normalize_plan_error({:error, {:invalid_format_tag, field}}) do
      {:error,
       InvalidAttribute.exception(
         field: field,
         message: "tagged binary values must use a 2-byte tag and binary payload"
       )}
    end

    defp normalize_plan_error(other), do: other

    defp verify_create_filter(_record, _resource, %Ash.Changeset{filter: nil}), do: :ok

    defp verify_create_filter(
           _record,
           _resource,
           %Ash.Changeset{filter: %Ash.Filter{expression: expr}}
         )
         when expr in [nil, true],
         do: :ok

    defp verify_create_filter(record, resource, %Ash.Changeset{} = changeset) do
      record_struct = ensure_resource_struct(resource, record)

      case verify_filter_list([changeset.filter], record_struct, record_struct, changeset, nil) do
        :ok ->
          :ok

        :filtered_out ->
          {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

        {:error, _} = err ->
          err
      end
    end

    defp split_upsert_filters(nil), do: {[], []}

    defp split_upsert_filters(%Ash.Filter{expression: expr}) when expr in [nil, true],
      do: {[], []}

    defp split_upsert_filters(%Ash.Filter{expression: expr} = filter) do
      conjuncts = flatten_and_conjuncts(expr)
      {post_exprs, pre_exprs} = Enum.split_with(conjuncts, &expr_is_post_atomic_validation?/1)

      pre_filters =
        case pre_exprs do
          [] -> []
          list -> [%Ash.Filter{filter | expression: combine_and_conjuncts(list)}]
        end

      post_filters =
        Enum.map(post_exprs, fn e -> %Ash.Filter{filter | expression: e} end)

      {post_filters, pre_filters}
    end

    defp flatten_and_conjuncts(%Ash.Query.BooleanExpression{op: :and, left: l, right: r}) do
      flatten_and_conjuncts(l) ++ flatten_and_conjuncts(r)
    end

    defp flatten_and_conjuncts(other), do: [other]

    defp combine_and_conjuncts([single]), do: single

    defp combine_and_conjuncts([first | rest]) do
      Enum.reduce(rest, first, fn item, acc ->
        %Ash.Query.BooleanExpression{op: :and, left: acc, right: item}
      end)
    end

    defp expr_is_post_atomic_validation?(expr) do
      not is_nil(
        Ash.Filter.find(expr, fn
          {:_atomic_ref, _} -> true
          %Ash.Query.Call{name: :atomic_ref} -> true
          %Ash.Query.Function.Error{} -> true
          _ -> false
        end)
      )
    end

    defp verify_filter_list(
           filters,
           sub_struct,
           match_struct,
           %Ash.Changeset{} = changeset,
           conflicting_upsert_values
         ) do
      actor = get_in(changeset.context, [:private, :actor])

      Enum.reduce_while(filters, :ok, fn filter_item, :ok ->
        resolved = substitute_atomic_refs(filter_item, sub_struct)

        case Ash.Filter.Runtime.filter_matches(
               changeset.domain,
               [match_struct],
               resolved,
               actor: actor,
               tenant: changeset.tenant,
               authorize?: false,
               conflicting_upsert_values: conflicting_upsert_values
             ) do
          {:ok, [_matched]} -> {:cont, :ok}
          {:ok, []} -> {:halt, :filtered_out}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp verify_changeset_filter(_record, %Ash.Changeset{filter: nil}, _conflicting), do: :ok

    defp verify_changeset_filter(
           _record,
           %Ash.Changeset{filter: %Ash.Filter{expression: expr}},
           _conflicting
         )
         when expr in [nil, true],
         do: :ok

    defp verify_changeset_filter(record, %Ash.Changeset{} = changeset, conflicting_upsert_values) do
      record_struct = ensure_resource_struct(changeset.resource, record)

      verify_filter_list(
        [changeset.filter],
        record_struct,
        record_struct,
        changeset,
        conflicting_upsert_values
      )
    end

    defp apply_create_record(_resource, %Ash.Changeset{create_atomics: []} = changeset) do
      Ash.Changeset.apply_attributes(changeset)
    end

    defp apply_create_record(resource, %Ash.Changeset{create_atomics: create_atomics} = changeset) do
      atomic_fields = MapSet.new(create_atomics, fn {field, _expr} -> field end)

      non_resolved_errors =
        Enum.reject(changeset.errors, fn
          %Ash.Error.Changes.Required{field: field, type: :attribute} ->
            MapSet.member?(atomic_fields, field)

          _ ->
            false
        end)

      if non_resolved_errors != [] do
        {:error, Ash.Error.to_error_class(non_resolved_errors, changeset: changeset)}
      else
        with {:ok, base_record} <- Ash.Changeset.apply_attributes(changeset, force?: true),
             {:ok, after_atomics} <- apply_create_atomics(base_record, resource, changeset),
             :ok <- validate_required_after_atomics(resource, after_atomics) do
          {:ok, after_atomics}
        end
      end
    end

    defp validate_required_after_atomics(resource, record) do
      missing =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.find(fn attr ->
          attr.allow_nil? == false and not attr.generated? and is_nil(Map.get(record, attr.name))
        end)

      case missing do
        nil ->
          :ok

        attr ->
          {:error, Ash.Error.Changes.Required.exception(field: attr.name, type: :attribute)}
      end
    end

    defp apply_create_atomics(base_record, resource, %Ash.Changeset{} = changeset) do
      create_atomics = Map.get(changeset, :create_atomics, [])

      if create_atomics == [] do
        {:ok, base_record}
      else
        actor = get_in(changeset.context, [:private, :actor])

        Enum.reduce_while(create_atomics, {:ok, base_record}, fn {field, expr}, {:ok, acc_rec} ->
          attr = Ash.Resource.Info.attribute(resource, field)
          resolved_expr = substitute_atomic_refs(expr, acc_rec)

          with {:ok, raw_val} <-
                 eval_value_expr(resolved_expr, acc_rec, resource, changeset, actor, nil),
               {:ok, casted_val} <- cast_atomic_value(attr, raw_val) do
            {:cont, {:ok, Map.put(acc_rec, field, casted_val)}}
          else
            {:error, _} = err -> {:halt, err}
          end
        end)
      end
    end

    defp evaluate_update_atomics(
           current_record,
           allowed_attrs,
           allowed_atomic_set,
           resource,
           %Ash.Changeset{} = changeset,
           conflicting_upsert_values
         ) do
      atomics = Map.get(changeset, :atomics, [])
      pk_set = MapSet.new(Ash.Resource.Info.primary_key(resource))

      filtered_atomics =
        Enum.filter(atomics, fn {field, _expr} ->
          case allowed_atomic_set do
            :all -> true
            %MapSet{} = set -> MapSet.member?(set, field) and not MapSet.member?(pk_set, field)
          end
        end)

      if filtered_atomics == [] do
        {:ok, %{}}
      else
        actor = get_in(changeset.context, [:private, :actor])

        # `{:_atomic_ref, f}` sees explicit attribute overrides while bare `%Ref{}` sees `current_record`!
        pre_atomic_overlay = Map.merge(current_record, allowed_attrs)

        Enum.reduce_while(filtered_atomics, {:ok, %{}}, fn {field, expr}, {:ok, acc_map} ->
          attr = Ash.Resource.Info.attribute(resource, field)
          overlay = Map.merge(pre_atomic_overlay, acc_map)
          resolved_expr = substitute_atomic_refs(expr, overlay)

          with {:ok, raw_val} <-
                 eval_value_expr(
                   resolved_expr,
                   current_record,
                   resource,
                   changeset,
                   actor,
                   conflicting_upsert_values
                 ),
               {:ok, casted_val} <- cast_atomic_value(attr, raw_val) do
            {:cont, {:ok, Map.put(acc_map, field, casted_val)}}
          else
            {:error, _} = err -> {:halt, err}
          end
        end)
      end
    end

    defp verify_atomic_validations(
           pre_record,
           post_record,
           resource,
           %Ash.Changeset{} = changeset,
           conflicting_upsert_values \\ nil
         ) do
      validations = Map.get(changeset, :atomic_validations, [])
      actor = get_in(changeset.context, [:private, :actor])
      pre_struct = ensure_resource_struct(resource, pre_record)
      post_struct = ensure_resource_struct(resource, post_record)

      Enum.reduce_while(validations, :ok, fn entry, :ok ->
        {failure_expr, error_expr} =
          case entry do
            {_fields, cond_expr, err_expr} -> {cond_expr, err_expr}
            {cond_expr, err_expr} -> {cond_expr, err_expr}
          end

        # Substitute any `{:_atomic_ref, field}` nodes against `post_struct`, while bare
        # `%Ash.Query.Ref{}` nodes inspect `pre_struct` (for updates/destroys) or `post_struct` (for creates).
        resolved_cond = substitute_atomic_refs(failure_expr, post_struct)

        case eval_boolean_condition(
               resolved_cond,
               pre_struct,
               resource,
               changeset,
               actor,
               conflicting_upsert_values
             ) do
          {:ok, true} ->
            resolved_err = substitute_atomic_refs(error_expr, post_struct)

            {:halt,
             {:error,
              materialize_validation_error(resolved_err, post_struct, resource, changeset, actor)}}

          {:ok, false} ->
            {:cont, :ok}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    end

    defp eval_boolean_condition(
           expr,
           record_struct,
           resource,
           %Ash.Changeset{} = changeset,
           actor,
           conflicting_upsert_values
         ) do
      hydrate_ctx = %{
        resource: resource,
        public?: false,
        conflicting_upsert_values: conflicting_upsert_values
      }

      with {:ok, hydrated} <- Ash.Filter.hydrate_refs(expr, hydrate_ctx),
           external_loads =
             Query.external_loads_for_expression(hydrated, resource, [record_struct]),
           {:ok, [eval_record]} <-
             Query.load_external_deps(
               [record_struct],
               external_loads,
               resource,
               changeset.domain,
               changeset.tenant,
               actor,
               changeset.context
             ) do
        eval_opts = [
          record: eval_record,
          resource: resource,
          actor: actor,
          tenant: changeset.tenant,
          context: changeset.context,
          unknown_on_unknown_refs?: true
        ]

        case Ash.Expr.eval_hydrated(hydrated, eval_opts) do
          {:ok, truthy} when truthy not in [false, nil] ->
            {:ok, true}

          {:ok, _false_or_nil} ->
            {:ok, false}

          :unknown ->
            # Relational / cross-store expressions (e.g. `exists(organization.profiles, ...)`)
            # return `:unknown` from pure `Ash.Expr.eval/2`. NEVER map `:unknown` to `{:ok, nil}`!
            case Ash.Filter.Runtime.filter_matches(
                   changeset.domain,
                   [eval_record],
                   expr,
                   actor: actor,
                   tenant: changeset.tenant,
                   authorize?: false,
                   conflicting_upsert_values: conflicting_upsert_values
                 ) do
              {:ok, [_matched]} -> {:ok, true}
              {:ok, []} -> {:ok, false}
              {:error, _} = err -> err
            end

          {:error, _} = err ->
            err
        end
      end
    end

    defp eval_value_expr(
           expr,
           record,
           resource,
           %Ash.Changeset{} = changeset,
           actor,
           conflicting_upsert_values
         ) do
      record_struct = ensure_resource_struct(resource, record)

      hydrate_ctx = %{
        resource: resource,
        public?: false,
        conflicting_upsert_values: conflicting_upsert_values
      }

      with {:ok, hydrated} <- Ash.Filter.hydrate_refs(expr, hydrate_ctx),
           external_loads =
             Query.external_loads_for_expression(hydrated, resource, [record_struct]),
           {:ok, [eval_record]} <-
             Query.load_external_deps(
               [record_struct],
               external_loads,
               resource,
               changeset.domain,
               changeset.tenant,
               actor,
               changeset.context
             ) do
        eval_opts = [
          record: eval_record,
          resource: resource,
          actor: actor,
          tenant: changeset.tenant,
          context: changeset.context,
          unknown_on_unknown_refs?: true
        ]

        case Ash.Expr.eval_hydrated(hydrated, eval_opts) do
          {:ok, val} ->
            {:ok, val}

          :unknown ->
            {:error,
             InvalidChanges.exception(
               message: "could not evaluate atomic expression #{inspect(expr)}"
             )}

          {:error, _} = err ->
            err
        end
      end
    end

    defp substitute_atomic_refs(expr, post_record) when is_map(post_record) do
      Ash.Filter.map(expr, fn
        {:_atomic_ref, field} when is_atom(field) ->
          Map.get(post_record, field)

        %Ash.Query.Call{name: :atomic_ref, args: [field]} when is_atom(field) ->
          Map.get(post_record, field)

        other ->
          other
      end)
    end

    defp materialize_validation_error(error_expr, record, resource, changeset, actor) do
      case eval_value_expr(error_expr, record, resource, changeset, actor, nil) do
        {:ok, %_{} = exc} when is_exception(exc) ->
          exc

        {:ok, {error_mod, opts}} when is_atom(error_mod) and (is_list(opts) or is_map(opts)) ->
          error_mod.exception(Enum.to_list(opts))

        {:error, %_{} = exc} when is_exception(exc) ->
          exc

        {:error, reason} ->
          InvalidChanges.exception(message: inspect(reason))

        {:ok, other} ->
          InvalidChanges.exception(message: inspect(other))
      end
    end

    defp cast_atomic_value(_attr, nil), do: {:ok, nil}
    defp cast_atomic_value(nil, val), do: {:ok, val}

    defp cast_atomic_value(%Ash.Resource.Attribute{} = attr, val) do
      case Ash.Type.cast_input(attr.type, val, attr.constraints) do
        {:ok, casted} ->
          {:ok, casted}

        {:error, reason} ->
          {:error, InvalidAttribute.exception(field: attr.name, message: inspect(reason))}
      end
    end

    # -- Duplicate-PK, Intra-Batch Identity & Upsert Target Lookup --

    defp allow_existing_cursor?(%Ash.Changeset{context: ctx}) when is_map(ctx) do
      Map.get(ctx, :mdm_materializer, false) == true or
        match?(%{allow_existing_cursor?: true}, Map.get(ctx, :xitdb))
    end

    defp allow_existing_cursor?(_changeset), do: false

    defp verify_pk_unused(
           cursor_root,
           resource,
           record,
           tenant,
           seen_pks,
           allow_existing? \\ false
         ) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_val = Map.get(record, pk_name)

      if is_nil(pk_val) do
        {:error, InvalidChanges.exception(fields: [pk_name], message: "is required")}
      else
        pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
        doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)
        scoped_col = Codec.scoped_collection(resource, tenant)

        cond do
          MapSet.member?(seen_pks, {scoped_col, doc_id}) ->
            {:error,
             InvalidChanges.exception(fields: [pk_name], message: "has already been taken")}

          allow_existing? ->
            :ok

          true ->
            case Indexer.fetch_cursor(cursor_root, resource, pk_val, tenant) do
              :none ->
                :ok

              {:ok, _existing} ->
                {:error,
                 InvalidChanges.exception(fields: [pk_name], message: "has already been taken")}
            end
        end
      end
    end

    defp track_batch_identities(resource, record, tenant, seen_identities) do
      scoped_col = Codec.scoped_collection(resource, tenant)
      base_col = Atom.to_string(Info.collection!(resource))

      resource
      |> Ash.Resource.Info.identities()
      |> Enum.reduce_while({:ok, seen_identities}, fn identity, {:ok, acc_seen} ->
        if not candidate_matches_identity_where?(
             resource,
             record,
             Map.get(identity, :where),
             tenant
           ) do
          {:cont, {:ok, acc_seen}}
        else
          case Codec.encode_identity_key(resource, identity, record, tenant) do
            :skip ->
              {:cont, {:ok, acc_seen}}

            {:ok, encoded_key} ->
              id_col = if Map.get(identity, :all_tenants?, false), do: base_col, else: scoped_col
              batch_token = {id_col, identity.name, encoded_key}

              if MapSet.member?(acc_seen, batch_token) do
                {:halt,
                 {:error,
                  InvalidChanges.exception(
                    fields: Map.get(identity, :field_names) || identity.keys,
                    message: Map.get(identity, :message) || "has already been taken"
                  )}}
              else
                {:cont, {:ok, MapSet.put(acc_seen, batch_token)}}
              end
          end
        end
      end)
    end

    defp find_upsert_target(cursor_root, resource, candidate_record, keys, identity, tenant) do
      pk_fields = Ash.Resource.Info.primary_key(resource)

      cond do
        identity != nil ->
          lookup_existing_by_identity(cursor_root, resource, identity, candidate_record, tenant)

        Enum.sort(keys) == Enum.sort(pk_fields) ->
          pk_val = Map.get(candidate_record, hd(pk_fields))
          load_existing_record(cursor_root, resource, pk_val, tenant)

        true ->
          matched_identity =
            resource
            |> Ash.Resource.Info.identities()
            |> Enum.find(fn id -> Enum.sort(id.keys) == Enum.sort(keys) end)

          if matched_identity != nil do
            lookup_existing_by_identity(
              cursor_root,
              resource,
              matched_identity,
              candidate_record,
              tenant
            )
          else
            find_existing_by_arbitrary_keys(cursor_root, resource, candidate_record, keys, tenant)
          end
      end
    end

    defp lookup_existing_by_identity(
           cursor_root,
           resource,
           identity_or_name,
           candidate_record,
           tenant
         ) do
      resolved_identity =
        case identity_or_name do
          %Ash.Resource.Identity{} = id_struct ->
            id_struct

          name when is_atom(name) and not is_nil(name) ->
            Ash.Resource.Info.identity(resource, name)

          _ ->
            nil
        end

      with %Ash.Resource.Identity{} = identity <- resolved_identity,
           true <-
             candidate_matches_identity_where?(
               resource,
               candidate_record,
               Map.get(identity, :where),
               tenant
             ),
           {:ok, doc_id} <-
             Indexer.lookup_by_identity(cursor_root, resource, identity, candidate_record, tenant),
           {:ok, pk_val} <- Codec.decode_doc_id(resource, doc_id) do
        load_existing_record(cursor_root, resource, pk_val, tenant)
      else
        _ -> :none
      end
    end

    defp find_existing_by_arbitrary_keys(cursor_root, resource, candidate_record, keys, tenant) do
      if Enum.any?(keys, &is_nil(Map.get(candidate_record, &1))) do
        :none
      else
        filter_kw = Enum.map(keys, fn k -> {k, Map.get(candidate_record, k)} end)
        ash_filter = Ash.Filter.parse!(resource, filter_kw)
        domain = Ash.Resource.Info.domain(resource)

        query =
          resource
          |> Query.new(domain)
          |> Map.put(:filter, ash_filter)
          |> Map.put(:tenant, tenant)
          |> Map.put(:limit, 1)

        case Query.execute(cursor_root, query, resource) do
          {:ok, [existing | _]} -> {:ok, existing}
          _ -> :none
        end
      end
    end

    defp candidate_matches_identity_where?(_resource, _record, nil, _tenant), do: true

    defp candidate_matches_identity_where?(resource, record, where_filter, tenant) do
      record_struct = ensure_resource_struct(resource, record)
      domain = Ash.Resource.Info.domain(resource)

      case Ash.Filter.Runtime.filter_matches(
             domain,
             [record_struct],
             where_filter,
             tenant: tenant,
             authorize?: false
           ) do
        {:ok, [_]} -> true
        _ -> false
      end
    end

    # -- Same-Store Reverse FK `on_delete` Enforcement --

    defp cascade_and_delete(
           {db, moment} = snapshot,
           resource,
           record,
           tenant,
           visited,
           commit_opts
         ) do
      cursor_root = Xitdb.as_of(db, moment)

      with {:ok, ops, _next_visited, _next_batch, _next_staged} <-
             stage_cascade_delete(cursor_root, resource, record, tenant, visited, %{}, %{}) do
        commit_ops(snapshot, ops, commit_opts)
      end
    end

    defp record_stage_key(resource, record, tenant) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
      doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(record, pk_name))
      {resource, Codec.scoped_collection(resource, tenant), doc_id}
    end

    defp fk_rule_priority(%{on_delete: :delete}), do: 0
    defp fk_rule_priority(%{on_delete: :nilify}), do: 1
    defp fk_rule_priority(%{on_delete: :restrict}), do: 2
    defp fk_rule_priority(_rule), do: 3

    defp stage_cascade_delete(
           cursor_root,
           resource,
           record,
           tenant,
           visited,
           batch_state,
           staged_records
         ) do
      stage_key = record_stage_key(resource, record, tenant)

      if MapSet.member?(visited, stage_key) or Map.get(staged_records, stage_key) == :deleted do
        {:ok, [], visited, batch_state, staged_records}
      else
        effective_record =
          case Map.get(staged_records, stage_key) do
            %_{} = staged -> staged
            _ -> record
          end

        next_visited = MapSet.put(visited, stage_key)
        staged_with_self = Map.put(staged_records, stage_key, :deleted)
        store = Info.store!(resource)
        rules = Store.reverse_fks(store, resource)

        with {:ok, fk_ops, visited_after_fks, batch_after_fks, staged_after_fks} <-
               stage_reverse_fk_rules(
                 cursor_root,
                 rules,
                 effective_record,
                 tenant,
                 next_visited,
                 batch_state,
                 staged_with_self
               ),
             {:ok, del_ops, final_batch} <-
               Indexer.plan_delete_ops_batched(
                 cursor_root,
                 resource,
                 effective_record,
                 tenant,
                 batch_after_fks
               ) do
          {:ok, fk_ops ++ del_ops, visited_after_fks, final_batch, staged_after_fks}
        end
      end
    end

    defp stage_reverse_fk_rules(
           _cursor_root,
           [],
           _record,
           _tenant,
           visited,
           batch_state,
           staged_records
         ) do
      {:ok, [], visited, batch_state, staged_records}
    end

    defp stage_reverse_fk_rules(
           cursor_root,
           rules,
           parent_record,
           tenant,
           visited,
           batch_state,
           staged_records
         ) do
      rules
      |> Enum.sort_by(&fk_rule_priority/1)
      |> Enum.reduce_while({:ok, [], visited, batch_state, staged_records}, fn rule,
                                                                               {:ok, ops_acc,
                                                                                vis_acc, b_acc,
                                                                                s_acc} ->
        dest_val = Map.get(parent_record, rule.destination_attribute)

        if is_nil(dest_val) do
          {:cont, {:ok, ops_acc, vis_acc, b_acc, s_acc}}
        else
          case stage_single_fk_rule(cursor_root, rule, dest_val, tenant, vis_acc, b_acc, s_acc) do
            {:ok, rule_ops, next_vis, next_b, next_s} ->
              {:cont, {:ok, [rule_ops | ops_acc], next_vis, next_b, next_s}}

            {:error, _} = err ->
              {:halt, err}
          end
        end
      end)
      |> case do
        {:ok, ops_chunks, final_vis, final_b, final_s} ->
          {:ok, ops_chunks |> Enum.reverse() |> List.flatten(), final_vis, final_b, final_s}

        {:error, _} = err ->
          err
      end
    end

    defp stage_single_fk_rule(
           _cursor_root,
           %{on_delete: :nothing},
           _dest_val,
           _tenant,
           visited,
           batch_state,
           staged_records
         ) do
      {:ok, [], visited, batch_state, staged_records}
    end

    defp stage_single_fk_rule(
           cursor_root,
           %{on_delete: :restrict} = rule,
           dest_val,
           tenant,
           visited,
           batch_state,
           staged_records
         ) do
      child_count =
        count_referencing_children(cursor_root, rule, dest_val, tenant, staged_records)

      if child_count > 0 do
        {:error,
         InvalidChanges.exception(
           fields: [rule.destination_attribute],
           message: "cannot be destroyed while referenced by #{inspect(rule.source_collection)}"
         )}
      else
        {:ok, [], visited, batch_state, staged_records}
      end
    end

    defp stage_single_fk_rule(
           cursor_root,
           %{on_delete: :nilify} = rule,
           dest_val,
           tenant,
           visited,
           batch_state,
           staged_records
         ) do
      children = load_referencing_children(cursor_root, rule, dest_val, tenant, staged_records)

      Enum.reduce_while(children, {:ok, [], batch_state, staged_records}, fn child,
                                                                             {:ok, ops_acc, b_acc,
                                                                              s_acc} ->
        nilified = Map.put(child, rule.source_attribute, nil)

        case Indexer.plan_put_ops_batched(
               cursor_root,
               rule.source_resource,
               child,
               nilified,
               tenant,
               b_acc
             )
             |> normalize_plan_error() do
          {:ok, ops, next_b} ->
            next_s =
              Map.put(s_acc, record_stage_key(rule.source_resource, child, tenant), nilified)

            {:cont, {:ok, [ops | ops_acc], next_b, next_s}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, ops_chunks, final_b, final_s} ->
          {:ok, ops_chunks |> Enum.reverse() |> List.flatten(), visited, final_b, final_s}

        {:error, _} = err ->
          err
      end
    end

    defp stage_single_fk_rule(
           cursor_root,
           %{on_delete: :delete} = rule,
           dest_val,
           tenant,
           visited,
           batch_state,
           staged_records
         ) do
      children = load_referencing_children(cursor_root, rule, dest_val, tenant, staged_records)

      Enum.reduce_while(children, {:ok, [], visited, batch_state, staged_records}, fn child,
                                                                                      {:ok,
                                                                                       ops_acc,
                                                                                       vis_acc,
                                                                                       b_acc,
                                                                                       s_acc} ->
        case stage_cascade_delete(
               cursor_root,
               rule.source_resource,
               child,
               tenant,
               vis_acc,
               b_acc,
               s_acc
             ) do
          {:ok, ops, next_vis, next_b, next_s} ->
            {:cont, {:ok, [ops | ops_acc], next_vis, next_b, next_s}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, ops_chunks, final_vis, final_b, final_s} ->
          {:ok, ops_chunks |> Enum.reverse() |> List.flatten(), final_vis, final_b, final_s}

        {:error, _} = err ->
          err
      end
    end

    defp count_referencing_children(
           cursor_root,
           %{source_resource: res, source_attribute: fk} = rule,
           dest_val,
           tenant,
           staged_records
         ) do
      staged_for_resource? =
        Enum.any?(staged_records, fn {{staged_res, _col, _doc_id}, _state} ->
          staged_res == res
        end)

      if staged_for_resource? do
        length(load_referencing_children(cursor_root, rule, dest_val, tenant, staged_records))
      else
        nested_cursors =
          if Map.get(rule, :nested?, false) do
            Indexer.nested_cursors_for_parent(cursor_root, res, dest_val, tenant)
          else
            []
          end

        cond do
          nested_cursors != [] ->
            length(nested_cursors)

          Enum.any?(Info.indexes_for_field(res, fk), &(&1.fields == [fk])) ->
            Indexer.count_by_attribute(cursor_root, res, fk, dest_val, tenant)

          true ->
            length(load_referencing_children(cursor_root, rule, dest_val, tenant, staged_records))
        end
      end
    end

    defp load_referencing_children(
           cursor_root,
           %{source_resource: res, source_attribute: fk} = rule,
           dest_val,
           tenant,
           staged_records
         ) do
      nested_cursors =
        if Map.get(rule, :nested?, false) do
          Indexer.nested_cursors_for_parent(cursor_root, res, dest_val, tenant)
        else
          []
        end

      cursors =
        if nested_cursors != [] do
          nested_cursors
        else
          case Enum.find(Info.indexes_for_field(res, fk), &(&1.fields == [fk])) do
            %{} = idx ->
              cursor_root
              |> Indexer.lookup_secondary_eq(res, idx, [dest_val], tenant)
              |> Enum.flat_map(fn doc_id ->
                with {:ok, pk_val} <- Codec.decode_doc_id(res, doc_id),
                     {:ok, cursor} <- Indexer.fetch_cursor(cursor_root, res, pk_val, tenant) do
                  [{doc_id, cursor}]
                else
                  _ -> []
                end
              end)

            nil ->
              Indexer.all_cursors(cursor_root, res, tenant)
          end
        end

      attr = Ash.Resource.Info.attribute(res, fk)
      scoped_col = Codec.scoped_collection(res, tenant)

      cursors
      |> Enum.flat_map(fn {doc_id, cursor} ->
        case Map.get(staged_records, {res, scoped_col, doc_id}) do
          :deleted ->
            []

          %_{} = staged_child ->
            if values_equal?(attr, Map.get(staged_child, fk), dest_val),
              do: [staged_child],
              else: []

          nil ->
            case Codec.from_cursor(res, cursor, tenant) do
              {:ok, child} ->
                if values_equal?(attr, Map.get(child, fk), dest_val), do: [child], else: []

              {:error, _} ->
                []
            end
        end
      end)
    end

    defp values_equal?(nil, left, right), do: left == right

    defp values_equal?(%Ash.Resource.Attribute{type: type}, left, right) do
      Ash.Type.equal?(type, left, right)
    end

    # -- Commit, Hydration & Metadata Helpers --

    defp emit_mutation_telemetry(resource, action_kind, fun) do
      collection = Info.collection!(resource)
      start_time = System.monotonic_time()
      prev_stats = Process.get(@mutation_stats_key)

      Process.put(@mutation_stats_key, %{commit_duration: 0, op_count: 0, record_count: 0})

      meta = %{resource: resource, collection: collection, action: action_kind}

      :telemetry.execute(
        [:xitdb, :ash, :mutation, :start],
        %{monotonic_time: start_time, system_time: System.system_time()},
        meta
      )

      try do
        result = fun.()
        duration = System.monotonic_time() - start_time

        stats =
          Process.get(@mutation_stats_key) || %{commit_duration: 0, op_count: 0, record_count: 0}

        plan_duration = max(duration - stats.commit_duration, 0)

        status =
          case result do
            {:error, _} -> :error
            _ -> :ok
          end

        :telemetry.execute(
          [:xitdb, :ash, :mutation, :stop],
          %{
            duration: duration,
            monotonic_time: System.monotonic_time(),
            plan_duration: plan_duration,
            commit_duration: stats.commit_duration,
            op_count: stats.op_count,
            record_count: stats.record_count
          },
          Map.put(meta, :status, status)
        )

        result
      rescue
        exception ->
          emit_mutation_exception(start_time, meta, :error, exception, __STACKTRACE__)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          emit_mutation_exception(start_time, meta, kind, reason, __STACKTRACE__)
          :erlang.raise(kind, reason, __STACKTRACE__)
      after
        if prev_stats == nil do
          Process.delete(@mutation_stats_key)
        else
          Process.put(@mutation_stats_key, prev_stats)
        end
      end
    end

    defp emit_mutation_exception(start_time, meta, kind, reason, stacktrace) do
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        [:xitdb, :ash, :mutation, :exception],
        %{duration: duration, monotonic_time: System.monotonic_time()},
        Map.merge(meta, %{kind: kind, reason: reason, stacktrace: stacktrace})
      )
    end

    defp put_mutation_record_count(count) when is_integer(count) do
      case Process.get(@mutation_stats_key) do
        %{} = stats -> Process.put(@mutation_stats_key, %{stats | record_count: count})
        nil -> :ok
      end
    end

    defp record_commit_stats(op_count, commit_duration) do
      case Process.get(@mutation_stats_key) do
        %{} = stats ->
          Process.put(@mutation_stats_key, %{
            stats
            | op_count: stats.op_count + op_count,
              commit_duration: stats.commit_duration + commit_duration
          })

        nil ->
          :ok
      end
    end

    defp commit_ops({db, moment}, [], _commit_opts), do: {:ok, {db, moment}}

    defp commit_ops({db, moment}, ops, commit_opts)
         when is_list(ops) and is_list(commit_opts) do
      tx_opts = Keyword.put(commit_opts, :base_moment, moment)
      started = System.monotonic_time()

      case Xitdb.transact_ops_with_moment(db, ops, tx_opts) do
        {:ok, next_db, next_moment} ->
          record_commit_stats(length(ops), System.monotonic_time() - started)
          {:ok, {next_db, next_moment}}

        {:error, _} = err ->
          err
      end
    end

    defp build_commit_opts(resource, action_kind, changeset, opts) do
      cs_ctx =
        case changeset do
          %Ash.Changeset{context: ctx} when is_map(ctx) -> ctx
          _ -> %{}
        end

      opts_map =
        cond do
          is_map(opts) -> opts
          is_list(opts) -> Map.new(opts)
          true -> %{}
        end

      ambient = Xitdb.current_tx_context()
      ambient_meta = if ambient, do: ambient.meta, else: %{}

      override = extract_xitdb_override(cs_ctx, opts_map)
      explicit_meta = extract_explicit_meta(override)

      cs_action_name =
        case changeset do
          %Ash.Changeset{action: %{name: name}} when not is_nil(name) -> to_string(name)
          _ -> nil
        end

      action_name =
        Map.get(explicit_meta, "action_name") ||
          cs_action_name ||
          Map.get(ambient_meta, "action_name") ||
          Atom.to_string(action_kind)

      source_system =
        Map.get(explicit_meta, "source_system") ||
          Map.get(ambient_meta, "source_system") ||
          "ash_action"

      actor =
        get_in(cs_ctx, [:private, :actor]) ||
          Map.get(opts_map, :actor)

      actor_meta = extract_actor_meta(actor, ambient_meta)

      doc =
        non_empty_string(fetch_map_opt(override, :doc)) ||
          (ambient && non_empty_string(ambient.doc)) ||
          "#{short_resource_name(resource)}.#{action_name}"

      instant =
        positive_or_zero_int(fetch_map_opt(override, :instant)) ||
          (ambient && ambient.instant) ||
          System.os_time(:millisecond)

      meta =
        ambient_meta
        |> Map.merge(actor_meta)
        |> Map.put("source_system", source_system)
        |> Map.put("action_name", action_name)
        |> Map.merge(explicit_meta)
        |> Map.put_new("actor_id", "system")

      [doc: doc, instant: instant, meta: meta]
    end

    defp extract_xitdb_override(cs_ctx, opts_map) do
      dl_ctx = Map.get(cs_ctx, :data_layer)
      shared_ctx = Map.get(cs_ctx, :shared)

      [
        Map.get(cs_ctx, :xitdb),
        if(is_map(dl_ctx), do: Map.get(dl_ctx, :xitdb)),
        if(is_map(shared_ctx), do: Map.get(shared_ctx, :xitdb)),
        Map.get(opts_map, :xitdb)
      ]
      |> Enum.reduce(%{}, fn
        item, acc when is_map(item) and not is_struct(item) -> Map.merge(acc, item)
        item, acc when is_list(item) -> Map.merge(acc, Map.new(item))
        _, acc -> acc
      end)
    end

    defp extract_explicit_meta(override) when is_map(override) do
      nested_meta =
        case fetch_map_opt(override, :meta) do
          m when is_map(m) and not is_struct(m) -> stringify_meta_map(m)
          l when is_list(l) -> stringify_meta_map(Map.new(l))
          _ -> %{}
        end

      top_fields =
        Enum.reduce(
          [:actor_id, :actor_email, :source_system, :action_name, :workflow_run_id, :reason],
          %{},
          fn key, acc ->
            case fetch_map_opt(override, key) do
              nil -> acc
              val -> Map.put(acc, Atom.to_string(key), stringify_meta_value(val))
            end
          end
        )

      Map.merge(top_fields, nested_meta)
    end

    defp extract_actor_meta(nil, ambient_meta) do
      if Map.has_key?(ambient_meta, "actor_id") do
        %{}
      else
        %{"actor_id" => "system"}
      end
    end

    defp extract_actor_meta(actor, ambient_meta) when is_map(actor) do
      base =
        case Map.get(actor, :id) || Map.get(actor, "id") do
          nil ->
            if Map.has_key?(ambient_meta, "actor_id"), do: %{}, else: %{"actor_id" => "system"}

          id ->
            %{"actor_id" => to_string(id)}
        end

      case Map.get(actor, :email) || Map.get(actor, "email") do
        nil -> base
        email -> Map.put(base, "actor_email", to_string(email))
      end
    end

    defp extract_actor_meta(actor, _ambient_meta) when is_binary(actor) or is_atom(actor) do
      %{"actor_id" => to_string(actor)}
    end

    defp extract_actor_meta(_actor, _ambient_meta), do: %{"actor_id" => "system"}

    defp stringify_meta_map(map) do
      Enum.reduce(map, %{}, fn
        {_k, nil}, acc -> acc
        {k, v}, acc -> Map.put(acc, to_string(k), stringify_meta_value(v))
      end)
    end

    defp stringify_meta_value(v) when is_boolean(v) or is_number(v) or is_binary(v), do: v
    defp stringify_meta_value(v) when is_atom(v), do: Atom.to_string(v)
    defp stringify_meta_value(v), do: to_string(v)

    defp fetch_map_opt(map, key) when is_map(map) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key))
    end

    defp non_empty_string(val) when is_binary(val) do
      if val == "", do: nil, else: val
    end

    defp non_empty_string(_), do: nil

    defp positive_or_zero_int(val) when is_integer(val), do: val
    defp positive_or_zero_int(_), do: nil

    defp short_resource_name(resource) do
      resource
      |> Module.split()
      |> List.last()
    end

    defp load_existing_record(_cursor_root, _resource, nil, _tenant), do: :none

    defp load_existing_record(cursor_root, resource, pk_val, tenant) do
      case Indexer.fetch_cursor(cursor_root, resource, pk_val, tenant) do
        :none ->
          :none

        {:ok, cursor} ->
          case Codec.from_cursor(resource, cursor, tenant) do
            {:ok, record} ->
              if Codec.matches_tenant?(resource, record, tenant), do: {:ok, record}, else: :none

            {:error, _} ->
              :none
          end
      end
    end

    defp finalize_loaded_record(resource, record, tenant) do
      record =
        if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute and tenant != nil do
          tenant_attr = Ash.Resource.Info.multitenancy_attribute(resource)

          if is_nil(Map.get(record, tenant_attr)) do
            Map.put(record, tenant_attr, tenant)
          else
            record
          end
        else
          record
        end

      record = unload_relationships(resource, ensure_resource_struct(resource, record))

      record =
        if Map.has_key?(record, :__meta__) and Code.ensure_loaded?(Ecto) and
             function_exported?(Ecto, :put_meta, 2) do
          apply(Ecto, :put_meta, [record, [state: :loaded]])
        else
          record
        end

      if tenant != nil do
        Ash.Resource.put_metadata(record, :tenant, tenant)
      else
        record
      end
    end

    defp ensure_resource_struct(resource, %mod{} = record) when mod == resource, do: record
    defp ensure_resource_struct(resource, map) when is_map(map), do: struct(resource, map)

    defp unload_relationships(resource, record) do
      empty = struct(resource)

      resource
      |> Ash.Resource.Info.relationships()
      |> Enum.reduce(record, fn rel, acc ->
        Map.put(acc, rel.name, Map.get(empty, rel.name))
      end)
    end

    defp attach_bulk_metadata(record, %Ash.Changeset{} = cs, fallback_idx) do
      case get_in(cs.context, [:bulk_create]) do
        %{index: idx, ref: ref} ->
          Ash.Actions.Helpers.Bulk.put_metadata(record, idx, ref, :bulk_create_index)

        %{index: idx} ->
          Ash.Resource.put_metadata(record, :bulk_create_index, idx)

        _ ->
          Ash.Resource.put_metadata(record, :bulk_create_index, fallback_idx)
      end
    end
  end

  defmodule Xitdb.Ash.Mutator.Sequences do
    @moduledoc false
    # Pure op-staging sequence allocator over `root["meta"]["sequences"][scoped_collection]`.

    alias Xitdb.Ash.Codec
    alias Xitdb.TxCompiler

    @doc """
    Plans primary-key allocation or high-water mark advancement for `record` without
    executing an intermediate `Xitdb.transact/2` commit.

    Returns `{:ok, updated_record, seq_ops, updated_seq_cache}`.
    """
    @spec plan_pk(Xitdb.Cursor.t(), module(), struct() | map(), term(), map()) ::
            {:ok, struct() | map(), [tuple()], map()}
    def plan_pk(%Xitdb.Cursor{} = cursor_root, resource, record, tenant, seq_cache)
        when is_atom(resource) and is_map(record) and is_map(seq_cache) do
      case Ash.Resource.Info.primary_key(resource) do
        [pk_name] ->
          attr = Ash.Resource.Info.attribute(resource, pk_name)
          current_val = Map.get(record, pk_name)
          scoped_col = Codec.scoped_collection(resource, tenant)

          cond do
            integer_attribute?(attr) and is_nil(current_val) and generated_int_pk?(attr) ->
              prev =
                Map.get_lazy(seq_cache, scoped_col, fn ->
                  read_current(cursor_root, scoped_col)
                end)

              allocated = prev + 1

              ops =
                compile_sequence_ops(
                  cursor_root,
                  scoped_col,
                  allocated,
                  Map.has_key?(seq_cache, scoped_col)
                )

              {:ok, Map.put(record, pk_name, allocated), ops,
               Map.put(seq_cache, scoped_col, allocated)}

            integer_attribute?(attr) and is_integer(current_val) ->
              prev =
                Map.get_lazy(seq_cache, scoped_col, fn ->
                  read_current(cursor_root, scoped_col)
                end)

              if current_val > prev do
                ops =
                  compile_sequence_ops(
                    cursor_root,
                    scoped_col,
                    current_val,
                    Map.has_key?(seq_cache, scoped_col)
                  )

                {:ok, record, ops, Map.put(seq_cache, scoped_col, current_val)}
              else
                {:ok, record, [], seq_cache}
              end

            true ->
              {:ok, record, [], seq_cache}
          end

        _other ->
          {:ok, record, [], seq_cache}
      end
    end

    def generated_int_pk?(%Ash.Resource.Attribute{} = attr) do
      Map.get(attr, :generated?, false) == true
    end

    def integer_attribute?(%Ash.Resource.Attribute{type: type, constraints: constraints}) do
      resolved = Ash.Type.get_type(type)

      cond do
        resolved == Ash.Type.Integer ->
          true

        Ash.Type.NewType.new_type?(resolved) ->
          sub = Ash.Type.NewType.subtype_of(resolved)
          sub_c = Ash.Type.NewType.constraints(resolved, constraints)
          integer_attribute?(%Ash.Resource.Attribute{name: :tmp, type: sub, constraints: sub_c})

        true ->
          false
      end
    end

    def read_current(%Xitdb.Cursor{} = root, scoped_collection) do
      with %Xitdb.Cursor{} = meta <- root["meta"],
           %Xitdb.Cursor{} = seqs <- meta["sequences"],
           val when is_integer(val) <- seqs[scoped_collection] do
        val
      else
        _ -> 0
      end
    end

    def compile_sequence_ops(%Xitdb.Cursor{} = root, scoped_collection, value, cached_in_batch?) do
      init_ops =
        if cached_in_batch? do
          []
        else
          meta_cursor = root["meta"]

          seqs_cursor =
            if match?(%Xitdb.Cursor{}, meta_cursor), do: meta_cursor["sequences"], else: nil

          cond do
            is_nil(meta_cursor) ->
              [
                {:init_col, ".meta", "hash_map"},
                {:init_col, ".meta.sequences", "hash_map"}
              ]

            is_nil(seqs_cursor) ->
              [{:init_col, ".meta.sequences", "hash_map"}]

            true ->
              []
          end
        end

      key_step = TxCompiler.format_step(:hash_map, scoped_collection)
      init_ops ++ [{:put, ".meta.sequences" <> key_step, value}]
    end
  end
end
