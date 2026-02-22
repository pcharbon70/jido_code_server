defmodule JidoCodeServer.Conversation.ToolBridge do
  @moduledoc """
  Placeholder bridge between conversation tool requests and project tool execution.
  """

  @spec handle_tool_requested(map(), String.t(), map()) :: :ok
  def handle_tool_requested(_project_ctx, _conversation_id, _tool_call), do: :ok
end
