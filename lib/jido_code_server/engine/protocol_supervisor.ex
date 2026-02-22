defmodule Jido.Code.Server.Engine.ProtocolSupervisor do
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
          {Jido.Code.Server.Protocol.MCP.Gateway, [name: Jido.Code.Server.Protocol.MCP.Gateway]},
          {Jido.Code.Server.Protocol.A2A.Gateway, [name: Jido.Code.Server.Protocol.A2A.Gateway]}
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
