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
end
