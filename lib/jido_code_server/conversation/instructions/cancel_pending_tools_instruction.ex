defmodule Jido.Code.Server.Conversation.Instructions.CancelPendingToolsInstruction do
  @moduledoc """
  Runtime instruction that emits cancellation signals for pending tools.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_cancel_pending_tools_instruction",
    schema: []

  alias Jido.Code.Server.Conversation.ToolBridge
  alias Jido.Code.Server.Telemetry

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    project_ctx = map_get(context, "project_ctx") || %{}

    conversation_id =
      map_get(context, "conversation_id") || map_get(params, "conversation_id") || "unknown"

    correlation_id = map_get(params, "correlation_id")
    reason = normalize_reason(map_get(params, "reason"))
    cause_id = map_get(params, "cause_id")

    _ = ToolBridge.cancel_pending(project_ctx, conversation_id)

    signals =
      params
      |> map_get("pending_tool_calls")
      |> List.wrap()
      |> Enum.map(&cancelled_tool_signal(&1, conversation_id, correlation_id, reason, cause_id))

    Enum.each(signals, fn signal ->
      Telemetry.emit("conversation.tool.cancelled", %{
        project_id: map_get(project_ctx, "project_id"),
        conversation_id: conversation_id,
        correlation_id: correlation_id_from_signal(signal)
      })
    end)

    {:ok, %{"signals" => signals}}
  end

  defp cancelled_tool_signal(
         tool_call,
         conversation_id,
         override_correlation_id,
         reason,
         cause_id
       ) do
    tool_call = normalize_string_map(tool_call)

    correlation_id =
      override_correlation_id || tool_call |> map_get("meta") |> map_get("correlation_id")

    extensions =
      %{}
      |> maybe_put("correlation_id", correlation_id)
      |> maybe_put("cause_id", cause_id)

    Jido.Signal.new!(
      "conversation.tool.cancelled",
      %{
        "name" => map_get(tool_call, "name") || "unknown",
        "args" => map_get(tool_call, "args") || %{},
        "meta" => map_get(tool_call, "meta") || %{},
        "reason" => reason
      },
      source: "/conversation/#{conversation_id}",
      extensions: extensions
    )
    |> Jido.Code.Server.Conversation.Signal.to_map()
  end

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

  defp normalize_string_map(value), do: value

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_existing_atom(key))
  end

  defp map_get(_map, _key), do: nil

  defp correlation_id_from_signal(signal) when is_map(signal) do
    signal
    |> map_get("meta")
    |> map_get("correlation_id")
  end

  defp correlation_id_from_signal(_signal), do: nil

  defp normalize_reason(reason) when is_binary(reason) do
    normalized = String.trim(reason)
    if normalized == "", do: "conversation_cancelled", else: normalized
  end

  defp normalize_reason(_reason), do: "conversation_cancelled"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
