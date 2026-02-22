defmodule JidoCodeServer.Project.Loaders.SkillGraph do
  @moduledoc """
  Placeholder skill graph loader.
  """

  @spec load(map()) :: {:ok, map()} | {:error, term()}
  def load(_layout), do: {:ok, %{nodes: [], edges: []}}
end
