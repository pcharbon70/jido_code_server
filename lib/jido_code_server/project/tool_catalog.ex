defmodule Jido.Code.Server.Project.ToolCatalog do
  @moduledoc """
  Tool inventory composition for each project instance.
  """

  alias Jido.Code.Server.Project.AssetStore

  @permissive_asset_input_schema %{
    "type" => "object",
    "properties" => %{},
    "additionalProperties" => true
  }

  @spec all_tools(map()) :: list(map())
  def all_tools(project_ctx) when is_map(project_ctx) do
    builtin_tools() ++ asset_tools(project_ctx) ++ spawn_tools(project_ctx)
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
        safety: %{sandboxed: true, network_capable: false},
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
        safety: %{sandboxed: true, network_capable: false},
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
        safety: %{sandboxed: true, network_capable: false},
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
          input_schema: command_input_schema(command),
          output_schema: %{"type" => "object"},
          safety: %{sandboxed: true, network_capable: true},
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
          input_schema: workflow_input_schema(workflow),
          output_schema: %{"type" => "object"},
          safety: %{sandboxed: true, network_capable: true},
          kind: :workflow_run,
          asset_name: workflow.name
        }
      end)

    (command_tools ++ workflow_tools)
    |> Enum.sort_by(& &1.name)
  end

  defp spawn_tools(project_ctx) do
    project_ctx
    |> Map.get(:subagent_templates, [])
    |> List.wrap()
    |> Enum.flat_map(fn template ->
      template_id = Map.get(template, :template_id) || Map.get(template, "template_id")

      if is_binary(template_id) and template_id != "" do
        [
          %{
            name: "agent.spawn.#{template_id}",
            description: "Spawn a policy-approved sub-agent from template #{template_id}.",
            input_schema: %{
              "type" => "object",
              "properties" => %{
                "goal" => %{"type" => "string"},
                "inputs" => %{"type" => "object", "additionalProperties" => true},
                "ttl_ms" => %{"type" => "integer", "minimum" => 1}
              },
              "required" => ["goal"],
              "additionalProperties" => false
            },
            output_schema: %{"type" => "object"},
            safety: %{sandboxed: true, network_capable: false},
            kind: :subagent_spawn,
            template_id: template_id,
            template: template
          }
        ]
      else
        []
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp command_input_schema(asset) when is_map(asset) do
    case parse_command_definition(asset) do
      {:ok, definition} -> command_schema_from_definition(definition)
      {:error, _reason} -> @permissive_asset_input_schema
    end
  end

  defp command_schema_from_definition(definition) when is_map(definition) do
    {param_properties, param_required} = command_parameter_schema(definition)

    if param_properties == %{} do
      @permissive_asset_input_schema
    else
      %{
        "type" => "object",
        "properties" =>
          %{
            "params" => %{
              "type" => "object",
              "properties" => param_properties,
              "required" => param_required,
              "additionalProperties" => true
            }
          }
          |> Map.merge(param_properties),
        "additionalProperties" => true
      }
    end
  end

  defp command_schema_from_definition(_definition), do: @permissive_asset_input_schema

  defp command_parameter_schema(definition) do
    definition
    |> Map.get(:schema, [])
    |> do_command_parameter_schema()
  end

  defp do_command_parameter_schema(schema) when is_list(schema) do
    {properties, required} =
      Enum.reduce(schema, {%{}, []}, &reduce_command_schema_entry/2)

    {properties, required |> Enum.reverse() |> Enum.uniq()}
  end

  defp do_command_parameter_schema(_schema), do: {%{}, []}

  defp reduce_command_schema_entry({field, opts}, {acc_properties, acc_required})
       when is_list(opts) do
    case normalize_schema_field_name(field) do
      {:ok, field_name} ->
        property = command_property_schema(opts)

        {
          Map.put(acc_properties, field_name, property),
          append_required(acc_required, field_name, Keyword.get(opts, :required, false))
        }

      :error ->
        {acc_properties, acc_required}
    end
  end

  defp reduce_command_schema_entry(_entry, acc), do: acc

  defp command_property_schema(opts) when is_list(opts) do
    base =
      case command_type_to_json_schema(Keyword.get(opts, :type)) do
        nil -> %{}
        type -> %{"type" => type}
      end

    base
    |> maybe_put_description(Keyword.get(opts, :doc))
    |> maybe_put_default(opts)
  end

  defp command_property_schema(_opts), do: %{}

  defp maybe_put_description(schema, description) when is_binary(description) do
    normalized = String.trim(description)
    if normalized == "", do: schema, else: Map.put(schema, "description", normalized)
  end

  defp maybe_put_description(schema, _description), do: schema

  defp maybe_put_default(schema, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :default) do
      Map.put(schema, "default", Keyword.get(opts, :default))
    else
      schema
    end
  end

  defp command_type_to_json_schema(:string), do: "string"
  defp command_type_to_json_schema(:integer), do: "integer"
  defp command_type_to_json_schema(:float), do: "number"
  defp command_type_to_json_schema(:boolean), do: "boolean"
  defp command_type_to_json_schema(:map), do: "object"
  defp command_type_to_json_schema(:list), do: "array"
  defp command_type_to_json_schema(:atom), do: "string"
  defp command_type_to_json_schema(_type), do: nil

  defp workflow_input_schema(asset) when is_map(asset) do
    case parse_workflow_definition(asset) do
      {:ok, definition} -> workflow_schema_from_definition(definition)
      {:error, _reason} -> @permissive_asset_input_schema
    end
  end

  defp workflow_schema_from_definition(definition) when is_map(definition) do
    {input_properties, input_required} = workflow_inputs_schema(definition)

    if input_properties == %{} do
      @permissive_asset_input_schema
    else
      %{
        "type" => "object",
        "properties" =>
          %{
            "inputs" => %{
              "type" => "object",
              "properties" => input_properties,
              "required" => input_required,
              "additionalProperties" => true
            }
          }
          |> Map.merge(input_properties),
        "additionalProperties" => true
      }
    end
  end

  defp workflow_inputs_schema(definition) do
    definition
    |> Map.get(:inputs, [])
    |> do_workflow_inputs_schema()
  end

  defp do_workflow_inputs_schema(inputs) when is_list(inputs) do
    {properties, required} =
      Enum.reduce(inputs, {%{}, []}, &reduce_workflow_input_schema_entry/2)

    {properties, required |> Enum.reverse() |> Enum.uniq()}
  end

  defp do_workflow_inputs_schema(_inputs), do: {%{}, []}

  defp reduce_workflow_input_schema_entry(input, {acc_properties, acc_required}) do
    case workflow_input_name(input) do
      {:ok, field_name} ->
        property = workflow_property_schema(input)

        {
          Map.put(acc_properties, field_name, property),
          append_required(acc_required, field_name, workflow_input_required?(input))
        }

      :error ->
        {acc_properties, acc_required}
    end
  end

  defp workflow_input_name(input) when is_map(input) do
    case fetch_field(input, :name) do
      value when is_binary(value) ->
        normalized = String.trim(value)
        if normalized == "", do: :error, else: {:ok, normalized}

      _other ->
        :error
    end
  end

  defp workflow_input_name(_input), do: :error

  defp workflow_property_schema(input) when is_map(input) do
    base =
      case workflow_type_to_json_schema(fetch_field(input, :type)) do
        nil -> %{}
        type -> %{"type" => type}
      end

    base
    |> maybe_put_description(fetch_field(input, :description))
    |> maybe_put_workflow_default(fetch_field(input, :default))
  end

  defp workflow_property_schema(_input), do: %{}

  defp maybe_put_workflow_default(schema, nil), do: schema
  defp maybe_put_workflow_default(schema, default), do: Map.put(schema, "default", default)

  defp workflow_input_required?(input) when is_map(input) do
    fetch_field(input, :required) == true
  end

  defp workflow_input_required?(_input), do: false

  defp workflow_type_to_json_schema(type) when is_atom(type) do
    type |> Atom.to_string() |> workflow_type_to_json_schema()
  end

  defp workflow_type_to_json_schema(type) when is_binary(type) do
    case String.downcase(String.trim(type)) do
      "string" -> "string"
      "integer" -> "integer"
      "float" -> "number"
      "boolean" -> "boolean"
      "map" -> "object"
      "list" -> "array"
      "atom" -> "string"
      _other -> nil
    end
  end

  defp workflow_type_to_json_schema(_type), do: nil

  defp fetch_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_schema_field_name(field) when is_atom(field) do
    normalize_schema_field_name(Atom.to_string(field))
  end

  defp normalize_schema_field_name(field) when is_binary(field) do
    normalized = String.trim(field)
    if normalized == "", do: :error, else: {:ok, normalized}
  end

  defp normalize_schema_field_name(_field), do: :error

  defp append_required(required, field_name, true), do: [field_name | required]
  defp append_required(required, _field_name, _required_flag), do: required

  defp parse_command_definition(%{body: body, path: path})
       when is_binary(body) and is_binary(path) do
    parser_module = JidoCommand.Extensibility.CommandFrontmatter

    case Code.ensure_loaded(parser_module) do
      {:module, _loaded} ->
        if function_exported?(parser_module, :parse_string, 2) do
          parser_module.parse_string(body, path)
        else
          {:error, :command_frontmatter_unavailable}
        end

      _other ->
        {:error, :command_frontmatter_unavailable}
    end
  end

  defp parse_command_definition(_asset), do: {:error, :invalid_command_asset}

  defp parse_workflow_definition(%{body: body}) when is_binary(body) do
    loader_module = JidoWorkflow.Workflow.Loader

    case Code.ensure_loaded(loader_module) do
      {:module, _loaded} ->
        if function_exported?(loader_module, :load_markdown, 1) do
          loader_module.load_markdown(body)
        else
          {:error, :workflow_loader_unavailable}
        end

      _other ->
        {:error, :workflow_loader_unavailable}
    end
  end

  defp parse_workflow_definition(_asset), do: {:error, :invalid_workflow_asset}
end
