defmodule JidoCodeServer.Project.ToolRunner do
  @moduledoc """
  Unified tool execution placeholder.
  """

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(_project_ctx, _tool_call), do: {:error, :not_implemented}

  @spec run_async(map(), map(), keyword()) :: :ok
  def run_async(_project_ctx, _tool_call, _opts), do: :ok
end
