defmodule JidoCodeServer.Engine.ProjectRegistry do
  @moduledoc """
  Registry helpers for project process lookup and naming.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    Registry.child_spec(Keyword.merge([keys: :unique, name: __MODULE__], opts))
  end

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(project_id) when is_binary(project_id) do
    {:via, Registry, {__MODULE__, project_id}}
  end

  @spec lookup(String.t()) :: [{pid(), term()}]
  def lookup(project_id) when is_binary(project_id) do
    Registry.lookup(__MODULE__, project_id)
  end
end
