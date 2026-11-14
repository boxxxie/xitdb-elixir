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
            run_bulk_creates_single_commit(initial_snapshot, resource, stream, tenant)
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
            apply_bulk_updates(initial_snapshot, candidates, resource, scoped_changeset)
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
            apply_bulk_destroys(initial_snapshot, candidates, resource, scoped_changeset)
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

      with {:ok, base_record} <- Ash.Changeset.apply_attributes(changeset),
           {:ok, after_atomics} <- apply_create_atomics(base_record, resource, changeset),
           {:ok, record_with_pk, seq_ops, _seq_map} <-
             Sequences.plan_pk(cursor_root, resource, after_atomics, tenant, %{}),
           :ok <- verify_pk_unused(cursor_root, resource, record_with_pk, tenant, MapSet.new()),
           record <- finalize_loaded_record(resource, record_with_pk, tenant),
           :ok <- verify_atomic_validations(record, record, resource, changeset),
           {:ok, index_ops} <- Indexer.plan_put_ops(cursor_root, resource, nil, record, tenant),
           {:ok, next_snapshot} <- commit_ops({db, moment}, seq_ops ++ index_ops) do
        {:ok, next_snapshot, record}
      end
    end

    defp run_bulk_creates_single_commit({db, moment}, resource, stream, fallback_tenant) do
      cursor_root = Xitdb.as_of(db, moment)

      staged =
        stream
        |> Enum.with_index()
        |> Enum.reduce_while(
          {:ok, [], [], %{}, %{}, MapSet.new(), MapSet.new()},
          fn {%Ash.Changeset{} = raw_cs, idx},
             {:ok, rev_records, ops_chunks, seq_state, idx_batch_state, seen_pks, seen_identities} ->
            cs =
              if is_nil(raw_cs.tenant) and fallback_tenant != nil do
                %Ash.Changeset{raw_cs | tenant: fallback_tenant}
              else
                raw_cs
              end

            tenant = cs.tenant
            scoped_col = Codec.scoped_collection(resource, tenant)

            with {:ok, base_record} <- Ash.Changeset.apply_attributes(cs),
                 {:ok, after_atomics} <- apply_create_atomics(base_record, resource, cs),
                 {:ok, record_with_pk, seq_ops, next_seq_state} <-
                   Sequences.plan_pk(cursor_root, resource, after_atomics, tenant, seq_state),
                 :ok <- verify_pk_unused(cursor_root, resource, record_with_pk, tenant, seen_pks),
                 record <- finalize_loaded_record(resource, record_with_pk, tenant),
                 :ok <- verify_atomic_validations(record, record, resource, cs),
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
                   ) do
              [pk_name | _] = Ash.Resource.Info.primary_key(resource)
              pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
              doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(record, pk_name))
              next_seen_pks = MapSet.put(seen_pks, {scoped_col, doc_id})
              tagged = attach_bulk_metadata(record, cs, idx)

              {:cont,
               {:ok, [tagged | rev_records], [seq_ops ++ index_ops | ops_chunks], next_seq_state,
                next_idx_batch_state, next_seen_pks, next_seen_identities}}
            else
              {:error, _} = err ->
                {:halt, err}
            end
          end
        )

      case staged do
        {:ok, rev_records, ops_chunks, _seq_state, _idx_batch_state, _seen_pks, _seen_identities} ->
          all_ops = ops_chunks |> Enum.reverse() |> List.flatten()

          with {:ok, next_snapshot} <- commit_ops({db, moment}, all_ops) do
            {:ok, next_snapshot, Enum.reverse(rev_records)}
          end

        {:error, _} = err ->
          err
      end
    end

    defp run_bulk_upserts(
           initial_snapshot,
           resource,
           stream,
           upsert_keys,
           identity,
           fallback_tenant,
           opts
         ) do
      stream
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, initial_snapshot, []}, fn {%Ash.Changeset{} = raw_cs, idx},
                                                           {:ok, snap, acc} ->
        cs =
          if is_nil(raw_cs.tenant) and fallback_tenant != nil do
            %Ash.Changeset{raw_cs | tenant: fallback_tenant}
          else
            raw_cs
          end

        case upsert_in_snapshot(snap, resource, cs, upsert_keys, identity, opts) do
          {:ok, next_snap, record} ->
            if Ash.Resource.get_metadata(record, :upsert_skipped) do
              {:cont, {:ok, next_snap, acc}}
            else
              tagged = attach_bulk_metadata(record, cs, idx)
              {:cont, {:ok, next_snap, [tagged | acc]}}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, final_snap, rev_records} -> {:ok, final_snap, Enum.reverse(rev_records)}
        {:error, _} = err -> err
      end
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
                     ),
                   {:ok, next_snapshot} <- commit_ops({db, moment}, seq_ops ++ index_ops) do
                {:ok, next_snapshot, retain_changeset_data_fields(synced_with_seq, changeset)}
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

      with {:ok, candidate_record} <- Ash.Changeset.apply_attributes(changeset) do
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
                       ),
                     {:ok, next_snapshot} <- commit_ops(snapshot, index_ops) do
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
                 cascade_and_delete(snapshot, resource, current_record, tenant, MapSet.new()) do
            {:ok, next_snapshot, current_record}
          else
            :filtered_out ->
              {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

            {:error, _} = err ->
              err
          end
      end
    end

    defp apply_bulk_updates(initial_snapshot, candidates, resource, %Ash.Changeset{} = changeset) do
      tenant = changeset.tenant

      candidates
      |> Enum.reduce_while({:ok, initial_snapshot, []}, fn current_record,
                                                           {:ok, {acc_db, acc_moment} = snap,
                                                            acc_records} ->
        case build_updated_record(current_record, resource, changeset, :all_non_upsert) do
          {:ok, updated_record} ->
            cursor_root = Xitdb.as_of(acc_db, acc_moment)
            final_record = finalize_loaded_record(resource, updated_record, tenant)

            with {:ok, index_ops} <-
                   Indexer.plan_put_ops(
                     cursor_root,
                     resource,
                     current_record,
                     final_record,
                     tenant
                   ),
                 {:ok, next_snap} <- commit_ops(snap, index_ops) do
              tagged =
                Ash.Actions.Helpers.Bulk.put_metadata(
                  final_record,
                  %Ash.Changeset{changeset | data: current_record}
                )

              {:cont, {:ok, next_snap, [tagged | acc_records]}}
            else
              {:error, _} = err ->
                {:halt, err}
            end

          :filtered_out ->
            {:cont, {:ok, snap, acc_records}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, final_snap, rev_records} -> {:ok, final_snap, Enum.reverse(rev_records)}
        {:error, _} = err -> err
      end
    end

    defp apply_bulk_destroys(initial_snapshot, candidates, resource, %Ash.Changeset{} = changeset) do
      tenant = changeset.tenant

      candidates
      |> Enum.reduce_while({:ok, initial_snapshot, []}, fn current_record,
                                                           {:ok, snap, acc_records} ->
        with :ok <- verify_changeset_filter(current_record, changeset, nil),
             :ok <-
               verify_atomic_validations(current_record, current_record, resource, changeset),
             {:ok, next_snap} <-
               cascade_and_delete(snap, resource, current_record, tenant, MapSet.new()) do
          tagged =
            Ash.Actions.Helpers.Bulk.put_metadata(
              current_record,
              %Ash.Changeset{changeset | data: current_record}
            )

          {:cont, {:ok, next_snap, [tagged | acc_records]}}
        else
          :filtered_out ->
            {:cont, {:ok, snap, acc_records}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, final_snap, rev_records} -> {:ok, final_snap, Enum.reverse(rev_records)}
        {:error, _} = err -> err
      end
    end

    # -- Atomic Filter, Expression & Validation Evaluation --

    defp build_updated_record(current_record, resource, %Ash.Changeset{} = changeset, mode) do
      {allowed_attrs, allowed_atomic_set, conflicting_upsert_values} =
        prepare_update_inputs(current_record, resource, changeset, mode)

      with :ok <- verify_changeset_filter(current_record, changeset, conflicting_upsert_values),
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

        case verify_atomic_validations(current_record, post_record, resource, changeset) do
          :ok -> {:ok, post_record}
          {:error, _} = err -> err
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

            update_defaults =
              resource
              |> Ash.Resource.Info.attributes()
              |> Enum.filter(&(&1.update_default != nil))
              |> Enum.map(& &1.name)

            Enum.uniq(explicit ++ update_defaults)

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

    defp verify_changeset_filter(_record, %Ash.Changeset{filter: nil}, _conflicting), do: :ok

    defp verify_changeset_filter(
           _record,
           %Ash.Changeset{filter: %Ash.Filter{expression: expr}},
           _conflicting
         )
         when expr in [nil, true],
         do: :ok

    defp verify_changeset_filter(record, %Ash.Changeset{} = changeset, conflicting_upsert_values) do
      actor = get_in(changeset.context, [:private, :actor])
      record_struct = ensure_resource_struct(changeset.resource, record)

      case Ash.Filter.Runtime.filter_matches(
             changeset.domain,
             [record_struct],
             changeset.filter,
             actor: actor,
             tenant: changeset.tenant,
             authorize?: false,
             conflicting_upsert_values: conflicting_upsert_values
           ) do
        {:ok, [_matched]} -> :ok
        {:ok, []} -> :filtered_out
        {:error, _} = err -> err
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
           %Ash.Changeset{} = changeset
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

        case eval_boolean_condition(resolved_cond, pre_struct, resource, changeset, actor) do
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
           actor
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
                 authorize?: false
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
              batch_token = {scoped_col, identity.name, encoded_key}

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

    defp cascade_and_delete({db, moment} = snapshot, resource, record, tenant, visited) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_attr = Ash.Resource.Info.attribute(resource, pk_name)
      pk_val = Map.fetch!(record, pk_name)
      visit_key = {resource, Codec.encode_pk_doc_id(pk_attr, pk_val)}

      if MapSet.member?(visited, visit_key) do
        {:ok, snapshot}
      else
        next_visited = MapSet.put(visited, visit_key)
        store = Info.store!(resource)
        rules = Store.reverse_fks(store, resource)

        with {:ok, {after_db, after_moment} = snap_after_fks} <-
               apply_reverse_fk_rules({db, moment}, rules, record, tenant, next_visited),
             cursor_root = Xitdb.as_of(after_db, after_moment),
             {:ok, del_ops} <- Indexer.plan_delete_ops(cursor_root, resource, record, tenant) do
          commit_ops(snap_after_fks, del_ops)
        end
      end
    end

    defp apply_reverse_fk_rules(snapshot, [], _record, _tenant, _visited), do: {:ok, snapshot}

    defp apply_reverse_fk_rules(snapshot, rules, parent_record, tenant, visited) do
      Enum.reduce_while(rules, {:ok, snapshot}, fn rule, {:ok, acc_snap} ->
        dest_val = Map.get(parent_record, rule.destination_attribute)

        if is_nil(dest_val) do
          {:cont, {:ok, acc_snap}}
        else
          case apply_single_fk_rule(acc_snap, rule, dest_val, tenant, visited) do
            {:ok, updated_snap} -> {:cont, {:ok, updated_snap}}
            {:error, _} = err -> {:halt, err}
          end
        end
      end)
    end

    defp apply_single_fk_rule(snapshot, %{on_delete: :nothing}, _dest_val, _tenant, _visited) do
      {:ok, snapshot}
    end

    defp apply_single_fk_rule(
           {db, moment} = snapshot,
           %{on_delete: :restrict} = rule,
           dest_val,
           tenant,
           _visited
         ) do
      cursor_root = Xitdb.as_of(db, moment)
      child_count = count_referencing_children(cursor_root, rule, dest_val, tenant)

      if child_count > 0 do
        {:error,
         InvalidChanges.exception(
           fields: [rule.destination_attribute],
           message: "cannot be destroyed while referenced by #{inspect(rule.source_collection)}"
         )}
      else
        {:ok, snapshot}
      end
    end

    defp apply_single_fk_rule(
           {db, moment} = snapshot,
           %{on_delete: :nilify} = rule,
           dest_val,
           tenant,
           _visited
         ) do
      cursor_root = Xitdb.as_of(db, moment)
      children = load_referencing_children(cursor_root, rule, dest_val, tenant)

      Enum.reduce_while(children, {:ok, snapshot}, fn child,
                                                      {:ok, {cur_db, cur_moment} = cur_snap} ->
        nilified = Map.put(child, rule.source_attribute, nil)
        cur_root = Xitdb.as_of(cur_db, cur_moment)

        with {:ok, ops} <-
               Indexer.plan_put_ops(cur_root, rule.source_resource, child, nilified, tenant),
             {:ok, next_snap} <- commit_ops(cur_snap, ops) do
          {:cont, {:ok, next_snap}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp apply_single_fk_rule(
           {db, moment} = snapshot,
           %{on_delete: :delete} = rule,
           dest_val,
           tenant,
           visited
         ) do
      cursor_root = Xitdb.as_of(db, moment)
      children = load_referencing_children(cursor_root, rule, dest_val, tenant)

      Enum.reduce_while(children, {:ok, snapshot}, fn child, {:ok, cur_snap} ->
        case cascade_and_delete(cur_snap, rule.source_resource, child, tenant, visited) do
          {:ok, next_snap} -> {:cont, {:ok, next_snap}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp count_referencing_children(
           cursor_root,
           %{source_resource: res, source_attribute: fk} = rule,
           dest_val,
           tenant
         ) do
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
          length(load_referencing_children(cursor_root, rule, dest_val, tenant))
      end
    end

    defp load_referencing_children(
           cursor_root,
           %{source_resource: res, source_attribute: fk} = rule,
           dest_val,
           tenant
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
          case Info.indexes_for_field(res, fk) do
            [%{fields: [^fk]} = idx | _] ->
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

            _ ->
              Indexer.all_cursors(cursor_root, res, tenant)
          end
        end

      attr = Ash.Resource.Info.attribute(res, fk)

      cursors
      |> Enum.flat_map(fn {_doc_id, cursor} ->
        case Codec.from_cursor(res, cursor, tenant) do
          {:ok, child} ->
            if values_equal?(attr, Map.get(child, fk), dest_val), do: [child], else: []

          {:error, _} ->
            []
        end
      end)
    end

    defp values_equal?(nil, left, right), do: left == right

    defp values_equal?(%Ash.Resource.Attribute{type: type}, left, right) do
      Ash.Type.equal?(type, left, right)
    end

    # -- Commit, Hydration & Metadata Helpers --

    defp commit_ops({db, moment}, []), do: {:ok, {db, moment}}

    defp commit_ops({db, moment}, ops) when is_list(ops) do
      case Xitdb.transact_ops(db, ops, base_moment: moment) do
        {:ok, next_db} -> {:ok, {next_db, Xitdb.moment_count(next_db) - 1}}
        {:error, _} = err -> err
      end
    end

    defp load_existing_record(_cursor_root, _resource, nil, _tenant), do: :none

    defp load_existing_record(cursor_root, resource, pk_val, tenant) do
      case Indexer.fetch_cursor(cursor_root, resource, pk_val, tenant) do
        :none ->
          :none

        {:ok, cursor} ->
          case Codec.from_cursor(resource, cursor, tenant) do
            {:ok, record} ->
              if matches_tenant?(resource, record, tenant), do: {:ok, record}, else: :none

            {:error, _} ->
              :none
          end
      end
    end

    defp matches_tenant?(_resource, _record, nil), do: true

    defp matches_tenant?(resource, record, tenant) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
        tenant_attr = Ash.Resource.Info.multitenancy_attribute(resource)
        Map.get(record, tenant_attr) == tenant
      else
        true
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

    defp retain_changeset_data_fields(record, %Ash.Changeset{data: %struct_mod{} = data}) do
      if struct_mod == record.__struct__ do
        attr_names = Enum.map(Ash.Resource.Info.attributes(struct_mod), & &1.name)
        take = [:__metadata__, :__meta__ | attr_names]
        Map.merge(data, Map.take(record, take))
      else
        record
      end
    end

    defp retain_changeset_data_fields(record, _changeset), do: record

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
      Map.get(attr, :generated?, false) or attr.allow_nil? == false
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
