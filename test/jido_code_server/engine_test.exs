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

  test "rejects invalid runtime option values" do
    root = TempProject.create!()
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:error, {:invalid_runtime_opt, :tool_timeout_ms, :expected_positive_integer}} =
             Runtime.start_project(root, tool_timeout_ms: 0)

    assert {:error, {:invalid_runtime_opt, :watcher, :expected_boolean}} =
             Runtime.start_project(root, watcher: :enabled)

    assert {:error, {:invalid_runtime_opt, :network_egress_policy, :expected_allow_or_deny}} =
             Runtime.start_project(root, network_egress_policy: :blocked)

    assert {:error, {:invalid_runtime_opt, :sensitive_path_denylist, :expected_list_of_strings}} =
             Runtime.start_project(root, sensitive_path_denylist: nil)

    assert {:error, {:invalid_runtime_opt, :tool_env_allowlist, :expected_list_of_strings}} =
             Runtime.start_project(root, tool_env_allowlist: ["PATH", 123])

    assert {:error, {:invalid_runtime_opt, :llm_model, :expected_string_or_nil}} =
             Runtime.start_project(root, llm_model: 123)

    assert {:error,
            {:invalid_runtime_opt, :outside_root_allowlist,
             {:invalid_entry, 0, :missing_reason_code}}} =
             Runtime.start_project(root,
               outside_root_allowlist: [%{"path" => "/tmp/allowed.txt"}]
             )

    assert {:error,
            {:invalid_runtime_opt, :outside_root_allowlist,
             {:invalid_entry, 0, :expected_map_entry}}} =
             Runtime.start_project(root, outside_root_allowlist: ["/tmp/allowed.txt"])

    assert {:error, {:invalid_runtime_opt, :unknown_option, :unknown_option}} =
             Runtime.start_project(root, unknown_option: :value)
  end

  test "normalizes accepted runtime options before project start" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, "engine-runtime-normalize"} =
             Runtime.start_project(root,
               project_id: "engine-runtime-normalize",
               network_egress_policy: "allow"
             )

    diagnostics = Runtime.diagnostics("engine-runtime-normalize")

    assert diagnostics.runtime_opts[:network_egress_policy] == :allow
    assert diagnostics.policy.network_egress_policy == :allow
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
