defmodule Jido.Code.Server.Conversation.ToolBridge do
  @moduledoc """
  Bridge between conversation tool requests and project tool execution.
  """

  alias Jido.Code.Server.Conversation.ExecutionLifecycle
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.ExecutionRunner
  alias Jido.Code.Server.Types.ToolCall

  @task_table __MODULE__.PendingTasks

  @spec handle_tool_requested(map(), String.t(), map()) :: {:ok, [map()]}
  def handle_tool_requested(project_ctx, conversation_id, tool_call)
      when is_map(project_ctx) and is_binary(conversation_id) and is_map(tool_call) do
    case ToolCall.from_map(tool_call) do
      {:ok, normalized_call} ->
        call_with_meta = call_with_meta(normalized_call, conversation_id, project_ctx)
        run_tool_request(project_ctx, conversation_id, call_with_meta)

      {:error, reason} ->
        {:ok, [invalid_tool_call_event(reason, tool_call)]}
    end
  end

  def handle_tool_requested(_project_ctx, _conversation_id, _tool_call) do
    {:ok, [invalid_tool_call_event(:invalid_tool_call, %{})]}
  end

  @spec handle_tool_result(map(), String.t(), pid(), map(), {:ok, map()} | {:error, term()}) ::
          {:ok, [map()]}
  def handle_tool_result(project_ctx, conversation_id, task_pid, _tool_call, result)
      when is_map(project_ctx) and is_binary(conversation_id) and is_pid(task_pid) do
    project_id = project_id_from_ctx(project_ctx)

    case pop_pending_task(project_id, conversation_id, task_pid) do
      {:ok, call} ->
        case result do
          {:ok, payload} ->
            {:ok, [tool_completed_event(call, payload)]}

          {:error, reason} ->
            {:ok, [tool_failed_event(call, reason)]}
        end

      :error ->
        # Ignore stale task results that were already cancelled or consumed.
        {:ok, []}
    end
  end

  def handle_tool_result(_project_ctx, _conversation_id, _task_pid, _tool_call, _result) do
    {:ok, []}
  end

  @spec cancel_pending(map(), String.t()) :: :ok
  def cancel_pending(project_ctx, conversation_id)
      when is_map(project_ctx) and is_binary(conversation_id) do
    project_id = project_id_from_ctx(project_ctx)

    list_pending_tasks(project_id, conversation_id)
    |> Enum.each(fn {task_pid, call} ->
      _ = ExecutionRunner.cancel_task(project_ctx, task_pid, call)

      delete_pending_task(project_id, conversation_id, task_pid)
    end)

    :ok
  end

  def cancel_pending(_project_ctx, _conversation_id), do: :ok

  defp call_with_meta(%ToolCall{} = call, conversation_id, project_ctx) do
    correlation_id = Map.get(project_ctx, :correlation_id)

    meta =
      call.meta
      |> Map.put("conversation_id", conversation_id)
      |> maybe_put_correlation(correlation_id)

    %{name: call.name, args: call.args, meta: meta}
  end

  defp run_tool_request(project_ctx, conversation_id, call_with_meta) do
    if async_request?(call_with_meta) and is_pid(Map.get(project_ctx, :conversation_server)) do
      run_tool_request_async(project_ctx, conversation_id, call_with_meta)
    else
      run_tool_request_sync(project_ctx, call_with_meta)
    end
  end

  defp run_tool_request_sync(project_ctx, call_with_meta) do
    case ExecutionRunner.run(project_ctx, call_with_meta) do
      {:ok, result} ->
        {:ok, [tool_completed_event(call_with_meta, result)]}

      {:error, reason} ->
        {:ok, [tool_failed_event(call_with_meta, reason)]}
    end
  end

  defp run_tool_request_async(project_ctx, conversation_id, call_with_meta) do
    notify = Map.get(project_ctx, :conversation_server)

    case ExecutionRunner.run_async(project_ctx, call_with_meta, notify: notify) do
      {:ok, task_pid} ->
        track_pending_task(
          project_id_from_ctx(project_ctx),
          conversation_id,
          task_pid,
          call_with_meta,
          notify
        )

        {:ok, []}

      {:error, reason} ->
        {:ok, [tool_failed_event(call_with_meta, reason)]}
    end
  end

  defp async_request?(%{meta: meta}) when is_map(meta) do
    run_mode = Map.get(meta, "run_mode") || Map.get(meta, :run_mode)
    async_flag = Map.get(meta, "async") || Map.get(meta, :async)

    run_mode == "async" or async_flag == true
  end

  defp tool_completed_event(call, result) do
    event_meta = event_meta(call.meta)
    execution = execution_from_call(call, "completed")

    %{
      type: "conversation.tool.completed",
      source: event_source(call.meta),
      meta: event_meta,
      data: %{
        "name" => call.name,
        "args" => call.args,
        "meta" => call.meta,
        "result" => result,
        "execution" => execution
      }
    }
  end

  defp tool_failed_event(call, reason) do
    event_meta = event_meta(call.meta)
    lifecycle_status = failure_lifecycle_status(reason)
    execution = execution_from_call(call, lifecycle_status)

    %{
      type: "conversation.tool.failed",
      source: event_source(call.meta),
      meta: event_meta,
      data: %{
        "name" => call.name,
        "args" => call.args,
        "meta" => call.meta,
        "reason" => reason,
        "execution" => execution
      }
    }
  end

  defp invalid_tool_call_event(reason, raw_tool_call) do
    raw_meta = raw_tool_call["meta"] || raw_tool_call[:meta] || %{}
    meta = event_meta(raw_meta)

    %{
      type: "conversation.tool.failed",
      source: event_source(raw_meta),
      meta: meta,
      data: %{
        "name" => "unknown",
        "args" => %{},
        "reason" => reason,
        "raw_tool_call" => raw_tool_call,
        "execution" =>
          ExecutionLifecycle.execution_metadata(
            %{
              execution_kind: "tool_run",
              correlation_id: map_get(meta, "correlation_id")
            },
            %{"lifecycle_status" => "failed"}
          )
      }
    }
  end

  defp execution_from_call(call, lifecycle_status) when is_map(call) do
    meta = normalize_string_map(map_get(call, :meta) || map_get(call, "meta") || %{})
    embedded_execution = map_get(meta, "execution") |> normalize_string_map()
    execution_kind = execution_kind_for_call(call, embedded_execution)

    ExecutionLifecycle.execution_metadata(
      %{
        execution_kind: execution_kind,
        execution_id:
          map_get(embedded_execution, "execution_id") || map_get(meta, "execution_id"),
        correlation_id: map_get(meta, "correlation_id"),
        cause_id: map_get(embedded_execution, "cause_id") || map_get(meta, "cause_id"),
        run_id: map_get(embedded_execution, "run_id") || map_get(meta, "run_id"),
        step_id: map_get(embedded_execution, "step_id") || map_get(meta, "step_id"),
        mode: map_get(embedded_execution, "mode") || map_get(meta, "mode"),
        meta: %{"pipeline" => %{}}
      },
      %{"lifecycle_status" => lifecycle_status}
    )
  end

  defp execution_from_call(_call, lifecycle_status) do
    ExecutionLifecycle.execution_metadata(
      %{
        execution_kind: "tool_run"
      },
      %{"lifecycle_status" => lifecycle_status}
    )
  end

  defp execution_kind_for_call(call, embedded_execution) do
    map_get(embedded_execution, "execution_kind") ||
      call
      |> map_get(:name)
      |> ExecutionLifecycle.execution_kind_for_tool_name()
  end

  defp failure_lifecycle_status(reason) do
    reason
    |> normalize_failure_reason()
    |> case do
      "conversation_cancelled" -> "canceled"
      _other -> "failed"
    end
  end

  defp normalize_failure_reason(reason) when is_binary(reason), do: String.trim(reason)
  defp normalize_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp normalize_failure_reason(reason) when is_map(reason) do
    map_get(normalize_string_map(reason), "reason") || inspect(reason)
  end

  defp normalize_failure_reason(reason), do: inspect(reason)

  defp maybe_put_correlation(meta, correlation_id) when is_binary(correlation_id) do
    case Correlation.fetch(meta) do
      {:ok, _existing} -> meta
      :error -> Correlation.put(meta, correlation_id)
    end
  end

  defp maybe_put_correlation(meta, _correlation_id), do: meta

  defp event_meta(meta) when is_map(meta) do
    case Correlation.fetch(meta) do
      {:ok, correlation_id} -> Correlation.put(%{}, correlation_id)
      :error -> %{}
    end
  end

  defp event_meta(_meta), do: %{}

  defp event_source(meta) when is_map(meta) do
    case Map.get(meta, "conversation_id") || Map.get(meta, :conversation_id) do
      conversation_id when is_binary(conversation_id) and conversation_id != "" ->
        "/conversation/#{conversation_id}"

      _ ->
        "/jido/code/server/conversation"
    end
  end

  defp event_source(_meta), do: "/jido/code/server/conversation"

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

  defp map_get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp map_get(_map, _key), do: nil

  defp project_id_from_ctx(project_ctx) when is_map(project_ctx) do
    Map.get(project_ctx, :project_id) || "global"
  end

  defp track_pending_task(project_id, conversation_id, task_pid, call, heir_pid)
       when is_binary(project_id) and is_binary(conversation_id) and is_pid(task_pid) and
              is_map(call) do
    ensure_task_table(heir_pid)
    :ets.insert(@task_table, {{project_id, conversation_id, task_pid}, call})
    :ok
  rescue
    _error ->
      :ok
  end

  defp list_pending_tasks(project_id, conversation_id)
       when is_binary(project_id) and is_binary(conversation_id) do
    ensure_task_table()

    @task_table
    |> :ets.match_object({{project_id, conversation_id, :"$1"}, :"$2"})
    |> Enum.map(fn {{^project_id, ^conversation_id, task_pid}, call} -> {task_pid, call} end)
  rescue
    _error ->
      []
  end

  defp pop_pending_task(project_id, conversation_id, task_pid)
       when is_binary(project_id) and is_binary(conversation_id) and is_pid(task_pid) do
    ensure_task_table()
    key = {project_id, conversation_id, task_pid}

    case :ets.lookup(@task_table, key) do
      [{^key, call}] ->
        :ets.delete(@task_table, key)
        {:ok, call}

      _ ->
        :error
    end
  rescue
    _error ->
      :error
  end

  defp delete_pending_task(project_id, conversation_id, task_pid)
       when is_binary(project_id) and is_binary(conversation_id) and is_pid(task_pid) do
    ensure_task_table()
    :ets.delete(@task_table, {project_id, conversation_id, task_pid})
    :ok
  rescue
    _error ->
      :ok
  end

  defp ensure_task_table(heir_pid \\ nil)

  defp ensure_task_table(heir_pid) do
    case :ets.whereis(@task_table) do
      :undefined ->
        opts = [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ]

        opts =
          if is_pid(heir_pid) do
            [{:heir, heir_pid, :tool_bridge_pending_tasks} | opts]
          else
            opts
          end

        :ets.new(@task_table, opts)

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
