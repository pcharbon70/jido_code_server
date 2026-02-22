defmodule JidoCodeServer.Project.AssetStore do
  @moduledoc """
  ETS-backed asset store placeholder.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: opts, table: nil}}
  end
end
