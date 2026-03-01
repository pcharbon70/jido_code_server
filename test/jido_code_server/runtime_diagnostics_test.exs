defmodule Jido.Code.Server.RuntimeDiagnosticsTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

  alias Jido.Code.Server.Engine.ProjectRegistry
  alias Jido.Code.Server.Telemetry
  alias Jido.Code.Server.TestSupport.RuntimeSignal
  alias Jido.Code.Server.TestSupport.TempProject

  setup do
    Telemetry.reset()

    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "project and conversation diagnostics expose health and telemetry counters" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase7-diag",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "diag-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "diag-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "diag-c1", %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "hello"}
             })

    assert_eventually(
      fn ->
        Runtime.conversation_diagnostics(project_id, "diag-c1").status == :idle
      end,
      200
    )

    diagnostics = Runtime.diagnostics(project_id)

    assert diagnostics.project_id == project_id
    assert diagnostics.health.status == :ok
    assert diagnostics.assets.loaded?
    assert diagnostics.policy.project_id == project_id
    assert event_count(diagnostics, "project.started") >= 1
    assert event_count(diagnostics, "conversation.started") == 1
    assert event_count(diagnostics, "conversation.event_ingested") >= 1

    assert [%{conversation_id: "diag-c1"} = conversation_diag] = diagnostics.conversations
    assert conversation_diag.event_count >= 1
    assert conversation_diag.pending_tool_call_count == 0

    direct_diag = Runtime.conversation_diagnostics(project_id, "diag-c1")
    assert direct_diag.conversation_id == "diag-c1"
    assert direct_diag.status == :idle
    assert direct_diag.event_count >= conversation_diag.event_count
  end

  test "watcher debounces change events and reloads assets" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase7-watcher",
               watcher: true,
               watcher_debounce_ms: 40
             )

    new_skill_path = Path.join(root, ".jido/skills/new_skill.md")
    File.write!(new_skill_path, "# New Skill\n")

    [{watcher_pid, _}] = Registry.lookup(ProjectRegistry, {project_id, :watcher})

    send(watcher_pid, {:file_event, self(), {new_skill_path, [:modified]}})
    send(watcher_pid, {:file_event, self(), {new_skill_path, [:modified]}})

    assert_eventually(fn ->
      Runtime.list_assets(project_id, :skill)
      |> Enum.any?(&(&1.name == "new_skill"))
    end)

    assert_eventually(
      fn ->
        diagnostics = Runtime.diagnostics(project_id)

        event_count(diagnostics, "project.watcher_reload_completed") >= 1 and
          event_count(diagnostics, "project.assets_reloaded") >= 1
      end,
      200
    )

    diagnostics = Runtime.diagnostics(project_id)
    assert diagnostics.assets.counts.skill == 2
    assert event_count(diagnostics, "project.watcher_reload_completed") >= 1
    assert event_count(diagnostics, "project.assets_reloaded") >= 1
  end

  test "recent telemetry error counters surface degraded project health" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase7-errors",
               conversation_orchestration: true,
               llm_adapter: :deterministic,
               allow_tools: ["asset.list"]
             )

    assert {:ok, "errors-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "errors-c1")

    assert :ok =
             RuntimeSignal.send_signal(project_id, "errors-c1", %{
               "type" => "conversation.user.message",
               "data" => %{
                 "content" => "run command",
                 "llm" => %{
                   "tool_calls" => [%{"name" => "command.run.example_command", "args" => %{}}]
                 }
               }
             })

    assert_eventually(fn ->
      event_count(Runtime.diagnostics(project_id), "conversation.tool.failed") >= 1
    end)

    diagnostics = Runtime.diagnostics(project_id)

    assert diagnostics.health.status == :degraded
    assert event_count(diagnostics, "conversation.tool.failed") >= 1
    assert diagnostics.telemetry.recent_errors != []
  end

  defp event_count(diagnostics, event_name) do
    diagnostics.telemetry.event_counts
    |> Map.get(event_name, 0)
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0) do
    flunk("condition did not become true in time")
  end
end
