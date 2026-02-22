defmodule JidoCodeServer.Project.Loaders.Command do
  @moduledoc """
  Loads markdown command specifications from the project data directory.
  """

  alias JidoCodeServer.Project.Loaders.Common

  @spec load(map()) :: {:ok, %{assets: list(map()), errors: list(map())}} | {:error, term()}
  def load(layout) when is_map(layout) do
    {:ok, Common.load_markdown_assets(layout, :command, __MODULE__)}
  end
end
