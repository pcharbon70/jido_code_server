defmodule Jido.Code.Server.ToolActionBridgeTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Project.ToolActionBridge
  alias Jido.Code.Server.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "action_registry exposes runtime tools as generated Jido action modules" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "tool-action-bridge-registry",
               network_egress_policy: :allow
             )

    assert {:ok, registry} = ToolActionBridge.action_registry(project_id)

    runtime_tool_names =
      project_id
      |> Runtime.list_tools()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    assert map_size(registry) == MapSet.size(runtime_tool_names)

    assert Enum.all?(Map.keys(registry), fn action_name ->
             Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_]*$/, action_name)
           end)

    assert Enum.all?(registry, fn {action_name, module} ->
             is_atom(module) and module.name() == action_name
           end)
  end

  test "tool_calling_context works with Jido.AI ExecuteTool and preserves tool metadata" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "tool-action-bridge-execute-tool",
               network_egress_policy: :allow
             )

    assert {:ok, context} =
             ToolActionBridge.tool_calling_context(project_id,
               conversation_id: "bridge-c1",
               correlation_id: "bridge-corr"
             )

    tool_name_by_action =
      context
      |> Map.fetch!(:jido_code_server)
      |> Map.fetch!(:tool_name_by_action)

    action_name =
      Enum.find_value(tool_name_by_action, fn {candidate_action_name, candidate_tool_name} ->
        if candidate_tool_name == "asset.list", do: candidate_action_name
      end)

    assert is_binary(action_name)

    assert {:ok, %{tool_name: resolved_action_name, status: :success, result: result}} =
             Jido.Exec.run(
               Jido.AI.Actions.ToolCalling.ExecuteTool,
               %{tool_name: action_name, params: %{"type" => "skill"}},
               context,
               log_level: :error
             )

    assert resolved_action_name == action_name
    assert result.status == :ok
    assert result.tool == "asset.list"
    assert result.conversation_id == "bridge-c1"
    assert result.correlation_id == "bridge-corr"
    assert Enum.any?(result.result.items, &(&1.name == "example_skill"))
  end

  test "execute_from_action keeps ExecutionRunner policy enforcement" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "tool-action-bridge-policy",
               network_egress_policy: :allow
             )

    assert {:error,
            %{
              status: :error,
              tool: "command.run.example_command",
              reason: :outside_root
            }} =
             ToolActionBridge.execute_from_action(
               "command.run.example_command",
               %{"path" => "../outside.md"},
               %{project_id: project_id}
             )
  end
end
