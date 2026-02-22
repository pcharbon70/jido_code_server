defmodule Jido.Code.Server.Conversation.Loop do
  @moduledoc """
  Pure conversation state transitions executed after each ingest.
  """

  alias Jido.Code.Server.Conversation.LLM
  alias Jido.Code.Server.Conversation.ToolBridge
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.ToolCatalog
  alias Jido.Code.Server.Types.Event
  alias Jido.Code.Server.Types.ToolCall
  alias Jido.Code.Server.Types.ToolSpec

  @max_orchestration_steps 64

  @type state :: %{
          project_id: String.t() | nil,
          conversation_id: String.t() | nil,
          events: [Event.t()],
          raw_timeline: [map()],
          pending_tool_calls: [ToolCall.t()],
          cancelled_tool_calls: [ToolCall.t()],
          status: :idle | :cancelled,
          projection_cache: map(),
          last_event: Event.t() | nil
        }

  @spec new(String.t() | nil, String.t() | nil) :: state()
  def new(project_id, conversation_id) do
    state = %{
      project_id: project_id,
      conversation_id: conversation_id,
      events: [],
      raw_timeline: [],
      pending_tool_calls: [],
      cancelled_tool_calls: [],
      status: :idle,
      projection_cache: %{},
      last_event: nil
    }

    refresh_projections(state)
  end

  @spec ingest(state(), Event.t(), map()) :: state()
  def ingest(state, %Event{} = event, raw_event) when is_map(state) and is_map(raw_event) do
    {pending_tool_calls, cancelled_tool_calls} =
      case event.type do
        "conversation.cancel" ->
          {[], state.pending_tool_calls}

        _ ->
          pending_tool_calls =
            state.pending_tool_calls
            |> update_pending_on_requested(event)
            |> update_pending_on_completion(event)

          {pending_tool_calls, []}
      end

    status =
      case event.type do
        "conversation.cancel" -> :cancelled
        "conversation.resume" -> :idle
        _ -> state.status
      end

    %{
      state
      | events: state.events ++ [event],
        raw_timeline: state.raw_timeline ++ [raw_event],
        pending_tool_calls: pending_tool_calls,
        cancelled_tool_calls: cancelled_tool_calls,
        status: status,
        last_event: event
    }
  end

  @spec after_ingest(state(), map()) :: {:ok, state(), list(map())}
  def after_ingest(conv_state, project_ctx) when is_map(conv_state) and is_map(project_ctx) do
    state = refresh_projections(conv_state)

    if orchestration_enabled?(project_ctx) do
      start_index = max(length(state.events) - 1, 0)

      {final_state, emitted_reversed} =
        process_event_queue(state, project_ctx, start_index, [], 0)

      {:ok, final_state, Enum.reverse(emitted_reversed)}
    else
      {:ok, state, []}
    end
  end

  def after_ingest(conv_state, _project_ctx) when is_map(conv_state) do
    {:ok, refresh_projections(conv_state), []}
  end

  defp process_event_queue(state, _project_ctx, index, emitted, _steps)
       when index < 0 or index >= length(state.events) do
    {state, emitted}
  end

  defp process_event_queue(state, _project_ctx, _index, emitted, steps)
       when steps >= @max_orchestration_steps do
    {state, emitted}
  end

  defp process_event_queue(state, project_ctx, index, emitted, steps) do
    event = Enum.at(state.events, index)
    followups = derive_followups(state, event, project_ctx)
    {next_state, next_emitted} = append_emitted_events(state, followups, emitted)

    process_event_queue(next_state, project_ctx, index + 1, next_emitted, steps + 1)
  end

  defp append_emitted_events(state, events, emitted) when is_list(events) do
    Enum.reduce(events, {state, emitted}, fn raw_event, {acc_state, acc_emitted} ->
      case Event.from_map(raw_event) do
        {:ok, event} ->
          canonical = Event.to_map(event)
          next_state = acc_state |> ingest(event, canonical) |> refresh_projections()
          {next_state, [canonical | acc_emitted]}

        {:error, _reason} ->
          {acc_state, acc_emitted}
      end
    end)
  end

  defp derive_followups(state, %Event{} = event, project_ctx) do
    correlation_id = correlation_id_from_event(event)

    cond do
      event.type == "conversation.cancel" ->
        cancel_runtime_work(state, project_ctx)
        |> attach_correlation(event, correlation_id)

      state.status == :cancelled ->
        []

      event.type == "tool.requested" ->
        tool_followups(project_ctx, state.conversation_id, event)
        |> attach_correlation(event, correlation_id)

      event.type in ["tool.completed", "tool.failed"] and state.pending_tool_calls == [] ->
        llm_followups(state, project_ctx, event)
        |> attach_correlation(event, correlation_id)

      event.type == "user.message" ->
        llm_followups(state, project_ctx, event)
        |> attach_correlation(event, correlation_id)

      true ->
        []
    end
  end

  defp llm_followups(state, project_ctx, source_event) do
    llm_context = Map.get(state.projection_cache, :llm_context, %{})
    tool_specs = available_tool_specs(project_ctx)

    opts =
      llm_request_opts(project_ctx)
      |> Keyword.put(:source_event, source_event)
      |> Keyword.put(:tool_specs, tool_specs)

    case LLM.start_completion(project_ctx, state.conversation_id || "unknown", llm_context, opts) do
      {:ok, %{events: events}} when is_list(events) -> events
      {:error, reason} -> [llm_failed_event(reason)]
    end
  end

  defp llm_request_opts(project_ctx) do
    [
      adapter: Map.get(project_ctx, :llm_adapter),
      model: Map.get(project_ctx, :llm_model),
      system_prompt: Map.get(project_ctx, :llm_system_prompt),
      temperature: Map.get(project_ctx, :llm_temperature),
      max_tokens: Map.get(project_ctx, :llm_max_tokens),
      timeout_ms: Map.get(project_ctx, :llm_timeout_ms)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp available_tool_specs(project_ctx) do
    case tool_inventory(project_ctx) do
      [] ->
        []

      tools ->
        tools
        |> Enum.map(&to_tool_spec_map/1)
        |> Enum.reject(&is_nil/1)
    end
  end

  defp tool_inventory(project_ctx) do
    with true <- not is_nil(Map.get(project_ctx, :asset_store)),
         policy when not is_nil(policy) <- Map.get(project_ctx, :policy) do
      tools = ToolCatalog.all_tools(project_ctx)
      Policy.filter_tools(policy, tools)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp to_tool_spec_map(tool) do
    case ToolSpec.from_map(tool) do
      {:ok, spec} -> ToolSpec.to_map(spec)
      {:error, _reason} -> nil
    end
  end

  defp tool_followups(project_ctx, conversation_id, event) do
    with {:ok, call} <- extract_tool_call(event),
         {:ok, events} <-
           ToolBridge.handle_tool_requested(
             project_ctx,
             conversation_id || "unknown",
             ToolCall.to_map(call)
           ) do
      events
    else
      _ -> []
    end
  end

  defp llm_failed_event(reason) do
    %{
      type: "llm.failed",
      data: %{"reason" => normalize_reason(reason)}
    }
  end

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(%_{} = reason), do: inspect(reason)
  defp normalize_reason(reason) when is_map(reason) or is_list(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  defp cancel_runtime_work(state, project_ctx) do
    _ = ToolBridge.cancel_pending(project_ctx, state.conversation_id || "unknown")

    Enum.map(state.cancelled_tool_calls, &tool_cancelled_event/1)
  end

  defp tool_cancelled_event(%ToolCall{} = call) do
    %{
      type: "tool.cancelled",
      data: %{
        "name" => call.name,
        "args" => call.args,
        "meta" => call.meta,
        "reason" => "conversation_cancelled"
      }
    }
  end

  defp orchestration_enabled?(project_ctx) do
    Map.get(project_ctx, :orchestration_enabled, false) == true
  end

  defp refresh_projections(state) do
    llm_context = %{
      project_id: state.project_id,
      conversation_id: state.conversation_id,
      status: state.status,
      events: state.raw_timeline,
      messages: build_messages(state.events),
      pending_tool_calls: Enum.map(state.pending_tool_calls, &ToolCall.to_map/1)
    }

    diagnostics = %{
      event_count: length(state.events),
      pending_tool_call_count: length(state.pending_tool_calls),
      last_event_type: state.last_event && state.last_event.type,
      status: state.status
    }

    projection_cache = %{
      timeline: state.raw_timeline,
      llm_context: llm_context,
      pending_tool_calls: Enum.map(state.pending_tool_calls, &ToolCall.to_map/1),
      diagnostics: diagnostics
    }

    %{state | projection_cache: projection_cache}
  end

  defp build_messages(events) do
    events
    |> Enum.reduce([], fn event, acc ->
      case event.type do
        "user.message" ->
          [%{role: "user", content: extract_content(event), at: event.at, type: event.type} | acc]

        "assistant.message" ->
          [
            %{role: "assistant", content: extract_content(event), at: event.at, type: event.type}
            | acc
          ]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp extract_content(event) do
    cond do
      is_binary(event.data[:content]) -> event.data[:content]
      is_binary(event.data["content"]) -> event.data["content"]
      true -> ""
    end
  end

  defp update_pending_on_requested(calls, event) do
    case event.type do
      "tool.requested" ->
        case extract_tool_call(event) do
          {:ok, call} -> calls ++ [call]
          _ -> calls
        end

      _ ->
        calls
    end
  end

  defp update_pending_on_completion(calls, %{type: type} = event)
       when type in ["tool.completed", "tool.failed", "tool.cancelled"] do
    case extract_tool_name(event) do
      nil -> calls
      name -> Enum.reject(calls, fn call -> call.name == name end)
    end
  end

  defp update_pending_on_completion(calls, _event), do: calls

  defp extract_tool_call(event) do
    data = event.data

    cond do
      is_map(data[:tool_call]) ->
        ToolCall.from_map(data[:tool_call])

      is_map(data["tool_call"]) ->
        ToolCall.from_map(data["tool_call"])

      is_binary(data[:name]) or is_binary(data["name"]) ->
        ToolCall.from_map(data)

      true ->
        {:error, :invalid_tool_call}
    end
  end

  defp extract_tool_name(event) do
    data = event.data

    cond do
      is_binary(data[:name]) ->
        data[:name]

      is_binary(data["name"]) ->
        data["name"]

      is_map(data[:tool_call]) ->
        Map.get(data[:tool_call], :name) || Map.get(data[:tool_call], "name")

      is_map(data["tool_call"]) ->
        Map.get(data["tool_call"], :name) || Map.get(data["tool_call"], "name")

      true ->
        nil
    end
  end

  defp attach_correlation(events, _event, nil) when is_list(events), do: events

  defp attach_correlation(events, _event, correlation_id) when is_list(events) do
    Enum.map(events, fn raw_event ->
      put_event_correlation(raw_event, correlation_id)
    end)
  end

  defp put_event_correlation(raw_event, correlation_id) when is_map(raw_event) do
    meta = Map.get(raw_event, :meta, Map.get(raw_event, "meta", %{})) || %{}
    meta_with_correlation = Correlation.put(meta, correlation_id)

    cond do
      Map.has_key?(raw_event, :meta) ->
        Map.put(raw_event, :meta, meta_with_correlation)

      Map.has_key?(raw_event, "meta") ->
        Map.put(raw_event, "meta", meta_with_correlation)

      true ->
        Map.put(raw_event, "meta", meta_with_correlation)
    end
  end

  defp put_event_correlation(raw_event, _correlation_id), do: raw_event

  defp correlation_id_from_event(%Event{meta: meta}) when is_map(meta) do
    case Correlation.fetch(meta) do
      {:ok, correlation_id} -> correlation_id
      :error -> nil
    end
  end

  defp correlation_id_from_event(_event), do: nil
end
