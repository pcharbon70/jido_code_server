defmodule Jido.Code.Server.SubAgentRuntimeTest.TestSubAgent do
  use Jido.Agent,
    name: "jido_code_server_subagent_runtime_test_agent",
    description: "Test sub-agent template module",
    schema: []
end

defmodule Jido.Code.Server.SubAgentRuntimeTest do
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

  test "list_tools exposes only allowlisted spawn templates" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "subagent-tools-allowlist",
               subagent_templates: [template("builder"), template("reviewer")],
               subagent_templates_allowlist: ["builder"]
             )

    tool_names =
      project_id
      |> Runtime.list_tools()
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert "agent.spawn.builder" in tool_names
    refute "agent.spawn.reviewer" in tool_names
  end

  test "conversation cancel stops active sub-agents and emits canonical stopped signal" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "subagent-cancel",
               subagent_templates: [template("worker")]
             )

    assert {:ok, "subagent-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "subagent-c1")

    correlation_id = "corr-subagent-cancel"

    assert :ok =
             RuntimeSignal.send_signal(project_id, "subagent-c1", %{
               "type" => "conversation.tool.requested",
               "data" => %{
                 "tool_call" => %{
                   "name" => "agent.spawn.worker",
                   "args" => %{"goal" => "process queue"}
                 }
               },
               "meta" => %{"correlation_id" => correlation_id}
             })

    assert {:ok, started_timeline} =
             wait_for_timeline(project_id, "subagent-c1", fn timeline ->
               Enum.any?(timeline, &(map_get(&1, "type") == "conversation.subagent.started"))
             end)

    assert Enum.any?(started_timeline, fn event ->
             map_get(event, "type") == "conversation.subagent.requested"
           end)

    assert :ok =
             RuntimeSignal.send_signal(project_id, "subagent-c1", %{
               "type" => "conversation.cancel",
               "data" => %{"reason" => "user_cancel"},
               "meta" => %{"correlation_id" => correlation_id}
             })

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "subagent-c1", fn events ->
               Enum.any?(events, &(map_get(&1, "type") == "conversation.subagent.stopped"))
             end)

    stopped =
      Enum.find(timeline, fn event ->
        map_get(event, "type") == "conversation.subagent.stopped"
      end)

    assert map_get(stopped, "meta") |> map_get("correlation_id") == correlation_id

    assert {:ok, subagent_status} =
             Runtime.conversation_projection(project_id, "subagent-c1", :subagent_status)

    assert subagent_status.active_count == 0
    assert subagent_status.completed_count >= 1
    assert Enum.any?(subagent_status.completed, &(map_get(&1, "status") == "stopped"))
  end

  test "policy-denied spawn emits security telemetry and subagent failure signal" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "subagent-policy-deny",
               subagent_templates: [template("blocked")],
               subagent_templates_allowlist: ["other-template"]
             )

    assert {:ok, "subagent-denied-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "subagent-denied-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "subagent-denied-c1", %{
               "type" => "conversation.tool.requested",
               "data" => %{
                 "tool_call" => %{
                   "name" => "agent.spawn.blocked",
                   "args" => %{"goal" => "should fail"}
                 }
               },
               "meta" => %{"correlation_id" => "corr-subagent-denied"}
             })

    assert {:ok, timeline} =
             wait_for_timeline(project_id, "subagent-denied-c1", fn events ->
               Enum.any?(events, &(map_get(&1, "type") == "conversation.subagent.failed"))
             end)

    assert Enum.any?(timeline, fn event ->
             map_get(event, "type") == "conversation.tool.failed"
           end)

    diagnostics = Runtime.diagnostics(project_id)

    assert Map.get(diagnostics.telemetry.event_counts, "security.subagent.spawn_denied", 0) >= 1
  end

  defp template(template_id) do
    %{
      "template_id" => template_id,
      "agent_module" => Jido.Code.Server.SubAgentRuntimeTest.TestSubAgent,
      "initial_state" => %{},
      "allowed_tools" => ["asset.list"],
      "network_policy" => "deny",
      "env_allowlist" => [],
      "ttl_ms" => 300_000,
      "max_children_per_conversation" => 3,
      "spawn_timeout_ms" => 30_000
    }
  end

  defp wait_for_timeline(project_id, conversation_id, predicate, attempts \\ 40)

  defp wait_for_timeline(_project_id, _conversation_id, _predicate, 0),
    do: {:error, :timeline_timeout}

  defp wait_for_timeline(project_id, conversation_id, predicate, attempts) do
    case Runtime.conversation_projection(project_id, conversation_id, :timeline) do
      {:ok, timeline} when is_list(timeline) ->
        if predicate.(timeline) do
          {:ok, timeline}
        else
          Process.sleep(25)
          wait_for_timeline(project_id, conversation_id, predicate, attempts - 1)
        end

      _other ->
        Process.sleep(25)
        wait_for_timeline(project_id, conversation_id, predicate, attempts - 1)
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp map_get(_map, _key), do: nil
end
