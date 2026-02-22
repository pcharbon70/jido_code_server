defmodule Jido.Code.Server.Types.ToolCall do
  @moduledoc """
  Tool invocation payload type and normalization helpers.
  """

  @enforce_keys [:name]
  defstruct name: nil, args: %{}, meta: %{}

  @type t :: %__MODULE__{
          name: String.t(),
          args: map(),
          meta: map()
        }

  @spec from_map(map() | t()) :: {:ok, t()} | {:error, term()}
  def from_map(%__MODULE__{} = call), do: {:ok, call}

  def from_map(map) when is_map(map) do
    with {:ok, name} <- normalize_name(Map.get(map, :name) || Map.get(map, "name")),
         {:ok, args} <- normalize_payload_map(Map.get(map, :args) || Map.get(map, "args"), %{}),
         {:ok, meta} <- normalize_payload_map(Map.get(map, :meta) || Map.get(map, "meta"), %{}) do
      {:ok, %__MODULE__{name: name, args: args, meta: meta}}
    end
  end

  def from_map(_invalid), do: {:error, :invalid_tool_call}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = call) do
    %{
      name: call.name,
      args: call.args,
      meta: call.meta
    }
  end

  defp normalize_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: {:error, :invalid_tool_name}, else: {:ok, trimmed}
  end

  defp normalize_name(_invalid), do: {:error, :invalid_tool_name}

  defp normalize_payload_map(nil, default), do: {:ok, default}
  defp normalize_payload_map(value, _default) when is_map(value), do: {:ok, value}
  defp normalize_payload_map(_invalid, _default), do: {:error, :invalid_tool_payload}
end
