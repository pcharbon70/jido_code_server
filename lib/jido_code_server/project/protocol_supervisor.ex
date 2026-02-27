defmodule Jido.Code.Server.Project.ProtocolSupervisor do
  @moduledoc """
  Supervisor for project-scoped protocol adapters.
  """

  use Supervisor

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Project.Naming
  alias Jido.Code.Server.Protocol.A2A.ProjectServer, as: A2AProjectServer
  alias Jido.Code.Server.Protocol.MCP.ProjectServer, as: MCPProjectServer

  @known_protocols ["mcp", "a2a"]

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    project_id = Keyword.fetch!(opts, :project_id)

    allowlist =
      opts
      |> Keyword.get(:runtime_opts, [])
      |> protocol_allowlist()

    children =
      Enum.flat_map(@known_protocols, fn protocol ->
        if protocol_allowed?(allowlist, protocol) do
          [
            {protocol_module(protocol),
             [name: Naming.protocol_server(project_id, protocol), project_id: project_id]}
          ]
        else
          []
        end
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp protocol_module("mcp"), do: MCPProjectServer
  defp protocol_module("a2a"), do: A2AProjectServer

  defp protocol_allowed?(allowlist, protocol) when is_list(allowlist) and is_binary(protocol) do
    "*" in allowlist or protocol in allowlist
  end

  defp protocol_allowlist(runtime_opts) when is_list(runtime_opts) do
    runtime_opts
    |> Keyword.get(:protocol_allowlist, Config.protocol_allowlist())
    |> normalize_protocol_allowlist()
  end

  defp protocol_allowlist(_runtime_opts),
    do: normalize_protocol_allowlist(Config.protocol_allowlist())

  defp normalize_protocol_allowlist(allowlist) when is_list(allowlist) do
    allowlist
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_protocol_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_protocol_allowlist(_allowlist),
    do: normalize_protocol_allowlist(Config.protocol_allowlist())

  defp normalize_protocol_name(protocol) when is_binary(protocol) do
    protocol
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_protocol_name(_protocol), do: nil
end
