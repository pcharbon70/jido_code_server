defmodule JidoCodeServer.Engine do
  @moduledoc """
  Phase 0 placeholder for engine operations across multiple projects.
  """

  @type project_id :: String.t()
  @type conversation_id :: String.t()

  @spec start_project(String.t(), keyword()) :: {:ok, project_id()} | {:error, term()}
  def start_project(_root_path, _opts \\ []), do: {:error, :not_implemented}

  @spec stop_project(project_id()) :: :ok | {:error, term()}
  def stop_project(_project_id), do: {:error, :not_implemented}

  @spec list_projects() :: list(map())
  def list_projects, do: []

  @spec start_conversation(project_id(), keyword()) :: {:ok, conversation_id()} | {:error, term()}
  def start_conversation(_project_id, _opts \\ []), do: {:error, :not_implemented}

  @spec stop_conversation(project_id(), conversation_id()) :: :ok | {:error, term()}
  def stop_conversation(_project_id, _conversation_id), do: {:error, :not_implemented}

  @spec send_event(project_id(), conversation_id(), map()) :: :ok | {:error, term()}
  def send_event(_project_id, _conversation_id, _event), do: {:error, :not_implemented}

  @spec get_projection(project_id(), conversation_id(), atom() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_projection(_project_id, _conversation_id, _key), do: {:error, :not_implemented}

  @spec list_tools(project_id()) :: list(map())
  def list_tools(_project_id), do: []

  @spec reload_assets(project_id()) :: :ok | {:error, term()}
  def reload_assets(_project_id), do: {:error, :not_implemented}
end
