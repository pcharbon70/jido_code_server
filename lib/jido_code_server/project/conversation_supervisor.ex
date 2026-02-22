defmodule JidoCodeServer.Project.ConversationSupervisor do
  @moduledoc """
  Dynamic supervisor for per-project conversation runtime processes.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> DynamicSupervisor.start_link(__MODULE__, opts)
      name -> DynamicSupervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_conversation(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_conversation(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, {JidoCodeServer.Conversation.Server, opts})
  end

  @spec stop_conversation(GenServer.server(), pid()) :: :ok | {:error, term()}
  def stop_conversation(supervisor, pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  end
end
