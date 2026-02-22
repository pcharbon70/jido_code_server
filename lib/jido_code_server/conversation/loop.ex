defmodule JidoCodeServer.Conversation.Loop do
  @moduledoc """
  Pure conversation state transitions executed after each ingest.
  """

  alias JidoCodeServer.Types.Event
  alias JidoCodeServer.Types.ToolCall

  @type state :: %{
          project_id: String.t() | nil,
          conversation_id: String.t() | nil,
          events: [Event.t()],
          raw_timeline: [map()],
          pending_tool_calls: [ToolCall.t()],
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
      status: :idle,
      projection_cache: %{},
      last_event: nil
    }

    state
    |> refresh_projections()
  end

  @spec ingest(state(), Event.t(), map()) :: state()
  def ingest(state, %Event{} = event, raw_event) when is_map(state) and is_map(raw_event) do
    pending_tool_calls =
      state.pending_tool_calls
      |> update_pending_on_requested(event)
      |> update_pending_on_completion(event)

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
        status: status,
        last_event: event
    }
  end

  @spec after_ingest(state(), map()) :: {:ok, state(), list(map())}
  def after_ingest(conv_state, _project_ctx) when is_map(conv_state) do
    updated_state = refresh_projections(conv_state)
    {:ok, updated_state, []}
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
       when type in ["tool.completed", "tool.failed"] do
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
end
