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
          | :subagent_manager
          | :conversation_registry
          | :conversation_supervisor
          | :protocol_supervisor
          | :watcher
          | {:protocol_server, String.t()}

  @spec via(String.t(), component()) :: {:via, Registry, {module(), {String.t(), component()}}}
  def via(project_id, component) when is_binary(project_id) do
    {:via, Registry, {ProjectRegistry, {project_id, component}}}
  end

  @spec protocol_server(String.t(), String.t()) ::
          {:via, Registry, {module(), {String.t(), component()}}}
  def protocol_server(project_id, protocol) when is_binary(project_id) and is_binary(protocol) do
    normalized_protocol = protocol |> String.trim() |> String.downcase()

    if normalized_protocol == "" do
      raise ArgumentError, "protocol must be a non-empty string"
    else
      via(project_id, {:protocol_server, normalized_protocol})
    end
  end
end
