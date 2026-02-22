defmodule Jido.Code.Server.Types.Event do
  @moduledoc """
  Canonical event envelope type and normalization helpers.
  """

  @enforce_keys [:type, :at]
  defstruct type: nil, at: nil, data: %{}, meta: %{}

  @type t :: %__MODULE__{
          type: String.t(),
          at: DateTime.t(),
          data: map(),
          meta: map()
        }

  @reserved_keys ["type", "at", "data", "meta", :type, :at, :data, :meta]

  @spec from_map(map() | t()) :: {:ok, t()} | {:error, term()}
  def from_map(%__MODULE__{} = event), do: {:ok, event}

  def from_map(map) when is_map(map) do
    with {:ok, type} <- normalize_type(Map.get(map, :type) || Map.get(map, "type")),
         {:ok, at} <- normalize_at(Map.get(map, :at) || Map.get(map, "at")),
         {:ok, data} <- normalize_data(map),
         {:ok, meta} <- normalize_meta(Map.get(map, :meta) || Map.get(map, "meta")) do
      {:ok, %__MODULE__{type: type, at: at, data: data, meta: meta}}
    end
  end

  def from_map(_invalid), do: {:error, :invalid_event}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      type: event.type,
      at: event.at,
      data: event.data,
      meta: event.meta
    }
  end

  defp normalize_type(type) when is_binary(type) do
    trimmed = String.trim(type)
    if trimmed == "", do: {:error, :invalid_event_type}, else: {:ok, trimmed}
  end

  defp normalize_type(_invalid), do: {:error, :invalid_event_type}

  defp normalize_at(nil), do: {:ok, DateTime.utc_now()}
  defp normalize_at(%DateTime{} = at), do: {:ok, at}

  defp normalize_at(%NaiveDateTime{} = at) do
    DateTime.from_naive(at, "Etc/UTC")
  end

  defp normalize_at(value) when is_integer(value) do
    case DateTime.from_unix(value, :millisecond) do
      {:ok, at} -> {:ok, at}
      _ -> DateTime.from_unix(value)
    end
  end

  defp normalize_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      _ -> {:error, :invalid_event_at}
    end
  end

  defp normalize_at(_invalid), do: {:error, :invalid_event_at}

  defp normalize_data(map) do
    case Map.get(map, :data) || Map.get(map, "data") do
      nil ->
        derived_data = Map.drop(map, @reserved_keys)
        {:ok, derived_data}

      value when is_map(value) ->
        {:ok, value}

      _invalid ->
        {:error, :invalid_event_data}
    end
  end

  defp normalize_meta(nil), do: {:ok, %{}}
  defp normalize_meta(meta) when is_map(meta), do: {:ok, meta}
  defp normalize_meta(_invalid), do: {:error, :invalid_event_meta}
end
