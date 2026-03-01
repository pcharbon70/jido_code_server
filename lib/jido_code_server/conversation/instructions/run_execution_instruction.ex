defmodule Jido.Code.Server.Conversation.Instructions.RunExecutionInstruction do
  @moduledoc """
  Runtime instruction that delegates mode execution envelopes to ExecutionRunner.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_run_execution_instruction",
    schema: []

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Project.ExecutionRunner

  @supported_execution_kinds [:strategy_run]

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    project_ctx = map_get(context, "project_ctx") || %{}

    with {:ok, execution_envelope} <- normalize_execution_envelope(params, context),
         :ok <- validate_execution_kind(execution_envelope),
         {:ok, result} <- ExecutionRunner.run_execution(project_ctx, execution_envelope) do
      {:ok, normalize_execution_result(result)}
    end
  end

  defp normalize_execution_envelope(params, context) do
    raw_envelope = map_get(params, "execution_envelope")

    with envelope when is_map(envelope) <- normalize_string_key_map(raw_envelope || %{}),
         {:ok, source_signal} <- normalize_source_signal(map_get(envelope, "source_signal")),
         execution_kind when not is_nil(execution_kind) <-
           normalize_execution_kind(map_get(envelope, "execution_kind")),
         mode <- map_get(envelope, "mode") || map_get(context, "mode") || :coding,
         mode_state <-
           normalize_map(map_get(envelope, "mode_state") || map_get(context, "mode_state")),
         conversation_id <-
           map_get(envelope, "conversation_id") || map_get(context, "conversation_id"),
         llm_context <-
           normalize_map(map_get(envelope, "llm_context") || map_get(params, "llm_context")) do
      {:ok,
       %{
         execution_kind: execution_kind,
         name: map_get(envelope, "name"),
         mode: mode,
         mode_state: mode_state,
         strategy_type: map_get(envelope, "strategy_type"),
         strategy_opts: normalize_map(map_get(envelope, "strategy_opts")),
         source_signal: source_signal,
         llm_context: llm_context,
         correlation_id:
           map_get(envelope, "correlation_id") || ConversationSignal.correlation_id(source_signal),
         cause_id: map_get(envelope, "cause_id") || source_signal.id,
         conversation_id: conversation_id,
         meta: normalize_map(map_get(envelope, "meta"))
       }}
    else
      _ -> {:error, :invalid_execution_envelope}
    end
  end

  defp validate_execution_kind(%{execution_kind: execution_kind})
       when execution_kind in @supported_execution_kinds,
       do: :ok

  defp validate_execution_kind(%{execution_kind: execution_kind}),
    do: {:error, {:unsupported_execution_kind, execution_kind}}

  defp normalize_source_signal(%Jido.Signal{} = signal), do: {:ok, signal}

  defp normalize_source_signal(signal) when is_map(signal) do
    ConversationSignal.normalize(signal)
  end

  defp normalize_source_signal(_signal), do: {:error, :invalid_source_signal}

  defp normalize_execution_kind(kind) when is_atom(kind), do: kind

  defp normalize_execution_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> nil
      value -> String.to_atom(String.downcase(value))
    end
  end

  defp normalize_execution_kind(_kind), do: nil

  defp normalize_execution_result(result) when is_map(result) do
    %{
      "signals" =>
        result
        |> map_get("signals")
        |> List.wrap()
        |> normalize_signals(),
      "result_meta" => normalize_map(map_get(result, "result_meta")),
      "execution_ref" => normalize_execution_ref(result)
    }
  end

  defp normalize_signals(signals) when is_list(signals) do
    signals
    |> Enum.flat_map(fn signal ->
      case ConversationSignal.normalize(signal) do
        {:ok, normalized} -> [ConversationSignal.to_map(normalized)]
        {:error, _reason} -> []
      end
    end)
  end

  defp normalize_signals(_signals), do: []

  defp normalize_execution_ref(result) do
    case map_get(result, "execution_ref") do
      ref when is_binary(ref) and ref != "" ->
        ref

      _other ->
        "execution:unknown"
    end
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp normalize_string_key_map(%_{} = value), do: value

  defp normalize_string_key_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)

      normalized_value =
        cond do
          is_map(nested) -> normalize_string_key_map(nested)
          is_list(nested) -> Enum.map(nested, &normalize_string_key_map/1)
          true -> nested
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_string_key_map(value) when is_list(value),
    do: Enum.map(value, &normalize_string_key_map/1)

  defp normalize_string_key_map(value), do: value

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
