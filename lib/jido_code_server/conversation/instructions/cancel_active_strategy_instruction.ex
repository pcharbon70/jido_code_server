defmodule Jido.Code.Server.Conversation.Instructions.CancelActiveStrategyInstruction do
  @moduledoc """
  Runtime instruction that delegates active strategy cancellation through the
  strategy runner gateway and emits a canonical strategy cancellation signal.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_cancel_active_strategy_instruction",
    schema: []

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Project.StrategyRunner

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    project_ctx = map_get(context, "project_ctx") || %{}
    conversation_id = map_get(context, "conversation_id") || map_get(params, "conversation_id")

    envelope = normalize_cancel_envelope(params, context)

    with true <- is_binary(conversation_id),
         :ok <- StrategyRunner.cancel(project_ctx, envelope) do
      {:ok,
       %{
         "signals" => [
           strategy_cancelled_signal(envelope, conversation_id)
         ]
       }}
    else
      false ->
        {:error, :missing_conversation_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_cancel_envelope(params, context) do
    %{
      execution_kind: :strategy_run,
      run_id: map_get(params, "run_id"),
      step_id: map_get(params, "step_id"),
      strategy_type: map_get(params, "strategy_type"),
      mode: normalize_mode(map_get(params, "mode") || map_get(context, "mode")),
      mode_state: normalize_map(map_get(params, "mode_state") || map_get(context, "mode_state")),
      correlation_id: map_get(params, "correlation_id"),
      cause_id: map_get(params, "cause_id"),
      reason: normalize_reason(map_get(params, "reason")),
      source_signal: normalize_signal(map_get(params, "source_signal"))
    }
  end

  defp strategy_cancelled_signal(envelope, conversation_id) do
    extensions =
      %{}
      |> maybe_put("correlation_id", map_get(envelope, :correlation_id))
      |> maybe_put("cause_id", map_get(envelope, :cause_id))

    Jido.Signal.new!(
      "conversation.strategy.cancelled",
      %{
        "run_id" => map_get(envelope, :run_id),
        "step_id" => map_get(envelope, :step_id),
        "strategy_type" => map_get(envelope, :strategy_type),
        "mode" => mode_label(map_get(envelope, :mode)),
        "reason" => normalize_reason(map_get(envelope, :reason))
      },
      source: "/conversation/#{conversation_id}",
      extensions: extensions
    )
    |> ConversationSignal.to_map()
  end

  defp normalize_signal(%Jido.Signal{} = signal), do: signal
  defp normalize_signal(signal) when is_map(signal), do: ConversationSignal.normalize!(signal)
  defp normalize_signal(_signal), do: nil

  defp normalize_mode(mode) when is_atom(mode), do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> :coding
      value -> String.to_atom(value)
    end
  end

  defp normalize_mode(_mode), do: :coding

  defp mode_label(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp mode_label(mode) when is_binary(mode), do: mode
  defp mode_label(_mode), do: "coding"

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> "conversation_cancelled"
      value -> value
    end
  end

  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(_reason), do: "conversation_cancelled"

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
