if Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.SearchField do
    @moduledoc """
    Declares a field indexed for transactional BM25 and B+Tree prefix search
    in `idx.search.<collection>`.
    """

    @type t :: %__MODULE__{
            field: atom(),
            boost: float(),
            resolver: (struct(), term() -> term()) | nil,
            __identifier__: term(),
            __spark_metadata__: term()
          }

    defstruct [
      :field,
      :resolver,
      :__identifier__,
      :__spark_metadata__,
      boost: 1.0
    ]
  end
end
