defmodule Xitdb.Ash.NestedIn do
  @moduledoc """
  Declares that a `Xitdb.Ash.DataLayer` resource is co-located inside a parent
  entity cursor (`root[parent_collection][parent_id][path]`) instead of its own
  top-level collection.

      xitdb do
        store MyApp.Store
        collection :sessions
        nested_in :events, foreign_key: :event_id, path: :sessions, cardinality: :many
      end

  ## Fields

    * `:parent_collection` - parent collection atom at the `.xit` root.
    * `:foreign_key` - attribute on this resource storing the parent primary key.
    * `:path` - map key inside the parent entity cursor holding child cursor(s).
    * `:cardinality` - `:many` (a map of keyed entries, default) or `:one` (single embedded map).
  """

  @type t :: %__MODULE__{
          parent_collection: atom() | nil,
          foreign_key: atom() | nil,
          path: atom() | nil,
          cardinality: :one | :many,
          __identifier__: term(),
          __spark_metadata__: term()
        }

  defstruct [
    :parent_collection,
    :foreign_key,
    :path,
    cardinality: :many,
    __identifier__: nil,
    __spark_metadata__: nil
  ]
end
