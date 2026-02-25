defmodule Jido.Code.Server.Conversation.Domain.Projections do
  @moduledoc """
  Deterministic projection builders for conversation domain state.
  """

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @spec build(Jido.Code.Server.Conversation.Domain.State.t()) :: map()
  def build(state) do
    %{
      timeline: timeline(state),
      llm_context: llm_context(state),
      diagnostics: diagnostics(state),
      subagent_status: subagent_status(state),
      pending_tool_calls: state.pending_tool_calls
    }
  end

  @spec timeline(map()) :: [map()]
  def timeline(state) do
    state.timeline
    |> Enum.map(&ConversationSignal.to_map/1)
  end

  @spec llm_context(map()) :: map()
  def llm_context(state) do
    %{
      project_id: state.project_id,
      conversation_id: state.conversation_id,
      status: state.status,
      events: Enum.map(state.timeline, &ConversationSignal.to_map/1),
      messages: build_messages(state.timeline),
      pending_tool_calls: state.pending_tool_calls
    }
  end

  @spec diagnostics(map()) :: map()
  def diagnostics(state) do
    last_signal = List.last(state.timeline)

    %{
      status: state.status,
      event_count: length(state.timeline),
      queue_size: state.queue_size,
      pending_tool_call_count: length(state.pending_tool_calls),
      pending_subagent_count: map_size(state.pending_subagents),
      last_signal_type: if(last_signal, do: last_signal.type, else: nil),
      drain_iteration: state.drain_iteration,
      max_queue_size: state.max_queue_size,
      max_drain_steps: state.max_drain_steps
    }
  end

  @spec subagent_status(map()) :: map()
  def subagent_status(state) do
    active =
      state.pending_subagents
      |> Map.values()
      |> Enum.map(&normalize_string_map/1)
      |> Enum.sort_by(&Map.get(&1, "child_id", ""))

    completed = terminal_subagent_summaries(state.timeline)

    %{
      active: active,
      completed: completed,
      count: length(active),
      active_count: length(active),
      completed_count: length(completed)
    }
  end

  defp terminal_subagent_summaries(signals) when is_list(signals) do
    signals
    |> Enum.reduce(%{}, fn
      %Jido.Signal{type: type, data: data}, acc
      when type in [
             "conversation.subagent.completed",
             "conversation.subagent.failed",
             "conversation.subagent.stopped"
           ] and is_map(data) ->
        child_id = data["child_id"] || data[:child_id]

        if is_binary(child_id) and child_id != "" do
          summary =
            data
            |> normalize_string_map()
            |> Map.put_new("child_id", child_id)
            |> Map.put("status", terminal_subagent_status(type))

          Map.put(acc, child_id, summary)
        else
          acc
        end

      _signal, acc ->
        acc
    end)
    |> Map.values()
    |> Enum.sort_by(&Map.get(&1, "child_id", ""))
  end

  defp terminal_subagent_summaries(_signals), do: []

  defp terminal_subagent_status("conversation.subagent.completed"), do: "completed"
  defp terminal_subagent_status("conversation.subagent.failed"), do: "failed"
  defp terminal_subagent_status("conversation.subagent.stopped"), do: "stopped"
  defp terminal_subagent_status(_type), do: "unknown"

  defp build_messages(signals) when is_list(signals) do
    signals
    |> Enum.reduce([], fn signal, acc ->
      case signal.type do
        "conversation.user.message" ->
          maybe_append_message(acc, "user", signal)

        "conversation.assistant.message" ->
          maybe_append_message(acc, "assistant", signal)

        _other ->
          acc
      end
    end)
  end

  defp maybe_append_message(messages, role, signal) do
    case extract_content(signal) do
      nil ->
        messages

      content ->
        messages ++
          [
            %{
              role: role,
              content: content,
              signal_id: signal.id,
              at: signal.time,
              type: signal.type
            }
          ]
    end
  end

  defp extract_content(%Jido.Signal{data: data}) when is_map(data) do
    content = data["content"] || data[:content]
    if is_binary(content) and String.trim(content) != "", do: content, else: nil
  end

  defp extract_content(_signal), do: nil

  defp normalize_string_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)

      normalized_value =
        cond do
          is_map(nested) -> normalize_string_map(nested)
          is_list(nested) -> Enum.map(nested, &normalize_string_map/1)
          true -> nested
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_string_map(value) when is_list(value),
    do: Enum.map(value, &normalize_string_map/1)

  defp normalize_string_map(value), do: value
end
