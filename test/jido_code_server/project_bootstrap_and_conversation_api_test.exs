defmodule Jido.Code.Server.ProjectBootstrapAndConversationApiTest do
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

  test "project start ensures data layout for configured data_dir" do
    root =
      Path.join(
        System.tmp_dir!(),
        "jido_code_server_phase2_root_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf(root)
    end)

    assert {:ok, "phase2-layout"} =
             Runtime.start_project(root,
               project_id: "phase2-layout",
               data_dir: ".runtime"
             )

    assert File.dir?(Path.join(root, ".runtime"))
    assert File.dir?(Path.join(root, ".runtime/skills"))
    assert File.dir?(Path.join(root, ".runtime/commands"))
    assert File.dir?(Path.join(root, ".runtime/workflows"))
    assert File.dir?(Path.join(root, ".runtime/skill_graph"))
    assert File.dir?(Path.join(root, ".runtime/state"))

    [summary] = Enum.filter(Runtime.list_projects(), &(&1.project_id == "phase2-layout"))
    assert summary.root_path == Path.expand(root)
    assert summary.data_dir == ".runtime"
  end

  test "conversation shell supports start, send event, projection reads, and stop" do
    root = TempProject.create!()
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root, project_id: "phase2-conversations")

    assert {:ok, "conversation-a"} =
             Runtime.start_conversation(project_id, conversation_id: "conversation-a")

    assert {:error, {:conversation_already_started, "conversation-a"}} =
             Runtime.start_conversation(project_id, conversation_id: "conversation-a")

    event = %{"type" => "conversation.user.message", "content" => "hello"}

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "conversation-a",
               event
             )

    assert {:ok, [timeline_event]} =
             Runtime.conversation_projection(project_id, "conversation-a", :timeline)

    assert timeline_event["type"] == "conversation.user.message"
    assert timeline_event["content"] == "hello"
    assert is_binary(get_in(timeline_event, ["meta", "correlation_id"]))
    correlation_id = get_in(timeline_event, ["meta", "correlation_id"])

    assert {:ok, llm_context} =
             Runtime.conversation_projection(project_id, "conversation-a", :llm_context)

    assert llm_context.project_id == project_id
    assert llm_context.conversation_id == "conversation-a"
    assert [context_event] = llm_context.events
    assert context_event["type"] == "conversation.user.message"
    assert context_event["content"] == "hello"
    assert get_in(context_event, ["meta", "correlation_id"]) == correlation_id

    assert :ok = Runtime.stop_conversation(project_id, "conversation-a")

    assert {:error, {:conversation_not_found, "conversation-a"}} =
             Runtime.conversation_projection(project_id, "conversation-a", :timeline)
  end
end
