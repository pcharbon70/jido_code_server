defmodule Jido.Code.Server.Project.StrategyRunner do
  @moduledoc """
  Strategy adapter gateway for conversation execution.

  This module resolves the effective strategy for a mode, validates that the
  strategy is supported by mode capabilities, selects an adapter module, and
  delegates execution to that adapter.
  """

  alias Jido.Code.Server.Conversation.ModeRegistry
  alias Jido.Code.Server.Project.StrategyRunner.Default

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

    with :ok <- validate_runner(runner),
         {:ok, result} <- runner.start(project_ctx, envelope, []),
         true <- is_map(result) do
      {:ok, result}
    else
      false ->
        {:error, {:invalid_strategy_runner_result, runner}}

      {:error, _reason} = error ->
        error
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
