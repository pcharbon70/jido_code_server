defmodule Jido.Code.Server.Conversation.Signal do
  @moduledoc """
  Canonical signal normalization helpers for conversation runtime.
  """

  alias Jido.Code.Server.Correlation

  @default_source "/jido/code/server/conversation"
  @legacy_type_prefixes [
    "user.",
    "assistant.",
    "llm.",
    "tool.",
    "conversation.cancel",
    "conversation.resume",
    "conversation.queue.overflow",
    "conversation.subagent."
  ]

  @spec normalize(Jido.Signal.t() | map()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def normalize(%Jido.Signal{} = signal) do
    {:ok, ensure_correlation(signal)}
  end

  def normalize(raw) when is_map(raw) do
    with {:ok, type} <- extract_type(raw),
         {:ok, signal} <- build_signal(raw, type) do
      {:ok, ensure_correlation(signal)}
    end
  end

  def normalize(_raw), do: {:error, :invalid_signal}

  @spec normalize!(Jido.Signal.t() | map()) :: Jido.Signal.t()
  def normalize!(raw) do
    case normalize(raw) do
      {:ok, signal} -> signal
      {:error, reason} -> raise ArgumentError, "invalid conversation signal: #{inspect(reason)}"
    end
  end

  @spec to_map(Jido.Signal.t()) :: map()
  def to_map(%Jido.Signal{} = signal) do
    data = normalize_signal_data(signal.data)
    correlation_id = correlation_id(signal)

    base = %{
      "id" => signal.id,
      "type" => signal.type,
      "source" => signal.source,
      "time" => signal.time,
      "data" => data,
      "extensions" => signal.extensions
    }

    base
    |> maybe_put_content(data)
    |> maybe_put_meta(correlation_id)
  end

  @spec correlation_id(Jido.Signal.t()) :: String.t() | nil
  def correlation_id(%Jido.Signal{extensions: extensions}) when is_map(extensions) do
    case Correlation.fetch(extensions) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  def correlation_id(_signal), do: nil

  defp build_signal(raw, type) do
    source = extract_source(raw)
    data = extract_data(raw)

    attrs =
      [
        source: source,
        id: raw[:id] || raw["id"],
        time: raw[:time] || raw["time"],
        extensions: extract_extensions(raw)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Jido.Signal.new(type, data, attrs)
  end

  defp extract_type(raw) do
    type = raw[:type] || raw["type"]

    cond do
      not is_binary(type) ->
        {:error, :missing_type}

      String.trim(type) == "" ->
        {:error, :missing_type}

      true ->
        {:ok, normalize_type(type)}
    end
  end

  defp normalize_type(type) when is_binary(type) do
    type = String.trim(type)

    if String.starts_with?(type, "conversation.") do
      type
    else
      if Enum.any?(@legacy_type_prefixes, &String.starts_with?(type, &1)) do
        "conversation." <> type
      else
        type
      end
    end
  end

  defp extract_source(raw) do
    source = raw[:source] || raw["source"]

    case source do
      value when is_binary(value) and value != "" -> value
      _ -> @default_source
    end
  end

  defp extract_data(raw) do
    cond do
      is_map(raw[:data]) ->
        raw[:data]

      is_map(raw["data"]) ->
        raw["data"]

      true ->
        legacy_data_from_flat_map(raw)
    end
  end

  defp extract_extensions(raw) do
    ext = raw[:extensions] || raw["extensions"] || %{}
    meta = raw[:meta] || raw["meta"] || %{}

    %{}
    |> merge_if_map(ext)
    |> merge_if_map(meta)
  end

  defp merge_if_map(acc, value) when is_map(value), do: Map.merge(acc, value)
  defp merge_if_map(acc, _value), do: acc

  defp legacy_data_from_flat_map(raw) do
    ignored = [
      :id,
      "id",
      :type,
      "type",
      :source,
      "source",
      :time,
      "time",
      :meta,
      "meta",
      :extensions,
      "extensions",
      :data,
      "data",
      :specversion,
      "specversion"
    ]

    payload =
      raw
      |> Map.drop(ignored)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)
        Map.put(acc, normalized_key, value)
      end)

    if map_size(payload) == 0, do: %{}, else: payload
  end

  defp ensure_correlation(%Jido.Signal{extensions: extensions} = signal) do
    {correlation_id, meta} = Correlation.ensure(extensions)

    extensions =
      meta
      |> Map.put_new("correlation_id", correlation_id)

    %{signal | extensions: extensions}
  end

  defp normalize_signal_data(%{} = data), do: data
  defp normalize_signal_data(nil), do: %{}
  defp normalize_signal_data(other), do: %{"value" => other}

  defp maybe_put_content(map, %{"content" => content}) when is_binary(content) do
    Map.put(map, "content", content)
  end

  defp maybe_put_content(map, _data), do: map

  defp maybe_put_meta(map, nil), do: map

  defp maybe_put_meta(map, correlation_id) do
    Map.put(map, "meta", %{"correlation_id" => correlation_id})
  end
end
