defmodule Jido.Code.Server.Project.ToolCatalog.Provider do
  @moduledoc """
  Provider contract for registering additional action-backed runtime tools.
  """

  @callback tools(project_ctx :: map()) :: [map()]
end
