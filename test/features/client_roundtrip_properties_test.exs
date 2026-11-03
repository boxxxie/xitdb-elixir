defmodule Xitdb.Features.ClientRoundtripPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xitdb

  defp key_gen do
    string(:alphanumeric, min_length: 1, max_length: 16)
  end

  defp scalar_gen do
    one_of([
      string(:printable, max_length: 48),
      integer(-100_000..100_000),
      float(min: -1.0e4, max: 1.0e4),
      boolean()
    ])
  end

  defp document_gen do
    fixed_map(%{
      "title" => string(:printable, min_length: 1, max_length: 32),
      "count" => integer(0..50_000),
      "delta" => integer(-50_000..-1),
      "enabled" => boolean(),
      "items" => list_of(scalar_gen(), max_length: 8),
      "attributes" => map_of(key_gen(), scalar_gen(), max_length: 6),
      "tags" => map(list_of(key_gen(), max_length: 6), &MapSet.new/1)
    })
  end

  property "arbitrary nested Elixir documents round-trip identically through lazy Access, Enumerable, and Xitdb.materialize/1" do
    check all(doc <- document_gen(), max_runs: 40) do
      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        payload = Map.update!(doc, "tags", &Xitdb.counted_set(MapSet.to_list(&1)))
        {:ok, db} = Xitdb.transact(db, %{"doc" => payload})

        root = Xitdb.db(db)
        doc_cursor = root["doc"]

        assert doc_cursor["title"] == doc["title"]
        assert doc_cursor["count"] == doc["count"]
        assert doc_cursor["delta"] == doc["delta"]
        assert doc_cursor["enabled"] == doc["enabled"]
        assert Enum.count(doc_cursor["items"]) == length(doc["items"])
        assert Enum.to_list(doc_cursor["items"]) == doc["items"]
        assert Xitdb.materialize(doc_cursor) == doc
      after
        Xitdb.close(db)
      end
    end
  end
end
