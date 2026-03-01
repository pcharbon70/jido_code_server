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
    assert get_in(start_intent, [:meta, "pipeline", "template_id"]) == "coding.baseline"
    assert get_in(start_intent, [:meta, "pipeline", "template_version"]) == "1.0.0"
    assert get_in(start_intent, [:meta, "pipeline", "output_profile"]) == "code_changes"
    assert "strategy:code_generation" in get_in(start_intent, [:meta, "pipeline", "step_chain"])
    assert "strategy.override" in get_in(start_intent, [:meta, "pipeline", "extension_points"])
    assert state.active_run.run_id == "planner-run-1"
    assert state.active_run.pipeline_template_id == "coding.baseline"
    assert state.active_run.pipeline_template_version == "1.0.0"

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
    assert get_in(retry_intent, [:meta, "pipeline", "retry_count"]) == 0
    assert get_in(retry_intent, [:meta, "pipeline", "max_retries"]) == 1
    assert get_in(retry_intent, [:meta, "pipeline", "retry_attempt"]) == 1
    assert get_in(retry_intent, [:meta, "pipeline", "retry_backoff_ms"]) == 250
    assert get_in(retry_intent, [:meta, "pipeline", "retry_policy", "strategy"]) == "exponential"
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

  test "retry metadata honors configured retry backoff policy bounds" do
    state =
      State.new(
        project_id: "planner-p3b",
        conversation_id: "planner-c3b",
        orchestration_enabled: true,
        mode_state: %{
          "max_retries" => 3,
          "retry_backoff_base_ms" => 100,
          "retry_backoff_max_ms" => 250
        }
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "hello"}, "planner-run-3b")
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "planner-run-3b"))

    # first retry
    {state, intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.llm.failed",
          %{"reason" => "timeout", "retryable" => true},
          "planner-run-3b"
        )
      )

    first_retry =
      Enum.find(intents, fn intent ->
        intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
      end)

    assert first_retry
    assert get_in(first_retry, [:meta, "pipeline", "retry_backoff_ms"]) == 100

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "planner-run-3b"))

    # second retry
    {state, intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.llm.failed",
          %{"reason" => "timeout", "retryable" => true},
          "planner-run-3b"
        )
      )

    second_retry =
      Enum.find(intents, fn intent ->
        intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
      end)

    assert second_retry
    assert get_in(second_retry, [:meta, "pipeline", "retry_backoff_ms"]) == 200

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "planner-run-3b"))

    # third retry should cap at max backoff.
    {_state, intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.llm.failed",
          %{"reason" => "timeout", "retryable" => true},
          "planner-run-3b"
        )
      )

    third_retry =
      Enum.find(intents, fn intent ->
        intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
      end)

    assert third_retry
    assert get_in(third_retry, [:meta, "pipeline", "retry_backoff_ms"]) == 250
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

  test "planning and engineering modes emit distinct baseline pipeline templates" do
    scenarios = [
      {:planning, "planning.artifact.baseline", "structured_artifact", "strategy:planning"},
      {:engineering, "engineering.tradeoff.baseline", "tradeoff_analysis",
       "strategy:engineering_design"}
    ]

    for {mode, template_id, output_profile, chain_step} <- scenarios do
      state =
        State.new(
          project_id: "planner-mode-#{mode}",
          conversation_id: "planner-mode-c-#{mode}",
          orchestration_enabled: true,
          mode: mode
        )

      {state, intents} =
        Reducer.apply_signal(
          state,
          signal("conversation.user.message", %{"content" => "hello"}, "planner-run-#{mode}")
        )

      start_intent =
        Enum.find(intents, fn intent ->
          intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
        end)

      assert start_intent
      assert get_in(start_intent, [:meta, "pipeline", "mode"]) == Atom.to_string(mode)
      assert get_in(start_intent, [:meta, "pipeline", "template_id"]) == template_id
      assert get_in(start_intent, [:meta, "pipeline", "template_version"]) == "1.0.0"
      assert get_in(start_intent, [:meta, "pipeline", "output_profile"]) == output_profile
      assert chain_step in get_in(start_intent, [:meta, "pipeline", "step_chain"])

      assert "conversation.llm.completed" in get_in(start_intent, [
               :meta,
               "pipeline",
               "terminal_signals",
               "completed"
             ])

      assert "conversation.llm.failed" in get_in(start_intent, [
               :meta,
               "pipeline",
               "terminal_signals",
               "failed"
             ])

      assert state.active_run.pipeline_template_id == template_id
      assert state.active_run.pipeline_template_version == "1.0.0"
    end
  end

  test "mode_state can override shared template extension points and version tags" do
    state =
      State.new(
        project_id: "planner-p6",
        conversation_id: "planner-c6",
        orchestration_enabled: true,
        mode: :planning,
        mode_state: %{
          "pipeline_template_version" => "2.2.0",
          "pipeline_extension_points" => ["artifact.schema.custom", "artifact.sections.custom"]
        }
      )

    {_state, intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "draft a plan"}, "planner-run-6")
      )

    start_intent =
      Enum.find(intents, fn intent ->
        intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
      end)

    assert start_intent

    assert get_in(start_intent, [:meta, "pipeline", "template_id"]) ==
             "planning.artifact.baseline"

    assert get_in(start_intent, [:meta, "pipeline", "template_version"]) == "2.2.0"

    assert get_in(start_intent, [:meta, "pipeline", "extension_points"]) == [
             "artifact.schema.custom",
             "artifact.sections.custom"
           ]
  end

  defp signal(type, data, correlation_id) do
    ConversationSignal.normalize!(%{
      "type" => type,
      "data" => data,
      "extensions" => %{"correlation_id" => correlation_id}
    })
  end
end
