defmodule JidoCodeServer.Project.ToolRunner do
  @moduledoc """
  Unified, policy-gated tool execution path for project runtime.
  """

  alias JidoCodeServer.Config
  alias JidoCodeServer.Project.AssetStore
  alias JidoCodeServer.Project.Policy
  alias JidoCodeServer.Project.ToolCatalog
  alias JidoCodeServer.Telemetry
  alias JidoCodeServer.Types.ToolCall

  @timeout_table __MODULE__.Timeouts
  @schema_atom_keys %{
    "type" => :type,
    "required" => :required,
    "properties" => :properties,
    "additionalProperties" => :additionalProperties,
    "additional_properties" => :additional_properties
  }

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(project_ctx, tool_call) when is_map(project_ctx) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, normalized_call} <- normalize_call(tool_call),
         {:ok, spec} <- ToolCatalog.get_tool(project_ctx, normalized_call.name),
         :ok <- validate_tool_args(spec, normalized_call.args),
         :ok <-
           Policy.authorize_tool(
             project_ctx.policy,
             normalized_call.name,
             normalized_call.args,
             normalized_call.meta,
             Map.get(spec, :safety, %{}) || %{},
             project_ctx
           ),
         :ok <- ensure_capacity(project_ctx),
         :ok <- emit_started(project_ctx, normalized_call, spec),
         {:ok, result} <- execute_within_task(project_ctx, spec, normalized_call),
         :ok <- enforce_result_limits(project_ctx, result) do
      duration_ms = System.monotonic_time(:millisecond) - started_at
      response = success_response(normalized_call, spec, duration_ms, result)
      Telemetry.emit("tool.completed", response)
      {:ok, response}
    else
      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at
        error = error_response(tool_call, duration_ms, reason)
        maybe_emit_timeout_signals(project_ctx, tool_call, reason)
        Telemetry.emit("tool.failed", error)
        {:error, error}
    end
  end

  @spec run_async(map(), map(), keyword()) :: :ok
  def run_async(project_ctx, tool_call, opts \\ []) when is_map(project_ctx) do
    notify = Keyword.get(opts, :notify)

    _ =
      Task.Supervisor.start_child(project_ctx.task_supervisor, fn ->
        result = run(project_ctx, tool_call)

        if is_pid(notify) do
          send(notify, {:tool_result, tool_name(tool_call), result})
        end
      end)

    :ok
  end

  defp execute_within_task(project_ctx, spec, call) do
    timeout_ms = Map.get(project_ctx, :tool_timeout_ms, Config.tool_timeout_ms())

    task =
      Task.Supervisor.async_nolink(project_ctx.task_supervisor, fn ->
        execute_tool(project_ctx, spec, call)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, reason}} ->
        {:error, {:tool_failed, reason}}

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, {:task_exit, reason}}
    end
  end

  defp execute_tool(project_ctx, spec, call) do
    case spec.kind do
      :asset_list ->
        type = fetch_string_arg(call.args, "type")
        {:ok, %{items: AssetStore.list(project_ctx.asset_store, type)}}

      :asset_search ->
        type = fetch_string_arg(call.args, "type")
        query = fetch_string_arg(call.args, "query")
        {:ok, %{items: AssetStore.search(project_ctx.asset_store, type, query)}}

      :asset_get ->
        type = fetch_string_arg(call.args, "type")
        key = fetch_string_arg(call.args, "key")

        case AssetStore.get(project_ctx.asset_store, type, key) do
          {:ok, asset} -> {:ok, %{asset: asset}}
          :error -> {:error, :asset_not_found}
        end

      :command_run ->
        run_asset_tool(project_ctx, :command, spec.asset_name, call)

      :workflow_run ->
        run_asset_tool(project_ctx, :workflow, spec.asset_name, call)

      _other ->
        {:error, :unsupported_tool}
    end
  end

  defp run_asset_tool(project_ctx, type, asset_name, call) do
    case AssetStore.get(project_ctx.asset_store, type, asset_name) do
      {:ok, asset} ->
        {:ok,
         %{
           asset: asset,
           args: call.args,
           mode: :preview,
           note: "Execution bridge to jido_command/jido_workflow is introduced in later phases."
         }}

      :error ->
        {:error, :asset_not_found}
    end
  end

  defp ensure_capacity(project_ctx) do
    max_concurrency = Map.get(project_ctx, :tool_max_concurrency, Config.tool_max_concurrency())
    running = length(Task.Supervisor.children(project_ctx.task_supervisor))

    if running < max_concurrency do
      :ok
    else
      {:error, :max_concurrency_reached}
    end
  end

  defp emit_started(project_ctx, call, spec) do
    Telemetry.emit("tool.started", %{
      project_id: project_ctx.project_id,
      tool: call.name,
      kind: spec.kind,
      args: call.args
    })

    :ok
  end

  defp success_response(call, spec, duration_ms, result) do
    %{
      status: :ok,
      tool: call.name,
      kind: spec.kind,
      duration_ms: duration_ms,
      result: result
    }
  end

  defp error_response(tool_call, duration_ms, reason) do
    %{
      status: :error,
      tool: tool_name(tool_call),
      duration_ms: duration_ms,
      reason: reason
    }
  end

  defp normalize_call(%ToolCall{name: name, args: args, meta: meta}) do
    normalize_call(%{name: name, args: args, meta: meta})
  end

  defp normalize_call(%{name: name} = call) when is_binary(name) do
    args = Map.get(call, :args, %{}) || %{}
    meta = Map.get(call, :meta, %{}) || %{}

    if is_map(args) and is_map(meta) do
      {:ok, %{name: name, args: args, meta: meta}}
    else
      {:error, :invalid_tool_call}
    end
  end

  defp normalize_call(_invalid), do: {:error, :invalid_tool_call}

  defp validate_tool_args(spec, args) when is_map(spec) and is_map(args) do
    schema = Map.get(spec, :input_schema, %{}) || %{}

    case validate_schema(args, schema) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_tool_args, reason}}
    end
  end

  defp validate_schema(args, schema) when is_map(schema) do
    type = map_get(schema, "type")

    case type do
      "object" -> validate_object_schema(args, schema)
      nil -> :ok
      _other -> :ok
    end
  end

  defp validate_schema(_args, _schema), do: :ok

  defp validate_object_schema(args, schema) do
    with {:ok, normalized_args} <- normalize_arg_keys(args),
         :ok <- validate_required_keys(normalized_args, schema),
         :ok <- validate_additional_keys(normalized_args, schema) do
      validate_property_types(normalized_args, schema)
    end
  end

  defp normalize_arg_keys(args) when is_map(args) do
    Enum.reduce_while(args, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, Atom.to_string(key), value)}}

      {key, _value}, _acc ->
        {:halt, {:error, {:invalid_arg_key, inspect(key)}}}
    end)
  end

  defp validate_required_keys(args, schema) do
    required = map_get(schema, "required")
    required_list = if is_list(required), do: required, else: []
    missing = Enum.reject(required_list, &Map.has_key?(args, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_required_args, missing}}
    end
  end

  defp validate_additional_keys(args, schema) do
    additional = map_get(schema, "additionalProperties")

    if additional == false do
      properties = map_get(schema, "properties")
      allowed = if is_map(properties), do: normalized_property_keys(properties), else: []
      unexpected = Map.keys(args) -- allowed

      if unexpected == [] do
        :ok
      else
        {:error, {:unexpected_args, unexpected}}
      end
    else
      :ok
    end
  end

  defp validate_property_types(args, schema) do
    properties = map_get(schema, "properties")

    if is_map(properties) do
      normalized_properties = normalize_property_schema(properties)
      validate_property_entries(args, normalized_properties)
    else
      :ok
    end
  end

  defp validate_property_entries(args, properties) do
    Enum.reduce_while(args, :ok, fn {key, value}, :ok ->
      reduce_property_entry(key, value, properties)
    end)
  end

  defp reduce_property_entry(key, value, properties) do
    case validate_property_entry(properties, key, value) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:invalid_arg_type, key, reason}}}
    end
  end

  defp validate_property_type(_value, schema) when not is_map(schema), do: :ok

  defp validate_property_type(value, schema),
    do: validate_known_type(value, map_get(schema, "type"))

  defp validate_type(value, predicate, expected_type) do
    if predicate.(value), do: :ok, else: {:error, {:expected, expected_type}}
  end

  defp validate_known_type(_value, nil), do: :ok
  defp validate_known_type(value, "string"), do: validate_type(value, &is_binary/1, "string")
  defp validate_known_type(value, "integer"), do: validate_type(value, &is_integer/1, "integer")
  defp validate_known_type(value, "number"), do: validate_type(value, &is_number/1, "number")
  defp validate_known_type(value, "boolean"), do: validate_type(value, &is_boolean/1, "boolean")
  defp validate_known_type(value, "object"), do: validate_type(value, &is_map/1, "object")
  defp validate_known_type(value, "array"), do: validate_type(value, &is_list/1, "array")
  defp validate_known_type(value, "null"), do: validate_type(value, &is_nil/1, "null")
  defp validate_known_type(_value, _other), do: :ok

  defp validate_property_entry(properties, key, value) do
    case Map.fetch(properties, key) do
      {:ok, property_schema} -> validate_property_type(value, property_schema)
      :error -> :ok
    end
  end

  defp normalize_property_schema(properties) when is_map(properties) do
    Enum.reduce(properties, %{}, fn {key, value}, acc ->
      case normalize_property_key(key) do
        nil -> acc
        normalized -> Map.put(acc, normalized, value)
      end
    end)
  end

  defp normalized_property_keys(properties) when is_map(properties) do
    properties
    |> normalize_property_schema()
    |> Map.keys()
  end

  defp normalize_property_key(key) when is_binary(key), do: key
  defp normalize_property_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_property_key(_key), do: nil

  defp enforce_result_limits(project_ctx, result) do
    max_output_bytes =
      Map.get(project_ctx, :tool_max_output_bytes, Config.tool_max_output_bytes())

    max_artifact_bytes =
      Map.get(project_ctx, :tool_max_artifact_bytes, Config.tool_max_artifact_bytes())

    result_size = term_size(result)

    if result_size > max_output_bytes do
      {:error, {:output_too_large, result_size, max_output_bytes}}
    else
      enforce_artifact_limits(result, max_artifact_bytes)
    end
  end

  defp enforce_artifact_limits(result, max_artifact_bytes) do
    artifacts = Map.get(result, :artifacts) || Map.get(result, "artifacts")

    if is_list(artifacts) do
      Enum.with_index(artifacts)
      |> Enum.reduce_while(:ok, fn {artifact, index}, :ok ->
        validate_artifact_size(artifact, index, max_artifact_bytes)
      end)
    else
      :ok
    end
  end

  defp validate_artifact_size(artifact, index, max_artifact_bytes) do
    artifact_size = term_size(artifact)

    if artifact_size > max_artifact_bytes do
      {:halt, {:error, {:artifact_too_large, index, artifact_size, max_artifact_bytes}}}
    else
      {:cont, :ok}
    end
  end

  defp term_size(term) do
    term
    |> :erlang.term_to_binary()
    |> byte_size()
  rescue
    _error -> 0
  end

  defp maybe_emit_timeout_signals(project_ctx, tool_call, :timeout) do
    tool = tool_name(tool_call)

    threshold =
      Map.get(project_ctx, :tool_timeout_alert_threshold, Config.tool_timeout_alert_threshold())

    timeout_count = increment_timeout_counter(project_ctx.project_id, tool)
    conversation_id = conversation_id_from_call(tool_call)

    Telemetry.emit("tool.timeout", %{
      project_id: project_ctx.project_id,
      conversation_id: conversation_id,
      tool: tool,
      timeout_count: timeout_count
    })

    if timeout_count >= threshold do
      Telemetry.emit("security.repeated_timeout_failures", %{
        project_id: project_ctx.project_id,
        conversation_id: conversation_id,
        tool: tool,
        timeout_count: timeout_count,
        threshold: threshold
      })
    end
  end

  defp maybe_emit_timeout_signals(_project_ctx, _tool_call, _reason), do: :ok

  defp increment_timeout_counter(project_id, tool) do
    ensure_timeout_table()
    key = {normalize_project_key(project_id), tool}

    try do
      :ets.update_counter(@timeout_table, key, {2, 1}, {key, 0})
    rescue
      _error -> 1
    end
  end

  defp ensure_timeout_table do
    case :ets.whereis(@timeout_table) do
      :undefined ->
        :ets.new(@timeout_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      :ok
  end

  defp normalize_project_key(project_id) when is_binary(project_id) and project_id != "",
    do: project_id

  defp normalize_project_key(_project_id), do: "global"

  defp conversation_id_from_call(%ToolCall{meta: meta}) when is_map(meta) do
    Map.get(meta, :conversation_id) || Map.get(meta, "conversation_id")
  end

  defp conversation_id_from_call(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :conversation_id) || Map.get(meta, "conversation_id")
  end

  defp conversation_id_from_call(_), do: nil

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.get(@schema_atom_keys, key) do
      nil -> Map.get(map, key)
      atom_key -> Map.get(map, key) || Map.get(map, atom_key)
    end
  end

  defp tool_name(%ToolCall{name: name}) when is_binary(name), do: name
  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(_), do: "unknown"

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
