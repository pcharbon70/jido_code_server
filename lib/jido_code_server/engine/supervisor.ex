defmodule Jido.Code.Server.Engine.Supervisor do
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
      Jido.Code.Server.Engine.ProjectRegistry,
      Jido.Code.Server.Engine.ProjectSupervisor,
      Jido.Code.Server.Engine.ProtocolSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
