defmodule JidoCodeServer.Protocol.MCP.ProjectServer do
  @moduledoc """
  Per-project MCP adapter that delegates to the global MCP gateway logic.
  """

  use GenServer

  alias JidoCodeServer.Protocol.MCP.Gateway

  @type conversation_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec tools_list(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def tools_list(server) do
    GenServer.call(server, :tools_list)
  end

  @spec tools_call(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def tools_call(server, tool_call) when is_map(tool_call) do
    GenServer.call(server, {:tools_call, tool_call})
  end

  @spec send_message(GenServer.server(), conversation_id(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def send_message(server, conversation_id, content, opts \\ [])
      when is_binary(conversation_id) and is_binary(content) and is_list(opts) do
    GenServer.call(server, {:send_message, conversation_id, content, opts})
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    {:ok, %{project_id: project_id, opts: opts}}
  end

  @impl true
  def handle_call(:tools_list, _from, state) do
    {:reply, Gateway.tools_list(state.project_id), state}
  end

  def handle_call({:tools_call, tool_call}, _from, state) do
    {:reply, Gateway.tools_call(state.project_id, tool_call), state}
  end

  def handle_call({:send_message, conversation_id, content, opts}, _from, state) do
    {:reply, Gateway.send_message(state.project_id, conversation_id, content, opts), state}
  end
end
