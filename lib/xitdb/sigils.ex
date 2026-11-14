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
    trimmed = String.trim(selector)

    if trimmed == "" or not is_valid_selector_start(:binary.first(trimmed)) do
      raise ArgumentError,
            "Invalid ~x selector #{inspect(selector)}: must start with ., #, $, [, %, ^, or @"
    end

    trimmed
  end

  defmacro sigil_x({:<<>>, _, _} = ast, _modifiers) do
    quote do
      unquote(ast)
    end
  end

  @doc """
  Validates a `xitdb` Datalog query string at compile time.
  """
  defmacro sigil_q({:<<>>, _meta, [query]}, _modifiers) when is_binary(query) do
    trimmed = String.trim(query)

    if not (String.contains?(trimmed, "find") and String.contains?(trimmed, "where")) do
      raise ArgumentError,
            "Invalid ~q Datalog query #{inspect(query)}: must contain 'find' and 'where' clauses"
    end

    trimmed
  end

  defmacro sigil_q({:<<>>, _, _} = ast, _modifiers) do
    quote do
      unquote(ast)
    end
  end
end
