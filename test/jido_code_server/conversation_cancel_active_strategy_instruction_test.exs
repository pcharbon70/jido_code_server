defmodule Jido.Code.Server.ConversationCancelActiveStrategyInstructionTest.CancellableRunner do
  @behaviour Jido.Code.Server.Project.StrategyRunner

  @impl true
  def start(_project_ctx, _envelope, _opts) do
    {:ok, %{"signals" => [], "result_meta" => %{}, "execution_ref" => "noop"}}
  end

  @impl true
  def cancel(_project_ctx, envelope, _opts) do
    send(self(), {:cancel_called, envelope.run_id, envelope.step_id, envelope.strategy_type})
    :ok
  end

  @impl true
  def capabilities do
    %{
      streaming?: false,
      tool_calling?: true,
      cancellable?: true,
      supported_strategies: [:planning]
    }
  end
end

defmodule Jido.Code.Server.ConversationCancelActiveStrategyInstructionTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.Instructions.CancelActiveStrategyInstruction

  test "delegates cancellation through execution runner and emits canonical signal" do
    params = %{
      "run_id" => "run-cancel-2",
      "step_id" => "run-cancel-2:strategy:1",
      "strategy_type" => "planning",
      "mode" => "planning",
      "reason" => "conversation_cancelled",
      "correlation_id" => "corr-cancel-2",
      "cause_id" => "cause-cancel-2"
    }

    context = %{
      "conversation_id" => "c-cancel-2",
      "project_ctx" => %{
        project_id: "p-cancel-2",
        strategy_runner_registry: %{
          "planning" =>
            Jido.Code.Server.ConversationCancelActiveStrategyInstructionTest.CancellableRunner
        }
      }
    }

    assert {:ok, %{"signals" => [signal]}} = CancelActiveStrategyInstruction.run(params, context)
    assert_receive {:cancel_called, "run-cancel-2", "run-cancel-2:strategy:1", "planning"}

    assert signal["type"] == "conversation.strategy.cancelled"
    assert get_in(signal, ["data", "run_id"]) == "run-cancel-2"
    assert get_in(signal, ["data", "step_id"]) == "run-cancel-2:strategy:1"
    assert get_in(signal, ["data", "strategy_type"]) == "planning"
    assert get_in(signal, ["data", "mode"]) == "planning"
    assert get_in(signal, ["data", "reason"]) == "conversation_cancelled"
    assert get_in(signal, ["meta", "correlation_id"]) == "corr-cancel-2"
    assert get_in(signal, ["extensions", "cause_id"]) == "cause-cancel-2"
  end
end
