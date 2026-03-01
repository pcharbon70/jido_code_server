defmodule Jido.Code.Server.Conversation.Domain.Reducer do
  @moduledoc """
  Pure conversation domain reducer with deterministic queue semantics.
  """

  alias Jido.Code.Server.Conversation.Domain.ModeRun
  alias Jido.Code.Server.Conversation.Domain.Projections
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @type effect_intent :: map()
  @runtime_lifecycle_types [
    "conversation.mode.switch.accepted",
    "conversation.mode.switch.rejected",
    "conversation.run.opened",
    "conversation.run.closed",
    "conversation.run.interrupted",
    "conversation.run.resumed"
  ]

  @spec enqueue_signal(State.t(), Jido.Signal.t()) :: State.t()
  def enqueue_signal(%State{} = state, %Jido.Signal{} = signal) do
    dedupe_key = {signal.id, ConversationSignal.correlation_id(signal)}

    cond do
      MapSet.member?(state.seen_signals, dedupe_key) ->
        state

      state.queue_size >= state.max_queue_size ->
        overflow = queue_overflow_signal(state, signal)

        state
        |> append_timeline(overflow)
        |> put_correlation_index(overflow)
        |> refresh_projection_cache()

      true ->
        %{
          state
          | event_queue: :queue.in(signal, state.event_queue),
            queue_size: state.queue_size + 1,
            seen_signals: MapSet.put(state.seen_signals, dedupe_key)
        }
    end
  end

  @spec drain_once(State.t()) :: {State.t(), [effect_intent()]}
  def drain_once(%State{} = state) do
    do_drain(state, [], 0)
  end

  @spec apply_signal(State.t(), Jido.Signal.t()) :: {State.t(), [effect_intent()]}
  def apply_signal(%State{} = state, %Jido.Signal{} = signal) do
    next_state =
      state
      |> append_timeline(signal)
      |> update_status(signal)
      |> put_correlation_index(signal)
      |> update_pending_sets(signal)
      |> update_mode_runtime(signal)
      |> update_mode_switch(signal)
      |> increment_drain_iteration()

    intents = derive_effect_intents(state, next_state, signal)
    {next_state, intents}
  end

  @spec derive_effect_intents(State.t(), Jido.Signal.t()) :: [effect_intent()]
  def derive_effect_intents(%State{} = state, %Jido.Signal{} = signal) do
    derive_effect_intents(state, state, signal)
  end

  @spec derive_effect_intents(State.t(), State.t(), Jido.Signal.t()) :: [effect_intent()]
  def derive_effect_intents(%State{} = previous_state, %State{} = state, %Jido.Signal{} = signal) do
    lifecycle_intents = mode_run_lifecycle_intents(previous_state, state, signal)
    effect_intents_for_signal(previous_state, state, signal, lifecycle_intents)
  end

  defp effect_intents_for_signal(
         _previous_state,
         %State{} = state,
         %Jido.Signal{type: "conversation.cancel"} = signal,
         lifecycle_intents
       ) do
    cancel_effect_intents(state, signal) ++ lifecycle_intents
  end

  defp effect_intents_for_signal(
         %State{} = previous_state,
         %State{} = state,
         %Jido.Signal{type: "conversation.mode.switch.requested"} = signal,
         lifecycle_intents
       ) do
    mode_switch_effect_intents(previous_state, state, signal) ++ lifecycle_intents
  end

  defp effect_intents_for_signal(
         _previous_state,
         %State{status: :cancelled},
         %Jido.Signal{type: type},
         _lifecycle_intents
       )
       when type != "conversation.resume" do
    []
  end

  defp effect_intents_for_signal(
         _previous_state,
         %State{} = state,
         %Jido.Signal{type: "conversation.user.message"} = signal,
         lifecycle_intents
       ) do
    lifecycle_intents ++ maybe_run_llm_intent(state, signal)
  end

  defp effect_intents_for_signal(
         _previous_state,
         _state,
         %Jido.Signal{type: "conversation.tool.requested"} = signal,
         _lifecycle_intents
       ) do
    tool_requested_intents(signal)
  end

  defp effect_intents_for_signal(
         _previous_state,
         %State{} = state,
         %Jido.Signal{type: type} = signal,
         lifecycle_intents
       )
       when type in ["conversation.tool.completed", "conversation.tool.failed"] do
    maybe_run_llm_after_tool_intent(state, signal) ++ lifecycle_intents
  end

  defp effect_intents_for_signal(
         _previous_state,
         _state,
         %Jido.Signal{type: type},
         lifecycle_intents
       )
       when type in [
              "conversation.llm.completed",
              "conversation.llm.failed",
              "conversation.resume"
            ] do
    lifecycle_intents
  end

  defp effect_intents_for_signal(_previous_state, _state, _signal, lifecycle_intents) do
    lifecycle_intents
  end

  @spec update_pending_sets(State.t(), Jido.Signal.t()) :: State.t()
  def update_pending_sets(%State{} = state, %Jido.Signal{} = signal) do
    case signal.type do
      "conversation.tool.requested" ->
        update_pending_tools_on_requested(state, signal)

      type
      when type in [
             "conversation.tool.completed",
             "conversation.tool.failed",
             "conversation.tool.cancelled"
           ] ->
        update_pending_tools_on_terminal(state, signal)

      "conversation.cancel" ->
        state

      "conversation.subagent.started" ->
        put_pending_subagent(state, signal)

      type
      when type in [
             "conversation.subagent.completed",
             "conversation.subagent.failed",
             "conversation.subagent.stopped"
           ] ->
        pop_pending_subagent(state, signal)

      _other ->
        state
    end
  end

  @spec update_mode_runtime(State.t(), Jido.Signal.t()) :: State.t()
  def update_mode_runtime(%State{} = state, %Jido.Signal{} = signal) do
    state
    |> maybe_start_mode_run(signal)
    |> maybe_touch_active_run(signal)
    |> update_pending_steps(signal)
    |> maybe_finalize_mode_run(signal)
    |> sync_active_run_step_count()
  end

  @spec update_mode_switch(State.t(), Jido.Signal.t()) :: State.t()
  def update_mode_switch(
        %State{} = state,
        %Jido.Signal{
          type: "conversation.mode.switch.requested",
          data: data
        } = signal
      )
      when is_map(data) do
    requested_mode = normalize_switch_mode(map_get(data, "mode"))
    force? = switch_force?(data)
    reason = switch_reason(data)
    requested_mode_state = normalize_switch_mode_state(map_get(data, "mode_state"))

    cond do
      is_nil(requested_mode) ->
        state

      state.active_run != nil and not force? ->
        state

      true ->
        next_mode_state =
          resolve_switched_mode_state(state, requested_mode, requested_mode_state)

        state
        |> maybe_interrupt_active_run_for_switch(signal, force?, reason)
        |> Map.put(:mode, requested_mode)
        |> Map.put(:mode_state, next_mode_state)
    end
  end

  def update_mode_switch(%State{} = state, _signal), do: state

  defp maybe_interrupt_active_run_for_switch(state, _signal, false, _reason), do: state

  defp maybe_interrupt_active_run_for_switch(
         %State{active_run: nil} = state,
         _signal,
         true,
         _reason
       ),
       do: state

  defp maybe_interrupt_active_run_for_switch(
         %State{} = state,
         %Jido.Signal{} = signal,
         true,
         reason
       ) do
    close_active_run(state, :interrupted, signal, reason)
  end

  defp normalize_switch_mode(mode) when is_atom(mode), do: mode

  defp normalize_switch_mode(mode) when is_binary(mode) do
    case String.trim(mode) do
      "" -> nil
      normalized -> String.to_atom(String.downcase(normalized))
    end
  end

  defp normalize_switch_mode(_mode), do: nil

  defp normalize_switch_mode_state(mode_state) when is_map(mode_state),
    do: normalize_string_key_map(mode_state)

  defp normalize_switch_mode_state(_mode_state), do: nil

  defp resolve_switched_mode_state(state, requested_mode, nil) do
    if state.mode == requested_mode, do: state.mode_state, else: %{}
  end

  defp resolve_switched_mode_state(_state, _requested_mode, mode_state), do: mode_state

  defp switch_force?(data) when is_map(data) do
    value = map_get(data, "force")
    value == true or value == "true"
  end

  defp switch_reason(data) when is_map(data) do
    reason = map_get(data, "reason")

    if is_binary(reason) and String.trim(reason) != "" do
      String.trim(reason)
    else
      "mode_switch_forced"
    end
  end

  defp maybe_start_mode_run(
         %State{active_run: nil} = state,
         %Jido.Signal{
           type: "conversation.user.message"
         } = signal
       ) do
    %{state | active_run: new_mode_run(state, signal), pending_steps: []}
  end

  defp maybe_start_mode_run(state, _signal), do: state

  defp maybe_touch_active_run(%State{active_run: nil} = state, _signal), do: state

  defp maybe_touch_active_run(%State{} = state, %Jido.Signal{} = signal) do
    active_run =
      state.active_run
      |> Map.put(:last_signal_id, signal.id)
      |> Map.put(:last_signal_type, signal.type)
      |> Map.put(:updated_at, signal.time)

    %{state | active_run: active_run}
  end

  defp update_pending_steps(
         %State{} = state,
         %Jido.Signal{type: "conversation.tool.requested"} = signal
       ) do
    case {state.active_run, extract_tool_call(signal)} do
      {%{} = active_run, {:ok, tool_call}} ->
        step = pending_step(active_run, tool_call, signal)

        pending_steps =
          if Enum.any?(state.pending_steps, &(&1.step_id == step.step_id)) do
            state.pending_steps
          else
            state.pending_steps ++ [step]
          end

        %{state | pending_steps: pending_steps}

      _other ->
        state
    end
  end

  defp update_pending_steps(
         %State{} = state,
         %Jido.Signal{type: type} = signal
       )
       when type in [
              "conversation.tool.completed",
              "conversation.tool.failed",
              "conversation.tool.cancelled"
            ] do
    step_name = extract_tool_name(signal)
    correlation_id = ConversationSignal.correlation_id(signal)

    if is_binary(step_name) do
      pending_steps =
        Enum.reject(state.pending_steps, fn step ->
          same_name? = step.name == step_name
          same_correlation? = is_nil(correlation_id) or step.correlation_id == correlation_id
          same_name? and same_correlation?
        end)

      %{state | pending_steps: pending_steps}
    else
      state
    end
  end

  defp update_pending_steps(%State{} = state, %Jido.Signal{type: "conversation.cancel"}) do
    %{state | pending_steps: []}
  end

  defp update_pending_steps(state, _signal), do: state

  defp maybe_finalize_mode_run(
         %State{} = state,
         %Jido.Signal{type: "conversation.cancel"} = signal
       ) do
    close_active_run(state, :cancelled, signal, "conversation_cancelled")
  end

  defp maybe_finalize_mode_run(
         %State{} = state,
         %Jido.Signal{type: "conversation.llm.failed"} = signal
       ) do
    close_active_run(state, :failed, signal, nil)
  end

  defp maybe_finalize_mode_run(
         %State{} = state,
         %Jido.Signal{
           type: "conversation.llm.completed"
         } = signal
       ) do
    if state.pending_tool_calls == [] and state.pending_steps == [] do
      close_active_run(state, :completed, signal, nil)
    else
      state
    end
  end

  defp maybe_finalize_mode_run(state, _signal), do: state

  defp sync_active_run_step_count(%State{active_run: nil} = state), do: state

  defp sync_active_run_step_count(%State{} = state) do
    %{state | active_run: Map.put(state.active_run, :step_count, length(state.pending_steps))}
  end

  defp close_active_run(%State{active_run: nil} = state, _status, _signal, _reason), do: state

  defp close_active_run(%State{} = state, status, %Jido.Signal{} = signal, reason) do
    active_run = state.active_run

    if ModeRun.valid_transition?(active_run.status, status) do
      completed_run =
        active_run
        |> Map.put(:status, status)
        |> Map.put(:updated_at, signal.time)
        |> Map.put(:ended_at, signal.time)
        |> maybe_put(:reason, reason)
        |> Map.put(:step_count, length(state.pending_steps))

      %{
        state
        | active_run: nil,
          run_history: append_run_history(state, completed_run),
          pending_steps: []
      }
    else
      state
    end
  end

  defp append_run_history(%State{} = state, run_snapshot) when is_map(run_snapshot) do
    [run_snapshot | state.run_history]
    |> Enum.take(state.max_run_history)
  end

  defp new_mode_run(%State{} = state, %Jido.Signal{} = signal) do
    run_id = ConversationSignal.correlation_id(signal) || signal.id

    %{
      run_id: run_id,
      mode: state.mode,
      status: :running,
      started_at: signal.time,
      updated_at: signal.time,
      source_signal_id: signal.id,
      source_signal_type: signal.type,
      last_signal_id: signal.id,
      last_signal_type: signal.type,
      step_count: 0
    }
  end

  defp pending_step(active_run, tool_call, signal) do
    run_id = active_run.run_id
    name = map_get(tool_call, "name")

    correlation_id =
      map_get(tool_call, "correlation_id") || ConversationSignal.correlation_id(signal)

    %{
      step_id: "#{run_id}:#{name}:#{correlation_id || signal.id}",
      run_id: run_id,
      kind: :tool,
      status: :requested,
      name: name,
      correlation_id: correlation_id,
      created_at: signal.time,
      updated_at: signal.time,
      source_signal_id: signal.id
    }
  end

  defp do_drain(%State{} = state, intents, steps) when steps >= state.max_drain_steps do
    state =
      if state.queue_size > 0 do
        append_timeline(state, queue_overflow_signal(state, nil))
      else
        state
      end

    state = refresh_projection_cache(state)

    intents =
      if state.queue_size > 0 do
        intents ++ [%{kind: :continue_drain}]
      else
        intents
      end

    {state, intents}
  end

  defp do_drain(%State{} = state, intents, steps) do
    case :queue.out(state.event_queue) do
      {:empty, _queue} ->
        {refresh_projection_cache(state), intents}

      {{:value, signal}, queue} ->
        state = %{
          state
          | event_queue: queue,
            queue_size: max(state.queue_size - 1, 0)
        }

        {state, signal_intents} = apply_signal(state, signal)

        do_drain(state, intents ++ signal_intents, steps + 1)
    end
  end

  defp append_timeline(%State{} = state, %Jido.Signal{} = signal) do
    %{state | timeline: state.timeline ++ [signal]}
  end

  defp increment_drain_iteration(%State{} = state) do
    %{state | drain_iteration: state.drain_iteration + 1}
  end

  defp update_status(%State{} = state, %Jido.Signal{type: "conversation.cancel"}) do
    %{state | status: :cancelled}
  end

  defp update_status(%State{} = state, %Jido.Signal{type: "conversation.resume"}) do
    %{state | status: :idle}
  end

  defp update_status(%State{} = state, %Jido.Signal{type: type})
       when type in ["conversation.llm.completed", "conversation.llm.failed"] do
    if state.pending_tool_calls == [], do: %{state | status: :idle}, else: state
  end

  defp update_status(%State{} = state, %Jido.Signal{type: type})
       when type in @runtime_lifecycle_types do
    state
  end

  defp update_status(%State{} = state, _signal) do
    if state.status == :idle, do: %{state | status: :running}, else: state
  end

  defp update_pending_tools_on_requested(%State{} = state, signal) do
    case extract_tool_call(signal) do
      {:ok, tool_call} ->
        existing = state.pending_tool_calls

        if pending_tool_exists?(existing, tool_call) do
          state
        else
          %{state | pending_tool_calls: existing ++ [tool_call]}
        end

      :error ->
        state
    end
  end

  defp update_pending_tools_on_terminal(%State{} = state, signal) do
    name = extract_tool_name(signal)

    if is_binary(name) do
      pending =
        Enum.reject(state.pending_tool_calls, fn call -> map_get(call, "name") == name end)

      %{state | pending_tool_calls: pending}
    else
      state
    end
  end

  defp pending_tool_exists?(pending, tool_call) do
    candidate_name = map_get(tool_call, "name")
    candidate_correlation = map_get(tool_call, "correlation_id")

    Enum.any?(pending, fn existing ->
      map_get(existing, "name") == candidate_name and
        map_get(existing, "correlation_id") == candidate_correlation
    end)
  end

  defp extract_tool_call(%Jido.Signal{data: data} = signal) when is_map(data) do
    case tool_call_payload(data) do
      nil -> :error
      tool_call -> {:ok, decorate_tool_call(tool_call, signal)}
    end
  end

  defp extract_tool_call(_signal), do: :error

  defp tool_call_payload(%{"tool_call" => tool_call}) when is_map(tool_call), do: tool_call
  defp tool_call_payload(%{tool_call: tool_call}) when is_map(tool_call), do: tool_call

  defp tool_call_payload(%{"name" => name} = data) when is_binary(name) do
    %{
      "name" => name,
      "args" => data["args"] || %{},
      "meta" => data["meta"] || %{}
    }
  end

  defp tool_call_payload(%{name: name} = data) when is_binary(name) do
    %{
      "name" => name,
      "args" => data[:args] || %{},
      "meta" => data[:meta] || %{}
    }
  end

  defp tool_call_payload(_data), do: nil

  defp cancel_effect_intents(state, signal) do
    correlation_id = ConversationSignal.correlation_id(signal)

    intents = [
      %{
        kind: :cancel_pending_tools,
        pending_tool_calls: state.pending_tool_calls,
        correlation_id: correlation_id
      }
    ]

    pending_subagents = state.pending_subagents |> Map.values() |> List.wrap()

    if pending_subagents == [] do
      intents
    else
      intents ++
        [
          %{
            kind: :cancel_pending_subagents,
            pending_subagents: pending_subagents,
            correlation_id: correlation_id,
            reason: cancel_reason(signal)
          }
        ]
    end
  end

  defp mode_switch_effect_intents(previous_state, state, signal) do
    data = normalize_string_key_map(signal.data || %{})
    requested_mode = normalize_switch_mode(map_get(data, "mode"))
    force? = switch_force?(data)

    cond do
      is_nil(requested_mode) ->
        [
          emit_signal_intent(
            new_runtime_signal(
              state,
              signal,
              "conversation.mode.switch.rejected",
              %{
                "requested_mode" => map_get(data, "mode"),
                "reason" => "invalid_mode"
              }
            )
          )
        ]

      previous_state.active_run != nil and not force? ->
        [
          emit_signal_intent(
            new_runtime_signal(
              state,
              signal,
              "conversation.mode.switch.rejected",
              %{
                "requested_mode" => mode_label(requested_mode),
                "reason" => "active_run_conflict"
              }
            )
          )
        ]

      true ->
        accepted =
          emit_signal_intent(
            new_runtime_signal(
              state,
              signal,
              "conversation.mode.switch.accepted",
              %{
                "from_mode" => mode_label(previous_state.mode),
                "to_mode" => mode_label(state.mode),
                "force" => force?,
                "reason" => map_get(data, "reason"),
                "mode_state_policy" => "reset_unless_explicit"
              }
            )
          )

        additional_intents =
          if force? and previous_state.active_run != nil do
            cancel_effect_intents(state, signal)
          else
            []
          end

        [accepted | additional_intents]
    end
  end

  defp mode_run_lifecycle_intents(previous_state, state, signal) do
    maybe_run_opened_intents(previous_state, state, signal) ++
      maybe_run_resumed_intents(previous_state, state, signal) ++
      maybe_run_closed_intents(previous_state, state, signal)
  end

  defp maybe_run_opened_intents(
         %State{active_run: nil},
         %State{active_run: active_run} = state,
         signal
       )
       when is_map(active_run) do
    [
      emit_signal_intent(
        new_runtime_signal(
          state,
          signal,
          "conversation.run.opened",
          %{
            "run_id" => map_get(active_run, "run_id"),
            "mode" => mode_label(map_get(active_run, "mode")),
            "source_signal_id" => map_get(active_run, "source_signal_id")
          }
        )
      )
    ]
  end

  defp maybe_run_opened_intents(_previous_state, _state, _signal), do: []

  defp maybe_run_resumed_intents(
         %State{status: :cancelled},
         %State{status: :idle} = state,
         %Jido.Signal{type: "conversation.resume"} = signal
       ) do
    [
      emit_signal_intent(
        new_runtime_signal(
          state,
          signal,
          "conversation.run.resumed",
          %{
            "mode" => mode_label(state.mode)
          }
        )
      )
    ]
  end

  defp maybe_run_resumed_intents(_previous_state, _state, _signal), do: []

  defp maybe_run_closed_intents(previous_state, %State{} = state, signal) do
    if length(state.run_history) > length(previous_state.run_history) do
      run = List.first(state.run_history) || %{}
      status = map_get(run, "status")

      closed =
        emit_signal_intent(
          new_runtime_signal(
            state,
            signal,
            "conversation.run.closed",
            %{
              "run_id" => map_get(run, "run_id"),
              "mode" => mode_label(map_get(run, "mode")),
              "status" => status_label(status),
              "reason" => map_get(run, "reason")
            }
          )
        )

      if status == :interrupted do
        interrupted =
          emit_signal_intent(
            new_runtime_signal(
              state,
              signal,
              "conversation.run.interrupted",
              %{
                "run_id" => map_get(run, "run_id"),
                "mode" => mode_label(map_get(run, "mode")),
                "reason" => map_get(run, "reason")
              }
            )
          )

        [closed, interrupted]
      else
        [closed]
      end
    else
      []
    end
  end

  defp emit_signal_intent(%Jido.Signal{} = signal), do: %{kind: :emit_signal, signal: signal}

  defp new_runtime_signal(%State{} = state, source_signal, type, data) do
    correlation_id = source_signal |> ConversationSignal.correlation_id()

    Jido.Signal.new!(type, data,
      source: "/conversation/#{state.conversation_id}",
      extensions: if(correlation_id, do: %{"correlation_id" => correlation_id}, else: %{})
    )
  end

  defp maybe_run_llm_intent(%State{orchestration_enabled: true}, signal) do
    [%{kind: :run_execution, execution_kind: :strategy_run, source_signal: signal}]
  end

  defp maybe_run_llm_intent(_state, _signal), do: []

  defp tool_requested_intents(signal) do
    case extract_tool_call(signal) do
      {:ok, tool_call} ->
        [%{kind: :run_tool, source_signal: signal, tool_call: tool_call}]

      :error ->
        []
    end
  end

  defp maybe_run_llm_after_tool_intent(
         %State{orchestration_enabled: true, pending_tool_calls: []},
         signal
       ) do
    [%{kind: :run_execution, execution_kind: :strategy_run, source_signal: signal}]
  end

  defp maybe_run_llm_after_tool_intent(_state, _signal), do: []

  defp decorate_tool_call(tool_call, signal) do
    correlation_id = ConversationSignal.correlation_id(signal)

    tool_call
    |> normalize_string_key_map()
    |> Map.put_new("args", %{})
    |> Map.put_new("meta", %{})
    |> maybe_put("correlation_id", correlation_id)
  end

  defp extract_tool_name(%Jido.Signal{data: data}) when is_map(data) do
    cond do
      is_binary(data["name"]) -> data["name"]
      is_binary(data[:name]) -> data[:name]
      is_map(data["tool_call"]) -> map_get(data["tool_call"], "name")
      is_map(data[:tool_call]) -> map_get(data[:tool_call], "name")
      true -> nil
    end
  end

  defp extract_tool_name(_signal), do: nil

  defp cancel_reason(%Jido.Signal{data: data}) when is_map(data) do
    reason = map_get(data, "reason")
    if is_binary(reason) and String.trim(reason) != "", do: reason, else: "conversation_cancelled"
  end

  defp cancel_reason(_signal), do: "conversation_cancelled"

  defp put_pending_subagent(%State{} = state, %Jido.Signal{data: data}) when is_map(data) do
    child_id = map_get(data, "child_id")

    if is_binary(child_id) and child_id != "" do
      ref =
        data
        |> normalize_string_key_map()
        |> Map.put_new("status", "running")

      %{state | pending_subagents: Map.put(state.pending_subagents, child_id, ref)}
    else
      state
    end
  end

  defp put_pending_subagent(state, _signal), do: state

  defp pop_pending_subagent(%State{} = state, %Jido.Signal{data: data}) when is_map(data) do
    child_id = map_get(data, "child_id")

    if is_binary(child_id) and child_id != "" do
      %{state | pending_subagents: Map.delete(state.pending_subagents, child_id)}
    else
      state
    end
  end

  defp pop_pending_subagent(state, _signal), do: state

  defp put_correlation_index(%State{} = state, %Jido.Signal{} = signal) do
    case ConversationSignal.correlation_id(signal) do
      nil ->
        state

      correlation_id ->
        updated =
          Map.update(state.correlation_index, correlation_id, [signal.id], fn ids ->
            ids ++ [signal.id]
          end)

        %{state | correlation_index: updated}
    end
  end

  defp refresh_projection_cache(%State{} = state) do
    %{state | projection_cache: Projections.build(state)}
  end

  defp queue_overflow_signal(%State{} = state, dropped_signal) do
    payload = %{
      "reason" => "queue_overflow",
      "queue_size" => state.queue_size,
      "max_queue_size" => state.max_queue_size,
      "dropped_signal_id" => if(dropped_signal, do: dropped_signal.id, else: nil)
    }

    Jido.Signal.new!("conversation.queue.overflow", payload,
      source: "/project/#{state.project_id}/conversation/#{state.conversation_id}"
    )
  end

  defp mode_label(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp mode_label(mode) when is_binary(mode), do: mode
  defp mode_label(_mode), do: nil

  defp status_label(status) when is_atom(status), do: Atom.to_string(status)
  defp status_label(status) when is_binary(status), do: status
  defp status_label(_status), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_existing_atom(key))
  end

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp normalize_string_key_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)
      Map.put(acc, normalized_key, value)
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
