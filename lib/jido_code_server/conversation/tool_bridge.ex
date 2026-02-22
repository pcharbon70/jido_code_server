defmodule Jido.Code.Server.Conversation.ToolBridge do
  @moduledoc """
  Bridge between conversation tool requests and project tool execution.
  """

  alias Jido.Code.Server.Correlation
  alias Jido.Code.Server.Project.ToolRunner
  alias Jido.Code.Server.Types.ToolCall

  @spec handle_tool_requested(map(), String.t(), map()) :: {:ok, [map()]}
  def handle_tool_requested(project_ctx, conversation_id, tool_call)
      when is_map(project_ctx) and is_binary(conversation_id) and is_map(tool_call) do
    case ToolCall.from_map(tool_call) do
      {:ok, normalized_call} ->
        call_with_meta = call_with_meta(normalized_call, conversation_id, project_ctx)

        case ToolRunner.run(project_ctx, call_with_meta) do
          {:ok, result} ->
            {:ok, [tool_completed_event(call_with_meta, result)]}

          {:error, reason} ->
            {:ok, [tool_failed_event(call_with_meta, reason)]}
        end

      {:error, reason} ->
        {:ok, [invalid_tool_call_event(reason, tool_call)]}
    end
  end

  def handle_tool_requested(_project_ctx, _conversation_id, _tool_call) do
    {:ok, [invalid_tool_call_event(:invalid_tool_call, %{})]}
  end

  @spec cancel_pending(map(), String.t()) :: :ok
  def cancel_pending(_project_ctx, _conversation_id), do: :ok

  defp call_with_meta(%ToolCall{} = call, conversation_id, project_ctx) do
    correlation_id = Map.get(project_ctx, :correlation_id)

    meta =
      call.meta
      |> Map.put("conversation_id", conversation_id)
      |> maybe_put_correlation(correlation_id)

    %{name: call.name, args: call.args, meta: meta}
  end

  defp tool_completed_event(call, result) do
    event_meta = event_meta(call.meta)

    %{
      type: "tool.completed",
      meta: event_meta,
      data: %{
        "name" => call.name,
        "args" => call.args,
        "meta" => call.meta,
        "result" => result
      }
    }
  end

  defp tool_failed_event(call, reason) do
    event_meta = event_meta(call.meta)

    %{
      type: "tool.failed",
      meta: event_meta,
      data: %{
        "name" => call.name,
        "args" => call.args,
        "meta" => call.meta,
        "reason" => reason
      }
    }
  end

  defp invalid_tool_call_event(reason, raw_tool_call) do
    meta = event_meta(raw_tool_call["meta"] || raw_tool_call[:meta] || %{})

    %{
      type: "tool.failed",
      meta: meta,
      data: %{
        "name" => "unknown",
        "args" => %{},
        "reason" => reason,
        "raw_tool_call" => raw_tool_call
      }
    }
  end

  defp maybe_put_correlation(meta, correlation_id) when is_binary(correlation_id) do
    case Correlation.fetch(meta) do
      {:ok, _existing} -> meta
      :error -> Correlation.put(meta, correlation_id)
    end
  end

  defp maybe_put_correlation(meta, _correlation_id), do: meta

  defp event_meta(meta) when is_map(meta) do
    case Correlation.fetch(meta) do
      {:ok, correlation_id} -> Correlation.put(%{}, correlation_id)
      :error -> %{}
    end
  end

  defp event_meta(_meta), do: %{}
end
