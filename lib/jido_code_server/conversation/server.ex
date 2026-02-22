defmodule Jido.Code.Server.Conversation.Server do
  @moduledoc """
  Thin GenServer wrapper around conversation runtime state.
  """

  use GenServer

  alias Jido.Code.Server.Conversation.Loop
  alias Jido.Code.Server.Conversation.ToolBridge
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Telemetry
  alias Jido.Code.Server.Types.Event

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec get_projection(GenServer.server(), atom() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_projection(server, key) do
    GenServer.call(server, {:get_projection, key})
  end

  @spec diagnostics(GenServer.server()) :: map()
  def diagnostics(server) do
    GenServer.call(server, :diagnostics)
  end

  @spec ingest_event(GenServer.server(), map()) :: :ok
  def ingest_event(server, event) when is_map(event) do
    GenServer.cast(server, {:event, event})
  end

  @spec ingest_event_sync(GenServer.server(), map()) :: :ok | {:error, term()}
  def ingest_event_sync(server, event) when is_map(event) do
    GenServer.call(server, {:event, event})
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, pid \\ self()) when is_pid(pid) do
    GenServer.call(server, {:subscribe, pid})
  end

  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(server, pid \\ self()) when is_pid(pid) do
    GenServer.call(server, {:unsubscribe, pid})
  end

  @impl true
  def init(opts) do
    project_id = Keyword.get(opts, :project_id)
    conversation_id = Keyword.get(opts, :conversation_id)

    conversation = Loop.new(project_id, conversation_id)

    project_ctx = %{
      project_id: project_id,
      conversation_id: conversation_id,
      conversation_server: self(),
      asset_store: Keyword.get(opts, :asset_store),
      policy: Keyword.get(opts, :policy),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms),
      tool_max_concurrency: Keyword.get(opts, :tool_max_concurrency),
      tool_max_concurrency_per_conversation:
        Keyword.get(opts, :tool_max_concurrency_per_conversation),
      tool_timeout_alert_threshold: Keyword.get(opts, :tool_timeout_alert_threshold),
      tool_max_output_bytes: Keyword.get(opts, :tool_max_output_bytes),
      tool_max_artifact_bytes: Keyword.get(opts, :tool_max_artifact_bytes),
      network_egress_policy: Keyword.get(opts, :network_egress_policy),
      network_allowlist: Keyword.get(opts, :network_allowlist),
      network_allowed_schemes: Keyword.get(opts, :network_allowed_schemes),
      sensitive_path_denylist: Keyword.get(opts, :sensitive_path_denylist),
      sensitive_path_allowlist: Keyword.get(opts, :sensitive_path_allowlist),
      outside_root_allowlist: Keyword.get(opts, :outside_root_allowlist),
      llm_timeout_ms: Keyword.get(opts, :llm_timeout_ms),
      orchestration_enabled: Keyword.get(opts, :orchestration_enabled, false),
      llm_adapter: Keyword.get(opts, :llm_adapter),
      llm_model: Keyword.get(opts, :llm_model),
      llm_system_prompt: Keyword.get(opts, :llm_system_prompt),
      llm_temperature: Keyword.get(opts, :llm_temperature),
      llm_max_tokens: Keyword.get(opts, :llm_max_tokens)
    }

    state = %{
      opts: opts,
      project_id: project_id,
      conversation_id: conversation_id,
      conversation: conversation,
      project_ctx: project_ctx,
      subscribers: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    case ingest_event_internal(state, event) do
      {:ok, next_state} -> {:noreply, next_state}
      {:error, _reason, next_state} -> {:noreply, next_state}
    end
  end

  @impl true
  def handle_call({:event, event}, _from, state) do
    case ingest_event_internal(state, event) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  def handle_call({:get_projection, key}, _from, state) do
    projection_key = normalize_projection_key(key)

    case Map.fetch(state.conversation.projection_cache, projection_key) do
      {:ok, projection} -> {:reply, {:ok, projection}, state}
      :error -> {:reply, {:error, :projection_not_found}, state}
    end
  end

  def handle_call(:diagnostics, _from, state) do
    diagnostics = Map.get(state.conversation.projection_cache, :diagnostics, %{})

    response = %{
      project_id: state.project_id,
      conversation_id: state.conversation_id,
      status: state.conversation.status,
      subscriber_count: MapSet.size(state.subscribers),
      event_count: Map.get(diagnostics, :event_count, length(state.conversation.events)),
      pending_tool_call_count:
        Map.get(
          diagnostics,
          :pending_tool_call_count,
          length(state.conversation.pending_tool_calls)
        ),
      last_event_type: Map.get(diagnostics, :last_event_type),
      last_event_at: state.conversation.last_event && state.conversation.last_event.at,
      projections: state.conversation.projection_cache |> Map.keys() |> Enum.sort()
    }

    {:reply, response, state}
  end

  @impl true
  def handle_info({:tool_result, task_pid, call, result}, state)
      when is_pid(task_pid) and is_map(call) do
    conversation_id = state.conversation_id || "unknown"

    next_state =
      case ToolBridge.handle_tool_result(
             state.project_ctx,
             conversation_id,
             task_pid,
             call,
             result
           ) do
        {:ok, events} ->
          ingest_runtime_events(state, events)
      end

    {:noreply, next_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ingest_event_internal(state, raw_event) do
    with {:ok, parsed_event} <- Event.from_map(raw_event),
         {correlation_id, event} <- ensure_event_correlation(parsed_event),
         canonical_incoming <- incoming_raw_event(raw_event, event),
         updated_conversation <- Loop.ingest(state.conversation, event, canonical_incoming),
         {:ok, next_conversation, emitted_events} <-
           Loop.after_ingest(
             updated_conversation,
             Map.put(state.project_ctx, :correlation_id, correlation_id)
           ) do
      next_state = %{state | conversation: next_conversation}

      emit_ingest_telemetry(
        next_state.project_id,
        next_state.conversation_id,
        event,
        emitted_events,
        correlation_id
      )

      notify_subscribers(
        next_state.subscribers,
        next_state.project_id,
        next_state.conversation_id,
        event,
        emitted_events,
        correlation_id
      )

      {:ok, next_state}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp ingest_runtime_events(state, events) when is_list(events) do
    Enum.reduce(events, state, fn event, acc_state ->
      case ingest_event_internal(acc_state, event) do
        {:ok, next_state} -> next_state
        {:error, _reason, next_state} -> next_state
      end
    end)
  end

  defp emit_ingest_telemetry(project_id, conversation_id, event, emitted_events, correlation_id) do
    Telemetry.emit("conversation.event_ingested", %{
      project_id: project_id,
      conversation_id: conversation_id,
      event_type: event.type,
      emitted_count: length(emitted_events),
      correlation_id: correlation_id
    })

    emit_runtime_event_telemetry(project_id, conversation_id, event, :incoming)
  end

  defp notify_subscribers(
         subscribers,
         project_id,
         conversation_id,
         event,
         emitted_events,
         correlation_id
       ) do
    send_event(subscribers, conversation_id, event)

    Enum.each(emitted_events, fn emitted ->
      notify_emitted_event(subscribers, project_id, conversation_id, emitted, correlation_id)
    end)
  end

  defp notify_emitted_event(
         subscribers,
         project_id,
         conversation_id,
         emitted,
         fallback_correlation_id
       ) do
    emitted_with_correlation = ensure_emitted_event_correlation(emitted, fallback_correlation_id)

    case Event.from_map(emitted_with_correlation) do
      {:ok, normalized} ->
        emit_runtime_event_telemetry(project_id, conversation_id, normalized, :emitted)
        send_event(subscribers, conversation_id, normalized)
        maybe_send_delta(subscribers, conversation_id, normalized)

      {:error, _reason} ->
        :ok
    end
  end

  defp send_event(subscribers, conversation_id, event) do
    payload = Event.to_map(event)
    Enum.each(subscribers, &send(&1, {:conversation_event, conversation_id, payload}))
  end

  defp maybe_send_delta(subscribers, conversation_id, event) do
    if event.type in ["assistant.delta", "conversation.delta"] do
      payload = Event.to_map(event)
      Enum.each(subscribers, &send(&1, {:conversation_delta, conversation_id, payload}))
    end
  end

  defp emit_runtime_event_telemetry(project_id, conversation_id, event, source) do
    base_payload = %{
      project_id: project_id,
      conversation_id: conversation_id,
      event_source: source,
      event_type: event.type,
      correlation_id: correlation_id_from_event(event)
    }

    cond do
      event.type == "assistant.delta" ->
        Telemetry.emit("llm.delta", base_payload)

      String.starts_with?(event.type, "llm.") ->
        Telemetry.emit(event.type, base_payload)

      String.starts_with?(event.type, "tool.") ->
        Telemetry.emit(
          event.type,
          Map.put(base_payload, :reason, event.data[:reason] || event.data["reason"])
        )

      true ->
        :ok
    end
  end

  defp ensure_event_correlation(%Event{} = event) do
    {correlation_id, meta} = Correlation.ensure(event.meta)
    {correlation_id, %{event | meta: meta}}
  end

  defp incoming_raw_event(raw_event, %Event{} = event) when is_map(raw_event) do
    raw_event
    |> ensure_raw_event_field(:type, "type", event.type)
    |> ensure_raw_event_field(:at, "at", event.at)
    |> put_event_meta(event.meta)
  end

  defp ensure_emitted_event_correlation(raw_event, fallback_correlation_id)
       when is_map(raw_event) do
    meta = raw_event[:meta] || raw_event["meta"] || %{}

    correlation_id =
      case Correlation.fetch(meta) do
        {:ok, existing} ->
          existing

        :error when is_binary(fallback_correlation_id) and fallback_correlation_id != "" ->
          fallback_correlation_id

        :error ->
          Correlation.generate()
      end

    put_event_meta(raw_event, Correlation.put(meta, correlation_id))
  end

  defp ensure_emitted_event_correlation(raw_event, _fallback_correlation_id), do: raw_event

  defp put_event_meta(raw_event, meta) do
    cond do
      Map.has_key?(raw_event, :meta) ->
        Map.put(raw_event, :meta, meta)

      Map.has_key?(raw_event, "meta") ->
        Map.put(raw_event, "meta", meta)

      true ->
        Map.put(raw_event, "meta", meta)
    end
  end

  defp ensure_raw_event_field(raw_event, atom_key, string_key, value) do
    cond do
      Map.has_key?(raw_event, atom_key) ->
        raw_event

      Map.has_key?(raw_event, string_key) ->
        raw_event

      Map.has_key?(raw_event, :data) or Map.has_key?(raw_event, "data") ->
        Map.put(raw_event, string_key, value)

      true ->
        raw_event
    end
  end

  defp correlation_id_from_event(%Event{meta: meta}) when is_map(meta) do
    case Correlation.fetch(meta) do
      {:ok, correlation_id} -> correlation_id
      :error -> nil
    end
  end

  defp normalize_projection_key(key) when is_atom(key), do: key

  defp normalize_projection_key(key) when is_binary(key) do
    case String.to_existing_atom(key) do
      projection_key -> projection_key
    end
  rescue
    ArgumentError -> :unknown_projection
  end
end
