defmodule JidoCodeServer.Project.ProtocolSupervisor do
  @moduledoc """
  Placeholder supervisor for project-scoped protocol listeners.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
