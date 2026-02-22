defmodule JidoCodeServer.Project.ToolCatalog do
  @moduledoc """
  Tool inventory composition for each project instance.
  """

  alias JidoCodeServer.Project.AssetStore

  @spec all_tools(map()) :: list(map())
  def all_tools(project_ctx) when is_map(project_ctx) do
    builtin_tools() ++ asset_tools(project_ctx)
  end

  @spec get_tool(map(), String.t()) :: {:ok, map()} | :error
  def get_tool(project_ctx, name) when is_binary(name) do
    project_ctx
    |> all_tools()
    |> Enum.find(:error, fn tool -> tool.name == name end)
    |> case do
      :error -> :error
      tool -> {:ok, tool}
    end
  end

  defp builtin_tools do
    [
      %{
        name: "asset.list",
        description: "List project assets by type.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"type" => %{"type" => "string"}},
          "required" => ["type"]
        },
        output_schema: %{"type" => "array"},
        safety: %{sandboxed: true},
        kind: :asset_list
      },
      %{
        name: "asset.search",
        description: "Search project assets by type and query text.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string"},
            "query" => %{"type" => "string"}
          },
          "required" => ["type", "query"]
        },
        output_schema: %{"type" => "array"},
        safety: %{sandboxed: true},
        kind: :asset_search
      },
      %{
        name: "asset.get",
        description: "Get a single project asset by type and key.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string"},
            "key" => %{"type" => "string"}
          },
          "required" => ["type", "key"]
        },
        output_schema: %{"type" => "object"},
        safety: %{sandboxed: true},
        kind: :asset_get
      }
    ]
  end

  defp asset_tools(project_ctx) do
    asset_store = Map.fetch!(project_ctx, :asset_store)

    command_tools =
      asset_store
      |> AssetStore.list(:command)
      |> Enum.map(fn command ->
        %{
          name: "command.run.#{command.name}",
          description: "Execute project command #{command.name}.",
          input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
          output_schema: %{"type" => "object"},
          safety: %{sandboxed: true},
          kind: :command_run,
          asset_name: command.name
        }
      end)

    workflow_tools =
      asset_store
      |> AssetStore.list(:workflow)
      |> Enum.map(fn workflow ->
        %{
          name: "workflow.run.#{workflow.name}",
          description: "Execute workflow #{workflow.name}.",
          input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => true},
          output_schema: %{"type" => "object"},
          safety: %{sandboxed: true},
          kind: :workflow_run,
          asset_name: workflow.name
        }
      end)

    (command_tools ++ workflow_tools)
    |> Enum.sort_by(& &1.name)
  end
end
