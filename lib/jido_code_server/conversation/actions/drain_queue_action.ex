defmodule Jido.Code.Server.Conversation.Actions.DrainQueueAction do
  @moduledoc """
  Drains the conversation domain queue and emits directives for side-effects.
  """

  use Jido.Action,
    name: "jido_code_server_conversation_drain_queue",
    schema: []

  alias Jido.Code.Server.Conversation.Actions.Support

  @impl true
  def run(_params, context) when is_map(context) do
    with {:ok, domain, state_map} <- Support.current_domain(context),
         {domain, directives} <- Support.drain(domain, state_map) do
      {:ok, %{domain: domain}, directives}
    end
  end
end
