defmodule JidoCodeServer.Protocol.MCP.Gateway do
  @moduledoc """
  Placeholder global MCP gateway.
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
