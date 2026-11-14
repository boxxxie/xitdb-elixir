if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Store do
    @moduledoc false

    defmacro __using__(_opts) do
      quote do
        def start_link(opts \\ []) do
          Xitdb.Ash.Store.start_link(Keyword.put_new(opts, :name, __MODULE__))
        end

        def current_db, do: Xitdb.Ash.Store.current_db(__MODULE__)
        def in_transaction?, do: Xitdb.Ash.Store.in_transaction?(__MODULE__)
        def transact(fun, opts \\ []), do: Xitdb.Ash.Store.transact(__MODULE__, fun, opts)
        def mutate(fun, opts \\ []), do: Xitdb.Ash.Store.mutate(__MODULE__, fun, opts)
        def rollback(reason), do: Xitdb.Ash.Store.rollback(__MODULE__, reason)
      end
    end

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)

      case Process.whereis(name) do
        nil -> Agent.start_link(fn -> :stub end, name: name)
        pid -> {:ok, pid}
      end
    end

    def current_db(_store), do: :not_implemented
    def in_transaction?(_store), do: false
    def transact(_store, _fun, _opts \\ []), do: {:error, :not_implemented}
    def mutate(_store, _fun, _opts \\ []), do: {:error, :not_implemented}
    def rollback(_store, reason), do: {:error, reason}
  end
end
