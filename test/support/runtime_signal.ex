defmodule Jido.Code.Server.TestSupport.RuntimeSignal do
  @moduledoc """
  Test helper to send canonical conversation signals through the runtime API.
  """

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Conversation.Agent, as: ConversationAgent
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Engine
  alias Jido.Code.Server.Project.Naming
  alias Jido.Code.Server.Project.Server, as: ProjectServer

  @spec send_signal(String.t(), String.t(), map() | Jido.Signal.t(), timeout()) ::
          :ok | {:error, term()}
  def send_signal(project_id, conversation_id, raw_signal, timeout \\ 30_000) do
    with {:ok, signal} <- ConversationSignal.normalize(raw_signal),
         {:ok, _snapshot} <- dispatch_signal(project_id, conversation_id, signal, timeout) do
      :ok
    end
  end

  defp dispatch_signal(project_id, conversation_id, signal, timeout) do
    if ConversationAgent.external_signal_type?(signal.type) do
      Runtime.conversation_call(project_id, conversation_id, signal, timeout)
    else
      dispatch_internal_signal(project_id, conversation_id, signal, timeout)
    end
  end

  defp dispatch_internal_signal(project_id, conversation_id, signal, timeout) do
    with {:ok, _project_pid} <- Engine.whereis_project(project_id) do
      ProjectServer.conversation_internal_call(
        Naming.via(project_id, :project_server),
        conversation_id,
        signal,
        timeout
      )
    end
  end
end
