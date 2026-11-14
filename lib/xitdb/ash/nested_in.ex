defmodule Xitdb.Ash.NestedIn do
  @moduledoc """
  Declares that an `Xitdb.Ash.Resource` lives inside a parent entity instead of in its
  own top-level collection.

  A resource can be nested in more than one parent. For example, a phone number can
  belong to a person or to an organization:

      xitdb do
        nested_in MyApp.Accounts.User,
          as: :phones,
          parent_key: :user_id,
          key: :e164

        nested_in MyApp.Accounts.Organization,
          as: :phones,
          parent_key: :organization_id,
          key: :e164
      end

  With the declarations above, a phone owned by user `"42"` is stored at
  `people["42"].phones["+14165550199"]`, where `:people` is the parent's `collection`.

  ## Fields

    * `:parent` - the parent `Xitdb.Ash.Resource`. The parent must declare a top-level
      `collection`; nesting is one level deep.
    * `:as` - the slot name under the parent entity (`:phones`, `:tenures`, `:sessions`).
    * `:parent_key` - the attribute on this resource that holds the parent entity id.
    * `:key` - the attribute whose value is the entry key inside the sub-collection.
      Required when `:cardinality` is `:many`.
    * `:cardinality` - `:many` (a map of entries, the default) or `:one` (a single map
      stored directly at the slot, such as an event's conference).
  """

  @type t :: %__MODULE__{
          parent: module() | nil,
          as: atom() | nil,
          parent_key: atom() | nil,
          key: atom() | nil,
          parent_collection: atom() | nil,
          foreign_key: atom() | nil,
          path: atom() | nil,
          cardinality: :one | :many,
          __identifier__: term(),
          __spark_metadata__: term()
        }

  defstruct [
    :parent,
    :as,
    :parent_key,
    :key,
    :parent_collection,
    :foreign_key,
    :path,
    cardinality: :many,
    __identifier__: nil,
    __spark_metadata__: nil
  ]
end
