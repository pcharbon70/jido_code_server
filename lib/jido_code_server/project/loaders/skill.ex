defmodule JidoCodeServer.Project.Loaders.Skill do
  @moduledoc """
  Loads markdown skills from the project data directory.
  """

  alias JidoCodeServer.Project.Loaders.Common

  @spec load(map()) :: {:ok, %{assets: list(map()), errors: list(map())}} | {:error, term()}
  def load(layout) when is_map(layout) do
    {:ok, Common.load_markdown_assets(layout, :skill, __MODULE__)}
  end
end
