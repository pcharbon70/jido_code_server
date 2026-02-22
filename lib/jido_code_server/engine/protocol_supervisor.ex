defmodule JidoCodeServer.Engine.ProtocolSupervisor do
  @moduledoc """
  Supervisor for global protocol adapter listeners.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children =
      if Keyword.get(opts, :enabled, true) do
        [
          {JidoCodeServer.Protocol.MCP.Gateway, [name: JidoCodeServer.Protocol.MCP.Gateway]},
          {JidoCodeServer.Protocol.A2A.Gateway, [name: JidoCodeServer.Protocol.A2A.Gateway]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
