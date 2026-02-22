defmodule JidoCodeServer.Engine.ProtocolSupervisor do
  @moduledoc """
  Placeholder supervisor for global protocol listeners.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
