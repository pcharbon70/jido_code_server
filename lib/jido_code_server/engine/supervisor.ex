defmodule JidoCodeServer.Engine.Supervisor do
  @moduledoc """
  Top-level engine supervisor for global runtime services.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      JidoCodeServer.Engine.ProjectRegistry,
      JidoCodeServer.Engine.ProjectSupervisor,
      JidoCodeServer.Engine.ProtocolSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
