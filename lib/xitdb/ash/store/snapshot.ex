if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Store.Snapshot do
    @moduledoc false

    alias Xitdb.Ash.TestSandbox

    @type reverse_fk :: %{
            source_resource: module(),
            source_collection: atom(),
            source_attribute: atom(),
            destination_attribute: atom(),
            on_delete: :delete | :nilify | :restrict
          }

    @type reverse_fk_map :: %{optional(module()) => [reverse_fk()]}

    @uncommitted_moment -1

    @doc """
    Publishes `{base_db, atomics_ref, reverse_fks}` to `:persistent_term` once at store boot.
    """
    @spec put_base(module(), term(), keyword()) :: :ok
    def put_base(store, base_db, opts \\ []) when is_atom(store) and is_list(opts) do
      initial_moment = Keyword.get(opts, :moment, @uncommitted_moment)
      reverse_fks = Keyword.get(opts, :reverse_fks, %{})

      atomics = :atomics.new(1, signed: true)
      :ok = :atomics.put(atomics, 1, initial_moment)
      :persistent_term.put(pt_key(store), {base_db, atomics, reverse_fks})
    end

    @doc """
    Replaces `base_db` after a background `.xit` file compaction while preserving `reverse_fks`.
    """
    @spec swap_compacted_base(module(), term(), integer()) :: :ok
    def swap_compacted_base(store, compacted_db, moment)
        when is_atom(store) and is_integer(moment) and moment >= @uncommitted_moment do
      {_old_db, atomics, reverse_fks} = fetch_slot!(store)
      :ok = :atomics.put(atomics, 1, moment)
      :persistent_term.put(pt_key(store), {compacted_db, atomics, reverse_fks})
    end

    @doc """
    Advances the published snapshot moment in ~5ns with zero heap allocation or global GC.
    """
    @spec advance_moment(module(), non_neg_integer()) :: :ok
    def advance_moment(store, moment)
        when is_atom(store) and is_integer(moment) and moment >= 0 do
      {_base_db, atomics, _reverse_fks} = fetch_slot!(store)
      :atomics.put(atomics, 1, moment)
    end

    @doc """
    Returns the latest committed integer moment, or `-1` before the first write commit.
    """
    @spec current_moment(module()) :: integer()
    def current_moment(store) when is_atom(store) do
      {_base_db, atomics, _reverse_fks} = fetch_slot!(store)
      :atomics.get(atomics, 1)
    end

    @doc """
    Resolves the active database handle in 3 lock-free tiers:
    1. Caller's active transaction working handle (`{:xitdb_tx_db, store}`).
    2. Caller or `$callers` isolated `TestSandbox` CoW handle.
    3. Latest committed `Xitdb.as_of/2` moment from `{base_db, atomics}`.
    """
    @spec current_db(module()) :: term()
    def current_db(store) when is_atom(store) do
      case Process.get({:xitdb_tx_db, store}) do
        nil -> sandbox_or_committed_db(store)
        tx_db -> tx_db
      end
    end

    @doc """
    Returns the latest committed `%Xitdb{}` snapshot directly, bypassing tx/sandbox overrides.
    """
    @spec committed_db(module()) :: term()
    def committed_db(store) when is_atom(store) do
      {base_db, atomics, _reverse_fks} = fetch_slot!(store)

      case :atomics.get(atomics, 1) do
        @uncommitted_moment -> base_db
        moment -> Xitdb.as_of(base_db, moment)
      end
    end

    @doc """
    Returns incoming same-store foreign-key rules targeting `resource`.
    """
    @spec reverse_fks(module(), module()) :: [reverse_fk()]
    def reverse_fks(store, resource) when is_atom(store) and is_atom(resource) do
      {_base_db, _atomics, reverse_fks} = fetch_slot!(store)
      Map.get(reverse_fks, resource, [])
    end

    @doc """
    Removes the `:persistent_term` entry when stopping dynamically named stores in tests.
    """
    @spec erase(module()) :: boolean()
    def erase(store) when is_atom(store) do
      :persistent_term.erase(pt_key(store))
    end

    defp sandbox_or_committed_db(store) do
      if Code.ensure_loaded?(TestSandbox) and function_exported?(TestSandbox, :checkout_db, 1) do
        case apply(TestSandbox, :checkout_db, [store]) do
          {:ok, sandbox_db} -> sandbox_db
          :none -> committed_db(store)
        end
      else
        committed_db(store)
      end
    end

    defp fetch_slot!(store) do
      case :persistent_term.get(pt_key(store), nil) do
        nil ->
          raise ArgumentError,
                "Xitdb.Ash.Store #{inspect(store)} is not started or has no initialized Snapshot"

        slot ->
          slot
      end
    end

    defp pt_key(store), do: {__MODULE__, store}
  end
end
