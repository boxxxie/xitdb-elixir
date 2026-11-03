defmodule Xitdb.Error do
  @moduledoc """
  Structured exception returned or raised when a `Xitdb` operation fails.
  """
  defexception [:reason, :details]

  @type t :: %__MODULE__{
          reason: atom() | String.t(),
          details: map() | nil
        }

  @impl Exception
  def message(%__MODULE__{reason: reason, details: nil}) do
    "Xitdb operation failed: #{inspect(reason)}"
  end

  def message(%__MODULE__{reason: reason, details: details}) do
    "Xitdb operation failed (#{inspect(reason)}): #{inspect(details)}"
  end
end
