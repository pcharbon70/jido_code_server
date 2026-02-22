defmodule JidoCodeServer.Project.TaskSupervisor do
  @moduledoc """
  Named `Task.Supervisor` child-spec wrapper for project-scoped execution.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    Task.Supervisor.child_spec(opts)
  end
end
