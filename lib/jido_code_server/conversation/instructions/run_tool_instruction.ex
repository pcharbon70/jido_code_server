defmodule Jido.Code.Server.Conversation.Instructions.RunToolInstruction do
  @moduledoc """
  Runtime instruction that executes one policy-gated tool call.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_run_tool_instruction",
    schema: []

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Conversation.ToolBridge
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.ToolCatalog
  alias Jido.Code.Server.Telemetry

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    project_ctx = map_get(context, "project_ctx") || %{}
    conversation_id = map_get(context, "conversation_id") || map_get(params, "conversation_id")
    mode = map_get(params, "mode") || map_get(context, "mode") || :coding
    enforce_exposure = map_get(params, "enforce_tool_exposure") == true

    with true <- is_binary(conversation_id),
         {:ok, tool_call} <- normalize_tool_call(map_get(params, "tool_call"), conversation_id),
         :ok <- maybe_ensure_tool_exposed(enforce_exposure, project_ctx, tool_call, mode) do
      requested_signals = subagent_requested_signals(tool_call, conversation_id)

      case ToolBridge.handle_tool_requested(project_ctx, conversation_id, tool_call) do
        {:ok, events} ->
          emitted_signals =
            events
            |> List.wrap()
            |> Enum.flat_map(&events_to_signal_maps(&1, conversation_id))

          {:ok, %{"signals" => requested_signals ++ emitted_signals}}
      end
    else
      false ->
        {:error, :missing_conversation_id}

      {:error, :tool_not_exposed} ->
        emit_tool_not_exposed_telemetry(project_ctx, params, mode, conversation_id)

        {:ok,
         %{
           "signals" => [
             tool_not_exposed_signal(map_get(params, "tool_call"), mode, conversation_id)
           ]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_ensure_tool_exposed(true, project_ctx, tool_call, mode),
    do: ensure_tool_exposed(project_ctx, tool_call, mode)

  defp maybe_ensure_tool_exposed(false, _project_ctx, _tool_call, _mode), do: :ok

  defp ensure_tool_exposed(project_ctx, tool_call, mode) when is_map(tool_call) do
    name = map_get(tool_call, "name")

    case ToolCatalog.llm_tool_allowed?(project_ctx, name, mode: mode) do
      {:ok, _spec} -> :ok
      {:error, :tool_not_exposed} -> {:error, :tool_not_exposed}
    end
  end

  defp tool_not_exposed_signal(raw_tool_call, mode, conversation_id) do
    normalized_call = normalize_string_map(raw_tool_call || %{})
    meta = map_get(normalized_call, "meta") || %{}
    correlation_id = map_get(normalized_call, "correlation_id") || map_get(meta, "correlation_id")

    signal_map(
      "conversation.tool.failed",
      %{
        "name" => map_get(normalized_call, "name") || "unknown",
        "args" => map_get(normalized_call, "args") || %{},
        "meta" => meta,
        "reason" => %{
          "code" => "tool_not_exposed",
          "mode" => normalize_mode_label(mode)
        }
      },
      conversation_id,
      correlation_id
    )
  end

  defp normalize_mode_label(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp normalize_mode_label(mode) when is_binary(mode), do: mode
  defp normalize_mode_label(_mode), do: "coding"

  defp emit_tool_not_exposed_telemetry(project_ctx, params, mode, conversation_id) do
    normalized_call = normalize_string_map(map_get(params, "tool_call") || %{})
    meta = map_get(normalized_call, "meta") || %{}
    correlation_id = map_get(normalized_call, "correlation_id") || map_get(meta, "correlation_id")
    project_id = map_get(project_ctx, "project_id")

    Telemetry.emit("conversation.tool.failed", %{
      project_id: project_id,
      conversation_id: conversation_id,
      correlation_id: correlation_id,
      tool: map_get(normalized_call, "name"),
      reason: "tool_not_exposed",
      mode: normalize_mode_label(mode)
    })
  end

  defp normalize_tool_call(raw_call, conversation_id) when is_map(raw_call) do
    normalized = normalize_string_map(raw_call)
    name = map_get(normalized, "name")

    if not is_binary(name) or String.trim(name) == "" do
      {:error, :invalid_tool_call_name}
    else
      incoming_correlation_id = map_get(normalized, "correlation_id")

      meta =
        normalize_string_map(map_get(normalized, "meta") || %{})
        |> maybe_put_correlation(incoming_correlation_id)

      {correlation_id, meta} = Correlation.ensure(meta)

      meta =
        meta
        |> Map.put_new("conversation_id", conversation_id)
        |> Map.put_new("correlation_id", correlation_id)

      {:ok,
       %{
         name: name,
         args: normalize_string_map(map_get(normalized, "args") || %{}),
         meta: meta
       }}
    end
  end

  defp normalize_tool_call(_raw_call, _conversation_id), do: {:error, :invalid_tool_call}

  defp subagent_requested_signals(tool_call, conversation_id) when is_map(tool_call) do
    tool_name = map_get(tool_call, "name") || map_get(tool_call, :name)

    if is_binary(tool_name) and String.starts_with?(tool_name, "agent.spawn.") do
      template_id = String.replace_prefix(tool_name, "agent.spawn.", "")
      args = map_get(tool_call, "args") || map_get(tool_call, :args) || %{}
      goal = map_get(args, "goal")
      meta = map_get(tool_call, "meta") || map_get(tool_call, :meta) || %{}
      correlation_id = map_get(meta, "correlation_id")

      [
        signal_map(
          "conversation.subagent.requested",
          %{"template_id" => template_id, "goal" => goal},
          conversation_id,
          correlation_id
        )
      ]
    else
      []
    end
  end

  defp events_to_signal_maps(event, conversation_id) when is_map(event) do
    event = normalize_string_map(event)

    case ConversationSignal.normalize(event) do
      {:ok, signal} ->
        base = [ConversationSignal.to_map(signal)]
        base ++ maybe_subagent_signal(signal, conversation_id)

      _ ->
        []
    end
  end

  defp events_to_signal_maps(_event, _conversation_id), do: []

  defp maybe_subagent_signal(%Jido.Signal{} = signal, conversation_id) do
    type = signal.type
    data = signal.data || %{}
    tool_name = map_get(data, "name")

    cond do
      type == "conversation.tool.completed" ->
        payload = data |> map_get("result") |> map_get("result")
        ref = payload && map_get(payload, "subagent")
        correlation_id = ConversationSignal.correlation_id(signal)

        if is_map(ref) do
          [signal_map("conversation.subagent.started", ref, conversation_id, correlation_id)]
        else
          []
        end

      type == "conversation.tool.failed" and is_binary(tool_name) and
          String.starts_with?(tool_name, "agent.spawn.") ->
        correlation_id = ConversationSignal.correlation_id(signal)
        template_id = String.replace_prefix(tool_name, "agent.spawn.", "")

        [
          signal_map(
            "conversation.subagent.failed",
            %{"template_id" => template_id, "reason" => map_get(data, "reason")},
            conversation_id,
            correlation_id
          )
        ]

      true ->
        []
    end
  end

  defp signal_map(type, data, conversation_id, correlation_id) do
    attrs =
      [
        source: "/conversation/#{conversation_id}",
        extensions: if(correlation_id, do: %{"correlation_id" => correlation_id}, else: %{})
      ]

    Jido.Signal.new!(type, normalize_string_map(data || %{}), attrs)
    |> ConversationSignal.to_map()
  end

  defp normalize_string_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)

      normalized_value =
        cond do
          match?(%_{}, nested) -> nested
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

  defp maybe_put_correlation(meta, correlation_id)
       when is_map(meta) and is_binary(correlation_id) do
    Map.put(meta, "correlation_id", correlation_id)
  end

  defp maybe_put_correlation(meta, _correlation_id), do: meta

  defp map_get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp map_get(_map, _key), do: nil

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
