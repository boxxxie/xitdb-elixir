defmodule Xitdb.TxCompilerTest do
  use ExUnit.Case, async: true

  alias Xitdb.{Collection, TxCompiler}

  test "encode_value/1 encodes nested structs inside maps, lists, and Collections without re-wrapping plain values" do
    dec = Decimal.new("12.34")
    encoded_dec = Xitdb.Encoder.encode(dec)

    # Plain values pass through unchanged
    assert TxCompiler.encode_value(%{"a" => 1, "b" => [2, 3]}) == %{"a" => 1, "b" => [2, 3]}
    assert TxCompiler.encode_value(Xitdb.sorted_map(%{"a" => 1})) == Xitdb.sorted_map(%{"a" => 1})
    assert TxCompiler.encode_value(Xitdb.array_list([1, 2])) == Xitdb.array_list([1, 2])
    assert TxCompiler.encode_value(Xitdb.hash_set(["a"])) == Xitdb.hash_set(["a"])
    assert TxCompiler.encode_value(MapSet.new(["a"])) == MapSet.new(["a"])

    # List with plain head and struct tail (tests `or` in list_needs_encoding?)
    assert TxCompiler.encode_value([1, dec]) == [1, encoded_dec]

    # Map-backed Collection with nested struct (tests encode_kv_data map clause)
    assert %Collection{kind: :sorted_map, data: %{"a" => 1, "b" => ^encoded_dec}} =
             TxCompiler.encode_value(Xitdb.sorted_map(%{"a" => 1, "b" => dec}))

    # Keyword/list-backed Collection with plain head, non-tuple item, and struct tail
    assert %Collection{
             kind: :counted_hash_map,
             data: [{"a", 1}, :raw_item, {"b", ^encoded_dec}]
           } =
             TxCompiler.encode_value(%Collection{
               kind: :counted_hash_map,
               data: [{"a", 1}, :raw_item, {"b", dec}]
             })

    # ArrayList and LinkedArrayList with plain head + struct tail and non-list enumerable
    assert %Collection{kind: :array_list, data: [1, ^encoded_dec]} =
             TxCompiler.encode_value(Xitdb.array_list([1, dec]))

    assert %Collection{kind: :linked_array_list, data: [^encoded_dec]} =
             TxCompiler.encode_value(%Collection{
               kind: :linked_array_list,
               data: Stream.map([dec], & &1)
             })
  end

  test "compile_node/3 covers array_list, linked_list, nil reset/no-reset, empty maps, and enumerable kv collections" do
    # Empty map at root (prefix == "") vs nested (prefix != "")
    assert TxCompiler.compile_node("", %{}, false) == [{:init_col, "", "hash_map"}]
    assert TxCompiler.compile_node(".sub", %{}, false) == [{:reset_col, ".sub", "hash_map"}]
    assert TxCompiler.compile_node("", %{}, true) == [{:reset_col, "", "hash_map"}]

    # Array list and linked list with nil element
    assert TxCompiler.compile_node(".arr", Xitdb.array_list([nil, "x"]), false) == [
             {:reset_col, ".arr", "array_list"},
             {:put, ".arr[0]", nil},
             {:put, ".arr[1]", "x"}
           ]

    assert TxCompiler.compile_node(".lnk", Xitdb.linked_list([nil, 42]), false) == [
             {:reset_col, ".lnk", "linked_array_list"},
             {:put, ".lnk[[0]]", nil},
             {:put, ".lnk[[1]]", 42}
           ]

    # Direct nil with reset? false vs true
    assert TxCompiler.compile_node(".k", nil, false) == [{:rm_if_exists, ".k"}]
    assert TxCompiler.compile_node(".k", nil, true) == [{:put, ".k", nil}]

    # Map with nil value: reset? false emits rm_if_exists; reset? true omits it
    assert TxCompiler.compile_node(".m", %{"a" => nil, "b" => 1}, false) == [
             {:rm_if_exists, ".m.a"},
             {:put, ".m.b", 1}
           ]

    assert TxCompiler.compile_node(".m", %{"a" => nil, "b" => 1}, true) == [
             {:reset_col, ".m", "hash_map"},
             {:put, ".m.b", 1}
           ]

    # Empty keyword/list-backed Collection with reset? false vs true
    assert TxCompiler.compile_node(".s", Xitdb.sorted_map([]), false) == [
             {:init_col, ".s", "sorted_map"}
           ]

    assert TxCompiler.compile_node(".s", Xitdb.sorted_map([]), true) == [
             {:reset_col, ".s", "sorted_map"}
           ]

    # Non-empty list-backed Collection with nil value uses reset?: false -> rm_if_exists
    assert TxCompiler.compile_node(".s", Xitdb.sorted_map(a: nil, b: 2), false) == [
             {:rm_if_exists, ".s$a"},
             {:put, ".s$b", 2}
           ]
  end
end
