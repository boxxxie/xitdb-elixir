if Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Index do
    @moduledoc """
    Declares an explicit single-attribute or composite B+Tree secondary index
    on an `Xitdb.Ash.Resource`.
    """

    @type t :: %__MODULE__{
            fields: [atom()],
            name: String.t() | atom() | nil,
            __identifier__: term(),
            __spark_metadata__: term()
          }

    defstruct [
      :fields,
      :name,
      :__identifier__,
      :__spark_metadata__
    ]
  end
end
