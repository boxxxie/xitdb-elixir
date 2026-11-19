if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Indexer do
    @moduledoc """
    Maintains and queries entity cursors, unique `identities` (with partial `where` filters),
    secondary `:sorted_map` B+Tree indexes, and transactional BM25 `idx.search` postings for
    `Xitdb.Ash.DataLayer`.
    """

    alias Ash.Error.Changes.InvalidChanges
    alias Xitdb.Ash.{Codec, Info, Search, Store}
    alias Xitdb.Ash.Indexer.Storage

    @parent_slot "_parent"
    @search_weight_scale 100

    @type bound :: {:inclusive | :exclusive, term()} | :unbounded
    @type range_spec :: %{
            optional(:prefix) => [term()],
            optional(:min) => bound(),
            optional(:max) => bound()
          }

    # -- Single-Commit Operation Staging & Transactional Write Helpers --

    @type batch_state :: map()

    @doc """
    Plans all low-level `Xitdb.transact_ops/3` tuples for writing `new_record` (and diffing
    `old_record` on update) across entity cursors, unique `identities`, secondary `:sorted_map`
    B+Trees, and BM25 `idx.search` postings—without committing yet.
    """
    @spec plan_put_ops(term(), module(), struct() | nil, struct(), term()) ::
            {:ok, [tuple()]} | {:error, Exception.t()}
    def plan_put_ops(db_or_cursor, resource, old_record, %_{} = new_record, tenant \\ nil)
        when is_atom(resource) do
      case plan_put_ops_batched(db_or_cursor, resource, old_record, new_record, tenant, %{}) do
        {:ok, ops, _batch_state} -> {:ok, ops}
        {:error, _} = err -> err
      end
    end

    @doc """
    Batch-aware variant of `plan_put_ops/5` that threads `batch_state` across multi-row
    `bulk_create` streams so BM25 `doc_count`/`total_len` and secondary set memberships
    accumulate accurately against a single pre-batch `cursor_root`.
    """
    @spec plan_put_ops_batched(
            term(),
            module(),
            struct() | nil,
            struct(),
            term(),
            batch_state()
          ) :: {:ok, [tuple()], batch_state()} | {:error, Exception.t()}
    def plan_put_ops_batched(
          db_or_cursor,
          resource,
          old_record,
          %_{} = new_record,
          tenant,
          batch_state
        )
        when is_atom(resource) and is_map(batch_state) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)
      doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(new_record, pk_attr.name))

      with {:ok, {effective_old, pre_evict_ops, batch_after_evict}} <-
             maybe_resolve_existing_one_nested(
               db_or_cursor,
               resource,
               old_record,
               new_record,
               tenant,
               batch_state
             ),
           {:ok, cursor_map} <- Codec.to_cursor_map(resource, new_record),
           {:ok, identity_ops} <-
             plan_identity_ops(
               db_or_cursor,
               resource,
               effective_old,
               new_record,
               tenant,
               batch_after_evict
             ),
           {:ok, locator_plan} <-
             plan_entity_location(db_or_cursor, resource, effective_old, new_record, tenant) do
        secondary_ops = plan_secondary_ops(resource, effective_old, new_record)
        removed_fields = removed_attribute_fields(resource, effective_old, cursor_map)

        {entity_and_idx_ops, batch_after_idx} =
          Storage.compile_put_ops(
            db_or_cursor,
            collection,
            cursor_map,
            locator_plan,
            identity_ops,
            secondary_ops,
            batch_after_evict,
            removed_fields
          )

        {search_ops, batch_after_search} =
          plan_search_ops(db_or_cursor, resource, collection, new_record, nil, batch_after_idx)

        next_batch =
          batch_after_search
          |> Map.delete({:deleted_doc, collection, doc_id})
          |> track_nested_one_put(resource, effective_old, new_record, tenant)

        {:ok, pre_evict_ops ++ entity_and_idx_ops ++ search_ops, next_batch}
      end
    end

    @doc """
    Plans all low-level `Xitdb.transact_ops/3` tuples for deleting `record`, including
    unique, secondary, and BM25 search index cleanup.
    """
    @spec plan_delete_ops(term(), module(), struct(), term()) :: {:ok, [tuple()]}
    def plan_delete_ops(db_or_cursor, resource, %_{} = record, tenant \\ nil)
        when is_atom(resource) do
      {:ok, ops, _batch_state} =
        plan_delete_ops_batched(db_or_cursor, resource, record, tenant, %{})

      {:ok, ops}
    end

    @spec plan_delete_ops_batched(term(), module(), struct(), term(), batch_state()) ::
            {:ok, [tuple()], batch_state()}
    def plan_delete_ops_batched(db_or_cursor, resource, %_{} = record, tenant, batch_state)
        when is_atom(resource) and is_map(batch_state) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)
      pk_val = Map.fetch!(record, pk_attr.name)
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)
      deleted_key = {:deleted_doc, collection, doc_id}

      if Map.has_key?(batch_state, deleted_key) do
        {:ok, [], batch_state}
      else
        batch_state = Map.put(batch_state, deleted_key, true)

        {child_ops, batch_after_children} =
          plan_purge_nested_children_ops(db_or_cursor, resource, pk_val, tenant, batch_state)

        {:ok, identity_ops} =
          plan_identity_ops(db_or_cursor, resource, record, nil, tenant, batch_after_children)

        secondary_ops = plan_secondary_ops(resource, record, nil)
        delete_location = build_delete_location(resource, record, pk_attr, pk_val, doc_id, tenant)

        {own_delete_ops, batch_after_idx} =
          Storage.compile_delete_ops(
            db_or_cursor,
            collection,
            delete_location,
            identity_ops,
            secondary_ops,
            batch_after_children
          )

        {search_ops, batch_after_search} =
          plan_search_ops(db_or_cursor, resource, collection, nil, doc_id, batch_after_idx)

        next_batch = track_nested_one_delete(batch_after_search, resource, record, tenant)

        {:ok, child_ops ++ own_delete_ops ++ search_ops, next_batch}
      end
    end

    @doc """
    Commits `new_record` (and diffs `old_record` when updating) in a single atomic
    `Xitdb.transact_ops/3` commit on `{db, moment}` (or `%Xitdb{}`).
    """
    @spec put_record(
            {Xitdb.t(), non_neg_integer()} | Xitdb.t(),
            module(),
            struct() | nil,
            struct(),
            term()
          ) :: {:ok, {Xitdb.t(), non_neg_integer()} | Xitdb.t()} | {:error, Exception.t()}
    def put_record(snapshot_or_db, resource, old_record, new_record, tenant \\ nil)

    def put_record({%Xitdb{} = db, moment}, resource, old_record, %_{} = new_record, tenant)
        when is_atom(resource) and is_integer(moment) do
      cursor_root = Xitdb.as_of(db, moment)
      tx_opts = reindex_tx_opts("put_record", resource, base_moment: moment)

      with {:ok, ops} <- plan_put_ops(cursor_root, resource, old_record, new_record, tenant),
           {:ok, next_db, next_moment} <-
             Xitdb.transact_ops_with_moment(db, ops, tx_opts) do
        {:ok, {next_db, next_moment}}
      end
    end

    def put_record(%Xitdb{} = db, resource, old_record, %_{} = new_record, tenant)
        when is_atom(resource) do
      tx_opts = reindex_tx_opts("put_record", resource)

      with {:ok, ops} <- plan_put_ops(db, resource, old_record, new_record, tenant),
           {:ok, next_db} <- Xitdb.transact_ops(db, ops, tx_opts) do
        {:ok, next_db}
      end
    end

    @doc """
    Deletes `record` and all of its secondary, identity, and search indexes in a single atomic
    `Xitdb.transact_ops/3` commit.
    """
    @spec delete_record(
            {Xitdb.t(), non_neg_integer()} | Xitdb.t(),
            module(),
            struct(),
            term()
          ) :: {:ok, {Xitdb.t(), non_neg_integer()} | Xitdb.t()}
    def delete_record(snapshot_or_db, resource, record, tenant \\ nil)

    def delete_record({%Xitdb{} = db, moment}, resource, %_{} = record, tenant)
        when is_atom(resource) and is_integer(moment) do
      cursor_root = Xitdb.as_of(db, moment)
      {:ok, ops} = plan_delete_ops(cursor_root, resource, record, tenant)
      tx_opts = reindex_tx_opts("delete_record", resource, base_moment: moment)
      {:ok, next_db, next_moment} = Xitdb.transact_ops_with_moment(db, ops, tx_opts)
      {:ok, {next_db, next_moment}}
    end

    def delete_record(%Xitdb{} = db, resource, %_{} = record, tenant) when is_atom(resource) do
      {:ok, ops} = plan_delete_ops(db, resource, record, tenant)
      tx_opts = reindex_tx_opts("delete_record", resource)
      {:ok, next_db} = Xitdb.transact_ops(db, ops, tx_opts)
      {:ok, next_db}
    end

    defp reindex_tx_opts(op_name, resource, extra \\ []) do
      ctx = Xitdb.current_tx_context()

      doc =
        case ctx && ctx.doc do
          d when is_binary(d) and d != "" -> d
          _ -> "#{op_name} #{resource |> Module.split() |> List.last()}"
        end

      instant = (ctx && ctx.instant) || System.os_time(:millisecond)

      meta =
        %{
          "source_system" => "xitdb_indexer",
          "action_name" => "reindex",
          "actor_id" => "system"
        }
        |> Map.merge((ctx && ctx.meta) || %{})

      Keyword.merge([doc: doc, instant: instant, meta: meta], extra)
    end

    # -- Point, Identity & B+Tree Read Operations --

    @doc """
    Fetches a single raw entity cursor by primary key in `O(1)` for top-level collections,
    or via `_parent` locator inside a `nested_in` parent subtree.
    """
    @spec fetch_cursor(term(), module(), term(), term()) :: {:ok, term()} | :none
    def fetch_cursor(db_or_cursor, resource, pk_value, tenant \\ nil)
    def fetch_cursor(_db_or_cursor, _resource, nil, _tenant), do: :none

    def fetch_cursor(db_or_cursor, resource, pk_value, tenant) when is_atom(resource) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_value)

      case resolve_nested_spec(resource) do
        nil ->
          Storage.fetch_top_level_cursor(db_or_cursor, collection, doc_id)

        nested ->
          pk_key = Codec.encode_scalar_key(pk_attr, pk_value)
          parent_col_str = resolve_parent_collection(nested, tenant, resource)

          with {:ok, parent_doc_id} <-
                 Storage.lookup_unique(db_or_cursor, collection, @parent_slot, pk_key),
               {:ok, cursor} <-
                 Storage.fetch_nested_cursor(
                   db_or_cursor,
                   parent_col_str,
                   parent_doc_id,
                   nested.path,
                   nested.cardinality,
                   doc_id
                 ),
               true <- cursor_matches_doc_id?(cursor, pk_attr, doc_id) do
            {:ok, cursor}
          else
            _ -> :none
          end
      end
    end

    @doc """
    Returns all `{doc_id, cursor}` pairs for a top-level collection or across deduplicated
    `_parent` entries of a `nested_in` collection.
    """
    @spec all_cursors(term(), module(), term()) :: [{String.t(), term()}]
    def all_cursors(db_or_cursor, resource, tenant \\ nil) when is_atom(resource) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)

      case resolve_nested_spec(resource) do
        nil ->
          Storage.list_top_level_cursors(db_or_cursor, collection)

        nested ->
          parent_col_str = resolve_parent_collection(nested, tenant, resource)

          db_or_cursor
          |> Storage.list_unique_entries(collection, @parent_slot)
          |> Stream.map(&elem(&1, 1))
          |> Stream.uniq()
          |> Enum.flat_map(fn parent_doc_id ->
            Storage.list_nested_cursors_for_parent(
              db_or_cursor,
              parent_col_str,
              parent_doc_id,
              nested.path,
              nested.cardinality,
              pk_attr
            )
          end)
      end
    end

    @doc """
    Jumps directly to `root[parent_col][parent_id][path]` in `O(1)` when filtering a
    `nested_in` resource by its parent foreign key (`event_id == ^eid`).
    """
    @spec nested_cursors_for_parent(term(), module(), term(), term()) :: [{String.t(), term()}]
    def nested_cursors_for_parent(db_or_cursor, resource, parent_id, tenant \\ nil)
        when is_atom(resource) do
      case resolve_nested_spec(resource) do
        nil ->
          []

        nested ->
          pk_attr = pk_attribute(resource)
          parent_col_str = resolve_parent_collection(nested, tenant, resource)
          parent_doc_id = encode_parent_doc_id(resource, nested, parent_id)

          Storage.list_nested_cursors_for_parent(
            db_or_cursor,
            parent_col_str,
            parent_doc_id,
            nested.path,
            nested.cardinality,
            pk_attr
          )
      end
    end

    @doc """
    Resolves an existing entity's canonical `doc_id` string by `Ash.Resource.Identity` in `O(log N)`.
    """
    @spec lookup_by_identity(term(), module(), Ash.Resource.Identity.t(), map(), term()) ::
            {:ok, String.t()} | :none
    def lookup_by_identity(db_or_cursor, resource, identity, key_map, tenant \\ nil)
        when is_atom(resource) and is_map(key_map) do
      case Codec.encode_identity_key(resource, identity, key_map, tenant) do
        :skip ->
          :none

        {:ok, encoded_key} ->
          id_col = identity_collection(resource, identity, tenant)

          case Storage.lookup_unique(
                 db_or_cursor,
                 id_col,
                 identity_slot_name(identity.name),
                 encoded_key
               ) do
            {:ok, stored_val} ->
              unpack_identity_lookup(resource, identity, tenant, stored_val)

            :none ->
              :none
          end
      end
    end

    @doc """
    Returns the `MapSet` of matching `doc_id` strings for an exact secondary index match in `O(log N)`.
    """
    @spec lookup_secondary_eq(term(), module(), map(), [term()], term()) :: MapSet.t(String.t())
    def lookup_secondary_eq(
          db_or_cursor,
          resource,
          %{fields: fields} = index_spec,
          values,
          tenant \\ nil
        )
        when is_atom(resource) and is_list(values) do
      collection = Codec.scoped_collection(resource, tenant)
      attrs = Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
      encoded_key = Codec.encode_index_key(attrs, values)
      slot = index_slot_name(index_spec)

      db_or_cursor
      |> Storage.lookup_set(collection, slot, encoded_key)
      |> MapSet.new()
    end

    @doc """
    Returns the `O(log N)` cardinality of matching child records for `:restrict` FK checks
    and indexed count shortcuts without materializing structs.
    """
    @spec count_by_attribute(term(), module(), atom(), term(), term()) :: non_neg_integer()
    def count_by_attribute(db_or_cursor, resource, field, value, tenant \\ nil)
        when is_atom(resource) and is_atom(field) do
      collection = Codec.scoped_collection(resource, tenant)
      attr = Ash.Resource.Info.attribute(resource, field)
      encoded_key = Codec.encode_index_key([attr], [value])

      slot =
        case resource |> Info.indexes_for_field(field) |> Enum.find(&(&1.fields == [field])) do
          nil -> "attr_#{field}"
          index_spec -> index_slot_name(index_spec)
        end

      Storage.count_set(db_or_cursor, collection, slot, encoded_key)
    end

    @doc """
    Scans a `:sorted_map` secondary index over `[min, max]` bounds (optionally scoped to a
    composite `prefix` tuple) and returns the union `MapSet` of `doc_id` strings.
    """
    @spec scan_secondary_range(term(), module(), map(), range_spec(), term()) ::
            MapSet.t(String.t())
    def scan_secondary_range(
          db_or_cursor,
          resource,
          %{fields: fields} = index_spec,
          range_spec,
          tenant \\ nil
        )
        when is_atom(resource) and is_map(range_spec) do
      collection = Codec.scoped_collection(resource, tenant)
      attrs = Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
      prefix_vals = Map.get(range_spec, :prefix, [])
      range_attr = Enum.at(attrs, length(prefix_vals))

      prefix_bin =
        if prefix_vals == [] do
          <<>>
        else
          Codec.encode_index_prefix(attrs, prefix_vals)
        end

      min_spec = Map.get(range_spec, :min, :unbounded)
      max_spec = Map.get(range_spec, :max, :unbounded)
      has_range_bound? = min_spec != :unbounded or max_spec != :unbounded

      {start_key, min_pred} =
        build_lower_bound(
          attrs,
          prefix_vals,
          prefix_bin,
          range_attr,
          min_spec,
          has_range_bound?
        )

      max_pred =
        build_upper_bound(
          attrs,
          prefix_vals,
          prefix_bin,
          range_attr,
          max_spec
        )

      db_or_cursor
      |> Storage.stream_index_from(collection, index_slot_name(index_spec), start_key)
      |> Stream.take_while(fn {key, _ids} ->
        binary_starts_with?(key, prefix_bin) and max_pred.(key)
      end)
      |> Enum.reduce(MapSet.new(), fn {key, ids}, acc ->
        if (has_range_bound? and not non_null_at_offset?(key, byte_size(prefix_bin))) or
             not min_pred.(key) do
          acc
        else
          Enum.reduce(ids, acc, &MapSet.put(&2, &1))
        end
      end)
    end

    @doc """
    Returns the canonical slot name under `idx.<collection>` for a `%Xitdb.Ash.Index{}`.
    """
    @spec index_slot_name(map()) :: String.t()
    def index_slot_name(%{name: name}) when is_atom(name) and not is_nil(name) do
      Atom.to_string(name)
    end

    def index_slot_name(%{name: name}) when is_binary(name) and name != "", do: name
    def index_slot_name(%{fields: [single_field]}), do: "attr_#{single_field}"

    def index_slot_name(%{fields: fields}) when is_list(fields) do
      "idx_" <> Enum.map_join(fields, "_", &Atom.to_string/1)
    end

    @doc """
    Returns the canonical slot name under `idx.<collection>` for an `Ash.Resource.Identity`.
    """
    @spec identity_slot_name(atom()) :: String.t()
    def identity_slot_name(name) when is_atom(name), do: "id_#{name}"

    # -- Internal Planning & Search Diffing Helpers (Flat Wave 2) --

    defp plan_entity_location(db_or_cursor, resource, old_record, new_record, tenant) do
      pk_attr = pk_attribute(resource)
      pk_val = Map.fetch!(new_record, pk_attr.name)
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)

      case resolve_nested_spec(resource) do
        nil ->
          {:ok, {:top_level, doc_id}}

        nested ->
          fk_attr = nested.foreign_key
          new_parent_val = Map.get(new_record, fk_attr)

          if is_nil(new_parent_val) do
            {:error,
             InvalidChanges.exception(
               fields: [fk_attr],
               message: "is required for nested Xitdb resource"
             )}
          else
            parent_col_str = resolve_parent_collection(nested, tenant, resource)
            new_parent_doc_id = encode_parent_doc_id(resource, nested, new_parent_val)

            case Storage.fetch_top_level_cursor(db_or_cursor, parent_col_str, new_parent_doc_id) do
              :none ->
                {:error,
                 InvalidChanges.exception(
                   fields: [fk_attr],
                   message: "does not exist"
                 )}

              {:ok, _parent_cursor} ->
                old_parent_doc_id =
                  case old_record do
                    nil ->
                      nil

                    prev ->
                      prev
                      |> Map.get(fk_attr)
                      |> then(&maybe_encode_parent_doc_id(resource, nested, &1))
                  end

                pk_key = Codec.encode_scalar_key(pk_attr, pk_val)

                {:ok,
                 {:nested,
                  %{
                    parent_collection: parent_col_str,
                    old_parent_doc_id: old_parent_doc_id,
                    new_parent_doc_id: new_parent_doc_id,
                    path: nested.path,
                    cardinality: nested.cardinality,
                    doc_id: doc_id,
                    pk_key: pk_key
                  }}}
            end
          end
      end
    end

    defp build_delete_location(resource, record, pk_attr, pk_val, doc_id, tenant) do
      case resolve_nested_spec(resource) do
        nil ->
          {:top_level, doc_id}

        nested ->
          parent_doc_id =
            record
            |> Map.get(nested.foreign_key)
            |> then(&maybe_encode_parent_doc_id(resource, nested, &1))

          {:nested,
           %{
             parent_collection: resolve_parent_collection(nested, tenant, resource),
             parent_doc_id: parent_doc_id,
             path: nested.path,
             cardinality: nested.cardinality,
             doc_id: doc_id,
             pk_key: Codec.encode_scalar_key(pk_attr, pk_val)
           }}
      end
    end

    defp resolve_parent_resource(resource, %{foreign_key: fk_attr}) do
      case Enum.find(
             Ash.Resource.Info.relationships(resource),
             &(&1.type == :belongs_to and &1.source_attribute == fk_attr)
           ) do
        %{destination: dest} when is_atom(dest) -> dest
        _ -> nil
      end
    end

    defp encode_parent_doc_id(resource, nested, val) do
      case resolve_parent_resource(resource, nested) do
        parent_res when is_atom(parent_res) and not is_nil(parent_res) ->
          Codec.encode_pk_doc_id(pk_attribute(parent_res), val)

        nil ->
          Codec.encode_doc_id(val)
      end
    end

    defp maybe_encode_parent_doc_id(_resource, _nested, nil), do: nil

    defp maybe_encode_parent_doc_id(resource, nested, val),
      do: encode_parent_doc_id(resource, nested, val)

    defp maybe_resolve_existing_one_nested(
           db_or_cursor,
           resource,
           old_record,
           new_record,
           tenant,
           batch_state
         ) do
      case resolve_nested_spec(resource) do
        %{cardinality: :one, foreign_key: fk_attr, path: path} = nested ->
          new_parent_val = Map.get(new_record, fk_attr)
          old_parent_val = if old_record, do: Map.get(old_record, fk_attr), else: nil

          if not is_nil(new_parent_val) and
               (old_record == nil or old_parent_val != new_parent_val) do
            collection = Codec.scoped_collection(resource, tenant)
            pk_attr = pk_attribute(resource)
            parent_col_str = resolve_parent_collection(nested, tenant, resource)
            new_parent_doc_id = encode_parent_doc_id(resource, nested, new_parent_val)
            batch_key = {:nested_one_record, parent_col_str, new_parent_doc_id, path}

            existing_res =
              case Map.fetch(batch_state, batch_key) do
                {:ok, :deleted} ->
                  :none

                {:ok, staged_rec} ->
                  {:ok, staged_rec}

                :error ->
                  doc_id = Codec.encode_pk_doc_id(pk_attr, Map.fetch!(new_record, pk_attr.name))

                  case Storage.fetch_nested_cursor(
                         db_or_cursor,
                         parent_col_str,
                         new_parent_doc_id,
                         path,
                         :one,
                         doc_id
                       ) do
                    {:ok, existing_cursor} ->
                      case Codec.from_cursor(resource, existing_cursor, tenant) do
                        {:ok, existing_old} ->
                          existing_doc_id =
                            Codec.encode_pk_doc_id(
                              pk_attr,
                              Map.fetch!(existing_old, pk_attr.name)
                            )

                          if Map.has_key?(
                               batch_state,
                               {:deleted_doc, collection, existing_doc_id}
                             ) do
                            :none
                          else
                            {:ok, existing_old}
                          end

                        _ ->
                          :none
                      end

                    :none ->
                      :none
                  end
              end

            case existing_res do
              :none ->
                {:ok, {old_record, [], batch_state}}

              {:ok, existing_old} ->
                if old_record == nil and
                     Map.get(existing_old, pk_attr.name) == Map.get(new_record, pk_attr.name) do
                  {:ok, {existing_old, [], batch_state}}
                else
                  {:ok, evict_ops, next_batch} =
                    plan_delete_ops_batched(
                      db_or_cursor,
                      resource,
                      existing_old,
                      tenant,
                      batch_state
                    )

                  {:ok, {old_record, evict_ops, next_batch}}
                end
            end
          else
            {:ok, {old_record, [], batch_state}}
          end

        _ ->
          {:ok, {old_record, [], batch_state}}
      end
    end

    defp track_nested_one_put(batch_state, resource, old_record, new_record, tenant) do
      case resolve_nested_spec(resource) do
        %{cardinality: :one, foreign_key: fk_attr, path: path} = nested ->
          parent_col_str = resolve_parent_collection(nested, tenant, resource)
          new_parent_val = Map.get(new_record, fk_attr)

          batch_state =
            case old_record do
              nil ->
                batch_state

              prev ->
                old_parent_val = Map.get(prev, fk_attr)

                if not is_nil(old_parent_val) and old_parent_val != new_parent_val do
                  old_parent_doc_id = encode_parent_doc_id(resource, nested, old_parent_val)

                  Map.put(
                    batch_state,
                    {:nested_one_record, parent_col_str, old_parent_doc_id, path},
                    :deleted
                  )
                else
                  batch_state
                end
            end

          if is_nil(new_parent_val) do
            batch_state
          else
            new_parent_doc_id = encode_parent_doc_id(resource, nested, new_parent_val)

            Map.put(
              batch_state,
              {:nested_one_record, parent_col_str, new_parent_doc_id, path},
              new_record
            )
          end

        _ ->
          batch_state
      end
    end

    defp track_nested_one_delete(batch_state, resource, record, tenant) do
      case resolve_nested_spec(resource) do
        %{cardinality: :one, foreign_key: fk_attr, path: path} = nested ->
          case Map.get(record, fk_attr) do
            nil ->
              batch_state

            parent_val ->
              parent_col_str = resolve_parent_collection(nested, tenant, resource)
              parent_doc_id = encode_parent_doc_id(resource, nested, parent_val)

              Map.put(
                batch_state,
                {:nested_one_record, parent_col_str, parent_doc_id, path},
                :deleted
              )
          end

        _ ->
          batch_state
      end
    end

    defp resolve_nested_spec(resource) do
      resource
      |> Info.nested_in()
      |> normalize_nested_spec()
    end

    defp normalize_nested_spec(nil), do: nil

    defp normalize_nested_spec(%{
           parent_collection: parent_col,
           foreign_key: fk_attr,
           path: path,
           cardinality: cardinality
         })
         when is_atom(parent_col) and not is_nil(parent_col) do
      %{
        parent_collection: parent_col,
        foreign_key: fk_attr,
        path: Atom.to_string(path),
        cardinality: cardinality
      }
    end

    defp resolve_parent_collection(%{parent_collection: parent_col}, tenant, resource) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :context and not is_nil(tenant) do
        "t:" <> Codec.encode_doc_id(tenant) <> ":" <> Atom.to_string(parent_col)
      else
        Atom.to_string(parent_col)
      end
    end

    defp plan_purge_nested_children_ops(
           db_or_cursor,
           parent_resource,
           parent_pk_val,
           tenant,
           batch_state
         ) do
      nested_children = discover_nested_children(parent_resource)

      Enum.flat_map_reduce(nested_children, batch_state, fn child_resource, outer_batch ->
        db_or_cursor
        |> nested_cursors_for_parent(child_resource, parent_pk_val, tenant)
        |> Enum.flat_map_reduce(outer_batch, fn {_child_doc_id, child_cursor}, inner_batch ->
          case Codec.from_cursor(child_resource, child_cursor, tenant) do
            {:ok, child_record} ->
              {:ok, ops, next_batch} =
                plan_delete_ops_batched(
                  db_or_cursor,
                  child_resource,
                  child_record,
                  tenant,
                  inner_batch
                )

              {ops, next_batch}

            {:error, _} ->
              {[], inner_batch}
          end
        end)
      end)
    end

    defp discover_nested_children(parent_resource) do
      store_children =
        case Info.fetch_store(parent_resource) do
          {:ok, store} ->
            if :persistent_term.get({Xitdb.Ash.Store.Snapshot, store}, nil) != nil do
              store
              |> Store.reverse_fks(parent_resource)
              |> Enum.filter(&Map.get(&1, :nested?, false))
              |> Enum.map(& &1.source_resource)
            else
              []
            end

          _ ->
            []
        end

      parent_col =
        case Info.fetch_collection(parent_resource) do
          {:ok, col} -> col
          _ -> nil
        end

      rel_children =
        parent_resource
        |> Ash.Resource.Info.relationships()
        |> Enum.filter(&(&1.type in [:has_many, :has_one]))
        |> Enum.map(& &1.destination)
        |> Enum.filter(fn dest ->
          case resolve_nested_spec(dest) do
            %{parent_collection: ^parent_col} when not is_nil(parent_col) -> true
            _ -> false
          end
        end)

      Enum.uniq(store_children ++ rel_children)
    end

    defp cursor_matches_doc_id?(cursor, pk_attr, expected_doc_id) do
      pk_field_str = Atom.to_string(pk_attr.name)

      case cursor[pk_field_str] do
        nil -> false
        val -> Codec.encode_pk_doc_id(pk_attr, val) == expected_doc_id
      end
    end

    defp plan_identity_ops(db_or_cursor, resource, old_record, new_record, tenant, batch_state) do
      scoped_col = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)

      current_doc_id =
        cond do
          new_record != nil ->
            Codec.encode_pk_doc_id(pk_attr, Map.fetch!(new_record, pk_attr.name))

          old_record != nil ->
            Codec.encode_pk_doc_id(pk_attr, Map.fetch!(old_record, pk_attr.name))
        end

      resource
      |> Ash.Resource.Info.identities()
      |> Enum.reduce_while({:ok, []}, fn identity, {:ok, acc} ->
        slot = identity_slot_name(identity.name)
        id_col = identity_collection(resource, identity, tenant)
        owner_id = encode_identity_owner(resource, identity, scoped_col, current_doc_id)
        old_key = active_identity_key(resource, identity, old_record, tenant)
        new_key = active_identity_key(resource, identity, new_record, tenant)

        case check_identity_collision(
               db_or_cursor,
               id_col,
               slot,
               new_key,
               owner_id,
               identity,
               batch_state
             ) do
          :ok ->
            ops = diff_unique_keys(id_col, slot, old_key, new_key, owner_id)
            {:cont, {:ok, ops ++ acc}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    end

    defp identity_collection(resource, identity, tenant) do
      if Map.get(identity, :all_tenants?, false) do
        Atom.to_string(Info.collection!(resource))
      else
        Codec.scoped_collection(resource, tenant)
      end
    end

    defp encode_identity_owner(resource, identity, scoped_col, doc_id) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :context and
           Map.get(identity, :all_tenants?, false) do
        scoped_col <> <<0>> <> doc_id
      else
        doc_id
      end
    end

    defp unpack_identity_lookup(resource, identity, tenant, stored_val) do
      if Ash.Resource.Info.multitenancy_strategy(resource) == :context and
           Map.get(identity, :all_tenants?, false) do
        caller_scoped_col = Codec.scoped_collection(resource, tenant)

        case String.split(stored_val, <<0>>, parts: 2) do
          [^caller_scoped_col, raw_doc_id] -> {:ok, raw_doc_id}
          _ -> :none
        end
      else
        {:ok, stored_val}
      end
    end

    defp active_identity_key(_resource, _identity, nil, _tenant), do: nil

    defp active_identity_key(resource, identity, record, tenant) do
      if matches_identity_where?(resource, record, Map.get(identity, :where), tenant) do
        case Codec.encode_identity_key(resource, identity, record, tenant) do
          {:ok, key} -> key
          :skip -> nil
        end
      else
        nil
      end
    end

    defp matches_identity_where?(_resource, _record, nil, _tenant), do: true

    defp matches_identity_where?(resource, record, where_filter, tenant) do
      struct_record = if is_struct(record, resource), do: record, else: struct(resource, record)

      case Ash.Filter.Runtime.filter_matches(nil, [struct_record], where_filter,
             tenant: tenant,
             authorize?: false
           ) do
        {:ok, [_ | _]} -> true
        _ -> false
      end
    end

    defp check_identity_collision(
           _db,
           _id_col,
           _slot,
           nil,
           _owner_id,
           _identity,
           _batch_state
         ),
         do: :ok

    defp check_identity_collision(
           db_or_cursor,
           id_col,
           slot,
           new_key,
           owner_id,
           identity,
           batch_state
         ) do
      lookup_res =
        case Map.fetch(batch_state, {:unique_slot, id_col, slot, new_key}) do
          {:ok, :deleted} -> :none
          {:ok, stored_owner} -> {:ok, stored_owner}
          :error -> Storage.lookup_unique(db_or_cursor, id_col, slot, new_key)
        end

      case lookup_res do
        :none ->
          :ok

        {:ok, ^owner_id} ->
          :ok

        {:ok, _other_owner} ->
          {:error,
           InvalidChanges.exception(
             fields: identity.keys,
             message: Map.get(identity, :message) || "has already been taken"
           )}
      end
    end

    defp diff_unique_keys(_id_col, _slot, key, key, _owner_id), do: []

    defp diff_unique_keys(id_col, slot, nil, new_key, owner_id),
      do: [{:put_unique, id_col, slot, new_key, owner_id}]

    defp diff_unique_keys(id_col, slot, old_key, nil, owner_id),
      do: [{:del_unique, id_col, slot, old_key, owner_id}]

    defp diff_unique_keys(id_col, slot, old_key, new_key, owner_id) do
      [
        {:del_unique, id_col, slot, old_key, owner_id},
        {:put_unique, id_col, slot, new_key, owner_id}
      ]
    end

    defp plan_secondary_ops(resource, old_record, new_record) do
      pk_attr = pk_attribute(resource)

      doc_id =
        cond do
          new_record != nil ->
            Codec.encode_pk_doc_id(pk_attr, Map.fetch!(new_record, pk_attr.name))

          old_record != nil ->
            Codec.encode_pk_doc_id(pk_attr, Map.fetch!(old_record, pk_attr.name))
        end

      resource
      |> Info.indexes()
      |> Enum.flat_map(fn %{fields: fields} = index_spec ->
        attrs = Enum.map(fields, &Ash.Resource.Info.attribute(resource, &1))
        slot = index_slot_name(index_spec)

        old_key = encode_record_index_key(attrs, fields, old_record)
        new_key = encode_record_index_key(attrs, fields, new_record)

        diff_set_keys(slot, old_key, new_key, doc_id)
      end)
    end

    defp removed_attribute_fields(_resource, nil, _cursor_map), do: []

    defp removed_attribute_fields(resource, old_record, cursor_map) do
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.reduce([], fn %{name: name}, acc ->
        field_str = Atom.to_string(name)

        if Map.get(old_record, name) != nil and not Map.has_key?(cursor_map, field_str) do
          [field_str | acc]
        else
          acc
        end
      end)
    end

    defp encode_record_index_key(_attrs, _fields, nil), do: nil

    defp encode_record_index_key(attrs, fields, record) do
      values = Enum.map(fields, &Map.get(record, &1))
      Codec.encode_index_key(attrs, values)
    end

    defp diff_set_keys(_slot, key, key, _doc_id), do: []
    defp diff_set_keys(slot, nil, new_key, doc_id), do: [{:put_set, slot, new_key, doc_id}]
    defp diff_set_keys(slot, old_key, nil, doc_id), do: [{:del_set, slot, old_key, doc_id}]

    defp diff_set_keys(slot, old_key, new_key, doc_id) do
      [{:del_set, slot, old_key, doc_id}, {:put_set, slot, new_key, doc_id}]
    end

    # Generates exact `idx.search.<collection>` ops matching `Xitdb.Ash.Search.Storage` layout
    # so BM25 token additions, weight updates, and removals commit atomically in ONE moment.
    defp plan_search_ops(
           db_or_cursor,
           resource,
           collection,
           new_record,
           explicit_doc_id,
           batch_state
         ) do
      case Info.search_fields(resource) do
        [] ->
          {[], batch_state}

        search_fields ->
          pk_attr = pk_attribute(resource)

          doc_key =
            explicit_doc_id ||
              Codec.encode_pk_doc_id(pk_attr, Map.fetch!(new_record, pk_attr.name))

          new_terms =
            if is_nil(new_record) do
              %{}
            else
              extract_search_terms(new_record, search_fields, db_or_cursor)
            end

          Storage.compile_search_diff_ops(
            db_or_cursor,
            collection,
            doc_key,
            new_terms,
            batch_state
          )
      end
    end

    defp extract_search_terms(record, search_fields, db_or_cursor) do
      Enum.reduce(search_fields, %{}, fn %{field: field, boost: boost, resolver: resolver}, acc ->
        weight = max(1, round(boost * @search_weight_scale))

        raw_value =
          case resolver do
            fun when is_function(fun, 2) -> fun.(record, db_or_cursor)
            nil -> Map.get(record, field)
          end

        raw_value
        |> tokenize_search_value()
        |> Enum.reduce(acc, fn token, term_acc ->
          Map.update(term_acc, token, weight, &(&1 + weight))
        end)
      end)
    end

    defp tokenize_search_value(values) when is_list(values) do
      Enum.flat_map(values, &tokenize_search_value/1)
    end

    defp tokenize_search_value(value) when is_binary(value) or is_struct(value, Ash.CiString) do
      Search.tokenize(value)
    end

    defp tokenize_search_value(value)
         when is_atom(value) and not is_nil(value) and not is_boolean(value) do
      value |> Atom.to_string() |> Search.tokenize()
    end

    defp tokenize_search_value(_other), do: []

    # -- Range Scan Boundary Helpers (Prefix-Aware for Composite Indexes) --

    defp build_lower_bound(_attrs, _prefix_vals, prefix_bin, _range_attr, :unbounded, true) do
      start_key = <<prefix_bin::binary, 0x01>>
      {start_key, fn _key -> true end}
    end

    defp build_lower_bound(_attrs, _prefix_vals, prefix_bin, _range_attr, :unbounded, false) do
      {prefix_bin, fn _key -> true end}
    end

    defp build_lower_bound(
           attrs,
           prefix_vals,
           _prefix_bin,
           %Ash.Resource.Attribute{},
           {inclusivity, min_val},
           _has_range_bound?
         ) do
      specified_vals = prefix_vals ++ [min_val]
      bound_key = Codec.encode_index_prefix(attrs, specified_vals)
      partial_prefix? = length(specified_vals) < length(attrs)

      pred =
        case {inclusivity, partial_prefix?} do
          {:inclusive, _} ->
            fn key -> key >= bound_key end

          {:exclusive, true} ->
            fn key -> key > bound_key and not binary_starts_with?(key, bound_key) end

          {:exclusive, false} ->
            fn key -> key > bound_key end
        end

      {bound_key, pred}
    end

    defp build_upper_bound(_attrs, _prefix_vals, _prefix_bin, _range_attr, :unbounded) do
      fn _key -> true end
    end

    defp build_upper_bound(
           attrs,
           prefix_vals,
           _prefix_bin,
           %Ash.Resource.Attribute{},
           {inclusivity, max_val}
         ) do
      specified_vals = prefix_vals ++ [max_val]
      bound_key = Codec.encode_index_prefix(attrs, specified_vals)
      partial_prefix? = length(specified_vals) < length(attrs)

      case {inclusivity, partial_prefix?} do
        {:inclusive, true} ->
          fn key -> key <= bound_key or binary_starts_with?(key, bound_key) end

        {:inclusive, false} ->
          fn key -> key <= bound_key end

        {:exclusive, _} ->
          fn key -> key < bound_key end
      end
    end

    defp binary_starts_with?(bin, <<>>), do: is_binary(bin)

    defp binary_starts_with?(bin, prefix) do
      plen = byte_size(prefix)

      case bin do
        <<^prefix::binary-size(^plen), _rest::binary>> -> true
        _ -> false
      end
    end

    defp non_null_at_offset?(bin, offset) when byte_size(bin) > offset do
      :binary.at(bin, offset) != 0x00
    end

    defp non_null_at_offset?(_bin, _offset), do: true

    defp pk_attribute(resource) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      Ash.Resource.Info.attribute(resource, pk_name)
    end
  end

  defmodule Xitdb.Ash.Indexer.Storage do
    @moduledoc false
    # Slot-tree adapter built strictly over real `Xitdb` APIs:
    #   root[collection][doc_id]                         (:hash_map)
    #   root[parent_col][parent_id][path]                (:hash_map for :many | entity map for :one)
    #   root["idx"][collection]["_parent"][hex_pk_key]   (:sorted_map -> parent_doc_id)
    #   root["idx"][collection]["id_<name>"][hex_id_key] (:sorted_map -> doc_id)
    #   root["idx"][collection]["attr_<f>"][hex_idx_key] (:sorted_map -> :counted_hash_set(doc_id))
    #   root["idx"]["search"][collection]                (BM25 `meta` / `docs` / `terms`)

    alias Xitdb.Ash.Codec
    alias Xitdb.TxCompiler

    @parent_slot "_parent"

    @spec fetch_top_level_cursor(term(), String.t(), String.t()) :: {:ok, term()} | :none
    def fetch_top_level_cursor(db_or_cursor, collection, doc_id) do
      with %Xitdb.Cursor{} = root <- root_cursor(db_or_cursor),
           %Xitdb.Cursor{} = col <- root[collection],
           cursor when not is_nil(cursor) <- col[doc_id] do
        {:ok, cursor}
      else
        _ -> :none
      end
    end

    @spec fetch_nested_cursor(
            term(),
            String.t(),
            String.t(),
            String.t(),
            :one | :many,
            String.t()
          ) :: {:ok, term()} | :none
    def fetch_nested_cursor(db_or_cursor, parent_col, parent_doc_id, path, cardinality, doc_id) do
      with {:ok, parent} <- fetch_top_level_cursor(db_or_cursor, parent_col, parent_doc_id),
           subtree when not is_nil(subtree) <- parent[path] do
        case cardinality do
          :one ->
            {:ok, subtree}

          :many ->
            case subtree[doc_id] do
              nil -> :none
              cursor -> {:ok, cursor}
            end
        end
      else
        _ -> :none
      end
    end

    @spec list_top_level_cursors(term(), String.t()) :: [{String.t(), term()}]
    def list_top_level_cursors(db_or_cursor, collection) do
      with %Xitdb.Cursor{} = root <- root_cursor(db_or_cursor),
           %Xitdb.Cursor{} = col <- root[collection] do
        Enum.to_list(col)
      else
        _ -> []
      end
    end

    @spec list_nested_cursors_for_parent(
            term(),
            String.t(),
            String.t(),
            String.t(),
            :one | :many,
            Ash.Resource.Attribute.t()
          ) :: [{String.t(), term()}]
    def list_nested_cursors_for_parent(
          db_or_cursor,
          parent_col,
          parent_doc_id,
          path,
          cardinality,
          pk_attr
        ) do
      pk_field = Atom.to_string(pk_attr.name)

      with {:ok, parent} <- fetch_top_level_cursor(db_or_cursor, parent_col, parent_doc_id),
           subtree when not is_nil(subtree) <- parent[path] do
        case cardinality do
          :many ->
            Enum.to_list(subtree)

          :one ->
            case subtree[pk_field] do
              nil -> []
              pk_val -> [{Codec.encode_pk_doc_id(pk_attr, pk_val), subtree}]
            end
        end
      else
        _ -> []
      end
    end

    @spec lookup_unique(term(), String.t(), String.t(), binary()) :: {:ok, String.t()} | :none
    def lookup_unique(db_or_cursor, collection, slot, raw_key) do
      hex_key = encode_btree_key(raw_key)

      with %Xitdb.Cursor{} = btree <- get_index_slot(db_or_cursor, collection, slot),
           doc_id when is_binary(doc_id) <- btree[hex_key] do
        {:ok, doc_id}
      else
        _ -> :none
      end
    end

    @spec list_unique_entries(term(), String.t(), String.t()) :: [{binary(), String.t()}]
    def list_unique_entries(db_or_cursor, collection, slot) do
      case get_index_slot(db_or_cursor, collection, slot) do
        nil ->
          []

        %Xitdb.Cursor{} = btree ->
          Enum.map(btree, fn {hex_key, doc_id} -> {decode_btree_key(hex_key), doc_id} end)
      end
    end

    @spec lookup_set(term(), String.t(), String.t(), binary()) :: [String.t()]
    def lookup_set(db_or_cursor, collection, slot, raw_key) do
      hex_key = encode_btree_key(raw_key)

      with %Xitdb.Cursor{} = btree <- get_index_slot(db_or_cursor, collection, slot),
           %Xitdb.Cursor{} = set <- btree[hex_key] do
        Enum.to_list(set)
      else
        _ -> []
      end
    end

    @spec count_set(term(), String.t(), String.t(), binary()) :: non_neg_integer()
    def count_set(db_or_cursor, collection, slot, raw_key) do
      hex_key = encode_btree_key(raw_key)

      with %Xitdb.Cursor{} = btree <- get_index_slot(db_or_cursor, collection, slot),
           %Xitdb.Cursor{} = set <- btree[hex_key] do
        Enum.count(set)
      else
        _ -> 0
      end
    end

    @spec stream_index_from(term(), String.t(), String.t(), binary()) :: Enumerable.t()
    def stream_index_from(db_or_cursor, collection, slot, start_raw_key) do
      start_hex = encode_btree_key(start_raw_key)

      case get_index_slot(db_or_cursor, collection, slot) do
        nil ->
          []

        %Xitdb.Cursor{tag: :sorted_map} = btree ->
          stream_btree_from_key(btree, start_hex)

        %Xitdb.Cursor{tag: :none, value: 0} ->
          []

        %Xitdb.Cursor{tag: other} ->
          raise Xitdb.Error, reason: {:unsupported_index_tag, other}
      end
    end

    @spec compile_put_ops(
            term(),
            String.t(),
            map(),
            tuple(),
            [tuple()],
            [tuple()],
            map(),
            [String.t()]
          ) ::
            {[tuple()], map()}
    def compile_put_ops(
          db_or_cursor,
          collection,
          cursor_map,
          locator_plan,
          identity_ops,
          secondary_ops,
          batch_state \\ %{},
          removed_fields \\ []
        ) do
      {entity_ops, b1} =
        compile_write_entity_ops(
          db_or_cursor,
          collection,
          cursor_map,
          locator_plan,
          batch_state,
          removed_fields
        )

      {unique_ops, b2} = compile_unique_ops(db_or_cursor, identity_ops, b1)
      {set_ops, b3} = compile_set_ops(db_or_cursor, collection, secondary_ops, b2)
      {entity_ops ++ unique_ops ++ set_ops, b3}
    end

    @spec compile_delete_ops(term(), String.t(), tuple(), [tuple()], [tuple()], map()) ::
            {[tuple()], map()}
    def compile_delete_ops(
          db_or_cursor,
          collection,
          delete_location,
          identity_ops,
          secondary_ops,
          batch_state \\ %{}
        ) do
      {entity_ops, b1} =
        compile_remove_entity_ops(db_or_cursor, collection, delete_location, batch_state)

      {unique_ops, b2} = compile_unique_ops(db_or_cursor, identity_ops, b1)
      {set_ops, b3} = compile_set_ops(db_or_cursor, collection, secondary_ops, b2)
      {entity_ops ++ unique_ops ++ set_ops, b3}
    end

    @spec compile_search_diff_ops(
            term(),
            String.t(),
            String.t(),
            %{optional(String.t()) => pos_integer()},
            map()
          ) :: {[tuple()], map()}
    def compile_search_diff_ops(
          db_or_cursor,
          collection,
          doc_key,
          new_terms,
          batch_state \\ %{}
        ) do
      doc_state_key = {:search_doc, collection, doc_key}

      %{len: old_len, terms: old_terms} =
        Map.get_lazy(batch_state, doc_state_key, fn ->
          Xitdb.Ash.Search.Storage.read_doc(db_or_cursor, collection, doc_key)
        end)

      new_len = Enum.reduce(new_terms, 0, fn {_term, weight}, sum -> sum + weight end)

      if old_terms == new_terms do
        {[], batch_state}
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
        term_diffs = diff_search_terms(old_terms, new_terms)

        col_str = TxCompiler.format_key(collection)
        doc_str = TxCompiler.format_key(doc_key)
        meta_prefix = ".idx.search." <> col_str <> ".meta"
        docs_prefix = ".idx.search." <> col_str <> ".docs"
        terms_prefix = ".idx.search." <> col_str <> ".terms"

        stats_key = {:search_stats, collection}

        %{doc_count: cur_doc_count, total_len: cur_total_len} =
          Map.get_lazy(batch_state, stats_key, fn ->
            Xitdb.Ash.Search.Storage.read_corpus_stats(db_or_cursor, collection)
          end)

        new_doc_count = max(0, cur_doc_count + doc_count_delta)
        new_total_len = max(0, cur_total_len + len_delta)

        next_batch =
          batch_state
          |> Map.put(stats_key, %{doc_count: new_doc_count, total_len: new_total_len})
          |> Map.put(doc_state_key, %{len: new_len, terms: new_terms})

        meta_ops = [
          {:put, meta_prefix <> ".doc_count", new_doc_count},
          {:put, meta_prefix <> ".total_len", new_total_len}
        ]

        doc_path = docs_prefix <> "." <> doc_str

        doc_ops =
          if now_indexed? do
            put_terms =
              Enum.map(new_terms, fn {term, weight} ->
                {:put, doc_path <> ".terms." <> TxCompiler.format_key(term), weight}
              end)

            [
              {:put, doc_path <> ".len", new_len},
              {:reset_col, doc_path <> ".terms", "hash_map"} | put_terms
            ]
          else
            if was_indexed?, do: [{:rm, doc_path}], else: []
          end

        {term_ops, final_batch} =
          Enum.flat_map_reduce(term_diffs, next_batch, fn
            {:put, term, weight}, b_acc ->
              term_key = {:search_term_docs, collection, term}

              docs_set =
                Map.get_lazy(b_acc, term_key, fn ->
                  db_or_cursor
                  |> Xitdb.Ash.Search.Storage.lookup_term(collection, term)
                  |> MapSet.new(&elem(&1, 0))
                end)

              term_str = TxCompiler.format_key(term)

              {[{:put, terms_prefix <> "$" <> term_str <> "." <> doc_str, weight}],
               Map.put(b_acc, term_key, MapSet.put(docs_set, doc_key))}

            {:delete, term}, b_acc ->
              term_key = {:search_term_docs, collection, term}

              docs_set =
                Map.get_lazy(b_acc, term_key, fn ->
                  db_or_cursor
                  |> Xitdb.Ash.Search.Storage.lookup_term(collection, term)
                  |> MapSet.new(&elem(&1, 0))
                end)

              remaining = MapSet.delete(docs_set, doc_key)
              term_str = TxCompiler.format_key(term)

              op =
                if MapSet.size(remaining) == 0 do
                  {:rm, terms_prefix <> "$" <> term_str}
                else
                  {:rm, terms_prefix <> "$" <> term_str <> "." <> doc_str}
                end

              {[op], Map.put(b_acc, term_key, remaining)}
          end)

        {meta_ops ++ doc_ops ++ term_ops, final_batch}
      end
    end

    # -- Internal Compilation & Binary-Search Helpers --

    defp compile_write_entity_ops(
           _db_or_cursor,
           collection,
           cursor_map,
           {:top_level, doc_id},
           batch_state,
           removed_fields
         ) do
      prefix =
        TxCompiler.format_step(:hash_map, collection) <>
          TxCompiler.format_step(:hash_map, doc_id)

      {compile_entity_map_ops(prefix, cursor_map, removed_fields), batch_state}
    end

    defp compile_write_entity_ops(
           db_or_cursor,
           collection,
           cursor_map,
           {:nested, plan},
           batch_state,
           removed_fields
         ) do
      %{
        parent_collection: parent_col,
        old_parent_doc_id: old_parent_id,
        new_parent_doc_id: new_parent_id,
        path: path,
        cardinality: cardinality,
        doc_id: doc_id,
        pk_key: pk_key
      } = plan

      reparent_rm_ops =
        if old_parent_id != nil and old_parent_id != new_parent_id do
          compile_remove_from_parent_ops(
            db_or_cursor,
            parent_col,
            old_parent_id,
            path,
            cardinality,
            doc_id
          )
        else
          []
        end

      parent_prefix =
        TxCompiler.format_step(:hash_map, parent_col) <>
          TxCompiler.format_step(:hash_map, new_parent_id) <>
          TxCompiler.format_step(:hash_map, path)

      target_prefix =
        case cardinality do
          :one -> parent_prefix
          :many -> parent_prefix <> TxCompiler.format_step(:hash_map, doc_id)
        end

      write_ops =
        compile_entity_map_ops(target_prefix, cursor_map, removed_fields, cardinality == :one)

      {parent_locator_ops, next_batch} =
        compile_unique_ops(
          db_or_cursor,
          [{:put_unique, collection, @parent_slot, pk_key, new_parent_id}],
          batch_state
        )

      {reparent_rm_ops ++ write_ops ++ parent_locator_ops, next_batch}
    end

    defp compile_entity_map_ops(prefix, cursor_map, removed_fields, reset? \\ false) do
      init_op =
        if reset? do
          {:reset_col, prefix, "hash_map"}
        else
          {:init_col, prefix, "hash_map"}
        end

      put_ops =
        :maps.fold(
          fn k, v, acc ->
            TxCompiler.compile_node(prefix <> TxCompiler.format_step(:hash_map, k), v, true) ++
              acc
          end,
          [],
          cursor_map
        )

      rm_ops =
        if reset? do
          []
        else
          Enum.map(removed_fields, fn field_str ->
            {:rm, prefix <> TxCompiler.format_step(:hash_map, field_str)}
          end)
        end

      [init_op | put_ops] ++ rm_ops
    end

    defp compile_remove_entity_ops(
           db_or_cursor,
           collection,
           {:top_level, doc_id},
           batch_state
         ) do
      case fetch_top_level_cursor(db_or_cursor, collection, doc_id) do
        {:ok, _} ->
          path =
            TxCompiler.format_step(:hash_map, collection) <>
              TxCompiler.format_step(:hash_map, doc_id)

          {[{:rm, path}], batch_state}

        :none ->
          {[], batch_state}
      end
    end

    defp compile_remove_entity_ops(db_or_cursor, collection, {:nested, plan}, batch_state) do
      %{
        parent_collection: parent_col,
        parent_doc_id: parent_id,
        path: path,
        cardinality: cardinality,
        doc_id: doc_id,
        pk_key: pk_key
      } = plan

      subtree_rm =
        if parent_id != nil do
          compile_remove_from_parent_ops(
            db_or_cursor,
            parent_col,
            parent_id,
            path,
            cardinality,
            doc_id
          )
        else
          []
        end

      {locator_rm, next_batch} =
        compile_unique_ops(
          db_or_cursor,
          [{:del_unique, collection, @parent_slot, pk_key, parent_id}],
          batch_state
        )

      {subtree_rm ++ locator_rm, next_batch}
    end

    defp compile_remove_from_parent_ops(
           db_or_cursor,
           parent_col,
           parent_id,
           path,
           cardinality,
           doc_id
         ) do
      case fetch_nested_cursor(db_or_cursor, parent_col, parent_id, path, cardinality, doc_id) do
        {:ok, _} ->
          base =
            TxCompiler.format_step(:hash_map, parent_col) <>
              TxCompiler.format_step(:hash_map, parent_id) <>
              TxCompiler.format_step(:hash_map, path)

          target =
            case cardinality do
              :one -> base
              :many -> base <> TxCompiler.format_step(:hash_map, doc_id)
            end

          [{:rm, target}]

        :none ->
          []
      end
    end

    defp compile_unique_ops(db_or_cursor, ops, batch_state) do
      Enum.flat_map_reduce(ops, batch_state, fn
        {:put_unique, id_col, slot, raw_key, doc_id}, b_acc ->
          col_step = TxCompiler.format_step(:hash_map, id_col)
          hex_key = encode_btree_key(raw_key)
          slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
          init_key = {:init_slot, id_col, slot}

          {init_op, b_next} =
            if Map.has_key?(b_acc, init_key) or
                 get_index_slot(db_or_cursor, id_col, slot) != nil do
              {[], Map.put(b_acc, init_key, true)}
            else
              {[{:init_col, slot_path, "sorted_map"}], Map.put(b_acc, init_key, true)}
            end

          b_next = Map.put(b_next, {:unique_slot, id_col, slot, raw_key}, doc_id)
          {init_op ++ [{:put, slot_path <> "$" <> hex_key, doc_id}], b_next}

        {:del_unique, id_col, slot, raw_key, expected_doc_id}, b_acc ->
          col_step = TxCompiler.format_step(:hash_map, id_col)
          unique_key = {:unique_slot, id_col, slot, raw_key}

          current_res =
            case Map.fetch(b_acc, unique_key) do
              {:ok, :deleted} -> :none
              {:ok, doc_id} -> {:ok, doc_id}
              :error -> lookup_unique(db_or_cursor, id_col, slot, raw_key)
            end

          case current_res do
            {:ok, current} when is_nil(expected_doc_id) or current == expected_doc_id ->
              hex_key = encode_btree_key(raw_key)
              slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
              {[{:rm, slot_path <> "$" <> hex_key}], Map.put(b_acc, unique_key, :deleted)}

            _ ->
              {[], b_acc}
          end
      end)
    end

    defp compile_set_ops(db_or_cursor, collection, ops, batch_state) do
      col_step = TxCompiler.format_step(:hash_map, collection)

      Enum.flat_map_reduce(ops, batch_state, fn
        {:put_set, slot, raw_key, doc_id}, b_acc ->
          hex_key = encode_btree_key(raw_key)
          slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
          set_path = slot_path <> "$" <> hex_key
          init_key = {:init_slot, collection, slot}
          members_key = {:set_members, collection, slot, raw_key}

          {init_btree, b_init} =
            if Map.has_key?(b_acc, init_key) or
                 get_index_slot(db_or_cursor, collection, slot) != nil do
              {[], Map.put(b_acc, init_key, true)}
            else
              {[{:init_col, slot_path, "sorted_map"}], Map.put(b_acc, init_key, true)}
            end

          cur_members =
            Map.get_lazy(b_init, members_key, fn ->
              db_or_cursor |> lookup_set(collection, slot, raw_key) |> MapSet.new()
            end)

          b_next = Map.put(b_init, members_key, MapSet.put(cur_members, doc_id))

          init_set =
            if MapSet.size(cur_members) == 0 do
              [{:init_col, set_path, "counted_hash_set"}]
            else
              []
            end

          ops_out =
            init_btree ++
              init_set ++
              [
                {:put, set_path <> TxCompiler.format_step(:counted_hash_set, doc_id), true}
              ]

          {ops_out, b_next}

        {:del_set, slot, raw_key, doc_id}, b_acc ->
          members_key = {:set_members, collection, slot, raw_key}

          cur_members =
            Map.get_lazy(b_acc, members_key, fn ->
              db_or_cursor |> lookup_set(collection, slot, raw_key) |> MapSet.new()
            end)

          if MapSet.member?(cur_members, doc_id) do
            remaining = MapSet.delete(cur_members, doc_id)
            hex_key = encode_btree_key(raw_key)
            slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
            set_path = slot_path <> "$" <> hex_key

            rm_op =
              if MapSet.size(remaining) == 0 do
                {:rm, set_path}
              else
                {:rm, set_path <> TxCompiler.format_step(:counted_hash_set, doc_id)}
              end

            {[rm_op], Map.put(b_acc, members_key, remaining)}
          else
            {[], b_acc}
          end
      end)
    end

    defp diff_search_terms(old_terms, new_terms) do
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

    defp stream_btree_from_key(btree, start_hex) do
      Stream.unfold({start_hex, 16}, fn
        {nil, _limit} ->
          nil

        {cursor_key, page_limit} ->
          case Xitdb.NIF.nif_sorted_map_seek(
                 btree.db_ref,
                 btree.tag_id,
                 btree.value,
                 cursor_key,
                 page_limit,
                 false,
                 false
               ) do
            {:ok, [], _next} ->
              nil

            {:ok, chunk, next_cursor} ->
              {chunk, {next_cursor, 64}}

            {:error, reason} ->
              raise Xitdb.Error, reason: reason
          end
      end)
      |> Stream.flat_map(& &1)
      |> Stream.map(fn
        {hex_key, set_tag_id, set_val} when is_integer(set_tag_id) and is_integer(set_val) ->
          {decode_btree_key(hex_key),
           Xitdb.Cursor.from_compact_slot(btree.db_ref, set_tag_id, set_val, btree.moment)}

        {hex_key, {:cursor, _, _} = slot_tuple} ->
          {decode_btree_key(hex_key),
           Xitdb.Cursor.from_nif_tuple(btree.db_ref, slot_tuple, btree.moment)}

        {hex_key, ids} when is_list(ids) ->
          {decode_btree_key(hex_key),
           Xitdb.Cursor.unwrap_nif_entries(btree.db_ref, ids, btree.moment)}

        {hex_key, _other} ->
          {decode_btree_key(hex_key), []}
      end)
    end

    defp encode_btree_key(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)
    defp decode_btree_key(hex) when is_binary(hex), do: Base.decode16!(hex, case: :lower)

    defp root_cursor({%Xitdb{} = db, moment}) when is_integer(moment), do: Xitdb.as_of(db, moment)
    defp root_cursor(%Xitdb.Cursor{} = cursor), do: cursor
    defp root_cursor(%Xitdb{} = db), do: Xitdb.db(db)
    defp root_cursor(_), do: nil

    defp get_index_slot(db_or_cursor, collection, slot) do
      with %Xitdb.Cursor{} = root <- root_cursor(db_or_cursor),
           %Xitdb.Cursor{} = idx <- root["idx"],
           %Xitdb.Cursor{} = col <- idx[collection] do
        col[slot]
      else
        _ -> nil
      end
    end
  end
end
