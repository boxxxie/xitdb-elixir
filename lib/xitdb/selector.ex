defmodule Xitdb.Selector do
  @moduledoc false

  @valid_selector_starts [?., ?#, ?$, ?[, ?%, ?^, ?@]

  @typed_modifiers [
    :counted,
    :counted_map,
    :sorted,
    :sorted_map,
    :linked,
    :linked_list,
    :array,
    :array_list,
    :set_member,
    :hash_set,
    :counted_set_member,
    :counted_set,
    :sorted_set_member,
    :sorted_set
  ]

  @map_modifiers [:counted, :counted_map, :sorted, :sorted_map]

  @set_modifiers [
    :set_member,
    :hash_set,
    :counted_set_member,
    :counted_set,
    :sorted_set_member,
    :sorted_set
  ]

  @special_chars [
    ".",
    "[",
    "]",
    "#",
    "$",
    "%",
    "^",
    "@",
    "\"",
    "'",
    "\\",
    " ",
    "\t",
    "\n",
    "\r"
  ]

  @escapable_chars ["\\", "\"", "\n", "\r", "\t"]

  defguard is_valid_selector_start(byte) when byte in @valid_selector_starts
  defguard is_typed_modifier(name) when name in @typed_modifiers
  defguard is_map_modifier(name) when name in @map_modifiers
  defguard is_set_modifier(name) when name in @set_modifiers

  @spec format_step(Xitdb.Collection.kind(), term()) :: String.t()
  def format_step(:hash_map, key), do: "." <> format_key(key)
  def format_step(:counted_hash_map, key), do: "#" <> format_key(key)
  def format_step(:sorted_map, key), do: "$" <> format_key(key)
  def format_step(:array_list, idx) when is_integer(idx), do: "[#{idx}]"
  def format_step(:linked_array_list, idx) when is_integer(idx), do: "[[#{idx}]]"
  def format_step(:hash_set, member), do: "%" <> format_key(member)
  def format_step(:counted_hash_set, member), do: "#%" <> format_key(member)
  def format_step(:sorted_set, member), do: "^" <> format_key(member)

  @spec format_typed_step(atom(), term()) :: String.t()
  def format_typed_step(kind, val) when kind in [:hash_map, :map],
    do: format_step(:hash_map, val)

  def format_typed_step(kind, val) when kind in [:counted, :counted_map, :counted_hash_map],
    do: format_step(:counted_hash_map, val)

  def format_typed_step(kind, val) when kind in [:sorted, :sorted_map],
    do: format_step(:sorted_map, val)

  def format_typed_step(kind, val) when kind in [:array, :array_list],
    do: format_step(:array_list, val)

  def format_typed_step(kind, val) when kind in [:linked, :linked_list, :linked_array_list],
    do: format_step(:linked_array_list, val)

  def format_typed_step(kind, val) when kind in [:set, :hash_set, :set_member],
    do: format_step(:hash_set, val)

  def format_typed_step(kind, val)
      when kind in [:counted_set, :counted_hash_set, :counted_set_member],
      do: format_step(:counted_hash_set, val)

  def format_typed_step(kind, val) when kind in [:sorted_set, :sorted_set_member],
    do: format_step(:sorted_set, val)

  @spec format_bracket_step(term()) :: String.t()
  def format_bracket_step(idx) when is_integer(idx), do: format_step(:array_list, idx)
  def format_bracket_step([idx]) when is_integer(idx), do: format_step(:linked_array_list, idx)
  def format_bracket_step({kind, val}), do: format_typed_step(kind, val)

  def format_bracket_step(key)
      when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)),
      do: format_step(:hash_map, key)

  def format_bracket_step(invalid) do
    raise ArgumentError,
          "Invalid bracket path step #{inspect(invalid)}: expected non-nil/non-boolean key, integer index, [idx], or {kind, val}"
  end

  @spec format_root_or_step(term()) :: String.t()
  def format_root_or_step(<<first, _rest::binary>> = selector)
      when is_valid_selector_start(first) do
    selector
  end

  def format_root_or_step(steps) when is_list(steps), do: format_path_steps(steps)
  def format_root_or_step({kind, val}), do: format_typed_step(kind, val)
  def format_root_or_step(key), do: format_step(:hash_map, key)

  @spec format_path_steps(String.t() | [term()]) :: String.t()
  def format_path_steps(selector) when is_binary(selector), do: selector

  def format_path_steps(steps) when is_list(steps) do
    Enum.map_join(steps, "", &format_bracket_step/1)
  end

  @spec format_key(term()) :: String.t()
  def format_key(invalid) when is_nil(invalid) or is_boolean(invalid) do
    raise ArgumentError,
          "Invalid selector key #{inspect(invalid)}: nil and booleans are not valid map or set keys"
  end

  def format_key(key) when is_binary(key) do
    if key != <<>> and :binary.match(key, @special_chars) == :nomatch do
      key
    else
      "[" <> encode_quoted(key) <> "]"
    end
  end

  def format_key(key) when is_atom(key), do: format_key(Atom.to_string(key))
  def format_key(key), do: format_key(to_string(key))

  @spec encode_quoted(String.t()) :: String.t()
  def encode_quoted(str) when is_binary(str) do
    if :binary.match(str, @escapable_chars) == :nomatch do
      "\"" <> str <> "\""
    else
      IO.iodata_to_binary([?", escape_bytes(str, []), ?"])
    end
  end

  defp escape_bytes(<<>>, acc), do: Enum.reverse(acc)
  defp escape_bytes(<<?\\, rest::binary>>, acc), do: escape_bytes(rest, ["\\\\" | acc])
  defp escape_bytes(<<?", rest::binary>>, acc), do: escape_bytes(rest, ["\\\"" | acc])
  defp escape_bytes(<<?\n, rest::binary>>, acc), do: escape_bytes(rest, ["\\n" | acc])
  defp escape_bytes(<<?\r, rest::binary>>, acc), do: escape_bytes(rest, ["\\r" | acc])
  defp escape_bytes(<<?\t, rest::binary>>, acc), do: escape_bytes(rest, ["\\t" | acc])
  defp escape_bytes(<<byte, rest::binary>>, acc), do: escape_bytes(rest, [byte | acc])
end
