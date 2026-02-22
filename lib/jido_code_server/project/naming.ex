defmodule Jido.Code.Server.Project.Naming do
  @moduledoc """
  Name helpers for project-scoped processes registered in the engine registry.
  """

  alias Jido.Code.Server.Engine.ProjectRegistry

  @type component ::
          :project_supervisor
          | :project_server
          | :asset_store
          | :policy
          | :task_supervisor
          | :conversation_registry
          | :conversation_supervisor
          | :protocol_supervisor
          | :watcher

  @spec via(String.t(), component()) :: {:via, Registry, {module(), {String.t(), component()}}}
  def via(project_id, component) when is_binary(project_id) do
    {:via, Registry, {ProjectRegistry, {project_id, component}}}
  end
end
