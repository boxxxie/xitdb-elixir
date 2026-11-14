defmodule Xitdb.Ash.Tx do
  @moduledoc """
  Provides `tx_for/3`, `tx_for/4`, `tx_for!/3`, and `tx_for!/4` macros that wrap
  `Xitdb.DSL.tx` and automatically inject all single-field `index_on` declarations
  configured on one or more `Xitdb.Ash.Resource` or `Xitdb.Ash.DataLayer` modules.

  Note: `use Xitdb.DSL` also imports `tx_for` and `tx_for!` directly.
  """

  defmacro tx_for(db, resources, do: body) do
    quote do
      Xitdb.DSL.tx_for(unquote(db), unquote(resources), [], do: unquote(body))
    end
  end

  defmacro tx_for(db, resources, opts, do: body) do
    quote do
      Xitdb.DSL.tx_for(unquote(db), unquote(resources), unquote(opts), do: unquote(body))
    end
  end

  defmacro tx_for!(db, resources, do: body) do
    quote do
      Xitdb.DSL.tx_for!(unquote(db), unquote(resources), [], do: unquote(body))
    end
  end

  defmacro tx_for!(db, resources, opts, do: body) do
    quote do
      Xitdb.DSL.tx_for!(unquote(db), unquote(resources), unquote(opts), do: unquote(body))
    end
  end
end
