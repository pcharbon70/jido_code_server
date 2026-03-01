defmodule Jido.Code.Server.Types.ToolCall do
  @moduledoc """
  Tool invocation payload type and normalization helpers.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            args: %{},
            meta: %{},
            call_type: nil,
            target_type: nil,
            target_name: nil

  @type t :: %__MODULE__{
          name: String.t(),
          args: map(),
          meta: map(),
          call_type: String.t() | nil,
          target_type: String.t() | nil,
          target_name: String.t() | nil
        }

  @spec from_map(map() | t()) :: {:ok, t()} | {:error, term()}
  def from_map(%__MODULE__{} = call), do: {:ok, call}

  def from_map(map) when is_map(map) do
    with {:ok, name} <- normalize_name(Map.get(map, :name) || Map.get(map, "name")),
         {:ok, args} <- normalize_payload_map(Map.get(map, :args) || Map.get(map, "args"), %{}),
         {:ok, meta} <- normalize_payload_map(Map.get(map, :meta) || Map.get(map, "meta"), %{}),
         {:ok, call_type} <-
           normalize_optional_name(Map.get(map, :call_type) || Map.get(map, "call_type")),
         {:ok, target_type} <-
           normalize_optional_name(Map.get(map, :target_type) || Map.get(map, "target_type")),
         {:ok, target_name} <-
           normalize_optional_name(Map.get(map, :target_name) || Map.get(map, "target_name")) do
      {:ok,
       %__MODULE__{
         name: name,
         args: args,
         meta: meta,
         call_type: call_type,
         target_type: target_type,
         target_name: target_name
       }}
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
    |> maybe_put("call_type", call.call_type)
    |> maybe_put("target_type", call.target_type)
    |> maybe_put("target_name", call.target_name)
  end

  defp normalize_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: {:error, :invalid_tool_name}, else: {:ok, trimmed}
  end

  defp normalize_name(_invalid), do: {:error, :invalid_tool_name}

  defp normalize_optional_name(nil), do: {:ok, nil}

  defp normalize_optional_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed == "", do: {:error, :invalid_tool_name}, else: {:ok, trimmed}
  end

  defp normalize_optional_name(_invalid), do: {:error, :invalid_tool_name}

  defp normalize_payload_map(nil, default), do: {:ok, default}
  defp normalize_payload_map(value, _default) when is_map(value), do: {:ok, value}
  defp normalize_payload_map(_invalid, _default), do: {:error, :invalid_tool_payload}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
