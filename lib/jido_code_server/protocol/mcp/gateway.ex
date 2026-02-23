defmodule Jido.Code.Server.Protocol.MCP.Gateway do
  @moduledoc """
  Global MCP adapter that multiplexes requests by `project_id`.
  """

  use GenServer

  alias Jido.Code.Server.Engine
  alias Jido.Code.Server.Telemetry
  alias Jido.Code.Server.Types.ToolCall

  @type project_id :: String.t()
  @type conversation_id :: String.t()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec tools_list(project_id(), GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def tools_list(project_id, server \\ __MODULE__) when is_binary(project_id) do
    GenServer.call(server, {:tools_list, project_id})
  end

  @spec tools_call(project_id(), map(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def tools_call(project_id, tool_call, server \\ __MODULE__)
      when is_binary(project_id) and is_map(tool_call) do
    GenServer.call(server, {:tools_call, project_id, tool_call})
  end

  @spec send_message(project_id(), conversation_id(), String.t(), keyword(), GenServer.server()) ::
          :ok | {:error, term()}
  def send_message(project_id, conversation_id, content, opts \\ [], server \\ __MODULE__)
      when is_binary(project_id) and is_binary(conversation_id) and is_binary(content) and
             is_list(opts) do
    GenServer.call(server, {:send_message, project_id, conversation_id, content, opts})
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts}}
  end

  @impl true
  def handle_call({:tools_list, project_id}, _from, state) do
    reply =
      with :ok <- ensure_protocol_access(project_id, "mcp", "tools.list") do
        {:ok, Engine.list_tools(project_id)}
      end

    {:reply, reply, state}
  end

  def handle_call({:tools_call, project_id, tool_call}, _from, state) do
    reply =
      with :ok <- ensure_protocol_access(project_id, "mcp", "tools.call"),
           {:ok, normalized} <- ToolCall.from_map(tool_call) do
        Engine.run_tool(project_id, ToolCall.to_map(normalized))
      end

    {:reply, reply, state}
  end

  def handle_call({:send_message, project_id, conversation_id, content, opts}, _from, state) do
    reply =
      with :ok <- ensure_protocol_access(project_id, "mcp", "message.send"),
           :ok <- validate_content(content) do
        event = message_event(content, opts)
        Engine.send_event(project_id, conversation_id, event)
      end

    {:reply, reply, state}
  end

  defp ensure_protocol_access(project_id, protocol, operation) do
    case Engine.protocol_allowed?(project_id, protocol) do
      :ok ->
        :ok

      {:error, :protocol_denied} ->
        Telemetry.emit("security.protocol_denied", %{
          project_id: project_id,
          protocol: protocol,
          operation: operation
        })

        {:error, {:protocol_denied, protocol}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_content(content) when is_binary(content) do
    if String.trim(content) == "" do
      {:error, :empty_content}
    else
      :ok
    end
  end

  defp message_event(content, opts) do
    meta =
      opts
      |> Keyword.get(:meta, %{})
      |> Map.new()
      |> Map.put_new("protocol", "mcp")

    %{
      "type" => "user.message",
      "content" => content,
      "meta" => meta
    }
  end
end
