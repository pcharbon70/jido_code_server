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
    with {:ok, signal} <- normalize_test_signal(raw_signal),
         {:ok, _snapshot} <- dispatch_signal(project_id, conversation_id, signal, timeout) do
      :ok
    end
  end

  defp normalize_test_signal(%Jido.Signal{} = signal), do: ConversationSignal.normalize(signal)

  defp normalize_test_signal(raw_signal) when is_map(raw_signal) do
    raw_signal
    |> ensure_data_envelope()
    |> ConversationSignal.normalize()
  end

  defp normalize_test_signal(raw_signal), do: ConversationSignal.normalize(raw_signal)

  defp ensure_data_envelope(raw_signal) do
    case raw_signal[:data] || raw_signal["data"] do
      data when is_map(data) ->
        raw_signal

      _other ->
        payload = build_payload(raw_signal)
        put_payload(raw_signal, payload)
    end
  end

  defp build_payload(raw_signal) do
    raw_signal
    |> Map.drop([
      :id,
      "id",
      :type,
      "type",
      :source,
      "source",
      :time,
      "time",
      :meta,
      "meta",
      :extensions,
      "extensions",
      :data,
      "data",
      :specversion,
      "specversion"
    ])
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_payload_key(key), value)
    end)
  end

  defp normalize_payload_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_payload_key(key), do: key

  defp put_payload(%{data: _} = raw_signal, payload), do: Map.put(raw_signal, :data, payload)
  defp put_payload(raw_signal, payload), do: Map.put(raw_signal, "data", payload)

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
