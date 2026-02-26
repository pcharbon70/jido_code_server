defmodule Jido.Code.Server.ConversationSignalTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  test "normalizes canonical map signals with flat payload fields" do
    assert {:ok, signal} =
             ConversationSignal.normalize(%{
               "type" => "conversation.user.message",
               "content" => "hello"
             })

    assert signal.type == "conversation.user.message"
    assert signal.data == %{"content" => "hello"}
    assert is_binary(ConversationSignal.correlation_id(signal))
  end

  test "rejects non-canonical map signal types" do
    assert {:error, {:invalid_type, "user.message"}} =
             ConversationSignal.normalize(%{"type" => "user.message", "content" => "hello"})
  end

  test "rejects non-canonical Jido.Signal types" do
    signal = Jido.Signal.new!("tool.completed", %{"name" => "asset.list"})

    assert {:error, {:invalid_type, "tool.completed"}} =
             ConversationSignal.normalize(signal)
  end
end
