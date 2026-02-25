defmodule Jido.Code.Server.Project.SubAgentRef do
  @moduledoc """
  Runtime reference for active/terminal sub-agent instances.
  """

  @type status :: :starting | :running | :completed | :failed | :stopped

  @type t :: %__MODULE__{
          child_id: String.t(),
          template_id: String.t(),
          owner_conversation_id: String.t(),
          pid: pid(),
          started_at: DateTime.t(),
          status: status(),
          correlation_id: String.t() | nil
        }

  @enforce_keys [:child_id, :template_id, :owner_conversation_id, :pid, :started_at, :status]
  defstruct [
    :child_id,
    :template_id,
    :owner_conversation_id,
    :pid,
    :started_at,
    :status,
    :correlation_id
  ]
end
