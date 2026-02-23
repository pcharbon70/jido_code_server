defmodule Jido.Code.Server.Telemetry do
  @moduledoc """
  Telemetry emission facade with lightweight in-memory diagnostics counters.
  """

  alias Jido.Code.Server.AlertRouter

  @table __MODULE__
  @prefix [:jido_code_server]
  @max_recent_errors 25
  @max_recent_events 200
  @redacted "[REDACTED]"
  @sensitive_key_fragments [
    "token",
    "secret",
    "password",
    "api_key",
    "apikey",
    "authorization",
    "credential",
    "private_key",
    "access_key"
  ]
  @known_segments %{
    "project" => :project,
    "conversation" => :conversation,
    "tool" => :tool,
    "llm" => :llm,
    "policy" => :policy,
    "security" => :security,
    "assets" => :assets,
    "started" => :started,
    "stopped" => :stopped,
    "loaded" => :loaded,
    "reloaded" => :reloaded,
    "allowed" => :allowed,
    "denied" => :denied,
    "failed" => :failed,
    "completed" => :completed,
    "timeout" => :timeout,
    "delta" => :delta,
    "event_ingested" => :event_ingested,
    "watcher_started" => :watcher_started,
    "watcher_stopped" => :watcher_stopped,
    "watcher_reload_completed" => :watcher_reload_completed,
    "watcher_reload_failed" => :watcher_reload_failed
  }

  @spec emit(String.t(), map()) :: :ok
  def emit(name, payload) when is_binary(name) and is_map(payload) do
    ensure_table()
    sanitized_payload = sanitize_payload(payload)
    project_key = normalize_project_id(sanitized_payload)

    metadata =
      sanitized_payload
      |> Map.put_new(:event_name, name)
      |> Map.put_new(:emitted_at, DateTime.utc_now())

    :telemetry.execute(event_name(name), measurements(sanitized_payload), metadata)
    increment_counter(project_key, name)
    maybe_track_event(project_key, name, sanitized_payload, metadata.emitted_at)
    maybe_track_error(project_key, name, sanitized_payload, metadata.emitted_at)
    AlertRouter.maybe_dispatch(name, sanitized_payload, metadata)
    :ok
  rescue
    _error ->
      :ok
  end

  @spec snapshot(String.t() | nil) :: map()
  def snapshot(project_id \\ nil) do
    ensure_table()
    project_key = normalize_project_key(project_id)

    counters =
      @table
      |> :ets.tab2list()
      |> Enum.reduce(%{}, fn
        {{:counter, ^project_key, name}, count}, acc ->
          Map.put(acc, name, count)

        _entry, acc ->
          acc
      end)

    recent_errors =
      case :ets.lookup(@table, {:recent_errors, project_key}) do
        [{{:recent_errors, ^project_key}, errors}] when is_list(errors) -> errors
        _ -> []
      end

    recent_events =
      case :ets.lookup(@table, {:recent_events, project_key}) do
        [{{:recent_events, ^project_key}, events}] when is_list(events) -> events
        _ -> []
      end

    %{
      project_id: if(project_key == :global, do: nil, else: project_key),
      total_events: counters |> Map.values() |> Enum.sum(),
      event_counts: counters,
      recent_errors: recent_errors,
      recent_events: recent_events
    }
  end

  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end
  rescue
    _error ->
      :ok
  end

  defp measurements(payload) do
    payload
    |> Map.get(:duration_ms, Map.get(payload, "duration_ms"))
    |> case do
      value when is_integer(value) and value >= 0 ->
        %{count: 1, duration_ms: value}

      _ ->
        %{count: 1}
    end
  end

  defp event_name(name) do
    segments =
      name
      |> String.split(".", trim: true)
      |> Enum.map(&segment_to_atom/1)

    @prefix ++ segments
  end

  defp segment_to_atom(segment) do
    Map.get(@known_segments, segment, :custom)
  end

  defp normalize_project_id(payload) do
    payload
    |> Map.get(:project_id, Map.get(payload, "project_id"))
    |> normalize_project_key()
  end

  defp normalize_project_key(project_id) when is_binary(project_id) and project_id != "",
    do: project_id

  defp normalize_project_key(_project_id), do: :global

  defp increment_counter(project_key, name) do
    key = {:counter, project_key, name}

    try do
      :ets.update_counter(@table, key, {2, 1}, {key, 0})
      :ok
    rescue
      _ -> :ok
    end
  end

  defp maybe_track_error(project_key, name, payload, emitted_at) do
    if error_event?(name, payload) do
      entry = %{
        event: name,
        conversation_id: extract_conversation_id(payload),
        correlation_id: extract_correlation_id(payload),
        reason: Map.get(payload, :reason, Map.get(payload, "reason")),
        error: Map.get(payload, :error, Map.get(payload, "error")),
        at: emitted_at
      }

      errors =
        case :ets.lookup(@table, {:recent_errors, project_key}) do
          [{{:recent_errors, ^project_key}, existing}] when is_list(existing) -> existing
          _ -> []
        end

      :ets.insert(
        @table,
        {{:recent_errors, project_key}, [entry | errors] |> Enum.take(@max_recent_errors)}
      )
    end
  rescue
    _ -> :ok
  end

  defp maybe_track_event(project_key, name, payload, emitted_at) do
    entry = %{
      event: name,
      event_type: Map.get(payload, :event_type, Map.get(payload, "event_type")),
      project_id: Map.get(payload, :project_id, Map.get(payload, "project_id")),
      conversation_id: extract_conversation_id(payload),
      correlation_id: extract_correlation_id(payload),
      tool: Map.get(payload, :tool, Map.get(payload, "tool")),
      reason: Map.get(payload, :reason, Map.get(payload, "reason")),
      error: Map.get(payload, :error, Map.get(payload, "error")),
      at: emitted_at
    }

    events =
      case :ets.lookup(@table, {:recent_events, project_key}) do
        [{{:recent_events, ^project_key}, existing}] when is_list(existing) -> existing
        _ -> []
      end

    :ets.insert(
      @table,
      {{:recent_events, project_key}, [entry | events] |> Enum.take(@max_recent_events)}
    )
  rescue
    _ -> :ok
  end

  defp error_event?(name, payload) do
    String.ends_with?(name, ".failed") or
      Map.has_key?(payload, :error) or
      Map.has_key?(payload, "error")
  end

  defp extract_conversation_id(payload) when is_map(payload) do
    Map.get(payload, :conversation_id) || Map.get(payload, "conversation_id")
  end

  defp extract_correlation_id(payload) when is_map(payload) do
    Map.get(payload, :correlation_id) || Map.get(payload, "correlation_id")
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp sanitize_payload(payload) when is_map(payload) do
    sanitize_value(payload)
  end

  defp sanitize_value(value) when is_binary(value), do: redact_string(value)

  defp sanitize_value(value) when is_list(value) do
    Enum.map(value, &sanitize_value/1)
  end

  defp sanitize_value(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&sanitize_value/1)
    |> List.to_tuple()
  end

  defp sanitize_value(%_{} = struct), do: struct

  defp sanitize_value(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      sanitized =
        if sensitive_key?(key) do
          @redacted
        else
          sanitize_value(nested)
        end

      Map.put(acc, key, sanitized)
    end)
  end

  defp sanitize_value(other), do: other

  defp sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))

  defp sensitive_key?(key) when is_binary(key) do
    normalized =
      key
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")

    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp sensitive_key?(_), do: false

  defp redact_string(value) do
    value
    |> redact_bearer_tokens()
    |> redact_key_value_tokens()
    |> redact_provider_tokens()
  end

  defp redact_bearer_tokens(value) do
    Regex.replace(
      ~r/\b(Bearer)\s+[A-Za-z0-9\-\._~\+\/]+=*/i,
      value,
      "\\1 #{@redacted}"
    )
  end

  defp redact_key_value_tokens(value) do
    Regex.replace(
      ~r/((?:api[_-]?key|token|secret|password|authorization)\s*[:=]\s*)([^\s,;]+)/i,
      value,
      "\\1#{@redacted}"
    )
  end

  defp redact_provider_tokens(value) do
    value
    |> then(&Regex.replace(~r/\bghp_[A-Za-z0-9]{20,}\b/, &1, @redacted))
    |> then(&Regex.replace(~r/\bgithub_pat_[A-Za-z0-9_]{20,}\b/, &1, @redacted))
    |> then(&Regex.replace(~r/\bsk-[A-Za-z0-9]{16,}\b/, &1, @redacted))
    |> then(&Regex.replace(~r/\bAKIA[0-9A-Z]{16}\b/, &1, @redacted))
    |> then(&Regex.replace(~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/, &1, @redacted))
  end
end
