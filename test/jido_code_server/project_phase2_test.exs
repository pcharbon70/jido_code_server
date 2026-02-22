defmodule JidoCodeServer.ProjectPhase2Test do
  use ExUnit.Case, async: false

  alias JidoCodeServer.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(JidoCodeServer.list_projects(), fn %{project_id: project_id} ->
        _ = JidoCodeServer.stop_project(project_id)
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
             JidoCodeServer.start_project(root, project_id: "phase2-layout", data_dir: ".runtime")

    assert File.dir?(Path.join(root, ".runtime"))
    assert File.dir?(Path.join(root, ".runtime/skills"))
    assert File.dir?(Path.join(root, ".runtime/commands"))
    assert File.dir?(Path.join(root, ".runtime/workflows"))
    assert File.dir?(Path.join(root, ".runtime/skill_graph"))
    assert File.dir?(Path.join(root, ".runtime/state"))

    [summary] = Enum.filter(JidoCodeServer.list_projects(), &(&1.project_id == "phase2-layout"))
    assert summary.root_path == Path.expand(root)
    assert summary.data_dir == ".runtime"
  end

  test "conversation shell supports start, send event, projection reads, and stop" do
    root = TempProject.create!()
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             JidoCodeServer.start_project(root, project_id: "phase2-conversations")

    assert {:ok, "conversation-a"} =
             JidoCodeServer.start_conversation(project_id, conversation_id: "conversation-a")

    assert {:error, {:conversation_already_started, "conversation-a"}} =
             JidoCodeServer.start_conversation(project_id, conversation_id: "conversation-a")

    event = %{"type" => "user.message", "content" => "hello"}
    assert :ok = JidoCodeServer.send_event(project_id, "conversation-a", event)

    assert {:ok, [^event]} =
             JidoCodeServer.get_projection(project_id, "conversation-a", :timeline)

    assert {:ok, %{project_id: ^project_id, conversation_id: "conversation-a", events: [^event]}} =
             JidoCodeServer.get_projection(project_id, "conversation-a", :llm_context)

    assert :ok = JidoCodeServer.stop_conversation(project_id, "conversation-a")

    assert {:error, {:conversation_not_found, "conversation-a"}} =
             JidoCodeServer.get_projection(project_id, "conversation-a", :timeline)
  end
end
