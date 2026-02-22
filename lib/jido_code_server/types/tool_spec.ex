defmodule Jido.Code.Server.Types.ToolSpec do
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

  @spec from_map(map() | t()) :: {:ok, t()} | {:error, term()}
  def from_map(%__MODULE__{} = spec), do: {:ok, spec}

  def from_map(map) when is_map(map) do
    with {:ok, name} <- normalize_required_string(map, :name),
         {:ok, description} <- normalize_required_string(map, :description),
         {:ok, input_schema} <- normalize_required_map(map, :input_schema),
         {:ok, output_schema} <- normalize_optional_map(map, :output_schema, %{}),
         {:ok, safety} <- normalize_optional_map(map, :safety, %{}) do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         input_schema: input_schema,
         output_schema: output_schema,
         safety: safety
       }}
    end
  end

  def from_map(_invalid), do: {:error, :invalid_tool_spec}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = spec) do
    %{
      name: spec.name,
      description: spec.description,
      input_schema: spec.input_schema,
      output_schema: spec.output_schema,
      safety: spec.safety
    }
  end

  defp normalize_required_string(map, key) do
    key_value = Map.get(map, key) || Map.get(map, Atom.to_string(key))

    case key_value do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: {:error, {:missing_field, key}}, else: {:ok, trimmed}

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp normalize_required_map(map, key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    if is_map(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}
  end

  defp normalize_optional_map(map, key, default) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))

    cond do
      is_nil(value) -> {:ok, default}
      is_map(value) -> {:ok, value}
      true -> {:error, {:invalid_field, key}}
    end
  end
end
