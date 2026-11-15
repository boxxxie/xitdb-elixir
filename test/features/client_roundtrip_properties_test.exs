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

  property "adversarial map keys round-trip through transact, Access, materialize, select, and history_of" do
    special_chars = [
      "\"",
      "'",
      "\\",
      "\n",
      "\r",
      "\t",
      "[",
      "]",
      ".",
      "#",
      "$",
      "%",
      "^",
      "{",
      "}",
      ",",
      " ",
      "a",
      "1"
    ]

    key_gen =
      one_of([
        constant(~S(k."q"\b\n\r\t[]#$%^{}, )),
        map(list_of(member_of(special_chars), min_length: 1, max_length: 10), &Enum.join/1)
      ])

    val_gen = one_of([integer(-1_000..1_000), string(:alphanumeric, max_length: 12), boolean()])

    check all(key <- key_gen, v1 <- val_gen, raw_v2 <- val_gen, max_runs: 35) do
      v2 =
        if raw_v2 === v1 do
          if is_integer(v1), do: v1 + 1, else: "#{v1}_changed"
        else
          raw_v2
        end

      {:ok, db} = Xitdb.open(backend: :memory)

      try do
        {:ok, db} = Xitdb.transact(db, %{"box" => %{key => v1}})
        {:ok, db} = Xitdb.transact(db, fn root -> put_in(root["box"][key], v2) end)
        # Unrelated transaction leaves the slot unchanged so history_of ignores moment 2
        {:ok, db} = Xitdb.transact(db, fn root -> put_in(root["unrelated"], 1) end)

        assert Xitdb.db(db)["box"][key] == v2
        assert Xitdb.materialize(Xitdb.db(db)["box"]) == %{key => v2}

        sel = Xitdb.Selector.format_path_steps(["box", key])
        assert {:ok, ^v2} = Xitdb.select(db, sel)
        assert {:ok, history} = Xitdb.history_of(db, sel)
        assert Enum.map(history, &{&1.moment_index, &1.value}) == [{0, v1}, {1, v2}]
      after
        Xitdb.close(db)
      end
    end
  end
end
