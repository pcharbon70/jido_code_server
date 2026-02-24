defmodule Jido.Code.Server.ToolRuntimePolicyTest.WorkflowEchoAction do
  use Jido.Action,
    name: "tool_runtime_policy_workflow_echo_action",
    schema: [
      file_path: [type: :string, required: true]
    ]

  @impl true
  def run(%{file_path: file_path}, _context) do
    {:ok, %{"file_path" => file_path}}
  end
end

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

  test "command tool supports workspace-backed executor isolation mode" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    command_path = Path.join(root, ".jido/commands/example_command.md")
    File.write!(command_path, valid_workspace_shell_command_markdown())

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-command-workspace-executor",
               network_egress_policy: :allow,
               command_executor: :workspace_shell
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command", result: result}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => ".jido/commands/example_command.md"}
             })

    assert result.mode == :executed
    assert result.runtime == :jido_command
    assert get_in(result, [:execution, "result", "executor"]) == "workspace_shell"

    assert get_in(result, [:execution, "result", "workspace_id"]) =~
             "phase4-command-workspace-executor"

    assert get_in(result, [:execution, "result", "output"]) =~ "workspace-sandbox-ok"
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

  test "workflow tool executes valid markdown definitions through jido_workflow runtime" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    workflow_path = Path.join(root, ".jido/workflows/example_workflow.md")

    File.write!(workflow_path, valid_workflow_markdown())

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-workflow-runtime",
               network_egress_policy: :allow
             )

    assert {:ok, %{status: :ok, tool: "workflow.run.example_workflow", result: result}} =
             Runtime.run_tool(project_id, %{
               name: "workflow.run.example_workflow",
               args: %{
                 "inputs" => %{"file_path" => "lib/example.ex"}
               }
             })

    assert result.mode == :executed
    assert result.runtime == :jido_workflow
    assert result.workflow == "example_workflow"
    assert result.asset.name == "example_workflow"
    assert get_in(result, [:execution, :status]) == :completed
    assert get_in(result, [:execution, :workflow_id]) == "example_workflow"
    assert get_in(result, [:execution, :result, "file_path"]) == "lib/example.ex"
  end

  test "list_tools exposes definition-aware schemas for command and workflow assets" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    command_path = Path.join(root, ".jido/commands/example_command.md")
    workflow_path = Path.join(root, ".jido/workflows/example_workflow.md")

    File.write!(command_path, valid_command_markdown_with_schema())
    File.write!(workflow_path, valid_workflow_markdown_with_inputs())

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-definition-aware-tool-schema",
               network_egress_policy: :allow
             )

    tools = Runtime.list_tools(project_id)

    command_tool = Enum.find(tools, &(&1.name == "command.run.example_command"))
    workflow_tool = Enum.find(tools, &(&1.name == "workflow.run.example_workflow"))

    assert command_tool.input_schema["additionalProperties"] == true
    assert get_in(command_tool, [:input_schema, "properties", "query", "type"]) == "string"

    assert get_in(command_tool, [:input_schema, "properties", "query", "description"]) ==
             "Search query string"

    assert get_in(command_tool, [:input_schema, "properties", "limit", "type"]) == "integer"
    assert get_in(command_tool, [:input_schema, "properties", "limit", "default"]) == 10
    assert get_in(command_tool, [:input_schema, "properties", "params", "type"]) == "object"

    assert get_in(command_tool, [:input_schema, "properties", "params", "required"]) == ["query"]

    assert workflow_tool.input_schema["additionalProperties"] == true
    assert get_in(workflow_tool, [:input_schema, "properties", "file_path", "type"]) == "string"

    assert get_in(workflow_tool, [:input_schema, "properties", "file_path", "description"]) ==
             "Path to file"

    assert get_in(workflow_tool, [:input_schema, "properties", "max_findings", "type"]) ==
             "integer"

    assert get_in(workflow_tool, [:input_schema, "properties", "max_findings", "default"]) == 25
    assert get_in(workflow_tool, [:input_schema, "properties", "inputs", "type"]) == "object"

    assert get_in(workflow_tool, [:input_schema, "properties", "inputs", "required"]) == [
             "file_path"
           ]
  end

  test "definition-aware schemas enforce nested params and inputs payload validation" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    command_path = Path.join(root, ".jido/commands/example_command.md")
    workflow_path = Path.join(root, ".jido/workflows/example_workflow.md")

    File.write!(command_path, valid_command_markdown_with_schema())
    File.write!(workflow_path, valid_workflow_markdown_with_inputs())

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-nested-schema-validation",
               network_egress_policy: :allow
             )

    assert {:error, %{status: :error, reason: command_missing_reason}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"params" => %{}}
             })

    assert {:invalid_tool_args,
            {:invalid_arg_type, "params", {:missing_required_args, ["query"]}}} =
             command_missing_reason

    assert {:error, %{status: :error, reason: command_type_reason}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"params" => %{"query" => 123}}
             })

    assert {:invalid_tool_args,
            {:invalid_arg_type, "params", {:invalid_arg_type, "query", {:expected, "string"}}}} =
             command_type_reason

    assert {:error, %{status: :error, reason: workflow_missing_reason}} =
             Runtime.run_tool(project_id, %{
               name: "workflow.run.example_workflow",
               args: %{"inputs" => %{}}
             })

    assert {:invalid_tool_args,
            {:invalid_arg_type, "inputs", {:missing_required_args, ["file_path"]}}} =
             workflow_missing_reason
  end

  test "workflow tool falls back to preview mode when workflow markdown is invalid" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase4-workflow-preview-fallback",
               network_egress_policy: :allow
             )

    assert {:ok, %{status: :ok, tool: "workflow.run.example_workflow", result: result}} =
             Runtime.run_tool(project_id, %{
               name: "workflow.run.example_workflow",
               args: %{}
             })

    assert result.mode == :preview
    assert result.asset.name == "example_workflow"
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

  defp valid_workflow_markdown do
    """
    ---
    name: example_workflow
    version: "1.0.0"
    description: Example workflow fixture for runtime execution tests
    enabled: true
    inputs:
      - name: file_path
        type: string
        required: true
    ---
    # Example Workflow

    ## Steps

    ### echo
    - **type**: action
    - **module**: Jido.Code.Server.ToolRuntimePolicyTest.WorkflowEchoAction
    - **inputs**:
      - file_path: `input:file_path`

    ## Return
    - **value**: echo
    """
  end

  defp valid_workspace_shell_command_markdown do
    """
    ---
    name: example_command
    description: Example command fixture for workspace-backed command execution
    allowed-tools:
      - asset.list
    ---
    echo workspace-sandbox-ok
    """
  end

  defp valid_command_markdown_with_schema do
    """
    ---
    name: example_command
    description: Example command fixture with declared parameter schema
    allowed-tools:
      - asset.list
    jido:
      schema:
        query:
          type: string
          required: true
          doc: Search query string
        limit:
          type: integer
          default: 10
    ---
    Execute query={{query}} limit={{limit}}
    """
  end

  defp valid_workflow_markdown_with_inputs do
    """
    ---
    name: example_workflow
    version: "1.0.0"
    description: Example workflow fixture with declared inputs
    enabled: true
    inputs:
      - name: file_path
        type: string
        required: true
        description: Path to file
      - name: max_findings
        type: integer
        required: false
        default: 25
    ---
    # Example Workflow

    ## Steps

    ### echo
    - **type**: action
    - **module**: Jido.Code.Server.ToolRuntimePolicyTest.WorkflowEchoAction
    - **inputs**:
      - file_path: `input:file_path`

    ## Return
    - **value**: echo
    """
  end
end
