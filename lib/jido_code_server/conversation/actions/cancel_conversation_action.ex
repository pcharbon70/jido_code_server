defmodule Jido.Code.Server.Conversation.Actions.CancelConversationAction do
  @moduledoc """
  Cancels conversation by ingesting canonical `conversation.cancel` signal.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_cancel",
    schema: []

  alias Jido.Code.Server.Conversation.Actions.Support

  @impl true
  def run(params, context) when is_map(params) and is_map(context) do
    with {:ok, domain, state_map} <- Support.current_domain(context),
         signal <- cancel_signal(domain, params),
         {domain, directives} <- Support.ingest_and_drain(domain, signal, state_map) do
      {:ok, %{domain: domain}, directives}
    end
  end

  defp cancel_signal(domain, params) do
    reason = params[:reason] || params["reason"] || "cancelled"

    Jido.Signal.new!("conversation.cancel", %{"reason" => reason},
      source: "/project/#{domain.project_id}/conversation/#{domain.conversation_id}"
    )
  end
end
