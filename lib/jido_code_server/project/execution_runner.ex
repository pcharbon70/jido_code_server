defmodule Jido.Code.Server.Project.ExecutionRunner do
  @moduledoc """
  Unified, policy-gated tool execution path for project runtime.
  """

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Conversation.LLM
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.CommandRunner
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.ToolCatalog
  alias Jido.Code.Server.Project.ToolRunner
  alias Jido.Code.Server.Project.WorkflowRunner
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

  @spec run_execution(map(), map()) :: {:ok, map()} | {:error, term()}
  def run_execution(project_ctx, execution_envelope)
      when is_map(project_ctx) and is_map(execution_envelope) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, envelope} <- normalize_execution_envelope(project_ctx, execution_envelope),
         :ok <- emit_execution_started(project_ctx, envelope),
         {:ok, result} <- execute_envelope(project_ctx, envelope) do
      duration_ms = System.monotonic_time(:millisecond) - started_at

      response =
        normalize_execution_success(project_ctx, envelope, result)
        |> Map.put("duration_ms", duration_ms)

      Telemetry.emit("conversation.execution.completed", response)
      {:ok, response}
    else
      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - started_at

        error =
          normalize_execution_error(project_ctx, execution_envelope, reason)
          |> Map.put("duration_ms", duration_ms)

        Telemetry.emit("conversation.execution.failed", error)
        {:error, error}
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
                |> success_response(project_ctx.project_id, spec, duration_ms, result)
                |> maybe_flag_sensitive_result(project_ctx)

              Telemetry.emit("conversation.tool.completed", response)
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
    error = error_response(project_ctx.project_id, tool_call, duration_ms, reason)
    maybe_emit_timeout_signals(project_ctx, tool_call, reason)
    maybe_emit_env_signals(project_ctx, tool_call, reason)
    Telemetry.emit("conversation.tool.failed", error)
    {:error, error}
  end

  defp execute_within_task(project_ctx, spec, call) do
    timeout_ms = Map.get(project_ctx, :tool_timeout_ms, Config.tool_timeout_ms())
    owner_pid = self()

    task =
      Task.Supervisor.async_nolink(project_ctx.task_supervisor, fn ->
        task_project_ctx =
          project_ctx
          |> Map.put(:task_owner_pid, owner_pid)
          |> Map.put(:task_pid, self())

        execute_tool(task_project_ctx, spec, call)
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
            prune_dead_registered_child_processes(owner_pid)
            handle_task_reply(task_reply)
        end

      task_reply ->
        unregister_child_process(owner_pid, task.pid)
        prune_dead_registered_child_processes(owner_pid)
        handle_task_reply(task_reply)
    end
  end

  defp execute_tool(project_ctx, spec, call) do
    case Map.get(spec, :kind) do
      kind when kind in [:asset_list, :asset_search, :asset_get, :subagent_spawn] ->
        ToolRunner.execute(project_ctx, spec, call)

      :command_run ->
        CommandRunner.execute(project_ctx, spec, call)

      :workflow_run ->
        WorkflowRunner.execute(project_ctx, spec, call)

      _other ->
        {:error, :unsupported_tool}
    end
  end

  defp execute_envelope(project_ctx, %{execution_kind: :strategy_run} = envelope) do
    execute_strategy(project_ctx, envelope)
  end

  defp execute_envelope(_project_ctx, %{execution_kind: execution_kind}) do
    {:error, {:unsupported_execution_kind, execution_kind}}
  end

  defp normalize_execution_envelope(project_ctx, execution_envelope) do
    envelope = normalize_string_key_map(execution_envelope)
    execution_kind = normalize_execution_kind(map_get_any(envelope, "execution_kind"))
    mode = normalize_execution_mode(map_get_any(envelope, "mode"))
    mode_state = normalize_map(map_get_any(envelope, "mode_state"))
    strategy_type = normalize_strategy_type(map_get_any(envelope, "strategy_type"), mode)

    with :strategy_run <- execution_kind,
         {:ok, source_signal} <- normalize_source_signal(map_get_any(envelope, "source_signal")),
         conversation_id when is_binary(conversation_id) <-
           map_get_any(envelope, "conversation_id") || Map.get(project_ctx, :conversation_id) do
      {:ok,
       %{
         execution_kind: execution_kind,
         name: map_get_any(envelope, "name") || "mode.#{mode}.strategy",
         conversation_id: conversation_id,
         mode: mode,
         mode_state: mode_state,
         strategy_type: strategy_type,
         strategy_opts: normalize_map(map_get_any(envelope, "strategy_opts")),
         source_signal: source_signal,
         llm_context: normalize_map(map_get_any(envelope, "llm_context")),
         correlation_id:
           map_get_any(envelope, "correlation_id") ||
             ConversationSignal.correlation_id(source_signal),
         cause_id: map_get_any(envelope, "cause_id") || source_signal.id,
         meta: normalize_map(map_get_any(envelope, "meta"))
       }}
    else
      nil -> {:error, :invalid_execution_kind}
      false -> {:error, :missing_conversation_id}
      other -> other
    end
  end

  defp emit_execution_started(project_ctx, envelope) do
    Telemetry.emit("conversation.execution.started", %{
      project_id: project_ctx.project_id,
      conversation_id: envelope.conversation_id,
      execution_kind: envelope.execution_kind,
      strategy_type: envelope.strategy_type,
      correlation_id: envelope.correlation_id,
      cause_id: envelope.cause_id
    })

    :ok
  end

  defp normalize_execution_success(project_ctx, envelope, result) do
    %{
      "status" => "ok",
      "project_id" => project_ctx.project_id,
      "conversation_id" => envelope.conversation_id,
      "execution_kind" => Atom.to_string(envelope.execution_kind),
      "signals" => normalize_execution_signals(map_get_any(result, "signals")),
      "result_meta" =>
        normalize_map(map_get_any(result, "result_meta"))
        |> Map.put_new("strategy_type", envelope.strategy_type)
        |> Map.put_new("mode", Atom.to_string(envelope.mode)),
      "execution_ref" => strategy_execution_ref(envelope)
    }
  end

  defp normalize_execution_error(project_ctx, execution_envelope, reason) do
    envelope = normalize_string_key_map(execution_envelope)
    execution_kind = normalize_execution_kind(map_get_any(envelope, "execution_kind")) || :unknown

    %{
      "status" => "error",
      "project_id" => project_ctx.project_id,
      "conversation_id" =>
        map_get_any(envelope, "conversation_id") || Map.get(project_ctx, :conversation_id),
      "execution_kind" => Atom.to_string(execution_kind),
      "reason" => normalize_reason(reason),
      "retryable" => retryable_execution_error?(reason)
    }
  end

  defp execute_strategy(project_ctx, envelope) do
    requested_signal =
      new_strategy_signal(
        "conversation.llm.requested",
        %{"source_signal_id" => envelope.source_signal.id},
        envelope.conversation_id,
        envelope.correlation_id
      )

    opts =
      [source_event: ConversationSignal.to_map(envelope.source_signal)]
      |> maybe_put_opt(
        :tool_specs,
        available_tool_specs(project_ctx, envelope.mode, envelope.mode_state)
      )
      |> maybe_put_opt(:model, map_get_any(envelope.strategy_opts, "model"))
      |> maybe_put_opt(:system_prompt, map_get_any(envelope.strategy_opts, "system_prompt"))
      |> maybe_put_opt(:temperature, map_get_any(envelope.strategy_opts, "temperature"))
      |> maybe_put_opt(:max_tokens, map_get_any(envelope.strategy_opts, "max_tokens"))
      |> maybe_put_opt(:timeout_ms, map_get_any(envelope.strategy_opts, "timeout_ms"))
      |> maybe_put_opt(:adapter, map_get_any(envelope.strategy_opts, "adapter"))

    case LLM.start_completion(project_ctx, envelope.conversation_id, envelope.llm_context, opts) do
      {:ok, %{events: events}} ->
        completion_signals =
          events
          |> List.wrap()
          |> Enum.flat_map(
            &event_to_strategy_signals(&1, envelope.conversation_id, envelope.correlation_id)
          )

        {:ok,
         %{
           "signals" =>
             Enum.map([requested_signal | completion_signals], &ConversationSignal.to_map/1),
           "result_meta" => %{
             "execution_kind" => "strategy_run",
             "strategy_type" => envelope.strategy_type,
             "mode" => Atom.to_string(envelope.mode),
             "signal_count" => length(completion_signals) + 1
           },
           "execution_ref" => strategy_execution_ref(envelope)
         }}

      {:error, reason} ->
        failed_signal =
          new_strategy_signal(
            "conversation.llm.failed",
            %{"reason" => normalize_reason(reason)},
            envelope.conversation_id,
            envelope.correlation_id
          )

        {:error,
         %{
           "signals" => Enum.map([requested_signal, failed_signal], &ConversationSignal.to_map/1),
           "result_meta" => %{
             "execution_kind" => "strategy_run",
             "strategy_type" => envelope.strategy_type,
             "mode" => Atom.to_string(envelope.mode),
             "retryable" => retryable_execution_error?(reason)
           },
           "execution_ref" => strategy_execution_ref(envelope),
           "reason" => normalize_reason(reason),
           "retryable" => retryable_execution_error?(reason)
         }}
    end
  end

  defp available_tool_specs(project_ctx, mode, mode_state) do
    tools = ToolCatalog.llm_tools(project_ctx, mode: mode, mode_state: mode_state)

    project_ctx
    |> filter_available_tools(tools)
    |> Enum.map(&tool_spec/1)
  rescue
    _error ->
      []
  catch
    :exit, _reason ->
      []
  end

  defp filter_available_tools(project_ctx, tools) when is_list(tools) do
    case Map.get(project_ctx, :policy) do
      nil -> tools
      policy -> Policy.filter_tools(policy, tools)
    end
  end

  defp event_to_strategy_signals(raw_event, conversation_id, fallback_correlation_id)
       when is_map(raw_event) do
    case ConversationSignal.normalize(raw_event) do
      {:ok, %Jido.Signal{type: "conversation.llm.started"}} ->
        []

      {:ok, normalized_event} ->
        correlation_id =
          ConversationSignal.correlation_id(normalized_event) || fallback_correlation_id

        [
          new_strategy_signal(
            normalized_event.type,
            normalized_event.data,
            conversation_id,
            correlation_id
          )
        ]

      {:error, _reason} ->
        []
    end
  end

  defp event_to_strategy_signals(_raw_event, _conversation_id, _fallback_correlation_id), do: []

  defp new_strategy_signal(type, data, conversation_id, correlation_id) do
    attrs =
      [
        source: "/conversation/#{conversation_id}",
        extensions: if(correlation_id, do: %{"correlation_id" => correlation_id}, else: %{})
      ]

    Jido.Signal.new!(type, normalize_execution_map(data), attrs)
  end

  defp normalize_execution_signals(signals) when is_list(signals) do
    signals
    |> Enum.flat_map(fn signal ->
      case ConversationSignal.normalize(signal) do
        {:ok, normalized} -> [ConversationSignal.to_map(normalized)]
        {:error, _reason} -> []
      end
    end)
  end

  defp normalize_execution_signals(_signals), do: []

  defp retryable_execution_error?(reason) do
    match?(%{"retryable" => true}, reason) or
      match?({:task_exit, _}, reason) or
      reason in [:timeout, :temporary_failure]
  end

  defp strategy_execution_ref(envelope) do
    base = envelope.correlation_id || envelope.cause_id || "unknown"
    "strategy:#{base}"
  end

  defp normalize_execution_kind(:strategy_run), do: :strategy_run
  defp normalize_execution_kind("strategy_run"), do: :strategy_run
  defp normalize_execution_kind(_kind), do: nil

  defp normalize_execution_mode(mode) when is_atom(mode), do: mode

  defp normalize_execution_mode(mode) when is_binary(mode) do
    case String.trim(mode) do
      "" -> :coding
      normalized -> String.to_atom(String.downcase(normalized))
    end
  end

  defp normalize_execution_mode(_mode), do: :coding

  defp normalize_strategy_type(strategy_type, _mode)
       when is_binary(strategy_type) and strategy_type != "",
       do: strategy_type

  defp normalize_strategy_type(strategy_type, _mode) when is_atom(strategy_type),
    do: Atom.to_string(strategy_type)

  defp normalize_strategy_type(_strategy_type, :planning), do: "planning"
  defp normalize_strategy_type(_strategy_type, :engineering), do: "engineering_design"
  defp normalize_strategy_type(_strategy_type, _mode), do: "code_generation"

  defp normalize_source_signal(%Jido.Signal{} = signal), do: {:ok, signal}

  defp normalize_source_signal(signal) when is_map(signal),
    do: ConversationSignal.normalize(signal)

  defp normalize_source_signal(_signal), do: {:error, :invalid_source_signal}

  defp normalize_execution_map(map) when is_map(map), do: map
  defp normalize_execution_map(_map), do: %{}

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp tool_spec(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema
    }
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, []), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

  defp map_get_any(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, safe_to_existing_atom(key))

  defp normalize_string_key_map(%_{} = value), do: value

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

  defp safe_to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
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
    Telemetry.emit("conversation.tool.started", %{
      project_id: project_ctx.project_id,
      conversation_id: conversation_id_from_call(call),
      correlation_id: correlation_id_from_call(call),
      tool: call.name,
      kind: spec.kind,
      args: call.args
    })

    :ok
  end

  defp success_response(call, project_id, spec, duration_ms, result) do
    %{
      status: :ok,
      project_id: project_id,
      tool: call.name,
      conversation_id: conversation_id_from_call(call),
      correlation_id: correlation_id_from_call(call),
      kind: spec.kind,
      duration_ms: duration_ms,
      result: result
    }
  end

  defp error_response(project_id, tool_call, duration_ms, reason) do
    %{
      status: :error,
      project_id: project_id,
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
    result
    |> collect_artifacts()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {artifact, index}, :ok ->
      validate_artifact_size(artifact, index, max_artifact_bytes)
    end)
  end

  defp collect_artifacts(%_{} = _struct), do: []

  defp collect_artifacts(term) when is_map(term) do
    direct_artifacts =
      case map_get_value(term, "artifacts") do
        artifacts when is_list(artifacts) -> artifacts
        _other -> []
      end

    nested_artifacts =
      term
      |> Map.values()
      |> Enum.flat_map(&collect_artifacts/1)

    direct_artifacts ++ nested_artifacts
  end

  defp collect_artifacts(term) when is_list(term) do
    Enum.flat_map(term, &collect_artifacts/1)
  end

  defp collect_artifacts(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> collect_artifacts()
  end

  defp collect_artifacts(_term), do: []

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

    Telemetry.emit("conversation.tool.timeout", %{
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
    Telemetry.emit("conversation.tool.child_processes_terminated", %{
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

  defp prune_dead_registered_child_processes(owner_pid) when is_pid(owner_pid) do
    owner_pid
    |> list_registered_child_processes()
    |> Enum.each(fn child_pid ->
      if not Process.alive?(child_pid) do
        unregister_child_process(owner_pid, child_pid)
      end
    end)

    :ok
  rescue
    _error ->
      :ok
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
end
