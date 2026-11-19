defmodule Xitdb.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      Xitdb.CacheOwner
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Xitdb.Supervisor)
  end
end
