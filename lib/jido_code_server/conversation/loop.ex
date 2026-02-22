defmodule JidoCodeServer.Conversation.Loop do
  @moduledoc """
  Placeholder decision loop executed after each event ingest.
  """

  @spec after_ingest(term(), map()) :: {:ok, term(), list(map())}
  def after_ingest(conv_state, _project_ctx), do: {:ok, conv_state, []}
end
