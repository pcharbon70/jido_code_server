defmodule JidoCodeServer.ProjectPhase5Test do
  use ExUnit.Case, async: false

  alias JidoCodeServer.Conversation.Server, as: ConversationServer
  alias JidoCodeServer.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(JidoCodeServer.list_projects(), fn %{project_id: project_id} ->
        _ = JidoCodeServer.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "conversation server supports cast ingest and projection queries" do
    assert {:ok, pid} =
             ConversationServer.start_link(project_id: "phase5", conversation_id: "direct-cast")

    :ok = ConversationServer.subscribe(pid, self())
    :ok = ConversationServer.ingest_event(pid, %{"type" => "user.message", "content" => "ping"})

    assert_receive {:conversation_event, "direct-cast", event}, 1_000
    assert event.type == "user.message"
    assert event.data["content"] == "ping"

    assert {:ok, [%{"type" => "user.message", "content" => "ping"}]} =
             ConversationServer.get_projection(pid, :timeline)
  end

  test "project conversation projections are deterministic for same event sequence" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             JidoCodeServer.start_project(root, project_id: "phase5-determinism")

    assert {:ok, "c-a"} = JidoCodeServer.start_conversation(project_id, conversation_id: "c-a")
    assert {:ok, "c-b"} = JidoCodeServer.start_conversation(project_id, conversation_id: "c-b")

    events = [
      %{"type" => "user.message", "content" => "hello"},
      %{
        "type" => "tool.requested",
        "tool_call" => %{"name" => "asset.list", "args" => %{"type" => "skill"}}
      },
      %{"type" => "tool.completed", "name" => "asset.list"}
    ]

    Enum.each(events, fn event ->
      assert :ok = JidoCodeServer.send_event(project_id, "c-a", event)
      assert :ok = JidoCodeServer.send_event(project_id, "c-b", event)
    end)

    assert {:ok, timeline_a} = JidoCodeServer.get_projection(project_id, "c-a", :timeline)
    assert {:ok, timeline_b} = JidoCodeServer.get_projection(project_id, "c-b", :timeline)
    assert timeline_a == timeline_b

    assert {:ok, pending_a} =
             JidoCodeServer.get_projection(project_id, "c-a", :pending_tool_calls)

    assert {:ok, pending_b} =
             JidoCodeServer.get_projection(project_id, "c-b", :pending_tool_calls)

    assert pending_a == pending_b
    assert pending_a == []
  end

  test "project conversation subscribers receive notifications and can unsubscribe" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             JidoCodeServer.start_project(root, project_id: "phase5-subscribers")

    assert {:ok, "sub-c"} =
             JidoCodeServer.start_conversation(project_id, conversation_id: "sub-c")

    assert :ok = JidoCodeServer.subscribe_conversation(project_id, "sub-c", self())

    assert :ok =
             JidoCodeServer.send_event(project_id, "sub-c", %{
               "type" => "user.message",
               "content" => "one"
             })

    assert_receive {:conversation_event, "sub-c", event}, 1_000
    assert event.type == "user.message"

    assert :ok = JidoCodeServer.unsubscribe_conversation(project_id, "sub-c", self())

    assert :ok =
             JidoCodeServer.send_event(project_id, "sub-c", %{
               "type" => "user.message",
               "content" => "two"
             })

    refute_receive {:conversation_event, "sub-c", _event}, 200
  end

  test "conversation lifecycle supports stop and restart without project disruption" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = JidoCodeServer.start_project(root, project_id: "phase5-restart")

    assert {:ok, "restart-c"} =
             JidoCodeServer.start_conversation(project_id, conversation_id: "restart-c")

    assert :ok =
             JidoCodeServer.send_event(project_id, "restart-c", %{
               "type" => "user.message",
               "content" => "before"
             })

    assert {:ok, [%{"content" => "before"}]} =
             JidoCodeServer.get_projection(project_id, "restart-c", :timeline)

    assert :ok = JidoCodeServer.stop_conversation(project_id, "restart-c")

    assert {:error, {:conversation_not_found, "restart-c"}} =
             JidoCodeServer.get_projection(project_id, "restart-c", :timeline)

    assert {:ok, "restart-c"} =
             JidoCodeServer.start_conversation(project_id, conversation_id: "restart-c")

    assert {:ok, []} = JidoCodeServer.get_projection(project_id, "restart-c", :timeline)
  end
end
