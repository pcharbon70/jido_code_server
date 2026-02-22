defmodule JidoCodeServer.Telemetry do
  @moduledoc """
  Telemetry facade placeholder for runtime signal emission.
  """

  @spec emit(String.t(), map()) :: :ok
  def emit(_name, _payload), do: :ok
end
