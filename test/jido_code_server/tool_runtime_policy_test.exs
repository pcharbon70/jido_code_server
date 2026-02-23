defmodule Jido.Code.Server.ToolRuntimePolicyTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.Layout
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.ToolRunner
  alias Jido.Code.Server.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "list_tools returns policy-filtered builtins and asset-backed tools" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-tools",
               network_egress_policy: :allow
             )

    tool_names =
      project_id
      |> Runtime.list_tools()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert "asset.list" in tool_names
    assert "asset.search" in tool_names
    assert "asset.get" in tool_names
    assert "command.run.example_command" in tool_names
    assert "workflow.run.example_workflow" in tool_names
  end

  test "run_tool uses unified policy and tool runner execution path" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-runner",
               network_egress_policy: :allow
             )

    assert {:ok, %{status: :ok, tool: "asset.list", result: %{items: skills}}} =
             Runtime.run_tool(project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"}
             })

    assert Enum.any?(skills, &(&1.name == "example_skill"))

    assert {:ok, %{status: :ok, tool: "command.run.example_command", result: result}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => ".jido/commands/example_command.md"}
             })

    assert result.asset.name == "example_command"

    assert {:error, %{status: :error, tool: "command.run.example_command", reason: :outside_root}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => "../outside.md"}
             })
  end

  test "command tool executes valid markdown definitions through jido_command runtime" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    command_path = Path.join(root, ".jido/commands/example_command.md")

    File.write!(command_path, valid_command_markdown())

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-command-runtime",
               network_egress_policy: :allow
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command", result: result}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => ".jido/commands/example_command.md", "query" => "hello-world"}
             })

    assert result.mode == :executed
    assert result.runtime == :jido_command
    assert result.command == "example_command"
    assert result.asset.name == "example_command"
    assert get_in(result, [:execution, "result", "command"]) == "example_command"
    assert get_in(result, [:execution, "result", "params", "query"]) == "hello-world"
    assert get_in(result, [:execution, "result", "prompt"]) =~ "query=hello-world"
  end

  test "command tool falls back to preview mode when command markdown is invalid" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-command-preview-fallback",
               network_egress_policy: :allow
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command", result: result}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => ".jido/commands/example_command.md"}
             })

    assert result.mode == :preview
    assert result.asset.name == "example_command"
    assert is_binary(result.note)
    assert result.note =~ "preview compatibility mode"
  end

  test "project allow_tools policy limits inventory and execution surface" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-allow",
               allow_tools: ["asset.list"]
             )

    assert ["asset.list"] ==
             project_id
             |> Runtime.list_tools()
             |> Enum.map(& &1.name)

    assert {:ok, %{status: :ok, tool: "asset.list"}} =
             Runtime.run_tool(project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"}
             })

    assert {:error, %{status: :error, tool: "asset.search", reason: :denied}} =
             Runtime.run_tool(project_id, %{
               name: "asset.search",
               args: %{"type" => "skill", "query" => "example"}
             })
  end

  test "policy normalize_path blocks symlink escape" do
    root = TempProject.create!()
    outside_root = Path.join(System.tmp_dir!(), "jido_code_server_phase4_outside")
    File.mkdir_p!(outside_root)
    on_exit(fn -> TempProject.cleanup(root) end)
    on_exit(fn -> File.rm_rf(outside_root) end)

    escape_link = Path.join(root, "escape")
    File.ln_s!(outside_root, escape_link)

    assert {:error, :outside_root} = Policy.normalize_path(root, "escape/secret.txt")
  end

  test "tool runner enforces max concurrency limit before task execution" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    layout = Layout.paths(root, ".jido")
    assert {:ok, asset_store} = AssetStore.start_link(project_id: "phase4-direct")
    assert :ok = AssetStore.load(asset_store, layout)

    assert {:ok, policy} =
             Policy.start_link(project_id: "phase4-direct", root_path: root, allow_tools: nil)

    assert {:ok, task_supervisor} = Task.Supervisor.start_link()

    project_ctx = %{
      project_id: "phase4-direct",
      root_path: root,
      data_dir: ".jido",
      layout: layout,
      asset_store: asset_store,
      policy: policy,
      task_supervisor: task_supervisor,
      tool_timeout_ms: 30_000,
      tool_max_concurrency: 0
    }

    assert {:error, %{status: :error, reason: :max_concurrency_reached}} =
             ToolRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})
  end

  defp valid_command_markdown do
    """
    ---
    name: example_command
    description: Example command fixture for runtime execution tests
    allowed-tools:
      - asset.list
    ---
    Execute path={{path}} query={{query}}
    """
  end
end
