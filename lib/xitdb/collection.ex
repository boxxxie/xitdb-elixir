defmodule Xitdb.Collection do
  @moduledoc """
  Explicit wrapper struct for selecting a specific `xitdb` persistent collection
  backing structure when writing nested data in `Xitdb.transact/3`.

  Supported `:kind` values:
  - `:hash_map` — 16-way HAMT (`Tag.Hash_Map`, `.key`)
  - `:counted_hash_map` — 16-way HAMT with `O(1)` count header (`Tag.Counted_Hash_Map`, `#key`)
  - `:sorted_map` — Count-augmented B+Tree ordered lexicographically (`Tag.Sorted_Map`, `$key`)
  - `:array_list` — 16-way Radix Trie (`Tag.Array_List`, `[i]`)
  - `:linked_array_list` — Count-augmented B-Tree with `O(log N)` insert/remove/slice (`Tag.Linked_Array_List`, `[[i]]`)
  - `:hash_set` — 16-way HAMT set (`Tag.Hash_Set`, `%member`)
  - `:counted_hash_set` — 16-way HAMT set with `O(1)` count header (`Tag.Counted_Hash_Set`, `#%member`)
  - `:sorted_set` — Count-augmented B+Tree set (`Tag.Sorted_Set`, `^member`)
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
