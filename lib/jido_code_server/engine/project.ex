defmodule JidoCodeServer.Engine.Project do
  @moduledoc """
  Runtime process representing a started project instance.

  Phase 1 keeps this intentionally lightweight. It stores normalized project metadata
  and exposes a summary API used by engine list/lookup operations.
  """

  use GenServer

  @type t :: %{
          project_id: String.t(),
          root_path: String.t(),
          data_dir: String.t(),
          started_at: DateTime.t(),
          opts: keyword()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    name = JidoCodeServer.Engine.ProjectRegistry.via(project_id)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec summary(pid()) :: map()
  def summary(pid) when is_pid(pid) do
    GenServer.call(pid, :summary)
  end

  @impl true
  def init(opts) do
    state = %{
      project_id: Keyword.fetch!(opts, :project_id),
      root_path: Keyword.fetch!(opts, :root_path),
      data_dir: Keyword.fetch!(opts, :data_dir),
      started_at: DateTime.utc_now(),
      opts: opts
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:summary, _from, state) do
    summary = %{
      project_id: state.project_id,
      root_path: state.root_path,
      data_dir: state.data_dir,
      started_at: state.started_at,
      pid: self()
    }

    {:reply, summary, state}
  end
end
