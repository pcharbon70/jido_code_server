defmodule JidoCodeServer.Project.Supervisor do
  @moduledoc """
  Per-project supervision boundary.
  """

  use Supervisor

  alias JidoCodeServer.Project.Naming

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    project_id = Keyword.fetch!(opts, :project_id)
    name = Naming.via(project_id, :project_supervisor)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    root_path = Keyword.fetch!(opts, :root_path)
    data_dir = Keyword.fetch!(opts, :data_dir)

    conversation_registry = Naming.via(project_id, :conversation_registry)
    conversation_supervisor = Naming.via(project_id, :conversation_supervisor)

    task_supervisor = Naming.via(project_id, :task_supervisor)
    asset_store = Naming.via(project_id, :asset_store)
    policy = Naming.via(project_id, :policy)
    project_server = Naming.via(project_id, :project_server)
    protocol_supervisor = Naming.via(project_id, :protocol_supervisor)
    policy_opts = Keyword.get(opts, :policy, [])
    runtime_opts = Keyword.get(opts, :runtime_opts, [])
    watcher_opts = Keyword.get(opts, :watcher_opts, [])

    children = [
      {JidoCodeServer.Project.ConversationRegistry, name: conversation_registry},
      {JidoCodeServer.Project.ConversationSupervisor, name: conversation_supervisor},
      {JidoCodeServer.Project.AssetStore, [name: asset_store, project_id: project_id]},
      {JidoCodeServer.Project.Policy,
       Keyword.merge([name: policy, project_id: project_id, root_path: root_path], policy_opts)},
      {JidoCodeServer.Project.TaskSupervisor, name: task_supervisor},
      {JidoCodeServer.Project.ProtocolSupervisor, name: protocol_supervisor},
      {JidoCodeServer.Project.Server,
       [
         name: project_server,
         project_id: project_id,
         root_path: root_path,
         data_dir: data_dir,
         conversation_registry: conversation_registry,
         conversation_supervisor: conversation_supervisor,
         runtime_opts: runtime_opts
       ]}
    ]

    children =
      if Keyword.get(opts, :watcher, false) do
        watcher = Naming.via(project_id, :watcher)

        children ++
          [
            {JidoCodeServer.Project.Watcher,
             [
               name: watcher,
               project_id: project_id,
               root_path: root_path,
               data_dir: data_dir,
               asset_store: asset_store,
               debounce_ms: Keyword.get(watcher_opts, :watcher_debounce_ms)
             ]}
          ]
      else
        children
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
