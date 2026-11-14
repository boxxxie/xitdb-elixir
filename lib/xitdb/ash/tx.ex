defmodule Xitdb.Ash.Tx do
  @moduledoc """
  Resource-aware transaction macro wrapper (`tx_for/3,4`, `tx_for!/3,4`) that automatically
  injects `index_on` rules declared in one or more `Xitdb.Ash.Resource` modules (or plain
  schema modules exporting `__xitdb_collection__/0` and `__xitdb_indexes__/0`).

  Re-exports `Xitdb.DSL.tx_for/3,4` and `Xitdb.DSL.tx_for!/3,4` under the `Xitdb.Ash` namespace.
  """

  defmacro tx_for(db, resources, do: body) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.tx_for(unquote(db), unquote(resources), [], do: unquote(body))
    end
  end

  defmacro tx_for(db, resources, opts, do: body) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.tx_for(unquote(db), unquote(resources), unquote(opts), do: unquote(body))
    end
  end

  defmacro tx_for!(db, resources, do: body) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.tx_for!(unquote(db), unquote(resources), [], do: unquote(body))
    end
  end

  defmacro tx_for!(db, resources, opts, do: body) do
    quote do
      require Xitdb.DSL
      Xitdb.DSL.tx_for!(unquote(db), unquote(resources), unquote(opts), do: unquote(body))
    end
  end
end
