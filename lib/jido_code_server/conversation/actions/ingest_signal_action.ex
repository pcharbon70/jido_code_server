defmodule Jido.Code.Server.Conversation.Actions.IngestSignalAction do
  @moduledoc """
  Ingests a canonical signal into conversation domain queue and drains intents.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_ingest_signal",
    schema: []

  alias Jido.Code.Server.Conversation.Actions.Support
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, signal} <- extract_signal(params),
         {:ok, domain, state_map} <- Support.current_domain(context),
         {domain, directives} <- Support.ingest_and_drain(domain, signal, state_map) do
      {:ok, %{domain: domain}, directives}
    end
  end

  defp extract_signal(params) do
    params
    |> Map.get(:signal, Map.get(params, "signal"))
    |> ConversationSignal.normalize()
  end
end
