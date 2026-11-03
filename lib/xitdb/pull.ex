defmodule Xitdb.Pull do
  @moduledoc """
  Compiles structured Elixir Pull patterns into canonical `xitdb` Pull syntax strings.

  ## Examples

      iex> Xitdb.Pull.compile!([:username, :age, todos: 0..2, profile: [:city]])
      "{username, age, todos[0..2], profile{city}}"

      iex> Xitdb.Pull.compile!([:*, friends: {0..5, [:username, profile: [:city]]}])
      "{*, friends[0..5]{username, profile{city}}}"
  """

  alias Xitdb.Error

  @type pattern_entry ::
          atom()
          | String.t()
          | {atom() | String.t(), Range.t()}
          | {atom() | String.t(), {:slice, non_neg_integer(), non_neg_integer()}}
          | {atom() | String.t(), [pattern_entry()]}
          | {atom() | String.t(), {Range.t(), [pattern_entry()]}}
          | {atom() | String.t(),
             {{:slice, non_neg_integer(), non_neg_integer()}, [pattern_entry()]}}

  @type pattern :: String.t() | [pattern_entry()]

  @doc """
  Compiles a structural Pull pattern list or validates a Pull pattern binary.
  """
  @spec compile(pattern()) :: {:ok, String.t()} | {:error, Error.t()}
  def compile(pattern) when is_binary(pattern) do
    trimmed = String.trim(pattern)

    if trimmed != "" do
      {:ok, trimmed}
    else
      {:error, %Error{reason: :invalid_pull_pattern, details: %{pattern: pattern}}}
    end
  end

  def compile(pattern) when is_list(pattern) and pattern != [] do
    {:ok, compile_list!(pattern)}
  rescue
    e in ArgumentError ->
      {:error, %Error{reason: :invalid_pull_pattern, details: %{message: e.message}}}
  end

  def compile(other) do
    {:error, %Error{reason: :invalid_pull_pattern, details: %{pattern: other}}}
  end

  @doc """
  Same as `compile/1`, but raises `ArgumentError` on invalid patterns.
  """
  @spec compile!(pattern()) :: String.t()
  def compile!(pattern) when is_binary(pattern) do
    case compile(pattern) do
      {:ok, compiled} -> compiled
      {:error, err} -> raise ArgumentError, Exception.message(err)
    end
  end

  def compile!(pattern) when is_list(pattern) and pattern != [] do
    compile_list!(pattern)
  end

  def compile!(other) do
    raise ArgumentError, "Invalid pull pattern: #{inspect(other)}"
  end

  defp compile_list!(entries) when is_list(entries) and entries != [] do
    inner = Enum.map_join(entries, ", ", &compile_entry!/1)
    "{" <> inner <> "}"
  end

  defp compile_list!(other) do
    raise ArgumentError, "Expected non-empty list in pull pattern, got: #{inspect(other)}"
  end

  defp compile_entry!(:*), do: "*"
  defp compile_entry!("*"), do: "*"

  defp compile_entry!(field)
       when is_atom(field) and not is_nil(field) and not is_boolean(field) do
    Atom.to_string(field)
  end

  defp compile_entry!(field) when is_binary(field) and field != "" do
    field
  end

  defp compile_entry!({field, first..last//1}) do
    format_field_name!(field) <> "[#{first}..#{last}]"
  end

  defp compile_entry!({field, {:slice, offset, limit}})
       when is_integer(offset) and is_integer(limit) do
    format_field_name!(field) <> "[#{offset}..#{offset + limit}]"
  end

  defp compile_entry!({field, nested}) when is_list(nested) and nested != [] do
    format_field_name!(field) <> compile_list!(nested)
  end

  defp compile_entry!({field, {first..last//1, nested}})
       when is_list(nested) and nested != [] do
    format_field_name!(field) <> "[#{first}..#{last}]" <> compile_list!(nested)
  end

  defp compile_entry!({field, {{:slice, offset, limit}, nested}})
       when is_integer(offset) and is_integer(limit) and is_list(nested) and nested != [] do
    format_field_name!(field) <> "[#{offset}..#{offset + limit}]" <> compile_list!(nested)
  end

  defp compile_entry!(other) do
    raise ArgumentError, "Unsupported pull pattern entry: #{inspect(other)}"
  end

  defp format_field_name!(field)
       when is_atom(field) and not is_nil(field) and not is_boolean(field),
       do: Atom.to_string(field)

  defp format_field_name!(field) when is_binary(field) and field != "", do: field

  defp format_field_name!(other) do
    raise ArgumentError, "Invalid pull field name: #{inspect(other)}"
  end
end
