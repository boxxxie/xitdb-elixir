if Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Reference do
    @moduledoc """
    Declares foreign key cascade actions (`:nothing`, `:delete`, `:nilify`, `:restrict`)
    for relationships targeting same-store resources.
    """

    @type t :: %__MODULE__{
            relationship: atom(),
            on_delete: :nothing | :delete | :nilify | :restrict,
            __identifier__: term(),
            __spark_metadata__: term()
          }

    defstruct [
      :relationship,
      :__identifier__,
      :__spark_metadata__,
      on_delete: :nothing
    ]
  end
end
