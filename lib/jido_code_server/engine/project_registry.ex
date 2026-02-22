defmodule JidoCodeServer.Engine.ProjectRegistry do
  @moduledoc """
  Registry wrapper for project process lookup.
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    Registry.child_spec(Keyword.merge([keys: :unique, name: __MODULE__], opts))
  end
end
