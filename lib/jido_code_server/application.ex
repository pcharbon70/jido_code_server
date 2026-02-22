defmodule Jido.Code.Server.Application do
  @moduledoc """
  Application entrypoint for the Jido.Code.Server runtime.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Jido.Code.Server.Engine.Supervisor
    ]

    opts = [strategy: :one_for_one, name: Jido.Code.Server.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
