defmodule Jido.Code.Server.StrategyRunnerTest.CustomRunner do
  @behaviour Jido.Code.Server.Project.StrategyRunner

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @impl true
  def start(_project_ctx, envelope, _opts) do
    signal =
      Jido.Signal.new!("conversation.assistant.message", %{
        "content" => "strategy runner response",
        "strategy" => envelope.strategy_type
      })

    {:ok,
     %{
       "signals" => [ConversationSignal.to_map(signal)],
       "result_meta" => %{"strategy_runner" => "custom"},
       "execution_ref" => "custom:#{envelope.strategy_type}"
     }}
  end

  @impl true
  def capabilities do
    %{
      streaming?: false,
      tool_calling?: true,
      cancellable?: true,
      supported_strategies: [:planning, :reasoning]
    }
  end
end

defmodule Jido.Code.Server.StrategyRunnerTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Project.StrategyRunner
  alias Jido.Code.Server.Project.StrategyRunner.Default, as: DefaultRunner

  test "prepare resolves default strategy per mode" do
    envelope = %{
      mode: :planning,
      mode_state: %{},
      strategy_opts: %{}
    }

    assert {:ok, prepared} = StrategyRunner.prepare(%{}, envelope)
    assert prepared.mode == :planning
    assert prepared.strategy_type == "planning"
    assert prepared.strategy_runner == DefaultRunner
  end

  test "prepare prefers request strategy over runtime defaults" do
    project_ctx = %{
      strategy_defaults: %{planning: "planning"},
      conversation_mode_defaults: %{planning: %{"strategy" => "planning"}}
    }

    envelope = %{
      mode: :planning,
      mode_state: %{"strategy" => "planning"},
      strategy_type: "reasoning",
      strategy_opts: %{}
    }

    assert {:ok, prepared} = StrategyRunner.prepare(project_ctx, envelope)
    assert prepared.strategy_type == "reasoning"
  end

  test "prepare rejects unsupported strategy for mode" do
    envelope = %{
      mode: :planning,
      mode_state: %{},
      strategy_type: "engineering_design",
      strategy_opts: %{}
    }

    assert {:error, {:unsupported_strategy_for_mode, :planning, "engineering_design"}} =
             StrategyRunner.prepare(%{}, envelope)
  end

  test "prepare resolves runner from strategy registry and run delegates to it" do
    project_ctx = %{
      strategy_runner_registry: %{"planning" => Jido.Code.Server.StrategyRunnerTest.CustomRunner}
    }

    envelope = %{
      mode: :planning,
      mode_state: %{},
      strategy_opts: %{}
    }

    assert {:ok, prepared} = StrategyRunner.prepare(project_ctx, envelope)
    assert prepared.strategy_runner == Jido.Code.Server.StrategyRunnerTest.CustomRunner

    assert {:ok, result} = StrategyRunner.run(project_ctx, prepared)
    assert is_list(result["signals"])
    assert result["execution_ref"] == "custom:planning"
    assert result["result_meta"]["strategy_runner"] == "custom"
  end
end
