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

defmodule Jido.Code.Server.StrategyRunnerTest.NativePayloadRunner do
  @behaviour Jido.Code.Server.Project.StrategyRunner

  @impl true
  def start(_project_ctx, _envelope, _opts) do
    {:ok,
     %{
       "delta_chunks" => ["Design ", "notes"],
       "tool_calls" => [%{"name" => "asset.list", "args" => %{"type" => "skill"}}],
       "finish_reason" => "tool_calls",
       "provider" => :jido_ai,
       "model" => "claude-3-7-sonnet",
       "result_meta" => %{"provider" => "jido_ai"}
     }}
  end

  @impl true
  def capabilities do
    %{
      streaming?: true,
      tool_calling?: true,
      cancellable?: true,
      supported_strategies: [:code_generation]
    }
  end
end

defmodule Jido.Code.Server.StrategyRunnerTest.FailingRunner do
  @behaviour Jido.Code.Server.Project.StrategyRunner

  @impl true
  def start(_project_ctx, _envelope, _opts) do
    {:error, %{"reason" => "temporary_failure", "retryable" => true}}
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

defmodule Jido.Code.Server.StrategyRunnerTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Project.StrategyRunner
  alias Jido.Code.Server.Project.StrategyRunner.Default, as: DefaultRunner
  alias Jido.Code.Server.Telemetry

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
    assert Enum.any?(result["signals"], &(&1["type"] == "conversation.llm.completed"))
    assert result["execution_ref"] == "custom:planning"
    assert result["result_meta"]["strategy_runner"] == "custom"
  end

  test "run normalizes native payload output into canonical conversation events" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "design"},
        source: "/conversation/c-native",
        extensions: %{"correlation_id" => "corr-native"}
      )

    project_id = "strategy-runner-native-#{System.unique_integer([:positive])}"

    envelope = %{
      conversation_id: "c-native",
      mode: :coding,
      mode_state: %{},
      strategy_type: "code_generation",
      strategy_opts: %{},
      source_signal: source_signal,
      correlation_id: "corr-native",
      cause_id: source_signal.id,
      strategy_runner: Jido.Code.Server.StrategyRunnerTest.NativePayloadRunner
    }

    assert {:ok, result} = StrategyRunner.run(%{project_id: project_id}, envelope)
    assert is_list(result["signals"])

    types = Enum.map(result["signals"], & &1["type"])
    assert "conversation.llm.requested" in types
    assert "conversation.assistant.delta" in types
    assert "conversation.tool.requested" in types
    assert "conversation.llm.completed" in types

    assert Enum.all?(result["signals"], fn signal ->
             get_in(signal, ["meta", "correlation_id"]) == "corr-native"
           end)

    assert Enum.all?(result["signals"], fn signal ->
             get_in(signal, ["extensions", "cause_id"]) == source_signal.id
           end)

    assert Enum.all?(result["signals"], fn signal ->
             is_map(get_in(signal, ["data", "execution"]))
           end)

    tool_requested =
      Enum.find(result["signals"], fn signal ->
        signal["type"] == "conversation.tool.requested"
      end)

    assert get_in(tool_requested, ["data", "tool_call", :name]) == "asset.list"
    assert get_in(tool_requested, ["data", "execution", "execution_kind"]) == "tool_run"
    assert get_in(tool_requested, ["data", "execution", "lifecycle_status"]) == "requested"

    completed =
      Enum.find(result["signals"], fn signal ->
        signal["type"] == "conversation.llm.completed"
      end)

    assert get_in(completed, ["data", "provider"]) == "jido_ai"
    assert get_in(completed, ["data", "model"]) == "claude-3-7-sonnet"
    assert get_in(completed, ["data", "strategy_type"]) == "code_generation"
    assert get_in(completed, ["data", "execution", "execution_kind"]) == "strategy_run"
    assert get_in(completed, ["data", "execution", "lifecycle_status"]) == "completed"
    assert result["result_meta"]["terminal_status"] == "completed"
    assert result["result_meta"]["execution_id"] =~ "execution:strategy_run:"
  end

  test "run normalizes adapter errors with canonical failure signals and telemetry" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "plan"},
        source: "/conversation/c-failing",
        extensions: %{"correlation_id" => "corr-failing"}
      )

    project_id = "strategy-runner-failing-#{System.unique_integer([:positive])}"

    envelope = %{
      conversation_id: "c-failing",
      mode: :planning,
      mode_state: %{},
      strategy_type: "planning",
      strategy_opts: %{},
      source_signal: source_signal,
      correlation_id: "corr-failing",
      cause_id: source_signal.id,
      strategy_runner: Jido.Code.Server.StrategyRunnerTest.FailingRunner
    }

    assert {:error, result} = StrategyRunner.run(%{project_id: project_id}, envelope)
    assert is_list(result["signals"])

    types = Enum.map(result["signals"], & &1["type"])
    assert "conversation.llm.requested" in types
    assert "conversation.llm.failed" in types
    assert result["retryable"] == true
    assert result["result_meta"]["terminal_status"] == "failed"

    failed =
      Enum.find(result["signals"], fn signal ->
        signal["type"] == "conversation.llm.failed"
      end)

    assert get_in(failed, ["data", "reason"]) == "temporary_failure"
    assert get_in(failed, ["extensions", "cause_id"]) == source_signal.id
    assert get_in(failed, ["data", "execution", "lifecycle_status"]) == "failed"
    assert result["result_meta"]["lifecycle_status"] == "failed"

    snapshot = Telemetry.snapshot(project_id)
    assert Map.get(snapshot.event_counts, "conversation.strategy.started", 0) >= 1
    assert Map.get(snapshot.event_counts, "conversation.strategy.failed", 0) >= 1
    assert Map.get(snapshot.event_counts, "conversation.strategy.retryable", 0) >= 1
  end
end
