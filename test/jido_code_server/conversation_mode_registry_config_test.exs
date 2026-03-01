defmodule Jido.Code.Server.ConversationModeRegistryConfigTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Conversation.ExecutionEnvelope
  alias Jido.Code.Server.Conversation.ModeConfig
  alias Jido.Code.Server.Conversation.ModeRegistry
  alias Jido.Code.Server.TestSupport.RuntimeSignal
  alias Jido.Code.Server.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "mode registry exposes built-ins and capability contract" do
    assert {:ok, coding} = ModeRegistry.fetch(:coding, %{})
    assert coding.mode == :coding
    assert is_map(coding.capabilities)
    assert is_map(coding.defaults)

    assert ModeRegistry.allowed_execution_kinds(:planning, %{}) == [:tool_run]
    assert ModeRegistry.allowed_execution_kinds(:engineering, %{}) == :all
  end

  test "mode config resolver applies precedence and validation diagnostics" do
    project_ctx = %{
      conversation_default_mode: :planning,
      conversation_mode_defaults: %{
        planning: %{"max_turn_steps" => 10, "strategy" => "project_defaults"}
      }
    }

    conversation_state = %{
      mode: :planning,
      mode_state: %{"max_turn_steps" => 15}
    }

    assert {:ok, resolved} =
             ModeConfig.resolve(
               [mode: :planning, mode_state: %{"strategy" => "request_override"}],
               conversation_state,
               project_ctx
             )

    assert resolved.mode == :planning
    assert resolved.mode_state["max_turn_steps"] == 15
    assert resolved.mode_state["strategy"] == "request_override"
    assert resolved.diagnostics.mode_source == :request

    assert {:error, diagnostics} =
             ModeConfig.resolve(
               [mode: :planning, mode_state: %{"unknown_option" => true}],
               conversation_state,
               project_ctx
             )

    assert diagnostics.code == :invalid_mode_config

    assert Enum.any?(diagnostics.errors, fn error ->
             error.path == "mode_state.unknown_option" and error.reason == :unknown_option
           end)
  end

  test "execution envelope maps reducer intents to normalized execution kinds" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "hello"},
        source: "/conversation/test",
        extensions: %{"correlation_id" => "corr-envelope"}
      )

    assert {:ok, llm_envelope} =
             ExecutionEnvelope.from_intent(
               %{
                 kind: :run_execution,
                 execution_kind: :strategy_run,
                 source_signal: source_signal
               },
               mode: :planning,
               mode_state: %{"strategy" => "planning"}
             )

    assert llm_envelope.execution_kind == :strategy_run
    assert llm_envelope.strategy_type == "planning"
    assert llm_envelope.strategy_opts == %{}
    assert llm_envelope.correlation_id == "corr-envelope"
    assert llm_envelope.cause_id == source_signal.id
    assert is_binary(llm_envelope.execution_id)
    assert llm_envelope.execution_id =~ "execution:strategy_run:"
    assert llm_envelope.run_id == "corr-envelope"
    assert llm_envelope.step_id =~ ":strategy:"

    assert {:ok, tool_envelope} =
             ExecutionEnvelope.from_intent(
               %{
                 kind: :run_tool,
                 source_signal: source_signal,
                 tool_call: %{
                   "name" => "command.run.example_command",
                   "args" => %{},
                   "meta" => %{}
                 }
               },
               mode: :coding
             )

    assert tool_envelope.execution_kind == :command_run
    assert tool_envelope.name == "command.run.example_command"
    assert tool_envelope.correlation_id == "corr-envelope"
    assert is_binary(tool_envelope.execution_id)
    assert tool_envelope.execution_id =~ "execution:command_run:"

    assert {:ok, strategy_with_pipeline} =
             ExecutionEnvelope.from_intent(
               %{
                 kind: :run_execution,
                 execution_kind: :strategy_run,
                 source_signal: source_signal,
                 meta: %{"pipeline" => %{"step_index" => 2, "reason" => "continue"}}
               },
               mode: :planning,
               mode_state: %{"strategy" => "planning"}
             )

    assert get_in(strategy_with_pipeline, [:meta, "pipeline", "step_index"]) == 2
    assert get_in(strategy_with_pipeline, [:meta, "pipeline", "reason"]) == "continue"

    assert get_in(strategy_with_pipeline, [:meta, "pipeline", "step_id"]) ==
             strategy_with_pipeline.step_id

    assert {:ok, cancel_strategy_envelope} =
             ExecutionEnvelope.from_intent(
               %{
                 kind: :cancel_active_strategy,
                 run_id: "corr-envelope",
                 step_id: "corr-envelope:strategy:2",
                 strategy_type: "planning",
                 mode: "planning",
                 correlation_id: "corr-envelope",
                 reason: "conversation_cancelled",
                 source_signal: source_signal
               },
               mode: :planning,
               mode_state: %{"strategy" => "planning"}
             )

    assert cancel_strategy_envelope.execution_kind == :cancel_strategy
    assert cancel_strategy_envelope.run_id == "corr-envelope"
    assert cancel_strategy_envelope.step_id == "corr-envelope:strategy:2"
    assert cancel_strategy_envelope.strategy_type == "planning"
    assert cancel_strategy_envelope.mode == :planning
    assert get_in(cancel_strategy_envelope, [:args, "reason"]) == "conversation_cancelled"
  end

  test "planning mode keeps asset tools exposed and rejects command tools for LLM turns" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase3-mode-llm-tools",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase3-mode-c1"} =
             Runtime.start_conversation(project_id,
               conversation_id: "phase3-mode-c1",
               mode: :planning
             )

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-mode-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "please list skills"}
             })

    assert {:ok, timeline_after_list} =
             Runtime.conversation_projection(project_id, "phase3-mode-c1", :timeline)

    completed_tool =
      Enum.find(timeline_after_list, fn event ->
        map_lookup(event, :type) == "conversation.tool.completed"
      end)

    assert map_lookup(completed_tool, :data) |> map_lookup(:name) == "asset.list"

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-mode-c1", %{
               "type" => "conversation.user.message",
               "data" => %{
                 "content" => "run command",
                 "llm" => %{
                   "tool_calls" => [%{"name" => "command.run.example_command", "args" => %{}}]
                 }
               }
             })

    assert {:ok, timeline_after_reject} =
             Runtime.conversation_projection(project_id, "phase3-mode-c1", :timeline)

    rejected_tool =
      timeline_after_reject
      |> Enum.reverse()
      |> Enum.find(fn event ->
        map_lookup(event, :type) == "conversation.tool.failed" and
          map_lookup(event, :data) |> map_lookup(:name) == "command.run.example_command"
      end)

    assert map_lookup(rejected_tool, :data) |> map_lookup(:reason) |> map_lookup(:code) ==
             "tool_not_exposed"
  end

  defp map_lookup(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_lookup(_map, _key), do: nil
end
