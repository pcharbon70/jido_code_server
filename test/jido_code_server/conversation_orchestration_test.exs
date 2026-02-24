defmodule Jido.Code.Server.ConversationOrchestrationTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

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
             Runtime.send_event(project_id, "phase6-c1", %{
               "type" => "user.message",
               "content" => "hello"
             })

    assert {:ok, timeline} = Runtime.get_projection(project_id, "phase6-c1", :timeline)

    assert event_types(timeline) == [
             "user.message",
             "llm.started",
             "assistant.delta",
             "assistant.message",
             "llm.completed"
           ]
  end

  test "tool requests flow through tool runner and continue conversation after completion" do
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
             Runtime.send_event(project_id, "phase6-tools-c1", %{
               "type" => "user.message",
               "content" => "please list skills"
             })

    assert {:ok, timeline} =
             Runtime.get_projection(project_id, "phase6-tools-c1", :timeline)

    types = event_types(timeline)

    assert "tool.requested" in types
    assert "tool.completed" in types
    assert "assistant.message" in types

    tool_completed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "tool.completed"
      end)

    result = map_lookup(tool_completed, :data) |> map_lookup(:result)

    assert map_lookup(result, :status) == :ok

    items =
      result
      |> map_lookup(:result)
      |> map_lookup(:items)
      |> List.wrap()

    assert Enum.any?(items, fn item -> item.name == "example_skill" end)

    assert {:ok, []} =
             Runtime.get_projection(project_id, "phase6-tools-c1", :pending_tool_calls)
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
             Runtime.send_event(project_id, "phase6-tool-failure-c1", %{
               "type" => "user.message",
               "content" => "run command",
               "llm" => %{
                 "tool_calls" => [%{"name" => "command.run.example_command", "args" => %{}}]
               }
             })

    assert {:ok, timeline} =
             Runtime.get_projection(project_id, "phase6-tool-failure-c1", :timeline)

    types = event_types(timeline)
    assert "tool.failed" in types
    assert "assistant.message" in types

    tool_failed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "tool.failed"
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
             Runtime.send_event(project_id, "phase6-cancel-c1", %{
               "type" => "conversation.cancel"
             })

    assert :ok =
             Runtime.send_event(project_id, "phase6-cancel-c1", %{
               "type" => "user.message",
               "content" => "ignored"
             })

    assert {:ok, timeline_before_resume} =
             Runtime.get_projection(project_id, "phase6-cancel-c1", :timeline)

    refute "llm.started" in event_types(timeline_before_resume)

    assert :ok =
             Runtime.send_event(project_id, "phase6-cancel-c1", %{
               "type" => "conversation.resume"
             })

    assert :ok =
             Runtime.send_event(project_id, "phase6-cancel-c1", %{
               "type" => "user.message",
               "content" => "active again"
             })

    assert {:ok, timeline_after_resume} =
             Runtime.get_projection(project_id, "phase6-cancel-c1", :timeline)

    assert "llm.started" in event_types(timeline_after_resume)
    assert "assistant.message" in event_types(timeline_after_resume)
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
             Runtime.send_event(project_id, "phase6-command-executor-c1", %{
               "type" => "user.message",
               "content" => "run workspace command",
               "llm" => %{
                 "tool_calls" => [
                   %{
                     "name" => "command.run.example_command",
                     "args" => %{"path" => ".jido/commands/example_command.md"}
                   }
                 ]
               }
             })

    assert {:ok, timeline} =
             Runtime.get_projection(project_id, "phase6-command-executor-c1", :timeline)

    tool_completed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "tool.completed"
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

  defp map_lookup(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_lookup(_map, _key), do: nil
end
