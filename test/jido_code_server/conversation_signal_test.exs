defmodule Jido.Code.Server.ConversationSignalTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  test "normalizes canonical map signals with explicit data envelope" do
    assert {:ok, signal} =
             ConversationSignal.normalize(%{
               "type" => "conversation.user.message",
               "data" => %{"content" => "hello"}
             })

    assert signal.type == "conversation.user.message"
    assert signal.data == %{"content" => "hello"}
    assert is_binary(ConversationSignal.correlation_id(signal))
  end

  test "rejects flat payload fields outside the data envelope" do
    assert {:error, :missing_data_envelope} =
             ConversationSignal.normalize(%{
               "type" => "conversation.user.message",
               "content" => "hello"
             })
  end

  test "rejects non-canonical map signal types" do
    assert {:error, {:invalid_type, "user.message"}} =
             ConversationSignal.normalize(%{"type" => "user.message", "content" => "hello"})
  end

  test "rejects unknown conversation namespace types" do
    assert {:error, {:invalid_type, "conversation.unknown.event"}} =
             ConversationSignal.normalize(%{
               "type" => "conversation.unknown.event",
               "content" => "hello"
             })
  end

  test "rejects non-canonical Jido.Signal types" do
    signal = Jido.Signal.new!("tool.completed", %{"name" => "asset.list"})

    assert {:error, {:invalid_type, "tool.completed"}} =
             ConversationSignal.normalize(signal)
  end

  test "rejects non-map Jido.Signal payload data" do
    signal = Jido.Signal.new!("conversation.user.message", "hello")

    assert {:error, :invalid_data} =
             ConversationSignal.normalize(signal)
  end
end
