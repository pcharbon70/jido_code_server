defmodule Jido.Code.Server.TestSupport.RuntimeSignal do
  @moduledoc """
  Test helper to send canonical conversation signals through the runtime API.
  """

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @spec send_signal(String.t(), String.t(), map() | Jido.Signal.t(), timeout()) ::
          :ok | {:error, term()}
  def send_signal(project_id, conversation_id, raw_signal, timeout \\ 30_000) do
    with {:ok, signal} <- ConversationSignal.normalize(raw_signal),
         {:ok, _snapshot} <-
           Runtime.conversation_call(project_id, conversation_id, signal, timeout) do
      :ok
    end
  end
end
