defprotocol Xitdb.Encoder do
  @moduledoc """
  Protocol for encoding custom Elixir structs into `Xitdb`-writeable values
  during transactions (`Xitdb.transact/3`, `put_in/3`, `Xitdb.DSL.tx/3`, and
  `Xitdb.insert_at/4`).

  Implementations should return any `Xitdb`-supported value:
  - native scalars (`binary`, `integer`, `float`, `boolean`, `nil`)
  - 2-byte format-tagged binaries (`{:tagged, <<a, b>>, binary}`)
  - plain maps (`%{}`), lists (`[]`), `%MapSet{}`, or `%Xitdb.Collection{}` wrappers
  - another struct implementing `Xitdb.Encoder` (encoded recursively)

  ## Built-in Implementations

  | Struct | Encoded Value |
  | :--- | :--- |
  | `%Decimal{}` *(when `Decimal` is loaded)* | `{:tagged, "dc", Decimal.to_string(dec, :normal)}` |
  | `%Date{}` | `{:tagged, "dt", Date.to_iso8601(d)}` |
  | `%Time{}` | `{:tagged, "tm", Time.to_iso8601(t)}` |
  | `%DateTime{}` | `{:tagged, "ts", <<DateTime.to_unix(dt, :microsecond)::signed-big-64>>}` |
  | `%NaiveDateTime{}` | `{:tagged, "nt", NaiveDateTime.to_iso8601(ndt)}` |
  """

  @doc """
  Encodes `value` into a `Xitdb`-compatible term.
  """
  @spec encode(t()) :: term()
  def encode(value)
end

if Code.ensure_loaded?(Decimal) do
  defimpl Xitdb.Encoder, for: Decimal do
    def encode(%Decimal{} = dec) do
      {:tagged, "dc", Decimal.to_string(dec, :normal)}
    end
  end
end

defimpl Xitdb.Encoder, for: Date do
  def encode(%Date{} = date) do
    {:tagged, "dt", Date.to_iso8601(date)}
  end
end

defimpl Xitdb.Encoder, for: Time do
  def encode(%Time{} = time) do
    {:tagged, "tm", Time.to_iso8601(time)}
  end
end

defimpl Xitdb.Encoder, for: DateTime do
  def encode(%DateTime{} = dt) do
    {:tagged, "ts", <<DateTime.to_unix(dt, :microsecond)::signed-big-64>>}
  end
end

defimpl Xitdb.Encoder, for: NaiveDateTime do
  def encode(%NaiveDateTime{} = ndt) do
    {:tagged, "nt", NaiveDateTime.to_iso8601(ndt)}
  end
end
