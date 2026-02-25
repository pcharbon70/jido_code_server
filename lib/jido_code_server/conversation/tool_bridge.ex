defmodule Jido.Code.Server.Conversation.ToolBridge do
  @moduledoc """
  Bridge between conversation tool requests and project tool execution.
  """

  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.ToolRunner
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
      _ = ToolRunner.cancel_task(project_ctx, task_pid, call)

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
    case ToolRunner.run(project_ctx, call_with_meta) do
      {:ok, result} ->
        {:ok, [tool_completed_event(call_with_meta, result)]}

      {:error, reason} ->
        {:ok, [tool_failed_event(call_with_meta, reason)]}
    end
  end

  defp run_tool_request_async(project_ctx, conversation_id, call_with_meta) do
    notify = Map.get(project_ctx, :conversation_server)

    case ToolRunner.run_async(project_ctx, call_with_meta, notify: notify) do
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

    %{
      type: "tool.completed",
      meta: event_meta,
      data: %{
        "name" => call.name,
        "args" => call.args,
        "meta" => call.meta,
        "result" => result
      }
    }
  end

  defp tool_failed_event(call, reason) do
    event_meta = event_meta(call.meta)

    %{
      type: "tool.failed",
      meta: event_meta,
      data: %{
        "name" => call.name,
        "args" => call.args,
        "meta" => call.meta,
        "reason" => reason
      }
    }
  end

  defp invalid_tool_call_event(reason, raw_tool_call) do
    meta = event_meta(raw_tool_call["meta"] || raw_tool_call[:meta] || %{})

    %{
      type: "tool.failed",
      meta: meta,
      data: %{
        "name" => "unknown",
        "args" => %{},
        "reason" => reason,
        "raw_tool_call" => raw_tool_call
      }
    }
  end

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
end
