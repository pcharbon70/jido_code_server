defmodule JidoCodeServer do
  @moduledoc """
  Public facade for runtime lifecycle and conversation operations.
  """

  alias JidoCodeServer.Engine

  @type project_id :: String.t()
  @type conversation_id :: String.t()
  @type event :: map()

  @spec start_project(String.t(), keyword()) :: {:ok, project_id()} | {:error, term()}
  def start_project(root_path, opts \\ []), do: Engine.start_project(root_path, opts)

  @spec stop_project(project_id()) :: :ok | {:error, term()}
  def stop_project(project_id), do: Engine.stop_project(project_id)

  @spec list_projects() :: list(map())
  def list_projects, do: Engine.list_projects()

  @spec start_conversation(project_id(), keyword()) :: {:ok, conversation_id()} | {:error, term()}
  def start_conversation(project_id, opts \\ []), do: Engine.start_conversation(project_id, opts)

  @spec stop_conversation(project_id(), conversation_id()) :: :ok | {:error, term()}
  def stop_conversation(project_id, conversation_id),
    do: Engine.stop_conversation(project_id, conversation_id)

  @spec send_event(project_id(), conversation_id(), event()) :: :ok | {:error, term()}
  def send_event(project_id, conversation_id, event),
    do: Engine.send_event(project_id, conversation_id, event)

  @spec subscribe_conversation(project_id(), conversation_id(), pid()) :: :ok | {:error, term()}
  def subscribe_conversation(project_id, conversation_id, subscriber_pid \\ self()),
    do: Engine.subscribe_conversation(project_id, conversation_id, subscriber_pid)

  @spec unsubscribe_conversation(project_id(), conversation_id(), pid()) ::
          :ok | {:error, term()}
  def unsubscribe_conversation(project_id, conversation_id, subscriber_pid \\ self()),
    do: Engine.unsubscribe_conversation(project_id, conversation_id, subscriber_pid)

  @spec get_projection(project_id(), conversation_id(), atom() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def get_projection(project_id, conversation_id, key),
    do: Engine.get_projection(project_id, conversation_id, key)

  @spec list_tools(project_id()) :: list(map())
  def list_tools(project_id), do: Engine.list_tools(project_id)

  @spec run_tool(project_id(), map()) :: {:ok, map()} | {:error, term()}
  def run_tool(project_id, tool_call), do: Engine.run_tool(project_id, tool_call)

  @spec reload_assets(project_id()) :: :ok | {:error, term()}
  def reload_assets(project_id), do: Engine.reload_assets(project_id)

  @spec list_assets(project_id(), atom() | String.t()) :: list(map())
  def list_assets(project_id, type), do: Engine.list_assets(project_id, type)

  @spec get_asset(project_id(), atom() | String.t(), atom() | String.t()) ::
          {:ok, term()} | :error | {:error, term()}
  def get_asset(project_id, type, key), do: Engine.get_asset(project_id, type, key)

  @spec search_assets(project_id(), atom() | String.t(), String.t()) :: list(map())
  def search_assets(project_id, type, query), do: Engine.search_assets(project_id, type, query)

  @spec assets_diagnostics(project_id()) :: map() | {:error, term()}
  def assets_diagnostics(project_id), do: Engine.assets_diagnostics(project_id)

  @spec conversation_diagnostics(project_id(), conversation_id()) :: map() | {:error, term()}
  def conversation_diagnostics(project_id, conversation_id),
    do: Engine.conversation_diagnostics(project_id, conversation_id)

  @spec diagnostics(project_id()) :: map() | {:error, term()}
  def diagnostics(project_id), do: Engine.diagnostics(project_id)
end
