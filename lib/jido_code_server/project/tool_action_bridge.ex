defmodule Jido.Code.Server.Project.ToolActionBridge do
  @moduledoc """
  Bridges project-scoped ToolRunner tools into Jido action modules.

  This lets Jido.AI tool-calling actions execute project tools while preserving the
  existing `Jido.Code.Server.Project.ToolRunner` policy and sandbox controls.
  """

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Project.ToolRunner
  alias Jido.Code.Server.Telemetry

  @generated_root Jido.Code.Server.Project.ToolActions.Generated
  @bridge_tags ["tool", "jido_code_server", "tool_runner_bridge"]

  @type tool_name :: String.t()
  @type action_name :: String.t()
  @type action_registry :: %{action_name() => module()}

  @doc """
  Builds an action-name => action-module registry for a started project.
  """
  @spec action_registry(String.t()) :: {:ok, action_registry()}
  def action_registry(project_id) when is_binary(project_id) do
    with {:ok, registry, _tool_name_by_action} <-
           project_id
           |> Runtime.list_tools()
           |> build_registry_for_specs(project_id) do
      {:ok, registry}
    end
  end

  @doc """
  Builds a Jido.AI-friendly context that includes the generated tool registry.

  Accepted opts:
  - `:conversation_id`
  - `:correlation_id`
  - `:tool_meta` (map merged into each executed call metadata)
  """
  @spec tool_calling_context(String.t(), keyword()) :: {:ok, map()}
  def tool_calling_context(project_id, opts \\ []) when is_binary(project_id) and is_list(opts) do
    with {:ok, tools, tool_name_by_action} <-
           project_id
           |> Runtime.list_tools()
           |> build_registry_for_specs(project_id) do
      base = %{
        project_id: project_id,
        tools: tools,
        tool_calling: %{tools: tools},
        jido_code_server: %{
          project_id: project_id,
          tool_name_by_action: tool_name_by_action
        }
      }

      context =
        base
        |> maybe_put_context_value(:conversation_id, Keyword.get(opts, :conversation_id))
        |> maybe_put_context_value(:correlation_id, Keyword.get(opts, :correlation_id))
        |> maybe_put_context_value(:tool_meta, Keyword.get(opts, :tool_meta))

      {:ok, context}
    end
  end

  @doc """
  Executes a tool call from a generated action module.

  Supports either:
  - `%{project_ctx: %{...}}` in context for direct ToolRunner execution
  - `%{project_id: "..."}`
  """
  @spec execute_from_action(tool_name(), map(), map()) :: {:ok, map()} | {:error, term()}
  def execute_from_action(tool_name, params, context)
      when is_binary(tool_name) and is_map(params) and is_map(context) do
    call = %{
      name: tool_name,
      args: params,
      meta: call_meta_from_context(context)
    }

    case project_target_from_context(context) do
      {:project_ctx, project_ctx} ->
        ToolRunner.run(project_ctx, call)

      {:project_id, project_id} ->
        Runtime.run_tool(project_id, call)

      :error ->
        Telemetry.emit("tool.failed", %{
          status: :error,
          tool: tool_name,
          reason: :missing_project_context
        })

        {:error, :missing_project_context}
    end
  end

  def execute_from_action(_tool_name, _params, _context), do: {:error, :invalid_bridge_input}

  defp build_registry_for_specs(tool_specs, project_id) when is_list(tool_specs) do
    tool_specs
    |> Enum.reduce({:ok, %{}, %{}}, fn spec, {:ok, action_registry, tool_name_by_action} ->
      with {:ok, tool_name} <- fetch_tool_name(spec),
           {:ok, description} <- fetch_tool_description(spec),
           action_name <- action_name_for_tool(tool_name),
           {:ok, module_name} <-
             ensure_action_module(project_id, tool_name, action_name, description) do
        {:ok, Map.put(action_registry, action_name, module_name),
         Map.put(tool_name_by_action, action_name, tool_name)}
      else
        {:error, _reason} ->
          {:ok, action_registry, tool_name_by_action}
      end
    end)
  end

  defp ensure_action_module(project_id, tool_name, action_name, description)
       when is_binary(project_id) and is_binary(tool_name) and is_binary(action_name) and
              is_binary(description) do
    module_name = generated_module_name(project_id, tool_name)

    if Code.ensure_loaded?(module_name) do
      {:ok, module_name}
    else
      define_action_module(module_name, tool_name, action_name, description)
    end
  end

  defp define_action_module(module_name, tool_name, action_name, description)
       when is_atom(module_name) do
    quoted = generated_action_ast(tool_name, action_name, description)

    try do
      Module.create(module_name, quoted, Macro.Env.location(__ENV__))
      {:ok, module_name}
    rescue
      error in ArgumentError ->
        if Code.ensure_loaded?(module_name) do
          {:ok, module_name}
        else
          {:error, {:action_module_create_failed, module_name, error}}
        end
    end
  end

  defp generated_action_ast(tool_name, action_name, description)
       when is_binary(tool_name) and is_binary(action_name) and is_binary(description) do
    bridge_module = __MODULE__

    quote do
      use Jido.Action,
        name: unquote(action_name),
        description: unquote(description),
        category: "jido_code_server",
        tags: unquote(@bridge_tags),
        schema: []

      unquote(generated_action_runtime_ast(tool_name, bridge_module))
    end
  end

  defp generated_action_runtime_ast(tool_name, bridge_module) do
    quote do
      @moduledoc false
      @tool_name unquote(tool_name)
      @bridge_module unquote(bridge_module)

      @impl true
      def run(params, context) when is_map(params) and is_map(context) do
        @bridge_module.execute_from_action(@tool_name, params, context)
      end

      @impl true
      def run(_params, _context), do: {:error, :invalid_tool_call}
    end
  end

  defp generated_module_name(project_id, tool_name)
       when is_binary(project_id) and is_binary(tool_name) do
    hash =
      :sha256
      |> :crypto.hash("#{project_id}:#{tool_name}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    Module.concat([@generated_root, "M#{hash}"])
  end

  defp action_name_for_tool(tool_name) when is_binary(tool_name) do
    normalized_base =
      tool_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")
      |> ensure_starts_with_letter()
      |> String.slice(0, 48)

    suffix =
      :sha256
      |> :crypto.hash(tool_name)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "jcs_#{normalized_base}_#{suffix}"
  end

  defp ensure_starts_with_letter(""), do: "tool"

  defp ensure_starts_with_letter(value) when is_binary(value) do
    if Regex.match?(~r/^[a-z]/, value) do
      value
    else
      "t_#{value}"
    end
  end

  defp fetch_tool_name(%{} = spec) do
    case Map.get(spec, :name) || Map.get(spec, "name") do
      name when is_binary(name) and name != "" -> {:ok, name}
      _ -> {:error, :invalid_tool_name}
    end
  end

  defp fetch_tool_description(%{} = spec) do
    case Map.get(spec, :description) || Map.get(spec, "description") do
      desc when is_binary(desc) and desc != "" -> {:ok, desc}
      _ -> {:ok, "Project tool"}
    end
  end

  defp project_target_from_context(%{project_ctx: project_ctx}) when is_map(project_ctx) do
    {:project_ctx, project_ctx}
  end

  defp project_target_from_context(%{"project_ctx" => project_ctx}) when is_map(project_ctx) do
    {:project_ctx, project_ctx}
  end

  defp project_target_from_context(%{project_id: project_id}) when is_binary(project_id) do
    {:project_id, project_id}
  end

  defp project_target_from_context(%{"project_id" => project_id}) when is_binary(project_id) do
    {:project_id, project_id}
  end

  defp project_target_from_context(_context), do: :error

  defp call_meta_from_context(context) when is_map(context) do
    base_meta =
      context
      |> Map.get(:tool_meta, Map.get(context, "tool_meta", %{}))
      |> normalize_meta()

    base_meta
    |> maybe_put_meta("conversation_id", context_value(context, :conversation_id))
    |> maybe_put_meta("correlation_id", context_value(context, :correlation_id))
  end

  defp context_value(context, key) when is_map(context) and is_atom(key) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end

  defp normalize_meta(%{} = meta), do: meta
  defp normalize_meta(_meta), do: %{}

  defp maybe_put_meta(meta, _key, nil), do: meta
  defp maybe_put_meta(meta, _key, ""), do: meta
  defp maybe_put_meta(meta, key, value), do: Map.put(meta, key, value)

  defp maybe_put_context_value(context, _key, nil), do: context
  defp maybe_put_context_value(context, key, value), do: Map.put(context, key, value)
end
