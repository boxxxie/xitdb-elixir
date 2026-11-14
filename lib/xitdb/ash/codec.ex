if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Codec do
    @moduledoc false

    def encode_i64_be(_val), do: :not_implemented
    def decode_i64_be(_bin), do: :not_implemented
    def encode_f64_be(_val), do: :not_implemented
    def encode_decimal_key(_val), do: :not_implemented
    def encode_index_key(_attrs, _vals), do: :not_implemented
    def encode_identity_key(_resource, _identity, _record, _tenant \\ nil), do: :not_implemented
  end
end
