defmodule JidoCodeServer.Engine.Project do
  @moduledoc """
  Runtime process representing a started project instance.

  It owns the project container lifecycle by starting a project-level supervisor
  and delegating control-plane operations to `Project.Server`.
  """

  use GenServer

  alias JidoCodeServer.Engine.ProjectRegistry
  alias JidoCodeServer.Project.Naming
  alias JidoCodeServer.Project.Server
  alias JidoCodeServer.Project.Supervisor

  @type t :: %{
          project_id: String.t(),
          root_path: String.t(),
          data_dir: String.t(),
          started_at: DateTime.t(),
          opts: keyword(),
          project_supervisor: pid(),
          project_server: GenServer.server()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    name = ProjectRegistry.via(project_id)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec summary(pid()) :: map()
  def summary(pid) when is_pid(pid) do
    GenServer.call(pid, :summary)
  end

  @spec start_conversation(pid(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_conversation(pid, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:start_conversation, opts})
  end

  @spec stop_conversation(pid(), String.t()) :: :ok | {:error, term()}
  def stop_conversation(pid, conversation_id) when is_pid(pid) and is_binary(conversation_id) do
    GenServer.call(pid, {:stop_conversation, conversation_id})
  end

  @spec send_event(pid(), String.t(), map()) :: :ok | {:error, term()}
  def send_event(pid, conversation_id, event)
      when is_pid(pid) and is_binary(conversation_id) and is_map(event) do
    GenServer.call(pid, {:send_event, conversation_id, event})
  end

  @spec get_projection(pid(), String.t(), atom() | String.t()) :: {:ok, term()} | {:error, term()}
  def get_projection(pid, conversation_id, key) when is_pid(pid) and is_binary(conversation_id) do
    GenServer.call(pid, {:get_projection, conversation_id, key})
  end

  @spec list_tools(pid()) :: [map()]
  def list_tools(pid) when is_pid(pid) do
    GenServer.call(pid, :list_tools)
  end

  @spec reload_assets(pid()) :: :ok | {:error, term()}
  def reload_assets(pid) when is_pid(pid) do
    GenServer.call(pid, :reload_assets)
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    root_path = Keyword.fetch!(opts, :root_path)
    data_dir = Keyword.fetch!(opts, :data_dir)

    supervisor_opts = [
      project_id: project_id,
      root_path: root_path,
      data_dir: data_dir
    ]

    supervisor_opts =
      case Keyword.fetch(opts, :watcher) do
        {:ok, watcher} -> Keyword.put(supervisor_opts, :watcher, watcher)
        :error -> supervisor_opts
      end

    case Supervisor.start_link(supervisor_opts) do
      {:ok, project_supervisor} ->
        state = %{
          project_id: project_id,
          root_path: root_path,
          data_dir: data_dir,
          started_at: DateTime.utc_now(),
          opts: opts,
          project_supervisor: project_supervisor,
          project_server: Naming.via(project_id, :project_server)
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:project_supervisor_start_failed, reason}}
    end
  end

  @impl true
  def handle_call(:summary, _from, state) do
    project_summary =
      case delegate(fn -> Server.summary(state.project_server) end) do
        {:ok, summary} ->
          summary

        {:error, _reason} ->
          %{
            project_id: state.project_id,
            root_path: state.root_path,
            data_dir: state.data_dir,
            layout: %{},
            conversation_count: 0
          }
      end

    summary =
      Map.merge(project_summary, %{
        started_at: state.started_at,
        pid: self(),
        project_supervisor: state.project_supervisor
      })

    {:reply, summary, state}
  end

  def handle_call({:start_conversation, opts}, _from, state) do
    reply =
      delegate(fn ->
        Server.start_conversation(state.project_server, opts)
      end)
      |> unwrap_delegate()

    {:reply, reply, state}
  end

  def handle_call({:stop_conversation, conversation_id}, _from, state) do
    reply =
      delegate(fn ->
        Server.stop_conversation(state.project_server, conversation_id)
      end)
      |> unwrap_delegate()

    {:reply, reply, state}
  end

  def handle_call({:send_event, conversation_id, event}, _from, state) do
    reply =
      delegate(fn ->
        Server.send_event(state.project_server, conversation_id, event)
      end)
      |> unwrap_delegate()

    {:reply, reply, state}
  end

  def handle_call({:get_projection, conversation_id, key}, _from, state) do
    reply =
      delegate(fn ->
        Server.get_projection(state.project_server, conversation_id, key)
      end)
      |> unwrap_delegate()

    {:reply, reply, state}
  end

  def handle_call(:list_tools, _from, state) do
    reply =
      delegate(fn -> Server.list_tools(state.project_server) end)
      |> unwrap_delegate([])

    {:reply, reply, state}
  end

  def handle_call(:reload_assets, _from, state) do
    reply =
      delegate(fn -> Server.reload_assets(state.project_server) end)
      |> unwrap_delegate()

    {:reply, reply, state}
  end

  defp delegate(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  catch
    :exit, reason ->
      {:error, {:project_unavailable, reason}}
  end

  defp unwrap_delegate(result), do: unwrap_delegate(result, nil)
  defp unwrap_delegate({:ok, value}, _default), do: value
  defp unwrap_delegate({:error, _reason}, default) when not is_nil(default), do: default
  defp unwrap_delegate({:error, reason}, nil), do: {:error, reason}
end
