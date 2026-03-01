defmodule Jido.Code.Server.Conversation.Domain.StepPlanner do
  @moduledoc """
  Pure planning rules for mode-run step execution intents.
  """

  alias Jido.Code.Server.Conversation.Domain.ModePipeline
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @default_max_turn_steps 32
  @default_max_retries 1
  @default_retry_backoff_base_ms 250
  @default_retry_backoff_max_ms 4_000

  @spec plan(State.t(), State.t(), Jido.Signal.t()) :: [map()]
  def plan(%State{} = previous_state, %State{} = state, %Jido.Signal{} = signal) do
    case signal.type do
      "conversation.user.message" ->
        plan_start(previous_state, state, signal)

      "conversation.tool.completed" ->
        plan_continue(state, signal, "continue")

      "conversation.tool.failed" ->
        plan_continue(state, signal, "continue_after_tool_failure")

      "conversation.llm.failed" ->
        plan_retry(state, signal)

      _other ->
        []
    end
  end

  defp plan_start(%State{} = previous_state, %State{} = state, %Jido.Signal{} = signal) do
    cond do
      not state.orchestration_enabled ->
        []

      state.status == :cancelled ->
        []

      previous_state.active_run != nil ->
        []

      not is_map(state.active_run) ->
        []

      max_steps_reached?(state) ->
        [guardrail_signal_intent(state, signal)]

      true ->
        [strategy_intent(state, signal, "start")]
    end
  end

  defp plan_continue(%State{} = state, %Jido.Signal{} = signal, reason) when is_binary(reason) do
    mode_pipeline = ModePipeline.resolve(state.mode, state.mode_state)

    cond do
      not state.orchestration_enabled ->
        []

      state.status == :cancelled ->
        []

      not is_map(state.active_run) ->
        []

      state.pending_tool_calls != [] ->
        []

      not ModePipeline.continue_signal?(mode_pipeline, signal.type) ->
        []

      not correlation_matches_active_run?(state, signal) ->
        []

      max_steps_reached?(state) ->
        [guardrail_signal_intent(state, signal)]

      true ->
        [strategy_intent(state, signal, reason, mode_pipeline)]
    end
  end

  defp plan_retry(%State{} = state, %Jido.Signal{} = signal) do
    cond do
      not state.orchestration_enabled ->
        []

      state.status == :cancelled ->
        []

      not is_map(state.active_run) ->
        []

      state.pending_tool_calls != [] ->
        []

      not retryable_failure?(signal) ->
        []

      not can_retry?(state.active_run) ->
        []

      max_steps_reached?(state) ->
        [guardrail_signal_intent(state, signal)]

      true ->
        [strategy_intent(state, signal, "retry")]
    end
  end

  defp strategy_intent(%State{} = state, %Jido.Signal{} = signal, reason) do
    strategy_intent(state, signal, reason, ModePipeline.resolve(state.mode, state.mode_state))
  end

  defp strategy_intent(%State{} = state, %Jido.Signal{} = signal, reason, mode_pipeline) do
    active_run = state.active_run || %{}
    run_id = map_get(active_run, "run_id")
    next_step_index = current_step_count(active_run) + 1
    retry_count = current_retry_count(active_run)
    max_retries = max_retries(active_run)
    retry_attempt = retry_attempt(reason, retry_count)
    retry_backoff_ms = retry_backoff_ms(reason, retry_attempt, active_run, state.mode_state)
    retry_policy = retry_policy(active_run, state.mode_state)

    %{
      kind: :run_execution,
      execution_kind: :strategy_run,
      source_signal: signal,
      meta: %{
        "pipeline" =>
          ModePipeline.pipeline_meta(mode_pipeline,
            reason: reason,
            run_id: run_id,
            step_index: next_step_index,
            predecessor_step_id:
              map_get(active_run, "current_step_id") ||
                map_get(active_run, "last_completed_step_id"),
            retry_count: retry_count,
            max_retries: max_retries,
            retry_attempt: retry_attempt,
            retry_backoff_ms: retry_backoff_ms,
            retry_policy: retry_policy
          )
      }
    }
  end

  defp guardrail_signal_intent(%State{} = state, %Jido.Signal{} = signal) do
    active_run = state.active_run || %{}
    run_id = map_get(active_run, "run_id") || ConversationSignal.correlation_id(signal)
    max_turn_steps = max_turn_steps(active_run, state.mode_state)

    guardrail_signal =
      Jido.Signal.new!(
        "conversation.llm.failed",
        %{
          "reason" => "max_turn_steps_exceeded",
          "retryable" => false,
          "max_turn_steps" => max_turn_steps,
          "step_count" => current_step_count(active_run),
          "run_id" => run_id
        },
        source: "/conversation/#{state.conversation_id}",
        extensions: %{
          "correlation_id" => run_id,
          "cause_id" => signal.id
        }
      )

    %{kind: :emit_signal, signal: guardrail_signal}
  end

  defp max_steps_reached?(%State{} = state) do
    active_run = state.active_run || %{}
    current_step_count(active_run) >= max_turn_steps(active_run, state.mode_state)
  end

  defp correlation_matches_active_run?(%State{} = state, %Jido.Signal{} = signal) do
    signal_correlation_id = ConversationSignal.correlation_id(signal)
    active_run_id = state.active_run |> map_get("run_id")

    is_binary(signal_correlation_id) and signal_correlation_id != "" and
      is_binary(active_run_id) and active_run_id != "" and signal_correlation_id == active_run_id
  end

  defp retryable_failure?(%Jido.Signal{data: data}) when is_map(data) do
    data["retryable"] == true or data[:retryable] == true
  end

  defp retryable_failure?(_signal), do: false

  defp can_retry?(active_run) when is_map(active_run) do
    current_retry_count(active_run) < max_retries(active_run)
  end

  defp can_retry?(_active_run), do: false

  defp current_step_count(active_run) when is_map(active_run) do
    active_run
    |> map_get("step_count")
    |> normalize_non_neg_integer(0)
  end

  defp current_step_count(_active_run), do: 0

  defp current_retry_count(active_run) when is_map(active_run) do
    active_run
    |> map_get("retry_count")
    |> normalize_non_neg_integer(0)
  end

  defp current_retry_count(_active_run), do: 0

  defp max_retries(active_run) when is_map(active_run) do
    active_run
    |> map_get("max_retries")
    |> normalize_non_neg_integer(@default_max_retries)
    |> max(1)
  end

  defp max_turn_steps(active_run, mode_state) when is_map(active_run) and is_map(mode_state) do
    from_run =
      active_run
      |> map_get("max_turn_steps")
      |> normalize_non_neg_integer(nil)

    from_mode_state =
      mode_state
      |> map_get("max_turn_steps")
      |> normalize_non_neg_integer(nil)

    (from_run || from_mode_state || @default_max_turn_steps)
    |> max(1)
  end

  defp max_turn_steps(_active_run, _mode_state), do: @default_max_turn_steps

  defp retry_attempt("retry", retry_count), do: retry_count + 1
  defp retry_attempt(_reason, retry_count), do: retry_count

  defp retry_backoff_ms("retry", retry_attempt, active_run, mode_state)
       when is_integer(retry_attempt) and retry_attempt > 0 do
    base_ms = retry_backoff_base_ms(active_run, mode_state)
    max_ms = retry_backoff_max_ms(active_run, mode_state)
    exponent = max(retry_attempt - 1, 0)
    unbounded = trunc(base_ms * :math.pow(2, exponent))
    min(unbounded, max_ms)
  end

  defp retry_backoff_ms(_reason, _retry_attempt, _active_run, _mode_state), do: 0

  defp retry_policy(active_run, mode_state) do
    %{
      "strategy" => "exponential",
      "base_ms" => retry_backoff_base_ms(active_run, mode_state),
      "max_ms" => retry_backoff_max_ms(active_run, mode_state)
    }
  end

  defp retry_backoff_base_ms(active_run, mode_state)
       when is_map(active_run) and is_map(mode_state) do
    from_run =
      active_run
      |> map_get("retry_backoff_base_ms")
      |> normalize_non_neg_integer(nil)

    from_mode_state =
      mode_state
      |> map_get("retry_backoff_base_ms")
      |> normalize_non_neg_integer(nil)

    (from_run || from_mode_state || @default_retry_backoff_base_ms)
    |> max(1)
  end

  defp retry_backoff_base_ms(_active_run, _mode_state), do: @default_retry_backoff_base_ms

  defp retry_backoff_max_ms(active_run, mode_state)
       when is_map(active_run) and is_map(mode_state) do
    from_run =
      active_run
      |> map_get("retry_backoff_max_ms")
      |> normalize_non_neg_integer(nil)

    from_mode_state =
      mode_state
      |> map_get("retry_backoff_max_ms")
      |> normalize_non_neg_integer(nil)

    resolved = from_run || from_mode_state || @default_retry_backoff_max_ms
    max(resolved, retry_backoff_base_ms(active_run, mode_state))
  end

  defp retry_backoff_max_ms(_active_run, _mode_state), do: @default_retry_backoff_max_ms

  defp normalize_non_neg_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp normalize_non_neg_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp normalize_non_neg_integer(_value, default), do: default

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp map_get(_map, _key), do: nil

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
