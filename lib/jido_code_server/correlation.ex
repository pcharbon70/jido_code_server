defmodule Jido.Code.Server.Correlation do
  @moduledoc """
  Correlation ID helpers for runtime event and telemetry propagation.
  """

  @spec ensure(map() | nil) :: {String.t(), map()}
  def ensure(meta) when is_map(meta) do
    case fetch(meta) do
      {:ok, correlation_id} ->
        {correlation_id, put(meta, correlation_id)}

      :error ->
        correlation_id = generate()
        {correlation_id, put(meta, correlation_id)}
    end
  end

  def ensure(_meta), do: ensure(%{})

  @spec fetch(map() | nil) :: {:ok, String.t()} | :error
  def fetch(meta) when is_map(meta) do
    value = Map.get(meta, :correlation_id) || Map.get(meta, "correlation_id")

    case value do
      id when is_binary(id) ->
        trimmed = String.trim(id)
        if trimmed == "", do: :error, else: {:ok, trimmed}

      _ ->
        :error
    end
  end

  def fetch(_meta), do: :error

  @spec put(map() | nil, String.t()) :: map()
  def put(meta, correlation_id) when is_binary(correlation_id) do
    base = if is_map(meta), do: meta, else: %{}
    Map.put(base, "correlation_id", String.trim(correlation_id))
  end

  @spec generate() :: String.t()
  def generate do
    token = Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
    "corr-" <> token
  end
end
