defmodule JidoCodeServer.Project.Server do
  @moduledoc """
  Project control-plane process.

  Phase 2 responsibilities:
  - canonicalize and validate project root
  - ensure project layout exists on disk
  - route conversation lifecycle and event/projection operations
  """

  use GenServer

  alias JidoCodeServer.Config
  alias JidoCodeServer.Conversation.Server, as: ConversationServer
  alias JidoCodeServer.Project.AssetStore
  alias JidoCodeServer.Project.ConversationRegistry
  alias JidoCodeServer.Project.ConversationSupervisor
  alias JidoCodeServer.Project.Layout
  alias JidoCodeServer.Project.Naming
  alias JidoCodeServer.Project.Policy
  alias JidoCodeServer.Project.ToolCatalog
  alias JidoCodeServer.Project.ToolRunner
  alias JidoCodeServer.Telemetry

  @type conversation_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec start_conversation(GenServer.server(), keyword()) ::
          {:ok, conversation_id()} | {:error, term()}
  def start_conversation(server, opts \\ []) do
    GenServer.call(server, {:start_conversation, opts})
  end

  @spec stop_conversation(GenServer.server(), conversation_id()) :: :ok | {:error, term()}
  def stop_conversation(server, conversation_id) do
    GenServer.call(server, {:stop_conversation, conversation_id})
  end

  @spec send_event(GenServer.server(), conversation_id(), map()) :: :ok | {:error, term()}
  def send_event(server, conversation_id, event) when is_map(event) do
    GenServer.call(server, {:send_event, conversation_id, event})
  end

  @spec subscribe_conversation(GenServer.server(), conversation_id(), pid()) ::
          :ok | {:error, term()}
  def subscribe_conversation(server, conversation_id, pid \\ self()) when is_pid(pid) do
    GenServer.call(server, {:subscribe_conversation, conversation_id, pid})
  end

  @spec unsubscribe_conversation(GenServer.server(), conversation_id(), pid()) ::
          :ok | {:error, term()}
  def unsubscribe_conversation(server, conversation_id, pid \\ self()) when is_pid(pid) do
    GenServer.call(server, {:unsubscribe_conversation, conversation_id, pid})
  end

  @spec get_projection(GenServer.server(), conversation_id(), atom() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_projection(server, conversation_id, key) do
    GenServer.call(server, {:get_projection, conversation_id, key})
  end

  @spec list_tools(GenServer.server()) :: [map()]
  def list_tools(server) do
    GenServer.call(server, :list_tools)
  end

  @spec run_tool(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def run_tool(server, tool_call) when is_map(tool_call) do
    GenServer.call(server, {:run_tool, tool_call})
  end

  @spec reload_assets(GenServer.server()) :: :ok | {:error, term()}
  def reload_assets(server) do
    GenServer.call(server, :reload_assets)
  end

  @spec list_assets(GenServer.server(), atom() | String.t()) :: [map()]
  def list_assets(server, type) do
    GenServer.call(server, {:list_assets, type})
  end

  @spec get_asset(GenServer.server(), atom() | String.t(), atom() | String.t()) ::
          {:ok, term()} | :error
  def get_asset(server, type, key) do
    GenServer.call(server, {:get_asset, type, key})
  end

  @spec search_assets(GenServer.server(), atom() | String.t(), String.t()) :: [map()]
  def search_assets(server, type, query) when is_binary(query) do
    GenServer.call(server, {:search_assets, type, query})
  end

  @spec assets_diagnostics(GenServer.server()) :: map()
  def assets_diagnostics(server) do
    GenServer.call(server, :assets_diagnostics)
  end

  @spec summary(GenServer.server()) :: map()
  def summary(server) do
    GenServer.call(server, :summary)
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    root_path = Keyword.fetch!(opts, :root_path)
    data_dir = Keyword.fetch!(opts, :data_dir)
    asset_store = Naming.via(project_id, :asset_store)
    policy = Naming.via(project_id, :policy)
    task_supervisor = Naming.via(project_id, :task_supervisor)
    conversation_registry = Keyword.fetch!(opts, :conversation_registry)
    conversation_supervisor = Keyword.fetch!(opts, :conversation_supervisor)
    runtime_opts = Keyword.get(opts, :runtime_opts, [])

    with {:ok, canonical_root} <- Layout.canonical_root(root_path),
         {:ok, layout} <- Layout.ensure_layout(canonical_root, data_dir),
         :ok <- AssetStore.load(asset_store, layout) do
      Telemetry.emit("project.started", %{
        project_id: project_id,
        root_path: canonical_root,
        data_dir: data_dir
      })

      {:ok,
       %{
         project_id: project_id,
         root_path: canonical_root,
         data_dir: data_dir,
         layout: layout,
         asset_store: asset_store,
         policy: policy,
         task_supervisor: task_supervisor,
         conversation_registry: conversation_registry,
         conversation_supervisor: conversation_supervisor,
         conversations: %{},
         runtime_opts: runtime_opts,
         opts: opts
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Telemetry.emit("project.stopped", %{
      project_id: state.project_id,
      root_path: state.root_path,
      data_dir: state.data_dir
    })

    :ok
  end

  @impl true
  def handle_call({:start_conversation, opts}, _from, state) do
    conversation_id =
      case Keyword.get(opts, :conversation_id) do
        id when is_binary(id) and id != "" ->
          id

        _ ->
          "conversation_" <> Integer.to_string(System.unique_integer([:positive]))
      end

    case ConversationRegistry.fetch(state.conversation_registry, conversation_id) do
      {:ok, _existing_pid} ->
        {:reply, {:error, {:conversation_already_started, conversation_id}}, state}

      :error ->
        conversation_opts = [
          project_id: state.project_id,
          conversation_id: conversation_id,
          asset_store: state.asset_store,
          policy: state.policy,
          task_supervisor: state.task_supervisor,
          tool_timeout_ms: Config.tool_timeout_ms(),
          tool_max_concurrency: Config.tool_max_concurrency(),
          llm_timeout_ms: Config.llm_timeout_ms(),
          orchestration_enabled: conversation_orchestration_enabled?(state.runtime_opts),
          llm_adapter: Keyword.get(state.runtime_opts, :llm_adapter),
          llm_model: Keyword.get(state.runtime_opts, :llm_model),
          llm_system_prompt: Keyword.get(state.runtime_opts, :llm_system_prompt),
          llm_temperature: Keyword.get(state.runtime_opts, :llm_temperature),
          llm_max_tokens: Keyword.get(state.runtime_opts, :llm_max_tokens)
        ]

        case ConversationSupervisor.start_conversation(
               state.conversation_supervisor,
               conversation_opts
             ) do
          {:ok, pid} ->
            monitor_ref = Process.monitor(pid)
            :ok = ConversationRegistry.put(state.conversation_registry, conversation_id, pid)

            conversations =
              Map.put(state.conversations, conversation_id, %{pid: pid, monitor_ref: monitor_ref})

            {:reply, {:ok, conversation_id}, %{state | conversations: conversations}}

          {:error, reason} ->
            {:reply, {:error, {:start_conversation_failed, reason}}, state}
        end
    end
  end

  def handle_call({:stop_conversation, conversation_id}, _from, state) do
    case Map.fetch(state.conversations, conversation_id) do
      {:ok, %{pid: pid, monitor_ref: monitor_ref}} ->
        _ = ConversationSupervisor.stop_conversation(state.conversation_supervisor, pid)
        :ok = ConversationRegistry.delete(state.conversation_registry, conversation_id)
        Process.demonitor(monitor_ref, [:flush])

        conversations = Map.delete(state.conversations, conversation_id)
        {:reply, :ok, %{state | conversations: conversations}}

      :error ->
        {:reply, {:error, {:conversation_not_found, conversation_id}}, state}
    end
  end

  def handle_call({:send_event, conversation_id, event}, _from, state) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, pid} ->
        case ConversationServer.ingest_event_sync(pid, event) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe_conversation, conversation_id, pid}, _from, state) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, conversation_pid} ->
        :ok = ConversationServer.subscribe(conversation_pid, pid)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe_conversation, conversation_id, pid}, _from, state) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, conversation_pid} ->
        :ok = ConversationServer.unsubscribe(conversation_pid, pid)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_projection, conversation_id, key}, _from, state) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, pid} ->
        {:reply, ConversationServer.get_projection(pid, key), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_tools, _from, state) do
    available_tools =
      state
      |> project_ctx()
      |> ToolCatalog.all_tools()

    filtered_tools = Policy.filter_tools(state.policy, available_tools)

    {:reply, filtered_tools, state}
  end

  def handle_call({:run_tool, tool_call}, _from, state) do
    reply =
      state
      |> project_ctx()
      |> ToolRunner.run(tool_call)

    {:reply, reply, state}
  end

  def handle_call(:reload_assets, _from, state) do
    {:reply, AssetStore.reload(state.asset_store), state}
  end

  def handle_call({:list_assets, type}, _from, state) do
    {:reply, AssetStore.list(state.asset_store, type), state}
  end

  def handle_call({:get_asset, type, key}, _from, state) do
    {:reply, AssetStore.get(state.asset_store, type, key), state}
  end

  def handle_call({:search_assets, type, query}, _from, state) do
    {:reply, AssetStore.search(state.asset_store, type, query), state}
  end

  def handle_call(:assets_diagnostics, _from, state) do
    {:reply, AssetStore.diagnostics(state.asset_store), state}
  end

  def handle_call(:summary, _from, state) do
    diagnostics = AssetStore.diagnostics(state.asset_store)

    summary = %{
      project_id: state.project_id,
      root_path: state.root_path,
      data_dir: state.data_dir,
      layout: state.layout,
      conversation_count: map_size(state.conversations),
      asset_versions: diagnostics.versions
    }

    {:reply, summary, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {conversation_id, conversations} = pop_by_monitor_ref(state.conversations, ref, pid)

    if conversation_id do
      :ok = ConversationRegistry.delete(state.conversation_registry, conversation_id)
      {:noreply, %{state | conversations: conversations}}
    else
      {:noreply, state}
    end
  end

  defp fetch_conversation_pid(state, conversation_id) do
    case ConversationRegistry.fetch(state.conversation_registry, conversation_id) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          :ok = ConversationRegistry.delete(state.conversation_registry, conversation_id)
          {:error, {:conversation_not_found, conversation_id}}
        end

      _ ->
        {:error, {:conversation_not_found, conversation_id}}
    end
  end

  defp pop_by_monitor_ref(conversations, ref, pid) do
    Enum.reduce(conversations, {nil, conversations}, fn {conversation_id, info},
                                                        {found_id, acc} ->
      cond do
        found_id ->
          {found_id, acc}

        info.monitor_ref == ref or info.pid == pid ->
          {conversation_id, Map.delete(acc, conversation_id)}

        true ->
          {nil, acc}
      end
    end)
  end

  defp project_ctx(state) do
    %{
      project_id: state.project_id,
      root_path: state.root_path,
      data_dir: state.data_dir,
      layout: state.layout,
      asset_store: state.asset_store,
      policy: state.policy,
      task_supervisor: state.task_supervisor,
      tool_timeout_ms: Config.tool_timeout_ms(),
      tool_max_concurrency: Config.tool_max_concurrency()
    }
  end

  defp conversation_orchestration_enabled?(runtime_opts) when is_list(runtime_opts) do
    Keyword.get(runtime_opts, :conversation_orchestration, false) == true
  end

  defp conversation_orchestration_enabled?(_runtime_opts), do: false
end
