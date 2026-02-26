defmodule Jido.Code.Server.Project.Server do
  @moduledoc """
  Project control-plane process.

  Phase 2 responsibilities:
  - canonicalize and validate project root
  - ensure project layout exists on disk
  - route conversation lifecycle and event/projection operations
  """

  use GenServer

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Conversation.Agent, as: ConversationAgent
  alias Jido.Code.Server.Conversation.JournalBridge
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Conversation.ToolBridge
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.ConversationRegistry
  alias Jido.Code.Server.Project.ConversationSupervisor
  alias Jido.Code.Server.Project.Layout
  alias Jido.Code.Server.Project.Naming
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.SubAgentManager
  alias Jido.Code.Server.Project.SubAgentTemplate
  alias Jido.Code.Server.Project.ToolCatalog
  alias Jido.Code.Server.Project.ToolRunner
  alias Jido.Code.Server.Telemetry

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

  @spec conversation_call(GenServer.server(), conversation_id(), Jido.Signal.t(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def conversation_call(server, conversation_id, %Jido.Signal{} = signal, timeout \\ 30_000) do
    GenServer.call(server, {:conversation_call, conversation_id, signal, timeout}, timeout)
  end

  @spec conversation_cast(GenServer.server(), conversation_id(), Jido.Signal.t()) ::
          :ok | {:error, term()}
  def conversation_cast(server, conversation_id, %Jido.Signal{} = signal) do
    GenServer.call(server, {:conversation_cast, conversation_id, signal})
  end

  @spec conversation_state(GenServer.server(), conversation_id(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def conversation_state(server, conversation_id, timeout \\ 30_000) do
    GenServer.call(server, {:conversation_state, conversation_id, timeout}, timeout)
  end

  @spec conversation_projection(
          GenServer.server(),
          conversation_id(),
          atom() | String.t(),
          timeout()
        ) ::
          {:ok, term()} | {:error, term()}
  def conversation_projection(server, conversation_id, key, timeout \\ 30_000) do
    GenServer.call(server, {:conversation_projection, conversation_id, key, timeout}, timeout)
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

  @spec conversation_diagnostics(GenServer.server(), conversation_id()) ::
          map() | {:error, term()}
  def conversation_diagnostics(server, conversation_id) do
    GenServer.call(server, {:conversation_diagnostics, conversation_id})
  end

  @spec incident_timeline(GenServer.server(), conversation_id(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def incident_timeline(server, conversation_id, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:incident_timeline, conversation_id, opts})
  end

  @spec diagnostics(GenServer.server()) :: map()
  def diagnostics(server) do
    GenServer.call(server, :diagnostics)
  end

  @spec protocol_allowed?(GenServer.server(), String.t()) :: :ok | {:error, :protocol_denied}
  def protocol_allowed?(server, protocol) when is_binary(protocol) do
    GenServer.call(server, {:protocol_allowed?, protocol})
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
    subagent_manager = Naming.via(project_id, :subagent_manager)
    conversation_registry = Keyword.fetch!(opts, :conversation_registry)
    conversation_supervisor = Keyword.fetch!(opts, :conversation_supervisor)
    runtime_opts = Keyword.get(opts, :runtime_opts, [])
    subagent_templates = load_subagent_templates(runtime_opts)

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
         subagent_manager: subagent_manager,
         subagent_templates: subagent_templates,
         conversation_registry: conversation_registry,
         conversation_supervisor: conversation_supervisor,
         conversations: %{},
         subscribers: %{},
         last_notified_event_index: %{},
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
        conversation_project_ctx =
          state
          |> project_ctx()
          |> Map.put(:conversation_id, conversation_id)
          |> Map.put(:conversation_server, self())
          |> Map.put(:subagent_manager, state.subagent_manager)
          |> Map.put(:subagent_templates, state.subagent_templates)
          |> Map.put(
            :llm_timeout_ms,
            runtime_opt(state, :llm_timeout_ms, Config.llm_timeout_ms())
          )
          |> Map.put(:llm_adapter, Keyword.get(state.runtime_opts, :llm_adapter))
          |> Map.put(:llm_model, Keyword.get(state.runtime_opts, :llm_model))
          |> Map.put(:llm_system_prompt, Keyword.get(state.runtime_opts, :llm_system_prompt))
          |> Map.put(:llm_temperature, Keyword.get(state.runtime_opts, :llm_temperature))
          |> Map.put(:llm_max_tokens, Keyword.get(state.runtime_opts, :llm_max_tokens))

        conversation_opts = [
          project_id: state.project_id,
          conversation_id: conversation_id,
          project_ctx: conversation_project_ctx,
          max_queue_size:
            runtime_opt(state, :conversation_max_queue_size, Config.conversation_max_queue_size()),
          max_drain_steps:
            runtime_opt(
              state,
              :conversation_max_drain_steps,
              Config.conversation_max_drain_steps()
            ),
          orchestration_enabled: conversation_orchestration_enabled?(state.runtime_opts),
          subagent_templates: state.subagent_templates
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

            last_notified_event_index =
              Map.put(state.last_notified_event_index, conversation_id, 0)

            Telemetry.emit("conversation.started", %{
              project_id: state.project_id,
              conversation_id: conversation_id
            })

            {:reply, {:ok, conversation_id},
             %{
               state
               | conversations: conversations,
                 last_notified_event_index: last_notified_event_index
             }}

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

        _ =
          SubAgentManager.stop_children_for_conversation(state.subagent_manager, conversation_id)

        Telemetry.emit("conversation.stopped", %{
          project_id: state.project_id,
          conversation_id: conversation_id
        })

        conversations = Map.delete(state.conversations, conversation_id)
        subscribers = Map.delete(state.subscribers, conversation_id)
        last_notified_event_index = Map.delete(state.last_notified_event_index, conversation_id)

        {:reply, :ok,
         %{
           state
           | conversations: conversations,
             subscribers: subscribers,
             last_notified_event_index: last_notified_event_index
         }}

      :error ->
        {:reply, {:error, {:conversation_not_found, conversation_id}}, state}
    end
  end

  def handle_call({:conversation_call, conversation_id, signal, timeout}, _from, state) do
    reply =
      with {:ok, pid} <- fetch_conversation_pid(state, conversation_id),
           {:ok, snapshot} <- ConversationAgent.call(pid, signal, timeout) do
        emit_conversation_ingested(state.project_id, conversation_id, signal)
        :ok = maybe_wait_for_orchestration(state, conversation_id)
        {:ok, snapshot}
      end

    {state, _delivered_count} = maybe_notify_subscribers_after_call(state, conversation_id)
    {:reply, reply, state}
  end

  def handle_call({:conversation_cast, conversation_id, signal}, _from, state) do
    reply =
      case fetch_conversation_pid(state, conversation_id) do
        {:ok, pid} ->
          case ConversationAgent.cast(pid, signal) do
            :ok ->
              emit_conversation_ingested(state.project_id, conversation_id, signal)
              send(self(), {:conversation_cast_dispatched, conversation_id})
              :ok

            {:error, _reason} = error ->
              error
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:conversation_state, conversation_id, timeout}, _from, state) do
    reply =
      case fetch_conversation_pid(state, conversation_id) do
        {:ok, pid} -> ConversationAgent.state(pid, timeout)
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:conversation_projection, conversation_id, key, timeout}, _from, state) do
    reply = conversation_projection_reply(state, conversation_id, key, timeout)
    {:reply, reply, state}
  end

  def handle_call({:subscribe_conversation, conversation_id, pid}, _from, state) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, conversation_pid} ->
        current_index =
          case ConversationAgent.projection(conversation_pid, :timeline) do
            {:ok, timeline} when is_list(timeline) -> length(timeline)
            _ -> Map.get(state.last_notified_event_index, conversation_id, 0)
          end

        subscribers =
          Map.update(state.subscribers, conversation_id, MapSet.new([pid]), &MapSet.put(&1, pid))

        {:reply, :ok,
         %{
           state
           | subscribers: subscribers,
             last_notified_event_index:
               Map.put(state.last_notified_event_index, conversation_id, current_index)
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe_conversation, conversation_id, pid}, _from, state) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, _conversation_pid} ->
        subscribers =
          update_in(state.subscribers, [Access.key(conversation_id, MapSet.new())], fn set ->
            MapSet.delete(set, pid)
          end)

        {:reply, :ok, %{state | subscribers: subscribers}}

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

  def handle_call({:conversation_diagnostics, conversation_id}, _from, state) do
    reply =
      case fetch_conversation_pid(state, conversation_id) do
        {:ok, pid} ->
          case ConversationAgent.projection(pid, :diagnostics) do
            {:ok, diagnostics} ->
              diagnostics
              |> Map.put_new(:project_id, state.project_id)
              |> Map.put_new(:conversation_id, conversation_id)

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:incident_timeline, conversation_id, opts}, _from, state) do
    reply = build_incident_timeline(state, conversation_id, opts)
    {:reply, reply, state}
  end

  def handle_call(:diagnostics, _from, state) do
    diagnostics = diagnostics_snapshot(state)
    {:reply, diagnostics, state}
  end

  def handle_call({:protocol_allowed?, protocol}, _from, state) do
    reply =
      if protocol_allowed_for_project?(state, protocol) do
        :ok
      else
        {:error, :protocol_denied}
      end

    {:reply, reply, state}
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
  def handle_info({:conversation_cast_dispatched, conversation_id}, state) do
    {state, _delivered_count} = maybe_notify_subscribers_after_call(state, conversation_id)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {conversation_id, conversations} = pop_by_monitor_ref(state.conversations, ref, pid)

    if conversation_id do
      _ = SubAgentManager.stop_children_for_conversation(state.subagent_manager, conversation_id)

      Telemetry.emit("conversation.stopped", %{
        project_id: state.project_id,
        conversation_id: conversation_id,
        reason: :process_down
      })

      :ok = ConversationRegistry.delete(state.conversation_registry, conversation_id)

      subscribers = Map.delete(state.subscribers, conversation_id)
      last_notified_event_index = Map.delete(state.last_notified_event_index, conversation_id)

      {:noreply,
       %{
         state
         | conversations: conversations,
           subscribers: subscribers,
           last_notified_event_index: last_notified_event_index
       }}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tool_result, task_pid, tool_call, result}, state)
      when is_pid(task_pid) and is_map(tool_call) do
    conversation_id =
      tool_call
      |> incident_map_get(:meta)
      |> incident_map_get(:conversation_id)

    next_state = maybe_apply_tool_result(state, conversation_id, task_pid, tool_call, result)

    {:noreply, next_state}
  end

  def handle_info({:subagent_started, conversation_id, subagent_ref}, state) do
    {:noreply,
     emit_subagent_signal(
       state,
       conversation_id,
       "conversation.subagent.started",
       subagent_ref,
       nil
     )}
  end

  def handle_info({:subagent_completed, conversation_id, subagent_ref, reason}, state) do
    {:noreply,
     emit_subagent_signal(
       state,
       conversation_id,
       "conversation.subagent.completed",
       subagent_ref,
       reason
     )}
  end

  def handle_info({:subagent_failed, conversation_id, subagent_ref, reason}, state) do
    {:noreply,
     emit_subagent_signal(
       state,
       conversation_id,
       "conversation.subagent.failed",
       subagent_ref,
       reason
     )}
  end

  def handle_info({:subagent_stopped, conversation_id, subagent_ref}, state) do
    {:noreply,
     emit_subagent_signal(
       state,
       conversation_id,
       "conversation.subagent.stopped",
       subagent_ref,
       nil
     )}
  end

  def handle_info({:subagent_stopped, conversation_id, subagent_ref, reason}, state) do
    {:noreply,
     emit_subagent_signal(
       state,
       conversation_id,
       "conversation.subagent.stopped",
       subagent_ref,
       reason
     )}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_apply_tool_result(state, conversation_id, _task_pid, _tool_call, _result)
       when not is_binary(conversation_id),
       do: state

  defp maybe_apply_tool_result(state, conversation_id, task_pid, tool_call, result) do
    with {:ok, events} <-
           ToolBridge.handle_tool_result(
             project_ctx(state),
             conversation_id,
             task_pid,
             tool_call,
             result
           ),
         signals when is_list(signals) <- events_to_signals(events),
         {:ok, pid} <- fetch_conversation_pid(state, conversation_id) do
      ingest_tool_result_signals(state, conversation_id, pid, signals)
    else
      _ -> state
    end
  end

  defp ingest_tool_result_signals(state, conversation_id, pid, signals) do
    Enum.each(signals, fn signal ->
      maybe_emit_ingested_signal(state.project_id, conversation_id, pid, signal)
    end)

    {updated_state, _count} = maybe_notify_subscribers_after_call(state, conversation_id)
    updated_state
  end

  defp maybe_emit_ingested_signal(project_id, conversation_id, pid, signal) do
    case ConversationAgent.call(pid, signal, 30_000) do
      {:ok, _snapshot} -> emit_conversation_ingested(project_id, conversation_id, signal)
      _other -> :ok
    end
  end

  defp fetch_conversation_pid(state, conversation_id) when is_binary(conversation_id) do
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

  defp fetch_conversation_pid(_state, conversation_id) do
    {:error, {:conversation_not_found, conversation_id}}
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
      tool_timeout_ms: runtime_opt(state, :tool_timeout_ms, Config.tool_timeout_ms()),
      tool_max_concurrency:
        runtime_opt(state, :tool_max_concurrency, Config.tool_max_concurrency()),
      tool_max_concurrency_per_conversation:
        runtime_opt(
          state,
          :tool_max_concurrency_per_conversation,
          Config.tool_max_concurrency_per_conversation()
        ),
      tool_timeout_alert_threshold:
        runtime_opt(
          state,
          :tool_timeout_alert_threshold,
          Config.tool_timeout_alert_threshold()
        ),
      tool_max_output_bytes:
        runtime_opt(state, :tool_max_output_bytes, Config.tool_max_output_bytes()),
      tool_max_artifact_bytes:
        runtime_opt(state, :tool_max_artifact_bytes, Config.tool_max_artifact_bytes()),
      network_egress_policy:
        runtime_opt(state, :network_egress_policy, Config.network_egress_policy()),
      network_allowlist: runtime_opt(state, :network_allowlist, Config.network_allowlist()),
      network_allowed_schemes:
        runtime_opt(state, :network_allowed_schemes, Config.network_allowed_schemes()),
      sensitive_path_denylist:
        runtime_opt(state, :sensitive_path_denylist, Config.sensitive_path_denylist()),
      sensitive_path_allowlist:
        runtime_opt(state, :sensitive_path_allowlist, Config.sensitive_path_allowlist()),
      outside_root_allowlist:
        runtime_opt(state, :outside_root_allowlist, Config.outside_root_allowlist()),
      tool_env_allowlist: runtime_opt(state, :tool_env_allowlist, Config.tool_env_allowlist()),
      command_executor: runtime_opt(state, :command_executor, nil),
      subagent_manager: state.subagent_manager,
      subagent_templates: state.subagent_templates,
      llm_timeout_ms: runtime_opt(state, :llm_timeout_ms, Config.llm_timeout_ms()),
      llm_adapter: Keyword.get(state.runtime_opts, :llm_adapter),
      llm_model: Keyword.get(state.runtime_opts, :llm_model),
      llm_system_prompt: Keyword.get(state.runtime_opts, :llm_system_prompt),
      llm_temperature: Keyword.get(state.runtime_opts, :llm_temperature),
      llm_max_tokens: Keyword.get(state.runtime_opts, :llm_max_tokens)
    }
  end

  defp build_incident_timeline(state, conversation_id, opts)
       when is_binary(conversation_id) and is_list(opts) do
    limit = incident_timeline_limit(opts)
    correlation_id = incident_timeline_correlation_id(opts)

    case incident_timeline_source(state, conversation_id) do
      {:ok, timeline} ->
        incident_timeline_response(state, conversation_id, timeline, correlation_id, limit)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_incident_timeline(_state, _conversation_id, _opts),
    do: {:error, :invalid_incident_timeline_request}

  defp incident_timeline_source(state, conversation_id) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, pid} ->
        ConversationAgent.projection(pid, :timeline)

      {:error, {:conversation_not_found, ^conversation_id}} ->
        timeline = JournalBridge.events(state.project_id, conversation_id)

        if timeline == [] do
          {:error, {:conversation_not_found, conversation_id}}
        else
          {:ok, timeline}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp incident_timeline_response(state, conversation_id, timeline, correlation_id, limit) do
    telemetry = Telemetry.snapshot(state.project_id)

    conversation_entries =
      incident_conversation_entries(timeline, conversation_id, correlation_id)

    telemetry_entries =
      telemetry.recent_events
      |> List.wrap()
      |> incident_telemetry_entries(conversation_id, correlation_id)

    total_entries = length(conversation_entries) + length(telemetry_entries)

    entries =
      conversation_entries
      |> Kernel.++(telemetry_entries)
      |> Enum.sort_by(&incident_sort_key/1)
      |> take_recent(limit)

    {:ok,
     %{
       project_id: state.project_id,
       conversation_id: conversation_id,
       correlation_id: correlation_id,
       limit: limit,
       total_entries: total_entries,
       entries: entries
     }}
  end

  defp runtime_opt(state, key, default) do
    Keyword.get(state.runtime_opts, key, default)
  end

  defp protocol_allowed_for_project?(state, protocol) do
    case normalize_protocol_name(protocol) do
      nil ->
        false

      normalized_protocol ->
        allowlist =
          state
          |> runtime_opt(:protocol_allowlist, Config.protocol_allowlist())
          |> normalize_protocol_allowlist()

        "*" in allowlist or normalized_protocol in allowlist
    end
  end

  defp normalize_protocol_allowlist(allowlist) when is_list(allowlist) do
    allowlist
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_protocol_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_protocol_allowlist(_allowlist), do: Config.protocol_allowlist()

  defp normalize_protocol_name(protocol) when is_binary(protocol) do
    normalized = protocol |> String.trim() |> String.downcase()
    if normalized == "", do: nil, else: normalized
  end

  defp normalize_protocol_name(_protocol), do: nil

  defp conversation_orchestration_enabled?(runtime_opts) when is_list(runtime_opts) do
    Keyword.get(runtime_opts, :conversation_orchestration, false) == true
  end

  defp conversation_orchestration_enabled?(_runtime_opts), do: false

  defp diagnostics_snapshot(state) do
    assets = AssetStore.diagnostics(state.asset_store)
    policy = Policy.diagnostics(state.policy)
    telemetry = Telemetry.snapshot(state.project_id)
    conversation_snapshots = conversation_snapshots(state)

    %{
      project_id: state.project_id,
      root_path: state.root_path,
      data_dir: state.data_dir,
      watcher_enabled: Keyword.get(state.opts, :watcher, false) == true,
      runtime_opts:
        Keyword.take(state.runtime_opts, [
          :conversation_orchestration,
          :llm_adapter,
          :watcher,
          :strict_asset_loading,
          :watcher_debounce_ms,
          :tool_timeout_ms,
          :tool_max_concurrency,
          :tool_max_concurrency_per_conversation,
          :tool_timeout_alert_threshold,
          :tool_max_output_bytes,
          :tool_max_artifact_bytes,
          :network_egress_policy,
          :network_allowlist,
          :network_allowed_schemes,
          :sensitive_path_denylist,
          :sensitive_path_allowlist,
          :outside_root_allowlist,
          :tool_env_allowlist,
          :command_executor,
          :protocol_allowlist,
          :llm_timeout_ms,
          :conversation_max_queue_size,
          :conversation_max_drain_steps,
          :subagent_templates,
          :subagent_max_children,
          :subagent_ttl_ms
        ]),
      health: %{
        status: if(telemetry.recent_errors == [], do: :ok, else: :degraded),
        conversation_count: map_size(state.conversations),
        error_count: length(telemetry.recent_errors)
      },
      assets: assets,
      policy: policy,
      telemetry: telemetry,
      conversations: conversation_snapshots
    }
  end

  defp incident_timeline_limit(opts) do
    case Keyword.get(opts, :limit, 100) do
      value when is_integer(value) and value > 0 ->
        min(value, 500)

      _ ->
        100
    end
  end

  defp incident_timeline_correlation_id(opts) do
    case Keyword.get(opts, :correlation_id) do
      id when is_binary(id) ->
        trimmed = String.trim(id)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end

  defp incident_conversation_entries(timeline, conversation_id, correlation_id)
       when is_list(timeline) do
    timeline
    |> Enum.map(fn event ->
      event_correlation = incident_event_correlation(event)
      event_name = event |> incident_map_get(:type) |> legacy_event_type(event)

      %{
        source: :conversation,
        at: incident_event_at(event),
        event: event_name,
        conversation_id: conversation_id,
        correlation_id: event_correlation,
        payload: event
      }
    end)
    |> Enum.reject(fn entry -> internal_conversation_incident_event?(entry.event) end)
    |> maybe_filter_correlation(correlation_id)
  end

  defp incident_conversation_entries(_timeline, _conversation_id, _correlation_id), do: []

  defp incident_telemetry_entries(events, conversation_id, correlation_id) when is_list(events) do
    events
    |> Enum.filter(fn event ->
      event_conversation_id =
        Map.get(event, :conversation_id) || Map.get(event, "conversation_id")

      event_conversation_id == conversation_id
    end)
    |> Enum.map(fn event ->
      event_correlation = Map.get(event, :correlation_id) || Map.get(event, "correlation_id")
      event_name = Map.get(event, :event) || Map.get(event, "event")

      %{
        source: :telemetry,
        at: Map.get(event, :at) || Map.get(event, "at"),
        event: normalize_telemetry_event_name(event_name, event),
        conversation_id: conversation_id,
        correlation_id: event_correlation,
        payload: event
      }
    end)
    |> Enum.reject(fn entry -> internal_telemetry_incident_event?(entry.event) end)
    |> maybe_filter_correlation(correlation_id)
  end

  defp incident_telemetry_entries(_events, _conversation_id, _correlation_id), do: []

  defp maybe_filter_correlation(entries, nil), do: entries

  defp maybe_filter_correlation(entries, correlation_id) do
    Enum.filter(entries, fn entry -> entry.correlation_id == correlation_id end)
  end

  defp incident_event_correlation(event) do
    event
    |> incident_map_get(:meta)
    |> incident_map_get(:correlation_id)
    |> case do
      nil ->
        event
        |> incident_map_get(:extensions)
        |> incident_map_get(:correlation_id)

      value ->
        value
    end
  end

  defp incident_event_at(event) do
    incident_map_get(event, :at) || incident_map_get(event, :time)
  end

  defp incident_map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp incident_map_get(_map, _key), do: nil

  defp incident_sort_key(entry) do
    {
      incident_timestamp(entry.at),
      incident_source_rank(entry.source)
    }
  end

  defp incident_timestamp(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)

  defp incident_timestamp(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, date_time, _offset} -> DateTime.to_unix(date_time, :millisecond)
      _ -> -1
    end
  end

  defp incident_timestamp(at) when is_integer(at), do: at
  defp incident_timestamp(_at), do: -1

  defp incident_source_rank(:conversation), do: 0
  defp incident_source_rank(:telemetry), do: 1
  defp incident_source_rank(_source), do: 2

  defp take_recent(entries, limit) when is_list(entries) and is_integer(limit) and limit > 0 do
    entries
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp take_recent(entries, _limit), do: entries

  defp conversation_snapshots(state) do
    state.conversations
    |> Enum.map(fn {conversation_id, %{pid: pid}} ->
      conversation_snapshot(conversation_id, pid)
    end)
    |> Enum.sort_by(& &1.conversation_id)
  end

  defp maybe_notify_subscribers_after_call(state, conversation_id) do
    subscribers = Map.get(state.subscribers, conversation_id, MapSet.new())

    if MapSet.size(subscribers) == 0 do
      {state, 0}
    else
      notify_subscribers(state, conversation_id, subscribers)
    end
  end

  defp conversation_snapshot(conversation_id, pid) do
    if Process.alive?(pid) do
      case ConversationAgent.projection(pid, :diagnostics) do
        {:ok, diagnostics} ->
          Map.put(diagnostics, :conversation_id, conversation_id)

        {:error, _reason} ->
          %{conversation_id: conversation_id, status: :degraded, pid: pid}
      end
    else
      %{conversation_id: conversation_id, status: :stopped, pid: pid}
    end
  end

  defp conversation_projection_reply(state, conversation_id, key, timeout) do
    case key do
      projection_key when projection_key in [:canonical_timeline, "canonical_timeline"] ->
        canonical_timeline_reply(state.project_id, conversation_id)

      projection_key when projection_key in [:canonical_llm_context, "canonical_llm_context"] ->
        canonical_llm_context_reply(state.project_id, conversation_id)

      _other ->
        with_conversation(state, conversation_id, fn pid ->
          ConversationAgent.projection(pid, key, timeout)
        end)
    end
  end

  defp with_conversation(state, conversation_id, fun) when is_function(fun, 1) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, pid} -> fun.(pid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_timeline_reply(project_id, conversation_id) when is_binary(conversation_id) do
    {:ok, JournalBridge.timeline(project_id, conversation_id)}
  end

  defp canonical_timeline_reply(_project_id, conversation_id) do
    {:error, {:conversation_not_found, conversation_id}}
  end

  defp canonical_llm_context_reply(project_id, conversation_id) when is_binary(conversation_id) do
    {:ok, JournalBridge.llm_context(project_id, conversation_id)}
  end

  defp canonical_llm_context_reply(_project_id, conversation_id) do
    {:error, {:conversation_not_found, conversation_id}}
  end

  defp notify_subscribers(state, conversation_id, subscribers) do
    with {:ok, pid} <- fetch_conversation_pid(state, conversation_id),
         {:ok, timeline} <- ConversationAgent.projection(pid, :timeline) do
      deliver_subscriber_events(state, conversation_id, subscribers, timeline)
    else
      _ -> {state, 0}
    end
  end

  defp deliver_subscriber_events(state, conversation_id, subscribers, timeline)
       when is_list(timeline) do
    last_index = Map.get(state.last_notified_event_index, conversation_id, 0)
    pending_events = timeline |> Enum.drop(last_index) |> List.wrap()

    Enum.each(pending_events, fn event ->
      legacy_event = legacy_timeline_event(event)
      send_conversation_event(subscribers, conversation_id, legacy_event)
      maybe_send_conversation_delta(subscribers, conversation_id, legacy_event)
    end)

    updated_index = last_index + length(pending_events)

    {
      %{
        state
        | last_notified_event_index:
            Map.put(state.last_notified_event_index, conversation_id, updated_index)
      },
      length(pending_events)
    }
  end

  defp deliver_subscriber_events(state, _conversation_id, _subscribers, _timeline), do: {state, 0}

  defp send_conversation_event(subscribers, conversation_id, event) do
    Enum.each(subscribers, fn pid ->
      send(pid, {:conversation_event, conversation_id, event})
    end)
  end

  defp maybe_send_conversation_delta(subscribers, conversation_id, event) do
    type = incident_map_get(event, :type)

    if type in ["conversation.assistant.delta", "assistant.delta"] do
      Enum.each(subscribers, fn pid ->
        send(pid, {:conversation_delta, conversation_id, event})
      end)
    end
  end

  defp emit_subagent_signal(state, conversation_id, type, payload, reason) do
    case fetch_conversation_pid(state, conversation_id) do
      {:ok, pid} ->
        data =
          payload
          |> normalize_payload_map()
          |> maybe_put_reason(reason)

        correlation_id = incident_map_get(data, :correlation_id)

        signal =
          Jido.Signal.new!(type, data,
            source: "/project/#{state.project_id}/conversation/#{conversation_id}",
            extensions:
              if(is_binary(correlation_id), do: %{"correlation_id" => correlation_id}, else: %{})
          )

        case ConversationAgent.call(pid, signal, 30_000) do
          {:ok, _snapshot} ->
            emit_conversation_ingested(state.project_id, conversation_id, signal)
            {updated_state, _count} = maybe_notify_subscribers_after_call(state, conversation_id)
            updated_state

          _other ->
            state
        end

      _ ->
        state
    end
  end

  defp normalize_payload_map(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {key, value}, acc ->
      normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)
      Map.put(acc, normalized_key, value)
    end)
  end

  defp normalize_payload_map(_payload), do: %{}

  defp maybe_put_reason(payload, nil), do: payload
  defp maybe_put_reason(payload, reason), do: Map.put(payload, "reason", inspect(reason))

  defp load_subagent_templates(runtime_opts) do
    templates =
      case Keyword.get(runtime_opts, :subagent_templates) do
        nil -> Config.subagent_templates()
        value -> value
      end

    templates
    |> List.wrap()
    |> Enum.flat_map(fn raw ->
      case SubAgentTemplate.from_map(raw,
             default_max_children: Config.default_subagent_max_children(),
             default_ttl_ms: Config.default_subagent_ttl_ms()
           ) do
        {:ok, template} -> [template]
        {:error, _reason} -> []
      end
    end)
  end

  defp legacy_timeline_event(event) when is_map(event) do
    type = incident_map_get(event, :type) |> legacy_event_type(event)
    data = event |> incident_map_get(:data) |> add_existing_atom_keys()
    meta = event |> incident_map_get(:meta) |> add_existing_atom_keys()

    event
    |> maybe_put_atom_key(:type, type)
    |> maybe_put_string_key("type", type)
    |> maybe_put_atom_key(:data, data)
    |> maybe_put_atom_key(:meta, meta)
    |> maybe_put_atom_key(:content, incident_map_get(event, :content))
    |> maybe_put_atom_key(:id, incident_map_get(event, :id))
    |> maybe_put_atom_key(:source, incident_map_get(event, :source))
    |> maybe_put_atom_key(:time, incident_map_get(event, :time))
    |> maybe_put_atom_key(:extensions, incident_map_get(event, :extensions))
    |> drop_nondeterministic_fields()
    |> drop_conversation_id_fields()
  end

  defp legacy_timeline_event(event), do: event

  defp legacy_event_type(type, event)

  defp legacy_event_type("conversation.llm.requested", _event), do: "llm.started"
  defp legacy_event_type("conversation.llm.completed", _event), do: "llm.completed"
  defp legacy_event_type("conversation.llm.failed", _event), do: "llm.failed"
  defp legacy_event_type("conversation.assistant.delta", _event), do: "assistant.delta"
  defp legacy_event_type("conversation.assistant.message", _event), do: "assistant.message"
  defp legacy_event_type("conversation.user.message", _event), do: "user.message"
  defp legacy_event_type("conv.out.assistant.delta", _event), do: "assistant.delta"
  defp legacy_event_type("conv.out.assistant.completed", _event), do: "assistant.message"
  defp legacy_event_type("conv.in.message.received", _event), do: "user.message"
  defp legacy_event_type("conversation.cancel", _event), do: "conversation.cancel"
  defp legacy_event_type("conversation.resume", _event), do: "conversation.resume"
  defp legacy_event_type("conversation.tool.requested", _event), do: "tool.requested"
  defp legacy_event_type("conversation.tool.completed", _event), do: "tool.completed"
  defp legacy_event_type("conv.out.tool.status", event), do: canonical_tool_status_event(event)

  defp legacy_event_type("conversation.tool.failed", event) do
    reason =
      event
      |> incident_map_get(:data)
      |> canonical_tool_failure_reason()

    if cancelled_tool_reason?(reason) do
      "tool.cancelled"
    else
      "tool.failed"
    end
  end

  defp legacy_event_type("conversation.tool.cancelled", _event), do: "tool.cancelled"

  defp legacy_event_type(type, _event) when is_binary(type) do
    if String.starts_with?(type, "conversation.") do
      String.replace_prefix(type, "conversation.", "")
    else
      type
    end
  end

  defp legacy_event_type(type, _event), do: type

  defp normalize_telemetry_event_name(name, payload) when is_binary(name) and is_map(payload) do
    if telemetry_cancelled_tool_event?(name, payload) do
      "tool.cancelled"
    else
      legacy_event_type(name, %{})
    end
  end

  defp normalize_telemetry_event_name(name, _payload), do: name

  defp internal_conversation_incident_event?(event) when is_binary(event) do
    String.starts_with?(event, "conv.")
  end

  defp internal_conversation_incident_event?(_event), do: false

  defp internal_telemetry_incident_event?(event)
       when event in ["event_ingested", "conversation.event_ingested"] do
    true
  end

  defp internal_telemetry_incident_event?(_event), do: false

  defp canonical_tool_status_event(event) do
    status =
      event
      |> incident_map_get(:data)
      |> incident_map_get(:status)
      |> normalize_tool_status()

    case status do
      "requested" -> "tool.requested"
      "completed" -> "tool.completed"
      "cancelled" -> "tool.cancelled"
      "failed" -> canonical_failed_tool_status_event(event)
      _ -> "tool.status"
    end
  end

  defp canonical_failed_tool_status_event(event) do
    reason =
      event
      |> incident_map_get(:data)
      |> canonical_tool_failure_reason()

    if cancelled_tool_reason?(reason) do
      "tool.cancelled"
    else
      "tool.failed"
    end
  end

  defp canonical_tool_failure_reason(data) when is_map(data) do
    incident_map_get(data, :message) || incident_map_get(data, :reason)
  end

  defp canonical_tool_failure_reason(_data), do: nil

  defp cancelled_tool_reason?(reason) when is_binary(reason) do
    normalized =
      reason
      |> String.trim()
      |> String.trim_leading(":")

    normalized == "conversation_cancelled"
  end

  defp cancelled_tool_reason?(reason) when is_atom(reason) do
    reason == :conversation_cancelled
  end

  defp cancelled_tool_reason?(_reason), do: false

  defp normalize_tool_status(status) when is_atom(status) do
    status
    |> Atom.to_string()
    |> normalize_tool_status()
  end

  defp normalize_tool_status(status) when is_binary(status) do
    status
    |> String.trim()
    |> String.trim_leading(":")
    |> String.downcase()
  end

  defp normalize_tool_status(_status), do: nil

  defp telemetry_cancelled_tool_event?(event_name, payload)
       when event_name in ["tool.failed", "conversation.tool.failed"] and is_map(payload) do
    reason = Map.get(payload, :reason) || Map.get(payload, "reason")
    cancelled_tool_reason?(reason)
  end

  defp telemetry_cancelled_tool_event?(_event_name, _payload), do: false

  defp drop_conversation_id_fields(value) when is_map(value) do
    value
    |> Map.drop([:conversation_id, "conversation_id"])
    |> Enum.reduce(%{}, fn {key, nested}, acc ->
      Map.put(acc, key, drop_conversation_id_fields(nested))
    end)
  end

  defp drop_conversation_id_fields(value) when is_list(value) do
    Enum.map(value, &drop_conversation_id_fields/1)
  end

  defp drop_conversation_id_fields(value), do: value

  defp drop_nondeterministic_fields(value) when is_map(value) do
    Map.drop(value, [:id, "id", :time, "time", :source, "source", :extensions, "extensions"])
  end

  defp maybe_put_atom_key(map, key, value) when is_map(map) and is_atom(key) do
    Map.put(map, key, value)
  end

  defp maybe_put_string_key(map, key, value) when is_map(map) and is_binary(key) do
    Map.put(map, key, value)
  end

  defp add_existing_atom_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      nested_value = add_existing_atom_keys(nested)
      acc = Map.put(acc, key, nested_value)
      maybe_put_existing_atom_key(acc, key, nested_value)
    end)
  end

  defp add_existing_atom_keys(value) when is_list(value) do
    Enum.map(value, &add_existing_atom_keys/1)
  end

  defp add_existing_atom_keys(value), do: value

  defp maybe_put_existing_atom_key(acc, key, nested_value) when is_binary(key) do
    case to_existing_atom(key) do
      nil -> acc
      atom_key -> Map.put(acc, atom_key, nested_value)
    end
  end

  defp maybe_put_existing_atom_key(acc, _key, _nested_value), do: acc

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp emit_conversation_ingested(project_id, conversation_id, %Jido.Signal{} = signal) do
    Telemetry.emit("conversation.event_ingested", %{
      project_id: project_id,
      conversation_id: conversation_id,
      event_type: signal.type,
      correlation_id: ConversationSignal.correlation_id(signal)
    })

    if signal.type == "conversation.tool.cancelled" do
      Telemetry.emit("tool.cancelled", %{
        project_id: project_id,
        conversation_id: conversation_id,
        correlation_id: ConversationSignal.correlation_id(signal)
      })
    end

    :ok
  end

  defp events_to_signals(events) when is_list(events) do
    events
    |> Enum.flat_map(fn event ->
      case ConversationSignal.normalize(event) do
        {:ok, signal} -> [signal]
        _ -> []
      end
    end)
  end

  defp maybe_wait_for_orchestration(state, conversation_id) do
    with {:ok, pid} <- fetch_conversation_pid(state, conversation_id),
         {:ok, conversation_state} <- ConversationAgent.state(pid) do
      maybe_wait_for_settle(pid, conversation_state)
    else
      _ -> :ok
    end
  end

  defp maybe_wait_for_settle(pid, conversation_state) do
    domain = Map.get(conversation_state, :domain) || %{}

    if Map.get(domain, :orchestration_enabled, false) do
      wait_for_settle(pid, System.monotonic_time(:millisecond) + 300, %{len: nil, stable: 0})
    else
      :ok
    end
  end

  defp wait_for_settle(pid, deadline_ms, tracker) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      :ok
    else
      wait_for_settle_iteration(pid, deadline_ms, tracker)
    end
  end

  defp wait_for_settle_iteration(pid, deadline_ms, tracker) do
    with {:ok, conversation_state} <- ConversationAgent.state(pid),
         {:ok, timeline} <- ConversationAgent.projection(pid, :timeline) do
      domain = Map.get(conversation_state, :domain) || %{}
      len = length(List.wrap(timeline))
      settle_next_step(pid, deadline_ms, tracker, domain, len)
    else
      _ -> :ok
    end
  end

  defp settle_next_step(pid, deadline_ms, tracker, domain, len) do
    queue_size = Map.get(domain, :queue_size, 0)
    pending = Map.get(domain, :pending_tool_calls, [])
    status = Map.get(domain, :status)

    cond do
      queue_size > 0 ->
        wait_for_next_settle(pid, deadline_ms, reset_tracker(len))

      pending != [] and pending_async?(pending) ->
        :ok

      pending != [] ->
        wait_for_next_settle(pid, deadline_ms, reset_tracker(len))

      status in [:idle, :cancelled] ->
        maybe_settle_stable(pid, deadline_ms, tracker, len)

      true ->
        wait_for_next_settle(pid, deadline_ms, reset_tracker(len))
    end
  end

  defp maybe_settle_stable(pid, deadline_ms, tracker, len) do
    next_tracker = advance_stable_tracker(tracker, len)

    if next_tracker.stable >= 2 do
      :ok
    else
      wait_for_next_settle(pid, deadline_ms, next_tracker)
    end
  end

  defp wait_for_next_settle(pid, deadline_ms, tracker) do
    Process.sleep(10)
    wait_for_settle(pid, deadline_ms, tracker)
  end

  defp reset_tracker(len), do: %{len: len, stable: 0}

  defp advance_stable_tracker(%{len: len, stable: stable}, len) do
    %{len: len, stable: stable + 1}
  end

  defp advance_stable_tracker(_tracker, len), do: %{len: len, stable: 0}

  defp pending_async?(pending_calls) when is_list(pending_calls) do
    Enum.any?(pending_calls, fn call ->
      meta = incident_map_get(call, :meta) || %{}
      incident_map_get(meta, :run_mode) == "async" or incident_map_get(meta, :async) == true
    end)
  end

  defp pending_async?(_pending_calls), do: false
end
