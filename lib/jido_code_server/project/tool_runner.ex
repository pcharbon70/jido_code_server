defmodule JidoCodeServer.Project.ToolRunner do
  @moduledoc """
  Unified, policy-gated tool execution path for project runtime.
  """

  alias JidoCodeServer.Config
  alias JidoCodeServer.Project.AssetStore
  alias JidoCodeServer.Project.Policy
  alias JidoCodeServer.Project.ToolCatalog
  alias JidoCodeServer.Telemetry
  alias JidoCodeServer.Types.ToolCall

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(project_ctx, tool_call) when is_map(project_ctx) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, normalized_call} <- normalize_call(tool_call),
         {:ok, spec} <- ToolCatalog.get_tool(project_ctx, normalized_call.name),
         :ok <-
           Policy.authorize_tool(
             project_ctx.policy,
             normalized_call.name,
             normalized_call.args,
             project_ctx
           ),
         :ok <- ensure_capacity(project_ctx),
         :ok <- emit_started(project_ctx, normalized_call, spec),
         {:ok, result} <- execute_within_task(project_ctx, spec, normalized_call) do
      duration_ms = System.monotonic_time(:millisecond) - started_at
      response = success_response(normalized_call, spec, duration_ms, result)
      Telemetry.emit("tool.completed", response)
      {:ok, response}
    else
      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at
        error = error_response(tool_call, duration_ms, reason)
        Telemetry.emit("tool.failed", error)
        {:error, error}
    end
  end

  @spec run_async(map(), map(), keyword()) :: :ok
  def run_async(project_ctx, tool_call, opts \\ []) when is_map(project_ctx) do
    notify = Keyword.get(opts, :notify)

    _ =
      Task.Supervisor.start_child(project_ctx.task_supervisor, fn ->
        result = run(project_ctx, tool_call)

        if is_pid(notify) do
          send(notify, {:tool_result, tool_name(tool_call), result})
        end
      end)

    :ok
  end

  defp execute_within_task(project_ctx, spec, call) do
    timeout_ms = Map.get(project_ctx, :tool_timeout_ms, Config.tool_timeout_ms())

    task =
      Task.Supervisor.async_nolink(project_ctx.task_supervisor, fn ->
        execute_tool(project_ctx, spec, call)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, reason}} ->
        {:error, {:tool_failed, reason}}

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, {:task_exit, reason}}
    end
  end

  defp execute_tool(project_ctx, spec, call) do
    case spec.kind do
      :asset_list ->
        type = fetch_string_arg(call.args, "type")
        {:ok, %{items: AssetStore.list(project_ctx.asset_store, type)}}

      :asset_search ->
        type = fetch_string_arg(call.args, "type")
        query = fetch_string_arg(call.args, "query")
        {:ok, %{items: AssetStore.search(project_ctx.asset_store, type, query)}}

      :asset_get ->
        type = fetch_string_arg(call.args, "type")
        key = fetch_string_arg(call.args, "key")

        case AssetStore.get(project_ctx.asset_store, type, key) do
          {:ok, asset} -> {:ok, %{asset: asset}}
          :error -> {:error, :asset_not_found}
        end

      :command_run ->
        run_asset_tool(project_ctx, :command, spec.asset_name, call)

      :workflow_run ->
        run_asset_tool(project_ctx, :workflow, spec.asset_name, call)

      _other ->
        {:error, :unsupported_tool}
    end
  end

  defp run_asset_tool(project_ctx, type, asset_name, call) do
    case AssetStore.get(project_ctx.asset_store, type, asset_name) do
      {:ok, asset} ->
        {:ok,
         %{
           asset: asset,
           args: call.args,
           mode: :preview,
           note: "Execution bridge to jido_command/jido_workflow is introduced in later phases."
         }}

      :error ->
        {:error, :asset_not_found}
    end
  end

  defp ensure_capacity(project_ctx) do
    max_concurrency = Map.get(project_ctx, :tool_max_concurrency, Config.tool_max_concurrency())
    running = length(Task.Supervisor.children(project_ctx.task_supervisor))

    if running < max_concurrency do
      :ok
    else
      {:error, :max_concurrency_reached}
    end
  end

  defp emit_started(project_ctx, call, spec) do
    Telemetry.emit("tool.started", %{
      project_id: project_ctx.project_id,
      tool: call.name,
      kind: spec.kind,
      args: call.args
    })

    :ok
  end

  defp success_response(call, spec, duration_ms, result) do
    %{
      status: :ok,
      tool: call.name,
      kind: spec.kind,
      duration_ms: duration_ms,
      result: result
    }
  end

  defp error_response(tool_call, duration_ms, reason) do
    %{
      status: :error,
      tool: tool_name(tool_call),
      duration_ms: duration_ms,
      reason: reason
    }
  end

  defp normalize_call(%ToolCall{name: name, args: args, meta: meta}) do
    normalize_call(%{name: name, args: args, meta: meta})
  end

  defp normalize_call(%{name: name} = call) when is_binary(name) do
    args = Map.get(call, :args, %{}) || %{}
    meta = Map.get(call, :meta, %{}) || %{}

    if is_map(args) and is_map(meta) do
      {:ok, %{name: name, args: args, meta: meta}}
    else
      {:error, :invalid_tool_call}
    end
  end

  defp normalize_call(_invalid), do: {:error, :invalid_tool_call}

  defp tool_name(%ToolCall{name: name}) when is_binary(name), do: name
  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(_), do: "unknown"

  defp fetch_string_arg(args, key) when is_map(args) do
    value =
      Enum.find_value(args, fn
        {^key, val} when is_binary(val) ->
          val

        {atom_key, val} when is_atom(atom_key) and is_binary(val) ->
          if Atom.to_string(atom_key) == key, do: val, else: nil

        _ ->
          nil
      end)

    if is_binary(value), do: value, else: ""
  end
end
