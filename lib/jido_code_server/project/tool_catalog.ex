defmodule Jido.Code.Server.Project.ToolCatalog do
  @moduledoc """
  Tool inventory composition for each project instance.
  """

  alias Jido.Code.Server.Conversation.ModeRegistry
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.Policy

  @permissive_asset_input_schema %{
    "type" => "object",
    "properties" => %{},
    "additionalProperties" => true
  }

  @spec all_tools(map()) :: list(map())
  def all_tools(project_ctx) when is_map(project_ctx) do
    (builtin_tools() ++
       asset_tools(project_ctx) ++ provider_tools(project_ctx) ++ spawn_tools(project_ctx))
    |> dedupe_tools()
    |> Enum.sort_by(& &1.name)
  end

  @spec llm_tools(map(), keyword()) :: list(map())
  def llm_tools(project_ctx, opts \\ []) when is_map(project_ctx) and is_list(opts) do
    mode = Keyword.get(opts, :mode) || Map.get(project_ctx, :mode) || :coding
    allowed_execution_kinds = ModeRegistry.allowed_execution_kinds(mode, project_ctx)

    project_ctx
    |> all_tools()
    |> Enum.filter(&(llm_exposed?(&1) and allowed_in_mode?(&1, allowed_execution_kinds)))
    |> maybe_filter_with_policy(project_ctx)
    |> Enum.sort_by(& &1.name)
  end

  @spec llm_tool_allowed?(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, :tool_not_exposed}
  def llm_tool_allowed?(project_ctx, name, opts \\ [])
      when is_map(project_ctx) and is_binary(name) and is_list(opts) do
    case Enum.find(llm_tools(project_ctx, opts), fn tool -> tool.name == name end) do
      nil -> {:error, :tool_not_exposed}
      tool -> {:ok, tool}
    end
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
        kind: :asset_list,
        execution_kind: :tool_run,
        llm_exposed: true,
        provider: :builtin
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
        kind: :asset_search,
        execution_kind: :tool_run,
        llm_exposed: true,
        provider: :builtin
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
        kind: :asset_get,
        execution_kind: :tool_run,
        llm_exposed: true,
        provider: :builtin
      }
    ]
  end

  defp asset_tools(project_ctx) do
    asset_store = Map.fetch!(project_ctx, :asset_store)

    command_tools =
      asset_store
      |> AssetStore.list(:command)
      |> Enum.map(&command_tool_spec/1)

    workflow_tools =
      asset_store
      |> AssetStore.list(:workflow)
      |> Enum.map(&workflow_tool_spec/1)

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
            execution_kind: :subagent_spawn,
            llm_exposed: true,
            provider: :subagent_template,
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

  defp provider_tools(project_ctx) do
    project_ctx
    |> tool_provider_modules()
    |> Enum.flat_map(fn provider ->
      provider
      |> load_provider_tools(project_ctx)
      |> Enum.map(&normalize_provider_tool(&1, provider))
      |> Enum.reject(&is_nil/1)
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp tool_provider_modules(project_ctx) do
    project_ctx
    |> Map.get(:tool_providers, [])
    |> List.wrap()
    |> Enum.filter(&is_atom/1)
  end

  defp load_provider_tools(provider, project_ctx) when is_atom(provider) do
    cond do
      function_exported?(provider, :tools, 1) ->
        provider.tools(project_ctx)

      function_exported?(provider, :list_tools, 1) ->
        provider.list_tools(project_ctx)

      true ->
        []
    end
    |> List.wrap()
  rescue
    _error ->
      []
  end

  defp normalize_provider_tool(raw_tool, provider) when is_map(raw_tool) do
    tool = normalize_string_key_map(raw_tool)
    name = Map.get(tool, "name")
    kind = normalize_provider_kind(Map.get(tool, "kind"))

    if is_binary(name) and String.trim(name) != "" and is_map(Map.get(tool, "input_schema")) do
      %{
        name: name,
        description:
          normalize_description(Map.get(tool, "description"), "Provider tool #{name}."),
        input_schema: Map.get(tool, "input_schema"),
        output_schema: Map.get(tool, "output_schema", %{"type" => "object"}),
        safety: normalize_safety(Map.get(tool, "safety")),
        kind: kind,
        execution_kind: execution_kind_for_kind(kind),
        llm_exposed: Map.get(tool, "llm_exposed", true) == true,
        provider: provider
      }
    else
      nil
    end
  end

  defp normalize_provider_tool(_raw_tool, _provider), do: nil

  defp command_tool_spec(command) when is_map(command) do
    {description, input_schema, llm_exposed, registration} =
      case parse_command_definition(command) do
        {:ok, definition} ->
          {
            command_description(definition, command),
            command_schema_from_definition(definition),
            true,
            %{status: :registered}
          }

        {:error, reason} ->
          {
            "Execute project command #{command.name}.",
            @permissive_asset_input_schema,
            false,
            %{status: :invalid, reason: reason}
          }
      end

    %{
      name: "command.run.#{command.name}",
      description: description,
      input_schema: input_schema,
      output_schema: %{"type" => "object"},
      safety: %{sandboxed: true, network_capable: true},
      kind: :command_run,
      execution_kind: :command_run,
      llm_exposed: llm_exposed,
      provider: :jido_command,
      registration: registration,
      asset_name: command.name
    }
  end

  defp workflow_tool_spec(workflow) when is_map(workflow) do
    {description, input_schema, llm_exposed, registration} =
      case parse_workflow_definition(workflow) do
        {:ok, definition} ->
          {
            workflow_description(definition, workflow),
            workflow_schema_from_definition(definition),
            true,
            %{status: :registered}
          }

        {:error, reason} ->
          {
            "Execute workflow #{workflow.name}.",
            @permissive_asset_input_schema,
            false,
            %{status: :invalid, reason: reason}
          }
      end

    %{
      name: "workflow.run.#{workflow.name}",
      description: description,
      input_schema: input_schema,
      output_schema: %{"type" => "object"},
      safety: %{sandboxed: true, network_capable: true},
      kind: :workflow_run,
      execution_kind: :workflow_run,
      llm_exposed: llm_exposed,
      provider: :jido_workflow,
      registration: registration,
      asset_name: workflow.name
    }
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

  defp llm_exposed?(tool) when is_map(tool) do
    Map.get(tool, :llm_exposed, true) == true
  end

  defp allowed_in_mode?(_tool, :all), do: true

  defp allowed_in_mode?(tool, allowed_execution_kinds)
       when is_map(tool) and is_list(allowed_execution_kinds) do
    execution_kind = Map.get(tool, :execution_kind, :tool_run)
    execution_kind in allowed_execution_kinds
  end

  defp allowed_in_mode?(_tool, _allowed_execution_kinds), do: true

  defp maybe_filter_with_policy(tools, project_ctx) when is_list(tools) and is_map(project_ctx) do
    case Map.get(project_ctx, :policy) do
      nil -> tools
      policy -> Policy.filter_tools(policy, tools)
    end
  end

  defp dedupe_tools(tools) when is_list(tools) do
    tools
    |> Enum.reduce({MapSet.new(), []}, fn tool, {seen_names, acc} ->
      name = Map.get(tool, :name)

      if is_binary(name) and not MapSet.member?(seen_names, name) do
        {MapSet.put(seen_names, name), [tool | acc]}
      else
        {seen_names, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp normalize_provider_kind(kind) when is_atom(kind), do: kind

  defp normalize_provider_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> :tool_run
      "asset_list" -> :asset_list
      "asset_search" -> :asset_search
      "asset_get" -> :asset_get
      "command_run" -> :command_run
      "workflow_run" -> :workflow_run
      "subagent_spawn" -> :subagent_spawn
      _other -> :tool_run
    end
  end

  defp normalize_provider_kind(_kind), do: :tool_run

  defp execution_kind_for_kind(kind)
       when kind in [:asset_list, :asset_search, :asset_get, :tool_run],
       do: :tool_run

  defp execution_kind_for_kind(:command_run), do: :command_run
  defp execution_kind_for_kind(:workflow_run), do: :workflow_run
  defp execution_kind_for_kind(:subagent_spawn), do: :subagent_spawn
  defp execution_kind_for_kind(_kind), do: :tool_run

  defp normalize_safety(safety) when is_map(safety) do
    %{
      sandboxed: Map.get(safety, :sandboxed, true),
      network_capable: Map.get(safety, :network_capable, false)
    }
  end

  defp normalize_safety(_safety), do: %{sandboxed: true, network_capable: false}

  defp command_description(definition, command) do
    normalize_description(
      fetch_field(definition, :description),
      "Execute project command #{command.name}."
    )
  end

  defp workflow_description(definition, workflow) do
    normalize_description(
      fetch_field(definition, :description),
      "Execute workflow #{workflow.name}."
    )
  end

  defp normalize_description(description, fallback) when is_binary(description) do
    normalized = String.trim(description)
    if normalized == "", do: fallback, else: normalized
  end

  defp normalize_description(_description, fallback), do: fallback

  defp normalize_string_key_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)

      normalized_value =
        cond do
          is_map(nested) -> normalize_string_key_map(nested)
          is_list(nested) -> Enum.map(nested, &normalize_string_key_map/1)
          true -> nested
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_string_key_map(value) when is_list(value),
    do: Enum.map(value, &normalize_string_key_map/1)

  defp normalize_string_key_map(value), do: value

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
