defmodule Jido.Code.Server.Project.ToolCatalog.Provider do
  @moduledoc """
  Behaviour for project tool catalog providers.

  Providers translate runtime/project state into tool spec maps consumed by
  `ToolCatalog`. This makes tool inventory pluggable while keeping one
  canonical aggregation point.
  """

  @type tool_spec :: map()

  @callback tools(project_ctx :: map()) :: [tool_spec()] | {:ok, [tool_spec()]}
end
