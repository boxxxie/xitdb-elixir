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

  @special_bytes [
    ?.,
    ?[,
    ?],
    ?{,
    ?},
    ?,,
    ?=,
    ?!,
    ?<,
    ?>,
    ??,
    ?*,
    ?:,
    ?#,
    ?$,
    ?%,
    ?^,
    ?@,
    ?",
    ?',
    ?\\,
    ?\s,
    ?\t,
    ?\n,
    ?\r
  ]

  @escapable_bytes [?\\, ?", ?\n, ?\r, ?\t]

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

  def format_typed_step(:at_moment, idx) when is_integer(idx), do: "@#{idx}"

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

  @doc false
  @spec validate_step_key(term()) :: String.t() | atom()
  def validate_step_key(key)
      when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)),
      do: key

  def validate_step_key(invalid) do
    raise ArgumentError,
          "Invalid bracket path step #{inspect(invalid)}: expected non-nil/non-boolean key, integer index, [idx], or {kind, val}"
  end

  @doc false
  @spec normalize_typed_step(atom(), term()) :: term()
  def normalize_typed_step(:at_moment, idx) when is_integer(idx), do: {:at_moment, idx}

  def normalize_typed_step(:at_moment, invalid) do
    raise ArgumentError,
          "Invalid moment index #{inspect(invalid)}: expected integer moment index"
  end

  def normalize_typed_step(kind, val) when kind in [:hash_map, :map],
    do: {:hash_map, validate_step_key(val)}

  def normalize_typed_step(kind, val) when kind in [:counted, :counted_map, :counted_hash_map],
    do: {:counted_hash_map, validate_step_key(val)}

  def normalize_typed_step(kind, val) when kind in [:sorted, :sorted_map],
    do: {:sorted_map, validate_step_key(val)}

  def normalize_typed_step(kind, idx) when kind in [:array, :array_list] and is_integer(idx),
    do: {:array_list, idx}

  def normalize_typed_step(kind, [idx])
      when kind in [:linked, :linked_list, :linked_array_list] and is_integer(idx),
      do: {:linked_array_list, idx}

  def normalize_typed_step(kind, idx)
      when kind in [:linked, :linked_list, :linked_array_list] and is_integer(idx),
      do: {:linked_array_list, idx}

  def normalize_typed_step(kind, val) when kind in [:set, :hash_set, :set_member],
    do: {:hash_set, validate_step_key(val)}

  def normalize_typed_step(kind, val)
      when kind in [:counted_set, :counted_hash_set, :counted_set_member],
      do: {:counted_hash_set, validate_step_key(val)}

  def normalize_typed_step(kind, val) when kind in [:sorted_set, :sorted_set_member],
    do: {:sorted_set, validate_step_key(val)}

  def normalize_typed_step(kind, val) do
    raise ArgumentError,
          "Invalid typed path step {#{inspect(kind)}, #{inspect(val)}}"
  end

  @doc false
  @spec normalize_bracket_step(term()) :: term()
  def normalize_bracket_step(idx) when is_integer(idx), do: idx
  def normalize_bracket_step([idx]) when is_integer(idx), do: [idx]
  def normalize_bracket_step({kind, val}), do: normalize_typed_step(kind, val)

  def normalize_bracket_step(key)
      when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)),
      do: key

  def normalize_bracket_step(invalid) do
    raise ArgumentError,
          "Invalid bracket path step #{inspect(invalid)}: expected non-nil/non-boolean key, integer index, [idx], or {kind, val}"
  end

  @doc false
  @spec normalize_root_or_steps(term()) :: [term()]
  def normalize_root_or_steps(""), do: []

  def normalize_root_or_steps(<<first, _rest::binary>> = selector)
      when is_valid_selector_start(first) do
    parse_selector_steps(selector, true)
  end

  def normalize_root_or_steps(steps) when is_list(steps),
    do: Enum.map(steps, &normalize_bracket_step/1)

  def normalize_root_or_steps({kind, val}), do: [normalize_typed_step(kind, val)]
  def normalize_root_or_steps(key), do: [validate_step_key(key)]

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

  @doc false
  @spec parse_selector_steps(String.t(), boolean()) :: [term()]
  def parse_selector_steps(selector, include_moment \\ false) when is_binary(selector) do
    case selector do
      <<?@, rest::binary>> ->
        {num_str, tail} = take_until_sigil(rest)

        if include_moment do
          [{:at_moment, String.to_integer(num_str)} | do_parse_steps(tail, [])]
        else
          do_parse_steps(tail, [])
        end

      bin ->
        do_parse_steps(bin, [])
    end
  end

  defp do_parse_steps(<<>>, acc), do: :lists.reverse(acc)

  defp do_parse_steps(<<?#, ?%, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:counted_hash_set, key} | acc])
  end

  defp do_parse_steps(<<?., rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:hash_map, key} | acc])
  end

  defp do_parse_steps(<<?#, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:counted_hash_map, key} | acc])
  end

  defp do_parse_steps(<<?$, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:sorted_map, key} | acc])
  end

  defp do_parse_steps(<<?%, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:hash_set, key} | acc])
  end

  defp do_parse_steps(<<?^, rest::binary>>, acc) do
    {key, tail} = parse_key_token(rest)
    do_parse_steps(tail, [{:sorted_set, key} | acc])
  end

  defp do_parse_steps(<<?[, ?[, rest::binary>>, acc) do
    {int_str, <<?], ?], tail::binary>>} = take_until_byte(rest, ?])
    do_parse_steps(tail, [{:linked_array_list, String.to_integer(int_str)} | acc])
  end

  defp do_parse_steps(<<?[, ?', rest::binary>>, acc) do
    {unescaped, <<?], tail::binary>>} = parse_single_quoted_string(rest, [])
    do_parse_steps(tail, [{:hash_map, unescaped} | acc])
  end

  defp do_parse_steps(<<?[, ?", rest::binary>>, acc) do
    {unescaped, <<?], tail::binary>>} = parse_quoted_string(rest, [])
    do_parse_steps(tail, [{:hash_map, unescaped} | acc])
  end

  defp do_parse_steps(<<?[, rest::binary>>, acc) do
    {int_str, <<?], tail::binary>>} = take_until_byte(rest, ?])
    do_parse_steps(tail, [{:array_list, String.to_integer(int_str)} | acc])
  end

  defp do_parse_steps(bin, acc) do
    {key, tail} = parse_key_token(bin)
    do_parse_steps(tail, [{:hash_map, key} | acc])
  end

  defp parse_key_token(<<?[, ?', rest::binary>>) do
    {unescaped, <<?], tail::binary>>} = parse_single_quoted_string(rest, [])
    {unescaped, tail}
  end

  defp parse_key_token(<<?[, ?", rest::binary>>) do
    {unescaped, <<?], tail::binary>>} = parse_quoted_string(rest, [])
    {unescaped, tail}
  end

  defp parse_key_token(bin), do: take_until_sigil(bin)

  defp take_until_sigil(bin), do: do_take_until_sigil(bin, 0, bin)

  defp do_take_until_sigil(<<>>, len, orig), do: {binary_part(orig, 0, len), <<>>}

  defp do_take_until_sigil(<<b, _::binary>> = tail, len, orig)
       when b in [?., ?#, ?$, ?[, ?%, ?^] do
    {binary_part(orig, 0, len), tail}
  end

  defp do_take_until_sigil(<<_, rest::binary>>, len, orig) do
    do_take_until_sigil(rest, len + 1, orig)
  end

  defp take_until_byte(bin, stop_byte), do: do_take_until_byte(bin, stop_byte, 0, bin)

  defp do_take_until_byte(<<b, _::binary>> = tail, b, len, orig) do
    {binary_part(orig, 0, len), tail}
  end

  defp do_take_until_byte(<<_, rest::binary>>, stop_byte, len, orig) do
    do_take_until_byte(rest, stop_byte, len + 1, orig)
  end

  defp parse_single_quoted_string(<<?', tail::binary>>, acc),
    do: {IO.iodata_to_binary(:lists.reverse(acc)), tail}

  defp parse_single_quoted_string(<<?\\, ?\\, rest::binary>>, acc),
    do: parse_single_quoted_string(rest, [?\\ | acc])

  defp parse_single_quoted_string(<<?\\, ?', rest::binary>>, acc),
    do: parse_single_quoted_string(rest, [?' | acc])

  defp parse_single_quoted_string(<<?\\, ?n, rest::binary>>, acc),
    do: parse_single_quoted_string(rest, [?\n | acc])

  defp parse_single_quoted_string(<<?\\, ?r, rest::binary>>, acc),
    do: parse_single_quoted_string(rest, [?\r | acc])

  defp parse_single_quoted_string(<<?\\, ?t, rest::binary>>, acc),
    do: parse_single_quoted_string(rest, [?\t | acc])

  defp parse_single_quoted_string(<<b, rest::binary>>, acc),
    do: parse_single_quoted_string(rest, [b | acc])

  defp parse_quoted_string(<<?", tail::binary>>, acc),
    do: {IO.iodata_to_binary(:lists.reverse(acc)), tail}

  defp parse_quoted_string(<<?\\, ?\\, rest::binary>>, acc),
    do: parse_quoted_string(rest, [?\\ | acc])

  defp parse_quoted_string(<<?\\, ?", rest::binary>>, acc),
    do: parse_quoted_string(rest, [?" | acc])

  defp parse_quoted_string(<<?\\, ?n, rest::binary>>, acc),
    do: parse_quoted_string(rest, [?\n | acc])

  defp parse_quoted_string(<<?\\, ?r, rest::binary>>, acc),
    do: parse_quoted_string(rest, [?\r | acc])

  defp parse_quoted_string(<<?\\, ?t, rest::binary>>, acc),
    do: parse_quoted_string(rest, [?\t | acc])

  defp parse_quoted_string(<<b, rest::binary>>, acc),
    do: parse_quoted_string(rest, [b | acc])

  @spec format_key(term()) :: String.t()
  def format_key(invalid) when is_nil(invalid) or is_boolean(invalid) do
    raise ArgumentError,
          "Invalid selector key #{inspect(invalid)}: nil and booleans are not valid map or set keys"
  end

  def format_key(key) when is_binary(key) do
    if bare_key?(key) do
      key
    else
      "[" <> encode_quoted(key) <> "]"
    end
  end

  def format_key(key) when is_atom(key), do: format_key(Atom.to_string(key))
  def format_key(key), do: format_key(to_string(key))

  @spec encode_quoted(String.t()) :: String.t()
  def encode_quoted(str) when is_binary(str) do
    if needs_escape?(str) do
      IO.iodata_to_binary([?", escape_bytes(str, []), ?"])
    else
      "\"" <> str <> "\""
    end
  end

  @doc false
  def bare_key?(<<>>), do: false
  def bare_key?(bin) when is_binary(bin), do: do_bare_key?(bin)
  def bare_key?(_), do: false

  defp do_bare_key?(<<>>), do: true
  defp do_bare_key?(<<b, _rest::binary>>) when b in @special_bytes, do: false
  defp do_bare_key?(<<_b, rest::binary>>), do: do_bare_key?(rest)

  defp needs_escape?(<<>>), do: false
  defp needs_escape?(<<b, _rest::binary>>) when b in @escapable_bytes, do: true
  defp needs_escape?(<<_b, rest::binary>>), do: needs_escape?(rest)

  defp escape_bytes(<<>>, acc), do: Enum.reverse(acc)
  defp escape_bytes(<<?\\, rest::binary>>, acc), do: escape_bytes(rest, ["\\\\" | acc])
  defp escape_bytes(<<?", rest::binary>>, acc), do: escape_bytes(rest, ["\\\"" | acc])
  defp escape_bytes(<<?\n, rest::binary>>, acc), do: escape_bytes(rest, ["\\n" | acc])
  defp escape_bytes(<<?\r, rest::binary>>, acc), do: escape_bytes(rest, ["\\r" | acc])
  defp escape_bytes(<<?\t, rest::binary>>, acc), do: escape_bytes(rest, ["\\t" | acc])
  defp escape_bytes(<<byte, rest::binary>>, acc), do: escape_bytes(rest, [byte | acc])
end
