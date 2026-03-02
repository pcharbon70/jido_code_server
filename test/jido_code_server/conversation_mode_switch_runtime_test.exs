defmodule Jido.Code.Server.ConversationModeSwitchRuntimeTest do
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

  test "idle mode switch emits accepted event and updates mode runtime projection" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase3-switch-idle"
             )

    assert {:ok, "phase3-switch-idle-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase3-switch-idle-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-switch-idle-c1", %{
               "type" => "conversation.mode.switch.requested",
               "data" => %{
                 "mode" => "planning",
                 "mode_state" => %{"strategy" => "planning"}
               }
             })

    assert {:ok, mode_runtime} =
             Runtime.conversation_projection(project_id, "phase3-switch-idle-c1", :mode_runtime)

    assert map_lookup(mode_runtime, :mode) == :planning
    assert map_lookup(mode_runtime, :active_run) == nil

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase3-switch-idle-c1", fn events ->
               types = event_types(events)

               "conversation.mode.switch.requested" in types and
                 "conversation.mode.switch.accepted" in types
             end)

    assert "conversation.mode.switch.requested" in event_types(timeline)
    assert "conversation.mode.switch.accepted" in event_types(timeline)
  end

  test "non-forced switch follows deterministic outcome around run completion boundary" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase3-switch-reject"
             )

    assert {:ok, "phase3-switch-reject-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase3-switch-reject-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-switch-reject-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "keep run active"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-switch-reject-c1", %{
               "type" => "conversation.mode.switch.requested",
               "data" => %{"mode" => "planning"}
             })

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase3-switch-reject-c1", fn events ->
               types = event_types(events)

               "conversation.run.opened" in types and
                 ("conversation.mode.switch.rejected" in types or
                    "conversation.mode.switch.accepted" in types)
             end)

    assert {:ok, mode_runtime} =
             Runtime.conversation_projection(project_id, "phase3-switch-reject-c1", :mode_runtime)

    types = event_types(timeline)

    assert "conversation.run.opened" in types

    if "conversation.mode.switch.rejected" in types do
      assert map_lookup(mode_runtime, :mode) == :coding
    else
      assert "conversation.mode.switch.accepted" in types
      assert map_lookup(mode_runtime, :mode) == :planning
    end

    run_opened =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.run.opened"
      end)

    assert map_lookup(run_opened, :data) |> map_lookup(:pipeline_template_id) == "coding.baseline"
    assert map_lookup(run_opened, :data) |> map_lookup(:pipeline_template_version) == "1.0.0"
  end

  test "forced mode switch closes current run and emits consistent lifecycle events" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase3-switch-force"
             )

    assert {:ok, "phase3-switch-force-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase3-switch-force-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-switch-force-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "open run"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-switch-force-c1", %{
               "type" => "conversation.mode.switch.requested",
               "data" => %{
                 "mode" => "engineering",
                 "force" => true,
                 "reason" => "operator_switch"
               }
             })

    assert {:ok, mode_runtime} =
             Runtime.conversation_projection(project_id, "phase3-switch-force-c1", :mode_runtime)

    assert map_lookup(mode_runtime, :mode) == :engineering
    assert map_lookup(mode_runtime, :active_run) == nil

    run_history = map_lookup(mode_runtime, :run_history) |> List.wrap()
    assert [latest_run | _rest] = run_history
    latest_status = map_lookup(latest_run, :status)
    assert latest_status in [:interrupted, :completed]

    if latest_status == :interrupted do
      assert map_lookup(latest_run, :reason) == "operator_switch"
    end

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase3-switch-force-c1", fn events ->
               types = event_types(events)

               "conversation.mode.switch.accepted" in types and
                 "conversation.run.closed" in types
             end)

    types = event_types(timeline)
    assert "conversation.mode.switch.accepted" in types
    assert "conversation.run.closed" in types

    if latest_status == :interrupted do
      assert "conversation.run.interrupted" in types
    end

    run_closed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.run.closed"
      end)

    assert map_lookup(run_closed, :data) |> map_lookup(:pipeline_template_id) == "coding.baseline"
    assert map_lookup(run_closed, :data) |> map_lookup(:pipeline_template_version) == "1.0.0"
  end

  test "run lifecycle emits resumed event after cancel and resume" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase3-run-resume"
             )

    assert {:ok, "phase3-run-resume-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase3-run-resume-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-run-resume-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "start"}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-run-resume-c1", %{
               "type" => "conversation.cancel"
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, "phase3-run-resume-c1", %{
               "type" => "conversation.resume"
             })

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "phase3-run-resume-c1", fn events ->
               types = event_types(events)

               "conversation.run.opened" in types and
                 "conversation.run.closed" in types and
                 "conversation.run.resumed" in types
             end)

    types = event_types(timeline)
    assert "conversation.run.opened" in types
    assert "conversation.run.closed" in types
    assert "conversation.run.resumed" in types
  end

  defp event_types(timeline), do: Enum.map(timeline, &map_lookup(&1, :type))

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
