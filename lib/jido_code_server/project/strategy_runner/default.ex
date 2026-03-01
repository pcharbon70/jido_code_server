defmodule Jido.Code.Server.Project.StrategyRunner.Default do
  @moduledoc """
  Default strategy adapter backed by `Conversation.LLM`.
  """

  @behaviour Jido.Code.Server.Project.StrategyRunner

  alias Jido.Code.Server.Conversation.LLM
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Project.Policy
  alias Jido.Code.Server.Project.ToolCatalog

  @impl true
  def start(project_ctx, envelope, _opts) when is_map(project_ctx) and is_map(envelope) do
    requested_signal =
      new_strategy_signal(
        "conversation.llm.requested",
        %{"source_signal_id" => envelope.source_signal.id},
        envelope.conversation_id,
        envelope.correlation_id
      )

    opts =
      [source_event: ConversationSignal.to_map(envelope.source_signal)]
      |> maybe_put_opt(
        :tool_specs,
        available_tool_specs(project_ctx, envelope.mode, envelope.mode_state)
      )
      |> maybe_put_opt(:model, map_get(envelope.strategy_opts, "model"))
      |> maybe_put_opt(:system_prompt, map_get(envelope.strategy_opts, "system_prompt"))
      |> maybe_put_opt(:temperature, map_get(envelope.strategy_opts, "temperature"))
      |> maybe_put_opt(:max_tokens, map_get(envelope.strategy_opts, "max_tokens"))
      |> maybe_put_opt(:timeout_ms, map_get(envelope.strategy_opts, "timeout_ms"))
      |> maybe_put_opt(:adapter, map_get(envelope.strategy_opts, "adapter"))

    case LLM.start_completion(project_ctx, envelope.conversation_id, envelope.llm_context, opts) do
      {:ok, %{events: events}} ->
        completion_signals =
          events
          |> List.wrap()
          |> Enum.flat_map(
            &event_to_strategy_signals(&1, envelope.conversation_id, envelope.correlation_id)
          )

        {:ok,
         %{
           "signals" =>
             Enum.map([requested_signal | completion_signals], &ConversationSignal.to_map/1),
           "result_meta" => %{
             "execution_kind" => "strategy_run",
             "strategy_type" => envelope.strategy_type,
             "mode" => Atom.to_string(envelope.mode),
             "signal_count" => length(completion_signals) + 1,
             "strategy_runner" => runner_name()
           },
           "execution_ref" => strategy_execution_ref(envelope)
         }}

      {:error, reason} ->
        failed_signal =
          new_strategy_signal(
            "conversation.llm.failed",
            %{"reason" => normalize_reason(reason)},
            envelope.conversation_id,
            envelope.correlation_id
          )

        {:error,
         %{
           "signals" => Enum.map([requested_signal, failed_signal], &ConversationSignal.to_map/1),
           "result_meta" => %{
             "execution_kind" => "strategy_run",
             "strategy_type" => envelope.strategy_type,
             "mode" => Atom.to_string(envelope.mode),
             "retryable" => retryable_execution_error?(reason),
             "strategy_runner" => runner_name()
           },
           "execution_ref" => strategy_execution_ref(envelope),
           "reason" => normalize_reason(reason),
           "retryable" => retryable_execution_error?(reason)
         }}
    end
  end

  @impl true
  def capabilities do
    %{
      streaming?: false,
      tool_calling?: true,
      cancellable?: true,
      supported_strategies: [
        :code_generation,
        :reasoning,
        :tool_loop,
        :planning,
        :engineering_design
      ]
    }
  end

  defp runner_name do
    __MODULE__
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp available_tool_specs(project_ctx, mode, mode_state) do
    tools = ToolCatalog.llm_tools(project_ctx, mode: mode, mode_state: mode_state)

    project_ctx
    |> filter_available_tools(tools)
    |> Enum.map(&tool_spec/1)
  rescue
    _error ->
      []
  catch
    :exit, _reason ->
      []
  end

  defp filter_available_tools(project_ctx, tools) when is_list(tools) do
    case Map.get(project_ctx, :policy) do
      nil -> tools
      policy -> Policy.filter_tools(policy, tools)
    end
  end

  defp tool_spec(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.input_schema
    }
  end

  defp event_to_strategy_signals(raw_event, conversation_id, fallback_correlation_id)
       when is_map(raw_event) do
    case ConversationSignal.normalize(raw_event) do
      {:ok, %Jido.Signal{type: "conversation.llm.started"}} ->
        []

      {:ok, normalized_event} ->
        correlation_id =
          ConversationSignal.correlation_id(normalized_event) || fallback_correlation_id

        [
          new_strategy_signal(
            normalized_event.type,
            normalized_event.data,
            conversation_id,
            correlation_id
          )
        ]

      {:error, _reason} ->
        []
    end
  end

  defp event_to_strategy_signals(_raw_event, _conversation_id, _fallback_correlation_id), do: []

  defp new_strategy_signal(type, data, conversation_id, correlation_id) do
    attrs =
      [
        source: "/conversation/#{conversation_id}",
        extensions: if(correlation_id, do: %{"correlation_id" => correlation_id}, else: %{})
      ]

    Jido.Signal.new!(type, normalize_map(data), attrs)
  end

  defp retryable_execution_error?(reason) do
    match?(%{"retryable" => true}, reason) or
      match?({:task_exit, _}, reason) or
      reason in [:timeout, :temporary_failure]
  end

  defp strategy_execution_ref(envelope) do
    base = envelope.correlation_id || envelope.cause_id || "unknown"
    "strategy:#{base}"
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, []), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_map), do: %{}

  defp map_get(map, key) when is_map(map) and is_binary(key),
    do: Map.get(map, key) || Map.get(map, to_existing_atom(key))

  defp map_get(_map, _key), do: nil

  defp to_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
