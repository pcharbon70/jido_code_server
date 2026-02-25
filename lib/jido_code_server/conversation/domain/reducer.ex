defmodule Jido.Code.Server.Conversation.Domain.Reducer do
  @moduledoc """
  Pure conversation domain reducer with deterministic queue semantics.
  """

  alias Jido.Code.Server.Conversation.Domain.Projections
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  @type effect_intent :: map()

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
      |> increment_drain_iteration()

    intents = derive_effect_intents(next_state, signal)
    {next_state, intents}
  end

  @spec derive_effect_intents(State.t(), Jido.Signal.t()) :: [effect_intent()]
  def derive_effect_intents(%State{} = state, %Jido.Signal{} = signal) do
    case signal.type do
      "conversation.cancel" ->
        cancel_effect_intents(state, signal)

      _other when state.status == :cancelled and signal.type != "conversation.resume" ->
        []

      "conversation.user.message" ->
        maybe_run_llm_intent(state, signal)

      "conversation.tool.requested" ->
        tool_requested_intents(signal)

      type when type in ["conversation.tool.completed", "conversation.tool.failed"] ->
        maybe_run_llm_after_tool_intent(state, signal)

      _other ->
        []
    end
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

  defp maybe_run_llm_intent(%State{orchestration_enabled: true}, signal) do
    [%{kind: :run_llm, source_signal: signal}]
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
    [%{kind: :run_llm, source_signal: signal}]
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
