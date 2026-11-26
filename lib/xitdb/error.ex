defmodule Xitdb.Error do
  @moduledoc """
  Exception and error struct returned by `Xitdb` operations.
  """
  defexception [:reason, :details]

  @type t :: %__MODULE__{
          reason: atom() | String.t(),
          details: term()
        }

  @impl true
  def message(%__MODULE__{reason: :file_locked, details: nil}) do
    "Xitdb database file is locked by another writable handle"
  end

  def message(%__MODULE__{reason: :file_locked, details: details}) do
    "Xitdb database file is locked by another writable handle: #{inspect(details)}"
  end

  def message(%__MODULE__{reason: :stale_write_epoch, details: nil}) do
    "Xitdb write rejected due to stale write epoch"
  end

  def message(%__MODULE__{reason: :stale_write_epoch, details: details}) do
    "Xitdb write rejected due to stale write epoch: #{inspect(details)}"
  end

  def message(%__MODULE__{reason: reason, details: nil}) do
    "Xitdb operation failed: #{inspect(reason)}"
  end

  def message(%__MODULE__{reason: reason, details: details}) do
    "Xitdb operation failed (#{inspect(reason)}): #{inspect(details)}"
  end

  @doc false
  @spec wrap(:ok | {:ok, val} | {:error, term()} | t() | atom() | String.t(), term()) ::
          :ok | {:ok, val} | {:error, t()} | t()
        when val: var
  def wrap(result, details \\ nil)
  def wrap(:ok, _details), do: :ok
  def wrap({:ok, _} = ok, _details), do: ok
  def wrap({:error, %__MODULE__{}} = err, _details), do: err

  def wrap({:error, reason}, details) do
    {:error, %__MODULE__{reason: reason, details: details}}
  end

  def wrap(%__MODULE__{} = err, _details), do: err

  def wrap(reason, details) when is_atom(reason) or is_binary(reason) do
    %__MODULE__{reason: reason, details: details}
  end

  @doc false
  @spec unwrap!({:ok, val} | {:error, Exception.t()}) :: val when val: var
  def unwrap!({:ok, val}), do: val
  def unwrap!({:error, err}), do: raise(err)
end
