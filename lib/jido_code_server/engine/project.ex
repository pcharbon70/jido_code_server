defmodule Jido.Code.Server.Engine.Project do
  @moduledoc """
  Runtime process representing a started project instance.

  It owns the project container lifecycle by starting a project-level supervisor
  and delegating control-plane operations to `Project.Server`.
  """

  use GenServer

  alias Jido.Code.Server.Engine.ProjectRegistry
  alias Jido.Code.Server.Project.Naming
  alias Jido.Code.Server.Project.Server
  alias Jido.Code.Server.Project.Supervisor

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

  @spec subscribe_conversation(pid(), String.t(), pid()) :: :ok | {:error, term()}
  def subscribe_conversation(pid, conversation_id, subscriber_pid \\ self())
      when is_pid(pid) and is_binary(conversation_id) and is_pid(subscriber_pid) do
    GenServer.call(pid, {:subscribe_conversation, conversation_id, subscriber_pid})
  end

  @spec unsubscribe_conversation(pid(), String.t(), pid()) :: :ok | {:error, term()}
  def unsubscribe_conversation(pid, conversation_id, subscriber_pid \\ self())
      when is_pid(pid) and is_binary(conversation_id) and is_pid(subscriber_pid) do
    GenServer.call(pid, {:unsubscribe_conversation, conversation_id, subscriber_pid})
  end

  @spec get_projection(pid(), String.t(), atom() | String.t()) :: {:ok, term()} | {:error, term()}
  def get_projection(pid, conversation_id, key) when is_pid(pid) and is_binary(conversation_id) do
    GenServer.call(pid, {:get_projection, conversation_id, key})
  end

  @spec list_tools(pid()) :: [map()]
  def list_tools(pid) when is_pid(pid) do
    GenServer.call(pid, :list_tools)
  end

  @spec run_tool(pid(), map()) :: {:ok, map()} | {:error, term()}
  def run_tool(pid, tool_call) when is_pid(pid) and is_map(tool_call) do
    GenServer.call(pid, {:run_tool, tool_call})
  end

  @spec reload_assets(pid()) :: :ok | {:error, term()}
  def reload_assets(pid) when is_pid(pid) do
    GenServer.call(pid, :reload_assets)
  end

  @spec list_assets(pid(), atom() | String.t()) :: [map()]
  def list_assets(pid, type) when is_pid(pid) do
    GenServer.call(pid, {:list_assets, type})
  end

  @spec get_asset(pid(), atom() | String.t(), atom() | String.t()) :: {:ok, term()} | :error
  def get_asset(pid, type, key) when is_pid(pid) do
    GenServer.call(pid, {:get_asset, type, key})
  end

  @spec search_assets(pid(), atom() | String.t(), String.t()) :: [map()]
  def search_assets(pid, type, query) when is_pid(pid) and is_binary(query) do
    GenServer.call(pid, {:search_assets, type, query})
  end

  @spec assets_diagnostics(pid()) :: map()
  def assets_diagnostics(pid) when is_pid(pid) do
    GenServer.call(pid, :assets_diagnostics)
  end

  @spec conversation_diagnostics(pid(), String.t()) :: map() | {:error, term()}
  def conversation_diagnostics(pid, conversation_id)
      when is_pid(pid) and is_binary(conversation_id) do
    GenServer.call(pid, {:conversation_diagnostics, conversation_id})
  end

  @spec incident_timeline(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def incident_timeline(pid, conversation_id, opts \\ [])
      when is_pid(pid) and is_binary(conversation_id) and is_list(opts) do
    GenServer.call(pid, {:incident_timeline, conversation_id, opts})
  end

  @spec diagnostics(pid()) :: map()
  def diagnostics(pid) when is_pid(pid) do
    GenServer.call(pid, :diagnostics)
  end

  @spec protocol_allowed?(pid(), String.t()) :: :ok | {:error, term()}
  def protocol_allowed?(pid, protocol) when is_pid(pid) and is_binary(protocol) do
    GenServer.call(pid, {:protocol_allowed?, protocol})
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

    runtime_opts = Keyword.get(opts, :opts, [])
    supervisor_opts = Keyword.put(supervisor_opts, :runtime_opts, runtime_opts)

    supervisor_opts =
      case Keyword.take(runtime_opts, [
             :allow_tools,
             :deny_tools,
             :network_egress_policy,
             :network_allowlist,
             :network_allowed_schemes,
             :sensitive_path_denylist,
             :sensitive_path_allowlist,
             :outside_root_allowlist
           ]) do
        [] -> supervisor_opts
        policy_opts -> Keyword.put(supervisor_opts, :policy, policy_opts)
      end

    supervisor_opts =
      if Keyword.get(runtime_opts, :watcher, false) do
        watcher_opts = Keyword.take(runtime_opts, [:watcher_debounce_ms])

        supervisor_opts
        |> Keyword.put(:watcher, true)
        |> Keyword.put(:watcher_opts, watcher_opts)
      else
        supervisor_opts
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

  def handle_call({:subscribe_conversation, conversation_id, subscriber_pid}, _from, state) do
    reply =
      delegate(fn ->
        Server.subscribe_conversation(state.project_server, conversation_id, subscriber_pid)
      end)
      |> unwrap_delegate()

    {:reply, reply, state}
  end

  def handle_call({:unsubscribe_conversation, conversation_id, subscriber_pid}, _from, state) do
    reply =
      delegate(fn ->
        Server.unsubscribe_conversation(state.project_server, conversation_id, subscriber_pid)
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

  def handle_call({:run_tool, tool_call}, _from, state) do
    reply =
      delegate(fn -> Server.run_tool(state.project_server, tool_call) end)
      |> unwrap_delegate({:error, :project_unavailable})

    {:reply, reply, state}
  end

  def handle_call(:reload_assets, _from, state) do
    reply =
      delegate(fn -> Server.reload_assets(state.project_server) end)
      |> unwrap_delegate()

    {:reply, reply, state}
  end

  def handle_call({:list_assets, type}, _from, state) do
    reply =
      delegate(fn -> Server.list_assets(state.project_server, type) end)
      |> unwrap_delegate([])

    {:reply, reply, state}
  end

  def handle_call({:get_asset, type, key}, _from, state) do
    reply =
      delegate(fn -> Server.get_asset(state.project_server, type, key) end)
      |> unwrap_delegate(:error)

    {:reply, reply, state}
  end

  def handle_call({:search_assets, type, query}, _from, state) do
    reply =
      delegate(fn -> Server.search_assets(state.project_server, type, query) end)
      |> unwrap_delegate([])

    {:reply, reply, state}
  end

  def handle_call(:assets_diagnostics, _from, state) do
    reply =
      delegate(fn -> Server.assets_diagnostics(state.project_server) end)
      |> unwrap_delegate(%{})

    {:reply, reply, state}
  end

  def handle_call({:conversation_diagnostics, conversation_id}, _from, state) do
    reply =
      delegate(fn -> Server.conversation_diagnostics(state.project_server, conversation_id) end)
      |> unwrap_delegate({:error, :project_unavailable})

    {:reply, reply, state}
  end

  def handle_call({:incident_timeline, conversation_id, opts}, _from, state) do
    reply =
      delegate(fn -> Server.incident_timeline(state.project_server, conversation_id, opts) end)
      |> unwrap_delegate({:error, :project_unavailable})

    {:reply, reply, state}
  end

  def handle_call(:diagnostics, _from, state) do
    reply =
      delegate(fn -> Server.diagnostics(state.project_server) end)
      |> unwrap_delegate(%{})

    {:reply, reply, state}
  end

  def handle_call({:protocol_allowed?, protocol}, _from, state) do
    reply =
      delegate(fn -> Server.protocol_allowed?(state.project_server, protocol) end)
      |> unwrap_delegate({:error, :project_unavailable})

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
