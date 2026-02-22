defmodule JidoCodeServer.Conversation.LLM do
  @moduledoc """
  Placeholder adapter for `JidoAi` orchestration.
  """

  @spec start_completion(map(), String.t(), term(), keyword()) ::
          {:ok, reference()} | {:error, term()}
  def start_completion(_project_ctx, _conversation_id, _llm_context, _opts \\ []) do
    {:error, :not_implemented}
  end

  @spec cancel(reference()) :: :ok
  def cancel(_ref), do: :ok
end
