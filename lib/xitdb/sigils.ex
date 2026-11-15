defmodule Xitdb.Sigils do
  @moduledoc """
  Compile-time validated sigils for `xitdb` path selectors (`~x`) and Datalog queries (`~q`).

  ## Examples

      import Xitdb.Sigils

      selector = ~x|.users["101"].todos[0]|
      query = ~q"find ?name where .users[?id].username = ?name"
  """

  import Xitdb.Selector, only: [is_valid_selector_start: 1]

  @doc """
  Validates a `xitdb` path selector at compile time and returns the canonical selector string.
  """
  defmacro sigil_x({:<<>>, _meta, [selector]}, _modifiers) when is_binary(selector) do
    validate_selector!(selector)
  end

  defmacro sigil_x({:<<>>, _, _} = ast, _modifiers) do
    quote do
      Xitdb.Sigils.validate_selector!(unquote(ast))
    end
  end

  @doc false
  def validate_selector!(selector) when is_binary(selector) do
    trimmed = String.trim(selector)

    if trimmed == "" or not is_valid_selector_start(:binary.first(trimmed)) do
      raise ArgumentError,
            "Invalid ~x selector #{inspect(selector)}: must start with ., #, $, [, %, ^, or @"
    end

    case scan_delims(trimmed, 0, 0, nil) do
      {:ok, 0, 0, nil} ->
        trimmed

      _ ->
        raise ArgumentError,
              "Invalid ~x selector #{inspect(selector)}: unbalanced brackets, braces, or quotes"
    end
  end

  def validate_selector!(other) do
    raise ArgumentError, "Invalid ~x selector #{inspect(other)}: expected a string"
  end

  @doc """
  Validates a `xitdb` Datalog query string at compile time.
  """
  defmacro sigil_q({:<<>>, _meta, [query]}, _modifiers) when is_binary(query) do
    validate_datalog!(query)
  end

  defmacro sigil_q({:<<>>, _, _} = ast, _modifiers) do
    quote do
      Xitdb.Sigils.validate_datalog!(unquote(ast))
    end
  end

  @doc false
  def validate_datalog!(query) when is_binary(query) do
    trimmed = String.trim(query)

    if not (String.contains?(trimmed, "find") and String.contains?(trimmed, "where")) do
      raise ArgumentError,
            "Invalid ~q Datalog query #{inspect(query)}: must contain 'find' and 'where' clauses"
    end

    case scan_delims(trimmed, 0, 0, nil) do
      {:ok, 0, 0, nil} ->
        trimmed

      _ ->
        raise ArgumentError,
              "Invalid ~q Datalog query #{inspect(query)}: unbalanced brackets, braces, or quotes"
    end
  end

  def validate_datalog!(other) do
    raise ArgumentError, "Invalid ~q Datalog query #{inspect(other)}: expected a string"
  end

  defp scan_delims(<<>>, b_depth, c_depth, in_quote), do: {:ok, b_depth, c_depth, in_quote}

  defp scan_delims(<<?\\, _next, rest::binary>>, b_depth, c_depth, in_quote)
       when not is_nil(in_quote) do
    scan_delims(rest, b_depth, c_depth, in_quote)
  end

  defp scan_delims(<<?", rest::binary>>, b_depth, c_depth, nil),
    do: scan_delims(rest, b_depth, c_depth, ?")

  defp scan_delims(<<?", rest::binary>>, b_depth, c_depth, ?"),
    do: scan_delims(rest, b_depth, c_depth, nil)

  defp scan_delims(<<?', rest::binary>>, b_depth, c_depth, nil),
    do: scan_delims(rest, b_depth, c_depth, ?')

  defp scan_delims(<<?', rest::binary>>, b_depth, c_depth, ?'),
    do: scan_delims(rest, b_depth, c_depth, nil)

  defp scan_delims(<<?[, rest::binary>>, b_depth, c_depth, nil),
    do: scan_delims(rest, b_depth + 1, c_depth, nil)

  defp scan_delims(<<?], rest::binary>>, b_depth, c_depth, nil) when b_depth > 0,
    do: scan_delims(rest, b_depth - 1, c_depth, nil)

  defp scan_delims(<<?], _rest::binary>>, _b_depth, _c_depth, nil), do: :error

  defp scan_delims(<<?{, rest::binary>>, b_depth, c_depth, nil),
    do: scan_delims(rest, b_depth, c_depth + 1, nil)

  defp scan_delims(<<?}, rest::binary>>, b_depth, c_depth, nil) when c_depth > 0,
    do: scan_delims(rest, b_depth, c_depth - 1, nil)

  defp scan_delims(<<?}, _rest::binary>>, _b_depth, _c_depth, nil), do: :error

  defp scan_delims(<<_, rest::binary>>, b_depth, c_depth, in_quote),
    do: scan_delims(rest, b_depth, c_depth, in_quote)
end
