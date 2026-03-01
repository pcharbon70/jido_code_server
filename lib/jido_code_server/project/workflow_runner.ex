defmodule Jido.Code.Server.Project.WorkflowRunner do
  @moduledoc """
  Executes `workflow.run.*` calls once ExecutionRunner has validated and
  authorized the invocation.
  """

  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Types.ToolCall

  @spec execute(map(), map(), map() | ToolCall.t()) :: {:ok, map()} | {:error, term()}
  def execute(project_ctx, %{kind: :workflow_run, asset_name: asset_name}, call)
      when is_binary(asset_name) do
    case AssetStore.get(project_ctx.asset_store, :workflow, asset_name) do
      {:ok, asset} ->
        maybe_simulate_delay(call)
        execute_workflow_asset_tool(project_ctx, asset, call)

      :error ->
        {:error, :asset_not_found}
    end
  end

  def execute(_project_ctx, _spec, _call), do: {:error, :unsupported_tool}

  defp execute_workflow_asset_tool(project_ctx, asset, call) do
    with {:ok, definition} <- parse_workflow_definition(asset),
         {:ok, execution} <-
           execute_workflow_definition(
             definition,
             workflow_inputs_from_call(call_args(call)),
             workflow_execution_opts(project_ctx, call, definition)
           ) do
      {:ok,
       %{
         asset: asset,
         args: call_args(call),
         mode: :executed,
         runtime: :jido_workflow,
         workflow: definition.name,
         execution: execution
       }}
    else
      {:error, {:invalid_workflow_definition, reason}} ->
        {:ok,
         preview_asset_tool_result(
           asset,
           call_args(call),
           "Workflow definition is invalid for jido_workflow runtime; running in preview compatibility mode.",
           reason
         )}

      {:error, reason} ->
        {:error, {:workflow_execution_failed, reason}}
    end
  end

  defp parse_workflow_definition(%{body: body}) when is_binary(body) do
    case parse_workflow_markdown(body) do
      {:ok, definition} -> {:ok, definition}
      {:error, reason} -> {:error, {:invalid_workflow_definition, reason}}
    end
  end

  defp parse_workflow_definition(_asset),
    do: {:error, {:invalid_workflow_definition, :invalid_asset}}

  defp workflow_inputs_from_call(args) when is_map(args) do
    case map_get_value(args, "inputs") do
      inputs when is_map(inputs) ->
        inputs

      _other ->
        Map.drop(args, ["inputs", :inputs, "simulate_delay_ms", :simulate_delay_ms, "env", :env])
    end
  end

  defp workflow_execution_opts(project_ctx, call, definition) do
    []
    |> Keyword.put(:workflow_id, definition.name)
    |> Keyword.put(:run_id, workflow_run_id(call))
    |> Keyword.put(:bus, :jido_code_bus)
    |> maybe_put_opt(:backend, Map.get(project_ctx, :workflow_backend))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp workflow_run_id(call) do
    case correlation_id_from_call(call) do
      correlation_id when is_binary(correlation_id) and correlation_id != "" ->
        correlation_id

      _other ->
        "wf-#{System.unique_integer([:positive, :monotonic])}"
    end
  end

  defp preview_asset_tool_result(asset, args, note, reason) when is_binary(note) do
    %{
      asset: asset,
      args: args,
      mode: :preview,
      note: note,
      reason: reason
    }
  end

  defp parse_workflow_markdown(body) when is_binary(body) do
    loader_module = JidoWorkflow.Workflow.Loader

    case Code.ensure_loaded(loader_module) do
      {:module, _loaded} ->
        if function_exported?(loader_module, :load_markdown, 1) do
          loader_module.load_markdown(body)
        else
          {:error, :workflow_loader_unavailable}
        end

      _other ->
        {:error, :workflow_loader_unavailable}
    end
  end

  defp execute_workflow_definition(definition, inputs, opts)
       when is_map(inputs) and is_list(opts) do
    runtime_module = JidoWorkflow.Workflow.Engine

    case Code.ensure_loaded(runtime_module) do
      {:module, _loaded} ->
        if function_exported?(runtime_module, :execute_definition, 3) do
          runtime_module.execute_definition(definition, inputs, opts)
        else
          {:error, :workflow_runtime_unavailable}
        end

      _other ->
        {:error, :workflow_runtime_unavailable}
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
