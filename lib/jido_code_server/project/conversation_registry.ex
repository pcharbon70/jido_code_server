defmodule JidoCodeServer.Project.ConversationRegistry do
  @moduledoc """
  Project-local conversation registry placeholder.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    Registry.child_spec(Keyword.merge([keys: :unique, name: __MODULE__], opts))
  end
end
