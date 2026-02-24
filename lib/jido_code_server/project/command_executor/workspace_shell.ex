defmodule Jido.Code.Server.Project.CommandExecutor.WorkspaceShell do
  @moduledoc """
  Optional command executor that runs command prompts inside a `Jido.Workspace`
  shell session.

  This provides an additional isolation mode for command execution by using the
  workspace-backed shell sandbox instead of directly executing on host paths.
  """

  @default_timeout_ms 30_000

  def execute(definition, prompt, params, context)
      when is_map(definition) and is_binary(prompt) and is_map(params) and is_map(context) do
    workspace_id = workspace_id(context, definition, workspace_nonce())

    with {:ok, workspace} <- open_workspace(workspace_id),
         {:ok, output, workspace} <- run_workspace_command(workspace, prompt, context),
         :ok <- close_workspace(workspace) do
      {:ok,
       %{
         "executor" => "workspace_shell",
         "workspace_id" => workspace_id,
         "command" => command_name(definition),
         "prompt" => prompt,
         "params" => params,
         "output" => output
       }}
    else
      {:error, reason, workspace} ->
        _ = close_workspace(workspace)
        {:error, {:workspace_command_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_definition, _prompt, _params, _context), do: {:error, :invalid_executor_input}

  defp open_workspace(workspace_id) when is_binary(workspace_id) do
    case Jido.Workspace.new(id: workspace_id) do
      workspace when is_map(workspace) ->
        {:ok, workspace}

      {:error, reason} ->
        {:error, {:workspace_init_failed, reason}}
    end
  rescue
    error ->
      {:error, {:workspace_init_failed, error}}
  end

  defp run_workspace_command(workspace, prompt, context)
       when is_binary(prompt) and is_map(context) do
    timeout = workspace_timeout_ms(context)

    case Jido.Workspace.run(workspace, prompt, timeout: timeout) do
      {:ok, output, updated_workspace} ->
        {:ok, output, updated_workspace}

      {:error, reason, updated_workspace} ->
        {:error, reason, updated_workspace}
    end
  rescue
    error ->
      {:error, {:workspace_run_failed, error}, workspace}
  end

  defp close_workspace(workspace) do
    case Jido.Workspace.close(workspace) do
      {:ok, _updated_workspace} -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    _error ->
      :ok
  end

  defp workspace_timeout_ms(context) when is_map(context) do
    case Map.get(context, :tool_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      _other ->
        @default_timeout_ms
    end
  end

  defp workspace_id(context, definition, nonce) when is_binary(nonce) do
    project_id = context_value(context, :project_id, "project")
    conversation_id = context_value(context, :conversation_id, "conversation")
    invocation_id = context_value(context, :invocation_id, "invocation")
    name = command_name(definition)

    ["jcs", project_id, conversation_id, name, invocation_id, nonce]
    |> Enum.map(&normalize_segment/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("-")
    |> String.slice(0, 120)
    |> ensure_workspace_id()
  end

  defp workspace_nonce do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp ensure_workspace_id(""), do: "jcs-workspace"
  defp ensure_workspace_id(id), do: id

  defp command_name(definition) when is_map(definition) do
    case Map.get(definition, :name) || Map.get(definition, "name") do
      value when is_binary(value) and value != "" -> value
      _other -> "command"
    end
  end

  defp context_value(context, key, fallback) do
    case Map.get(context, key) || Map.get(context, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _other -> fallback
    end
  end

  defp normalize_segment(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.trim("-")
  end
end
