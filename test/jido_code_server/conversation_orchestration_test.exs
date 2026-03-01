defmodule Jido.Code.Server.ConversationOrchestrationTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

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

  test "orchestrated user message emits llm lifecycle and assistant response events" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase6-basic",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase6-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase6-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase6-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "hello"}
             })

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase6-c1", fn events ->
               types = event_types(events)

               Enum.all?(
                 [
                   "conversation.user.message",
                   "conversation.llm.requested",
                   "conversation.assistant.delta",
                   "conversation.assistant.message",
                   "conversation.llm.completed",
                   "conversation.run.opened",
                   "conversation.run.closed"
                 ],
                 &(&1 in types)
               )
             end)

    types = event_types(timeline)
    assert "conversation.user.message" in types
    assert "conversation.llm.requested" in types
    assert "conversation.assistant.delta" in types
    assert "conversation.assistant.message" in types
    assert "conversation.llm.completed" in types
    assert "conversation.run.opened" in types
    assert "conversation.run.closed" in types
  end

  test "strategy execution failures are re-ingested as canonical llm failure lifecycle events" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-reingest-failure",
               conversation_orchestration: true,
               llm_adapter: :missing_adapter
             )

    assert {:ok, "phase4-reingest-failure-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase4-reingest-failure-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase4-reingest-failure-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "hello"}
             })

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase4-reingest-failure-c1", fn events ->
               types = event_types(events)
               "conversation.llm.failed" in types and "conversation.run.closed" in types
             end)

    failed_event =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.llm.failed"
      end)

    assert failed_event

    assert String.contains?(
             map_lookup(map_lookup(failed_event, :data), :reason),
             "invalid_llm_adapter"
           )

    run_closed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.run.closed"
      end)

    assert run_closed
    assert map_lookup(map_lookup(run_closed, :data), :status) == "failed"
  end

  test "tool requests flow through execution runner and continue conversation after completion" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase6-tools",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase6-tools-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase6-tools-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase6-tools-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "please list skills"}
               }
             )

    assert {:ok, timeline} =
             Runtime.conversation_projection(project_id, "phase6-tools-c1", :timeline)

    types = event_types(timeline)

    assert "conversation.tool.requested" in types
    assert "conversation.tool.completed" in types
    assert "conversation.assistant.message" in types

    llm_requested =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.llm.requested"
      end)

    assert map_lookup(map_lookup(llm_requested, :data), :execution) |> map_lookup(:execution_kind) ==
             "strategy_run"

    assert map_lookup(map_lookup(llm_requested, :data), :execution)
           |> map_lookup(:lifecycle_status) == "requested"

    tool_completed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.tool.completed"
      end)

    tool_execution_kind =
      tool_completed
      |> map_lookup(:data)
      |> map_lookup(:execution)
      |> map_lookup(:execution_kind)

    assert tool_execution_kind in ["tool_run", "command_run", "workflow_run", "subagent_spawn"]

    assert map_lookup(map_lookup(tool_completed, :data), :execution)
           |> map_lookup(:lifecycle_status) == "completed"

    result = map_lookup(tool_completed, :data) |> map_lookup(:result)

    assert map_lookup(result, :status) == :ok

    items =
      result
      |> map_lookup(:result)
      |> map_lookup(:items)
      |> List.wrap()

    assert Enum.any?(items, fn item -> map_lookup(item, :name) == "example_skill" end)

    assert {:ok, []} =
             Runtime.conversation_projection(project_id, "phase6-tools-c1", :pending_tool_calls)
  end

  test "tool failures are captured as events and conversation continues with follow-up response" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase6-tool-failure",
               conversation_orchestration: true,
               llm_adapter: :deterministic,
               allow_tools: ["asset.list"]
             )

    assert {:ok, "phase6-tool-failure-c1"} =
             Runtime.start_conversation(project_id,
               conversation_id: "phase6-tool-failure-c1"
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase6-tool-failure-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{
                   "content" => "run command",
                   "llm" => %{
                     "tool_calls" => [%{"name" => "command.run.example_command", "args" => %{}}]
                   }
                 }
               }
             )

    assert {:ok, timeline} =
             Runtime.conversation_projection(project_id, "phase6-tool-failure-c1", :timeline)

    types = event_types(timeline)
    assert "conversation.tool.failed" in types
    assert "conversation.assistant.message" in types

    tool_failed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.tool.failed"
      end)

    assert map_lookup(tool_failed, :data) |> map_lookup(:name) == "command.run.example_command"
  end

  test "conversation.cancel suppresses orchestration until conversation.resume" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase6-cancel",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase6-cancel-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase6-cancel-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase6-cancel-c1",
               %{
                 "type" => "conversation.cancel"
               }
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase6-cancel-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "ignored"}
               }
             )

    assert {:ok, timeline_before_resume} =
             Runtime.conversation_projection(project_id, "phase6-cancel-c1", :timeline)

    refute "conversation.llm.requested" in event_types(timeline_before_resume)

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase6-cancel-c1",
               %{
                 "type" => "conversation.resume"
               }
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase6-cancel-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "active again"}
               }
             )

    assert {:ok, timeline_after_resume} =
             Runtime.conversation_projection(project_id, "phase6-cancel-c1", :timeline)

    assert "conversation.llm.requested" in event_types(timeline_after_resume)
    assert "conversation.assistant.message" in event_types(timeline_after_resume)
  end

  test "orchestrated command tool calls honor workspace command executor mode" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    command_path = Path.join(root, ".jido/commands/example_command.md")
    File.write!(command_path, valid_workspace_shell_command_markdown())

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase6-command-executor",
               conversation_orchestration: true,
               llm_adapter: :deterministic,
               network_egress_policy: :allow,
               command_executor: :workspace_shell
             )

    assert {:ok, "phase6-command-executor-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase6-command-executor-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase6-command-executor-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{
                   "content" => "run workspace command",
                   "llm" => %{
                     "tool_calls" => [
                       %{
                         "name" => "command.run.example_command",
                         "args" => %{"path" => ".jido/commands/example_command.md"}
                       }
                     ]
                   }
                 }
               }
             )

    assert {:ok, timeline} =
             Runtime.conversation_projection(project_id, "phase6-command-executor-c1", :timeline)

    tool_completed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.tool.completed"
      end)

    assert is_map(tool_completed)

    execution_result =
      tool_completed
      |> map_lookup(:data)
      |> map_lookup(:result)
      |> map_lookup(:result)
      |> map_lookup(:execution)
      |> map_lookup(:result)

    assert map_lookup(execution_result, :executor) == "workspace_shell"
    assert map_lookup(execution_result, :workspace_id) =~ "phase6-command-executor"
    assert map_lookup(execution_result, :output) =~ "workspace-sandbox-ok"
  end

  test "mode templates drive deterministic start continue and terminal transitions" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase5-mode-template-integration",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    scenarios = [
      {:coding, "coding.baseline"},
      {:planning, "planning.artifact.baseline"},
      {:engineering, "engineering.tradeoff.baseline"}
    ]

    Enum.each(scenarios, fn {mode, template_id} ->
      conversation_id = "phase5-template-#{mode}"

      assert {:ok, ^conversation_id} =
               Runtime.start_conversation(project_id,
                 conversation_id: conversation_id,
                 mode: mode
               )

      assert :ok =
               RuntimeSignal.send_signal(
                 project_id,
                 conversation_id,
                 %{
                   "type" => "conversation.user.message",
                   "data" => %{"content" => "please list skills"}
                 }
               )

      assert {:ok, timeline} =
               wait_for_timeline(project_id, conversation_id, fn events ->
                 types = event_types(events)

                 "conversation.run.opened" in types and
                   "conversation.tool.requested" in types and
                   "conversation.tool.completed" in types and
                   "conversation.run.closed" in types and
                   count_type(events, "conversation.llm.requested") >= 2
               end)

      run_opened = find_event(timeline, "conversation.run.opened")
      run_closed = find_last_event(timeline, "conversation.run.closed")

      assert map_lookup(run_opened, :data) |> map_lookup(:mode) == Atom.to_string(mode)

      assert map_lookup(run_opened, :data) |> map_lookup(:pipeline_template_id) == template_id

      assert map_lookup(run_opened, :data) |> map_lookup(:pipeline_template_version) == "1.0.0"

      assert map_lookup(run_closed, :data) |> map_lookup(:mode) == Atom.to_string(mode)
      assert map_lookup(run_closed, :data) |> map_lookup(:status) == "completed"
      assert map_lookup(run_closed, :data) |> map_lookup(:pipeline_template_id) == template_id
      assert map_lookup(run_closed, :data) |> map_lookup(:pipeline_template_version) == "1.0.0"

      assert count_type(timeline, "conversation.llm.requested") >= 2
    end)
  end

  test "duplicate and out-of-order signals keep run lifecycle deterministic" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase5-deterministic-ingestion",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase5-deterministic-c1"} =
             Runtime.start_conversation(project_id,
               conversation_id: "phase5-deterministic-c1"
             )

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-deterministic-c1", %{
               "type" => "conversation.tool.completed",
               "data" => %{"name" => "asset.list"},
               "extensions" => %{"correlation_id" => "phase5-reorder"}
             })

    repeated_user_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "please list skills"},
        source: "/test/phase5",
        extensions: %{"correlation_id" => "phase5-repeat"}
      )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase5-deterministic-c1",
               repeated_user_signal
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase5-deterministic-c1",
               repeated_user_signal
             )

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase5-deterministic-c1", fn events ->
               types = event_types(events)

               "conversation.run.closed" in types and
                 count_type(events, "conversation.user.message") == 1
             end)

    assert count_type(timeline, "conversation.user.message") == 1
    assert count_type(timeline, "conversation.run.opened") == 1
    assert count_type(timeline, "conversation.run.closed") == 1
    assert count_type(timeline, "conversation.llm.requested") >= 2

    run_closed = find_last_event(timeline, "conversation.run.closed")
    assert map_lookup(run_closed, :data) |> map_lookup(:status) == "completed"
  end

  test "forced mode switch interrupts in-flight strategy with canonical runtime events" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase5-runtime-interrupt",
               conversation_orchestration: false
             )

    assert {:ok, "phase5-runtime-interrupt-c1"} =
             Runtime.start_conversation(project_id,
               conversation_id: "phase5-runtime-interrupt-c1"
             )

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-interrupt-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "open run"},
               "extensions" => %{"correlation_id" => "phase5-interrupt-run"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-interrupt-c1", %{
               "type" => "conversation.llm.requested",
               "data" => %{},
               "extensions" => %{"correlation_id" => "phase5-interrupt-run"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-interrupt-c1", %{
               "type" => "conversation.mode.switch.requested",
               "data" => %{
                 "mode" => "planning",
                 "force" => true,
                 "reason" => "phase5_force_switch"
               },
               "extensions" => %{"correlation_id" => "phase5-interrupt-run"}
             })

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase5-runtime-interrupt-c1", fn events ->
               types = event_types(events)

               "conversation.mode.switch.accepted" in types and
                 "conversation.run.closed" in types and
                 "conversation.run.interrupted" in types
             end)

    run_closed = find_last_event(timeline, "conversation.run.closed")
    interrupted = find_last_event(timeline, "conversation.run.interrupted")

    assert map_lookup(run_closed, :data) |> map_lookup(:status) == "interrupted"
    assert map_lookup(run_closed, :data) |> map_lookup(:reason) == "phase5_force_switch"
    assert map_lookup(run_closed, :data) |> map_lookup(:interruption_kind) == "strategy"
    assert map_lookup(interrupted, :data) |> map_lookup(:reason) == "phase5_force_switch"
  end

  test "resume preconditions and cancel terminalization stay deterministic at runtime" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase5-runtime-resume-cancel",
               conversation_orchestration: false
             )

    assert {:ok, "phase5-runtime-resume-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase5-runtime-resume-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-resume-c1", %{
               "type" => "conversation.resume",
               "extensions" => %{"correlation_id" => "phase5-resume-precondition"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-resume-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "open run"},
               "extensions" => %{"correlation_id" => "phase5-cancel-run"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-resume-c1", %{
               "type" => "conversation.cancel",
               "data" => %{"reason" => "phase5_cancel"},
               "extensions" => %{"correlation_id" => "phase5-cancel-run"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-resume-c1", %{
               "type" => "conversation.resume",
               "extensions" => %{"correlation_id" => "phase5-cancel-run"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-resume-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "after resume"},
               "extensions" => %{"correlation_id" => "phase5-resumed-run"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase5-runtime-resume-c1", %{
               "type" => "conversation.llm.completed",
               "data" => %{},
               "extensions" => %{"correlation_id" => "phase5-resumed-run"}
             })

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase5-runtime-resume-c1", fn events ->
               types = event_types(events)

               "conversation.resume.rejected" in types and
                 "conversation.run.resumed" in types and
                 count_type(events, "conversation.run.closed") >= 2
             end)

    resume_rejected = find_event(timeline, "conversation.resume.rejected")

    assert map_lookup(resume_rejected, :data) |> map_lookup(:reason) == "not_cancelled"

    cancelled_run_closed =
      timeline
      |> Enum.filter(&(map_lookup(&1, :type) == "conversation.run.closed"))
      |> Enum.find(fn event ->
        map_lookup(event, :data) |> map_lookup(:status) == "cancelled"
      end)

    assert is_map(cancelled_run_closed)
    assert map_lookup(cancelled_run_closed, :data) |> map_lookup(:reason) == "phase5_cancel"

    resumed_event = find_last_event(timeline, "conversation.run.resumed")
    assert map_lookup(resumed_event, :data) |> map_lookup(:resume_policy) == "new_run_required"

    last_run_closed = find_last_event(timeline, "conversation.run.closed")
    assert map_lookup(last_run_closed, :data) |> map_lookup(:status) == "completed"
    assert map_lookup(last_run_closed, :data) |> map_lookup(:run_id) == "phase5-resumed-run"
  end

  defp valid_workspace_shell_command_markdown do
    """
    ---
    name: example_command
    description: Example command fixture for workspace-backed command execution
    allowed-tools:
      - asset.list
    ---
    echo workspace-sandbox-ok
    """
  end

  defp event_types(timeline) do
    Enum.map(timeline, fn event -> map_lookup(event, :type) end)
  end

  defp count_type(timeline, type) do
    timeline
    |> Enum.count(&(map_lookup(&1, :type) == type))
  end

  defp find_event(timeline, type) do
    Enum.find(timeline, &(map_lookup(&1, :type) == type))
  end

  defp find_last_event(timeline, type) do
    timeline
    |> Enum.reverse()
    |> Enum.find(&(map_lookup(&1, :type) == type))
  end

  defp map_lookup(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_lookup(_map, _key), do: nil

  defp wait_for_timeline(project_id, conversation_id, predicate, attempts \\ 40)

  defp wait_for_timeline(_project_id, _conversation_id, _predicate, 0),
    do: {:error, :timeline_timeout}

  defp wait_for_timeline(project_id, conversation_id, predicate, attempts) do
    case Runtime.conversation_projection(project_id, conversation_id, :timeline) do
      {:ok, timeline} ->
        if predicate.(timeline) do
          {:ok, timeline}
        else
          Process.sleep(25)
          wait_for_timeline(project_id, conversation_id, predicate, attempts - 1)
        end

      _other ->
        Process.sleep(25)
        wait_for_timeline(project_id, conversation_id, predicate, attempts - 1)
    end
  end
end
