defmodule Jido.Code.Server.Project.ToolCatalog.Providers.AssetProvider do
  @moduledoc """
  Default tool provider that exposes command/workflow tools discovered from
  project assets.
  """

  @behaviour Jido.Code.Server.Project.ToolCatalog.Provider

  alias Jido.Code.Server.Project.ToolCatalog

  @impl true
  def tools(project_ctx) when is_map(project_ctx) do
    ToolCatalog.asset_tools(project_ctx)
  end

  def tools(_project_ctx), do: []
end
