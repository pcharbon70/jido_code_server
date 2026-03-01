defmodule Jido.Code.Server.Project.StrategyRunner.Normalizer do
  @moduledoc false

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Types.ToolCall

  @terminal_types MapSet.new(["conversation.llm.completed", "conversation.llm.failed"])
  @cancelled_finish_reasons MapSet.new(["cancelled", "canceled"])

  @spec normalize_success(map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_success(envelope, result) when is_map(envelope) and is_map(result) do
    payload = normalize_string_key_map(result)

    with {:ok, signals} <- normalize_signals(payload, envelope, :success) do
      {:ok,
       %{
         "signals" => Enum.map(signals, &ConversationSignal.to_map/1),
         "result_meta" => normalize_result_meta(payload, envelope, signals, :success),
         "execution_ref" => normalize_execution_ref(payload, envelope)
       }}
    end
  end

  @spec normalize_error(map(), term()) :: {:ok, map()} | {:error, term()}
  def normalize_error(envelope, reason) when is_map(envelope) do
    payload = normalize_error_payload(reason)
    retryable = retryable_error?(reason)

    with {:ok, signals} <- normalize_signals(payload, envelope, :error) do
      {:ok,
       %{
         "signals" => Enum.map(signals, &ConversationSignal.to_map/1),
         "result_meta" =>
           normalize_result_meta(payload, envelope, signals, :error)
           |> Map.put_new("retryable", retryable),
         "execution_ref" => normalize_execution_ref(payload, envelope),
         "reason" => normalize_reason(reason),
         "retryable" => retryable
       }}
    end
  end

  defp normalize_signals(payload, envelope, status) do
    explicit_signals =
      payload
      |> extract_raw_signals()
      |> normalize_explicit_signals()

    signals =
      if explicit_signals == [] do
        synthesize_signals(payload, envelope)
      else
        explicit_signals
      end
      |> ensure_requested_signal(envelope)
      |> ensure_terminal_signal(payload, envelope, status)
      |> Enum.map(&enrich_signal(&1, envelope, payload))

    {:ok, signals}
  end

  defp extract_raw_signals(payload) when is_map(payload) do
    map_get(payload, "signals") || map_get(payload, "events") || []
  end

  defp extract_raw_signals(_payload), do: []

  defp normalize_explicit_signals(signals) when is_list(signals) do
    signals
    |> Enum.flat_map(fn signal ->
      case ConversationSignal.normalize(signal) do
        {:ok, %Jido.Signal{type: "conversation.llm.started"}} ->
          []

        {:ok, normalized} ->
          [normalized]

        {:error, _reason} ->
          []
      end
    end)
  end

  defp normalize_explicit_signals(_signals), do: []

  defp synthesize_signals(payload, envelope) do
    delta_signals =
      payload
      |> map_get("delta_chunks")
      |> normalize_delta_chunks()
      |> Enum.map(fn chunk ->
        new_signal("conversation.assistant.delta", %{"content" => chunk}, envelope)
      end)

    tool_calls =
      payload
      |> map_get("tool_calls")
      |> normalize_tool_calls(map_get(envelope, :correlation_id))

    tool_signals =
      Enum.map(tool_calls, fn tool_call ->
        new_signal("conversation.tool.requested", %{"tool_call" => tool_call}, envelope)
      end)

    assistant_signals =
      case normalize_text(map_get(payload, "text")) do
        text when is_binary(text) and tool_signals == [] ->
          [new_signal("conversation.assistant.message", %{"content" => text}, envelope)]

        _other ->
          []
      end

    delta_signals ++ tool_signals ++ assistant_signals
  end

  defp ensure_requested_signal(signals, envelope) do
    if Enum.any?(signals, &(&1.type == "conversation.llm.requested")) do
      signals
    else
      [requested_signal(envelope) | signals]
    end
  end

  defp ensure_terminal_signal(signals, payload, envelope, status) do
    if Enum.any?(signals, &MapSet.member?(@terminal_types, &1.type)) do
      signals
    else
      signals ++ [terminal_signal(payload, envelope, status)]
    end
  end

  defp requested_signal(envelope) do
    source_signal_id =
      case map_get(envelope, :source_signal) do
        %Jido.Signal{id: signal_id} -> signal_id
        _other -> map_get(envelope, :cause_id)
      end

    new_signal(
      "conversation.llm.requested",
      %{
        "source_signal_id" => source_signal_id,
        "strategy_type" => map_get(envelope, :strategy_type),
        "cause_id" => map_get(envelope, :cause_id)
      },
      envelope
    )
  end

  defp terminal_signal(payload, envelope, status) do
    reason = failure_reason(payload, status)

    if is_binary(reason) do
      new_signal(
        "conversation.llm.failed",
        %{
          "reason" => reason,
          "retryable" => retryable_error?(payload),
          "strategy_type" => map_get(envelope, :strategy_type),
          "strategy_runner" => runner_name(map_get(envelope, :strategy_runner))
        },
        envelope
      )
    else
      new_signal(
        "conversation.llm.completed",
        %{
          "finish_reason" => finish_reason(payload),
          "provider" => provider(payload),
          "model" => model(payload, envelope),
          "tool_call_count" => tool_call_count(payload),
          "strategy_type" => map_get(envelope, :strategy_type),
          "strategy_runner" => runner_name(map_get(envelope, :strategy_runner))
        },
        envelope
      )
    end
  end

  defp enrich_signal(%Jido.Signal{} = signal, envelope, payload) do
    source = normalize_signal_source(signal.source, map_get(envelope, :conversation_id))
    extensions = enrich_extensions(signal.extensions, envelope)

    data =
      signal.data
      |> normalize_map()
      |> enrich_terminal_data(signal.type, payload, envelope)

    normalized =
      %Jido.Signal{
        signal
        | source: source,
          extensions: extensions,
          data: data
      }

    case ConversationSignal.normalize(normalized) do
      {:ok, normalized_signal} -> normalized_signal
      {:error, _reason} -> signal
    end
  end

  defp enrich_extensions(extensions, envelope) do
    extensions = normalize_map(extensions)

    extensions =
      case Correlation.fetch(extensions) do
        {:ok, _id} ->
          extensions

        :error ->
          case map_get(envelope, :correlation_id) do
            correlation_id when is_binary(correlation_id) and correlation_id != "" ->
              Correlation.put(extensions, correlation_id)

            _other ->
              {_correlation_id, ensured} = Correlation.ensure(extensions)
              ensured
          end
      end

    case map_get(envelope, :cause_id) do
      cause_id when is_binary(cause_id) and cause_id != "" ->
        Map.put_new(extensions, "cause_id", cause_id)

      _other ->
        extensions
    end
  end

  defp enrich_terminal_data(data, "conversation.llm.completed", payload, envelope) do
    data
    |> Map.put_new("finish_reason", finish_reason(payload))
    |> Map.put_new("provider", provider(payload))
    |> Map.put_new("model", model(payload, envelope))
    |> Map.put_new("strategy_type", map_get(envelope, :strategy_type))
    |> Map.put_new("strategy_runner", runner_name(map_get(envelope, :strategy_runner)))
  end

  defp enrich_terminal_data(data, "conversation.llm.failed", payload, envelope) do
    reason = failure_reason(payload, :error) || "strategy_failed"

    data
    |> Map.put_new("reason", reason)
    |> Map.put_new("retryable", retryable_error?(payload))
    |> Map.put_new("strategy_type", map_get(envelope, :strategy_type))
    |> Map.put_new("strategy_runner", runner_name(map_get(envelope, :strategy_runner)))
  end

  defp enrich_terminal_data(data, _type, _payload, _envelope), do: data

  defp normalize_result_meta(payload, envelope, signals, status) do
    terminal_status = terminal_status(signals, status)
    retryable = terminal_retryable(signals) || retryable_error?(payload)

    normalize_map(map_get(payload, "result_meta"))
    |> Map.put_new("execution_kind", "strategy_run")
    |> Map.put_new("strategy_type", map_get(envelope, :strategy_type))
    |> Map.put_new("mode", mode_label(map_get(envelope, :mode)))
    |> Map.put_new("strategy_runner", runner_name(map_get(envelope, :strategy_runner)))
    |> Map.put_new("provider", provider(payload))
    |> Map.put_new("model", model(payload, envelope))
    |> Map.put_new("signal_count", length(signals))
    |> Map.put_new("terminal_status", terminal_status)
    |> maybe_put_retryable(terminal_status, retryable)
  end

  defp maybe_put_retryable(result_meta, terminal_status, retryable)
       when terminal_status in ["failed", "cancelled"] do
    Map.put_new(result_meta, "retryable", retryable)
  end

  defp maybe_put_retryable(result_meta, _terminal_status, _retryable), do: result_meta

  defp terminal_status(signals, fallback_status) when is_list(signals) do
    case Enum.find(signals, &MapSet.member?(@terminal_types, &1.type)) do
      %Jido.Signal{type: "conversation.llm.completed"} ->
        "completed"

      %Jido.Signal{type: "conversation.llm.failed", data: data} ->
        reason = normalize_reason(map_get(normalize_map(data), "reason"))
        if cancelled_reason?(reason), do: "cancelled", else: "failed"

      _other ->
        if(fallback_status == :error, do: "failed", else: "completed")
    end
  end

  defp terminal_retryable(signals) when is_list(signals) do
    signals
    |> Enum.find(&(&1.type == "conversation.llm.failed"))
    |> case do
      %Jido.Signal{data: data} -> map_get(normalize_map(data), "retryable") == true
      _other -> false
    end
  end

  defp normalize_execution_ref(payload, envelope) do
    case map_get(payload, "execution_ref") do
      ref when is_binary(ref) and ref != "" ->
        ref

      _other ->
        "strategy:#{map_get(envelope, :correlation_id) || map_get(envelope, :cause_id) || "unknown"}"
    end
  end

  defp normalize_error_payload(reason) when is_map(reason), do: normalize_string_key_map(reason)

  defp normalize_error_payload(reason) do
    %{"reason" => normalize_reason(reason)}
  end

  defp failure_reason(payload, :error) do
    normalize_reason(map_get(payload, "reason") || "strategy_failed")
  end

  defp failure_reason(payload, _status) do
    cond do
      cancelled_payload?(payload) ->
        "conversation_cancelled"

      is_binary(map_get(payload, "reason")) and String.trim(map_get(payload, "reason")) != "" ->
        String.trim(map_get(payload, "reason"))

      true ->
        nil
    end
  end

  defp cancelled_payload?(payload) do
    cancelled? = map_get(payload, "cancelled") == true
    reason = normalize_reason(map_get(payload, "reason"))
    finish_reason = finish_reason(payload)

    cancelled? or cancelled_reason?(reason) or
      MapSet.member?(@cancelled_finish_reasons, finish_reason)
  end

  defp cancelled_reason?(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> String.trim_leading(":")
    |> String.downcase() == "conversation_cancelled"
  end

  defp cancelled_reason?(_reason), do: false

  defp retryable_error?(reason) when is_map(reason) do
    map_get(reason, "retryable") == true or retryable_error?(map_get(reason, "reason"))
  end

  defp retryable_error?(reason) when is_binary(reason) do
    normalized =
      reason
      |> String.trim()
      |> String.downcase()

    normalized in ["timeout", "temporary_failure"]
  end

  defp retryable_error?(reason) when is_atom(reason), do: reason in [:timeout, :temporary_failure]
  defp retryable_error?(reason), do: match?({:task_exit, _}, reason)

  defp finish_reason(payload) do
    payload
    |> map_get("finish_reason")
    |> normalize_reason()
    |> case do
      value when is_binary(value) and value != "" ->
        String.downcase(value)

      _other ->
        if(tool_call_count(payload) > 0, do: "tool_calls", else: "stop")
    end
  end

  defp provider(payload) do
    payload
    |> map_get("provider")
    |> normalize_reason()
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> "unknown"
    end
  end

  defp model(payload, envelope) do
    from_payload =
      payload
      |> map_get("model")
      |> normalize_reason()

    from_meta =
      payload
      |> map_get("result_meta")
      |> normalize_map()
      |> map_get("model")
      |> normalize_reason()

    from_opts =
      envelope
      |> map_get(:strategy_opts)
      |> normalize_map()
      |> map_get("model")
      |> normalize_reason()

    cond do
      is_binary(from_payload) and from_payload != "" -> from_payload
      is_binary(from_meta) and from_meta != "" -> from_meta
      is_binary(from_opts) and from_opts != "" -> from_opts
      true -> "default"
    end
  end

  defp tool_call_count(payload) do
    payload
    |> map_get("tool_calls")
    |> List.wrap()
    |> length()
  end

  defp normalize_tool_calls(tool_calls, correlation_id) when is_list(tool_calls) do
    Enum.flat_map(tool_calls, fn raw_tool_call ->
      case normalize_tool_call(raw_tool_call, correlation_id) do
        {:ok, tool_call} -> [tool_call]
        {:error, _reason} -> []
      end
    end)
  end

  defp normalize_tool_calls(_tool_calls, _correlation_id), do: []

  defp normalize_tool_call(raw_tool_call, correlation_id) when is_map(raw_tool_call) do
    tool_call = normalize_string_key_map(raw_tool_call)
    function = normalize_map(map_get(tool_call, "function"))
    name = map_get(tool_call, "name") || map_get(function, "name")

    args =
      map_get(tool_call, "args") ||
        map_get(tool_call, "arguments") ||
        map_get(function, "arguments")

    meta =
      tool_call
      |> map_get("meta")
      |> normalize_map()
      |> maybe_put_correlation(correlation_id)

    request = %{
      "name" => name,
      "args" => decode_tool_call_args(args),
      "meta" => meta
    }

    with {:ok, normalized} <- ToolCall.from_map(request) do
      {:ok, ToolCall.to_map(normalized)}
    end
  end

  defp normalize_tool_call(_raw_tool_call, _correlation_id), do: {:error, :invalid_tool_call}

  defp decode_tool_call_args(args) when is_map(args), do: args

  defp decode_tool_call_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_tool_call_args(_args), do: %{}

  defp maybe_put_correlation(meta, correlation_id) when is_binary(correlation_id) do
    case Correlation.fetch(meta) do
      {:ok, _id} -> meta
      :error -> Correlation.put(meta, correlation_id)
    end
  end

  defp maybe_put_correlation(meta, _correlation_id), do: meta

  defp normalize_delta_chunks(chunks) when is_list(chunks) do
    chunks
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_delta_chunks(_chunks), do: []

  defp normalize_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_text(_text), do: nil

  defp normalize_signal_source(source, _conversation_id) when is_binary(source) and source != "",
    do: source

  defp normalize_signal_source(_source, conversation_id) when is_binary(conversation_id),
    do: "/conversation/#{conversation_id}"

  defp normalize_signal_source(_source, _conversation_id), do: "/conversation/unknown"

  defp new_signal(type, data, envelope) do
    attrs = [
      source: normalize_signal_source(nil, map_get(envelope, :conversation_id)),
      extensions:
        %{}
        |> maybe_put("correlation_id", map_get(envelope, :correlation_id))
        |> maybe_put("cause_id", map_get(envelope, :cause_id))
    ]

    Jido.Signal.new!(type, normalize_map(data), attrs)
  end

  defp runner_name(runner) when is_atom(runner) do
    runner
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp runner_name(runner) when is_binary(runner) and runner != "", do: runner
  defp runner_name(_runner), do: "unknown"

  defp mode_label(mode) when is_atom(mode), do: Atom.to_string(mode)
  defp mode_label(mode) when is_binary(mode), do: mode
  defp mode_label(_mode), do: "coding"

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp normalize_reason(reason) when is_map(reason) do
    map_get(reason, "reason") || inspect(reason)
  end

  defp normalize_reason(reason), do: inspect(reason)

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp normalize_string_key_map(%_{} = value), do: value

  defp normalize_string_key_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      normalized_key = if(is_atom(key), do: Atom.to_string(key), else: key)

      normalized_value =
        cond do
          is_map(nested) -> normalize_string_key_map(nested)
          is_list(nested) -> Enum.map(nested, &normalize_string_key_map/1)
          true -> nested
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp normalize_string_key_map(value) when is_list(value),
    do: Enum.map(value, &normalize_string_key_map/1)

  defp normalize_string_key_map(value), do: value

  defp map_get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp map_get(_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
