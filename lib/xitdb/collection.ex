defmodule Xitdb.Collection do
  @moduledoc """
  Wrapper struct for opting into explicit `xitdb` collection types when writing data.

  Plain Elixir maps (`%{}`), lists (`[]`), and `MapSet`s work automatically out of the box
  (stored as `:hash_map`, `:array_list`, and `:counted_hash_set`). Use the constructors on
  `Xitdb` (`Xitdb.counted_map/1`, `Xitdb.sorted_map/1`, `Xitdb.linked_list/1`,
  `Xitdb.sorted_set/1`, etc.) when you want instant `O(1)` `Enum.count/1`, sorted B+Tree
  key iteration and range queries, or `O(log N)` middle-of-list insertions and removals.

  Supported `:kind` values:
  - `:hash_map` — Uncounted hash map (default for `%{}`)
  - `:counted_hash_map` — Hash map with `O(1)` `Enum.count/1` (`Xitdb.counted_map/1`)
  - `:sorted_map` — Lexicographically ordered B+Tree map (`Xitdb.sorted_map/1`)
  - `:array_list` — Append-friendly indexed list (default for `[]`)
  - `:linked_array_list` — List supporting `O(log N)` insert, remove, and slice (`Xitdb.linked_list/1`)
  - `:hash_set` — Uncounted set (`Xitdb.hash_set/1`)
  - `:counted_hash_set` — Set with `O(1)` `Enum.count/1` (default for `%MapSet{}`, `Xitdb.counted_set/1`)
  - `:sorted_set` — Lexicographically ordered set (`Xitdb.sorted_set/1`)

  See [Collections & Secondary Indexes](docs/collections-and-indexing.md) for a full guide.
  """
  @enforce_keys [:kind, :data]
  defstruct [:kind, :data]

  @type kind ::
          :hash_map
          | :counted_hash_map
          | :sorted_map
          | :array_list
          | :linked_array_list
          | :hash_set
          | :counted_hash_set
          | :sorted_set

  @type t :: %__MODULE__{
          kind: kind(),
          data: term()
        }
end
