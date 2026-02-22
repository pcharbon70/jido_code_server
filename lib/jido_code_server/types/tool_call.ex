defmodule JidoCodeServer.Types.ToolCall do
  @moduledoc """
  Tool invocation payload type.
  """

  @enforce_keys [:name]
  defstruct name: nil, args: %{}, meta: %{}

  @type t :: %__MODULE__{
          name: String.t(),
          args: map(),
          meta: map()
        }
end
