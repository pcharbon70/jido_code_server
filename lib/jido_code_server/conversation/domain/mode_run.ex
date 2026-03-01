defmodule Jido.Code.Server.Conversation.Domain.ModeRun do
  @moduledoc """
  Shared mode-run lifecycle statuses and transition validation.
  """

  @statuses [:pending, :running, :interrupted, :completed, :failed, :cancelled]

  @terminal_statuses MapSet.new([:completed, :failed, :cancelled])

  @transition_matrix %{
    pending: MapSet.new([:running, :failed, :cancelled]),
    running: MapSet.new([:interrupted, :completed, :failed, :cancelled]),
    interrupted: MapSet.new([:running, :failed, :cancelled]),
    completed: MapSet.new(),
    failed: MapSet.new(),
    cancelled: MapSet.new()
  }

  @type status :: :pending | :running | :interrupted | :completed | :failed | :cancelled

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec terminal_status?(term()) :: boolean()
  def terminal_status?(status) when is_atom(status) do
    MapSet.member?(@terminal_statuses, status)
  end

  def terminal_status?(_status), do: false

  @spec valid_status?(term()) :: boolean()
  def valid_status?(status) when is_atom(status), do: status in @statuses
  def valid_status?(_status), do: false

  @spec valid_transition?(status() | nil, status()) :: boolean()
  def valid_transition?(nil, to_status), do: valid_status?(to_status)

  def valid_transition?(from_status, to_status)
      when is_atom(from_status) and is_atom(to_status) do
    from_status == to_status or
      @transition_matrix
      |> Map.get(from_status, MapSet.new())
      |> MapSet.member?(to_status)
  end

  def valid_transition?(_from_status, _to_status), do: false
end
