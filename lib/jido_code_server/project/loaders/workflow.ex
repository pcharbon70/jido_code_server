defmodule JidoCodeServer.Project.Loaders.Workflow do
  @moduledoc """
  Loads workflow markdown definitions from the project data directory.
  """

  alias JidoCodeServer.Project.Loaders.Common

  @spec load(map()) :: {:ok, %{assets: list(map()), errors: list(map())}} | {:error, term()}
  def load(layout) when is_map(layout) do
    {:ok, Common.load_markdown_assets(layout, :workflow, __MODULE__)}
  end
end
