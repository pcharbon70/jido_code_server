defmodule JidoCodeServer.Project.ToolCatalog do
  @moduledoc """
  Tool inventory placeholder.
  """

  @spec all_tools(map()) :: list(map())
  def all_tools(_project_ctx), do: []

  @spec get_tool(map(), String.t()) :: {:ok, map()} | :error
  def get_tool(_project_ctx, _name), do: :error
end
