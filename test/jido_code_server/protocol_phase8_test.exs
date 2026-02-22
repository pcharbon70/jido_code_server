defmodule JidoCodeServer.ProtocolPhase8Test do
  use ExUnit.Case, async: false

  alias JidoCodeServer.Protocol.A2A.Gateway, as: A2AGateway
  alias JidoCodeServer.Protocol.MCP.Gateway, as: MCPGateway
  alias JidoCodeServer.Protocol.MCP.ProjectServer, as: MCPProjectServer
  alias JidoCodeServer.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(JidoCodeServer.list_projects(), fn %{project_id: project_id} ->
        _ = JidoCodeServer.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "engine protocol supervisor boots MCP and A2A gateways" do
    assert Process.whereis(MCPGateway)
    assert Process.whereis(A2AGateway)
  end

  test "MCP gateway maps tools/list and tools/call through project runtime policy" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             JidoCodeServer.start_project(root,
               project_id: "phase8-mcp",
               allow_tools: ["asset.list"]
             )

    assert {:ok, tools} = MCPGateway.tools_list(project_id)
    assert Enum.map(tools, & &1.name) == ["asset.list"]

    assert {:ok, %{status: :ok, tool: "asset.list"}} =
             MCPGateway.tools_call(project_id, %{name: "asset.list", args: %{"type" => "skill"}})

    assert {:error, %{status: :error, tool: "asset.search", reason: :denied}} =
             MCPGateway.tools_call(project_id, %{
               name: "asset.search",
               args: %{"type" => "skill", "query" => "example"}
             })

    assert {:error, {:project_not_found, "missing-project"}} =
             MCPGateway.tools_list("missing-project")
  end

  test "MCP gateway and per-project server map chat messages to user.message events" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             JidoCodeServer.start_project(root, project_id: "phase8-mcp-message")

    assert {:ok, "mcp-c1"} =
             JidoCodeServer.start_conversation(project_id, conversation_id: "mcp-c1")

    assert :ok = MCPGateway.send_message(project_id, "mcp-c1", "hello from mcp")

    assert {:ok, server_pid} = MCPProjectServer.start_link(project_id: project_id)
    assert :ok = MCPProjectServer.send_message(server_pid, "mcp-c1", "hello from project server")

    assert {:ok, timeline} = JidoCodeServer.get_projection(project_id, "mcp-c1", :timeline)

    assert Enum.map(timeline, &Map.get(&1, "content")) == [
             "hello from mcp",
             "hello from project server"
           ]
  end

  test "A2A gateway maps task create/message/cancel and supports event subscriptions" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = JidoCodeServer.start_project(root, project_id: "phase8-a2a")

    assert {:ok, task} = A2AGateway.task_create(project_id, "start task")
    conversation_id = task.task_id

    assert :ok = A2AGateway.subscribe_task(project_id, conversation_id, self())
    assert :ok = A2AGateway.message_send(project_id, conversation_id, "follow-up")
    assert :ok = A2AGateway.task_cancel(project_id, conversation_id, reason: :user_requested)

    assert_receive {:conversation_event, ^conversation_id, event1}, 1_000
    assert event1.type == "user.message"

    assert_receive {:conversation_event, ^conversation_id, event2}, 1_000
    assert event2.type == "conversation.cancel"

    assert :ok = A2AGateway.unsubscribe_task(project_id, conversation_id, self())

    assert {:ok, timeline} = JidoCodeServer.get_projection(project_id, conversation_id, :timeline)

    assert Enum.map(timeline, &Map.get(&1, "type")) == [
             "user.message",
             "user.message",
             "conversation.cancel"
           ]

    assert {:ok, card} = A2AGateway.agent_card(project_id)
    assert card.project_id == project_id
    assert card.capabilities.tool_count >= 3
  end

  test "protocol adapters route requests to the correct project instance" do
    root_a = TempProject.create!(with_seed_files: true)
    root_b = TempProject.create!(with_seed_files: true)

    on_exit(fn -> TempProject.cleanup(root_a) end)
    on_exit(fn -> TempProject.cleanup(root_b) end)

    assert {:ok, project_a} =
             JidoCodeServer.start_project(root_a,
               project_id: "phase8-route-a",
               allow_tools: ["asset.list"]
             )

    assert {:ok, project_b} =
             JidoCodeServer.start_project(root_b,
               project_id: "phase8-route-b",
               allow_tools: ["asset.search"]
             )

    assert {:ok, tools_a} = MCPGateway.tools_list(project_a)
    assert {:ok, tools_b} = MCPGateway.tools_list(project_b)

    assert Enum.map(tools_a, & &1.name) == ["asset.list"]
    assert Enum.map(tools_b, & &1.name) == ["asset.search"]
  end
end
