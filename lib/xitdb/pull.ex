defmodule Xitdb.Pull do
  @moduledoc """
  Compiles structured Elixir Pull patterns into canonical `xitdb` Pull syntax strings.

  ## Examples

      iex> Xitdb.Pull.compile!([:username, :age, todos: 0..2, profile: [:city]])
      "{username, age, todos[0..3], profile{city}}"

      iex> Xitdb.Pull.compile!([:*, friends: {0..4, [:username, profile: [:city]]}])
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

  defguardp is_slice_spec(spec)
            when is_struct(spec, Range) or
                   (is_tuple(spec) and tuple_size(spec) == 3 and elem(spec, 0) == :slice)

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

  defp compile_entry!({field, nested}) when is_list(nested) and nested != [] do
    format_field_name!(field) <> compile_list!(nested)
  end

  defp compile_entry!({field, {slice_spec, nested}})
       when is_slice_spec(slice_spec) and is_list(nested) and nested != [] do
    format_field_name!(field) <> format_slice_spec!(slice_spec) <> compile_list!(nested)
  end

  defp compile_entry!({field, slice_spec}) when is_slice_spec(slice_spec) do
    format_field_name!(field) <> format_slice_spec!(slice_spec)
  end

  defp compile_entry!(other) do
    raise ArgumentError, "Unsupported pull pattern entry: #{inspect(other)}"
  end

  defp format_slice_spec!(first..last//1) when first >= 0 and last >= first do
    "[#{first}..#{last + 1}]"
  end

  defp format_slice_spec!(%Range{} = range) do
    raise ArgumentError,
          "Pull range must be a non-negative ascending step-1 range, got: #{inspect(range)}"
  end

  defp format_slice_spec!({:slice, offset, limit})
       when is_integer(offset) and offset >= 0 and is_integer(limit) and limit >= 0 do
    "[#{offset}..#{offset + limit}]"
  end

  defp format_slice_spec!({:slice, _, _} = bad_slice) do
    raise ArgumentError,
          "Pull slice requires non-negative integer offset and limit, got: #{inspect(bad_slice)}"
  end

  defp format_field_name!(field)
       when is_atom(field) and not is_nil(field) and not is_boolean(field),
       do: Atom.to_string(field)

  defp format_field_name!(field) when is_binary(field) and field != "", do: field

  defp format_field_name!(other) do
    raise ArgumentError, "Invalid pull field name: #{inspect(other)}"
  end
end
