defmodule Jido.Code.Server.Conversation.Domain.State do
  @moduledoc """
  Canonical conversation domain state for signal-first runtime.
  """

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Conversation.Domain.Projections

  @type status :: :idle | :running | :cancelled
  @type mode :: :coding | :planning | :engineering | atom()

  @type t :: %__MODULE__{
          project_id: String.t(),
          conversation_id: String.t(),
          status: status(),
          mode: mode(),
          mode_state: map(),
          active_run: map() | nil,
          run_history: [map()],
          pending_steps: [map()],
          timeline: [Jido.Signal.t()],
          pending_tool_calls: [map()],
          pending_subagents: %{optional(String.t()) => map()},
          event_queue: term(),
          queue_size: non_neg_integer(),
          seen_signals: term(),
          projection_cache: map(),
          correlation_index: %{optional(String.t()) => [String.t()]},
          drain_iteration: non_neg_integer(),
          max_queue_size: pos_integer(),
          max_drain_steps: pos_integer(),
          max_run_history: pos_integer(),
          orchestration_enabled: boolean()
        }

  @enforce_keys [
    :project_id,
    :conversation_id,
    :max_queue_size,
    :max_drain_steps,
    :orchestration_enabled
  ]
  defstruct project_id: nil,
            conversation_id: nil,
            status: :idle,
            mode: :coding,
            mode_state: %{},
            active_run: nil,
            run_history: [],
            pending_steps: [],
            timeline: [],
            pending_tool_calls: [],
            pending_subagents: %{},
            event_queue: :queue.new(),
            queue_size: 0,
            seen_signals: MapSet.new(),
            projection_cache: %{},
            correlation_index: %{},
            drain_iteration: 0,
            max_queue_size: 10_000,
            max_drain_steps: 128,
            max_run_history: 25,
            orchestration_enabled: false

  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    state = %__MODULE__{
      project_id: Keyword.fetch!(opts, :project_id),
      conversation_id: Keyword.fetch!(opts, :conversation_id),
      mode: normalize_mode(Keyword.get(opts, :mode, :coding)),
      mode_state: normalize_mode_state(Keyword.get(opts, :mode_state, %{})),
      max_queue_size: Keyword.get(opts, :max_queue_size, Config.conversation_max_queue_size()),
      max_drain_steps: Keyword.get(opts, :max_drain_steps, Config.conversation_max_drain_steps()),
      max_run_history: normalize_max_run_history(Keyword.get(opts, :max_run_history, 25)),
      orchestration_enabled: Keyword.get(opts, :orchestration_enabled, false) == true
    }

    %{state | projection_cache: Projections.build(state)}
  end

  defp normalize_mode(mode) when is_atom(mode), do: mode
  defp normalize_mode(_mode), do: :coding

  defp normalize_mode_state(mode_state) when is_map(mode_state), do: mode_state
  defp normalize_mode_state(_mode_state), do: %{}

  defp normalize_max_run_history(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_max_run_history(_limit), do: 25
end
