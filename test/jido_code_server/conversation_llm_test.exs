defmodule Jido.Code.Server.ConversationLLMTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.LLM

  @tool_specs [
    %{
      name: "asset.list",
      description: "List project assets",
      input_schema: %{"type" => "object", "properties" => %{}}
    }
  ]

  test "deterministic completion summarizes canonical tool completed source events" do
    source_event = %{
      "type" => "conversation.tool.completed",
      "data" => %{"name" => "asset.list"}
    }

    assert {:ok, %{events: events}} =
             LLM.start_completion(
               %{llm_adapter: :deterministic},
               "conversation-1",
               %{messages: []},
               source_event: source_event
             )

    assistant_message =
      Enum.find(events, fn event -> Map.get(event, :type) == "conversation.assistant.message" end)

    assert assistant_message
    assert get_in(assistant_message, [:data, "content"]) == "Tool asset.list completed."
  end

  test "deterministic completion infers tool calls from canonical user source events" do
    source_event = %{
      "type" => "conversation.user.message",
      "content" => "please list skills"
    }

    llm_context = %{messages: [%{role: :user, content: "please list skills"}]}

    assert {:ok, %{events: events}} =
             LLM.start_completion(
               %{llm_adapter: :deterministic},
               "conversation-3",
               llm_context,
               source_event: source_event,
               tool_specs: @tool_specs
             )

    tool_requested =
      Enum.find(events, fn event -> Map.get(event, :type) == "conversation.tool.requested" end)

    assert tool_requested
    assert get_in(tool_requested, [:data, "tool_call", :name]) == "asset.list"
    assert get_in(tool_requested, [:data, "tool_call", :args]) == %{"type" => "skill"}
  end
end
