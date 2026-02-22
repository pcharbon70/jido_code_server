defmodule JidoCodeServer.Project.Supervisor do
  @moduledoc """
  Per-project supervision boundary placeholder.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts) do
    children = [
      JidoCodeServer.Project.Server,
      JidoCodeServer.Project.AssetStore,
      JidoCodeServer.Project.Policy,
      JidoCodeServer.Project.TaskSupervisor,
      JidoCodeServer.Project.ConversationRegistry,
      JidoCodeServer.Project.ConversationSupervisor,
      JidoCodeServer.Project.ProtocolSupervisor,
      JidoCodeServer.Project.Watcher
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
