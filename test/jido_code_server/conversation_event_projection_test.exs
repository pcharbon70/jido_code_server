defmodule Jido.Code.Server.ConversationEventProjectionTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

  alias Jido.Code.Server.Conversation.Agent, as: ConversationAgent
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
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

  test "conversation agent supports cast ingest and projection queries" do
    assert {:ok, pid} =
             ConversationAgent.start_link(project_id: "phase5", conversation_id: "direct-cast")

    signal =
      ConversationSignal.normalize!(%{
        "type" => "conversation.user.message",
        "data" => %{"content" => "ping"}
      })

    assert :ok = ConversationAgent.cast(pid, signal)
    assert {:ok, timeline} = await_projection(pid, :timeline)

    assert [%{"type" => "conversation.user.message", "data" => %{"content" => "ping"}}] = timeline
  end

  test "project conversation projections are deterministic for same event sequence" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root, project_id: "phase5-determinism")

    assert {:ok, "c-a"} = Runtime.start_conversation(project_id, conversation_id: "c-a")
    assert {:ok, "c-b"} = Runtime.start_conversation(project_id, conversation_id: "c-b")

    events = [
      %{"type" => "conversation.user.message", "data" => %{"content" => "hello"}},
      %{
        "type" => "conversation.tool.requested",
        "data" => %{"tool_call" => %{"name" => "asset.list", "args" => %{"type" => "skill"}}}
      },
      %{"type" => "conversation.tool.completed", "data" => %{"name" => "asset.list"}}
    ]

    Enum.each(events, fn event ->
      assert :ok =
               RuntimeSignal.send_signal(project_id, "c-a", event)

      assert :ok =
               RuntimeSignal.send_signal(project_id, "c-b", event)
    end)

    assert {:ok, timeline_a} = Runtime.conversation_projection(project_id, "c-a", :timeline)
    assert {:ok, timeline_b} = Runtime.conversation_projection(project_id, "c-b", :timeline)
    assert event_types(timeline_a) == event_types(timeline_b)

    assert {:ok, pending_a} =
             Runtime.conversation_projection(project_id, "c-a", :pending_tool_calls)

    assert {:ok, pending_b} =
             Runtime.conversation_projection(project_id, "c-b", :pending_tool_calls)

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
             RuntimeSignal.send_signal(project_id, "sub-c", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "one"}
             })

    assert_receive {:conversation_event, "sub-c", event}, 1_000
    assert event["type"] == "conversation.user.message"

    assert :ok = Runtime.unsubscribe_conversation(project_id, "sub-c", self())

    assert :ok =
             RuntimeSignal.send_signal(project_id, "sub-c", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "two"}
             })

    refute_receive {:conversation_event, "sub-c", _event}, 200
  end

  test "project conversation cast notifies subscribers asynchronously" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root, project_id: "phase5-cast-subscribers")

    assert {:ok, "cast-sub-c"} =
             Runtime.start_conversation(project_id, conversation_id: "cast-sub-c")

    assert :ok = Runtime.subscribe_conversation(project_id, "cast-sub-c", self())

    signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "cast one"},
        source: "/test/conversation_event_projection"
      )

    assert :ok = Runtime.conversation_cast(project_id, "cast-sub-c", signal)

    assert_receive {:conversation_event, "cast-sub-c", event}, 1_000
    assert event["type"] == "conversation.user.message"
    assert get_in(event, ["data", "content"]) == "cast one"
  end

  test "conversation lifecycle supports stop and restart without project disruption" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = Runtime.start_project(root, project_id: "phase5-restart")

    assert {:ok, "restart-c"} =
             Runtime.start_conversation(project_id, conversation_id: "restart-c")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "restart-c", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "before"}
             })

    assert {:ok, [%{"data" => %{"content" => "before"}}]} =
             Runtime.conversation_projection(project_id, "restart-c", :timeline)

    assert :ok = Runtime.stop_conversation(project_id, "restart-c")

    assert {:error, {:conversation_not_found, "restart-c"}} =
             Runtime.conversation_projection(project_id, "restart-c", :timeline)

    assert {:ok, "restart-c"} =
             Runtime.start_conversation(project_id, conversation_id: "restart-c")

    assert {:ok, []} = Runtime.conversation_projection(project_id, "restart-c", :timeline)
  end

  defp event_types(timeline) when is_list(timeline) do
    Enum.map(timeline, &Map.get(&1, "type"))
  end

  defp await_projection(pid, key, attempts \\ 30)

  defp await_projection(_pid, _key, 0), do: {:error, :projection_timeout}

  defp await_projection(pid, key, attempts) do
    case ConversationAgent.projection(pid, key) do
      {:ok, projection} when is_list(projection) and projection != [] ->
        {:ok, projection}

      _other ->
        Process.sleep(10)
        await_projection(pid, key, attempts - 1)
    end
  end
end
