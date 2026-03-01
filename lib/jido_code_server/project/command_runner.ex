defmodule Jido.Code.Server.Project.CommandRunner do
  @moduledoc """
  Executes `command.run.*` calls once ExecutionRunner has validated and authorized
  the invocation.
  """

  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Types.ToolCall

  @spec execute(map(), map(), map() | ToolCall.t()) :: {:ok, map()} | {:error, term()}
  def execute(project_ctx, %{kind: :command_run, asset_name: asset_name}, call)
      when is_binary(asset_name) do
    case AssetStore.get(project_ctx.asset_store, :command, asset_name) do
      {:ok, asset} ->
        maybe_simulate_delay(call)
        execute_command_asset_tool(project_ctx, asset, call)

      :error ->
        {:error, :asset_not_found}
    end
  end

  def execute(_project_ctx, _spec, _call), do: {:error, :unsupported_tool}

  defp execute_command_asset_tool(project_ctx, asset, call) do
    with {:ok, definition} <- parse_command_definition(asset),
         {:ok, execution_ctx} <- command_execution_context(project_ctx, call),
         {:ok, execution} <-
           execute_command_definition(
             definition,
             command_params_from_call(call_args(call)),
             execution_ctx
           ) do
      {:ok,
       %{
         asset: asset,
         args: call_args(call),
         mode: :executed,
         runtime: :jido_command,
         command: definition.name,
         execution: execution
       }}
    else
      {:error, {:invalid_command_definition, reason}} ->
        {:ok,
         preview_asset_tool_result(
           asset,
           call_args(call),
           "Command definition is invalid for jido_command runtime; running in preview compatibility mode.",
           reason
         )}

      {:error, {:invalid_project_context, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:command_execution_failed, reason}}
    end
  end

  defp parse_command_definition(%{body: body, path: path})
       when is_binary(body) and is_binary(path) do
    case parse_command_frontmatter(body, path) do
      {:ok, definition} -> {:ok, definition}
      {:error, reason} -> {:error, {:invalid_command_definition, reason}}
    end
  end

  defp parse_command_definition(_asset),
    do: {:error, {:invalid_command_definition, :invalid_asset}}

  defp command_params_from_call(args) when is_map(args) do
    case map_get_value(args, "params") do
      params when is_map(params) ->
        params

      _other ->
        Map.drop(args, ["params", :params, "simulate_delay_ms", :simulate_delay_ms, "env", :env])
    end
  end

  defp command_execution_context(project_ctx, call) do
    case Map.get(project_ctx, :root_path) do
      root_path when is_binary(root_path) and root_path != "" ->
        context =
          %{
            project_id: Map.get(project_ctx, :project_id),
            conversation_id: conversation_id_from_call(call),
            correlation_id: correlation_id_from_call(call),
            project_root: root_path,
            invocation_id: command_invocation_id(call),
            bus: :jido_code_bus,
            tool_timeout_ms: Map.get(project_ctx, :tool_timeout_ms)
          }
          |> maybe_put_command_executor(Map.get(project_ctx, :command_executor))
          |> maybe_put_task_owner_pid(Map.get(project_ctx, :task_owner_pid))

        {:ok, context}

      _missing ->
        {:error, {:invalid_project_context, :missing_root_path}}
    end
  end

  defp maybe_put_command_executor(context, executor_module)
       when is_atom(executor_module) and not is_nil(executor_module) do
    Map.put(context, :command_executor, executor_module)
  end

  defp maybe_put_command_executor(context, _executor_module), do: context

  defp maybe_put_task_owner_pid(context, task_owner_pid) when is_pid(task_owner_pid) do
    Map.put(context, :task_owner_pid, task_owner_pid)
  end

  defp maybe_put_task_owner_pid(context, _task_owner_pid), do: context

  defp command_invocation_id(call) do
    case correlation_id_from_call(call) do
      correlation_id when is_binary(correlation_id) and correlation_id != "" ->
        correlation_id

      _other ->
        "cmd-#{System.unique_integer([:positive, :monotonic])}"
    end
  end

  defp preview_asset_tool_result(asset, args, note, reason) when is_binary(note) do
    base = %{
      asset: asset,
      args: args,
      mode: :preview,
      note: note
    }

    if is_nil(reason), do: base, else: Map.put(base, :reason, reason)
  end

  defp parse_command_frontmatter(body, path) when is_binary(body) and is_binary(path) do
    parser_module = JidoCommand.Extensibility.CommandFrontmatter

    case Code.ensure_loaded(parser_module) do
      {:module, _loaded} ->
        if function_exported?(parser_module, :parse_string, 2) do
          parser_module.parse_string(body, path)
        else
          {:error, :command_frontmatter_unavailable}
        end

      _other ->
        {:error, :command_frontmatter_unavailable}
    end
  end

  defp execute_command_definition(definition, params, context)
       when is_map(params) and is_map(context) do
    runtime_module = JidoCommand.Extensibility.CommandRuntime

    case Code.ensure_loaded(runtime_module) do
      {:module, _loaded} ->
        if function_exported?(runtime_module, :execute, 3) do
          runtime_module.execute(definition, params, context)
        else
          {:error, :command_runtime_unavailable}
        end

      _other ->
        {:error, :command_runtime_unavailable}
    end
  end

  defp maybe_simulate_delay(call) do
    case simulate_delay_ms(call) do
      delay when is_integer(delay) and delay > 0 -> Process.sleep(delay)
      _ -> :ok
    end
  end

  defp simulate_delay_ms(call) do
    delay =
      call_args(call)
      |> Map.to_list()
      |> Enum.find_value(fn
        {"simulate_delay_ms", value} when is_integer(value) -> value
        {:simulate_delay_ms, value} when is_integer(value) -> value
        _ -> nil
      end)

    if is_integer(delay) and delay > 0, do: min(delay, 5_000), else: 0
  end

  defp conversation_id_from_call(tool_call) do
    meta = call_meta(tool_call)
    Map.get(meta, :conversation_id) || Map.get(meta, "conversation_id")
  end

  defp correlation_id_from_call(tool_call) do
    case Correlation.fetch(call_meta(tool_call)) do
      {:ok, correlation_id} -> correlation_id
      :error -> nil
    end
  end

  defp call_args(%ToolCall{args: args}) when is_map(args), do: args
  defp call_args(%{args: args}) when is_map(args), do: args
  defp call_args(%{"args" => args}) when is_map(args), do: args
  defp call_args(_), do: %{}

  defp call_meta(%ToolCall{meta: meta}) when is_map(meta), do: meta
  defp call_meta(%{meta: meta}) when is_map(meta), do: meta
  defp call_meta(%{"meta" => meta}) when is_map(meta), do: meta
  defp call_meta(_), do: %{}

  defp map_get_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        find_atom_key_value(map, key)
    end
  end

  defp find_atom_key_value(map, key) when is_map(map) and is_binary(key) do
    Enum.find_value(map, fn
      {atom_key, value} when is_atom(atom_key) ->
        if Atom.to_string(atom_key) == key, do: value

      _other ->
        nil
    end)
  end
end
