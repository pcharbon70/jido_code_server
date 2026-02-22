defmodule JidoCodeServerTest do
  use ExUnit.Case, async: true

  alias JidoCodeServer.TestSupport.TempProject

  test "root module is available" do
    assert Code.ensure_loaded?(JidoCodeServer)
  end

  test "phase 0 config defaults are loaded" do
    assert JidoCodeServer.Config.default_data_dir() == ".jido"
    assert JidoCodeServer.Config.tool_timeout_ms() == 30_000
    assert JidoCodeServer.Config.llm_timeout_ms() == 120_000
    assert JidoCodeServer.Config.tool_max_concurrency() == 8
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
             JidoCodeServer.TestSupport.FakeAction.run(%{path: "foo"}, %{project: "p1"})

    assert {:ok, %{id: "fake-completion", model: "fake-model", text: "fake-response", tool_calls: []}} =
             JidoCodeServer.TestSupport.FakeLLM.complete(%{})
  end
end
