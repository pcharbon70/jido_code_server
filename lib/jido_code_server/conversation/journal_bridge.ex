defmodule Jido.Code.Server.Conversation.JournalBridge do
  @moduledoc """
  Bridges `conversation.*` runtime signals into `jido_conversation` canonical streams.
  """

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias JidoConversation.ConversationRef

  @default_channel "jido_code_server"
  @default_ingress "jido_code_server"

  @type project_id :: String.t()
  @type conversation_id :: String.t()

  @spec ingest(project_id(), conversation_id(), Jido.Signal.t()) :: :ok | {:error, term()}
  def ingest(project_id, conversation_id, %Jido.Signal{} = signal)
      when is_binary(project_id) and is_binary(conversation_id) do
    attrs = conversation_signal(project_id, conversation_id, signal)

    case JidoConversation.ingest(attrs) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec timeline(project_id(), conversation_id(), keyword()) :: [map()]
  def timeline(project_id, conversation_id, opts \\ [])
      when is_binary(project_id) and is_binary(conversation_id) and is_list(opts) do
    JidoConversation.timeline(project_id, conversation_id, opts)
  end

  @spec llm_context(project_id(), conversation_id(), keyword()) :: [map()]
  def llm_context(project_id, conversation_id, opts \\ [])
      when is_binary(project_id) and is_binary(conversation_id) and is_list(opts) do
    JidoConversation.llm_context(project_id, conversation_id, opts)
  end

  defp conversation_signal(project_id, conversation_id, %Jido.Signal{} = signal) do
    subject = ConversationRef.subject(project_id, conversation_id)
    correlation_id = ConversationSignal.correlation_id(signal)
    data = normalize_map(signal.data)

    {type, payload} = map_signal(signal.type, signal.id, data, correlation_id)

    %{
      id: signal.id,
      type: type,
      source: signal.source,
      subject: subject,
      time: signal.time,
      data: payload,
      extensions: signal_extensions(signal.extensions, project_id, correlation_id)
    }
  end

  defp map_signal("conversation.user.message", signal_id, data, _correlation_id) do
    payload =
      %{
        "message_id" => map_get(data, "message_id") || signal_id,
        "ingress" => map_get(data, "ingress") || @default_ingress
      }
      |> maybe_put("content", map_get(data, "content"))
      |> maybe_put("text", map_get(data, "text"))
      |> maybe_put("metadata", normalize_map(map_get(data, "metadata")))

    {"conv.in.message.received", payload}
  end

  defp map_signal("conversation.assistant.delta", signal_id, data, correlation_id) do
    payload =
      %{
        "output_id" => output_id(data, signal_id, correlation_id),
        "channel" => map_get(data, "channel") || @default_channel,
        "delta" => map_get(data, "delta") || map_get(data, "content") || ""
      }
      |> maybe_put("effect_id", map_get(data, "effect_id"))
      |> maybe_put("lifecycle", map_get(data, "lifecycle"))
      |> maybe_put("status", map_get(data, "status"))
      |> maybe_put("metadata", normalize_map(map_get(data, "metadata")))

    {"conv.out.assistant.delta", payload}
  end

  defp map_signal("conversation.assistant.message", signal_id, data, correlation_id) do
    payload =
      %{
        "output_id" => output_id(data, signal_id, correlation_id),
        "channel" => map_get(data, "channel") || @default_channel,
        "content" => map_get(data, "content") || ""
      }
      |> maybe_put("effect_id", map_get(data, "effect_id"))
      |> maybe_put("lifecycle", map_get(data, "lifecycle"))
      |> maybe_put("status", map_get(data, "status"))
      |> maybe_put("metadata", normalize_map(map_get(data, "metadata")))

    {"conv.out.assistant.completed", payload}
  end

  defp map_signal(type, signal_id, data, correlation_id)
       when type in [
              "conversation.tool.requested",
              "conversation.tool.completed",
              "conversation.tool.failed",
              "conversation.tool.cancelled"
            ] do
    status =
      case type do
        "conversation.tool.requested" -> "requested"
        "conversation.tool.completed" -> "completed"
        "conversation.tool.failed" -> "failed"
        "conversation.tool.cancelled" -> "cancelled"
      end

    payload =
      %{
        "output_id" => output_id(data, signal_id, correlation_id),
        "channel" => map_get(data, "channel") || @default_channel,
        "status" => status
      }
      |> maybe_put(
        "message",
        normalize_tool_status_message(map_get(data, "message") || map_get(data, "reason"))
      )
      |> maybe_put("tool_name", map_get(data, "name"))
      |> maybe_put("tool_call_id", map_get(data, "tool_call_id"))
      |> maybe_put("metadata", normalize_map(map_get(data, "metadata")))

    {"conv.out.tool.status", payload}
  end

  defp map_signal(type, signal_id, data, _correlation_id) do
    payload =
      %{
        "audit_id" => signal_id,
        "category" => "conversation.signal",
        "event_type" => type
      }
      |> maybe_put("metadata", data)

    {"conv.audit.policy.decision_recorded", payload}
  end

  defp signal_extensions(extensions, project_id, correlation_id) do
    extensions
    |> normalize_map()
    |> Map.put("contract_major", 1)
    |> Map.put("project_id", project_id)
    |> maybe_put("correlation_id", correlation_id)
  end

  defp output_id(data, signal_id, correlation_id) do
    map_get(data, "output_id") || map_get(data, "tool_call_id") || correlation_id || signal_id
  end

  defp maybe_put(map, _key, value) when value in [nil, %{}], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, maybe_existing_atom(key))
  end

  defp map_get(_map, _key), do: nil

  defp maybe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp normalize_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)
      normalized_value = normalize_value(value)
      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_map(_other), do: %{}

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_tool_status_message(nil), do: nil
  defp normalize_tool_status_message(message) when is_binary(message), do: message
  defp normalize_tool_status_message(message), do: inspect(message)
end
