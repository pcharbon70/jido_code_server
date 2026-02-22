defmodule Jido.Code.Server.Project.Watcher do
  @moduledoc """
  Optional `.jido/*` watcher with debounced asset reload.
  """

  use GenServer

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.Layout
  alias Jido.Code.Server.Telemetry

  @watched_layout_keys [:skills, :commands, :workflows, :skill_graph]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    root_path = Keyword.fetch!(opts, :root_path)
    data_dir = Keyword.get(opts, :data_dir, Config.default_data_dir())
    asset_store = Keyword.fetch!(opts, :asset_store)

    debounce_ms =
      normalize_debounce_ms(Keyword.get(opts, :debounce_ms, Config.watcher_debounce_ms()))

    layout = Layout.paths(root_path, data_dir)
    watch_dirs = Enum.map(@watched_layout_keys, &Map.fetch!(layout, &1))

    with {:ok, file_system_pid} <- FileSystem.start_link(dirs: watch_dirs),
         :ok <- FileSystem.subscribe(file_system_pid) do
      Telemetry.emit("project.watcher_started", %{
        project_id: project_id,
        watch_dirs: watch_dirs,
        debounce_ms: debounce_ms
      })

      {:ok,
       %{
         project_id: project_id,
         asset_store: asset_store,
         watch_dirs: watch_dirs,
         file_system_pid: file_system_pid,
         debounce_ms: debounce_ms,
         timer_ref: nil,
         pending_paths: MapSet.new(),
         pending_event_count: 0
       }}
    else
      {:error, reason} ->
        {:stop, {:watcher_start_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Telemetry.emit("project.watcher_stopped", %{
      project_id: state.project_id,
      pending_event_count: state.pending_event_count
    })

    :ok
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Telemetry.emit("project.watcher_stopped", %{
      project_id: state.project_id,
      reason: :file_system_stop
    })

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    case normalize_path(path) do
      {:ok, normalized_path} ->
        if relevant_path?(normalized_path, state.watch_dirs) do
          next_state =
            state
            |> mark_pending_change(normalized_path)
            |> schedule_reload()

          {:noreply, next_state}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:flush_reload, state) do
    changed_paths = state.pending_paths |> MapSet.to_list() |> Enum.sort()

    result = AssetStore.reload(state.asset_store)

    case result do
      :ok ->
        Telemetry.emit("project.watcher_reload_completed", %{
          project_id: state.project_id,
          changed_paths: changed_paths,
          changed_count: length(changed_paths)
        })

      {:error, reason} ->
        Telemetry.emit("project.watcher_reload_failed", %{
          project_id: state.project_id,
          changed_paths: changed_paths,
          changed_count: length(changed_paths),
          error: reason
        })
    end

    {:noreply, clear_pending(state)}
  end

  defp normalize_debounce_ms(value) when is_integer(value) and value > 0, do: value
  defp normalize_debounce_ms(_value), do: Config.watcher_debounce_ms()

  defp normalize_path(path) when is_binary(path), do: {:ok, Path.expand(path)}

  defp normalize_path(path) when is_list(path),
    do: {:ok, path |> List.to_string() |> Path.expand()}

  defp normalize_path(_path), do: :error

  defp relevant_path?(path, dirs) do
    Enum.any?(dirs, fn dir ->
      String.starts_with?(path, Path.expand(dir) <> "/") or path == Path.expand(dir)
    end)
  end

  defp mark_pending_change(state, normalized_path) do
    %{
      state
      | pending_paths: MapSet.put(state.pending_paths, normalized_path),
        pending_event_count: state.pending_event_count + 1
    }
  end

  defp schedule_reload(state) do
    if state.timer_ref do
      _ = Process.cancel_timer(state.timer_ref)
    end

    timer_ref = Process.send_after(self(), :flush_reload, state.debounce_ms)
    %{state | timer_ref: timer_ref}
  end

  defp clear_pending(state) do
    %{
      state
      | timer_ref: nil,
        pending_paths: MapSet.new(),
        pending_event_count: 0
    }
  end
end
