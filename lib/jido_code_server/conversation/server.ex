defmodule JidoCodeServer.Conversation.Server do
  @moduledoc """
  Thin GenServer wrapper around conversation runtime state.
  """

  use GenServer

  alias JidoCodeServer.Conversation.Loop
  alias JidoCodeServer.Telemetry
  alias JidoCodeServer.Types.Event

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
      asset_store: Keyword.get(opts, :asset_store),
      policy: Keyword.get(opts, :policy),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms),
      tool_max_concurrency: Keyword.get(opts, :tool_max_concurrency),
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

  defp ingest_event_internal(state, raw_event) do
    with {:ok, event} <- Event.from_map(raw_event),
         updated_conversation <- Loop.ingest(state.conversation, event, raw_event),
         {:ok, next_conversation, emitted_events} <-
           Loop.after_ingest(updated_conversation, state.project_ctx) do
      next_state = %{state | conversation: next_conversation}

      emit_ingest_telemetry(
        next_state.project_id,
        next_state.conversation_id,
        event,
        emitted_events
      )

      notify_subscribers(
        next_state.subscribers,
        next_state.project_id,
        next_state.conversation_id,
        event,
        emitted_events
      )

      {:ok, next_state}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp emit_ingest_telemetry(project_id, conversation_id, event, emitted_events) do
    Telemetry.emit("conversation.event_ingested", %{
      project_id: project_id,
      conversation_id: conversation_id,
      event_type: event.type,
      emitted_count: length(emitted_events)
    })

    emit_runtime_event_telemetry(project_id, conversation_id, event, :incoming)
  end

  defp notify_subscribers(subscribers, project_id, conversation_id, event, emitted_events) do
    send_event(subscribers, conversation_id, event)
    Enum.each(emitted_events, &notify_emitted_event(subscribers, project_id, conversation_id, &1))
  end

  defp notify_emitted_event(subscribers, project_id, conversation_id, emitted) do
    case Event.from_map(emitted) do
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
      event_type: event.type
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

  defp normalize_projection_key(key) when is_atom(key), do: key

  defp normalize_projection_key(key) when is_binary(key) do
    case String.to_existing_atom(key) do
      projection_key -> projection_key
    end
  rescue
    ArgumentError -> :unknown_projection
  end
end
