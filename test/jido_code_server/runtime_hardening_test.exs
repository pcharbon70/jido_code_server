defmodule Jido.Code.Server.RuntimeHardeningTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

  alias Jido.Code.Server.Engine.ProjectRegistry
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.ExecutionRunner
  alias Jido.Code.Server.Project.Layout
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Telemetry
  alias Jido.Code.Server.TestSupport.RuntimeSignal
  alias Jido.Code.Server.TestSupport.TempProject

  @pending_task_table Module.concat(Jido.Code.Server.Conversation.ToolBridge, PendingTasks)
  @child_process_table Module.concat(Jido.Code.Server.Project.ExecutionRunner, ChildProcesses)

  defmodule ArtifactProbeExecutor do
    @behaviour JidoCommand.Extensibility.CommandRuntime

    @impl true
    def execute(_definition, _prompt, _params, _context) do
      {:ok,
       %{"artifacts" => [%{"type" => "text/plain", "content" => String.duplicate("A", 256)}]}}
    end
  end

  setup do
    Telemetry.reset()

    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "execution runner rejects payloads that fail input schema validation" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = Runtime.start_project(root, project_id: "phase9-schema")

    assert {:error, %{status: :error, tool: "asset.search", reason: reason}} =
             Runtime.run_tool(project_id, %{
               name: "asset.search",
               args: %{"type" => "skill"}
             })

    assert {:invalid_tool_args, {:missing_required_args, ["query"]}} = reason
  end

  test "execution runner enforces output size caps" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_ctx =
      direct_project_ctx(root,
        project_id: "phase9-output-cap",
        tool_max_output_bytes: 64
      )

    assert {:error, %{status: :error, reason: {:output_too_large, _size, 64}}} =
             ExecutionRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})
  end

  test "policy decisions are audited and emitted in telemetry" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-policy-c1"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-policy-audit",
               allow_tools: ["asset.list"]
             )

    assert {:ok, ok_result} =
             Runtime.run_tool(project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"},
               meta: %{"conversation_id" => "phase9-c1", "correlation_id" => correlation_id}
             })

    assert ok_result.status == :ok
    assert ok_result.correlation_id == correlation_id

    assert {:error, denied_result} =
             Runtime.run_tool(project_id, %{
               name: "asset.search",
               args: %{"type" => "skill", "query" => "example"},
               meta: %{"conversation_id" => "phase9-c1", "correlation_id" => correlation_id}
             })

    assert denied_result.status == :error
    assert denied_result.reason == :denied
    assert denied_result.correlation_id == correlation_id

    diagnostics = Runtime.diagnostics(project_id)

    assert event_count(diagnostics, "policy.allowed") >= 1
    assert event_count(diagnostics, "policy.denied") >= 1

    assert Enum.any?(diagnostics.policy.recent_decisions, fn decision ->
             decision.conversation_id == "phase9-c1" and
               decision.correlation_id == correlation_id and
               decision.tool_name == "asset.list" and
               decision.reason == :allowed
           end)

    assert Enum.any?(diagnostics.policy.recent_decisions, fn decision ->
             decision.conversation_id == "phase9-c1" and
               decision.correlation_id == correlation_id and
               decision.tool_name == "asset.search" and
               decision.reason == :denied
           end)
  end

  test "conversation runtime propagates provided correlation id across llm, tool, and policy paths" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-conversation-tool"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-correlation-tool",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase9-corr-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-corr-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-corr-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "please list skills"},
                 "meta" => %{"correlation_id" => correlation_id}
               }
             )

    assert {:ok, timeline} =
             Runtime.conversation_projection(project_id, "phase9-corr-c1", :timeline)

    correlation_ids =
      timeline
      |> Enum.map(fn event ->
        event
        |> map_lookup(:meta)
        |> map_lookup(:correlation_id)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assert correlation_ids == [correlation_id]

    assert Enum.any?(timeline, fn event ->
             map_lookup(event, :type) == "conversation.tool.requested"
           end)

    assert Enum.any?(timeline, fn event ->
             map_lookup(event, :type) == "conversation.tool.completed"
           end)

    tool_completed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.tool.completed"
      end)

    result = map_lookup(tool_completed, :data) |> map_lookup(:result)
    assert map_lookup(result, :correlation_id) == correlation_id

    diagnostics = Runtime.diagnostics(project_id)

    assert Enum.any?(diagnostics.policy.recent_decisions, fn decision ->
             decision.conversation_id == "phase9-corr-c1" and
               decision.correlation_id == correlation_id and
               decision.tool_name == "asset.list" and
               decision.reason == :allowed
           end)
  end

  test "conversation runtime generates and reuses correlation id when ingest event omits one" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-correlation-generate",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase9-corr-c2"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-corr-c2")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-corr-c2",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "hello"}
               }
             )

    assert {:ok, timeline} =
             Runtime.conversation_projection(project_id, "phase9-corr-c2", :timeline)

    correlation_ids =
      timeline
      |> Enum.map(fn event ->
        event
        |> map_lookup(:meta)
        |> map_lookup(:correlation_id)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    assert length(correlation_ids) == 1
    assert [generated_correlation_id] = correlation_ids
    assert String.starts_with?(generated_correlation_id, "corr-")
  end

  test "incident timeline API returns bounded merged conversation and telemetry entries" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-incident-c1"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-incident-timeline",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase9-incident-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-incident-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-incident-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "please list skills"},
                 "meta" => %{"correlation_id" => correlation_id}
               }
             )

    assert {:ok, timeline} =
             Runtime.incident_timeline(project_id, "phase9-incident-c1",
               limit: 50,
               correlation_id: correlation_id
             )

    assert timeline.project_id == project_id
    assert timeline.conversation_id == "phase9-incident-c1"
    assert timeline.correlation_id == correlation_id
    assert timeline.limit == 50
    assert timeline.total_entries >= length(timeline.entries)
    assert length(timeline.entries) <= 50

    assert Enum.all?(timeline.entries, fn entry ->
             entry.conversation_id == "phase9-incident-c1" and
               entry.correlation_id == correlation_id
           end)

    sources =
      timeline.entries
      |> Enum.map(& &1.source)
      |> MapSet.new()

    assert MapSet.member?(sources, :conversation)
    assert MapSet.member?(sources, :telemetry)

    assert Enum.any?(timeline.entries, fn entry ->
             entry.source == :telemetry and entry.event == "conversation.tool.completed"
           end)

    refute Enum.any?(timeline.entries, fn entry ->
             entry.source == :telemetry and
               entry.event in ["event_ingested", "conversation.event_ingested"]
           end)
  end

  test "incident timeline maps conversation.tool.failed telemetry cancellation reasons to conversation.tool.cancelled" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-incident-telemetry-cancelled"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-incident-telemetry-cancelled",
               conversation_orchestration: false
             )

    assert {:ok, "phase9-incident-telemetry-cancelled-c1"} =
             Runtime.start_conversation(project_id,
               conversation_id: "phase9-incident-telemetry-cancelled-c1"
             )

    assert :ok =
             Telemetry.emit("conversation.tool.failed", %{
               project_id: project_id,
               conversation_id: "phase9-incident-telemetry-cancelled-c1",
               correlation_id: correlation_id,
               reason: :conversation_cancelled
             })

    assert {:ok, timeline} =
             Runtime.incident_timeline(project_id, "phase9-incident-telemetry-cancelled-c1",
               correlation_id: correlation_id,
               limit: 50
             )

    assert Enum.any?(timeline.entries, fn entry ->
             entry.source == :telemetry and entry.event == "conversation.tool.cancelled"
           end)

    refute Enum.any?(timeline.entries, fn entry ->
             entry.source == :telemetry and entry.event == "conversation.tool.failed"
           end)
  end

  test "incident timeline remains queryable after conversation stop when canonical history exists" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-incident-stopped-c1"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-incident-stopped",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase9-incident-stopped-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-incident-stopped-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-incident-stopped-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "persist incident history"},
                 "meta" => %{"correlation_id" => correlation_id}
               }
             )

    assert_eventually(fn ->
      case Runtime.conversation_projection(
             project_id,
             "phase9-incident-stopped-c1",
             :canonical_timeline
           ) do
        {:ok, timeline} ->
          Enum.any?(timeline, fn entry ->
            map_lookup(entry, :type) == "conv.in.message.received"
          end)

        _ ->
          false
      end
    end)

    assert :ok = Runtime.stop_conversation(project_id, "phase9-incident-stopped-c1")

    assert {:ok, timeline} =
             Runtime.incident_timeline(project_id, "phase9-incident-stopped-c1", limit: 50)

    assert timeline.project_id == project_id
    assert timeline.conversation_id == "phase9-incident-stopped-c1"
    assert timeline.correlation_id == nil
    assert timeline.total_entries >= length(timeline.entries)
    assert timeline.entries != []

    assert Enum.all?(timeline.entries, fn entry ->
             entry.conversation_id == "phase9-incident-stopped-c1"
           end)

    assert Enum.any?(timeline.entries, fn entry ->
             entry.source == :conversation and entry.event == "conversation.user.message"
           end)

    refute Enum.any?(timeline.entries, fn entry ->
             entry.source == :conversation and String.starts_with?(entry.event, "conv.")
           end)
  end

  test "incident timeline correlation filters still work after conversation stop with canonical history" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-incident-stopped-filter-c1"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-incident-stopped-filter",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase9-incident-stopped-filter-c1"} =
             Runtime.start_conversation(project_id,
               conversation_id: "phase9-incident-stopped-filter-c1"
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-incident-stopped-filter-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "preserve correlation"},
                 "meta" => %{"correlation_id" => correlation_id}
               }
             )

    assert_eventually(fn ->
      case Runtime.conversation_projection(
             project_id,
             "phase9-incident-stopped-filter-c1",
             :canonical_timeline
           ) do
        {:ok, timeline} ->
          Enum.any?(timeline, fn entry ->
            map_lookup(entry, :type) == "conv.in.message.received"
          end)

        _ ->
          false
      end
    end)

    assert :ok = Runtime.stop_conversation(project_id, "phase9-incident-stopped-filter-c1")

    assert {:ok, timeline} =
             Runtime.incident_timeline(project_id, "phase9-incident-stopped-filter-c1",
               correlation_id: correlation_id,
               limit: 50
             )

    assert timeline.project_id == project_id
    assert timeline.conversation_id == "phase9-incident-stopped-filter-c1"
    assert timeline.correlation_id == correlation_id
    assert timeline.total_entries >= length(timeline.entries)
    assert timeline.entries != []

    assert Enum.all?(timeline.entries, fn entry ->
             entry.conversation_id == "phase9-incident-stopped-filter-c1" and
               entry.correlation_id == correlation_id
           end)

    assert Enum.any?(timeline.entries, fn entry ->
             entry.source == :conversation and entry.event == "conversation.user.message"
           end)

    refute Enum.any?(timeline.entries, fn entry ->
             entry.source == :conversation and String.starts_with?(entry.event, "conv.")
           end)
  end

  test "incident timeline maps atom conversation_cancelled tool failures to conversation.tool.cancelled" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-incident-atom-cancelled"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-incident-atom-cancelled",
               conversation_orchestration: false
             )

    assert {:ok, "phase9-incident-atom-cancelled-c1"} =
             Runtime.start_conversation(project_id,
               conversation_id: "phase9-incident-atom-cancelled-c1"
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-incident-atom-cancelled-c1",
               %{
                 "type" => "conversation.tool.failed",
                 "meta" => %{"correlation_id" => correlation_id},
                 "data" => %{
                   "name" => "asset.list",
                   "reason" => :conversation_cancelled
                 }
               }
             )

    assert :ok = Runtime.stop_conversation(project_id, "phase9-incident-atom-cancelled-c1")

    assert {:ok, timeline} =
             Runtime.incident_timeline(project_id, "phase9-incident-atom-cancelled-c1",
               correlation_id: correlation_id,
               limit: 50
             )

    assert Enum.any?(timeline.entries, fn entry ->
             entry.source == :conversation and entry.event == "conversation.tool.cancelled"
           end)

    refute Enum.any?(timeline.entries, fn entry ->
             entry.source == :conversation and entry.event == "conversation.tool.failed"
           end)
  end

  test "incident timeline maps conversation.tool.failed cancellation message values to conversation.tool.cancelled" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-incident-failed-message-cancelled"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-incident-failed-message-cancelled",
               conversation_orchestration: false
             )

    assert {:ok, "phase9-incident-failed-message-cancelled-c1"} =
             Runtime.start_conversation(project_id,
               conversation_id: "phase9-incident-failed-message-cancelled-c1"
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-incident-failed-message-cancelled-c1",
               %{
                 "type" => "conversation.tool.failed",
                 "meta" => %{"correlation_id" => correlation_id},
                 "data" => %{
                   "name" => "asset.list",
                   "message" => :conversation_cancelled
                 }
               }
             )

    assert {:ok, timeline} =
             Runtime.incident_timeline(project_id, "phase9-incident-failed-message-cancelled-c1",
               correlation_id: correlation_id,
               limit: 50
             )

    assert Enum.any?(timeline.entries, fn entry ->
             entry.source == :conversation and entry.event == "conversation.tool.cancelled"
           end)

    refute Enum.any?(timeline.entries, fn entry ->
             entry.source == :conversation and entry.event == "conversation.tool.failed"
           end)
  end

  test "incident timeline API returns conversation-not-found error for unknown conversation" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root, project_id: "phase9-incident-not-found")

    assert {:error, {:conversation_not_found, "missing-c1"}} =
             Runtime.incident_timeline(project_id, "missing-c1")
  end

  test "sandbox violations emit security telemetry signals" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sandbox",
               network_egress_policy: :allow
             )

    assert {:error, %{status: :error, reason: :outside_root}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => "../outside.md"},
               meta: %{"conversation_id" => "phase9-c2"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.sandbox_violation") >= 1
  end

  test "nested and JSON-wrapped path args are sandbox-validated" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sandbox-nested",
               network_egress_policy: :allow
             )

    assert {:error, %{status: :error, reason: :outside_root}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"payload" => %{"path" => "../outside.md"}},
               meta: %{"conversation_id" => "phase9-c2-nested"}
             })

    assert {:error, %{status: :error, reason: :outside_root}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"payload" => Jason.encode!(%{"path" => "../outside-json.md"})},
               meta: %{"conversation_id" => "phase9-c2-json"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.sandbox_violation") >= 2
  end

  test "opaque serialized path payloads are sandbox-validated" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sandbox-opaque",
               network_egress_policy: :allow
             )

    assert {:error, %{status: :error, reason: :outside_root}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"payload" => "path=../outside-opaque.md"},
               meta: %{"conversation_id" => "phase9-c2-opaque"}
             })

    assert {:error, %{status: :error, reason: :outside_root}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => "path=../outside-opaque-direct.md"},
               meta: %{"conversation_id" => "phase9-c2-opaque"}
             })

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"payload" => "path=.jido/commands/example_command.md"},
               meta: %{"conversation_id" => "phase9-c2-opaque"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.sandbox_violation") >= 2
  end

  test "outside-root allowlist permits explicit exceptions and emits reason-coded security signal" do
    root = TempProject.create!(with_seed_files: true)

    outside_root =
      Path.join(
        System.tmp_dir!(),
        "jido_code_server_phase9_allowlisted_#{System.unique_integer([:positive])}"
      )

    outside_path = Path.join(outside_root, "allowlisted.md")

    File.mkdir_p!(outside_root)
    File.write!(outside_path, "# outside root path\n")

    on_exit(fn -> TempProject.cleanup(root) end)
    on_exit(fn -> File.rm_rf(outside_root) end)

    reason_code = "OPS-OUTSIDE-001"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sandbox-allow",
               network_egress_policy: :allow,
               outside_root_allowlist: [
                 %{"path" => outside_path, "reason_code" => reason_code}
               ]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => outside_path},
               meta: %{"conversation_id" => "phase9-c2-allow"}
             })

    assert {:ok, expected_pattern} = Policy.normalize_path("/", outside_path)
    expected_pattern = String.replace(expected_pattern, "\\", "/")
    diagnostics = Runtime.diagnostics(project_id)

    assert diagnostics.policy.outside_root_allowlist == [
             %{pattern: expected_pattern, reason_code: reason_code}
           ]

    assert event_count(diagnostics, "security.sandbox_exception_used") >= 1

    assert Enum.any?(diagnostics.policy.recent_decisions, fn decision ->
             decision.conversation_id == "phase9-c2-allow" and
               decision.tool_name == "command.run.example_command" and
               decision.reason == :allowed and
               reason_code in List.wrap(decision.outside_root_exception_reason_codes)
           end)
  end

  test "outside-root allowlist does not bypass sensitive path denylist" do
    root = TempProject.create!(with_seed_files: true)

    outside_root =
      Path.join(
        System.tmp_dir!(),
        "jido_code_server_phase9_allowlisted_sensitive_#{System.unique_integer([:positive])}"
      )

    outside_path = Path.join(outside_root, ".env")

    File.mkdir_p!(outside_root)
    File.write!(outside_path, "SECRET=outside\n")

    on_exit(fn -> TempProject.cleanup(root) end)
    on_exit(fn -> File.rm_rf(outside_root) end)

    reason_code = "OPS-OUTSIDE-SENSITIVE-001"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sandbox-allow-sensitive-deny",
               network_egress_policy: :allow,
               outside_root_allowlist: [
                 %{"path" => outside_path, "reason_code" => reason_code}
               ]
             )

    assert {:error, %{status: :error, reason: :sensitive_path_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => outside_path},
               meta: %{"conversation_id" => "phase9-c2-allow-sensitive-deny"}
             })

    diagnostics = Runtime.diagnostics(project_id)

    assert event_count(diagnostics, "security.sensitive_path_denied") >= 1
    assert event_count(diagnostics, "security.sandbox_exception_used") == 0
  end

  test "sensitive path allowlist can explicitly permit allowlisted outside-root sensitive paths" do
    root = TempProject.create!(with_seed_files: true)

    outside_root =
      Path.join(
        System.tmp_dir!(),
        "jido_code_server_phase9_allowlisted_sensitive_ok_#{System.unique_integer([:positive])}"
      )

    outside_path = Path.join(outside_root, ".env")

    File.mkdir_p!(outside_root)
    File.write!(outside_path, "SECRET=outside\n")

    on_exit(fn -> TempProject.cleanup(root) end)
    on_exit(fn -> File.rm_rf(outside_root) end)

    reason_code = "OPS-OUTSIDE-SENSITIVE-002"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sandbox-allow-sensitive-allowlist",
               network_egress_policy: :allow,
               outside_root_allowlist: [
                 %{"path" => outside_path, "reason_code" => reason_code}
               ],
               sensitive_path_allowlist: [".env"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => outside_path},
               meta: %{"conversation_id" => "phase9-c2-allow-sensitive-allowlist"}
             })

    diagnostics = Runtime.diagnostics(project_id)

    assert event_count(diagnostics, "security.sandbox_exception_used") >= 1
    assert event_count(diagnostics, "security.sensitive_path_denied") == 0
  end

  test "conversation cancel emits deterministic tool.cancelled events for pending tool calls" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-conversation-cancel",
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, "phase9-cancel-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-cancel-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-cancel-c1",
               %{
                 "type" => "conversation.cancel"
               }
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-cancel-c1",
               %{
                 "type" => "conversation.tool.requested",
                 "data" => %{
                   "name" => "asset.list",
                   "args" => %{"type" => "skill"}
                 }
               }
             )

    assert {:ok, pending_before_cancel} =
             Runtime.conversation_projection(project_id, "phase9-cancel-c1", :pending_tool_calls)

    assert length(pending_before_cancel) == 1

    correlation_id = "corr-phase9-cancel-c1"

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-cancel-c1",
               %{
                 "type" => "conversation.cancel",
                 "meta" => %{"correlation_id" => correlation_id}
               }
             )

    assert {:ok, timeline} =
             Runtime.conversation_projection(project_id, "phase9-cancel-c1", :timeline)

    cancelled_event =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "conversation.tool.cancelled"
      end)

    assert cancelled_event
    assert map_lookup(cancelled_event, :data) |> map_lookup(:name) == "asset.list"
    assert map_lookup(cancelled_event, :data) |> map_lookup(:reason) == "conversation_cancelled"
    assert map_lookup(cancelled_event, :meta) |> map_lookup(:correlation_id) == correlation_id

    assert {:ok, []} =
             Runtime.conversation_projection(project_id, "phase9-cancel-c1", :pending_tool_calls)

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "conversation.tool.cancelled") >= 1
  end

  test "async tool requests complete via background bridge and clear pending projection" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    correlation_id = "corr-phase9-async-complete"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-async-complete",
               conversation_orchestration: true,
               network_egress_policy: :allow
             )

    assert {:ok, "phase9-async-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-async-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-async-c1",
               %{
                 "type" => "conversation.tool.requested",
                 "meta" => %{"correlation_id" => correlation_id},
                 "data" => %{
                   "name" => "command.run.example_command",
                   "args" => %{
                     "path" => ".jido/commands/example_command.md",
                     "simulate_delay_ms" => 150
                   },
                   "meta" => %{"run_mode" => "async"}
                 }
               }
             )

    assert {:ok, timeline_before} =
             Runtime.conversation_projection(project_id, "phase9-async-c1", :timeline)

    refute Enum.any?(timeline_before, fn event ->
             map_lookup(event, :type) == "conversation.tool.completed"
           end)

    assert_eventually(fn ->
      {:ok, timeline_after} =
        Runtime.conversation_projection(project_id, "phase9-async-c1", :timeline)

      Enum.any?(timeline_after, fn event ->
        map_lookup(event, :type) == "conversation.tool.completed" and
          map_lookup(event, :meta) |> map_lookup(:correlation_id) == correlation_id
      end)
    end)

    assert_eventually(fn ->
      {:ok, pending_calls} =
        Runtime.conversation_projection(project_id, "phase9-async-c1", :pending_tool_calls)

      pending_calls == []
    end)
  end

  test "conversation cancel terminates async pending tools and emits tool.cancelled" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)
    request_correlation_id = "corr-phase9-async-cancel-request"
    cancel_correlation_id = "corr-phase9-async-cancel"

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-async-cancel",
               conversation_orchestration: true,
               network_egress_policy: :allow
             )

    assert {:ok, "phase9-async-c2"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-async-c2")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-async-c2",
               %{
                 "type" => "conversation.tool.requested",
                 "meta" => %{"correlation_id" => request_correlation_id},
                 "data" => %{
                   "name" => "command.run.example_command",
                   "args" => %{
                     "path" => ".jido/commands/example_command.md",
                     "simulate_delay_ms" => 500
                   },
                   "meta" => %{"run_mode" => "async"}
                 }
               }
             )

    pending_task_pid = wait_for_pending_task_pid(project_id, "phase9-async-c2")
    child_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(child_pid), do: Process.exit(child_pid, :kill)
      :ok
    end)

    :ok = ExecutionRunner.register_child_process(pending_task_pid, child_pid)

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-async-c2",
               %{
                 "type" => "conversation.cancel",
                 "meta" => %{"correlation_id" => cancel_correlation_id}
               }
             )

    assert_eventually(fn ->
      {:ok, timeline} = Runtime.conversation_projection(project_id, "phase9-async-c2", :timeline)

      Enum.any?(timeline, fn event ->
        map_lookup(event, :type) == "conversation.tool.cancelled" and
          map_lookup(event, :data) |> map_lookup(:reason) == "conversation_cancelled" and
          map_lookup(event, :meta) |> map_lookup(:correlation_id) == cancel_correlation_id
      end)
    end)

    Process.sleep(600)

    assert {:ok, timeline} =
             Runtime.conversation_projection(project_id, "phase9-async-c2", :timeline)

    refute Enum.any?(timeline, fn event ->
             map_lookup(event, :type) == "conversation.tool.completed" and
               map_lookup(event, :data) |> map_lookup(:name) == "command.run.example_command" and
               map_lookup(event, :meta) |> map_lookup(:correlation_id) == request_correlation_id
           end)

    assert_eventually(fn -> not Process.alive?(child_pid) end)

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "conversation.tool.cancelled") >= 1
    assert event_count(diagnostics, "conversation.tool.child_processes_terminated") >= 1
  end

  test "workspace executor sessions are tracked as child processes for async cancellation" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    command_path = Path.join(root, ".jido/commands/example_command.md")
    File.write!(command_path, valid_workspace_sleep_command_markdown())

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-workspace-child-tracking",
               conversation_orchestration: true,
               network_egress_policy: :allow,
               command_executor: :workspace_shell
             )

    assert {:ok, "phase9-workspace-child-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-workspace-child-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-workspace-child-c1",
               %{
                 "type" => "conversation.tool.requested",
                 "data" => %{
                   "name" => "command.run.example_command",
                   "args" => %{"path" => ".jido/commands/example_command.md"},
                   "meta" => %{"run_mode" => "async"}
                 }
               }
             )

    pending_task_pid = wait_for_pending_task_pid(project_id, "phase9-workspace-child-c1")

    assert_eventually(fn ->
      tracked_child_count(pending_task_pid) >= 2
    end)

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-workspace-child-c1",
               %{
                 "type" => "conversation.cancel"
               }
             )

    assert_eventually(fn ->
      {:ok, timeline} =
        Runtime.conversation_projection(project_id, "phase9-workspace-child-c1", :timeline)

      Enum.any?(timeline, fn event ->
        map_lookup(event, :type) == "conversation.tool.cancelled"
      end)
    end)

    assert_eventually(fn ->
      tracked_child_count(pending_task_pid) == 0
    end)

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "conversation.tool.child_processes_terminated") >= 1
  end

  test "workspace executor sessions are terminated on timeout without manual PID registration" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    command_path = Path.join(root, ".jido/commands/example_command.md")
    File.write!(command_path, valid_workspace_sleep_command_markdown())

    project_ctx =
      direct_project_ctx(root,
        project_id: "phase9-workspace-timeout-cleanup",
        network_egress_policy: :allow,
        command_executor: Jido.Code.Server.Project.CommandExecutor.WorkspaceShell,
        tool_timeout_ms: 1_500
      )

    run_task =
      Task.async(fn ->
        ExecutionRunner.run(project_ctx, %{
          name: "command.run.example_command",
          args: %{"path" => ".jido/commands/example_command.md"}
        })
      end)

    assert_eventually(fn ->
      tracked_child_count(run_task.pid) >= 2
    end)

    assert {:error, %{status: :error, reason: :timeout}} = Task.await(run_task, 2_000)

    assert_eventually(fn ->
      tracked_child_count(run_task.pid) == 0
    end)

    diagnostics = %{telemetry: Telemetry.snapshot("phase9-workspace-timeout-cleanup")}
    assert event_count(diagnostics, "conversation.tool.child_processes_terminated") >= 1
  end

  test "execution runner prunes dead child registrations after successful execution" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_ctx =
      direct_project_ctx(root,
        project_id: "phase9-child-process-prune",
        network_egress_policy: :allow
      )

    run_task =
      Task.async(fn ->
        ExecutionRunner.run(project_ctx, %{
          name: "command.run.example_command",
          args: %{
            "path" => ".jido/commands/example_command.md",
            "simulate_delay_ms" => 600
          }
        })
      end)

    assert_eventually(fn ->
      tracked_child_count(run_task.pid) >= 1
    end)

    stale_child = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(stale_child), do: Process.exit(stale_child, :kill) end)

    assert :ok = ExecutionRunner.register_child_process(run_task.pid, stale_child)
    Process.exit(stale_child, :kill)

    assert_eventually(fn ->
      not Process.alive?(stale_child)
    end)

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Task.await(run_task, 2_000)

    assert_eventually(fn ->
      tracked_child_count(run_task.pid) == 0
    end)
  end

  test "sensitive file paths are denied by default and emit security signal" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sensitive-path-deny",
               network_egress_policy: :allow
             )

    assert {:error, %{status: :error, reason: :sensitive_path_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => ".env"},
               meta: %{"conversation_id" => "phase9-sensitive-c1"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.sensitive_path_denied") >= 1
  end

  test "tool env passthrough is denied by default and emits security signal" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-env-deny",
               network_egress_policy: :allow
             )

    assert {:error, %{status: :error, reason: {:env_vars_not_allowed, ["OPENAI_API_KEY"]}}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "env" => %{"OPENAI_API_KEY" => "sk-test"}
               },
               meta: %{"conversation_id" => "phase9-env-c1"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.env_denied") >= 1
  end

  test "tool env allowlist permits explicit environment keys" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-env-allow",
               network_egress_policy: :allow,
               tool_env_allowlist: ["LANG", "OPENAI_API_KEY"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "env" => %{"LANG" => "en_US.UTF-8", "OPENAI_API_KEY" => "sk-test"}
               },
               meta: %{"conversation_id" => "phase9-env-c2"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert diagnostics.runtime_opts[:tool_env_allowlist] == ["LANG", "OPENAI_API_KEY"]
  end

  test "tool env payload must be a map when provided" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-env-invalid",
               network_egress_policy: :allow
             )

    assert {:error, %{status: :error, reason: :invalid_env_payload}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "env" => ["OPENAI_API_KEY=sk-test"]
               },
               meta: %{"conversation_id" => "phase9-env-c3"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.env_denied") >= 1
  end

  test "sensitive path allowlist can explicitly permit denylisted paths" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sensitive-path-allow",
               network_egress_policy: :allow,
               sensitive_path_allowlist: [".env"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => ".env"},
               meta: %{"conversation_id" => "phase9-sensitive-c2"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert diagnostics.policy.sensitive_path_allowlist == [".env"]
  end

  test "execution runner flags sensitive artifacts in result payloads and emits security signal" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-sensitive-artifact",
               network_egress_policy: :allow,
               sensitive_path_allowlist: [".env"]
             )

    assert {:ok, result} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".env",
                 "api_key" => "sk-ABCDEF1234567890ABCDEF1234567890"
               },
               meta: %{"conversation_id" => "phase9-sensitive-c3"}
             })

    assert result.status == :ok
    assert "sensitive_artifact_detected" in List.wrap(result.risk_flags)
    assert result.sensitivity_findings_count >= 1
    assert "sensitive_key" in List.wrap(result.sensitivity_finding_kinds)

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.sensitive_artifact_detected") >= 1
  end

  test "network egress deny-by-default hides network-capable tools and rejects execution" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root, project_id: "phase9-network-deny")

    tool_names =
      project_id
      |> Runtime.list_tools()
      |> Enum.map(& &1.name)

    refute "command.run.example_command" in tool_names
    refute "workflow.run.example_workflow" in tool_names

    assert {:error, %{status: :error, reason: :network_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => ".jido/commands/example_command.md"},
               meta: %{"conversation_id" => "phase9-network-c1"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network egress allow exposes network-capable tools and permits execution" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-allow",
               network_egress_policy: :allow
             )

    tool_names =
      project_id
      |> Runtime.list_tools()
      |> Enum.map(& &1.name)

    assert "command.run.example_command" in tool_names
    assert "workflow.run.example_workflow" in tool_names

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{"path" => ".jido/commands/example_command.md"}
             })
  end

  test "network allowlist blocks disallowed endpoint targets" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-allowlist",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "url" => "https://api.example.com/v1/status"
               },
               meta: %{"conversation_id" => "phase9-network-c2"}
             })

    assert {:error, %{status: :error, reason: :network_endpoint_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "url" => "https://evil.test/payload"
               },
               meta: %{"conversation_id" => "phase9-network-c2"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network allowlist inspects nested endpoint targets and host values" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-allowlist-nested",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "request" => %{"endpoint" => "https://api.example.com/v1/status"}
               },
               meta: %{"conversation_id" => "phase9-network-c2-nested"}
             })

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "connection" => %{"host" => "api.example.com:443"}
               },
               meta: %{"conversation_id" => "phase9-network-c2-nested"}
             })

    assert {:error, %{status: :error, reason: :network_endpoint_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "requests" => [%{"endpoint" => "https://evil.test/payload"}]
               },
               meta: %{"conversation_id" => "phase9-network-c2-nested"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network allowlist inspects JSON-encoded endpoint payloads" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-allowlist-json",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "endpoint" => ~s({"url":"https://api.example.com/v1/status"})
               },
               meta: %{"conversation_id" => "phase9-network-c2-json"}
             })

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "endpoint" => ~s({"host":"api.example.com:443"})
               },
               meta: %{"conversation_id" => "phase9-network-c2-json"}
             })

    assert {:error, %{status: :error, reason: :network_endpoint_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "endpoint" => ~s({"url":"https://evil.test/payload"})
               },
               meta: %{"conversation_id" => "phase9-network-c2-json"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network allowlist inspects JSON payload wrappers under non-network keys" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-allowlist-json-wrapper",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "payload" => ~s({"request":{"endpoint":"https://api.example.com/v1/status"}})
               },
               meta: %{"conversation_id" => "phase9-network-c2-json-wrapper"}
             })

    assert {:error, %{status: :error, reason: :network_endpoint_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "payload" => ~s({"request":{"endpoint":"https://evil.test/payload"}})
               },
               meta: %{"conversation_id" => "phase9-network-c2-json-wrapper"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network allowlist inspects opaque serialized payload wrappers" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-allowlist-opaque",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "payload" => "curl https://api.example.com/v1/status"
               },
               meta: %{"conversation_id" => "phase9-network-c2-opaque"}
             })

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "payload" => "host=api.example.com:443"
               },
               meta: %{"conversation_id" => "phase9-network-c2-opaque"}
             })

    assert {:error, %{status: :error, reason: :network_endpoint_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "payload" => "fetch https://evil.test/payload"
               },
               meta: %{"conversation_id" => "phase9-network-c2-opaque"}
             })

    assert {:error, %{status: :error, reason: :network_endpoint_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "payload" => "host=evil.test:443"
               },
               meta: %{"conversation_id" => "phase9-network-c2-opaque"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network egress allow denies high-risk protocols by default" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-protocol-deny",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:error, %{status: :error, reason: :network_protocol_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "url" => "ftp://api.example.com/v1/status"
               },
               meta: %{"conversation_id" => "phase9-network-c3"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network scheme guardrails inspect nested URL targets" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-protocol-nested",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:error, %{status: :error, reason: :network_protocol_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "request" => %{"endpoint" => "ftp://api.example.com/v1/status"}
               },
               meta: %{"conversation_id" => "phase9-network-c3-nested"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network scheme guardrails inspect JSON-encoded endpoint payloads" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-protocol-json",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:error, %{status: :error, reason: :network_protocol_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "endpoint" => ~s({"url":"ftp://api.example.com/v1/status"})
               },
               meta: %{"conversation_id" => "phase9-network-c3-json"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network scheme guardrails inspect JSON payload wrappers under non-network keys" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-protocol-json-wrapper",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:error, %{status: :error, reason: :network_protocol_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "payload" => ~s({"request":{"endpoint":"ftp://api.example.com/v1/status"}})
               },
               meta: %{"conversation_id" => "phase9-network-c3-json-wrapper"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network scheme guardrails inspect opaque serialized payload wrappers" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-protocol-opaque",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"]
             )

    assert {:error, %{status: :error, reason: :network_protocol_denied}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "payload" => "curl ftp://api.example.com/v1/status"
               },
               meta: %{"conversation_id" => "phase9-network-c3-opaque"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert event_count(diagnostics, "security.network_denied") >= 1
  end

  test "network allowed schemes option permits explicitly allowed protocol" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-network-protocol-allow",
               network_egress_policy: :allow,
               network_allowlist: ["example.com"],
               network_allowed_schemes: ["https", "ftp"]
             )

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Runtime.run_tool(project_id, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "url" => "ftp://api.example.com/v1/status"
               },
               meta: %{"conversation_id" => "phase9-network-c4"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert diagnostics.policy.network_allowed_schemes == ["ftp", "https"]
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
             ExecutionRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})

    assert {:error, %{status: :error, reason: :timeout}} =
             ExecutionRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})

    diagnostics = %{telemetry: Telemetry.snapshot("phase9-timeout")}
    assert event_count(diagnostics, "conversation.tool.timeout") >= 2
    assert event_count(diagnostics, "security.repeated_timeout_failures") >= 1
  end

  test "timeouts terminate registered child processes and emit cleanup telemetry" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_ctx =
      direct_project_ctx(root,
        project_id: "phase9-timeout-child-termination",
        tool_timeout_ms: 0
      )

    child_pid = spawn(fn -> Process.sleep(:infinity) end)

    on_exit(fn ->
      if Process.alive?(child_pid), do: Process.exit(child_pid, :kill)
      :ok
    end)

    :ok = ExecutionRunner.register_child_process(self(), child_pid)

    assert {:error, %{status: :error, reason: :timeout}} =
             ExecutionRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})

    assert_eventually(fn -> not Process.alive?(child_pid) end)

    diagnostics = %{telemetry: Telemetry.snapshot("phase9-timeout-child-termination")}
    assert event_count(diagnostics, "conversation.tool.child_processes_terminated") >= 1
  end

  test "project runtime options tune tool guardrails" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-runtime-opts",
               tool_max_output_bytes: 64
             )

    assert {:error, %{status: :error, reason: {:output_too_large, _size, 64}}} =
             Runtime.run_tool(project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"}
             })

    diagnostics = Runtime.diagnostics(project_id)

    assert diagnostics.runtime_opts[:tool_max_output_bytes] == 64
  end

  test "artifact size caps apply to nested command runtime artifacts" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    command_path = Path.join(root, ".jido/commands/example_command.md")
    File.write!(command_path, valid_command_markdown())

    project_ctx =
      direct_project_ctx(root,
        project_id: "phase9-artifact-cap",
        network_egress_policy: :allow,
        command_executor: ArtifactProbeExecutor,
        tool_max_output_bytes: 1_000_000,
        tool_max_artifact_bytes: 64
      )

    assert {:error, %{status: :error, reason: {:artifact_too_large, _index, _size, 64}}} =
             ExecutionRunner.run(project_ctx, %{
               name: "command.run.example_command",
               args: %{
                 "path" => ".jido/commands/example_command.md",
                 "query" => "artifact-check"
               }
             })
  end

  test "project-wide concurrency guardrail blocks over-limit tool calls" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_ctx =
      direct_project_ctx(root,
        project_id: "phase9-project-cap",
        tool_max_concurrency: 1,
        network_egress_policy: :allow
      )

    first_call =
      Task.async(fn ->
        ExecutionRunner.run(project_ctx, %{
          name: "command.run.example_command",
          args: %{
            "path" => ".jido/commands/example_command.md",
            "simulate_delay_ms" => 400
          }
        })
      end)

    assert_eventually(fn ->
      diagnostics = %{telemetry: Telemetry.snapshot("phase9-project-cap")}
      event_count(diagnostics, "conversation.tool.started") >= 1
    end)

    assert {:error, %{status: :error, reason: :max_concurrency_reached}} =
             ExecutionRunner.run(project_ctx, %{
               name: "asset.list",
               args: %{"type" => "skill"}
             })

    assert {:ok, %{status: :ok, tool: "command.run.example_command"}} =
             Task.await(first_call, 2_000)
  end

  test "conversation-scoped concurrency quota blocks over-limit tool calls" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-conversation-cap",
               tool_max_concurrency_per_conversation: 0
             )

    assert {:error, %{status: :error, reason: :conversation_max_concurrency_reached}} =
             Runtime.run_tool(project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"},
               meta: %{"conversation_id" => "phase9-cap-c1"}
             })

    assert {:ok, %{status: :ok, tool: "asset.list"}} =
             Runtime.run_tool(project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"}
             })

    diagnostics = Runtime.diagnostics(project_id)
    assert diagnostics.runtime_opts[:tool_max_concurrency_per_conversation] == 0
  end

  test "asset reload captures loader parse failures without crashing project runtime" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = Runtime.start_project(root, project_id: "phase9-loader")

    invalid_skill = Path.join(root, ".jido/skills/broken.md")
    File.write!(invalid_skill, <<255, 0, 255>>)

    assert :ok = Runtime.reload_assets(project_id)

    diagnostics = Runtime.assets_diagnostics(project_id)
    assert diagnostics.loaded?
    assert diagnostics.errors != []
    assert Enum.any?(diagnostics.errors, &(&1.reason == :invalid_utf8))

    assert {:ok, %{status: :ok}} =
             Runtime.run_tool(project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"}
             })
  end

  test "strict asset loading runtime option fails startup on loader parse errors" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    invalid_skill = Path.join(root, ".jido/skills/broken.md")
    File.write!(invalid_skill, <<255, 0, 255>>)

    assert {:error, {:start_project_failed, reason}} =
             Runtime.start_project(root,
               project_id: "phase9-loader-strict",
               strict_asset_loading: true
             )

    reason_text = inspect(reason)
    assert reason_text =~ "asset_load_failed"
    assert reason_text =~ "invalid_utf8"

    assert {:ok, lenient_project_id} =
             Runtime.start_project(root,
               project_id: "phase9-loader-lenient",
               strict_asset_loading: false
             )

    diagnostics = Runtime.assets_diagnostics(lenient_project_id)
    assert diagnostics.loaded?
    assert Enum.any?(diagnostics.errors, &(&1.reason == :invalid_utf8))

    assert {:ok, %{status: :ok}} =
             Runtime.run_tool(lenient_project_id, %{
               name: "asset.list",
               args: %{"type" => "skill"}
             })
  end

  test "invalid llm adapter emits llm.failed while conversation remains available" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-llm-failure",
               conversation_orchestration: true,
               llm_adapter: :missing_adapter
             )

    assert {:ok, "phase9-llm-c1"} =
             Runtime.start_conversation(project_id, conversation_id: "phase9-llm-c1")

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-llm-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "hello"}
               }
             )

    assert :ok =
             RuntimeSignal.send_signal(
               project_id,
               "phase9-llm-c1",
               %{
                 "type" => "conversation.user.message",
                 "data" => %{"content" => "still there?"}
               }
             )

    assert_eventually(
      fn ->
        case Runtime.conversation_projection(project_id, "phase9-llm-c1", :timeline) do
          {:ok, timeline} ->
            Enum.count(timeline, &(map_lookup(&1, :type) == "conversation.llm.failed")) >= 2

          _ ->
            false
        end
      end,
      200
    )

    assert_eventually(
      fn ->
        Runtime.conversation_diagnostics(project_id, "phase9-llm-c1").status == :idle
      end,
      200
    )

    diagnostics = Runtime.conversation_diagnostics(project_id, "phase9-llm-c1")
    assert diagnostics.status == :idle
  end

  test "watcher storm is debounced under bursty file events" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} =
             Runtime.start_project(root,
               project_id: "phase9-watcher-storm",
               watcher: true,
               watcher_debounce_ms: 30
             )

    new_skill_path = Path.join(root, ".jido/skills/storm_skill.md")
    File.write!(new_skill_path, "# Storm Skill\n")

    [{watcher_pid, _}] = Registry.lookup(ProjectRegistry, {project_id, :watcher})

    Enum.each(1..40, fn _ ->
      send(watcher_pid, {:file_event, self(), {new_skill_path, [:modified]}})
    end)

    assert_eventually(fn ->
      Runtime.list_assets(project_id, :skill)
      |> Enum.any?(&(&1.name == "storm_skill"))
    end)

    diagnostics = Runtime.diagnostics(project_id)
    completed_count = event_count(diagnostics, "project.watcher_reload_completed")

    assert completed_count >= 1
    assert completed_count <= 5
  end

  test "concurrent multi-project conversations remain isolated under load" do
    roots = Enum.map(1..3, fn _ -> TempProject.create!(with_seed_files: true) end)
    Enum.each(roots, fn root -> on_exit(fn -> TempProject.cleanup(root) end) end)

    project_ids =
      roots
      |> Enum.with_index(1)
      |> Enum.map(fn {root, index} ->
        project_id = "phase9-load-#{index}"

        assert {:ok, ^project_id} =
                 Runtime.start_project(root,
                   project_id: project_id,
                   conversation_orchestration: true,
                   llm_adapter: :deterministic
                 )

        project_id
      end)

    conversation_pairs =
      for project_id <- project_ids, index <- 1..4 do
        conversation_id = "#{project_id}-c#{index}"

        assert {:ok, ^conversation_id} =
                 Runtime.start_conversation(project_id, conversation_id: conversation_id)

        {project_id, conversation_id}
      end

    results =
      conversation_pairs
      |> Task.async_stream(
        fn {project_id, conversation_id} ->
          message = "load-message #{project_id}/#{conversation_id}"

          :ok =
            RuntimeSignal.send_signal(project_id, conversation_id, %{
              "type" => "conversation.user.message",
              "data" => %{"content" => message}
            })

          {project_id, conversation_id, message}
        end,
        max_concurrency: 12,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, _}, &1))

    Enum.each(results, fn {:ok, {project_id, conversation_id, message}} ->
      assert {:ok, timeline} =
               Runtime.conversation_projection(project_id, conversation_id, :timeline)

      user_messages =
        timeline
        |> Enum.filter(&(map_lookup(&1, :type) == "conversation.user.message"))
        |> Enum.map(&map_lookup(map_lookup(&1, :data), :content))

      assert user_messages == [message]
      assert Enum.any?(timeline, &(map_lookup(&1, :type) == "conversation.assistant.message"))
    end)
  end

  defp valid_command_markdown do
    """
    ---
    name: example_command
    description: Example command fixture for runtime hardening tests
    allowed-tools:
      - asset.list
    ---
    Execute path={{path}} query={{query}}
    """
  end

  defp valid_workspace_sleep_command_markdown do
    """
    ---
    name: example_command
    description: Workspace shell sleep fixture for cancellation tests
    allowed-tools:
      - asset.list
    ---
    sleep 10
    """
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
               allow_tools: Keyword.get(opts, :allow_tools),
               network_egress_policy: Keyword.get(opts, :network_egress_policy),
               network_allowlist: Keyword.get(opts, :network_allowlist),
               network_allowed_schemes: Keyword.get(opts, :network_allowed_schemes)
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
      tool_max_concurrency: Keyword.get(opts, :tool_max_concurrency, 8),
      tool_max_concurrency_per_conversation:
        Keyword.get(opts, :tool_max_concurrency_per_conversation, 4),
      tool_env_allowlist: Keyword.get(opts, :tool_env_allowlist, []),
      command_executor: Keyword.get(opts, :command_executor),
      workflow_backend: Keyword.get(opts, :workflow_backend)
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

  defp wait_for_pending_task_pid(project_id, conversation_id, attempts \\ 40)

  defp wait_for_pending_task_pid(_project_id, _conversation_id, 0) do
    flunk("pending async task pid was not registered in time")
  end

  defp wait_for_pending_task_pid(project_id, conversation_id, attempts) do
    case lookup_pending_task_pid(project_id, conversation_id) do
      {:ok, task_pid} ->
        task_pid

      :error ->
        Process.sleep(25)
        wait_for_pending_task_pid(project_id, conversation_id, attempts - 1)
    end
  end

  defp lookup_pending_task_pid(project_id, conversation_id) do
    case :ets.whereis(@pending_task_table) do
      :undefined ->
        :error

      _ ->
        case :ets.match_object(@pending_task_table, {{project_id, conversation_id, :"$1"}, :"$2"}) do
          [{{^project_id, ^conversation_id, task_pid}, _call} | _rest] when is_pid(task_pid) ->
            {:ok, task_pid}

          _ ->
            :error
        end
    end
  end

  defp tracked_child_count(owner_pid) when is_pid(owner_pid) do
    case :ets.whereis(@child_process_table) do
      :undefined ->
        0

      _ ->
        @child_process_table
        |> :ets.tab2list()
        |> Enum.count(fn
          {{^owner_pid, _child_pid}, _timestamp} -> true
          _other -> false
        end)
    end
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

  defp map_lookup(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_lookup(_map, _key), do: nil

  defp emit_redaction_probe(attempts \\ 3)

  defp emit_redaction_probe(0), do: nil

  defp emit_redaction_probe(attempts) do
    Telemetry.emit("conversation.tool.failed", %{
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
