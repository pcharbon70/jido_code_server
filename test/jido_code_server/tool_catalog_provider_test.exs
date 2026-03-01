defmodule Jido.Code.Server.ToolCatalogProviderTest.StaticProvider do
  @behaviour Jido.Code.Server.Project.ToolCatalog.Provider

  @impl true
  def tools(_project_ctx) do
    [
      %{
        name: "custom.tool",
        description: "Custom provider tool.",
        input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
        output_schema: %{"type" => "object"},
        safety: %{},
        kind: :asset_get
      }
    ]
  end
end

defmodule Jido.Code.Server.ToolCatalogProviderTest.BadProvider do
  @behaviour Jido.Code.Server.Project.ToolCatalog.Provider

  @impl true
  def tools(_project_ctx), do: {:error, :invalid}
end

defmodule Jido.Code.Server.ToolCatalogProviderTest.FirstDuplicateProvider do
  @behaviour Jido.Code.Server.Project.ToolCatalog.Provider

  @impl true
  def tools(_project_ctx) do
    [
      %{
        name: "duplicate.tool",
        description: "First provider wins.",
        input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
        output_schema: %{"type" => "object"},
        safety: %{},
        kind: :asset_list
      }
    ]
  end
end

defmodule Jido.Code.Server.ToolCatalogProviderTest.SecondDuplicateProvider do
  @behaviour Jido.Code.Server.Project.ToolCatalog.Provider

  @impl true
  def tools(_project_ctx) do
    [
      %{
        name: "duplicate.tool",
        description: "Second provider should be ignored.",
        input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
        output_schema: %{"type" => "object"},
        safety: %{},
        kind: :asset_search
      }
    ]
  end
end

defmodule Jido.Code.Server.ToolCatalogProviderTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.Layout
  alias Jido.Code.Server.Project.ToolCatalog
  alias Jido.Code.Server.TestSupport.TempProject

  test "explicit tool providers are merged with builtins" do
    tools =
      ToolCatalog.all_tools(%{
        tool_providers: [__MODULE__.StaticProvider],
        subagent_templates: []
      })

    names = Enum.map(tools, & &1.name)

    assert "asset.list" in names
    assert "asset.search" in names
    assert "asset.get" in names
    assert "custom.tool" in names
    refute Enum.any?(names, &String.starts_with?(&1, "command.run."))
    refute Enum.any?(names, &String.starts_with?(&1, "workflow.run."))
  end

  test "invalid providers are ignored without raising" do
    tools =
      ToolCatalog.all_tools(%{
        tool_providers: [__MODULE__.BadProvider],
        subagent_templates: []
      })

    names = Enum.map(tools, & &1.name)

    assert names == ["asset.list", "asset.search", "asset.get"]
  end

  test "duplicate provider tool names keep the first provider entry" do
    tools =
      ToolCatalog.all_tools(%{
        tool_providers: [__MODULE__.FirstDuplicateProvider, __MODULE__.SecondDuplicateProvider],
        subagent_templates: []
      })

    duplicate = Enum.find(tools, &(&1.name == "duplicate.tool"))

    assert duplicate.description == "First provider wins."
  end

  test "default provider list exposes command and workflow asset tools" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    layout = Layout.ensure_layout!(root, ".jido")
    {:ok, asset_store} = AssetStore.start_link([])

    assert :ok = AssetStore.load(asset_store, layout)

    tools =
      ToolCatalog.all_tools(%{
        asset_store: asset_store,
        subagent_templates: []
      })

    names = Enum.map(tools, & &1.name)

    assert "command.run.example_command" in names
    assert "workflow.run.example_workflow" in names
  end
end
