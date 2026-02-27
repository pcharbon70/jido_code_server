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

  test "rejects mixed payloads with data envelope and flat fields" do
    assert {:error, :missing_data_envelope} =
             ConversationSignal.normalize(%{
               "type" => "conversation.user.message",
               "data" => %{"content" => "hello"},
               "content" => "shadowed"
             })

    assert {:error, :missing_data_envelope} =
             ConversationSignal.normalize(%{
               type: "conversation.user.message",
               data: %{"content" => "hello"},
               content: "shadowed"
             })
  end

  test "rejects raw map signals with non-map data values" do
    assert {:error, :invalid_data} =
             ConversationSignal.normalize(%{
               "type" => "conversation.user.message",
               "data" => "hello"
             })

    assert {:error, :invalid_data} =
             ConversationSignal.normalize(%{
               type: "conversation.user.message",
               data: ["hello"]
             })
  end

  test "rejects raw map signals with non-map meta or extensions values" do
    assert {:error, :invalid_meta} =
             ConversationSignal.normalize(%{
               "type" => "conversation.user.message",
               "data" => %{"content" => "hello"},
               "meta" => "corr-123"
             })

    assert {:error, :invalid_extensions} =
             ConversationSignal.normalize(%{
               type: "conversation.user.message",
               data: %{"content" => "hello"},
               extensions: [:invalid]
             })
  end

  test "accepts nil meta and extensions envelope values" do
    assert {:ok, signal} =
             ConversationSignal.normalize(%{
               "type" => "conversation.user.message",
               "data" => %{"content" => "hello"},
               "meta" => nil,
               "extensions" => nil
             })

    assert signal.data == %{"content" => "hello"}
    assert is_binary(ConversationSignal.correlation_id(signal))
  end

  test "to_map keeps payload fields inside data envelope" do
    signal = Jido.Signal.new!("conversation.user.message", %{"content" => "hello"})
    mapped = ConversationSignal.to_map(signal)

    assert get_in(mapped, ["data", "content"]) == "hello"
    refute Map.has_key?(mapped, "content")
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
