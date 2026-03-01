defmodule Jido.Code.Server.ConversationStepPlannerTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.Domain.Reducer
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  test "planner emits strategy start intent only when opening a new run" do
    state =
      State.new(
        project_id: "planner-p1",
        conversation_id: "planner-c1",
        orchestration_enabled: true
      )

    {state, intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "hello"}, "planner-run-1")
      )

    start_intent =
      Enum.find(intents, fn intent ->
        intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
      end)

    assert start_intent
    assert get_in(start_intent, [:meta, "pipeline", "reason"]) == "start"
    assert get_in(start_intent, [:meta, "pipeline", "step_index"]) == 1
    assert state.active_run.run_id == "planner-run-1"

    {_state, intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "second"}, "planner-run-2")
      )

    refute Enum.any?(intents, fn intent ->
             intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
           end)
  end

  test "planner emits continue intent after tool terminal event for active run" do
    state =
      State.new(
        project_id: "planner-p2",
        conversation_id: "planner-c2",
        orchestration_enabled: true
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "hello"}, "planner-run-2")
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "planner-run-2"))

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.tool.requested",
          %{"tool_call" => %{"name" => "asset.list", "args" => %{"type" => "skill"}}},
          "planner-run-2"
        )
      )

    assert state.pending_tool_calls != []
    assert state.pending_steps != []

    {state, intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.tool.completed", %{"name" => "asset.list"}, "planner-run-2")
      )

    continue_intent =
      Enum.find(intents, fn intent ->
        intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
      end)

    assert continue_intent
    assert get_in(continue_intent, [:meta, "pipeline", "reason"]) == "continue"
    assert state.pending_tool_calls == []
    assert state.pending_steps == []
  end

  test "retryable llm failures trigger retry planning until retry limit is reached" do
    state =
      State.new(
        project_id: "planner-p3",
        conversation_id: "planner-c3",
        orchestration_enabled: true,
        mode_state: %{"max_retries" => 1}
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "hello"}, "planner-run-3")
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "planner-run-3"))

    {state, intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.llm.failed",
          %{"reason" => "timeout", "retryable" => true},
          "planner-run-3"
        )
      )

    retry_intent =
      Enum.find(intents, fn intent ->
        intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
      end)

    assert retry_intent
    assert get_in(retry_intent, [:meta, "pipeline", "reason"]) == "retry"
    assert state.active_run.retry_count == 0
    assert state.active_run.pending_retry == true

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "planner-run-3"))

    assert state.active_run.retry_count == 1
    assert state.active_run.pending_retry == false

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.llm.failed",
          %{"reason" => "timeout", "retryable" => true},
          "planner-run-3"
        )
      )

    assert state.active_run == nil
    assert [%{status: :failed}] = state.run_history
  end

  test "max turn-step guardrail emits canonical llm.failed signal intent" do
    state =
      State.new(
        project_id: "planner-p4",
        conversation_id: "planner-c4",
        orchestration_enabled: true,
        mode_state: %{"max_turn_steps" => 1}
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "hello"}, "planner-run-4")
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "planner-run-4"))

    {_state, intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.tool.completed", %{"name" => "asset.list"}, "planner-run-4")
      )

    guardrail_intent =
      Enum.find(intents, fn intent ->
        intent[:kind] == :emit_signal and match?(%Jido.Signal{}, intent[:signal])
      end)

    assert guardrail_intent
    assert guardrail_intent.signal.type == "conversation.llm.failed"
    assert guardrail_intent.signal.data["reason"] == "max_turn_steps_exceeded"

    refute Enum.any?(intents, fn intent ->
             intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
           end)
  end

  test "pending tool steps include index, predecessor, and retry contract fields" do
    state =
      State.new(
        project_id: "planner-p5",
        conversation_id: "planner-c5",
        orchestration_enabled: true
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "hello"}, "planner-run-5")
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "planner-run-5"))

    strategy_step_id = state.active_run.current_step_id
    assert is_binary(strategy_step_id)

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.tool.requested",
          %{"tool_call" => %{"name" => "asset.list", "id" => "tc-1", "args" => %{}}},
          "planner-run-5"
        )
      )

    assert [step] = state.pending_steps
    assert step.step_index == 2
    assert step.predecessor_step_id == strategy_step_id
    assert step.retry_count == 0
    assert step.max_retries == 1
    assert step.tool_call_id == "tc-1"
    assert step.requested_by_signal_id
  end

  defp signal(type, data, correlation_id) do
    ConversationSignal.normalize!(%{
      "type" => type,
      "data" => data,
      "extensions" => %{"correlation_id" => correlation_id}
    })
  end
end
