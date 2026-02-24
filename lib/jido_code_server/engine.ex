defmodule Jido.Code.Server.Engine do
  @moduledoc """
  Internal multi-project runtime API.

  Implemented baseline:
  - engine-level project lifecycle operations
  - project-scoped conversation shell routing through `Project.Server`
  """

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Engine.Project
  alias Jido.Code.Server.Engine.ProjectRegistry
  alias Jido.Code.Server.Engine.ProjectSupervisor
  alias Jido.Code.Server.Project.CommandExecutor.WorkspaceShell

  @positive_integer_runtime_opts [
    :tool_timeout_ms,
    :tool_timeout_alert_threshold,
    :tool_max_output_bytes,
    :tool_max_artifact_bytes,
    :tool_max_concurrency,
    :llm_timeout_ms,
    :watcher_debounce_ms
  ]
  @non_negative_integer_runtime_opts [:tool_max_concurrency_per_conversation]
  @boolean_runtime_opts [:watcher, :conversation_orchestration, :strict_asset_loading]
  @string_list_runtime_opts [
    :deny_tools,
    :network_allowlist,
    :network_allowed_schemes,
    :sensitive_path_denylist,
    :sensitive_path_allowlist,
    :tool_env_allowlist,
    :protocol_allowlist
  ]
  @passthrough_runtime_opts [:project_id, :data_dir, :llm_adapter]
  @allowed_command_executors [WorkspaceShell]

  @type project_id :: String.t()
  @type conversation_id :: String.t()
  @type project_summary :: %{
          project_id: project_id(),
          root_path: String.t(),
          data_dir: String.t(),
          started_at: DateTime.t(),
          pid: pid()
        }

  @spec start_project(String.t(), keyword()) :: {:ok, project_id()} | {:error, term()}
  def start_project(root_path, opts \\ []) do
    with {:ok, normalized_root_path} <- normalize_root_path(root_path),
         {:ok, data_dir} <- resolve_data_dir(opts),
         {:ok, project_id} <- resolve_project_id(opts),
         {:ok, runtime_opts} <- validate_runtime_opts(opts),
         :ok <- ensure_project_absent(project_id),
         {:ok, _pid} <-
           start_project_child(project_id, normalized_root_path, data_dir, runtime_opts) do
      {:ok, project_id}
    end
  end

  @spec stop_project(project_id()) :: :ok | {:error, term()}
  def stop_project(project_id) do
    case whereis_project(project_id) do
      {:ok, pid} -> terminate_project(pid)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec whereis_project(project_id()) ::
          {:ok, pid()}
          | {:error, {:project_not_found, project_id()}}
          | {:error, {:invalid_project_id, :expected_string}}
  def whereis_project(project_id) when is_binary(project_id) do
    case ProjectRegistry.lookup(project_id) do
      [{pid, _value}] when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          {:error, {:project_not_found, project_id}}
        end

      _ ->
        {:error, {:project_not_found, project_id}}
    end
  end

  def whereis_project(_project_id), do: {:error, {:invalid_project_id, :expected_string}}

  @spec list_projects() :: [project_summary()]
  def list_projects do
    ProjectSupervisor.list_project_pids()
    |> Enum.map(&child_to_summary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.project_id)
  end

  @spec start_conversation(project_id(), keyword()) :: {:ok, conversation_id()} | {:error, term()}
  def start_conversation(project_id, opts \\ []) do
    with_project(project_id, fn pid -> Project.start_conversation(pid, opts) end)
  end

  @spec stop_conversation(project_id(), conversation_id()) :: :ok | {:error, term()}
  def stop_conversation(project_id, conversation_id) do
    with_project(project_id, fn pid -> Project.stop_conversation(pid, conversation_id) end)
  end

  @spec send_event(project_id(), conversation_id(), map()) :: :ok | {:error, term()}
  def send_event(project_id, conversation_id, event) do
    with_project(project_id, fn pid -> Project.send_event(pid, conversation_id, event) end)
  end

  @spec subscribe_conversation(project_id(), conversation_id(), pid()) :: :ok | {:error, term()}
  def subscribe_conversation(project_id, conversation_id, subscriber_pid \\ self())
      when is_pid(subscriber_pid) do
    with_project(project_id, fn pid ->
      Project.subscribe_conversation(pid, conversation_id, subscriber_pid)
    end)
  end

  @spec unsubscribe_conversation(project_id(), conversation_id(), pid()) ::
          :ok | {:error, term()}
  def unsubscribe_conversation(project_id, conversation_id, subscriber_pid \\ self())
      when is_pid(subscriber_pid) do
    with_project(project_id, fn pid ->
      Project.unsubscribe_conversation(pid, conversation_id, subscriber_pid)
    end)
  end

  @spec get_projection(project_id(), conversation_id(), atom() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_projection(project_id, conversation_id, key) do
    with_project(project_id, fn pid -> Project.get_projection(pid, conversation_id, key) end)
  end

  @spec list_tools(project_id()) :: list(map())
  def list_tools(project_id) do
    case whereis_project(project_id) do
      {:ok, pid} -> Project.list_tools(pid)
      {:error, _reason} -> []
    end
  end

  @spec run_tool(project_id(), map()) :: {:ok, map()} | {:error, term()}
  def run_tool(project_id, tool_call) when is_map(tool_call) do
    with_project(project_id, fn pid -> Project.run_tool(pid, tool_call) end)
  end

  @spec reload_assets(project_id()) :: :ok | {:error, term()}
  def reload_assets(project_id) do
    with_project(project_id, fn pid -> Project.reload_assets(pid) end)
  end

  @spec list_assets(project_id(), atom() | String.t()) :: [map()]
  def list_assets(project_id, type) do
    case whereis_project(project_id) do
      {:ok, pid} -> Project.list_assets(pid, type)
      {:error, _reason} -> []
    end
  end

  @spec get_asset(project_id(), atom() | String.t(), atom() | String.t()) ::
          {:ok, term()} | :error | {:error, term()}
  def get_asset(project_id, type, key) do
    with_project(project_id, fn pid -> Project.get_asset(pid, type, key) end)
  end

  @spec search_assets(project_id(), atom() | String.t(), String.t()) :: [map()]
  def search_assets(project_id, type, query) do
    case whereis_project(project_id) do
      {:ok, pid} -> Project.search_assets(pid, type, query)
      {:error, _reason} -> []
    end
  end

  @spec assets_diagnostics(project_id()) :: map() | {:error, term()}
  def assets_diagnostics(project_id) do
    with_project(project_id, fn pid -> Project.assets_diagnostics(pid) end)
  end

  @spec conversation_diagnostics(project_id(), conversation_id()) ::
          map() | {:error, term()}
  def conversation_diagnostics(project_id, conversation_id) do
    with_project(project_id, fn pid ->
      Project.conversation_diagnostics(pid, conversation_id)
    end)
  end

  @spec incident_timeline(project_id(), conversation_id(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def incident_timeline(project_id, conversation_id, opts \\ []) when is_list(opts) do
    with_project(project_id, fn pid ->
      Project.incident_timeline(pid, conversation_id, opts)
    end)
  end

  @spec diagnostics(project_id()) :: map() | {:error, term()}
  def diagnostics(project_id) do
    with_project(project_id, fn pid -> Project.diagnostics(pid) end)
  end

  @spec protocol_allowed?(project_id(), String.t()) :: :ok | {:error, term()}
  def protocol_allowed?(project_id, protocol) when is_binary(protocol) do
    with_project(project_id, fn pid -> Project.protocol_allowed?(pid, protocol) end)
  end

  def protocol_allowed?(_project_id, _protocol), do: {:error, :invalid_protocol}

  defp resolve_project_id(opts) do
    case Keyword.get(opts, :project_id) do
      nil ->
        generate_project_id()

      project_id when is_binary(project_id) ->
        project_id = String.trim(project_id)

        if project_id == "" do
          {:error, {:invalid_project_id, :empty}}
        else
          {:ok, project_id}
        end

      _other ->
        {:error, {:invalid_project_id, :expected_string}}
    end
  end

  defp generate_project_id do
    {module, function, args} = Config.project_id_generator()
    project_id = apply(module, function, args)

    if is_binary(project_id) and String.trim(project_id) != "" do
      {:ok, project_id}
    else
      {:error, {:invalid_project_id, :generated_invalid}}
    end
  rescue
    error ->
      {:error, {:project_id_generation_failed, error}}
  end

  defp resolve_data_dir(opts) do
    data_dir = Keyword.get(opts, :data_dir, Config.default_data_dir())

    cond do
      not is_binary(data_dir) ->
        {:error, {:invalid_data_dir, :expected_non_empty_string}}

      String.trim(data_dir) == "" ->
        {:error, {:invalid_data_dir, :expected_non_empty_string}}

      Path.type(data_dir) == :absolute ->
        {:error, {:invalid_data_dir, :must_be_relative}}

      Enum.member?(Path.split(data_dir), "..") ->
        {:error, {:invalid_data_dir, :must_not_traverse}}

      true ->
        {:ok, data_dir}
    end
  end

  defp ensure_project_absent(project_id) do
    case whereis_project(project_id) do
      {:ok, _pid} -> {:error, {:already_started, project_id}}
      {:error, {:project_not_found, ^project_id}} -> :ok
    end
  end

  defp start_project_child(project_id, root_path, data_dir, opts) do
    child_opts = [
      project_id: project_id,
      root_path: root_path,
      data_dir: data_dir,
      opts: opts
    ]

    case ProjectSupervisor.start_project(child_opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        {:error, {:already_started, project_id}}

      {:error, reason} ->
        {:error, {:start_project_failed, reason}}
    end
  end

  defp validate_runtime_opts(opts) when is_list(opts) do
    opts
    |> Enum.reduce_while({:ok, []}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        case validate_runtime_opt(key, value) do
          {:ok, normalized_value} ->
            {:cont, {:ok, [{key, normalized_value} | acc]}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_runtime_opt, key, reason}}}
        end

      {key, _value}, _acc ->
        {:halt, {:error, {:invalid_runtime_opt, key, :expected_atom_key}}}

      invalid_entry, _acc ->
        {:halt, {:error, {:invalid_runtime_opt, invalid_entry, :expected_key_value_tuple}}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_runtime_opt(:allow_tools, nil), do: {:ok, nil}

  defp validate_runtime_opt(:allow_tools, value), do: validate_string_list(value)

  defp validate_runtime_opt(key, value) when key in @passthrough_runtime_opts,
    do: {:ok, value}

  defp validate_runtime_opt(key, value) when key in @string_list_runtime_opts,
    do: validate_string_list(value)

  defp validate_runtime_opt(key, value) when key in @positive_integer_runtime_opts,
    do: validate_positive_integer(value)

  defp validate_runtime_opt(key, value) when key in @non_negative_integer_runtime_opts,
    do: validate_non_negative_integer(value)

  defp validate_runtime_opt(key, value) when key in @boolean_runtime_opts,
    do: validate_boolean(value)

  defp validate_runtime_opt(:network_egress_policy, value),
    do: validate_network_egress_policy(value)

  defp validate_runtime_opt(:outside_root_allowlist, value),
    do: validate_outside_root_allowlist(value)

  defp validate_runtime_opt(:llm_model, value), do: validate_optional_binary(value)

  defp validate_runtime_opt(:llm_system_prompt, value), do: validate_optional_binary(value)

  defp validate_runtime_opt(:llm_temperature, value), do: validate_optional_number(value)

  defp validate_runtime_opt(:llm_max_tokens, value), do: validate_optional_positive_integer(value)

  defp validate_runtime_opt(:command_executor, value), do: validate_command_executor(value)

  defp validate_runtime_opt(_key, _value), do: {:error, :unknown_option}

  defp validate_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_positive_integer(_value), do: {:error, :expected_positive_integer}

  defp validate_non_negative_integer(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp validate_non_negative_integer(_value), do: {:error, :expected_non_negative_integer}

  defp validate_boolean(value) when is_boolean(value), do: {:ok, value}
  defp validate_boolean(_value), do: {:error, :expected_boolean}

  defp validate_string_list(value) when is_list(value) do
    if Enum.all?(value, &is_binary/1) do
      {:ok, value}
    else
      {:error, :expected_list_of_strings}
    end
  end

  defp validate_string_list(_value), do: {:error, :expected_list_of_strings}

  defp validate_network_egress_policy(:allow), do: {:ok, :allow}
  defp validate_network_egress_policy(:deny), do: {:ok, :deny}
  defp validate_network_egress_policy("allow"), do: {:ok, :allow}
  defp validate_network_egress_policy("deny"), do: {:ok, :deny}
  defp validate_network_egress_policy(_value), do: {:error, :expected_allow_or_deny}

  defp validate_outside_root_allowlist(value) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      case validate_outside_root_allowlist_entry(entry) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_entry, index, reason}}}
      end
    end)
    |> case do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp validate_outside_root_allowlist(_value), do: {:error, :expected_list_of_reason_coded_maps}

  defp validate_outside_root_allowlist_entry(entry) when is_map(entry) do
    path_or_pattern =
      Map.get(entry, :pattern) ||
        Map.get(entry, "pattern") ||
        Map.get(entry, :path) ||
        Map.get(entry, "path")

    reason_code = Map.get(entry, :reason_code) || Map.get(entry, "reason_code")

    case validate_path_or_pattern(path_or_pattern) do
      :ok -> validate_reason_code(reason_code)
      {:error, _reason} = error -> error
    end
  end

  defp validate_outside_root_allowlist_entry(_entry), do: {:error, :expected_map_entry}

  defp validate_path_or_pattern(nil), do: {:error, :missing_path_or_pattern}

  defp validate_path_or_pattern(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, :empty_path_or_pattern}
    else
      :ok
    end
  end

  defp validate_path_or_pattern(_value), do: {:error, :expected_path_or_pattern_string}

  defp validate_reason_code(nil), do: {:error, :missing_reason_code}

  defp validate_reason_code(value) when is_binary(value) do
    if String.trim(value) == "" do
      {:error, :empty_reason_code}
    else
      :ok
    end
  end

  defp validate_reason_code(_value), do: {:error, :expected_reason_code_string}

  defp validate_optional_binary(nil), do: {:ok, nil}
  defp validate_optional_binary(value) when is_binary(value), do: {:ok, value}
  defp validate_optional_binary(_value), do: {:error, :expected_string_or_nil}

  defp validate_optional_number(nil), do: {:ok, nil}
  defp validate_optional_number(value) when is_number(value), do: {:ok, value}
  defp validate_optional_number(_value), do: {:error, :expected_number_or_nil}

  defp validate_optional_positive_integer(nil), do: {:ok, nil}

  defp validate_optional_positive_integer(value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp validate_optional_positive_integer(_value), do: {:error, :expected_positive_integer_or_nil}

  defp validate_command_executor(nil), do: {:ok, nil}

  defp validate_command_executor(value) when is_atom(value) do
    case normalize_command_executor(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :unsupported_command_executor}
    end
  end

  defp validate_command_executor(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> normalize_command_executor()
    |> case do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :unsupported_command_executor}
    end
  end

  defp validate_command_executor(_value), do: {:error, :expected_command_executor_or_nil}

  defp normalize_command_executor(:workspace_shell), do: {:ok, WorkspaceShell}
  defp normalize_command_executor("workspace_shell"), do: {:ok, WorkspaceShell}

  defp normalize_command_executor(value) when is_atom(value) do
    if value in @allowed_command_executors do
      {:ok, value}
    else
      :error
    end
  end

  defp normalize_command_executor(_value), do: :error

  defp terminate_project(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    case ProjectSupervisor.stop_project(pid) do
      :ok -> await_project_exit(pid, ref)
      {:error, :not_found} -> :ok
    end
  end

  defp await_project_exit(pid, ref) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      6_000 ->
        Process.demonitor(ref, [:flush])
        :ok
    end
  end

  defp child_to_summary(pid) when is_pid(pid) do
    Project.summary(pid)
  catch
    :exit, _reason -> nil
  end

  defp child_to_summary(_), do: nil

  defp with_project(project_id, fun) do
    with {:ok, pid} <- whereis_project(project_id) do
      fun.(pid)
    end
  end

  defp normalize_root_path(root_path) when is_binary(root_path) do
    normalized = Path.expand(root_path)

    case File.stat(normalized) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, normalized}

      {:ok, _other} ->
        {:error, {:invalid_root_path, :not_directory}}

      {:error, reason} ->
        {:error, {:invalid_root_path, reason}}
    end
  end

  defp normalize_root_path(_root_path), do: {:error, {:invalid_root_path, :expected_string}}
end
