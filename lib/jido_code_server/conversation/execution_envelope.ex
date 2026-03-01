defmodule Jido.Code.Server.Conversation.ExecutionEnvelope do
  @moduledoc """
  Normalized execution envelope mapper for reducer-derived mode step intents.
  """

  alias Jido.Code.Server.Conversation.ExecutionLifecycle
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
        } = intent,
        opts
      ) do
    strategy_envelope(
      source_signal,
      Keyword.put(opts, :intent_meta, map_get(intent, :meta) || %{})
    )
  end

  def from_intent(
        %{kind: :run_tool, tool_call: tool_call, source_signal: %Jido.Signal{} = source_signal},
        opts
      )
      when is_map(tool_call) do
    run_tool_envelope(tool_call, source_signal, opts)
  end

  def from_intent(%{kind: :cancel_pending_tools, pending_tool_calls: pending} = intent, opts)
      when is_list(pending) do
    source_signal = map_get(intent, :source_signal)

    {:ok,
     %{
       execution_kind: :cancel_tools,
       name: "conversation.cancel_pending_tools",
       args: %{
         "pending_tool_calls" => pending,
         "reason" => map_get(intent, :reason)
       },
       meta: build_meta(opts, source_signal),
       correlation_id: map_get(intent, :correlation_id),
       cause_id: source_signal_id(source_signal),
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

  defp run_tool_envelope(tool_call, source_signal, opts) do
    normalized_tool_call = normalize_tool_call(tool_call)

    with {:ok, tool_name} <- validate_tool_name(map_get(normalized_tool_call, "name")) do
      execution = build_tool_execution(normalized_tool_call, source_signal, opts, tool_name)
      enriched_tool_call = enrich_tool_call_execution(normalized_tool_call, execution)
      {:ok, build_tool_envelope(enriched_tool_call, execution, source_signal, tool_name, opts)}
    end
  end

  defp validate_tool_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, :invalid_tool_name}
      normalized -> {:ok, normalized}
    end
  end

  defp validate_tool_name(_name), do: {:error, :invalid_tool_name}

  defp build_tool_execution(normalized_tool_call, source_signal, opts, tool_name) do
    source_execution = source_execution_metadata(source_signal)
    normalized_mode = normalize_mode(Keyword.get(opts, :mode))
    execution_kind = execution_kind_for_tool(tool_name)
    correlation_id = tool_call_correlation_id(normalized_tool_call, source_signal)
    cause_id = source_signal.id

    ExecutionLifecycle.execution_metadata(
      %{
        execution_kind: execution_kind,
        execution_id: tool_call_field(normalized_tool_call, source_execution, "execution_id"),
        correlation_id: correlation_id,
        cause_id: cause_id,
        run_id: tool_call_field(normalized_tool_call, source_execution, "run_id"),
        step_id: tool_call_field(normalized_tool_call, source_execution, "step_id"),
        mode: normalized_mode
      },
      %{"lifecycle_status" => "requested"}
    )
  end

  defp build_tool_envelope(enriched_tool_call, execution, source_signal, tool_name, opts) do
    %{
      execution_kind: execution_kind_for_tool(tool_name),
      name: tool_name,
      args: map_get(enriched_tool_call, "args") || %{},
      meta:
        build_meta(opts, source_signal)
        |> deep_merge(map_get(enriched_tool_call, "meta") || %{}),
      correlation_id: map_get(execution, "correlation_id"),
      cause_id: map_get(execution, "cause_id"),
      execution_id: map_get(execution, "execution_id"),
      run_id: map_get(execution, "run_id"),
      step_id: map_get(execution, "step_id"),
      source_signal: source_signal,
      tool_call: enriched_tool_call
    }
  end

  defp tool_call_field(tool_call, source_execution, field) do
    tool_meta = map_get(tool_call, "meta") || %{}
    map_get(tool_call, field) || map_get(tool_meta, field) || map_get(source_execution, field)
  end

  defp tool_call_correlation_id(tool_call, source_signal) do
    map_get(tool_call, "correlation_id") || ConversationSignal.correlation_id(source_signal)
  end

  defp strategy_envelope(source_signal, opts) do
    mode = normalize_mode(Keyword.get(opts, :mode))
    mode_state = Keyword.get(opts, :mode_state, %{}) |> normalize_map()
    strategy_type = map_get(mode_state, "strategy") || default_strategy_type(mode)
    strategy_opts = Map.delete(mode_state, "strategy")
    correlation_id = ConversationSignal.correlation_id(source_signal)
    intent_meta = normalize_map(Keyword.get(opts, :intent_meta, %{}))
    pipeline_meta = map_get(intent_meta, "pipeline") |> normalize_map()

    run_id = map_get(pipeline_meta, "run_id") || correlation_id || source_signal.id
    step_id = strategy_step_id(run_id, map_get(pipeline_meta, "step_index"))

    meta =
      build_meta(opts, source_signal)
      |> deep_merge(intent_meta)
      |> put_pipeline_runtime_ids(run_id, step_id)

    execution =
      ExecutionLifecycle.execution_metadata(
        %{
          execution_kind: :strategy_run,
          correlation_id: correlation_id,
          cause_id: source_signal.id,
          run_id: run_id,
          step_id: step_id,
          mode: mode,
          meta: meta
        },
        %{"lifecycle_status" => "requested"}
      )

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
       meta: meta,
       correlation_id: correlation_id,
       cause_id: source_signal.id,
       source_signal: source_signal,
       execution_id: map_get(execution, "execution_id"),
       run_id: map_get(execution, "run_id"),
       step_id: map_get(execution, "step_id")
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

  defp put_pipeline_runtime_ids(meta, run_id, step_id) when is_map(meta) do
    pipeline =
      meta
      |> map_get("pipeline")
      |> normalize_map()
      |> Map.put_new("run_id", run_id)
      |> maybe_put("step_id", step_id)

    Map.put(meta, "pipeline", pipeline)
  end

  defp put_pipeline_runtime_ids(meta, _run_id, _step_id), do: meta

  defp source_signal_type(%Jido.Signal{} = signal), do: signal.type
  defp source_signal_type(_signal), do: nil

  defp source_signal_id(%Jido.Signal{} = signal), do: signal.id
  defp source_signal_id(_signal), do: nil

  defp strategy_step_id(run_id, step_index)
       when is_binary(run_id) and run_id != "" and is_integer(step_index) and step_index > 0,
       do: "#{run_id}:strategy:#{step_index}"

  defp strategy_step_id(run_id, step_index)
       when is_binary(run_id) and run_id != "" and is_binary(step_index) do
    case Integer.parse(String.trim(step_index)) do
      {index, ""} when index > 0 -> "#{run_id}:strategy:#{index}"
      _ -> nil
    end
  end

  defp strategy_step_id(run_id, _step_index) when is_binary(run_id) and run_id != "",
    do: "#{run_id}:strategy:1"

  defp strategy_step_id(_run_id, _step_index), do: nil

  defp enrich_tool_call_execution(tool_call, execution)
       when is_map(tool_call) and is_map(execution) do
    meta =
      tool_call
      |> map_get("meta")
      |> normalize_map()
      |> Map.put("execution", execution)
      |> maybe_put("execution_id", map_get(execution, "execution_id"))
      |> maybe_put("run_id", map_get(execution, "run_id"))
      |> maybe_put("step_id", map_get(execution, "step_id"))
      |> maybe_put("mode", map_get(execution, "mode"))

    tool_call
    |> Map.put("meta", meta)
    |> maybe_put("execution_id", map_get(execution, "execution_id"))
    |> maybe_put("run_id", map_get(execution, "run_id"))
    |> maybe_put("step_id", map_get(execution, "step_id"))
  end

  defp enrich_tool_call_execution(tool_call, _execution), do: tool_call

  defp source_execution_metadata(%Jido.Signal{data: data}) when is_map(data) do
    data
    |> map_get("execution")
    |> normalize_map()
  end

  defp source_execution_metadata(_source_signal), do: %{}

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
