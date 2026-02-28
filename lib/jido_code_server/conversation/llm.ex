defmodule Jido.Code.Server.Conversation.LLM do
  @moduledoc """
  Conversation-scoped LLM adapter with deterministic and Jido.AI-backed modes.
  """

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Types.ToolCall

  @type completion_result :: %{
          ref: reference(),
          events: [map()]
        }

  @spec start_completion(map(), String.t(), map(), keyword()) ::
          {:ok, completion_result()} | {:error, term()}
  def start_completion(project_ctx, conversation_id, llm_context, opts \\ []) do
    request = build_request(project_ctx, conversation_id, llm_context, opts)
    ref = make_ref()

    with {:ok, response} <- complete(request) do
      {:ok, %{ref: ref, events: response_to_events(request, response)}}
    end
  end

  @spec cancel(reference()) :: :ok
  def cancel(_ref), do: :ok

  defp build_request(project_ctx, conversation_id, llm_context, opts) do
    source_event = Keyword.get(opts, :source_event)

    %{
      project_id: Map.get(project_ctx, :project_id),
      conversation_id: conversation_id,
      llm_context: normalize_llm_context(llm_context),
      source_event: source_event,
      correlation_id: resolve_correlation_id(opts, source_event),
      tool_specs: normalize_tool_specs(Keyword.get(opts, :tool_specs, [])),
      adapter: resolve_adapter(project_ctx, opts),
      model: Keyword.get(opts, :model) || Map.get(project_ctx, :llm_model),
      system_prompt:
        Keyword.get(opts, :system_prompt) || Map.get(project_ctx, :llm_system_prompt),
      temperature: Keyword.get(opts, :temperature) || Map.get(project_ctx, :llm_temperature),
      max_tokens: Keyword.get(opts, :max_tokens) || Map.get(project_ctx, :llm_max_tokens),
      timeout_ms: Keyword.get(opts, :timeout_ms) || Map.get(project_ctx, :llm_timeout_ms)
    }
  end

  defp resolve_adapter(project_ctx, opts) do
    Keyword.get(opts, :adapter) ||
      Map.get(project_ctx, :llm_adapter) ||
      Application.get_env(:jido_code_server, :llm_adapter, :deterministic)
  end

  defp complete(%{adapter: :deterministic} = request), do: deterministic_complete(request)
  defp complete(%{adapter: :jido_ai} = request), do: jido_ai_complete(request)

  defp complete(%{adapter: adapter} = request) when is_atom(adapter) do
    if function_exported?(adapter, :complete, 1) do
      adapter.complete(request)
    else
      {:error, {:invalid_llm_adapter, adapter}}
    end
  end

  defp complete(%{adapter: adapter} = request) when is_function(adapter, 1) do
    case adapter.(request) do
      {:ok, _response} = ok -> ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_llm_adapter_response, other}}
    end
  rescue
    error -> {:error, {:llm_adapter_exception, error}}
  end

  defp complete(%{adapter: adapter}), do: {:error, {:invalid_llm_adapter, adapter}}

  defp deterministic_complete(request) do
    directive = extract_directive(request.source_event)
    tool_calls = deterministic_tool_calls(directive, request)
    text = deterministic_text(directive, request)
    delta_chunks = deterministic_delta_chunks(directive, text)

    {:ok, deterministic_response(tool_calls, text, delta_chunks)}
  end

  defp jido_ai_complete(request) do
    opts = build_jido_ai_opts(request)

    with {:ok, response} <- Jido.AI.generate_text(request.llm_context.messages, opts),
         classified <- ReqLLM.Response.classify(response) do
      tool_calls =
        classified.tool_calls
        |> normalize_tool_calls()
        |> Enum.take(1)

      finish_reason =
        classified.finish_reason || if(tool_calls == [], do: :stop, else: :tool_calls)

      text = classified.text

      {:ok,
       %{
         provider: :jido_ai,
         text: text,
         delta_chunks: if(String.trim(text) == "", do: [], else: [text]),
         tool_calls: tool_calls,
         finish_reason: finish_reason
       }}
    end
  rescue
    error -> {:error, {:llm_exception, error}}
  end

  defp build_jido_ai_opts(request) do
    []
    |> maybe_put_opt(:model, request.model)
    |> maybe_put_opt(:system_prompt, request.system_prompt)
    |> maybe_put_opt(:temperature, request.temperature)
    |> maybe_put_opt(:max_tokens, request.max_tokens)
    |> maybe_put_opt(:timeout, request.timeout_ms)
    |> maybe_put_opt(:tools, to_reqllm_tools(request.tool_specs))
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, []), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp to_reqllm_tools(tool_specs) do
    Enum.map(tool_specs, fn spec ->
      %{
        "type" => "function",
        "function" => %{
          "name" => spec.name,
          "description" => spec.description,
          "parameters" => spec.input_schema
        }
      }
    end)
  end

  defp response_to_events(request, response) do
    correlation_id = Map.get(request, :correlation_id)
    event_meta = build_event_meta(correlation_id)

    tool_calls = Enum.take(Map.get(response, :tool_calls, []), 1)
    text = Map.get(response, :text, "") || ""
    delta_chunks = normalize_delta_chunks(Map.get(response, :delta_chunks, []))

    delta_events =
      Enum.map(delta_chunks, fn chunk ->
        %{type: "conversation.assistant.delta", meta: event_meta, data: %{"content" => chunk}}
      end)

    tool_events =
      Enum.map(tool_calls, fn tool_call ->
        %{
          type: "conversation.tool.requested",
          meta: event_meta,
          data: %{"tool_call" => tool_call_with_correlation(tool_call, correlation_id)}
        }
      end)

    assistant_events =
      if tool_events == [] and String.trim(text) != "" do
        [%{type: "conversation.assistant.message", meta: event_meta, data: %{"content" => text}}]
      else
        []
      end

    completed = %{
      type: "conversation.llm.completed",
      meta: event_meta,
      data: %{
        "finish_reason" => normalize_finish_reason(Map.get(response, :finish_reason)),
        "provider" => normalize_provider(Map.get(response, :provider)),
        "model" => request.model || "default",
        "tool_call_count" => length(tool_events)
      }
    }

    delta_events ++ tool_events ++ assistant_events ++ [completed]
  end

  defp normalize_llm_context(llm_context) when is_map(llm_context) do
    messages =
      llm_context
      |> Map.get(:messages, Map.get(llm_context, "messages", []))
      |> normalize_messages()

    Map.put(llm_context, :messages, messages)
  end

  defp normalize_llm_context(_), do: %{messages: []}

  defp normalize_messages(messages) when is_list(messages) do
    messages
    |> Enum.map(&normalize_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_messages(_), do: []

  defp normalize_message(%{} = message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")

    if is_binary(content) and String.trim(content) != "" do
      %{role: normalize_role(role), content: content}
    else
      nil
    end
  end

  defp normalize_message(_), do: nil

  defp normalize_role(:assistant), do: :assistant
  defp normalize_role("assistant"), do: :assistant
  defp normalize_role(:system), do: :system
  defp normalize_role("system"), do: :system
  defp normalize_role(:tool), do: :tool
  defp normalize_role("tool"), do: :tool
  defp normalize_role(_), do: :user

  defp normalize_tool_specs(tool_specs) when is_list(tool_specs) do
    tool_specs
    |> Enum.map(fn
      %{name: name, description: description, input_schema: schema}
      when is_binary(name) and is_binary(description) and is_map(schema) ->
        %{name: name, description: description, input_schema: schema}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tool_specs(_), do: []

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&normalize_tool_call/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_tool_calls(_), do: []

  defp normalize_tool_call(%{} = tool_call) do
    request = %{
      name: extract_tool_call_name(tool_call),
      args: extract_tool_call_args(tool_call),
      meta: %{}
    }

    case ToolCall.from_map(request) do
      {:ok, normalized} ->
        ToolCall.to_map(%{normalized | meta: tool_call_meta(tool_call)})

      {:error, _reason} ->
        nil
    end
  end

  defp normalize_tool_call(_), do: nil

  defp decode_args(args) when is_map(args), do: args

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_args(_), do: %{}

  defp extract_directive(source_event) when is_map(source_event) do
    data = map_lookup(source_event, :data) || %{}
    meta = map_lookup(source_event, :meta) || %{}
    extensions = map_lookup(source_event, :extensions) || %{}

    map_lookup(data, :llm) ||
      map_lookup(meta, :llm) ||
      map_lookup(extensions, :llm) ||
      map_lookup(source_event, :llm) ||
      %{}
  end

  defp extract_directive(_source_event), do: %{}

  defp directive_text(%{} = directive) do
    value = map_lookup(directive, :assistant_text) || map_lookup(directive, :text)
    if is_binary(value) and String.trim(value) != "", do: value, else: nil
  end

  defp directive_text(_), do: nil

  defp directive_delta_chunks(%{} = directive) do
    directive
    |> map_lookup(:delta_chunks)
    |> case do
      chunks when is_list(chunks) ->
        chunks
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(&(String.trim(&1) == ""))

      _ ->
        []
    end
  end

  defp directive_delta_chunks(_), do: []

  defp directive_tool_calls(%{} = directive) do
    directive
    |> map_lookup(:tool_calls)
    |> normalize_tool_calls()
  end

  defp directive_tool_calls(_), do: []

  defp infer_tool_calls(request) do
    prompt = latest_user_content(request.llm_context)
    available_names = Enum.map(request.tool_specs, & &1.name)

    cond do
      String.contains?(String.downcase(prompt), "list skills") and
          Enum.member?(available_names, "asset.list") ->
        [%{name: "asset.list", args: %{"type" => "skill"}, meta: %{}}]

      String.contains?(String.downcase(prompt), "list workflows") and
          Enum.member?(available_names, "asset.list") ->
        [%{name: "asset.list", args: %{"type" => "workflow"}, meta: %{}}]

      true ->
        []
    end
  end

  defp latest_user_content(llm_context) do
    llm_context
    |> Map.get(:messages, [])
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :user, content: content} when is_binary(content) -> content
      _ -> nil
    end)
  end

  defp summary_from_source_event(source_event) when is_map(source_event) do
    type = source_event_type(source_event)
    data = map_lookup(source_event, :data) || %{}

    cond do
      type == "conversation.tool.completed" ->
        name = map_lookup(data, :name) || "unknown"
        "Tool #{name} completed."

      type == "conversation.tool.failed" ->
        name = map_lookup(data, :name) || "unknown"
        reason = map_lookup(data, :reason)

        if is_nil(reason) do
          "Tool #{name} failed."
        else
          "Tool #{name} failed: #{inspect(reason)}"
        end

      true ->
        nil
    end
  end

  defp summary_from_source_event(_source_event), do: nil

  defp default_assistant_text(request) do
    case String.trim(latest_user_content(request.llm_context)) do
      "" -> "Acknowledged."
      content -> "Acknowledged: #{content}"
    end
  end

  defp deterministic_tool_calls(directive, request) do
    directive
    |> directive_tool_calls()
    |> case do
      [] -> infer_tool_calls_for_source(request)
      calls -> calls
    end
    |> Enum.take(1)
  end

  defp infer_tool_calls_for_source(%{source_event: source_event} = request) do
    if source_event_type(source_event) == "conversation.user.message" do
      infer_tool_calls(request)
    else
      []
    end
  end

  defp deterministic_text(directive, request) do
    directive_text(directive) ||
      summary_from_source_event(request.source_event) ||
      default_assistant_text(request)
  end

  defp deterministic_delta_chunks(directive, text) do
    case directive_delta_chunks(directive) do
      [] ->
        if is_binary(text) and String.trim(text) != "", do: [text], else: []

      chunks ->
        chunks
    end
  end

  defp deterministic_response(tool_calls, text, delta_chunks) do
    %{
      provider: :deterministic,
      text: text || "",
      delta_chunks: delta_chunks,
      tool_calls: tool_calls,
      finish_reason: if(tool_calls == [], do: :stop, else: :tool_calls)
    }
  end

  defp normalize_delta_chunks(chunks) when is_list(chunks) do
    chunks
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp normalize_delta_chunks(_), do: []

  defp normalize_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider(provider) when is_binary(provider), do: provider
  defp normalize_provider(_), do: "unknown"

  defp normalize_finish_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_finish_reason(reason) when is_binary(reason), do: reason
  defp normalize_finish_reason(_), do: "unknown"

  defp map_lookup(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_lookup(_map, _key), do: nil

  defp extract_tool_call_name(tool_call) do
    map_lookup(tool_call, :name) || nested_map_lookup(tool_call, [:function, :name])
  end

  defp extract_tool_call_args(tool_call) do
    tool_call
    |> tool_call_args_value()
    |> decode_args()
  end

  defp tool_call_args_value(tool_call) do
    map_lookup(tool_call, :arguments) ||
      map_lookup(tool_call, :args) ||
      nested_map_lookup(tool_call, [:function, :arguments]) ||
      %{}
  end

  defp tool_call_meta(tool_call) do
    case map_lookup(tool_call, :id) do
      id when is_binary(id) and id != "" -> %{"llm_tool_call_id" => id}
      _ -> %{}
    end
  end

  defp resolve_correlation_id(opts, source_event) do
    with nil <- Keyword.get(opts, :correlation_id),
         nil <- correlation_id_from_source_event(source_event) do
      Correlation.generate()
    end
  end

  defp correlation_id_from_source_event(source_event) when is_map(source_event) do
    extensions = map_lookup(source_event, :extensions)
    meta = map_lookup(source_event, :meta)

    with :error <- fetch_correlation_id(extensions),
         :error <- fetch_correlation_id(meta) do
      nil
    else
      {:ok, correlation_id} -> correlation_id
    end
  end

  defp correlation_id_from_source_event(_source_event), do: nil

  defp build_event_meta(correlation_id) when is_binary(correlation_id) do
    Correlation.put(%{}, correlation_id)
  end

  defp build_event_meta(_correlation_id), do: %{}

  defp tool_call_with_correlation(tool_call, correlation_id) do
    case ToolCall.from_map(tool_call) do
      {:ok, normalized} ->
        meta = Correlation.put(normalized.meta, correlation_id)
        ToolCall.to_map(%{normalized | meta: meta})

      _ ->
        tool_call
    end
  end

  defp nested_map_lookup(map, [first, second]) when is_map(map) do
    case map_lookup(map, first) do
      nested when is_map(nested) -> map_lookup(nested, second)
      _ -> nil
    end
  end

  defp nested_map_lookup(_map, _path), do: nil

  defp source_event_type(source_event) when is_map(source_event) do
    case ConversationSignal.normalize(source_event) do
      {:ok, signal} -> signal.type
      _ -> map_lookup(source_event, :type)
    end
  end

  defp source_event_type(_source_event), do: nil

  defp fetch_correlation_id(value) when is_map(value), do: Correlation.fetch(value)
  defp fetch_correlation_id(_value), do: :error
end
