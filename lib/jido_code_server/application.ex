defmodule JidoCodeServer.Application do
  @moduledoc """
  Application entrypoint for the JidoCodeServer runtime.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      JidoCodeServer.Engine.Supervisor
    ]

    opts = [strategy: :one_for_one, name: JidoCodeServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
