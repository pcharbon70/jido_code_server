defmodule Jido.Code.Server.Conversation.ExecutionEnvelope do
  @moduledoc """
  Normalized execution envelope mapper for reducer-derived mode step intents.
  """

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @type execution_kind ::
          :strategy_run
          | :tool_run
          | :command_run
          | :workflow_run
          | :subagent_spawn
          | :cancel_tools
          | :cancel_subagents

  @spec from_intent(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def from_intent(intent, opts \\ [])

  def from_intent(%{kind: :run_llm, source_signal: %Jido.Signal{} = source_signal}, opts) do
    strategy_envelope(source_signal, opts)
  end

  def from_intent(
        %{
          kind: :run_execution,
          execution_kind: :strategy_run,
          source_signal: %Jido.Signal{} = source_signal
        },
        opts
      ) do
    strategy_envelope(source_signal, opts)
  end

  def from_intent(
        %{kind: :run_tool, tool_call: tool_call, source_signal: %Jido.Signal{} = source_signal},
        opts
      )
      when is_map(tool_call) do
    normalized_tool_call = normalize_tool_call(tool_call)
    tool_name = map_get(normalized_tool_call, "name")

    if is_binary(tool_name) and String.trim(tool_name) != "" do
      {:ok,
       %{
         execution_kind: execution_kind_for_tool(tool_name),
         name: tool_name,
         args: map_get(normalized_tool_call, "args") || %{},
         meta:
           build_meta(opts, source_signal)
           |> deep_merge(map_get(normalized_tool_call, "meta") || %{}),
         correlation_id:
           map_get(normalized_tool_call, "correlation_id") ||
             ConversationSignal.correlation_id(source_signal),
         cause_id: source_signal.id,
         source_signal: source_signal,
         tool_call: normalized_tool_call
       }}
    else
      {:error, :invalid_tool_name}
    end
  end

  def from_intent(%{kind: :cancel_pending_tools, pending_tool_calls: pending} = intent, opts)
      when is_list(pending) do
    {:ok,
     %{
       execution_kind: :cancel_tools,
       name: "conversation.cancel_pending_tools",
       args: %{"pending_tool_calls" => pending},
       meta: build_meta(opts, map_get(intent, :source_signal)),
       correlation_id: map_get(intent, :correlation_id),
       cause_id: nil,
       pending_tool_calls: pending
     }}
  end

  def from_intent(%{kind: :cancel_pending_subagents, pending_subagents: pending} = intent, opts)
      when is_list(pending) do
    {:ok,
     %{
       execution_kind: :cancel_subagents,
       name: "conversation.cancel_pending_subagents",
       args: %{
         "pending_subagents" => pending,
         "reason" => map_get(intent, :reason)
       },
       meta: build_meta(opts, map_get(intent, :source_signal)),
       correlation_id: map_get(intent, :correlation_id),
       cause_id: nil,
       pending_subagents: pending
     }}
  end

  def from_intent(%{kind: kind}, _opts), do: {:error, {:unsupported_intent_kind, kind}}
  def from_intent(_intent, _opts), do: {:error, :invalid_intent}

  defp strategy_envelope(source_signal, opts) do
    mode = normalize_mode(Keyword.get(opts, :mode))
    mode_state = Keyword.get(opts, :mode_state, %{}) |> normalize_map()
    strategy_type = map_get(mode_state, "strategy") || default_strategy_type(mode)
    strategy_opts = Map.delete(mode_state, "strategy")

    {:ok,
     %{
       execution_kind: :strategy_run,
       name: "mode.#{mode}.strategy",
       mode: mode,
       strategy_type: strategy_type,
       strategy_opts: strategy_opts,
       args: %{
         "mode" => Atom.to_string(mode),
         "strategy_type" => strategy_type,
         "strategy_opts" => strategy_opts
       },
       meta: build_meta(opts, source_signal),
       correlation_id: ConversationSignal.correlation_id(source_signal),
       cause_id: source_signal.id,
       source_signal: source_signal
     }}
  end

  @spec execution_kind_for_tool(String.t()) ::
          :tool_run | :command_run | :workflow_run | :subagent_spawn
  def execution_kind_for_tool(name) when is_binary(name) do
    cond do
      String.starts_with?(name, "command.run.") -> :command_run
      String.starts_with?(name, "workflow.run.") -> :workflow_run
      String.starts_with?(name, "agent.spawn.") -> :subagent_spawn
      true -> :tool_run
    end
  end

  defp build_meta(opts, source_signal) do
    mode = normalize_mode(Keyword.get(opts, :mode))
    mode_state = Keyword.get(opts, :mode_state, %{}) |> normalize_map()

    meta =
      %{
        "mode" => Atom.to_string(mode),
        "mode_state" => mode_state
      }
      |> maybe_put("source_signal_type", source_signal_type(source_signal))

    case source_signal do
      %Jido.Signal{} = signal ->
        maybe_put(meta, "source_signal_id", signal.id)

      _other ->
        meta
    end
  end

  defp source_signal_type(%Jido.Signal{} = signal), do: signal.type
  defp source_signal_type(_signal), do: nil

  defp normalize_tool_call(tool_call) when is_map(tool_call) do
    tool_call
    |> normalize_string_key_map()
    |> Map.put_new("args", %{})
    |> Map.put_new("meta", %{})
  end

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

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp default_strategy_type(:planning), do: "planning"
  defp default_strategy_type(:engineering), do: "engineering_design"
  defp default_strategy_type(_mode), do: "code_generation"

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp deep_merge(_left, right), do: right

  defp map_get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp map_get(map, key) when is_map(map), do: Map.get(map, key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
