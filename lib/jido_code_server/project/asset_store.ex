defmodule JidoCodeServer.Project.AssetStore do
  @moduledoc """
  ETS-backed asset store placeholder.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts, table: nil}}
  end
end
