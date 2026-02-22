defmodule JidoCodeServer.Protocol.MCP.ProjectServer do
  @moduledoc """
  Placeholder per-project MCP server.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts}}
  end
end
