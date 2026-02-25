defmodule Jido.Code.Server.Conversation.Instructions.RunLLMInstruction do
  @moduledoc """
  Runtime instruction that executes one LLM turn and returns canonical signals.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_run_llm_instruction",
    schema: []

  alias Jido.Code.Server.Conversation.JournalBridge
  alias Jido.Code.Server.Conversation.LLM
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.ToolCatalog

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    project_ctx = map_get(context, "project_ctx") || %{}
    conversation_id = map_get(params, "conversation_id") || map_get(context, "conversation_id")

    with {:ok, source_signal} <- normalize_source_signal(params),
         true <- is_binary(conversation_id) do
      llm_context = resolve_llm_context(params, project_ctx, conversation_id)
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

  defp resolve_llm_context(params, project_ctx, conversation_id) do
    fallback = map_get(params, "llm_context") || %{}
    project_id = map_get(project_ctx, "project_id")

    with true <- is_binary(project_id) and project_id != "",
         true <- is_binary(conversation_id) and conversation_id != "",
         messages when is_list(messages) <- JournalBridge.llm_context(project_id, conversation_id),
         true <- messages != [] do
      %{messages: messages}
    else
      _ -> fallback
    end
  end

  defp available_tool_specs(project_ctx) do
    tools = ToolCatalog.all_tools(project_ctx)

    project_ctx
    |> filter_available_tools(tools)
    |> Enum.map(&tool_spec/1)
  rescue
    _error ->
      []
  catch
    :exit, _reason ->
      []
  end

  defp legacy_event_to_signals(raw_event, conversation_id, default_correlation_id)
       when is_map(raw_event) do
    case canonical_event_type(map_get(raw_event, "type")) do
      nil ->
        []

      canonical_type ->
        data = map_get(raw_event, "data") || %{}
        correlation_id = legacy_event_correlation_id(raw_event, default_correlation_id)
        [new_signal(canonical_type, normalize_data(data), conversation_id, correlation_id)]
    end
  end

  defp legacy_event_to_signals(_raw_event, _conversation_id, _default_correlation_id), do: []

  defp canonical_event_type("assistant.delta"), do: "conversation.assistant.delta"
  defp canonical_event_type("assistant.message"), do: "conversation.assistant.message"
  defp canonical_event_type("tool.requested"), do: "conversation.tool.requested"
  defp canonical_event_type("tool.completed"), do: "conversation.tool.completed"
  defp canonical_event_type("tool.failed"), do: "conversation.tool.failed"
  defp canonical_event_type("llm.completed"), do: "conversation.llm.completed"
  defp canonical_event_type("llm.failed"), do: "conversation.llm.failed"
  defp canonical_event_type("llm.started"), do: nil

  defp canonical_event_type(type) when is_binary(type) do
    if String.starts_with?(type, "conversation."), do: type, else: "conversation." <> type
  end

  defp canonical_event_type(_type), do: nil

  defp legacy_event_correlation_id(raw_event, fallback) do
    raw_event
    |> map_get("meta")
    |> map_get("correlation_id")
    |> case do
      nil -> fallback
      correlation_id -> correlation_id
    end
  end

  defp filter_available_tools(project_ctx, tools) when is_list(tools) do
    case Map.get(project_ctx, :policy) do
      nil -> tools
      policy -> Policy.filter_tools(policy, tools)
    end
  end

  defp tool_spec(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema
    }
  end

  defp new_signal(type, data, conversation_id, correlation_id) do
    attrs =
      [
        source: "/conversation/#{conversation_id}",
        extensions: if(correlation_id, do: %{"correlation_id" => correlation_id}, else: %{})
      ]

    Jido.Signal.new!(type, normalize_data(data), attrs)
  end

  defp maybe_put_opt(opts, _key, []), do: opts
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
