defmodule Jido.Code.Server.Conversation.Instructions.RunLLMInstruction do
  @moduledoc """
  Runtime instruction that executes one LLM turn and returns canonical signals.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_run_llm_instruction",
    schema: []

  alias Jido.Code.Server.Conversation.LLM
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    project_ctx = map_get(context, "project_ctx") || %{}
    conversation_id = map_get(params, "conversation_id") || map_get(context, "conversation_id")

    with {:ok, source_signal} <- normalize_source_signal(params),
         true <- is_binary(conversation_id) do
      llm_context = map_get(params, "llm_context") || %{}
      correlation_id = ConversationSignal.correlation_id(source_signal)

      requested_signal =
        new_signal(
          "conversation.llm.requested",
          %{"source_signal_id" => source_signal.id},
          conversation_id,
          correlation_id
        )

      opts =
        [
          source_event: ConversationSignal.to_legacy_event(source_signal)
        ]
        |> maybe_put_opt(:tool_specs, available_tool_specs(project_ctx))

      case LLM.start_completion(project_ctx, conversation_id, llm_context, opts) do
        {:ok, %{events: events}} ->
          completion_signals =
            events
            |> List.wrap()
            |> Enum.flat_map(&legacy_event_to_signals(&1, conversation_id, correlation_id))

          {:ok,
           %{
             "signals" =>
               Enum.map([requested_signal | completion_signals], &ConversationSignal.to_map/1)
           }}

        {:error, reason} ->
          failed_signal =
            new_signal(
              "conversation.llm.failed",
              %{"reason" => normalize_reason(reason)},
              conversation_id,
              correlation_id
            )

          {:ok,
           %{
             "signals" =>
               Enum.map([requested_signal, failed_signal], &ConversationSignal.to_map/1)
           }}
      end
    else
      false -> {:error, :missing_conversation_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_source_signal(params) do
    params
    |> map_get("source_signal")
    |> ConversationSignal.normalize()
  end

  defp available_tool_specs(project_ctx) do
    try do
      tools = Jido.Code.Server.Project.ToolCatalog.all_tools(project_ctx)

      filtered_tools =
        case Map.get(project_ctx, :policy) do
          nil -> tools
          policy -> Jido.Code.Server.Project.Policy.filter_tools(policy, tools)
        end

      filtered_tools
      |> Enum.map(fn tool ->
        %{
          name: tool.name,
          description: tool.description,
          input_schema: tool.input_schema
        }
      end)
    rescue
      _error ->
        []
    catch
      :exit, _reason ->
        []
    end
  end

  defp legacy_event_to_signals(raw_event, conversation_id, default_correlation_id)
       when is_map(raw_event) do
    type = map_get(raw_event, "type")

    canonical_type =
      cond do
        type == "assistant.delta" -> "conversation.assistant.delta"
        type == "assistant.message" -> "conversation.assistant.message"
        type == "tool.requested" -> "conversation.tool.requested"
        type == "tool.completed" -> "conversation.tool.completed"
        type == "tool.failed" -> "conversation.tool.failed"
        type == "llm.completed" -> "conversation.llm.completed"
        type == "llm.failed" -> "conversation.llm.failed"
        type == "llm.started" -> nil
        is_binary(type) and String.starts_with?(type, "conversation.") -> type
        is_binary(type) -> "conversation." <> type
        true -> nil
      end

    if is_nil(canonical_type) do
      []
    else
      data = map_get(raw_event, "data") || %{}

      correlation_id =
        raw_event
        |> map_get("meta")
        |> map_get("correlation_id") || default_correlation_id

      [new_signal(canonical_type, normalize_data(data), conversation_id, correlation_id)]
    end
  end

  defp legacy_event_to_signals(_raw_event, _conversation_id, _default_correlation_id), do: []

  defp new_signal(type, data, conversation_id, correlation_id) do
    attrs =
      [
        source: "/conversation/#{conversation_id}",
        extensions: if(correlation_id, do: %{"correlation_id" => correlation_id}, else: %{})
      ]

    Jido.Signal.new!(type, normalize_data(data), attrs)
  end

  defp maybe_put_opt(opts, _key, []), do: opts
  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_data(data) when is_map(data), do: data
  defp normalize_data(_data), do: %{}

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

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
