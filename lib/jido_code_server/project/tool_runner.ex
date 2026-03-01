defmodule Jido.Code.Server.Project.ToolRunner do
  @moduledoc """
  Executes base tool operations (assets and subagent spawn) once ExecutionRunner
  has validated and authorized a call.
  """

  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.SubAgentManager
  alias Jido.Code.Server.Types.ToolCall

  @spec execute(map(), map(), map() | ToolCall.t()) :: {:ok, map()} | {:error, term()}
  def execute(project_ctx, %{kind: :asset_list}, call) do
    type = fetch_string_arg(call_args(call), "type")
    {:ok, %{items: AssetStore.list(project_ctx.asset_store, type)}}
  end

  def execute(project_ctx, %{kind: :asset_search}, call) do
    args = call_args(call)
    type = fetch_string_arg(args, "type")
    query = fetch_string_arg(args, "query")
    {:ok, %{items: AssetStore.search(project_ctx.asset_store, type, query)}}
  end

  def execute(project_ctx, %{kind: :asset_get}, call) do
    args = call_args(call)
    type = fetch_string_arg(args, "type")
    key = fetch_string_arg(args, "key")

    case AssetStore.get(project_ctx.asset_store, type, key) do
      {:ok, asset} -> {:ok, %{asset: asset}}
      :error -> {:error, :asset_not_found}
    end
  end

  def execute(project_ctx, %{kind: :subagent_spawn} = spec, call) do
    spawn_subagent_tool(project_ctx, spec, call)
  end

  def execute(_project_ctx, _spec, _call), do: {:error, :unsupported_tool}

  defp spawn_subagent_tool(project_ctx, spec, call) do
    template = Map.get(spec, :template) || %{}
    template_id = Map.get(spec, :template_id)
    conversation_id = conversation_id_from_call(call)

    with true <- is_binary(conversation_id),
         true <- is_binary(template_id) and template_id != "",
         :ok <- ensure_subagent_manager(project_ctx),
         :ok <-
           Policy.authorize_subagent_spawn(project_ctx.policy, template_id, %{
             project_id: Map.get(project_ctx, :project_id),
             conversation_id: conversation_id,
             correlation_id: correlation_id_from_call(call)
           }),
         {:ok, request} <- subagent_spawn_request(call_args(call), template),
         {:ok, subagent_ref} <-
           SubAgentManager.spawn_from_template(
             project_ctx.subagent_manager,
             template,
             conversation_id,
             request,
             %{
               project_id: Map.get(project_ctx, :project_id),
               conversation_id: conversation_id,
               correlation_id: correlation_id_from_call(call)
             }
           ) do
      {:ok, %{subagent: subagent_ref_payload(subagent_ref)}}
    else
      false -> {:error, :missing_conversation_id}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_subagent_manager(project_ctx) do
    manager = Map.get(project_ctx, :subagent_manager)
    if is_nil(manager), do: {:error, :subagent_manager_unavailable}, else: :ok
  end

  defp subagent_spawn_request(args, template) when is_map(args) do
    goal = map_get_value(args, "goal")
    inputs = map_get_value(args, "inputs")
    ttl_ms = map_get_value(args, "ttl_ms")

    with :ok <- validate_spawn_goal(goal),
         :ok <- validate_spawn_inputs(inputs),
         :ok <- validate_spawn_ttl(ttl_ms) do
      {:ok,
       %{
         "goal" => goal,
         "inputs" => if(is_map(inputs), do: inputs, else: %{}),
         "ttl_ms" => bounded_ttl(ttl_ms, template)
       }}
    end
  end

  defp validate_spawn_goal(goal) when is_binary(goal) do
    if String.trim(goal) == "", do: {:error, :invalid_spawn_goal}, else: :ok
  end

  defp validate_spawn_goal(_goal), do: {:error, :invalid_spawn_goal}

  defp validate_spawn_inputs(nil), do: :ok
  defp validate_spawn_inputs(inputs) when is_map(inputs), do: :ok
  defp validate_spawn_inputs(_inputs), do: {:error, :invalid_spawn_inputs}

  defp validate_spawn_ttl(nil), do: :ok
  defp validate_spawn_ttl(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0, do: :ok
  defp validate_spawn_ttl(_ttl_ms), do: {:error, :invalid_spawn_ttl}

  defp bounded_ttl(nil, template) do
    Map.get(template, :ttl_ms) || 300_000
  end

  defp bounded_ttl(ttl_ms, template) when is_integer(ttl_ms) do
    max_ttl = Map.get(template, :ttl_ms) || ttl_ms
    min(ttl_ms, max_ttl)
  end

  defp subagent_ref_payload(%_{} = ref) do
    %{
      child_id: Map.get(ref, :child_id),
      template_id: Map.get(ref, :template_id),
      owner_conversation_id: Map.get(ref, :owner_conversation_id),
      pid: inspect(Map.get(ref, :pid)),
      started_at: format_started_at(Map.get(ref, :started_at)),
      status: normalize_status(Map.get(ref, :status)),
      correlation_id: Map.get(ref, :correlation_id)
    }
  end

  defp format_started_at(%DateTime{} = started_at), do: DateTime.to_iso8601(started_at)
  defp format_started_at(started_at), do: started_at

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status), do: status

  defp conversation_id_from_call(tool_call) do
    meta = call_meta(tool_call)
    Map.get(meta, :conversation_id) || Map.get(meta, "conversation_id")
  end

  defp correlation_id_from_call(tool_call) do
    case Correlation.fetch(call_meta(tool_call)) do
      {:ok, correlation_id} -> correlation_id
      :error -> nil
    end
  end

  defp call_args(%ToolCall{args: args}) when is_map(args), do: args
  defp call_args(%{args: args}) when is_map(args), do: args
  defp call_args(%{"args" => args}) when is_map(args), do: args
  defp call_args(_), do: %{}

  defp call_meta(%ToolCall{meta: meta}) when is_map(meta), do: meta
  defp call_meta(%{meta: meta}) when is_map(meta), do: meta
  defp call_meta(%{"meta" => meta}) when is_map(meta), do: meta
  defp call_meta(_), do: %{}

  defp map_get_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        find_atom_key_value(map, key)
    end
  end

  defp find_atom_key_value(map, key) when is_map(map) and is_binary(key) do
    Enum.find_value(map, fn
      {atom_key, value} when is_atom(atom_key) ->
        if Atom.to_string(atom_key) == key, do: value

      _other ->
        nil
    end)
  end

  defp fetch_string_arg(args, key) when is_map(args) do
    value =
      Enum.find_value(args, fn
        {^key, val} when is_binary(val) ->
          val

        {atom_key, val} when is_atom(atom_key) and is_binary(val) ->
          if Atom.to_string(atom_key) == key, do: val, else: nil

        _ ->
          nil
      end)

    if is_binary(value), do: value, else: ""
  end
end
