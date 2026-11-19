if Code.ensure_loaded?(Ash.Resource) do
  defmodule Xitdb.Ash.Compress do
    @moduledoc """
    Declares transparent value-level or Parquet-style row-group compression for one
    or more attributes on a `Xitdb.Ash.DataLayer` resource (`Xitdb.Ash.Dsl`).
    """

    @type mode :: :value | :row_group
    @type codec :: :zstd | :zlib | :none
    @type encoding :: :auto | :plain_block | :dict_rle | :dict_block

    @type t :: %__MODULE__{
            fields: [atom()],
            mode: mode(),
            codec: codec(),
            level: integer() | nil,
            min_bytes: non_neg_integer(),
            min_savings: non_neg_integer(),
            dictionary: atom() | String.t() | nil,
            intern_above: pos_integer() | nil,
            row_group_size: pos_integer(),
            encoding: encoding(),
            __identifier__: term(),
            __spark_metadata__: term()
          }

    defstruct [
      :fields,
      mode: :value,
      codec: :zstd,
      level: nil,
      min_bytes: 128,
      min_savings: 16,
      dictionary: nil,
      intern_above: nil,
      row_group_size: 128,
      encoding: :auto,
      __identifier__: nil,
      __spark_metadata__: nil
    ]
  end
end
