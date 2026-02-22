defmodule JidoCodeServer.Types.ToolSpec do
  @moduledoc """
  Tool specification type used for LLM and protocol exposure.
  """

  @enforce_keys [:name, :description, :input_schema]
  defstruct name: nil,
            description: nil,
            input_schema: %{},
            output_schema: %{},
            safety: %{}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          output_schema: map(),
          safety: map()
        }
end
