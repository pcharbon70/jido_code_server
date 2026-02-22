defmodule Jido.Code.Server.EngineTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

  alias Jido.Code.Server.Engine
  alias Jido.Code.Server.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "starts, looks up, lists, and stops project instances" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = Runtime.start_project(root)

    assert {:ok, pid} = Engine.whereis_project(project_id)
    assert is_pid(pid)

    assert [%{project_id: ^project_id, root_path: listed_root, data_dir: ".jido", pid: ^pid} | _] =
             Runtime.list_projects()

    assert listed_root == Path.expand(root)

    assert :ok = Runtime.stop_project(project_id)
    assert {:error, {:project_not_found, ^project_id}} = Engine.whereis_project(project_id)
  end

  test "returns deterministic error on duplicate project id" do
    root = TempProject.create!()
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, "project-alpha"} =
             Runtime.start_project(root, project_id: "project-alpha")

    assert {:error, {:already_started, "project-alpha"}} =
             Runtime.start_project(root, project_id: "project-alpha")
  end

  test "rejects invalid root paths" do
    missing_path =
      Path.join(
        System.tmp_dir!(),
        "jido_code_server_missing_#{System.unique_integer([:positive])}"
      )

    assert {:error, {:invalid_root_path, _reason}} = Runtime.start_project(missing_path)
  end

  test "rejects invalid data_dir values" do
    root = TempProject.create!()
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:error, {:invalid_data_dir, :expected_non_empty_string}} =
             Runtime.start_project(root, data_dir: "")

    assert {:error, {:invalid_data_dir, :must_be_relative}} =
             Runtime.start_project(root, data_dir: "/tmp/jido")

    assert {:error, {:invalid_data_dir, :must_not_traverse}} =
             Runtime.start_project(root, data_dir: "../jido")
  end

  test "stop_project returns not found error for unknown project" do
    assert {:error, {:project_not_found, "missing-project"}} =
             Runtime.stop_project("missing-project")
  end

  test "operations reject invalid project id type" do
    assert {:error, {:invalid_project_id, :expected_string}} = Engine.whereis_project(123)
    assert {:error, {:invalid_project_id, :expected_string}} = Runtime.stop_project(123)
  end

  test "conversation operations fail with project not found when project is unknown" do
    assert {:error, {:project_not_found, "missing-project"}} =
             Runtime.start_conversation("missing-project")

    assert {:error, {:project_not_found, "missing-project"}} =
             Runtime.stop_conversation("missing-project", "c1")

    assert {:error, {:project_not_found, "missing-project"}} =
             Runtime.send_event("missing-project", "c1", %{"type" => "user.message"})

    assert {:error, {:project_not_found, "missing-project"}} =
             Runtime.get_projection("missing-project", "c1", :llm_context)

    assert {:error, {:project_not_found, "missing-project"}} =
             Runtime.reload_assets("missing-project")
  end
end
