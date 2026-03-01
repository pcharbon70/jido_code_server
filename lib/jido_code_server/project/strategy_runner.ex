defmodule Jido.Code.Server.Project.StrategyRunner do
  @moduledoc """
  Strategy adapter gateway for conversation execution.

  This module resolves the effective strategy for a mode, validates that the
  strategy is supported by mode capabilities, selects an adapter module, and
  delegates execution to that adapter.
  """

  alias Jido.Code.Server.Conversation.ExecutionLifecycle
  alias Jido.Code.Server.Conversation.ModeRegistry
  alias Jido.Code.Server.Project.StrategyRunner.Default
  alias Jido.Code.Server.Project.StrategyRunner.Normalizer
  alias Jido.Code.Server.Telemetry

  @type capabilities :: %{
          optional(:streaming?) => boolean(),
          optional(:tool_calling?) => boolean(),
          optional(:cancellable?) => boolean(),
          optional(:supported_strategies) => [atom() | String.t()]
        }

  @callback start(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback capabilities() :: capabilities()
  @callback stream(map(), map(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  @callback cancel(map(), map(), keyword()) :: :ok | {:error, term()}

  @optional_callbacks stream: 3, cancel: 3

  @default_runner Default

  @spec prepare(map(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(project_ctx, envelope) when is_map(project_ctx) and is_map(envelope) do
    with mode <- normalize_mode(map_get(envelope, :mode) || :coding),
         {:ok, strategy_type} <- resolve_strategy_type(project_ctx, envelope, mode),
         :ok <- validate_mode_strategy_support(project_ctx, mode, strategy_type),
         {:ok, runner} <- resolve_runner(project_ctx, envelope, strategy_type),
         :ok <- validate_runner(runner),
         :ok <- validate_runner_capabilities(runner, strategy_type) do
      {:ok,
       envelope
       |> Map.put(:mode, mode)
       |> Map.put(:strategy_type, strategy_type)
       |> Map.put(:strategy_runner, runner)}
    end
  end

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(project_ctx, envelope) when is_map(project_ctx) and is_map(envelope) do
    runner = map_get(envelope, :strategy_runner) || @default_runner

    with :ok <- validate_runner(runner) do
      emit_strategy_started(project_ctx, envelope, runner)

      case runner.start(project_ctx, envelope, []) do
        {:ok, result} -> handle_runner_success(project_ctx, envelope, result)
        {:error, reason} -> handle_runner_error(project_ctx, envelope, reason)
      end
    end
  end

  @spec cancel(map(), map(), keyword()) :: :ok | {:error, term()}
  def cancel(project_ctx, envelope, opts \\ []) when is_map(project_ctx) and is_map(envelope) do
    with {:ok, prepared} <- prepare(project_ctx, envelope),
         runner <- map_get(prepared, :strategy_runner) || @default_runner,
         :ok <- validate_runner(runner) do
      emit_strategy_cancel_requested(project_ctx, prepared, runner)

      case cancel_with_runner(runner, project_ctx, prepared, opts) do
        :ok ->
          emit_strategy_cancelled(project_ctx, prepared, runner)
          :ok

        {:error, reason} = error ->
          emit_strategy_cancel_failed(project_ctx, prepared, runner, reason)
          error
      end
    end
  end

  defp handle_runner_success(project_ctx, envelope, result) when is_map(result) do
    with {:ok, normalized} <- Normalizer.normalize_success(envelope, result) do
      emit_strategy_terminal(project_ctx, envelope, normalized)
      {:ok, normalized}
    end
  end

  defp handle_runner_error(project_ctx, envelope, reason) do
    with {:ok, normalized_error} <- Normalizer.normalize_error(envelope, reason) do
      emit_strategy_terminal(project_ctx, envelope, normalized_error)
      {:error, normalized_error}
    end
  end

  @spec resolve_strategy_type(map(), map(), atom()) :: {:ok, String.t()} | {:error, term()}
  def resolve_strategy_type(project_ctx, envelope, mode)
      when is_map(project_ctx) and is_map(envelope) and is_atom(mode) do
    resolved =
      normalize_strategy_type(map_get(envelope, :strategy_type)) ||
        strategy_override_for_mode(project_ctx, mode) ||
        normalize_strategy_type(map_get(map_get(envelope, :mode_state), "strategy")) ||
        mode_default_strategy(project_ctx, mode)

    if is_binary(resolved) and resolved != "" do
      {:ok, resolved}
    else
      {:error, {:invalid_strategy_type, resolved}}
    end
  end

  defp validate_mode_strategy_support(project_ctx, mode, strategy_type)
       when is_map(project_ctx) and is_atom(mode) and is_binary(strategy_type) do
    case ModeRegistry.capabilities(mode, project_ctx) do
      {:ok, capabilities} ->
        supported =
          capabilities
          |> Map.get(:strategy_support, [])
          |> List.wrap()
          |> Enum.map(&normalize_strategy_type/1)
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        if supported == [] or strategy_type in supported do
          :ok
        else
          {:error, {:unsupported_strategy_for_mode, mode, strategy_type}}
        end

      {:error, :unknown_mode} ->
        {:error, {:unknown_mode, mode}}
    end
  end

  defp resolve_runner(project_ctx, envelope, strategy_type)
       when is_map(project_ctx) and is_map(envelope) and is_binary(strategy_type) do
    requested_runner =
      envelope
      |> map_get(:strategy_opts)
      |> map_get("runner")
      |> normalize_runner_module()

    registry_runner =
      project_ctx
      |> strategy_runner_registry()
      |> Map.get(strategy_type)

    fallback_runner = normalize_runner_module(map_get(project_ctx, :strategy_runner))

    runner = requested_runner || registry_runner || fallback_runner || @default_runner
    {:ok, runner}
  end

  defp validate_runner(runner) when is_atom(runner) do
    with {:module, _loaded} <- Code.ensure_loaded(runner),
         true <- function_exported?(runner, :start, 3) do
      :ok
    else
      _other -> {:error, {:invalid_strategy_runner, runner}}
    end
  end

  defp validate_runner(_runner), do: {:error, :invalid_strategy_runner}

  defp validate_runner_capabilities(runner, strategy_type)
       when is_atom(runner) and is_binary(strategy_type) do
    if function_exported?(runner, :capabilities, 0) do
      caps = runner.capabilities()

      with true <- is_map(caps),
           true <- boolean_capability?(caps, :streaming?),
           true <- boolean_capability?(caps, :tool_calling?),
           true <- boolean_capability?(caps, :cancellable?),
           :ok <- supported_by_runner?(caps, strategy_type, runner) do
        :ok
      else
        false -> {:error, {:invalid_strategy_runner_capabilities, runner}}
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  defp boolean_capability?(caps, key) do
    case Map.fetch(caps, key) do
      {:ok, value} -> is_boolean(value)
      :error -> true
    end
  end

  defp supported_by_runner?(caps, strategy_type, runner) do
    supported =
      caps
      |> Map.get(:supported_strategies, [])
      |> List.wrap()
      |> Enum.map(&normalize_strategy_type/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if supported == [] or strategy_type in supported do
      :ok
    else
      {:error, {:unsupported_strategy_for_runner, runner, strategy_type}}
    end
  end

  defp strategy_runner_registry(project_ctx) when is_map(project_ctx) do
    project_ctx
    |> map_get(:strategy_runner_registry)
    |> normalize_runner_registry()
  end

  defp normalize_runner_registry(registry) when is_map(registry) do
    Enum.reduce(registry, %{}, fn {key, value}, acc ->
      strategy_type = normalize_strategy_type(key)
      runner_module = normalize_runner_module(value)

      if is_binary(strategy_type) and is_atom(runner_module) do
        Map.put(acc, strategy_type, runner_module)
      else
        acc
      end
    end)
  end

  defp normalize_runner_registry(_registry), do: %{}

  defp strategy_override_for_mode(project_ctx, mode) when is_map(project_ctx) and is_atom(mode) do
    runtime_override =
      project_ctx
      |> map_get(:strategy_defaults)
      |> map_get(mode)
      |> normalize_strategy_type()

    if is_binary(runtime_override) do
      runtime_override
    else
      project_ctx
      |> map_get(:conversation_mode_defaults)
      |> map_get(mode)
      |> map_get("strategy")
      |> normalize_strategy_type()
    end
  end

  defp mode_default_strategy(project_ctx, mode) do
    case ModeRegistry.fetch(mode, project_ctx) do
      {:ok, mode_spec} ->
        mode_spec
        |> map_get(:defaults)
        |> map_get("strategy")
        |> normalize_strategy_type()

      _other ->
        case mode do
          :planning -> "planning"
          :engineering -> "engineering_design"
          _ -> "code_generation"
        end
    end
  end

  defp normalize_mode(mode) when is_atom(mode), do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    case String.trim(mode) do
      "" -> :coding
      value -> String.to_atom(String.downcase(value))
    end
  end

  defp normalize_mode(_mode), do: :coding

  defp normalize_strategy_type(nil), do: nil

  defp normalize_strategy_type(strategy_type) when is_atom(strategy_type),
    do: strategy_type |> Atom.to_string() |> normalize_strategy_type()

  defp normalize_strategy_type(strategy_type) when is_binary(strategy_type) do
    strategy_type
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_strategy_type(_strategy_type), do: nil

  defp normalize_runner_module(module) when is_atom(module), do: module
  defp normalize_runner_module(_module), do: nil

  defp emit_strategy_started(project_ctx, envelope, runner) do
    Telemetry.emit("conversation.strategy.started", %{
      project_id: map_get(project_ctx, :project_id),
      conversation_id: map_get(envelope, :conversation_id),
      execution_id: map_get(envelope, :execution_id),
      correlation_id: map_get(envelope, :correlation_id),
      cause_id: map_get(envelope, :cause_id),
      run_id: map_get(envelope, :run_id),
      step_id: map_get(envelope, :step_id),
      strategy_type: map_get(envelope, :strategy_type),
      strategy_runner: runner_name(runner),
      lifecycle_status: "started"
    })
  end

  defp emit_strategy_terminal(project_ctx, envelope, result) when is_map(result) do
    result_meta = normalize_strategy_result_meta(result)
    terminal_status = strategy_terminal_status(result_meta)
    lifecycle_status = strategy_lifecycle_status(terminal_status)
    retryable = strategy_retryable?(result, result_meta)

    payload =
      strategy_terminal_payload(
        project_ctx,
        envelope,
        result,
        result_meta,
        retryable,
        lifecycle_status
      )

    Telemetry.emit(strategy_terminal_event_name(terminal_status), payload)
    maybe_emit_strategy_retryable(payload, retryable, terminal_status)
  end

  defp normalize_strategy_result_meta(result) do
    normalize_map(map_get(result, "result_meta"))
  end

  defp strategy_terminal_status(result_meta) do
    map_get(result_meta, "terminal_status") || "completed"
  end

  defp strategy_lifecycle_status(terminal_status) do
    ExecutionLifecycle.normalize_status(terminal_status) || "completed"
  end

  defp strategy_retryable?(result, result_meta) do
    map_get(result, "retryable") == true or map_get(result_meta, "retryable") == true
  end

  defp strategy_terminal_event_name("failed"), do: "conversation.strategy.failed"
  defp strategy_terminal_event_name("cancelled"), do: "conversation.strategy.cancelled"
  defp strategy_terminal_event_name(_status), do: "conversation.strategy.completed"

  defp strategy_terminal_payload(
         project_ctx,
         envelope,
         result,
         result_meta,
         retryable,
         lifecycle_status
       ) do
    %{
      project_id: map_get(project_ctx, :project_id),
      conversation_id: map_get(envelope, :conversation_id),
      execution_id: map_get(result_meta, "execution_id") || map_get(envelope, :execution_id),
      correlation_id: map_get(envelope, :correlation_id),
      cause_id: map_get(envelope, :cause_id),
      run_id: map_get(result_meta, "run_id") || map_get(envelope, :run_id),
      step_id: map_get(result_meta, "step_id") || map_get(envelope, :step_id),
      strategy_type: map_get(envelope, :strategy_type),
      strategy_runner:
        map_get(result_meta, "strategy_runner") ||
          runner_name(map_get(envelope, :strategy_runner)),
      execution_ref: map_get(result, "execution_ref"),
      retryable: retryable,
      lifecycle_status: lifecycle_status
    }
  end

  defp maybe_emit_strategy_retryable(payload, true, terminal_status)
       when terminal_status in ["failed", "cancelled"] do
    Telemetry.emit("conversation.strategy.retryable", payload)
  end

  defp maybe_emit_strategy_retryable(_payload, _retryable, _terminal_status), do: :ok

  defp runner_name(runner) when is_atom(runner) do
    runner
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp runner_name(runner) when is_binary(runner), do: runner
  defp runner_name(_runner), do: "unknown"

  defp cancel_with_runner(runner, project_ctx, envelope, opts) when is_atom(runner) do
    if function_exported?(runner, :cancel, 3) do
      case runner.cancel(project_ctx, envelope, opts) do
        :ok -> :ok
        {:error, _reason} = error -> error
        _other -> {:error, {:invalid_cancel_response, runner}}
      end
    else
      :ok
    end
  end

  defp emit_strategy_cancel_requested(project_ctx, envelope, runner) do
    Telemetry.emit("conversation.strategy.cancel.requested", %{
      project_id: map_get(project_ctx, :project_id),
      conversation_id: map_get(envelope, :conversation_id),
      run_id: map_get(envelope, :run_id),
      step_id: map_get(envelope, :step_id),
      strategy_type: map_get(envelope, :strategy_type),
      strategy_runner: runner_name(runner),
      correlation_id: map_get(envelope, :correlation_id),
      cause_id: map_get(envelope, :cause_id),
      reason: map_get(envelope, :reason)
    })
  end

  defp emit_strategy_cancelled(project_ctx, envelope, runner) do
    Telemetry.emit("conversation.strategy.cancelled", %{
      project_id: map_get(project_ctx, :project_id),
      conversation_id: map_get(envelope, :conversation_id),
      run_id: map_get(envelope, :run_id),
      step_id: map_get(envelope, :step_id),
      strategy_type: map_get(envelope, :strategy_type),
      strategy_runner: runner_name(runner),
      correlation_id: map_get(envelope, :correlation_id),
      cause_id: map_get(envelope, :cause_id),
      reason: map_get(envelope, :reason),
      lifecycle_status: "canceled"
    })
  end

  defp emit_strategy_cancel_failed(project_ctx, envelope, runner, reason) do
    Telemetry.emit("conversation.strategy.cancel.failed", %{
      project_id: map_get(project_ctx, :project_id),
      conversation_id: map_get(envelope, :conversation_id),
      run_id: map_get(envelope, :run_id),
      step_id: map_get(envelope, :step_id),
      strategy_type: map_get(envelope, :strategy_type),
      strategy_runner: runner_name(runner),
      correlation_id: map_get(envelope, :correlation_id),
      cause_id: map_get(envelope, :cause_id),
      reason: inspect(reason)
    })
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp map_get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp map_get(_map, _key), do: nil

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
