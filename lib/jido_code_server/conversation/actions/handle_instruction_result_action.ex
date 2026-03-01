defmodule Jido.Code.Server.Conversation.Actions.HandleInstructionResultAction do
  @moduledoc """
  Re-ingests instruction execution results as canonical conversation signals.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_handle_instruction_result",
    schema: []

  alias Jido.Code.Server.Conversation.Actions.Support
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, domain, state_map} <- Support.current_domain(context),
         signals <- instruction_signals(params, state_map),
         {domain, directives} <- Support.ingest_many_and_drain(domain, signals, state_map) do
      {:ok, %{domain: domain}, directives}
    end
  end

  defp instruction_signals(params, state_map) do
    status = map_get(params, "status")
    result = map_get(params, "result")

    case status do
      :ok ->
        extract_result_signals(result)

      "ok" ->
        extract_result_signals(result)

      :error ->
        error_signals(params, state_map)

      "error" ->
        error_signals(params, state_map)

      _other ->
        []
    end
  end

  defp extract_result_signals(result) when is_map(result) do
    result
    |> map_get("signals")
    |> List.wrap()
    |> Enum.flat_map(fn signal ->
      case ConversationSignal.normalize(signal) do
        {:ok, normalized} -> [normalized]
        {:error, _reason} -> []
      end
    end)
  end

  defp extract_result_signals(_result), do: []

  defp error_signals(params, state_map) do
    signals =
      params
      |> map_get("reason")
      |> extract_result_signals()

    cond do
      signals == [] ->
        [instruction_failed_signal(params, state_map)]

      terminal_failure_signal?(signals) ->
        signals

      true ->
        signals ++ [instruction_failed_signal(params, state_map)]
    end
  end

  defp terminal_failure_signal?(signals) when is_list(signals) do
    Enum.any?(signals, fn
      %Jido.Signal{type: type} ->
        type in [
          "conversation.llm.failed",
          "conversation.tool.failed",
          "conversation.tool.cancelled",
          "conversation.subagent.failed"
        ]

      _other ->
        false
    end)
  end

  defp instruction_failed_signal(params, state_map) do
    meta = map_get(params, "meta")
    reason = map_get(params, "reason") || :instruction_failed
    effect_kind = map_get(meta, "effect_kind") || "instruction"
    execution_kind = map_get(meta, "execution_kind")

    type =
      case effect_kind do
        "llm" -> "conversation.llm.failed"
        "tool" -> "conversation.tool.failed"
        "cancel_pending_tools" -> "conversation.tool.failed"
        "cancel_pending_subagents" -> "conversation.subagent.failed"
        "execution" -> execution_failure_type(execution_kind)
        _ -> "conversation.llm.failed"
      end

    data =
      %{"reason" => normalize_reason(reason), "effect_kind" => effect_kind}
      |> maybe_put("execution_kind", execution_kind)

    Jido.Signal.new!(type, data,
      source:
        "/project/#{map_get(state_map, "project_id")}/conversation/#{map_get(state_map, "conversation_id")}"
    )
  end

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

  defp execution_failure_type("strategy_run"), do: "conversation.llm.failed"
  defp execution_failure_type("tool_run"), do: "conversation.tool.failed"
  defp execution_failure_type("command_run"), do: "conversation.tool.failed"
  defp execution_failure_type("workflow_run"), do: "conversation.tool.failed"
  defp execution_failure_type("subagent_spawn"), do: "conversation.subagent.failed"
  defp execution_failure_type(_execution_kind), do: "conversation.llm.failed"

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_existing_atom(key))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
