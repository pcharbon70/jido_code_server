defmodule Jido.Code.Server.Project.ToolRunner do
  @moduledoc """
  Unified, policy-gated tool execution path for project runtime.
  """

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.AssetStore
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.ToolCatalog
  alias Jido.Code.Server.Telemetry
  alias Jido.Code.Server.Types.ToolCall

  @timeout_table __MODULE__.Timeouts
  @concurrency_table __MODULE__.Concurrency
  @child_process_table __MODULE__.ChildProcesses
  @schema_atom_keys %{
    "type" => :type,
    "required" => :required,
    "properties" => :properties,
    "additionalProperties" => :additionalProperties,
    "additional_properties" => :additional_properties
  }
  @max_sensitivity_findings 25
  @sensitive_key_fragments [
    "token",
    "secret",
    "password",
    "api_key",
    "apikey",
    "authorization",
    "credential",
    "private_key",
    "access_key"
  ]
  @sensitive_patterns [
    {:bearer_token, ~r/\bBearer\s+[A-Za-z0-9\-\._~\+\/]+=*/i},
    {:openai_key, ~r/\bsk-[A-Za-z0-9]{16,}\b/},
    {:github_token, ~r/\bghp_[A-Za-z0-9]{20,}\b/},
    {:github_pat, ~r/\bgithub_pat_[A-Za-z0-9_]{20,}\b/},
    {:aws_access_key, ~r/\bAKIA[0-9A-Z]{16}\b/},
    {:slack_token, ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/}
  ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(project_ctx, tool_call) when is_map(project_ctx) do
    started_at = System.monotonic_time(:millisecond)

    case normalize_call(tool_call) do
      {:ok, normalized_call} ->
        correlated_call = ensure_call_correlation(normalized_call)
        execute_run(project_ctx, correlated_call, started_at)

      {:error, reason} ->
        run_failed(project_ctx, tool_call, started_at, reason)
    end
  end

  @spec run_async(map(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def run_async(project_ctx, tool_call, opts \\ []) when is_map(project_ctx) do
    notify = Keyword.get(opts, :notify)

    case normalize_call(tool_call) do
      {:ok, normalized_call} ->
        correlated_call = ensure_call_correlation(normalized_call)
        start_async_task(project_ctx, correlated_call, notify)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cancel_task(map(), pid(), map()) :: :ok
  def cancel_task(project_ctx, task_pid, tool_call \\ %{})

  def cancel_task(project_ctx, task_pid, tool_call)
      when is_map(project_ctx) and is_pid(task_pid) and is_map(tool_call) do
    terminated_count = terminate_registered_child_processes(task_pid)

    maybe_emit_child_process_termination(
      project_ctx,
      tool_call,
      :conversation_cancelled,
      terminated_count
    )

    if Process.alive?(task_pid) do
      Process.exit(task_pid, :kill)
    end

    :ok
  end

  def cancel_task(_project_ctx, task_pid, _tool_call) when is_pid(task_pid) do
    _terminated_count = terminate_registered_child_processes(task_pid)

    if Process.alive?(task_pid) do
      Process.exit(task_pid, :kill)
    end

    :ok
  end

  def cancel_task(_project_ctx, _task_pid, _tool_call), do: :ok

  @spec register_child_process(pid(), pid()) :: :ok
  def register_child_process(owner_pid, child_pid)
      when is_pid(owner_pid) and is_pid(child_pid) and owner_pid != child_pid do
    ensure_child_process_table()

    :ets.insert(
      @child_process_table,
      {{owner_pid, child_pid}, System.monotonic_time(:millisecond)}
    )

    :ok
  rescue
    _error ->
      :ok
  end

  def register_child_process(_owner_pid, _child_pid), do: :ok

  @spec unregister_child_process(pid(), pid()) :: :ok
  def unregister_child_process(owner_pid, child_pid)
      when is_pid(owner_pid) and is_pid(child_pid) do
    ensure_child_process_table()
    :ets.delete(@child_process_table, {owner_pid, child_pid})
    :ok
  rescue
    _error ->
      :ok
  end

  def unregister_child_process(_owner_pid, _child_pid), do: :ok

  defp execute_run(project_ctx, call, started_at) do
    run_ctx =
      project_ctx
      |> put_ctx_value(:conversation_id, conversation_id_from_call(call))
      |> put_ctx_value(:correlation_id, correlation_id_from_call(call))

    with {:ok, spec} <- ToolCatalog.get_tool(project_ctx, call.name),
         :ok <- validate_tool_args(spec, call.args),
         :ok <- enforce_env_controls(project_ctx, spec, call.args),
         :ok <-
           Policy.authorize_tool(
             project_ctx.policy,
             call.name,
             call.args,
             call.meta,
             Map.get(spec, :safety, %{}) || %{},
             run_ctx
           ) do
      case acquire_capacity(project_ctx, call) do
        {:ok, capacity_token} ->
          try do
            with :ok <- emit_started(project_ctx, call, spec),
                 {:ok, result} <- execute_within_task(project_ctx, spec, call),
                 :ok <- enforce_result_limits(project_ctx, result) do
              duration_ms = System.monotonic_time(:millisecond) - started_at

              response =
                call
                |> success_response(spec, duration_ms, result)
                |> maybe_flag_sensitive_result(project_ctx)

              Telemetry.emit("tool.completed", response)
              {:ok, response}
            else
              {:error, reason} ->
                run_failed(project_ctx, call, started_at, reason)
            end
          after
            release_capacity(capacity_token)
          end

        {:error, reason} ->
          run_failed(project_ctx, call, started_at, reason)
      end
    else
      {:error, reason} ->
        run_failed(project_ctx, call, started_at, reason)
    end
  end

  defp run_failed(project_ctx, tool_call, started_at, reason) do
    duration_ms = System.monotonic_time(:millisecond) - started_at
    error = error_response(tool_call, duration_ms, reason)
    maybe_emit_timeout_signals(project_ctx, tool_call, reason)
    maybe_emit_env_signals(project_ctx, tool_call, reason)
    Telemetry.emit("tool.failed", error)
    {:error, error}
  end

  defp execute_within_task(project_ctx, spec, call) do
    timeout_ms = Map.get(project_ctx, :tool_timeout_ms, Config.tool_timeout_ms())
    owner_pid = self()

    task =
      Task.Supervisor.async_nolink(project_ctx.task_supervisor, fn ->
        execute_tool(project_ctx, spec, call)
      end)

    register_child_process(owner_pid, task.pid)

    case Task.yield(task, timeout_ms) do
      nil ->
        case Task.shutdown(task, :brutal_kill) do
          nil ->
            terminated_count = terminate_registered_child_processes(owner_pid)
            maybe_emit_child_process_termination(project_ctx, call, :timeout, terminated_count)
            {:error, :timeout}

          task_reply ->
            unregister_child_process(owner_pid, task.pid)
            handle_task_reply(task_reply)
        end

      task_reply ->
        unregister_child_process(owner_pid, task.pid)
        handle_task_reply(task_reply)
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
        maybe_simulate_delay(call)
        execute_asset_tool(project_ctx, type, asset, call)

      :error ->
        {:error, :asset_not_found}
    end
  end

  defp execute_asset_tool(project_ctx, :command, asset, call) do
    case execute_command_asset_tool(project_ctx, asset, call) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:invalid_command_definition, reason}} ->
        {:ok,
         preview_asset_tool_result(
           asset,
           call.args,
           "Command definition is invalid for jido_command runtime; running in preview compatibility mode.",
           reason
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_asset_tool(project_ctx, :workflow, asset, call) do
    case execute_workflow_asset_tool(project_ctx, asset, call) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:invalid_workflow_definition, reason}} ->
        {:ok,
         preview_asset_tool_result(
           asset,
           call.args,
           "Workflow definition is invalid for jido_workflow runtime; running in preview compatibility mode.",
           reason
         )}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_command_asset_tool(project_ctx, asset, call) do
    with {:ok, definition} <- parse_command_definition(asset),
         {:ok, execution} <-
           execute_command_definition(
             definition,
             command_params_from_call(call.args),
             command_execution_context(project_ctx, call)
           ) do
      {:ok,
       %{
         asset: asset,
         args: call.args,
         mode: :executed,
         runtime: :jido_command,
         command: definition.name,
         execution: execution
       }}
    else
      {:error, {:invalid_command_definition, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:command_execution_failed, reason}}
    end
  end

  defp execute_workflow_asset_tool(project_ctx, asset, call) do
    with {:ok, definition} <- parse_workflow_definition(asset),
         {:ok, execution} <-
           execute_workflow_definition(
             definition,
             workflow_inputs_from_call(call.args),
             workflow_execution_opts(project_ctx, call, definition)
           ) do
      {:ok,
       %{
         asset: asset,
         args: call.args,
         mode: :executed,
         runtime: :jido_workflow,
         workflow: definition.name,
         execution: execution
       }}
    else
      {:error, {:invalid_workflow_definition, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:workflow_execution_failed, reason}}
    end
  end

  defp parse_command_definition(%{body: body, path: path})
       when is_binary(body) and is_binary(path) do
    case parse_command_frontmatter(body, path) do
      {:ok, definition} -> {:ok, definition}
      {:error, reason} -> {:error, {:invalid_command_definition, reason}}
    end
  end

  defp parse_command_definition(_asset),
    do: {:error, {:invalid_command_definition, :invalid_asset}}

  defp parse_workflow_definition(%{body: body}) when is_binary(body) do
    case parse_workflow_markdown(body) do
      {:ok, definition} -> {:ok, definition}
      {:error, reason} -> {:error, {:invalid_workflow_definition, reason}}
    end
  end

  defp parse_workflow_definition(_asset),
    do: {:error, {:invalid_workflow_definition, :invalid_asset}}

  defp command_params_from_call(args) when is_map(args) do
    case map_get_value(args, "params") do
      params when is_map(params) ->
        params

      _other ->
        Map.drop(args, ["params", :params, "simulate_delay_ms", :simulate_delay_ms, "env", :env])
    end
  end

  defp command_params_from_call(_args), do: %{}

  defp workflow_inputs_from_call(args) when is_map(args) do
    case map_get_value(args, "inputs") do
      inputs when is_map(inputs) ->
        inputs

      _other ->
        Map.drop(args, ["inputs", :inputs, "simulate_delay_ms", :simulate_delay_ms, "env", :env])
    end
  end

  defp workflow_inputs_from_call(_args), do: %{}

  defp command_execution_context(project_ctx, call) do
    %{
      project_id: project_ctx.project_id,
      conversation_id: conversation_id_from_call(call),
      correlation_id: correlation_id_from_call(call),
      project_root: project_ctx.root_path,
      invocation_id: command_invocation_id(call),
      bus: :jido_code_bus
    }
    |> maybe_put_command_executor(Map.get(project_ctx, :command_executor))
  end

  defp maybe_put_command_executor(context, executor_module)
       when is_atom(executor_module) and not is_nil(executor_module) do
    Map.put(context, :command_executor, executor_module)
  end

  defp maybe_put_command_executor(context, _executor_module), do: context

  defp workflow_execution_opts(project_ctx, call, definition) do
    []
    |> Keyword.put(:workflow_id, definition.name)
    |> Keyword.put(:run_id, workflow_run_id(call))
    |> Keyword.put(:bus, :jido_code_bus)
    |> maybe_put_opt(:backend, Map.get(project_ctx, :workflow_backend))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp command_invocation_id(call) do
    case correlation_id_from_call(call) do
      correlation_id when is_binary(correlation_id) and correlation_id != "" ->
        correlation_id

      _other ->
        "cmd-#{System.unique_integer([:positive, :monotonic])}"
    end
  end

  defp workflow_run_id(call) do
    case correlation_id_from_call(call) do
      correlation_id when is_binary(correlation_id) and correlation_id != "" ->
        correlation_id

      _other ->
        "wf-#{System.unique_integer([:positive, :monotonic])}"
    end
  end

  defp preview_asset_tool_result(asset, args, note, reason) when is_binary(note) do
    base = %{
      asset: asset,
      args: args,
      mode: :preview,
      note: note
    }

    if is_nil(reason), do: base, else: Map.put(base, :reason, reason)
  end

  defp parse_command_frontmatter(body, path) when is_binary(body) and is_binary(path) do
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

  defp parse_workflow_markdown(body) when is_binary(body) do
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

  defp execute_command_definition(definition, params, context)
       when is_map(params) and is_map(context) do
    runtime_module = JidoCommand.Extensibility.CommandRuntime

    case Code.ensure_loaded(runtime_module) do
      {:module, _loaded} ->
        if function_exported?(runtime_module, :execute, 3) do
          runtime_module.execute(definition, params, context)
        else
          {:error, :command_runtime_unavailable}
        end

      _other ->
        {:error, :command_runtime_unavailable}
    end
  end

  defp execute_workflow_definition(definition, inputs, opts)
       when is_map(inputs) and is_list(opts) do
    runtime_module = JidoWorkflow.Workflow.Engine

    case Code.ensure_loaded(runtime_module) do
      {:module, _loaded} ->
        if function_exported?(runtime_module, :execute_definition, 3) do
          runtime_module.execute_definition(definition, inputs, opts)
        else
          {:error, :workflow_runtime_unavailable}
        end

      _other ->
        {:error, :workflow_runtime_unavailable}
    end
  end

  defp enforce_env_controls(_project_ctx, %{kind: kind}, _args)
       when kind not in [:command_run, :workflow_run],
       do: :ok

  defp enforce_env_controls(project_ctx, _spec, args) when is_map(args) do
    case env_payload(args) do
      :missing ->
        :ok

      {:ok, payload} when is_map(payload) ->
        case normalize_env_keys(payload) do
          {:ok, env_keys} -> authorize_env_keys(project_ctx, env_keys)
          {:error, _reason} = error -> error
        end

      {:ok, _invalid_payload} ->
        {:error, :invalid_env_payload}
    end
  end

  defp enforce_env_controls(_project_ctx, _spec, _args), do: :ok

  defp env_payload(args) when is_map(args) do
    case Enum.find(args, fn
           {"env", _value} -> true
           {:env, _value} -> true
           _ -> false
         end) do
      nil -> :missing
      {_key, payload} -> {:ok, payload}
    end
  end

  defp normalize_env_keys(payload) when is_map(payload) do
    payload
    |> Map.keys()
    |> Enum.reduce_while([], fn key, acc ->
      case normalize_env_key(key) do
        {:ok, normalized} -> {:cont, [normalized | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error ->
        {:error, :invalid_env_payload}

      keys ->
        normalized =
          keys
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, normalized}
    end
  end

  defp normalize_env_key(key) when is_binary(key) do
    normalized = String.trim(key)
    if normalized == "", do: :error, else: {:ok, normalized}
  end

  defp normalize_env_key(key) when is_atom(key), do: normalize_env_key(Atom.to_string(key))
  defp normalize_env_key(_key), do: :error

  defp authorize_env_keys(_project_ctx, []), do: :ok

  defp authorize_env_keys(project_ctx, env_keys) do
    allowlist =
      project_ctx
      |> Map.get(:tool_env_allowlist, Config.tool_env_allowlist())
      |> normalize_env_allowlist()

    denied =
      env_keys
      |> Enum.reject(&(&1 in allowlist))
      |> Enum.uniq()
      |> Enum.sort()

    if denied == [] do
      :ok
    else
      {:error, {:env_vars_not_allowed, denied}}
    end
  end

  defp normalize_env_allowlist(allowlist) when is_list(allowlist) do
    allowlist
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_env_allowlist(_allowlist), do: []

  defp maybe_simulate_delay(call) do
    case simulate_delay_ms(call) do
      delay when is_integer(delay) and delay > 0 ->
        Process.sleep(delay)

      _ ->
        :ok
    end
  end

  defp simulate_delay_ms(call) do
    delay =
      call.args
      |> Map.to_list()
      |> Enum.find_value(fn
        {"simulate_delay_ms", value} when is_integer(value) -> value
        {:simulate_delay_ms, value} when is_integer(value) -> value
        _ -> nil
      end)

    if is_integer(delay) and delay > 0, do: min(delay, 5_000), else: 0
  end

  defp start_async_task(project_ctx, correlated_call, notify) do
    Task.Supervisor.start_child(project_ctx.task_supervisor, fn ->
      result = run(project_ctx, correlated_call)
      maybe_notify_async_result(notify, correlated_call, result)
    end)
  end

  defp maybe_notify_async_result(notify, correlated_call, result) when is_pid(notify) do
    send(notify, {:tool_result, self(), correlated_call, result})
  end

  defp maybe_notify_async_result(_notify, _correlated_call, _result), do: :ok

  defp handle_task_reply({:ok, {:ok, result}}), do: {:ok, result}
  defp handle_task_reply({:ok, {:error, reason}}), do: {:error, {:tool_failed, reason}}
  defp handle_task_reply({:exit, reason}), do: {:error, {:task_exit, reason}}

  defp acquire_capacity(project_ctx, call) do
    case ensure_project_capacity(project_ctx) do
      :ok ->
        acquire_conversation_capacity(project_ctx, call)

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_project_capacity(project_ctx) do
    max_concurrency = Map.get(project_ctx, :tool_max_concurrency, Config.tool_max_concurrency())
    running = length(Task.Supervisor.children(project_ctx.task_supervisor))

    if running < max_concurrency do
      :ok
    else
      {:error, :max_concurrency_reached}
    end
  end

  defp acquire_conversation_capacity(project_ctx, call) do
    case conversation_capacity_key(project_ctx, call) do
      nil ->
        {:ok, :none}

      key ->
        ensure_concurrency_table()
        max = conversation_capacity_limit(project_ctx)

        try do
          in_flight = :ets.update_counter(@concurrency_table, key, {2, 1}, {key, 0})

          if in_flight <= max do
            {:ok, {:conversation, key}}
          else
            _ = :ets.update_counter(@concurrency_table, key, {2, -1}, {key, 0})
            maybe_cleanup_conversation_key(key)
            {:error, :conversation_max_concurrency_reached}
          end
        rescue
          _error ->
            {:error, :conversation_max_concurrency_reached}
        end
    end
  end

  defp release_capacity(:none), do: :ok

  defp release_capacity({:conversation, key}) do
    ensure_concurrency_table()

    try do
      _ = :ets.update_counter(@concurrency_table, key, {2, -1}, {key, 0})
      maybe_cleanup_conversation_key(key)
    rescue
      _error -> :ok
    end
  end

  defp maybe_cleanup_conversation_key(key) do
    case :ets.lookup(@concurrency_table, key) do
      [{^key, count}] when is_integer(count) and count <= 0 ->
        :ets.delete(@concurrency_table, key)

      _ ->
        :ok
    end
  rescue
    _error -> :ok
  end

  defp conversation_capacity_key(project_ctx, call) do
    case normalize_conversation_id(conversation_id_from_call(call)) do
      nil ->
        nil

      conversation_id ->
        {:conversation, normalize_project_key(project_ctx.project_id), conversation_id}
    end
  end

  defp normalize_conversation_id(conversation_id) when is_binary(conversation_id) do
    trimmed = String.trim(conversation_id)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_conversation_id(_conversation_id), do: nil

  defp conversation_capacity_limit(project_ctx) do
    default = Config.tool_max_concurrency_per_conversation()

    case Map.get(project_ctx, :tool_max_concurrency_per_conversation, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp emit_started(project_ctx, call, spec) do
    Telemetry.emit("tool.started", %{
      project_id: project_ctx.project_id,
      conversation_id: conversation_id_from_call(call),
      correlation_id: correlation_id_from_call(call),
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
      conversation_id: conversation_id_from_call(call),
      correlation_id: correlation_id_from_call(call),
      kind: spec.kind,
      duration_ms: duration_ms,
      result: result
    }
  end

  defp error_response(tool_call, duration_ms, reason) do
    %{
      status: :error,
      tool: tool_name(tool_call),
      conversation_id: conversation_id_from_call(tool_call),
      correlation_id: correlation_id_from_call(tool_call),
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

  defp ensure_call_correlation(call) when is_map(call) do
    meta = call_meta(call)
    {_correlation_id, ensured_meta} = Correlation.ensure(meta)
    Map.put(call, :meta, ensured_meta)
  end

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
      "array" -> validate_array_schema(args, schema)
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
    required_list = normalize_required_keys(required)
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

  defp validate_property_type(value, schema) do
    case map_get(schema, "type") do
      "object" ->
        with :ok <- validate_type(value, &is_map/1, "object") do
          validate_object_schema(value, schema)
        end

      "array" ->
        with :ok <- validate_type(value, &is_list/1, "array") do
          validate_array_schema(value, schema)
        end

      type ->
        validate_known_type(value, type)
    end
  end

  defp validate_array_schema(items, schema) when is_list(items) and is_map(schema) do
    case map_get(schema, "items") do
      item_schema when is_map(item_schema) ->
        validate_array_items(items, item_schema)

      _other ->
        :ok
    end
  end

  defp validate_array_schema(_items, _schema), do: :ok

  defp validate_array_items(items, item_schema) when is_list(items) and is_map(item_schema) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      reduce_array_item(item, index, item_schema)
    end)
  end

  defp reduce_array_item(item, index, item_schema) do
    case validate_property_type(item, item_schema) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:invalid_array_item_type, index, reason}}}
    end
  end

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

  defp normalize_required_keys(required) when is_list(required) do
    required
    |> Enum.reduce([], fn
      key, acc when is_binary(key) ->
        normalized = String.trim(key)
        if normalized == "", do: acc, else: [normalized | acc]

      key, acc when is_atom(key) ->
        [Atom.to_string(key) | acc]

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp normalize_required_keys(_required), do: []

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

  defp maybe_flag_sensitive_result(response, project_ctx) do
    findings =
      response
      |> Map.get(:result)
      |> collect_sensitivity_findings()

    if findings == [] do
      response
    else
      emit_sensitive_artifact_signal(project_ctx, response, findings)

      response
      |> Map.put(:risk_flags, ["sensitive_artifact_detected"])
      |> Map.put(:sensitivity_findings_count, length(findings))
      |> Map.put(
        :sensitivity_finding_kinds,
        findings
        |> Enum.map(&Atom.to_string(&1.kind))
        |> Enum.uniq()
        |> Enum.sort()
      )
    end
  end

  defp emit_sensitive_artifact_signal(project_ctx, response, findings) do
    Telemetry.emit("security.sensitive_artifact_detected", %{
      project_id: project_ctx.project_id,
      conversation_id: Map.get(response, :conversation_id),
      correlation_id: Map.get(response, :correlation_id),
      tool: Map.get(response, :tool),
      finding_count: length(findings),
      finding_kinds:
        findings
        |> Enum.map(&Atom.to_string(&1.kind))
        |> Enum.uniq()
        |> Enum.sort(),
      finding_paths: findings |> Enum.map(& &1.path) |> Enum.take(10)
    })
  end

  defp collect_sensitivity_findings(term) do
    term
    |> scan_term_for_sensitivity([], [])
    |> Enum.uniq_by(&{&1.kind, &1.path})
    |> Enum.take(@max_sensitivity_findings)
  end

  defp scan_term_for_sensitivity(%_{} = _struct, _path, acc), do: acc

  defp scan_term_for_sensitivity(term, path, acc) when is_map(term) do
    Enum.reduce(term, acc, fn {key, value}, findings ->
      key_string = sensitivity_key_string(key)
      next_path = [key_string | path]

      findings =
        if sensitivity_key?(key_string) and non_empty_value?(value) do
          [%{kind: :sensitive_key, path: sensitivity_path(next_path)} | findings]
        else
          findings
        end

      scan_term_for_sensitivity(value, next_path, findings)
    end)
  end

  defp scan_term_for_sensitivity(term, path, acc) when is_list(term) do
    Enum.with_index(term)
    |> Enum.reduce(acc, fn {value, index}, findings ->
      scan_term_for_sensitivity(value, ["[#{index}]" | path], findings)
    end)
  end

  defp scan_term_for_sensitivity(term, path, acc) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> scan_term_for_sensitivity(path, acc)
  end

  defp scan_term_for_sensitivity(term, path, acc) when is_binary(term) do
    case sensitive_string_kind(term) do
      nil -> acc
      kind -> [%{kind: kind, path: sensitivity_path(path)} | acc]
    end
  end

  defp scan_term_for_sensitivity(_term, _path, acc), do: acc

  defp sensitive_string_kind(term) when is_binary(term) do
    Enum.find_value(@sensitive_patterns, fn {kind, pattern} ->
      if Regex.match?(pattern, term), do: kind, else: nil
    end)
  end

  defp sensitivity_key?(key) when is_binary(key) do
    normalized =
      key
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")

    Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1))
  end

  defp sensitivity_key_string(key) when is_binary(key), do: key
  defp sensitivity_key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp sensitivity_key_string(key), do: inspect(key)

  defp sensitivity_path(path) do
    path
    |> Enum.reverse()
    |> Enum.join(".")
  end

  defp non_empty_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_value?(nil), do: false
  defp non_empty_value?(_value), do: true

  defp maybe_emit_timeout_signals(project_ctx, tool_call, :timeout) do
    tool = tool_name(tool_call)

    threshold =
      Map.get(project_ctx, :tool_timeout_alert_threshold, Config.tool_timeout_alert_threshold())

    timeout_count = increment_timeout_counter(project_ctx.project_id, tool)
    conversation_id = conversation_id_from_call(tool_call)
    correlation_id = correlation_id_from_call(tool_call)

    Telemetry.emit("tool.timeout", %{
      project_id: project_ctx.project_id,
      conversation_id: conversation_id,
      correlation_id: correlation_id,
      tool: tool,
      timeout_count: timeout_count
    })

    if timeout_count >= threshold do
      Telemetry.emit("security.repeated_timeout_failures", %{
        project_id: project_ctx.project_id,
        conversation_id: conversation_id,
        correlation_id: correlation_id,
        tool: tool,
        timeout_count: timeout_count,
        threshold: threshold
      })
    end
  end

  defp maybe_emit_timeout_signals(_project_ctx, _tool_call, _reason), do: :ok

  defp maybe_emit_child_process_termination(project_ctx, tool_call, reason, terminated_count)
       when is_map(project_ctx) and is_integer(terminated_count) and terminated_count > 0 do
    Telemetry.emit("tool.child_processes_terminated", %{
      project_id: project_ctx.project_id,
      conversation_id: conversation_id_from_call(tool_call),
      correlation_id: correlation_id_from_call(tool_call),
      tool: tool_name(tool_call),
      reason: reason,
      terminated_child_process_count: terminated_count
    })
  end

  defp maybe_emit_child_process_termination(
         _project_ctx,
         _tool_call,
         _reason,
         _terminated_count
       ),
       do: :ok

  defp maybe_emit_env_signals(project_ctx, tool_call, {:env_vars_not_allowed, denied_env_keys}) do
    Telemetry.emit("security.env_denied", %{
      project_id: project_ctx.project_id,
      conversation_id: conversation_id_from_call(tool_call),
      correlation_id: correlation_id_from_call(tool_call),
      tool: tool_name(tool_call),
      reason: :env_vars_not_allowed,
      denied_env_keys: denied_env_keys
    })
  end

  defp maybe_emit_env_signals(project_ctx, tool_call, :invalid_env_payload) do
    Telemetry.emit("security.env_denied", %{
      project_id: project_ctx.project_id,
      conversation_id: conversation_id_from_call(tool_call),
      correlation_id: correlation_id_from_call(tool_call),
      tool: tool_name(tool_call),
      reason: :invalid_env_payload
    })
  end

  defp maybe_emit_env_signals(_project_ctx, _tool_call, _reason), do: :ok

  defp increment_timeout_counter(project_id, tool) do
    ensure_timeout_table()
    key = {normalize_project_key(project_id), tool}

    try do
      :ets.update_counter(@timeout_table, key, {2, 1}, {key, 0})
    rescue
      _error -> 1
    end
  end

  defp terminate_registered_child_processes(owner_pid) when is_pid(owner_pid) do
    child_pids = list_registered_child_processes(owner_pid)

    terminated_count =
      Enum.reduce(child_pids, 0, fn child_pid, terminated ->
        if Process.alive?(child_pid) do
          Process.exit(child_pid, :kill)
          terminated + 1
        else
          terminated
        end
      end)

    clear_registered_child_processes(owner_pid, child_pids)
    terminated_count
  rescue
    _error ->
      0
  end

  defp list_registered_child_processes(owner_pid) when is_pid(owner_pid) do
    ensure_child_process_table()

    @child_process_table
    |> :ets.match_object({{owner_pid, :"$1"}, :"$2"})
    |> Enum.map(fn {{^owner_pid, child_pid}, _started_at} -> child_pid end)
    |> Enum.reject(&(&1 == owner_pid))
    |> Enum.uniq()
  rescue
    _error ->
      []
  end

  defp clear_registered_child_processes(owner_pid, child_pids) when is_pid(owner_pid) do
    Enum.each(child_pids, fn child_pid ->
      unregister_child_process(owner_pid, child_pid)
    end)
  end

  defp ensure_concurrency_table do
    case :ets.whereis(@concurrency_table) do
      :undefined ->
        :ets.new(@concurrency_table, [
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

  defp ensure_child_process_table do
    case :ets.whereis(@child_process_table) do
      :undefined ->
        :ets.new(@child_process_table, [
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

  defp put_ctx_value(ctx, _key, nil), do: ctx
  defp put_ctx_value(ctx, key, value), do: Map.put(ctx, key, value)

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

  defp call_meta(%ToolCall{meta: meta}) when is_map(meta), do: meta
  defp call_meta(%{meta: meta}) when is_map(meta), do: meta
  defp call_meta(%{"meta" => meta}) when is_map(meta), do: meta
  defp call_meta(_), do: %{}

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    case Map.get(@schema_atom_keys, key) do
      nil -> Map.get(map, key)
      atom_key -> Map.get(map, key) || Map.get(map, atom_key)
    end
  end

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

  defp tool_name(%ToolCall{name: name}) when is_binary(name), do: name
  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(%{"name" => name}) when is_binary(name), do: name
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
