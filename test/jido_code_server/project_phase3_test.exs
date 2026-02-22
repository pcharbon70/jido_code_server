defmodule JidoCodeServer.ProjectPhase3Test do
  use ExUnit.Case, async: false

  alias JidoCodeServer.Project.AssetStore
  alias JidoCodeServer.Project.Layout
  alias JidoCodeServer.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(JidoCodeServer.list_projects(), fn %{project_id: project_id} ->
        _ = JidoCodeServer.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "project boot loads shared assets and exposes list/get/search APIs" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = JidoCodeServer.start_project(root, project_id: "phase3-assets")

    skills = JidoCodeServer.list_assets(project_id, :skill)
    commands = JidoCodeServer.list_assets(project_id, :command)
    workflows = JidoCodeServer.list_assets(project_id, :workflow)

    assert Enum.map(skills, & &1.name) == ["example_skill"]
    assert Enum.map(commands, & &1.name) == ["example_command"]
    assert Enum.map(workflows, & &1.name) == ["example_workflow"]

    assert {:ok, skill} = JidoCodeServer.get_asset(project_id, :skill, "example_skill")
    assert skill.relative_path == "example_skill.md"

    assert {:ok, skill_graph} = JidoCodeServer.get_asset(project_id, :skill_graph, :snapshot)
    assert Enum.any?(skill_graph.nodes, &(&1.id == "index"))

    assert [%{name: "example_skill"}] =
             JidoCodeServer.search_assets(project_id, :skill, "example")

    assert [] == JidoCodeServer.search_assets(project_id, :skill, "missing")

    diagnostics = JidoCodeServer.assets_diagnostics(project_id)
    assert diagnostics.loaded?
    assert diagnostics.generation == 1
    assert diagnostics.versions.skill == 1
    assert diagnostics.versions.skill_graph == 1
    assert diagnostics.counts.skill == 1
    assert diagnostics.counts.command == 1
    assert diagnostics.counts.workflow == 1
    assert diagnostics.errors == []
  end

  test "reload_assets refreshes snapshot and bumps generation deterministically" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = JidoCodeServer.start_project(root, project_id: "phase3-reload")
    before = JidoCodeServer.assets_diagnostics(project_id)

    File.write!(Path.join(root, ".jido/skills/new_skill.md"), "# New Skill\ncontent\n")

    assert :ok = JidoCodeServer.reload_assets(project_id)

    after_reload = JidoCodeServer.assets_diagnostics(project_id)
    assert after_reload.generation == before.generation + 1
    assert after_reload.versions.skill == before.versions.skill + 1
    assert after_reload.counts.skill == 2

    assert ["example_skill", "new_skill"] ==
             project_id
             |> JidoCodeServer.list_assets(:skill)
             |> Enum.map(& &1.name)
  end

  test "strict mode preserves existing snapshot when reload contains parse errors" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    layout = Layout.paths(root, ".jido")

    assert {:ok, store} = AssetStore.start_link(project_id: "phase3-strict", strict: true)
    assert :ok = AssetStore.load(store, layout)

    File.write!(Path.join(layout.skills, "fresh_skill.md"), "# Fresh Skill\n")
    File.write!(Path.join(layout.skills, "broken.md"), <<255, 254, 253>>)

    assert {:error, {:asset_load_failed, errors}} = AssetStore.reload(store)
    assert Enum.any?(errors, &(&1.reason == :invalid_utf8))

    names =
      store
      |> AssetStore.list(:skill)
      |> Enum.map(& &1.name)

    assert names == ["example_skill"]

    diagnostics = AssetStore.diagnostics(store)
    assert diagnostics.generation == 1
    assert diagnostics.versions.skill == 1
  end
end
