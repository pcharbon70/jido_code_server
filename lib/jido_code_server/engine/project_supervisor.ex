defmodule Jido.Code.Server.Engine.ProjectSupervisor do
  @moduledoc """
  Dynamic supervisor for project runtime processes.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_project(keyword()) :: DynamicSupervisor.on_start_child()
  def start_project(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Jido.Code.Server.Engine.Project, opts})
  end

  @spec stop_project(pid()) :: :ok | {:error, :not_found | term()}
  def stop_project(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @spec list_project_pids() :: [pid()]
  def list_project_pids do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
      _other -> []
    end)
  end
end
