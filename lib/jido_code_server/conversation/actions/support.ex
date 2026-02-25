defmodule Jido.Code.Server.Conversation.Actions.Support do
  @moduledoc false

  alias Jido.Agent.Directive
  alias Jido.Code.Server.Conversation.Domain.Reducer
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Conversation.Actions.HandleInstructionResultAction
  alias Jido.Code.Server.Conversation.Instructions.CancelPendingToolsInstruction
  alias Jido.Code.Server.Conversation.Instructions.CancelSubagentsInstruction
  alias Jido.Code.Server.Conversation.Instructions.RunLLMInstruction
  alias Jido.Code.Server.Conversation.Instructions.RunToolInstruction

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
    domain
    |> Reducer.enqueue_signal(signal)
    |> drain(state_map)
  end

  @spec ingest_many_and_drain(State.t(), [Jido.Signal.t()], map()) :: {State.t(), [Directive.t()]}
  def ingest_many_and_drain(%State{} = domain, signals, state_map) when is_list(signals) do
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

  defp intent_to_directive(%{kind: :run_llm, source_signal: source_signal}, domain, state_map) do
    params = %{
      "conversation_id" => domain.conversation_id,
      "source_signal" => ConversationSignal.to_map(source_signal),
      "llm_context" => domain.projection_cache[:llm_context] || %{}
    }

    [run_instruction(RunLLMInstruction, params, state_map, "llm")]
  end

  defp intent_to_directive(%{kind: :run_tool, tool_call: tool_call}, _domain, state_map) do
    params = %{"tool_call" => tool_call}
    [run_instruction(RunToolInstruction, params, state_map, "tool")]
  end

  defp intent_to_directive(
         %{kind: :cancel_pending_tools, pending_tool_calls: pending} = intent,
         _domain,
         state_map
       ) do
    correlation_id = Map.get(intent, :correlation_id)
    params = %{"pending_tool_calls" => pending, "correlation_id" => correlation_id}
    [run_instruction(CancelPendingToolsInstruction, params, state_map, "cancel_pending_tools")]
  end

  defp intent_to_directive(
         %{kind: :cancel_pending_subagents, pending_subagents: pending} = intent,
         _domain,
         state_map
       ) do
    params = %{
      "pending_subagents" => pending,
      "correlation_id" => Map.get(intent, :correlation_id),
      "reason" => Map.get(intent, :reason)
    }

    [run_instruction(CancelSubagentsInstruction, params, state_map, "cancel_pending_subagents")]
  end

  defp intent_to_directive(%{kind: :continue_drain}, domain, _state_map) do
    signal =
      Jido.Signal.new!("conversation.cmd.drain", %{},
        source: "/project/#{domain.project_id}/conversation/#{domain.conversation_id}"
      )

    [Directive.schedule(0, signal)]
  end

  defp intent_to_directive(_intent, _domain, _state_map), do: []

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
end
