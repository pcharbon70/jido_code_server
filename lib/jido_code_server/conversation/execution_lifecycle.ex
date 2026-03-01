defmodule Jido.Code.Server.Conversation.ExecutionLifecycle do
  @moduledoc false

  @lifecycle_statuses MapSet.new([
                        "requested",
                        "started",
                        "progress",
                        "completed",
                        "failed",
                        "canceled"
                      ])

  @signal_statuses %{
    "conversation.llm.requested" => "requested",
    "conversation.assistant.delta" => "progress",
    "conversation.assistant.message" => "progress",
    "conversation.llm.completed" => "completed",
    "conversation.llm.failed" => "failed",
    "conversation.tool.requested" => "requested",
    "conversation.tool.completed" => "completed",
    "conversation.tool.failed" => "failed",
    "conversation.tool.cancelled" => "canceled"
  }

  @status_aliases %{
    "ok" => "completed",
    "success" => "completed",
    "complete" => "completed",
    "error" => "failed",
    "cancelled" => "canceled",
    "cancel" => "canceled",
    "in_progress" => "progress",
    "running" => "progress"
  }

  @spec normalize_status(term()) :: String.t() | nil
  def normalize_status(status) when is_atom(status) do
    status
    |> Atom.to_string()
    |> normalize_status()
  end

  def normalize_status(status) when is_binary(status) do
    normalized =
      status
      |> String.trim()
      |> String.downcase()

    cond do
      normalized == "" ->
        nil

      Map.has_key?(@status_aliases, normalized) ->
        Map.fetch!(@status_aliases, normalized)

      MapSet.member?(@lifecycle_statuses, normalized) ->
        normalized

      true ->
        nil
    end
  end

  def normalize_status(_status), do: nil

  @spec status_for_signal_type(String.t()) :: String.t() | nil
  def status_for_signal_type(type) when is_binary(type), do: Map.get(@signal_statuses, type)
  def status_for_signal_type(_type), do: nil

  @spec execution_kind_for_tool_name(term()) :: String.t()
  def execution_kind_for_tool_name(name) when is_binary(name) do
    cond do
      String.starts_with?(name, "command.run.") -> "command_run"
      String.starts_with?(name, "workflow.run.") -> "workflow_run"
      String.starts_with?(name, "agent.spawn.") -> "subagent_spawn"
      true -> "tool_run"
    end
  end

  def execution_kind_for_tool_name(_name), do: "tool_run"

  @spec execution_kind_label(term()) :: String.t()
  def execution_kind_label(nil), do: "unknown"
  def execution_kind_label(kind) when is_atom(kind), do: Atom.to_string(kind)

  def execution_kind_label(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  def execution_kind_label(_kind), do: "unknown"

  @spec execution_metadata(map(), map()) :: map()
  def execution_metadata(envelope, overrides \\ %{})
      when is_map(envelope) and is_map(overrides) do
    normalized_envelope = normalize_string_key_map(envelope)
    normalized_overrides = normalize_string_key_map(overrides)
    meta = map_get(normalized_envelope, "meta") |> normalize_map()
    pipeline = map_get(meta, "pipeline") |> normalize_map()

    raw_execution_kind = map_get(normalized_envelope, "execution_kind")
    inferred_execution_kind = infer_execution_kind(raw_execution_kind, normalized_envelope)
    execution_kind = execution_kind_label(inferred_execution_kind)
    correlation_id = normalize_string(map_get(normalized_envelope, "correlation_id"))
    cause_id = normalize_string(map_get(normalized_envelope, "cause_id"))

    run_id =
      first_present([
        map_get(normalized_envelope, "run_id"),
        map_get(pipeline, "run_id"),
        correlation_id,
        cause_id
      ])

    step_id =
      first_present([
        map_get(normalized_envelope, "step_id"),
        map_get(pipeline, "step_id"),
        derive_step_id(execution_kind, run_id, map_get(pipeline, "step_index"))
      ])

    mode =
      map_get(normalized_envelope, "mode")
      |> normalize_mode()
      |> default_value("coding")

    execution_id =
      first_present([
        map_get(normalized_envelope, "execution_id"),
        derive_execution_id(execution_kind, run_id, step_id, correlation_id, cause_id),
        "execution:unknown"
      ])

    base = %{
      "execution_id" => execution_id,
      "execution_kind" => execution_kind,
      "correlation_id" => correlation_id,
      "cause_id" => cause_id,
      "step_id" => step_id,
      "run_id" => run_id,
      "mode" => mode
    }

    override_status =
      map_get(normalized_overrides, "lifecycle_status")
      |> normalize_status()

    envelope_status =
      map_get(normalized_envelope, "lifecycle_status")
      |> normalize_status()

    status = override_status || envelope_status

    normalized_overrides =
      normalized_overrides
      |> Map.drop(["lifecycle_status"])
      |> drop_nil_values()

    base
    |> maybe_put("lifecycle_status", status)
    |> Map.merge(normalized_overrides)
    |> drop_nil_values()
  end

  defp derive_step_id(_execution_kind, run_id, _step_index)
       when not is_binary(run_id) or run_id == "",
       do: nil

  defp derive_step_id(execution_kind, run_id, step_index) do
    case normalize_step_index(step_index) do
      index when is_integer(index) and index > 0 ->
        case execution_kind do
          "strategy_run" -> "#{run_id}:strategy:#{index}"
          _other -> nil
        end

      _other ->
        case execution_kind do
          "strategy_run" -> "#{run_id}:strategy:1"
          _other -> nil
        end
    end
  end

  defp infer_execution_kind(raw_kind, envelope) do
    case execution_kind_label(raw_kind) do
      "unknown" ->
        if(strategy_envelope?(envelope), do: "strategy_run", else: "unknown")

      normalized ->
        normalized
    end
  end

  defp strategy_envelope?(envelope) when is_map(envelope) do
    case map_get(envelope, "strategy_type") do
      value when is_binary(value) and value != "" ->
        true

      _other ->
        case map_get(envelope, "name") do
          value when is_binary(value) ->
            String.ends_with?(value, ".strategy")

          _ ->
            false
        end
    end
  end

  defp strategy_envelope?(_envelope), do: false

  defp derive_execution_id(execution_kind, run_id, step_id, correlation_id, cause_id) do
    tail =
      first_present([
        step_id,
        run_id,
        correlation_id,
        cause_id,
        "unknown"
      ])

    "execution:#{execution_kind}:#{tail}"
  end

  defp normalize_step_index(index) when is_integer(index), do: index

  defp normalize_step_index(index) when is_binary(index) do
    case Integer.parse(String.trim(index)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_step_index(_index), do: nil

  defp normalize_mode(mode) when is_atom(mode), do: Atom.to_string(mode)

  defp normalize_mode(mode) when is_binary(mode) do
    case String.trim(mode) do
      "" -> nil
      value -> String.downcase(value)
    end
  end

  defp normalize_mode(_mode), do: nil

  defp normalize_string(nil), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(value) when is_atom(value), do: normalize_string(Atom.to_string(value))
  defp normalize_string(_value), do: nil

  defp first_present(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case normalize_string(value) do
        nil -> nil
        normalized -> normalized
      end
    end)
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, to_existing_atom(key))
  end

  defp map_get(_map, _key), do: nil

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp drop_nil_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_value(nil, fallback), do: fallback
  defp default_value(value, _fallback), do: value

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

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
