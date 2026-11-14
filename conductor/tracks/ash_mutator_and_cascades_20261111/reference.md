# Reference: `Xitdb.Ash.Mutator`

> [!IMPORTANT]
> **Track Reference Metadata:**
> - **Associated Track:** [`ash_mutator_and_cascades_20261111`](./index.md)
> - **Target Repository:** `xitdb` (`/home/pauli/projects/elixir/xitdb`)
> - **Primary Module:** `lib/xitdb/ash/mutator.ex`
> - **Purpose:** Complete specification and reference implementation for the atomic mutator, monotonic sequences, optimistic locking, atomic validations, and foreign-key cascades for `Xitdb.Ash.DataLayer`.

---

## 1. Concurrency, Execution & Safety Invariants

### 1.1 Atomic Policy, Validation & CVE Guards
Every `update`, `update_query`, `destroy`, and `destroy_query` enforces `changeset.filter` (row-level `FilterCheck` policies + optimistic locks) and `changeset.atomic_validations` before evaluating `changeset.atomics` inside the single-writer lease, while `create` rejects duplicate primary keys and `upsert/4` scopes identity resolution to `changeset.tenant`.

### 1.2 Monotonic Sequences & Duplicate-PK Guard
- Unassigned generated integer primary keys are allocated monotonically from `meta.sequences[collection]` via `Sequences.next_id/2`.
- Explicit integer IDs advance the high-water mark `meta.sequences[collection] = max(seq, explicit_id)` via `Sequences.advance_at_least/3`.
- If an explicit ID already exists in the collection, `create/2` rejects it immediately with an `Ash.Error.Changes.InvalidChanges` duplicate key error.

### 1.3 Same-Store Reverse-FK Cascades
Enforces `:restrict`, `:nilify`, and `:delete` cascades recursively across incoming relationships within the same `.xit` store, preventing cyclic infinite loops via a `visited` Set.

### 1.4 Gradual Type-System Cleanliness (Elixir 1.19–1.20+)
Dynamic `%Resource{}` structs are updated via `Map.put/3` and `Map.merge/2` rather than untyped `%{record | ...}` map-update syntax so `mix compile --warnings-as-errors` stays clean.

---

## 2. Reference Implementation: `lib/xitdb/ash/mutator.ex`

```elixir
if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Mutator do
    @moduledoc """
    Transactional write engine (`create`, `bulk_create`, `update`, `update_query`,
    `upsert`, `destroy`, `destroy_query`), monotonic integer sequence allocator,
    atomic policy/validation evaluator, and same-store `on_delete` cascade enforcer.
    """

    alias Ash.Error.Changes.{InvalidChanges, StaleRecord}
    alias Xitdb.Ash.{Codec, Indexer, Info, Query, Store}
    alias Xitdb.Ash.Mutator.Sequences

    # -- Single-Record Mutations --

    @doc """
    Inserts a new entity cursor, allocating `meta.sequences[collection]` when `:id` is `nil`
    on generated integer primary keys and rejecting duplicate primary keys.
    """
    @spec create(module(), Ash.Changeset.t()) :: {:ok, struct()} | {:error, term()}
    def create(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      Store.mutate(store, fn db ->
        create_in_db(db, resource, changeset)
      end)
    end

    @doc """
    Inserts or upserts a stream of changesets in a single Xitdb transaction commit.
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
        Store.mutate(store, fn initial_db ->
          stream
          |> Enum.with_index()
          |> Enum.reduce_while({:ok, initial_db, []}, fn {%Ash.Changeset{} = cs, idx}, {:ok, acc_db, acc_records} ->
            cs = if is_nil(cs.tenant) and tenant != nil, do: %Ash.Changeset{cs | tenant: tenant}, else: cs

            step =
              if upsert? do
                upsert_in_db(acc_db, resource, cs, upsert_keys, identity, opts)
              else
                create_in_db(acc_db, resource, cs)
              end

            case step do
              {:ok, next_db, record} ->
                tagged = attach_bulk_index(record, cs, idx)
                {:cont, {:ok, next_db, [tagged | acc_records]}}

              {:error, _} = err ->
                {:halt, err}
            end
          end)
        end)

      case result do
        {:ok, rev_records} ->
          if return_records?, do: {:ok, Enum.reverse(rev_records)}, else: :ok

        {:error, _} = err ->
          err
      end
    end

    @doc """
    Atomically updates an existing entity inside the store writer lease, enforcing
    `changeset.filter` (row-level policies + optimistic locks), `changeset.atomic_validations`,
    and `changeset.atomics`.
    """
    @spec update(module(), Ash.Changeset.t()) :: {:ok, struct()} | {:error, term()}
    def update(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      Store.mutate(store, fn db ->
        update_in_db(db, resource, changeset)
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

      result =
        Store.mutate(store, fn initial_db ->
          with {:ok, candidates} <- Query.execute(initial_db, %Query{query | select: nil}, resource) do
            apply_bulk_updates(initial_db, candidates, resource, changeset)
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
    Executes a tenant-scoped atomic upsert by explicit `identity` or `keys`.
    """
    @spec upsert(module(), Ash.Changeset.t(), [atom()], Ash.Resource.Identity.t() | nil) ::
            {:ok, struct()} | {:error, term()}
    def upsert(resource, %Ash.Changeset{} = changeset, keys, identity \\ nil)
        when is_atom(resource) and is_list(keys) do
      store = Info.store!(resource)

      Store.mutate(store, fn db ->
        upsert_in_db(db, resource, changeset, keys, identity, %{})
      end)
    end

    @doc """
    Atomically destroys an entity after verifying `changeset.filter`, `changeset.atomic_validations`,
    and incoming same-store foreign-key `on_delete` rules (`:restrict`, `:nilify`, `:delete`).
    """
    @spec destroy(module(), Ash.Changeset.t()) :: :ok | {:error, term()}
    def destroy(resource, %Ash.Changeset{} = changeset) when is_atom(resource) do
      store = Info.store!(resource)

      case Store.mutate(store, fn db -> destroy_in_db(db, resource, changeset) end) do
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

      result =
        Store.mutate(store, fn initial_db ->
          with {:ok, candidates} <- Query.execute(initial_db, %Query{query | select: nil}, resource) do
            apply_bulk_destroys(initial_db, candidates, resource, changeset)
          end
        end)

      case result do
        {:ok, destroyed_records} ->
          if return_records?, do: {:ok, destroyed_records}, else: :ok

        {:error, _} = err ->
          err
      end
    end

    # -- Internal In-Transaction Create / Update / Upsert / Destroy --

    defp create_in_db(db, resource, %Ash.Changeset{} = changeset) do
      with {:ok, base_record} <- Ash.Changeset.apply_attributes(changeset),
           {:ok, db_with_seq, record_with_pk} <- allocate_or_advance_pk(db, resource, base_record),
           :ok <- verify_pk_unused(db_with_seq, resource, record_with_pk),
           record <- maybe_put_tenant_metadata(resource, record_with_pk, changeset.tenant),
           :ok <- verify_atomic_validations(record, resource, changeset),
           {:ok, next_db} <- Indexer.put_record(db_with_seq, resource, nil, record, changeset.tenant) do
        {:ok, next_db, record}
      end
    end

    defp update_in_db(db, resource, %Ash.Changeset{} = changeset) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_val = Map.get(changeset.data, pk_name) || Ash.Changeset.get_attribute(changeset, pk_name)

      case load_existing_record(db, resource, pk_val, changeset.tenant) do
        :none ->
          {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

        {:ok, current_record} ->
          case build_updated_record(current_record, resource, changeset, nil) do
            {:ok, updated_record} ->
              with {:ok, db_seq, synced_record} <- allocate_or_advance_pk(db, resource, updated_record),
                   {:ok, next_db} <-
                     Indexer.put_record(db_seq, resource, current_record, synced_record, changeset.tenant) do
                {:ok, next_db, synced_record}
              end

            :filtered_out ->
              {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

            {:error, _} = err ->
              err
          end
      end
    end

    defp upsert_in_db(db, resource, %Ash.Changeset{} = changeset, keys, identity, bulk_opts) do
      with {:ok, candidate_record} <- Ash.Changeset.apply_attributes(changeset) do
        case find_upsert_target(db, resource, candidate_record, keys, identity, changeset.tenant) do
          :none ->
            create_in_db(db, resource, changeset)

          {:ok, existing_record} ->
            upsert_fields = resolve_upsert_fields(changeset, bulk_opts)

            case build_updated_record(existing_record, resource, changeset, upsert_fields) do
              {:ok, updated_record} ->
                with {:ok, next_db} <-
                       Indexer.put_record(
                         db,
                         resource,
                         existing_record,
                         updated_record,
                         changeset.tenant
                       ) do
                  {:ok, next_db, updated_record}
                end

              :filtered_out ->
                {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

              {:error, _} = err ->
                err
            end
        end
      end
    end

    defp destroy_in_db(db, resource, %Ash.Changeset{} = changeset) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_val = Map.get(changeset.data, pk_name)

      case load_existing_record(db, resource, pk_val, changeset.tenant) do
        :none ->
          {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

        {:ok, current_record} ->
          with :ok <- verify_changeset_filter(current_record, changeset),
               :ok <- verify_atomic_validations(current_record, resource, changeset),
               {:ok, next_db} <-
                 cascade_and_delete(db, resource, current_record, changeset.tenant, MapSet.new()) do
            {:ok, next_db, current_record}
          else
            :filtered_out ->
              {:error, StaleRecord.exception(resource: resource, filter: changeset.filter)}

            {:error, _} = err ->
              err
          end
      end
    end

    defp apply_bulk_updates(initial_db, candidates, resource, %Ash.Changeset{} = changeset) do
      candidates
      |> Enum.reduce_while({:ok, initial_db, []}, fn current_record, {:ok, acc_db, acc_records} ->
        case build_updated_record(current_record, resource, changeset, nil) do
          {:ok, updated_record} ->
            case Indexer.put_record(acc_db, resource, current_record, updated_record, changeset.tenant) do
              {:ok, next_db} -> {:cont, {:ok, next_db, [updated_record | acc_records]}}
              {:error, _} = err -> {:halt, err}
            end

          :filtered_out ->
            # In bulk queries, records rejected by `changeset.filter` are skipped unless
            # an atomic_validation explicitly failed.
            {:cont, {:ok, acc_db, acc_records}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, final_db, rev_records} -> {:ok, final_db, Enum.reverse(rev_records)}
        {:error, _} = err -> err
      end
    end

    defp apply_bulk_destroys(initial_db, candidates, resource, %Ash.Changeset{} = changeset) do
      candidates
      |> Enum.reduce_while({:ok, initial_db, []}, fn current_record, {:ok, acc_db, acc_records} ->
        with :ok <- verify_changeset_filter(current_record, changeset),
             :ok <- verify_atomic_validations(current_record, resource, changeset),
             {:ok, next_db} <-
               cascade_and_delete(acc_db, resource, current_record, changeset.tenant, MapSet.new()) do
          {:cont, {:ok, next_db, [current_record | acc_records]}}
        else
          :filtered_out ->
            {:cont, {:ok, acc_db, acc_records}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
      |> case do
        {:ok, final_db, rev_records} -> {:ok, final_db, Enum.reverse(rev_records)}
        {:error, _} = err -> err
      end
    end

    # -- Atomic Filter, Validation & Expression Evaluation --

    defp build_updated_record(current_record, resource, %Ash.Changeset{} = changeset, upsert_fields) do
      with :ok <- verify_changeset_filter(current_record, changeset),
           :ok <- verify_atomic_validations(current_record, resource, changeset) do
        allowed_attrs = filter_allowed_attributes(changeset.attributes, resource, upsert_fields)
        merged_record = Map.merge(current_record, allowed_attrs)
        apply_atomic_expressions(merged_record, resource, changeset, upsert_fields)
      end
    end

    defp filter_allowed_attributes(attrs_map, _resource, nil), do: attrs_map

    defp filter_allowed_attributes(attrs_map, resource, upsert_fields) when is_list(upsert_fields) do
      pk_fields = Ash.Resource.Info.primary_key(resource)
      allowed = MapSet.difference(MapSet.new(upsert_fields), MapSet.new(pk_fields))
      Map.filter(attrs_map, fn {k, _v} -> MapSet.member?(allowed, k) end)
    end

    defp verify_changeset_filter(_record, %Ash.Changeset{filter: nil}), do: :ok

    defp verify_changeset_filter(record, %Ash.Changeset{} = changeset) do
      actor = get_in(changeset.context, [:private, :actor])

      case Ash.Filter.Runtime.matches?(
             changeset.domain,
             record,
             changeset.filter,
             actor: actor,
             tenant: changeset.tenant,
             authorize?: false
           ) do
        {:ok, true} -> :ok
        true -> :ok
        {:ok, false} -> :filtered_out
        false -> :filtered_out
        {:error, _} = err -> err
      end
    end

    defp verify_atomic_validations(record, resource, %Ash.Changeset{} = changeset) do
      validations = Map.get(changeset, :atomic_validations, [])
      actor = get_in(changeset.context, [:private, :actor])

      Enum.reduce_while(validations, :ok, fn {check_expr, error_expr}, :ok ->
        case eval_expr_against_record(check_expr, record, resource, changeset, actor) do
          {:ok, truthy} when truthy not in [false, nil] ->
            {:cont, :ok}

          {:ok, _falsy} ->
            {:halt, {:error, materialize_validation_error(error_expr, record, resource, changeset, actor)}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    end

    defp apply_atomic_expressions(record, resource, %Ash.Changeset{} = changeset, upsert_fields) do
      atomics = Map.get(changeset, :atomics, [])
      actor = get_in(changeset.context, [:private, :actor])
      pk_fields = Ash.Resource.Info.primary_key(resource)

      filtered_atomics =
        if is_list(upsert_fields) do
          allowed = MapSet.difference(MapSet.new(upsert_fields), MapSet.new(pk_fields))
          Enum.filter(atomics, fn {field, _expr} -> MapSet.member?(allowed, field) end)
        else
          atomics
        end

      Enum.reduce_while(filtered_atomics, {:ok, record}, fn {field, expr}, {:ok, acc_record} ->
        attr = Ash.Resource.Info.attribute(resource, field)

        with {:ok, raw_val} <- eval_expr_against_record(expr, acc_record, resource, changeset, actor),
             {:ok, casted_val} <- cast_atomic_value(attr, raw_val) do
          {:cont, {:ok, Map.put(acc_record, field, casted_val)}}
        else
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp eval_expr_against_record(expr, record, resource, %Ash.Changeset{} = changeset, actor) do
      opts = [
        record: record,
        resource: resource,
        domain: changeset.domain,
        actor: actor,
        tenant: changeset.tenant,
        context: changeset.context
      ]

      case Ash.Expr.eval(expr, opts) do
        {:ok, value} ->
          {:ok, value}

        :unknown ->
          case Ash.Filter.hydrate_refs(expr, %{resource: resource, public?: false}) do
            {:ok, hydrated} ->
              case Ash.Expr.eval(hydrated, opts) do
                {:ok, val} -> {:ok, val}
                {:error, _} = err -> err
                :unknown -> {:ok, nil}
              end

            {:error, _} = err ->
              err
          end

        {:error, _} = err ->
          err
      end
    end

    defp materialize_validation_error(error_expr, record, resource, changeset, actor) do
      case eval_expr_against_record(error_expr, record, resource, changeset, actor) do
        {:ok, %_{} = exc} when is_exception(exc) ->
          exc

        {:ok, {error_mod, opts}} when is_atom(error_mod) and is_list(opts) ->
          error_mod.exception(opts)

        {:error, reason} ->
          reason

        other ->
          InvalidChanges.exception(message: inspect(other))
      end
    end

    defp cast_atomic_value(_attr, nil), do: {:ok, nil}
    defp cast_atomic_value(nil, val), do: {:ok, val}

    defp cast_atomic_value(%Ash.Resource.Attribute{} = attr, val) do
      case Ash.Type.cast_input(attr.type, val, attr.constraints) do
        {:ok, casted} -> {:ok, casted}
        {:error, reason} -> {:error, InvalidChanges.exception(fields: [attr.name], message: inspect(reason))}
      end
    end

    # -- Sequence Allocation, Duplicate-PK Guard & Upsert Target Lookup --

    defp allocate_or_advance_pk(db, resource, record) do
      case Ash.Resource.Info.primary_key(resource) do
        [pk_name] ->
          attr = Ash.Resource.Info.attribute(resource, pk_name)
          current_val = Map.get(record, pk_name)
          collection = resource |> Info.collection!() |> Atom.to_string()

          cond do
            integer_attribute?(attr) and is_nil(current_val) and Map.get(attr, :generated?, false) ->
              {next_db, allocated_id} = Sequences.next_id(db, collection)
              {:ok, next_db, Map.put(record, pk_name, allocated_id)}

            integer_attribute?(attr) and is_integer(current_val) ->
              next_db = Sequences.advance_at_least(db, collection, current_val)
              {:ok, next_db, record}

            true ->
              {:ok, db, record}
          end

        _composite_pk ->
          {:ok, db, record}
      end
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

    defp verify_pk_unused(db, resource, record) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_val = Map.get(record, pk_name)

      if is_nil(pk_val) do
        {:error, InvalidChanges.exception(fields: [pk_name], message: "is required")}
      else
        case Indexer.fetch_cursor(db, resource, pk_val) do
          :none ->
            :ok

          {:ok, _existing} ->
            {:error,
             InvalidChanges.exception(
               fields: [pk_name],
               message: "has already been taken"
             )}
        end
      end
    end

    defp find_upsert_target(db, resource, candidate_record, keys, identity, tenant) do
      pk_fields = Ash.Resource.Info.primary_key(resource)

      cond do
        identity != nil ->
          lookup_existing_by_identity(db, resource, identity, candidate_record, tenant)

        Enum.sort(keys) == Enum.sort(pk_fields) ->
          pk_val = Map.get(candidate_record, hd(pk_fields))
          load_existing_record(db, resource, pk_val, tenant)

        true ->
          matched_identity =
            resource
            |> Ash.Resource.Info.identities()
            |> Enum.find(fn id -> Enum.sort(id.keys) == Enum.sort(keys) end)

          if matched_identity != nil do
            lookup_existing_by_identity(db, resource, matched_identity, candidate_record, tenant)
          else
            :none
          end
      end
    end

    defp lookup_existing_by_identity(db, resource, identity, candidate_record, tenant) do
      with true <- candidate_matches_identity_where?(candidate_record, Map.get(identity, :where)),
           {:ok, doc_id} <- Indexer.lookup_by_identity(db, resource, identity, candidate_record, tenant),
           {:ok, pk_val} <- Codec.decode_doc_id(resource, doc_id) do
        load_existing_record(db, resource, pk_val, tenant)
      else
        _ -> :none
      end
    end

    defp candidate_matches_identity_where?(_record, nil), do: true

    defp candidate_matches_identity_where?(record, where_filter) do
      case Ash.Filter.Runtime.matches?(nil, record, where_filter) do
        {:ok, matched?} -> matched?
        matched? when is_boolean(matched?) -> matched?
        _ -> false
      end
    end

    defp resolve_upsert_fields(%Ash.Changeset{} = changeset, bulk_opts) do
      case get_in(changeset.context, [:private, :upsert_fields]) || Map.get(bulk_opts, :upsert_fields) do
        fields when is_list(fields) -> fields
        _ -> nil
      end
    end

    # -- Same-Store Reverse FK `on_delete` Enforcement --

    defp cascade_and_delete(db, resource, record, tenant, visited) do
      [pk_name | _] = Ash.Resource.Info.primary_key(resource)
      pk_val = Map.fetch!(record, pk_name)
      visit_key = {resource, Codec.encode_doc_id(pk_val)}

      if MapSet.member?(visited, visit_key) do
        {:ok, db}
      else
        next_visited = MapSet.put(visited, visit_key)
        store = Info.store!(resource)
        rules = Store.reverse_fks(store, resource)

        with {:ok, db_after_fks} <- apply_reverse_fk_rules(db, rules, record, tenant, next_visited) do
          Indexer.delete_record(db_after_fks, resource, record, tenant)
        end
      end
    end

    defp apply_reverse_fk_rules(db, [], _record, _tenant, _visited), do: {:ok, db}

    defp apply_reverse_fk_rules(db, rules, parent_record, tenant, visited) do
      Enum.reduce_while(rules, {:ok, db}, fn rule, {:ok, acc_db} ->
        dest_val = Map.get(parent_record, rule.destination_attribute)

        if is_nil(dest_val) do
          {:cont, {:ok, acc_db}}
        else
          case apply_single_fk_rule(acc_db, rule, dest_val, tenant, visited) do
            {:ok, updated_db} -> {:cont, {:ok, updated_db}}
            {:error, _} = err -> {:halt, err}
          end
        end
      end)
    end

    defp apply_single_fk_rule(db, %{on_delete: :restrict} = rule, dest_val, _tenant, _visited) do
      child_count = count_referencing_children(db, rule, dest_val)

      if child_count > 0 do
        {:error,
         InvalidChanges.exception(
           fields: [rule.destination_attribute],
           message:
             "cannot be destroyed while referenced by #{inspect(rule.source_collection)}"
         )}
      else
        {:ok, db}
      end
    end

    defp apply_single_fk_rule(db, %{on_delete: :nilify} = rule, dest_val, tenant, _visited) do
      children = load_referencing_children(db, rule, dest_val, tenant)

      Enum.reduce_while(children, {:ok, db}, fn child, {:ok, acc_db} ->
        nilified = Map.put(child, rule.source_attribute, nil)

        case Indexer.put_record(acc_db, rule.source_resource, child, nilified, tenant) do
          {:ok, next_db} -> {:cont, {:ok, next_db}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp apply_single_fk_rule(db, %{on_delete: :delete} = rule, dest_val, tenant, visited) do
      children = load_referencing_children(db, rule, dest_val, tenant)

      Enum.reduce_while(children, {:ok, db}, fn child, {:ok, acc_db} ->
        case cascade_and_delete(acc_db, rule.source_resource, child, tenant, visited) do
          {:ok, next_db} -> {:cont, {:ok, next_db}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end

    defp count_referencing_children(db, %{source_resource: res, source_attribute: fk} = rule, dest_val) do
      if Map.get(rule, :nested?, false) do
        length(Indexer.nested_cursors_for_parent(db, res, dest_val))
      else
        Indexer.count_by_attribute(db, res, fk, dest_val)
      end
    end

    defp load_referencing_children(db, %{source_resource: res, source_attribute: fk} = rule, dest_val, tenant) do
      cursors =
        if Map.get(rule, :nested?, false) and Info.nested_in(res).foreign_key == fk do
          Indexer.nested_cursors_for_parent(db, res, dest_val)
        else
          case Info.indexes_for_field(res, fk) do
            [%{fields: [^fk]} = idx | _] ->
              db
              |> Indexer.lookup_secondary_eq(res, idx, [dest_val])
              |> Enum.flat_map(fn doc_id ->
                with {:ok, pk_val} <- Codec.decode_doc_id(res, doc_id),
                     {:ok, cursor} <- Indexer.fetch_cursor(db, res, pk_val) do
                  [{doc_id, cursor}]
                else
                  _ -> []
                end
              end)

            _ ->
              Indexer.all_cursors(db, res)
          end
        end

      cursors
      |> Enum.flat_map(fn {_doc_id, cursor} ->
        case Codec.from_cursor(res, cursor, tenant) do
          {:ok, child} -> if Map.get(child, fk) == dest_val, do: [child], else: []
          {:error, _} -> []
        end
      end)
    end

    # -- Record Hydration & Metadata Helpers --

    defp load_existing_record(_db, _resource, nil, _tenant), do: :none

    defp load_existing_record(db, resource, pk_val, tenant) do
      case Indexer.fetch_cursor(db, resource, pk_val) do
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

    defp maybe_put_tenant_metadata(_resource, record, nil), do: record

    defp maybe_put_tenant_metadata(resource, record, tenant) do
      record =
        if Ash.Resource.Info.multitenancy_strategy(resource) == :attribute do
          tenant_attr = Ash.Resource.Info.multitenancy_attribute(resource)
          if is_nil(Map.get(record, tenant_attr)), do: Map.put(record, tenant_attr, tenant), else: record
        else
          record
        end

      Ash.Resource.put_metadata(record, :tenant, tenant)
    end

    defp attach_bulk_index(record, %Ash.Changeset{} = cs, fallback_idx) do
      idx = get_in(cs.context, [:bulk_create, :index]) || fallback_idx
      Ash.Resource.put_metadata(record, :bulk_create_index, idx)
    end
  end

  defmodule Xitdb.Ash.Mutator.Sequences do
    @moduledoc false
    # Thin slot-tree adapter over `root["meta"]["sequences"][collection]`.

    @spec next_id(term(), String.t()) :: {term(), pos_integer()}
    def next_id(db, collection) when is_binary(collection) do
      current = read_current(db, collection)
      next = current + 1

      next_db =
        Xitdb.transact(db, fn root ->
          meta = Xitdb.Map.ensure(root, "meta", :hash_map)
          seqs = Xitdb.Map.ensure(meta, "sequences", :hash_map)
          Xitdb.Map.put(seqs, collection, next)
        end)

      {next_db, next}
    end

    @spec advance_at_least(term(), String.t(), integer()) :: term()
    def advance_at_least(db, collection, explicit_id)
        when is_binary(collection) and is_integer(explicit_id) do
      current = read_current(db, collection)

      if explicit_id > current do
        Xitdb.transact(db, fn root ->
          meta = Xitdb.Map.ensure(root, "meta", :hash_map)
          seqs = Xitdb.Map.ensure(meta, "sequences", :hash_map)
          Xitdb.Map.put(seqs, collection, explicit_id)
        end)
      else
        db
      end
    end

    defp read_current(db, collection) do
      with root when not is_nil(root) <- Xitdb.root(db),
           meta when not is_nil(meta) <- root["meta"],
           seqs when not is_nil(seqs) <- meta["sequences"],
           val when is_integer(val) <- seqs[collection] do
        val
      else
        _ -> 0
      end
    end
  end
end

```

