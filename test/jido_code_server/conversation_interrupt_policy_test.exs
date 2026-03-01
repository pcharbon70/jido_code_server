defmodule Jido.Code.Server.ConversationInterruptPolicyTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.Domain.Reducer
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  test "cancel propagates explicit reason and cause metadata for in-flight tool steps" do
    state =
      State.new(
        project_id: "interrupt-p1",
        conversation_id: "interrupt-c1",
        orchestration_enabled: true
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "start"}, "run-1")
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "run-1"))

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.tool.requested",
          %{"tool_call" => %{"name" => "asset.list", "id" => "tool-1", "args" => %{}}},
          "run-1"
        )
      )

    cancel_signal = signal("conversation.cancel", %{"reason" => "operator_cancel"}, "run-1")
    {state, intents} = Reducer.apply_signal(state, cancel_signal)

    assert state.active_run == nil
    assert [latest_run | _rest] = state.run_history
    assert latest_run.status == :cancelled
    assert latest_run.reason == "operator_cancel"
    assert latest_run.interruption_kind == "tool"
    assert latest_run.cause_signal_type == "conversation.cancel"
    assert latest_run.cause_signal_id == cancel_signal.id

    cancel_intent = Enum.find(intents, &(&1[:kind] == :cancel_pending_tools))
    assert cancel_intent
    assert cancel_intent.reason == "operator_cancel"
    assert cancel_intent.source_signal.id == cancel_signal.id

    closed_signal = emitted_signal(intents, "conversation.run.closed")
    assert closed_signal.data["reason"] == "operator_cancel"
    assert closed_signal.data["interruption_kind"] == "tool"
    assert closed_signal.extensions["cause_id"] == cancel_signal.id
  end

  test "forced mode switch marks strategy interruption and propagates cause links" do
    state =
      State.new(
        project_id: "interrupt-p2",
        conversation_id: "interrupt-c2",
        orchestration_enabled: true
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "start strategy"}, "run-2")
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "run-2"))

    switch_signal =
      signal(
        "conversation.mode.switch.requested",
        %{"mode" => "planning", "force" => true, "reason" => "operator_switch"},
        "run-2"
      )

    {state, intents} = Reducer.apply_signal(state, switch_signal)

    assert state.mode == :planning
    assert state.active_run == nil
    assert [latest_run | _rest] = state.run_history
    assert latest_run.status == :interrupted
    assert latest_run.reason == "operator_switch"
    assert latest_run.interruption_kind == "strategy"
    assert latest_run.cause_signal_type == "conversation.mode.switch.requested"
    assert latest_run.cause_signal_id == switch_signal.id

    interrupted_signal = emitted_signal(intents, "conversation.run.interrupted")
    assert interrupted_signal.data["reason"] == "operator_switch"
    assert interrupted_signal.data["interruption_kind"] == "strategy"
    assert interrupted_signal.extensions["cause_id"] == switch_signal.id
  end

  test "resume when not cancelled is rejected with deterministic taxonomy reason" do
    state = State.new(project_id: "interrupt-p3", conversation_id: "interrupt-c3")
    resume_signal = signal("conversation.resume", %{}, "resume-1")

    {state, intents} = Reducer.apply_signal(state, resume_signal)

    assert state.status == :idle
    refute Enum.any?(intents, &(signal_type(&1) == "conversation.run.resumed"))

    rejected_signal = emitted_signal(intents, "conversation.resume.rejected")
    assert rejected_signal.data["reason"] == "not_cancelled"
    assert rejected_signal.data["status"] == "idle"
    assert rejected_signal.data["active_run"] == false
    assert rejected_signal.extensions["cause_id"] == resume_signal.id
  end

  test "stale tool terminal events after cancel and resume do not replay strategy execution" do
    state =
      State.new(
        project_id: "interrupt-p4",
        conversation_id: "interrupt-c4",
        orchestration_enabled: true
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.user.message", %{"content" => "start"}, "run-3")
      )

    {state, _intents} =
      Reducer.apply_signal(state, signal("conversation.llm.requested", %{}, "run-3"))

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal(
          "conversation.tool.requested",
          %{"tool_call" => %{"name" => "asset.list", "id" => "tool-3", "args" => %{}}},
          "run-3"
        )
      )

    {state, _intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.cancel", %{"reason" => "conversation_cancelled"}, "run-3")
      )

    {state, _intents} = Reducer.apply_signal(state, signal("conversation.resume", %{}, "run-3"))

    {state, intents} =
      Reducer.apply_signal(
        state,
        signal("conversation.tool.completed", %{"name" => "asset.list"}, "run-3")
      )

    assert state.active_run == nil
    assert state.pending_steps == []

    refute Enum.any?(intents, fn intent ->
             intent[:kind] == :run_execution and intent[:execution_kind] == :strategy_run
           end)
  end

  defp signal(type, data, correlation_id) do
    ConversationSignal.normalize!(%{
      "type" => type,
      "data" => data,
      "extensions" => %{"correlation_id" => correlation_id}
    })
  end

  defp emitted_signal(intents, type) do
    intents
    |> Enum.find(fn intent ->
      intent[:kind] == :emit_signal and signal_type(intent) == type
    end)
    |> map_get(:signal)
  end

  defp signal_type(intent) do
    intent
    |> map_get(:signal)
    |> map_get(:type)
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, to_existing_atom(key))
  end

  defp map_get(_map, _key), do: nil

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
