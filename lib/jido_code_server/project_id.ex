defmodule JidoCodeServer.ProjectId do
  @moduledoc """
  Generates project identifiers for runtime project instances.
  """

  @spec generate() :: String.t()
  def generate do
    "project_" <> Integer.to_string(System.unique_integer([:positive]))
  end
end
