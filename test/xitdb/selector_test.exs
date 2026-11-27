defmodule Xitdb.SelectorTest do
  use ExUnit.Case, async: true

  alias Xitdb.{Selector, TxCompiler}

  test "format_path_steps formats mixed maps, typed steps, and linked indices" do
    steps = [{:counted, :users}, "alice.liddell", :todos, [0]]
    assert Selector.format_path_steps(steps) == ~s(#users.["alice.liddell"].todos[[0]])
  end

  test "format_root_or_step preserves canonical selectors and encodes plain keys" do
    assert Selector.format_root_or_step(".users.alice") == ".users.alice"
    assert Selector.format_root_or_step("$idx") == "$idx"
    assert Selector.format_root_or_step("users") == ".users"
  end

  test "rejects nil and boolean keys in format_bracket_step/1 and format_key/1" do
    assert_raise ArgumentError, ~r/Invalid bracket path step nil/, fn ->
      Selector.format_bracket_step(nil)
    end

    assert_raise ArgumentError, ~r/Invalid bracket path step false/, fn ->
      Selector.format_bracket_step(false)
    end

    assert_raise ArgumentError, ~r/Invalid selector key nil/, fn ->
      Selector.format_key(nil)
    end

    assert_raise ArgumentError, ~r/Invalid selector key true/, fn ->
      Selector.format_key(true)
    end
  end

  test "TxCompiler.compile_node handles empty and keyword-backed Collections identically" do
    assert TxCompiler.compile_node(".org", Xitdb.counted_map(%{}), false) == [
             {:init_col, ".org", "counted_hash_map"}
           ]

    assert TxCompiler.compile_node(".cat", Xitdb.sorted_map(a: 1, b: 2), true) == [
             {:reset_col, ".cat", "sorted_map"},
             {:put, ".cat$a", 1},
             {:put, ".cat$b", 2}
           ]
  end

  test "TxCompiler.compile_moment_map emits merge_map by default and flat ops with flatten: true" do
    input = %{"users" => %{"u1" => %{"name" => "Ada"}}}
    rules = [{:index_on, :users, :name, "users_by_name"}]

    assert TxCompiler.compile_moment_map(%{}) == []
    assert TxCompiler.compile_moment_map(input) == [{:merge_map, input}]

    assert TxCompiler.compile_moment_map(input, index_rules: rules) == [
             {:index_on, "users", "name", "users_by_name"},
             {:merge_map, input}
           ]

    assert TxCompiler.compile_moment_map(%{}, index_rules: rules) == [
             {:index_on, "users", "name", "users_by_name"}
           ]

    assert TxCompiler.compile_moment_map(input, index_rules: rules, flatten: true) == [
             {:index_on, "users", "name", "users_by_name"},
             {:put, ".users.u1.name", "Ada"}
           ]
  end

  test "format_typed_step/2 and normalize_typed_step/2 cover all collection kinds and error guards" do
    assert Selector.format_typed_step(:array, 2) == "[2]"
    assert Selector.format_typed_step(:array_list, -1) == "[-1]"
    assert Selector.format_typed_step(:linked, [3]) == "[[3]]"
    assert Selector.format_typed_step(:linked_list, 4) == "[[4]]"
    assert Selector.format_typed_step(:set, "a") == "%a"
    assert Selector.format_typed_step(:counted_set, "b") == "#%b"
    assert Selector.format_typed_step(:sorted_set, "c") == "^c"
    assert Selector.format_typed_step(:at_moment, 0) == "@0"

    assert_raise ArgumentError, fn -> Selector.format_typed_step(:linked, ["bad"]) end
    assert_raise ArgumentError, fn -> Selector.format_typed_step(:array, :bad) end
    assert_raise ArgumentError, fn -> Selector.format_typed_step(:at_moment, "0") end

    assert Selector.normalize_typed_step(:at_moment, 0) == {:at_moment, 0}
    assert_raise ArgumentError, fn -> Selector.normalize_typed_step(:at_moment, "0") end

    assert Selector.normalize_typed_step(:hash_map, :users) == {:hash_map, :users}
    assert Selector.normalize_typed_step(:map, "users") == {:hash_map, "users"}
    assert Selector.normalize_typed_step(:array, 1) == {:array_list, 1}
    assert Selector.normalize_typed_step(:array_list, -1) == {:array_list, -1}
    assert Selector.normalize_typed_step(:linked, [2]) == {:linked_array_list, 2}
    assert Selector.normalize_typed_step(:linked_list, 2) == {:linked_array_list, 2}
    assert Selector.normalize_typed_step(:set, "x") == {:hash_set, "x"}
    assert Selector.normalize_typed_step(:counted_set, "y") == {:counted_hash_set, "y"}
    assert Selector.normalize_typed_step(:sorted_set, "z") == {:sorted_set, "z"}

    assert_raise ArgumentError, fn -> Selector.normalize_typed_step(:array, "bad") end
    assert_raise ArgumentError, fn -> Selector.normalize_typed_step(:linked, ["bad"]) end
    assert_raise ArgumentError, fn -> Selector.normalize_typed_step(:bogus, "x") end
  end

  test "normalize_root_or_steps/1 and parse_selector_steps/2 cover moments, sets, linked lists, and quoted escapes" do
    assert Selector.normalize_root_or_steps("") == []
    assert Selector.normalize_root_or_steps("@2.users") == [{:at_moment, 2}, {:hash_map, "users"}]
    assert Selector.normalize_root_or_steps([:a, 0]) == [:a, 0]
    assert Selector.normalize_root_or_steps({:sorted, "k"}) == [{:sorted_map, "k"}]
    assert Selector.normalize_root_or_steps("plain") == ["plain"]

    # include_moment default is false vs true
    assert Selector.parse_selector_steps("@2.users") == [{:hash_map, "users"}]
    assert Selector.parse_selector_steps("@2.users", false) == [{:hash_map, "users"}]

    assert Selector.parse_selector_steps("@2.users", true) == [
             {:at_moment, 2},
             {:hash_map, "users"}
           ]

    # Counted hash set, linked list, single-quoted and double-quoted bracket keys & escapes
    assert Selector.parse_selector_steps("#%tag[[12]]") == [
             {:counted_hash_set, "tag"},
             {:linked_array_list, 12}
           ]

    assert Selector.parse_selector_steps(~S|['a\'b\n\r\t\\']["c\"d\n\r\t\\"]|) == [
             {:hash_map, "a'b\n\r\t\\"},
             {:hash_map, "c\"d\n\r\t\\"}
           ]

    assert Selector.parse_selector_steps(~S|.'s\'1'."d\"2"|) == [
             {:hash_map, "s'1"},
             {:hash_map, "d\"2"}
           ]

    for bad <- [
          "[[0]",
          "[[abc]]",
          "[abc]",
          "['unclosed",
          "['unclosed'",
          ~s(["unclosed),
          ~s(["unclosed"),
          ".'unclosed",
          ".'trailing\\",
          ~s(."unclosed),
          ~s(."trailing\\)
        ] do
      assert_raise ArgumentError, fn -> Selector.parse_selector_steps(bad) end
    end
  end

  test "bare_key?/1 and format_key/1 enforce exact ASCII 0x21..0x7E boundaries" do
    # 0x20 (space) and 0x1F (control) are < 0x21 -> not bare
    refute Selector.bare_key?(<<0x20>>)
    refute Selector.bare_key?(<<0x1F>>)
    # 0x2B ('+') and 0x7E ('~') are in 0x21..0x7E and not special -> bare
    assert Selector.bare_key?(<<0x2B>>)
    assert Selector.bare_key?(<<0x7E>>)
    # 0x7F (DEL) is > 0x7E -> not bare
    refute Selector.bare_key?(<<0x7F>>)
    # 0x21 ('!') is in @special_bytes -> not bare
    refute Selector.bare_key?(<<0x21>>)
    assert Selector.format_key("a~b") == "a~b"
    assert Selector.format_key("a b") == ~s(["a b"])
  end
end
