if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Indexer do
    @moduledoc """
    Maintains and queries entity cursors, unique `identities` (with partial `where` filters),
    secondary `:sorted_map` B+Tree indexes, and transactional BM25 `idx.search` postings for
    `Xitdb.Ash.DataLayer`.
    """

    alias Ash.Error.Changes.InvalidChanges
    alias Xitdb.Ash.{Codec, Info, Search}
    alias Xitdb.Ash.Indexer.Storage

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

      with {:ok, cursor_map} <- Codec.to_cursor_map(resource, new_record),
           {:ok, identity_ops} <-
             plan_identity_ops(db_or_cursor, resource, old_record, new_record, tenant),
           {:ok, locator_plan} <-
             plan_entity_location(db_or_cursor, resource, old_record, new_record, tenant) do
        secondary_ops = plan_secondary_ops(resource, old_record, new_record)

        {entity_and_idx_ops, batch_after_idx} =
          Storage.compile_put_ops(
            db_or_cursor,
            collection,
            cursor_map,
            locator_plan,
            identity_ops,
            secondary_ops,
            batch_state
          )

        {search_ops, batch_after_search} =
          plan_search_ops(db_or_cursor, resource, collection, new_record, nil, batch_after_idx)

        {:ok, entity_and_idx_ops ++ search_ops, batch_after_search}
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

      {child_ops, batch_after_children} =
        plan_purge_nested_children_ops(db_or_cursor, resource, pk_val, tenant, batch_state)

      {:ok, identity_ops} = plan_identity_ops(db_or_cursor, resource, record, nil, tenant)
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

      {:ok, child_ops ++ own_delete_ops ++ search_ops, batch_after_search}
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

      with {:ok, ops} <- plan_put_ops(cursor_root, resource, old_record, new_record, tenant),
           {:ok, next_db} <- Xitdb.transact_ops(db, ops, base_moment: moment) do
        {:ok, {next_db, Xitdb.moment_count(next_db) - 1}}
      end
    end

    def put_record(%Xitdb{} = db, resource, old_record, %_{} = new_record, tenant)
        when is_atom(resource) do
      with {:ok, ops} <- plan_put_ops(db, resource, old_record, new_record, tenant),
           {:ok, next_db} <- Xitdb.transact_ops(db, ops) do
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
      {:ok, next_db} = Xitdb.transact_ops(db, ops, base_moment: moment)
      {:ok, {next_db, Xitdb.moment_count(next_db) - 1}}
    end

    def delete_record(%Xitdb{} = db, resource, %_{} = record, tenant) when is_atom(resource) do
      {:ok, ops} = plan_delete_ops(db, resource, record, tenant)
      {:ok, next_db} = Xitdb.transact_ops(db, ops)
      {:ok, next_db}
    end

    # -- Point, Identity & B+Tree Read Operations --

    @doc """
    Fetches a single raw entity cursor by primary key in `O(1)` for top-level collections.
    """
    @spec fetch_cursor(term(), module(), term(), term()) :: {:ok, term()} | :none
    def fetch_cursor(db_or_cursor, resource, pk_value, tenant \\ nil)
    def fetch_cursor(_db_or_cursor, _resource, nil, _tenant), do: :none

    def fetch_cursor(db_or_cursor, resource, pk_value, tenant) when is_atom(resource) do
      collection = Codec.scoped_collection(resource, tenant)
      pk_attr = pk_attribute(resource)
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_value)

      nil = resolve_nested_spec(resource)
      Storage.fetch_top_level_cursor(db_or_cursor, collection, doc_id)
    end

    @doc """
    Returns all `{doc_id, cursor}` pairs for a collection.
    """
    @spec all_cursors(term(), module(), term()) :: [{String.t(), term()}]
    def all_cursors(db_or_cursor, resource, tenant \\ nil) when is_atom(resource) do
      collection = Codec.scoped_collection(resource, tenant)
      nil = resolve_nested_spec(resource)
      Storage.list_top_level_cursors(db_or_cursor, collection)
    end

    @doc """
    Returns `[]` in Wave 2 flat mode (activated for `nested_in` subtrees in Wave 3 Track 11B).
    """
    @spec nested_cursors_for_parent(term(), module(), term(), term()) :: [{String.t(), term()}]
    def nested_cursors_for_parent(_db_or_cursor, resource, _parent_id, _tenant \\ nil)
        when is_atom(resource) do
      []
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
          collection = Codec.scoped_collection(resource, tenant)

          Storage.lookup_unique(
            db_or_cursor,
            collection,
            identity_slot_name(identity.name),
            encoded_key
          )
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
      Storage.count_set(db_or_cursor, collection, "attr_#{field}", encoded_key)
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

    defp plan_entity_location(_db_or_cursor, resource, _old_record, new_record, _tenant) do
      pk_attr = pk_attribute(resource)
      pk_val = Map.fetch!(new_record, pk_attr.name)
      doc_id = Codec.encode_pk_doc_id(pk_attr, pk_val)
      nil = resolve_nested_spec(resource)
      {:ok, {:top_level, doc_id}}
    end

    defp build_delete_location(resource, _record, _pk_attr, _pk_val, doc_id, _tenant) do
      nil = resolve_nested_spec(resource)
      {:top_level, doc_id}
    end

    defp resolve_nested_spec(_resource), do: nil

    defp plan_purge_nested_children_ops(
           _db_or_cursor,
           _parent_resource,
           _parent_pk_val,
           _tenant,
           batch_state
         ) do
      {[], batch_state}
    end

    defp plan_identity_ops(db_or_cursor, resource, old_record, new_record, tenant) do
      collection = Codec.scoped_collection(resource, tenant)
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
        old_key = active_identity_key(resource, identity, old_record, tenant)
        new_key = active_identity_key(resource, identity, new_record, tenant)

        case check_identity_collision(
               db_or_cursor,
               collection,
               slot,
               new_key,
               current_doc_id,
               identity
             ) do
          :ok ->
            ops = diff_unique_keys(slot, old_key, new_key, current_doc_id)
            {:cont, {:ok, ops ++ acc}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
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

    defp check_identity_collision(_db, _collection, _slot, nil, _doc_id, _identity), do: :ok

    defp check_identity_collision(
           db_or_cursor,
           collection,
           slot,
           new_key,
           current_doc_id,
           identity
         ) do
      case Storage.lookup_unique(db_or_cursor, collection, slot, new_key) do
        :none ->
          :ok

        {:ok, ^current_doc_id} ->
          :ok

        {:ok, _other_doc_id} ->
          {:error,
           InvalidChanges.exception(
             fields: identity.keys,
             message: Map.get(identity, :message) || "has already been taken"
           )}
      end
    end

    defp diff_unique_keys(_slot, key, key, _doc_id), do: []
    defp diff_unique_keys(slot, nil, new_key, doc_id), do: [{:put_unique, slot, new_key, doc_id}]
    defp diff_unique_keys(slot, old_key, nil, doc_id), do: [{:del_unique, slot, old_key, doc_id}]

    defp diff_unique_keys(slot, old_key, new_key, doc_id) do
      [{:del_unique, slot, old_key, doc_id}, {:put_unique, slot, new_key, doc_id}]
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
    #   root["idx"][collection]["id_<name>"][hex_id_key] (:sorted_map -> doc_id)
    #   root["idx"][collection]["attr_<f>"][hex_idx_key] (:sorted_map -> :counted_hash_set(doc_id))
    #   root["idx"]["search"][collection]                (BM25 `meta` / `docs` / `terms`)

    alias Xitdb.TxCompiler

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

    @spec list_top_level_cursors(term(), String.t()) :: [{String.t(), term()}]
    def list_top_level_cursors(db_or_cursor, collection) do
      with %Xitdb.Cursor{} = root <- root_cursor(db_or_cursor),
           %Xitdb.Cursor{} = col <- root[collection] do
        Enum.to_list(col)
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

        %Xitdb.Cursor{} = btree ->
          case Xitdb.NIF.nif_slot_count(btree.db_ref, btree.tag_id, btree.value) do
            {:ok, total_count} when total_count > 0 ->
              start_idx = find_btree_start_index(btree, start_hex, 0, total_count)
              stream_btree_entries(btree, start_idx)

            _ ->
              []
          end
      end
    end

    @spec compile_put_ops(term(), String.t(), map(), tuple(), [tuple()], [tuple()], map()) ::
            {[tuple()], map()}
    def compile_put_ops(
          db_or_cursor,
          collection,
          cursor_map,
          locator_plan,
          identity_ops,
          secondary_ops,
          batch_state \\ %{}
        ) do
      {entity_ops, b1} =
        compile_write_entity_ops(db_or_cursor, collection, cursor_map, locator_plan, batch_state)

      {unique_ops, b2} = compile_unique_ops(db_or_cursor, collection, identity_ops, b1)
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

      {unique_ops, b2} = compile_unique_ops(db_or_cursor, collection, identity_ops, b1)
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
           batch_state
         ) do
      prefix =
        TxCompiler.format_step(:hash_map, collection) <>
          TxCompiler.format_step(:hash_map, doc_id)

      {TxCompiler.compile_node(prefix, cursor_map, true), batch_state}
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

    defp compile_unique_ops(db_or_cursor, collection, ops, batch_state) do
      col_step = TxCompiler.format_step(:hash_map, collection)

      Enum.flat_map_reduce(ops, batch_state, fn
        {:put_unique, slot, raw_key, doc_id}, b_acc ->
          hex_key = encode_btree_key(raw_key)
          slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
          init_key = {:init_slot, collection, slot}

          {init_op, b_next} =
            if Map.has_key?(b_acc, init_key) or
                 get_index_slot(db_or_cursor, collection, slot) != nil do
              {[], Map.put(b_acc, init_key, true)}
            else
              {[{:init_col, slot_path, "sorted_map"}], Map.put(b_acc, init_key, true)}
            end

          {init_op ++ [{:put, slot_path <> "$" <> hex_key, doc_id}], b_next}

        {:del_unique, slot, raw_key, expected_doc_id}, b_acc ->
          case lookup_unique(db_or_cursor, collection, slot, raw_key) do
            {:ok, current} when is_nil(expected_doc_id) or current == expected_doc_id ->
              hex_key = encode_btree_key(raw_key)
              slot_path = ".idx" <> col_step <> TxCompiler.format_step(:hash_map, slot)
              {[{:rm, slot_path <> "$" <> hex_key}], b_acc}

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

    defp find_btree_start_index(btree, start_hex, low, high) when low < high do
      mid = div(low + high, 2)

      case Xitdb.NIF.nif_slot_entries(btree.db_ref, btree.tag_id, btree.value, mid, 1) do
        {:ok, [{hex_key, _}]} ->
          if hex_key < start_hex do
            find_btree_start_index(btree, start_hex, mid + 1, high)
          else
            find_btree_start_index(btree, start_hex, low, mid)
          end

        _ ->
          low
      end
    end

    defp find_btree_start_index(_btree, _start_hex, low, _high), do: low

    defp stream_btree_entries(btree, start_idx) do
      Stream.unfold(start_idx, fn idx ->
        case Xitdb.NIF.nif_slot_entries(btree.db_ref, btree.tag_id, btree.value, idx, 64) do
          {:ok, []} -> nil
          {:ok, chunk} -> {chunk, idx + length(chunk)}
          _ -> nil
        end
      end)
      |> Stream.flat_map(& &1)
      |> Stream.map(fn {hex_key, raw_set} ->
        ids =
          case raw_set do
            {:cursor, _tag, _tag_id, _val, _full} = c_tuple ->
              btree.db_ref
              |> Xitdb.Cursor.from_nif_tuple(c_tuple, btree.moment)
              |> Enum.to_list()

            %Xitdb.Cursor{} = cur ->
              Enum.to_list(cur)

            list when is_list(list) ->
              list
          end

        {decode_btree_key(hex_key), ids}
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
