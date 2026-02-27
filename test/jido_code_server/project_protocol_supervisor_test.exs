defmodule Jido.Code.Server.ProjectProtocolSupervisorTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Project.Naming
  alias Jido.Code.Server.Protocol.A2A.ProjectServer, as: A2AProjectServer
  alias Jido.Code.Server.Protocol.MCP.ProjectServer, as: MCPProjectServer
  alias Jido.Code.Server.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "starts per-project protocol servers from protocol_allowlist" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, both_project_id} =
             Runtime.start_project(root,
               project_id: "phase8-project-protocol-both",
               protocol_allowlist: [" MCP ", "A2A"]
             )

    assert is_pid(GenServer.whereis(Naming.protocol_server(both_project_id, "mcp")))
    assert is_pid(GenServer.whereis(Naming.protocol_server(both_project_id, "a2a")))

    assert {:ok, mcp_only_project_id} =
             Runtime.start_project(root,
               project_id: "phase8-project-protocol-mcp-only",
               protocol_allowlist: ["mcp"]
             )

    assert is_pid(GenServer.whereis(Naming.protocol_server(mcp_only_project_id, "mcp")))
    refute GenServer.whereis(Naming.protocol_server(mcp_only_project_id, "a2a"))

    assert {:ok, a2a_only_project_id} =
             Runtime.start_project(root,
               project_id: "phase8-project-protocol-a2a-only",
               protocol_allowlist: ["a2a"]
             )

    refute GenServer.whereis(Naming.protocol_server(a2a_only_project_id, "mcp"))
    assert is_pid(GenServer.whereis(Naming.protocol_server(a2a_only_project_id, "a2a")))
  end

  test "project-scoped protocol servers delegate operations through global gateways" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase8-project-protocol-delegation",
               protocol_allowlist: ["mcp", "a2a"]
             )

    mcp_server = Naming.protocol_server(project_id, "mcp")
    a2a_server = Naming.protocol_server(project_id, "a2a")

    assert {:ok, "phase8-mcp-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase8-mcp-c1")

    assert :ok = MCPProjectServer.send_message(mcp_server, "phase8-mcp-c1", "hello from mcp")

    assert {:ok, task} =
             A2AProjectServer.task_create(a2a_server, "hello from a2a", task_id: "phase8-a2a-c1")

    assert task.task_id == "phase8-a2a-c1"
    assert :ok = A2AProjectServer.message_send(a2a_server, "phase8-a2a-c1", "a2a follow-up")

    assert {:ok, mcp_timeline} =
             Runtime.conversation_projection(project_id, "phase8-mcp-c1", :timeline)

    assert Enum.map(mcp_timeline, &get_in(&1, ["data", "content"])) == ["hello from mcp"]

    assert {:ok, a2a_timeline} =
             Runtime.conversation_projection(project_id, "phase8-a2a-c1", :timeline)

    assert Enum.map(a2a_timeline, &get_in(&1, ["data", "content"])) == [
             "hello from a2a",
             "a2a follow-up"
           ]
  end
end
