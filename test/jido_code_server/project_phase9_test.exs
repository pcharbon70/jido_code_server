defmodule Jido.Code.Server.ProjectPhase9Test do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

  alias Jido.Code.Server.Engine.ProjectRegistry
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.Layout
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.ToolRunner
  alias Jido.Code.Server.Telemetry
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

  test "tool runner rejects payloads that fail input schema validation" do
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
             Runtime.send_event(project_id, "phase9-corr-c1", %{
               "type" => "user.message",
               "content" => "please list skills",
               "meta" => %{"correlation_id" => correlation_id}
             })

    assert {:ok, timeline} = Runtime.get_projection(project_id, "phase9-corr-c1", :timeline)

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

    assert Enum.any?(timeline, fn event -> map_lookup(event, :type) == "tool.requested" end)
    assert Enum.any?(timeline, fn event -> map_lookup(event, :type) == "tool.completed" end)

    tool_completed =
      Enum.find(timeline, fn event ->
        map_lookup(event, :type) == "tool.completed"
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
             Runtime.send_event(project_id, "phase9-corr-c2", %{
               "type" => "user.message",
               "content" => "hello"
             })

    assert {:ok, timeline} = Runtime.get_projection(project_id, "phase9-corr-c2", :timeline)

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
             Runtime.send_event(project_id, "phase9-incident-c1", %{
               "type" => "user.message",
               "content" => "please list skills",
               "meta" => %{"correlation_id" => correlation_id}
             })

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
             entry.source == :telemetry and entry.event == "tool.completed"
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
             ToolRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})

    assert {:error, %{status: :error, reason: :timeout}} =
             ToolRunner.run(project_ctx, %{name: "asset.list", args: %{"type" => "skill"}})

    diagnostics = %{telemetry: Telemetry.snapshot("phase9-timeout")}
    assert event_count(diagnostics, "tool.timeout") >= 2
    assert event_count(diagnostics, "security.repeated_timeout_failures") >= 1
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
             Runtime.send_event(project_id, "phase9-llm-c1", %{
               "type" => "user.message",
               "content" => "hello"
             })

    assert :ok =
             Runtime.send_event(project_id, "phase9-llm-c1", %{
               "type" => "user.message",
               "content" => "still there?"
             })

    assert {:ok, timeline} =
             Runtime.get_projection(project_id, "phase9-llm-c1", :timeline)

    failed_count =
      timeline
      |> Enum.count(&(map_lookup(&1, :type) == "llm.failed"))

    assert failed_count >= 2

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
            Runtime.send_event(project_id, conversation_id, %{
              "type" => "user.message",
              "content" => message
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
               Runtime.get_projection(project_id, conversation_id, :timeline)

      user_messages =
        timeline
        |> Enum.filter(&(map_lookup(&1, :type) == "user.message"))
        |> Enum.map(&map_lookup(&1, :content))

      assert user_messages == [message]
      assert Enum.any?(timeline, &(map_lookup(&1, :type) == "assistant.message"))
    end)
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
