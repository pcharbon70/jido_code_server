defmodule Jido.Code.Server.Conversation.Signal do
  @moduledoc """
  Canonical signal normalization helpers for conversation runtime.
  """

  alias Jido.Code.Server.Correlation

  @default_source "/jido/code/server/conversation"
  @signal_envelope_keys MapSet.new([
                          "id",
                          "type",
                          "source",
                          "time",
                          "meta",
                          "extensions",
                          "data",
                          "specversion"
                        ])
  @canonical_types [
    "conversation.assistant.delta",
    "conversation.assistant.message",
    "conversation.cancel",
    "conversation.cmd.cancel",
    "conversation.cmd.drain",
    "conversation.cmd.ingest",
    "conversation.cmd.instruction.result",
    "conversation.llm.completed",
    "conversation.llm.failed",
    "conversation.llm.requested",
    "conversation.queue.overflow",
    "conversation.resume",
    "conversation.subagent.completed",
    "conversation.subagent.failed",
    "conversation.subagent.requested",
    "conversation.subagent.started",
    "conversation.subagent.stopped",
    "conversation.tool.cancelled",
    "conversation.tool.completed",
    "conversation.tool.failed",
    "conversation.tool.requested",
    "conversation.user.message"
  ]
  @canonical_type_set MapSet.new(@canonical_types)

  @spec normalize(Jido.Signal.t() | map()) :: {:ok, Jido.Signal.t()} | {:error, term()}
  def normalize(%Jido.Signal{type: type} = signal) when is_binary(type) do
    if canonical_type?(type) do
      with {:ok, data} <- normalize_signal_data_input(signal.data) do
        {:ok, ensure_correlation(%{signal | data: data})}
      end
    else
      {:error, {:invalid_type, String.trim(type)}}
    end
  end

  def normalize(%Jido.Signal{}), do: {:error, :missing_type}

  def normalize(%{type: type} = raw) when is_binary(type) do
    with {:ok, type} <- extract_type(raw),
         {:ok, signal} <- build_signal(raw, type) do
      {:ok, ensure_correlation(signal)}
    end
  end

  def normalize(%{"type" => type} = raw) when is_binary(type) do
    with {:ok, type} <- extract_type(raw),
         {:ok, signal} <- build_signal(raw, type) do
      {:ok, ensure_correlation(signal)}
    end
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

    maybe_put_meta(base, correlation_id)
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
    with {:ok, data} <- extract_data(raw) do
      source = extract_source(raw)

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
  end

  defp extract_type(raw) do
    type = raw[:type] || raw["type"]

    cond do
      not is_binary(type) ->
        {:error, :missing_type}

      String.trim(type) == "" ->
        {:error, :missing_type}

      true ->
        normalized = String.trim(type)

        if canonical_type?(normalized) do
          {:ok, normalized}
        else
          {:error, {:invalid_type, normalized}}
        end
    end
  end

  defp canonical_type?(type) when is_binary(type) do
    MapSet.member?(@canonical_type_set, type)
  end

  defp extract_source(raw) do
    source = raw[:source] || raw["source"]

    case source do
      value when is_binary(value) and value != "" -> value
      _ -> @default_source
    end
  end

  defp extract_data(raw) do
    data = raw[:data] || raw["data"]

    cond do
      is_map(data) ->
        {:ok, data}

      data_key_present?(raw) and not is_nil(data) ->
        {:error, :invalid_data}

      has_flat_payload_fields?(raw) ->
        {:error, :missing_data_envelope}

      true ->
        {:ok, %{}}
    end
  end

  defp data_key_present?(raw) when is_map(raw) do
    Map.has_key?(raw, :data) or Map.has_key?(raw, "data")
  end

  defp has_flat_payload_fields?(raw) when is_map(raw) do
    Enum.any?(raw, fn {key, _value} -> not envelope_key?(key) end)
  end

  defp envelope_key?(key) when is_atom(key), do: envelope_key?(Atom.to_string(key))
  defp envelope_key?(key) when is_binary(key), do: MapSet.member?(@signal_envelope_keys, key)
  defp envelope_key?(_key), do: false

  defp extract_extensions(raw) do
    ext = raw[:extensions] || raw["extensions"] || %{}
    meta = raw[:meta] || raw["meta"] || %{}

    %{}
    |> merge_if_map(ext)
    |> merge_if_map(meta)
  end

  defp merge_if_map(acc, value) when is_map(value), do: Map.merge(acc, value)
  defp merge_if_map(acc, _value), do: acc

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

  defp normalize_signal_data_input(%{} = data), do: {:ok, data}
  defp normalize_signal_data_input(nil), do: {:ok, %{}}
  defp normalize_signal_data_input(_other), do: {:error, :invalid_data}

  defp maybe_put_meta(map, nil), do: map

  defp maybe_put_meta(map, correlation_id) do
    Map.put(map, "meta", %{"correlation_id" => correlation_id})
  end
end
