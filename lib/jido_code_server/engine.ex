defmodule JidoCodeServer.Engine do
  @moduledoc """
  Internal multi-project runtime API.

  Implemented baseline:
  - engine-level project lifecycle operations
  - project-scoped conversation shell routing through `Project.Server`
  """

  alias JidoCodeServer.Config
  alias JidoCodeServer.Engine.Project
  alias JidoCodeServer.Engine.ProjectRegistry
  alias JidoCodeServer.Engine.ProjectSupervisor

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
         :ok <- ensure_project_absent(project_id),
         {:ok, _pid} <- start_project_child(project_id, normalized_root_path, data_dir, opts) do
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
