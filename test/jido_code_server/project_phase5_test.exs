defmodule Jido.Code.Server.ProjectPhase5Test do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

  alias Jido.Code.Server.Conversation.Server, as: ConversationServer
  alias Jido.Code.Server.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
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
             Runtime.start_project(root, project_id: "phase5-determinism")

    assert {:ok, "c-a"} = Runtime.start_conversation(project_id, conversation_id: "c-a")
    assert {:ok, "c-b"} = Runtime.start_conversation(project_id, conversation_id: "c-b")

    events = [
      %{"type" => "user.message", "content" => "hello"},
      %{
        "type" => "tool.requested",
        "tool_call" => %{"name" => "asset.list", "args" => %{"type" => "skill"}}
      },
      %{"type" => "tool.completed", "name" => "asset.list"}
    ]

    Enum.each(events, fn event ->
      assert :ok = Runtime.send_event(project_id, "c-a", event)
      assert :ok = Runtime.send_event(project_id, "c-b", event)
    end)

    assert {:ok, timeline_a} = Runtime.get_projection(project_id, "c-a", :timeline)
    assert {:ok, timeline_b} = Runtime.get_projection(project_id, "c-b", :timeline)
    assert strip_correlation_id(timeline_a) == strip_correlation_id(timeline_b)

    assert {:ok, pending_a} =
             Runtime.get_projection(project_id, "c-a", :pending_tool_calls)

    assert {:ok, pending_b} =
             Runtime.get_projection(project_id, "c-b", :pending_tool_calls)

    assert pending_a == pending_b
    assert pending_a == []
  end

  test "project conversation subscribers receive notifications and can unsubscribe" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root, project_id: "phase5-subscribers")

    assert {:ok, "sub-c"} =
             Runtime.start_conversation(project_id, conversation_id: "sub-c")

    assert :ok = Runtime.subscribe_conversation(project_id, "sub-c", self())

    assert :ok =
             Runtime.send_event(project_id, "sub-c", %{
               "type" => "user.message",
               "content" => "one"
             })

    assert_receive {:conversation_event, "sub-c", event}, 1_000
    assert event.type == "user.message"

    assert :ok = Runtime.unsubscribe_conversation(project_id, "sub-c", self())

    assert :ok =
             Runtime.send_event(project_id, "sub-c", %{
               "type" => "user.message",
               "content" => "two"
             })

    refute_receive {:conversation_event, "sub-c", _event}, 200
  end

  test "conversation lifecycle supports stop and restart without project disruption" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = Runtime.start_project(root, project_id: "phase5-restart")

    assert {:ok, "restart-c"} =
             Runtime.start_conversation(project_id, conversation_id: "restart-c")

    assert :ok =
             Runtime.send_event(project_id, "restart-c", %{
               "type" => "user.message",
               "content" => "before"
             })

    assert {:ok, [%{"content" => "before"}]} =
             Runtime.get_projection(project_id, "restart-c", :timeline)

    assert :ok = Runtime.stop_conversation(project_id, "restart-c")

    assert {:error, {:conversation_not_found, "restart-c"}} =
             Runtime.get_projection(project_id, "restart-c", :timeline)

    assert {:ok, "restart-c"} =
             Runtime.start_conversation(project_id, conversation_id: "restart-c")

    assert {:ok, []} = Runtime.get_projection(project_id, "restart-c", :timeline)
  end

  defp strip_correlation_id(term) when is_list(term) do
    Enum.map(term, &strip_correlation_id/1)
  end

  defp strip_correlation_id(%_{} = struct), do: struct

  defp strip_correlation_id(term) when is_map(term) do
    term
    |> Map.delete(:correlation_id)
    |> Map.delete("correlation_id")
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, key, strip_correlation_id(value))
    end)
  end

  defp strip_correlation_id(term), do: term
end
