defmodule JidoCodeServer.Telemetry do
  @moduledoc """
  Telemetry emission facade with lightweight in-memory diagnostics counters.
  """

  @table __MODULE__
  @prefix [:jido_code_server]
  @max_recent_errors 25
  @known_segments %{
    "project" => :project,
    "conversation" => :conversation,
    "tool" => :tool,
    "llm" => :llm,
    "assets" => :assets,
    "started" => :started,
    "stopped" => :stopped,
    "loaded" => :loaded,
    "reloaded" => :reloaded,
    "failed" => :failed,
    "completed" => :completed,
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

    metadata =
      payload
      |> Map.put_new(:event_name, name)
      |> Map.put_new(:emitted_at, DateTime.utc_now())

    :telemetry.execute(event_name(name), measurements(payload), metadata)
    increment_counter(normalize_project_id(payload), name)
    maybe_track_error(normalize_project_id(payload), name, payload)
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

    %{
      project_id: if(project_key == :global, do: nil, else: project_key),
      total_events: counters |> Map.values() |> Enum.sum(),
      event_counts: counters,
      recent_errors: recent_errors
    }
  end

  @spec reset() :: :ok
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end
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

  defp maybe_track_error(project_key, name, payload) do
    if error_event?(name, payload) do
      entry = %{
        event: name,
        reason: Map.get(payload, :reason, Map.get(payload, "reason")),
        error: Map.get(payload, :error, Map.get(payload, "error")),
        at: DateTime.utc_now()
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

  defp error_event?(name, payload) do
    String.ends_with?(name, ".failed") or
      Map.has_key?(payload, :error) or
      Map.has_key?(payload, "error")
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
end
