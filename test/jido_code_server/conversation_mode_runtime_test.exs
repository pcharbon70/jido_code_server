defmodule Jido.Code.Server.ConversationModeRuntimeTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.Domain.ModeRun
  alias Jido.Code.Server.Conversation.Domain.Projections
  alias Jido.Code.Server.Conversation.Domain.Reducer
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  test "state initializes mode runtime defaults" do
    state = State.new(project_id: "mode-p1", conversation_id: "mode-c1")

    assert state.mode == :coding
    assert state.mode_state == %{}
    assert state.active_run == nil
    assert state.run_history == []
    assert state.pending_steps == []
    assert state.max_run_history == 25

    mode_runtime = state.projection_cache[:mode_runtime]
    assert mode_runtime.mode == :coding
    assert mode_runtime.run_history_count == 0
    assert mode_runtime.pending_step_count == 0
  end

  test "mode run transition matrix enforces valid transitions" do
    assert ModeRun.valid_transition?(nil, :running)
    assert ModeRun.valid_transition?(:running, :completed)
    assert ModeRun.valid_transition?(:running, :failed)
    refute ModeRun.valid_transition?(:completed, :running)
    refute ModeRun.valid_transition?(:cancelled, :running)
  end

  test "reducer starts and completes a mode run from conversation lifecycle events" do
    state = State.new(project_id: "mode-p2", conversation_id: "mode-c2")

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "hello"}, "run-1")
      )

    assert state.active_run.status == :running
    assert state.active_run.mode == :coding
    assert state.active_run.run_id == "run-1"

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.completed", %{}, "run-1"))

    assert state.active_run == nil
    assert [%{status: :completed, run_id: "run-1"}] = state.run_history
  end

  test "reducer tracks pending steps from requested/completed tool lifecycle" do
    state = State.new(project_id: "mode-p3", conversation_id: "mode-c3")

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "hello"}, "run-step")
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.tool.requested",
          %{"tool_call" => %{"name" => "asset.list", "args" => %{"type" => "skill"}}},
          "step-1"
        )
      )

    assert length(state.pending_steps) == 1
    assert hd(state.pending_steps).name == "asset.list"

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.tool.completed", %{"name" => "asset.list"}, "step-1")
      )

    assert state.pending_steps == []
  end

  test "run history is bounded and mode projection redacts mode state values" do
    state =
      State.new(
        project_id: "mode-p4",
        conversation_id: "mode-c4",
        max_run_history: 2,
        mode_state: %{"objective" => "ship", "prompt" => "secret prompt text"}
      )

    state =
      ["run-a", "run-b", "run-c"]
      |> Enum.reduce(state, fn run_id, acc -> complete_run(acc, run_id) end)

    assert length(state.run_history) == 2
    assert Enum.map(state.run_history, & &1.run_id) == ["run-c", "run-b"]

    mode_runtime = Projections.mode_runtime(state)

    assert mode_runtime.mode_state == %{key_count: 2, keys: ["objective", "prompt"]}
    refute inspect(mode_runtime) =~ "secret prompt text"
  end

  defp complete_run(state, run_id) do
    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => run_id}, run_id)
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.completed", %{}, run_id))

    state
  end

  defp signal(type, data, correlation_id) do
    ConversationSignal.normalize!(%{
      "type" => type,
      "data" => data,
      "extensions" => %{"correlation_id" => correlation_id}
    })
  end
end
