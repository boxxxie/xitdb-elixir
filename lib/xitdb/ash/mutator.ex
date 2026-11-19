if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Mutator do
    @moduledoc """
    Transactional write engine (`create`, `bulk_create`, `update`, `update_query`,
    `upsert`, `destroy`, `destroy_query`), staged monotonic integer sequence allocator,
    Ash 3 atomic policy/validation evaluator, and same-store `on_delete` cascade enforcer.
    """

    alias Ash.Error.Changes.{InvalidAttribute, InvalidChanges, StaleRecord}
    alias Xitdb.Ash.{Codec, Indexer, Info, Query, Store}
    alias Xitdb.Ash.Mutator.Sequences

    @type snapshot :: {Xitdb.t(), non_neg_integer()}

    # -- Public DataLayer Mutation Entrypoints --

    @doc """
    Inserts a new entity cursor in a single atomic `Xitdb.transact_ops/3` commit,
    allocating `meta.sequences[scoped_collection]` when `:id` is `nil` on generated
    integer primary keys and rejecting duplicate primary keys or unique identities.
    """
    @spec create(module(), Ash.Changeset.t()) :: {:ok, struct()} | {:error, term()}
    def create(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      Store.mutate(store, fn snapshot ->
        create_in_snapshot(snapshot, resource, changeset)
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
          if return_records?, do: {:ok, records}, else: :ok

        {:error, _} = err ->
          err
      end
    end

    @doc """
    Atomically updates an existing entity in a single `Xitdb.transact_ops/3` commit inside
    the store writer lease, enforcing `changeset.filter` (row-level policies + optimistic locks),
    pre-update `changeset.atomics`, and `changeset.atomic_validations`.
    """
    @spec update(module(), Ash.Changeset.t()) :: {:ok, struct()} | {:error, term()}
    def update(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      Store.mutate(store, fn snapshot ->
        update_in_snapshot(snapshot, resource, changeset)
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

      result =
        Store.mutate(store, fn {db, moment} = initial_snapshot ->
          cursor_root = Xitdb.as_of(db, moment)

          with {:ok, candidates} <- Query.execute(cursor_root, scoped_query, resource) do
            apply_bulk_updates(initial_snapshot, candidates, resource, scoped_changeset, opts)
          end
        end)

      case result do
        {:ok, updated_records} ->
          if return_records?, do: {:ok, updated_records}, else: :ok

        {:error, _} = err ->
          err
      end
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

      Store.mutate(store, fn snapshot ->
        upsert_in_snapshot(snapshot, resource, changeset, keys, identity, %{})
      end)
    end

    @doc """
    Atomically destroys an entity after verifying `changeset.filter`, `changeset.atomic_validations`,
    and incoming same-store foreign-key `on_delete` rules (`:restrict`, `:nilify`, `:delete`).
    """
    @spec destroy(module(), Ash.Changeset.t()) :: :ok | {:error, term()}
    def destroy(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      case Store.mutate(store, fn snapshot ->
             destroy_in_snapshot(snapshot, resource, changeset)
           end) do
        {:ok, _deleted_record} -> :ok
        {:error, _} = err -> err
      end
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

      result =
        Store.mutate(store, fn {db, moment} = initial_snapshot ->
          cursor_root = Xitdb.as_of(db, moment)

          with {:ok, candidates} <- Query.execute(cursor_root, scoped_query, resource) do
            apply_bulk_destroys(initial_snapshot, candidates, resource, scoped_changeset, opts)
          end
        end)

      case result do
        {:ok, destroyed_records} ->
          if return_records?, do: {:ok, destroyed_records}, else: :ok

        {:error, _} = err ->
          err
      end
    end

    # -- Internal Snapshot Create / Bulk Create / Update / Upsert / Destroy --

    defp create_in_snapshot({db, moment}, resource, %Ash.Changeset{} = changeset) do
      cursor_root = Xitdb.as_of(db, moment)
      tenant = changeset.tenant

      with {:ok, after_atomics} <- apply_create_record(resource, changeset),
           {:ok, record_with_pk, seq_ops, _seq_map} <-
             Sequences.plan_pk(cursor_root, resource, after_atomics, tenant, %{}),
           :ok <- verify_pk_unused(cursor_root, resource, record_with_pk, tenant, MapSet.new()),
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
                 :ok <- verify_pk_unused(cursor_root, resource, record_with_pk, tenant, seen_pks),
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
                     idx_batch_state
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
      eval_opts = [
        record: record_struct,
        resource: resource,
        domain: changeset.domain,
        actor: actor,
        tenant: changeset.tenant,
        context: changeset.context,
        unknown_on_unknown_refs?: true
      ]

      case Ash.Expr.eval(expr, eval_opts) do
        {:ok, truthy} when truthy not in [false, nil] ->
          {:ok, true}

        {:ok, _false_or_nil} ->
          {:ok, false}

        :unknown ->
          # Relational / cross-store expressions (e.g. `exists(organization.profiles, ...)`)
          # return `:unknown` from pure `Ash.Expr.eval/2`. NEVER map `:unknown` to `{:ok, nil}`!
          case Ash.Filter.Runtime.filter_matches(
                 changeset.domain,
                 [record_struct],
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

    defp eval_value_expr(
           expr,
           record,
           resource,
           %Ash.Changeset{} = changeset,
           actor,
           conflicting_upsert_values
         ) do
      record_struct = ensure_resource_struct(resource, record)

      eval_opts = [
        record: record_struct,
        resource: resource,
        domain: changeset.domain,
        actor: actor,
        tenant: changeset.tenant,
        context: changeset.context,
        unknown_on_unknown_refs?: true
      ]

      case Ash.Expr.eval(expr, eval_opts) do
        {:ok, value} ->
          {:ok, value}

        :unknown ->
          hydrate_ctx = %{
            resource: resource,
            public?: false,
            conflicting_upsert_values: conflicting_upsert_values
          }

          with {:ok, hydrated} <- Ash.Filter.hydrate_refs(expr, hydrate_ctx) do
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

        {:error, _} = err ->
          err
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

    defp verify_pk_unused(cursor_root, resource, record, tenant, seen_pks) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_val = Map.get(record, pk_name)

      if is_nil(pk_val) do
        {:error, InvalidChanges.exception(fields: [pk_name], message: "is required")}
      else
        pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
        doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)
        scoped_col = Codec.scoped_collection(resource, tenant)

        if MapSet.member?(seen_pks, {scoped_col, doc_id}) do
          {:error, InvalidChanges.exception(fields: [pk_name], message: "has already been taken")}
        else
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

    defp commit_ops({db, moment}, [], _commit_opts), do: {:ok, {db, moment}}

    defp commit_ops({db, moment}, ops, commit_opts)
         when is_list(ops) and is_list(commit_opts) do
      tx_opts = Keyword.put(commit_opts, :base_moment, moment)

      case Xitdb.transact_ops_with_moment(db, ops, tx_opts) do
        {:ok, next_db, next_moment} -> {:ok, {next_db, next_moment}}
        {:error, _} = err -> err
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

    defp generated_int_pk?(%Ash.Resource.Attribute{} = attr) do
      Map.get(attr, :generated?, false) == true
    end

    defp integer_attribute?(%Ash.Resource.Attribute{type: type, constraints: constraints}) do
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

    defp read_current(%Xitdb.Cursor{} = root, scoped_collection) do
      with %Xitdb.Cursor{} = meta <- root["meta"],
           %Xitdb.Cursor{} = seqs <- meta["sequences"],
           val when is_integer(val) <- seqs[scoped_collection] do
        val
      else
        _ -> 0
      end
    end

    defp compile_sequence_ops(%Xitdb.Cursor{} = root, scoped_collection, value, cached_in_batch?) do
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
