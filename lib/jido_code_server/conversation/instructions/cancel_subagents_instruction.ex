defmodule Jido.Code.Server.Conversation.Instructions.CancelSubagentsInstruction do
  @moduledoc """
  Runtime instruction that stops active sub-agents and emits canonical terminal signals.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_cancel_subagents_instruction",
    schema: []

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Project.SubAgentManager

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    project_ctx = map_get(context, "project_ctx") || %{}
    conversation_id = map_get(context, "conversation_id") || map_get(params, "conversation_id")

    pending_subagents =
      params
      |> map_get("pending_subagents")
      |> List.wrap()
      |> Enum.map(&normalize_string_map/1)

    correlation_id = map_get(params, "correlation_id")
    reason = normalize_reason(map_get(params, "reason"))

    manager_subagents = active_subagents_from_manager(project_ctx, conversation_id)
    maybe_stop_subagents(project_ctx, conversation_id)

    effective_subagents =
      case manager_subagents do
        [] -> pending_subagents
        list -> list
      end

    signals =
      Enum.map(effective_subagents, fn subagent ->
        stopped_subagent_signal(subagent, conversation_id || "unknown", correlation_id, reason)
      end)

    {:ok, %{"signals" => signals}}
  end

  defp maybe_stop_subagents(project_ctx, conversation_id) when is_map(project_ctx) do
    manager = map_get(project_ctx, "subagent_manager")

    if not is_nil(manager) and is_binary(conversation_id) and String.trim(conversation_id) != "" do
      _ =
        SubAgentManager.stop_children_for_conversation(
          manager,
          conversation_id,
          :conversation_cancelled,
          notify: false
        )

      :ok
    else
      :ok
    end
  end

  defp active_subagents_from_manager(project_ctx, conversation_id)
       when is_map(project_ctx) and is_binary(conversation_id) do
    manager = map_get(project_ctx, "subagent_manager")

    if is_nil(manager) do
      []
    else
      manager
      |> SubAgentManager.list_children(conversation_id)
      |> List.wrap()
      |> Enum.map(&subagent_ref_to_map/1)
    end
  rescue
    _error ->
      []
  end

  defp active_subagents_from_manager(_project_ctx, _conversation_id), do: []

  defp stopped_subagent_signal(subagent, conversation_id, correlation_id, reason) do
    signal_correlation_id = correlation_id || map_get(subagent, "correlation_id")

    attrs = [
      source: "/conversation/#{conversation_id}",
      extensions:
        if(is_binary(signal_correlation_id),
          do: %{"correlation_id" => signal_correlation_id},
          else: %{}
        )
    ]

    data =
      subagent
      |> normalize_string_map()
      |> Map.put("reason", reason)
      |> Map.put("status", "stopped")

    Jido.Signal.new!("conversation.subagent.stopped", data, attrs)
    |> ConversationSignal.to_map()
  end

  defp normalize_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "", do: "conversation_cancelled", else: reason
  end

  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(_reason), do: "conversation_cancelled"

  defp subagent_ref_to_map(%_{} = ref) do
    %{
      "child_id" => Map.get(ref, :child_id),
      "template_id" => Map.get(ref, :template_id),
      "owner_conversation_id" => Map.get(ref, :owner_conversation_id),
      "pid" => inspect(Map.get(ref, :pid)),
      "started_at" => format_started_at(Map.get(ref, :started_at)),
      "status" => normalize_status(Map.get(ref, :status)),
      "correlation_id" => Map.get(ref, :correlation_id)
    }
  end

  defp subagent_ref_to_map(ref) when is_map(ref), do: normalize_string_map(ref)
  defp subagent_ref_to_map(_ref), do: %{}

  defp format_started_at(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_started_at(value), do: value

  defp normalize_status(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_status(value), do: value

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

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_existing_atom(key))
  end

  defp map_get(_map, _key), do: nil

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
