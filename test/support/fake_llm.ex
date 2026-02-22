defmodule Jido.Code.Server.TestSupport.FakeLLM do
  @moduledoc """
  Minimal fake LLM adapter that returns deterministic completions for tests.
  """

  @spec complete(map()) :: {:ok, map()}
  def complete(request) do
    {:ok,
     %{
       id: "fake-completion",
       model: Map.get(request, :model, "fake-model"),
       text: "fake-response",
       tool_calls: []
     }}
  end
end
