defmodule JidoCodeServer.ProjectPhase9Test do
  use ExUnit.Case, async: false

  alias JidoCodeServer.Project.AssetStore
  alias JidoCodeServer.Project.Layout
  alias JidoCodeServer.Project.Policy
  alias JidoCodeServer.Project.ToolRunner
  alias JidoCodeServer.Telemetry
  alias JidoCodeServer.TestSupport.TempProject

  setup do
    Telemetry.reset()

    on_exit(fn ->
      Enum.each(JidoCodeServer.list_projects(), fn %{project_id: project_id} ->
        _ = JidoCodeServer.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "tool runner rejects payloads that fail input schema validation" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = JidoCodeServer.start_project(root, project_id: "phase9-schema")

    assert {:error, %{status: :error, tool: "asset.search", reason: reason}} =
             JidoCodeServer.run_tool(project_id, %{
               name: "asset.search",
               args: %{"type" => "skill"}
             })

    assert {:invalid_tool_args, {:missing_required_args, ["query"]}} = reason
  end

  test "tool runner enforces output size caps" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_ctx =
      direct_project_ctx(root,
        project_id: "phase9-output-cap",
        tool_max_output_bytes: 64
      )

    assert {:error, %{status: :error, reason: {:output_too_large, _size, 64}}} =
             ToolRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})
  end

  test "policy decisions are audited and emitted in telemetry" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             JidoCodeServer.start_project(root,
               project_id: "phase9-policy-audit",
               allow_tools: ["asset.list"]
             )

    assert {:ok, %{status: :ok}} =
             JidoCodeServer.run_tool(project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"},
               meta: %{"conversation_id" => "phase9-c1"}
             })

    assert {:error, %{status: :error, reason: :denied}} =
             JidoCodeServer.run_tool(project_id, %{
               name: "asset.search",
               args: %{"type" => "skill", "query" => "example"},
               meta: %{"conversation_id" => "phase9-c1"}
             })

    diagnostics = JidoCodeServer.diagnostics(project_id)

    assert event_count(diagnostics, "policy.allowed") >= 1
    assert event_count(diagnostics, "policy.denied") >= 1

    assert Enum.any?(diagnostics.policy.recent_decisions, fn decision ->
             decision.conversation_id == "phase9-c1" and
               decision.tool_name == "asset.list" and
               decision.reason == :allowed
           end)

    assert Enum.any?(diagnostics.policy.recent_decisions, fn decision ->
             decision.conversation_id == "phase9-c1" and
               decision.tool_name == "asset.search" and
               decision.reason == :denied
           end)
  end

  test "sandbox violations emit security telemetry signals" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = JidoCodeServer.start_project(root, project_id: "phase9-sandbox")

    assert {:error, %{status: :error, reason: :outside_root}} =
             JidoCodeServer.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => "../outside.md"},
               meta: %{"conversation_id" => "phase9-c2"}
             })

    diagnostics = JidoCodeServer.diagnostics(project_id)
    assert event_count(diagnostics, "security.sandbox_violation") >= 1
  end

  test "telemetry redacts common secret patterns before persistence" do
    entry = emit_redaction_probe()
    assert entry
    error = entry.error

    assert error["api_key"] == "[REDACTED]"
    assert error["authorization"] == "[REDACTED]"
    assert error["nested"]["token"] == "[REDACTED]"
    assert entry.reason =~ "[REDACTED]"
    refute entry.reason =~ "dont-log-this"
  end

  test "repeated timeouts emit escalation telemetry signals" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_ctx =
      direct_project_ctx(root,
        project_id: "phase9-timeout",
        tool_timeout_ms: 0,
        tool_timeout_alert_threshold: 2
      )

    assert {:error, %{status: :error, reason: :timeout}} =
             ToolRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})

    assert {:error, %{status: :error, reason: :timeout}} =
             ToolRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})

    diagnostics = %{telemetry: Telemetry.snapshot("phase9-timeout")}
    assert event_count(diagnostics, "tool.timeout") >= 2
    assert event_count(diagnostics, "security.repeated_timeout_failures") >= 1
  end

  defp direct_project_ctx(root, opts) do
    layout = Layout.paths(root, ".jido")
    project_id = Keyword.fetch!(opts, :project_id)
    assert {:ok, asset_store} = AssetStore.start_link(project_id: project_id)
    assert :ok = AssetStore.load(asset_store, layout)

    assert {:ok, policy} =
             Policy.start_link(
               project_id: project_id,
               root_path: root,
               allow_tools: Keyword.get(opts, :allow_tools)
             )

    assert {:ok, task_supervisor} = Task.Supervisor.start_link()

    on_exit(fn ->
      stop_if_alive(task_supervisor)
      stop_if_alive(policy)
      stop_if_alive(asset_store)
    end)

    %{
      project_id: project_id,
      root_path: root,
      data_dir: ".jido",
      layout: layout,
      asset_store: asset_store,
      policy: policy,
      task_supervisor: task_supervisor,
      tool_timeout_ms: Keyword.get(opts, :tool_timeout_ms, 30_000),
      tool_timeout_alert_threshold: Keyword.get(opts, :tool_timeout_alert_threshold, 3),
      tool_max_output_bytes: Keyword.get(opts, :tool_max_output_bytes, 262_144),
      tool_max_artifact_bytes: Keyword.get(opts, :tool_max_artifact_bytes, 131_072),
      tool_max_concurrency: Keyword.get(opts, :tool_max_concurrency, 8)
    }
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_if_alive(_), do: :ok

  defp event_count(diagnostics, event_name) do
    diagnostics.telemetry.event_counts
    |> Map.get(event_name, 0)
  end

  defp emit_redaction_probe(attempts \\ 3)

  defp emit_redaction_probe(0), do: nil

  defp emit_redaction_probe(attempts) do
    Telemetry.emit("tool.failed", %{
      project_id: "phase9-redaction",
      error: %{
        "api_key" => "sk-ABCDEF1234567890ABCDEF1234567890",
        "authorization" => "Bearer very-secret-token-value",
        "nested" => %{"token" => "ghp_ABCDEFGHIJKLMNOPQRSTUV"}
      },
      reason: "authorization=Bearer dont-log-this"
    })

    case Telemetry.snapshot("phase9-redaction").recent_errors do
      [entry | _] ->
        entry

      [] ->
        Process.sleep(10)
        emit_redaction_probe(attempts - 1)
    end
  end
end
