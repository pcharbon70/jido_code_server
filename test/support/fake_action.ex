defmodule JidoCodeServer.TestSupport.FakeAction do
  @moduledoc """
  Minimal fake tool action adapter used by unit tests.
  """

  @spec run(map(), map()) :: {:ok, map()}
  def run(args, ctx \\ %{}) do
    {:ok, %{ok: true, args: args, ctx: ctx}}
  end
end
