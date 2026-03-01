defmodule Jido.Code.Server.Conversation.Actions.Support do
  @moduledoc false

  alias Jido.Agent.Directive
  alias Jido.Code.Server.Conversation.Actions.HandleInstructionResultAction
  alias Jido.Code.Server.Conversation.Domain.Reducer
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.ExecutionEnvelope
  alias Jido.Code.Server.Conversation.Instructions.CancelPendingToolsInstruction
  alias Jido.Code.Server.Conversation.Instructions.CancelSubagentsInstruction
  alias Jido.Code.Server.Conversation.Instructions.RunLLMInstruction
  alias Jido.Code.Server.Conversation.Instructions.RunToolInstruction
  alias Jido.Code.Server.Conversation.JournalBridge
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Telemetry

  @spec current_state(map()) :: {:ok, map()} | {:error, term()}
  def current_state(context) when is_map(context) do
    case Map.get(context, :state) || Map.get(context, "state") do
      state when is_map(state) -> {:ok, state}
      _ -> {:error, :missing_agent_state}
    end
  end

  @spec current_domain(map()) :: {:ok, State.t(), map()} | {:error, term()}
  def current_domain(context) when is_map(context) do
    with {:ok, state} <- current_state(context),
         %State{} = domain <- Map.get(state, :domain) || Map.get(state, "domain") do
      {:ok, domain, state}
    else
      _ -> {:error, :missing_domain_state}
    end
  end

  @spec ingest_and_drain(State.t(), Jido.Signal.t(), map()) :: {State.t(), [Directive.t()]}
  def ingest_and_drain(%State{} = domain, %Jido.Signal{} = signal, state_map) do
    persist_signal_to_journal(signal, state_map)

    domain
    |> Reducer.enqueue_signal(signal)
    |> drain(state_map)
  end

  @spec ingest_many_and_drain(State.t(), [Jido.Signal.t()], map()) :: {State.t(), [Directive.t()]}
  def ingest_many_and_drain(%State{} = domain, signals, state_map) when is_list(signals) do
    Enum.each(signals, &persist_signal_to_journal(&1, state_map))

    domain = Enum.reduce(signals, domain, &Reducer.enqueue_signal(&2, &1))
    drain(domain, state_map)
  end

  @spec drain(State.t(), map()) :: {State.t(), [Directive.t()]}
  def drain(%State{} = domain, state_map) do
    {domain, intents} = Reducer.drain_once(domain)

    directives =
      intents
      |> Enum.flat_map(&intent_to_directive(&1, domain, state_map))
      |> Enum.reject(&is_nil/1)

    {domain, directives}
  end

  defp intent_to_directive(
         %{kind: :emit_signal, signal: %Jido.Signal{} = signal},
         _domain,
         state_map
       ) do
    [Directive.schedule(0, ingest_signal(signal, state_map))]
  end

  defp intent_to_directive(%{kind: :continue_drain}, domain, _state_map) do
    signal =
      Jido.Signal.new!("conversation.cmd.drain", %{},
        source: "/project/#{domain.project_id}/conversation/#{domain.conversation_id}"
      )

    [Directive.schedule(0, signal)]
  end

  defp intent_to_directive(intent, domain, state_map) do
    case ExecutionEnvelope.from_intent(intent, mode: domain.mode, mode_state: domain.mode_state) do
      {:ok, envelope} ->
        envelope_to_directive(envelope, domain, state_map)

      {:error, _reason} ->
        []
    end
  end

  defp envelope_to_directive(%{execution_kind: :strategy_run} = envelope, domain, state_map) do
    source_signal =
      case Map.get(envelope, :source_signal) do
        %Jido.Signal{} = signal -> ConversationSignal.to_map(signal)
        _other -> %{}
      end

    params = %{
      "conversation_id" => domain.conversation_id,
      "source_signal" => source_signal,
      "llm_context" => domain.projection_cache[:llm_context] || %{},
      "mode" => domain.mode,
      "mode_state" => domain.mode_state,
      "execution_envelope" => envelope_meta(envelope)
    }

    [run_instruction(RunLLMInstruction, params, state_map, "llm")]
  end

  defp envelope_to_directive(
         %{execution_kind: execution_kind, tool_call: tool_call} = envelope,
         _domain,
         state_map
       )
       when execution_kind in [:tool_run, :command_run, :workflow_run, :subagent_spawn] do
    params = %{
      "tool_call" => tool_call,
      "mode" => map_get(envelope, :meta) |> map_get("mode"),
      "enforce_tool_exposure" => llm_origin_tool_request?(envelope),
      "execution_envelope" => envelope_meta(envelope)
    }

    [run_instruction(RunToolInstruction, params, state_map, "tool")]
  end

  defp envelope_to_directive(%{execution_kind: :cancel_tools} = envelope, _domain, state_map) do
    params = %{
      "pending_tool_calls" => map_get(envelope, :pending_tool_calls) || [],
      "correlation_id" => map_get(envelope, :correlation_id)
    }

    [run_instruction(CancelPendingToolsInstruction, params, state_map, "cancel_pending_tools")]
  end

  defp envelope_to_directive(%{execution_kind: :cancel_subagents} = envelope, _domain, state_map) do
    params = %{
      "pending_subagents" => map_get(envelope, :pending_subagents) || [],
      "correlation_id" => map_get(envelope, :correlation_id),
      "reason" => map_get(envelope, :args) |> map_get("reason")
    }

    [run_instruction(CancelSubagentsInstruction, params, state_map, "cancel_pending_subagents")]
  end

  defp envelope_to_directive(_envelope, _domain, _state_map), do: []

  defp ingest_signal(%Jido.Signal{} = signal, state_map) do
    project_id = map_get(state_map, "project_id")
    conversation_id = map_get(state_map, "conversation_id")

    Jido.Signal.new!(
      "conversation.cmd.ingest",
      %{"signal" => ConversationSignal.to_map(signal)},
      source: "/project/#{project_id}/conversation/#{conversation_id}"
    )
  end

  defp envelope_meta(envelope) when is_map(envelope) do
    envelope
    |> Map.take([:execution_kind, :name, :correlation_id, :cause_id, :meta])
    |> Enum.into(%{}, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp llm_origin_tool_request?(%{source_signal: %Jido.Signal{} = signal}) do
    signal.type == "conversation.tool.requested" and
      is_binary(signal.source) and
      String.starts_with?(signal.source, "/conversation/")
  end

  defp llm_origin_tool_request?(_envelope), do: false

  defp persist_signal_to_journal(%Jido.Signal{} = signal, state_map) do
    project_id = map_get(state_map, "project_id")
    conversation_id = map_get(state_map, "conversation_id")

    with true <- is_binary(project_id) and project_id != "",
         true <- is_binary(conversation_id) and conversation_id != "",
         :ok <- JournalBridge.ingest(project_id, conversation_id, signal) do
      :ok
    else
      {:error, reason} ->
        emit_journal_bridge_failed(project_id, conversation_id, signal, reason)
        :error

      _ ->
        :ok
    end
  end

  defp persist_signal_to_journal(_signal, _state_map), do: :ok

  defp emit_journal_bridge_failed(project_id, conversation_id, signal, reason) do
    Telemetry.emit("conversation.journal_bridge.failed", %{
      project_id: project_id,
      conversation_id: conversation_id,
      event_type: signal.type,
      reason: inspect(reason)
    })
  end

  defp run_instruction(action_module, params, state_map, effect_kind) do
    instruction =
      Jido.Instruction.new!(%{
        action: action_module,
        params: params,
        context: %{
          project_ctx:
            Map.get(state_map, :project_ctx) || Map.get(state_map, "project_ctx") || %{},
          project_id: Map.get(state_map, :project_id),
          conversation_id: Map.get(state_map, :conversation_id)
        }
      })

    Directive.run_instruction(instruction,
      result_action: HandleInstructionResultAction,
      meta: %{"effect_kind" => effect_kind}
    )
  end

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
