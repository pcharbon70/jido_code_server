defmodule Jido.Code.Server.AssetStoreLoadingTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime

  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.Layout
  alias Jido.Code.Server.TestSupport.TempProject

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "project boot loads shared assets and exposes list/get/search APIs" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    assert {:ok, project_id} = Runtime.start_project(root, project_id: "phase3-assets")

    skills = Runtime.list_assets(project_id, :skill)
    commands = Runtime.list_assets(project_id, :command)
    workflows = Runtime.list_assets(project_id, :workflow)

    assert Enum.map(skills, & &1.name) == ["example_skill"]
    assert Enum.map(commands, & &1.name) == ["example_command"]
    assert Enum.map(workflows, & &1.name) == ["example_workflow"]

    assert {:ok, skill} = Runtime.get_asset(project_id, :skill, "example_skill")
    assert skill.relative_path == "example_skill.md"

    assert {:ok, skill_graph} = Runtime.get_asset(project_id, :skill_graph, :snapshot)
    assert Enum.any?(skill_graph.nodes, &(&1.id == "index"))

    assert [%{name: "example_skill"}] =
             Runtime.search_assets(project_id, :skill, "example")

    assert [] == Runtime.search_assets(project_id, :skill, "missing")

    diagnostics = Runtime.assets_diagnostics(project_id)
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

    assert {:ok, project_id} = Runtime.start_project(root, project_id: "phase3-reload")
    before = Runtime.assets_diagnostics(project_id)

    File.write!(Path.join(root, ".jido/skills/new_skill.md"), "# New Skill\ncontent\n")

    assert :ok = Runtime.reload_assets(project_id)

    after_reload = Runtime.assets_diagnostics(project_id)
    assert after_reload.generation == before.generation + 1
    assert after_reload.versions.skill == before.versions.skill + 1
    assert after_reload.counts.skill == 2

    assert ["example_skill", "new_skill"] ==
             project_id
             |> Runtime.list_assets(:skill)
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
