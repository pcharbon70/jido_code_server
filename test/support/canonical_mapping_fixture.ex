defmodule Jido.Code.Server.TestSupport.CanonicalMappingFixture do
  @moduledoc false

  @mapping_cases [
    %{
      conversation_type: "conversation.user.message",
      data: %{"content" => "fixture user message"},
      expected_canonical_type: "conv.in.message.received",
      expected_status: nil
    },
    %{
      conversation_type: "conversation.assistant.delta",
      data: %{"delta" => "fixture delta"},
      expected_canonical_type: "conv.out.assistant.delta",
      expected_status: nil
    },
    %{
      conversation_type: "conversation.assistant.message",
      data: %{"content" => "fixture assistant message"},
      expected_canonical_type: "conv.out.assistant.completed",
      expected_status: nil
    },
    %{
      conversation_type: "conversation.tool.requested",
      data: %{"name" => "asset.list"},
      expected_canonical_type: "conv.out.tool.status",
      expected_status: "requested"
    },
    %{
      conversation_type: "conversation.tool.completed",
      data: %{"name" => "asset.list"},
      expected_canonical_type: "conv.out.tool.status",
      expected_status: "completed"
    },
    %{
      conversation_type: "conversation.tool.failed",
      data: %{"name" => "asset.list", "reason" => "fixture failure"},
      expected_canonical_type: "conv.out.tool.status",
      expected_status: "failed"
    },
    %{
      conversation_type: "conversation.tool.cancelled",
      data: %{"name" => "asset.list", "reason" => "fixture cancel"},
      expected_canonical_type: "conv.out.tool.status",
      expected_status: "canceled"
    }
  ]

  @spec mapping_cases() :: [map()]
  def mapping_cases, do: @mapping_cases
end
