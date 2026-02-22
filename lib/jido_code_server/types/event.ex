defmodule JidoCodeServer.Types.Event do
  @moduledoc """
  Canonical event envelope type.
  """

  @enforce_keys [:type, :at]
  defstruct type: nil, at: nil, data: %{}, meta: %{}

  @type t :: %__MODULE__{
          type: String.t(),
          at: DateTime.t(),
          data: map(),
          meta: map()
        }
end
