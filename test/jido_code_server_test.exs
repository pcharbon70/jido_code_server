defmodule Jido.Code.ServerTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.TestSupport.FakeAction
  alias Jido.Code.Server.TestSupport.FakeLLM
  alias Jido.Code.Server.TestSupport.TempProject
  alias Runtime.Config

  test "root module is available" do
    assert Code.ensure_loaded?(Runtime)
  end

  test "phase 0 config defaults are loaded" do
    assert Config.default_data_dir() == ".jido"
    assert Config.tool_timeout_ms() == 30_000
    assert Config.tool_timeout_alert_threshold() == 3

    assert Config.alert_signal_events() == [
             "security.sandbox_violation",
             "security.repeated_timeout_failures"
           ]

    assert Config.alert_router() == nil
    assert Config.tool_max_output_bytes() == 262_144
    assert Config.tool_max_artifact_bytes() == 131_072
    assert Config.network_egress_policy() == :deny
    assert Config.network_allowlist() == []
    assert Config.outside_root_allowlist() == []
    assert Config.tool_env_allowlist() == []
    assert Config.llm_timeout_ms() == 120_000
    assert Config.tool_max_concurrency() == 8
    assert Config.tool_max_concurrency_per_conversation() == 4
    assert Config.watcher_debounce_ms() == 250
  end

  test "temp project helper creates expected layout" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert File.dir?(Path.join(root, ".jido"))
    assert File.exists?(Path.join(root, ".jido/skills/example_skill.md"))
    assert File.exists?(Path.join(root, ".jido/commands/example_command.md"))
    assert File.exists?(Path.join(root, ".jido/workflows/example_workflow.md"))
    assert File.exists?(Path.join(root, ".jido/skill_graph/index.md"))
  end

  test "fake adapters return deterministic payloads" do
    assert {:ok, %{ok: true, args: %{path: "foo"}, ctx: %{project: "p1"}}} =
             FakeAction.run(%{path: "foo"}, %{project: "p1"})

    assert {:ok,
            %{id: "fake-completion", model: "fake-model", text: "fake-response", tool_calls: []}} =
             FakeLLM.complete(%{})
  end
end
