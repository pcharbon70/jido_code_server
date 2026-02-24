defmodule Jido.Code.Server.Project.CommandExecutor.WorkspaceShell do
  @moduledoc """
  Optional command executor that runs command prompts inside a `Jido.Workspace`
  shell session.

  This provides an additional isolation mode for command execution by using the
  workspace-backed shell sandbox instead of directly executing on host paths.
  """

  alias Jido.Code.Server.Project.ToolRunner
  alias Jido.Shell.ShellSession

  @default_timeout_ms 30_000

  def execute(definition, prompt, params, context)
      when is_map(definition) and is_binary(prompt) and is_map(params) and is_map(context) do
    workspace_id = workspace_id(context, definition, workspace_nonce())

    with {:ok, workspace} <- open_workspace(workspace_id, context),
         {:ok, workspace} <- ensure_workspace_session(workspace),
         :ok <- maybe_register_workspace_session(workspace, context),
         {:ok, output, workspace} <- run_workspace_command(workspace, prompt, context),
         :ok <- maybe_unregister_workspace_session(workspace, context),
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
        _ = maybe_unregister_workspace_session(workspace, context)
        _ = close_workspace(workspace)
        {:error, {:workspace_command_failed, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(_definition, _prompt, _params, _context), do: {:error, :invalid_executor_input}

  defp open_workspace(workspace_id, context) when is_binary(workspace_id) and is_map(context) do
    with {:ok, project_root} <- project_root(context) do
      workspace_opts = [
        id: workspace_id,
        adapter: Jido.VFS.Adapter.Local,
        adapter_opts: [prefix: project_root]
      ]

      case Jido.Workspace.new(workspace_opts) do
        workspace when is_map(workspace) ->
          {:ok, workspace}

        {:error, reason} ->
          {:error, {:workspace_init_failed, reason}}
      end
    end
  rescue
    error ->
      {:error, {:workspace_init_failed, error}}
  end

  defp open_workspace(_workspace_id, _context) do
    {:error, {:workspace_init_failed, :invalid_workspace_context}}
  end

  defp ensure_workspace_session(workspace) do
    case Jido.Workspace.start_session(workspace) do
      {:ok, workspace} ->
        {:ok, workspace}

      {:error, reason} ->
        {:error, {:workspace_session_failed, reason}}
    end
  rescue
    error ->
      {:error, {:workspace_session_failed, error}}
  end

  defp maybe_register_workspace_session(workspace, context) do
    with {:ok, owner_pid} <- owner_task_pid(context),
         {:ok, session_pid} <- workspace_session_pid(workspace) do
      ToolRunner.register_child_process(owner_pid, session_pid)
      :ok
    else
      _ -> :ok
    end
  end

  defp maybe_unregister_workspace_session(workspace, context) do
    with {:ok, owner_pid} <- owner_task_pid(context),
         {:ok, session_pid} <- workspace_session_pid(workspace) do
      ToolRunner.unregister_child_process(owner_pid, session_pid)
      :ok
    else
      _ -> :ok
    end
  end

  defp project_root(context) when is_map(context) do
    case Map.get(context, :project_root) || Map.get(context, "project_root") do
      root when is_binary(root) and root != "" ->
        {:ok, root}

      _missing ->
        {:error, {:workspace_init_failed, :missing_project_root}}
    end
  end

  defp owner_task_pid(context) when is_map(context) do
    case Map.get(context, :task_owner_pid) || Map.get(context, "task_owner_pid") do
      pid when is_pid(pid) -> {:ok, pid}
      _other -> :error
    end
  end

  defp workspace_session_pid(workspace) do
    case Jido.Workspace.session_id(workspace) do
      session_id when is_binary(session_id) and session_id != "" ->
        case ShellSession.lookup(session_id) do
          {:ok, session_pid} -> {:ok, session_pid}
          _ -> :error
        end

      _other ->
        :error
    end
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
