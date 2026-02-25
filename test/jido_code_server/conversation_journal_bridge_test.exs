defmodule Jido.Code.Server.ConversationJournalBridgeTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.TestSupport.RuntimeSignal
  alias Jido.Code.Server.TestSupport.TempProject
  alias JidoConversation

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "conversation timeline is mirrored into jido_conversation canonical timeline/context" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_id = unique_id("journal-bridge-project")
    conversation_id = unique_id("journal-bridge-conversation")

    assert {:ok, ^project_id} =
             Runtime.start_project(root,
               project_id: project_id,
               conversation_orchestration: true,
               llm_adapter: :deterministic
             )

    assert {:ok, ^conversation_id} =
             Runtime.start_conversation(project_id, conversation_id: conversation_id)

    assert :ok =
             RuntimeSignal.send_signal(project_id, conversation_id, %{
               "type" => "conversation.user.message",
               "content" => "hello bridge"
             })

    assert {:ok, canonical_timeline} =
             Runtime.conversation_projection(project_id, conversation_id, :canonical_timeline)

    assert Enum.any?(canonical_timeline, &(&1.type == "conv.in.message.received"))
    assert Enum.any?(canonical_timeline, &(&1.type == "conv.out.assistant.completed"))

    assert {:ok, canonical_context} =
             Runtime.conversation_projection(project_id, conversation_id, :canonical_llm_context)

    assert Enum.any?(canonical_context, &(&1.role == :user))
    assert Enum.any?(canonical_context, &(&1.role == :assistant))
  end

  test "same conversation id is isolated across projects in canonical mirror" do
    root_a = TempProject.create!()
    root_b = TempProject.create!()

    on_exit(fn ->
      TempProject.cleanup(root_a)
      TempProject.cleanup(root_b)
    end)

    project_a = unique_id("journal-bridge-project-a")
    project_b = unique_id("journal-bridge-project-b")
    conversation_id = unique_id("shared-conversation")

    assert {:ok, ^project_a} = Runtime.start_project(root_a, project_id: project_a)
    assert {:ok, ^project_b} = Runtime.start_project(root_b, project_id: project_b)

    assert {:ok, ^conversation_id} =
             Runtime.start_conversation(project_a, conversation_id: conversation_id)

    assert {:ok, ^conversation_id} =
             Runtime.start_conversation(project_b, conversation_id: conversation_id)

    assert :ok =
             RuntimeSignal.send_signal(project_a, conversation_id, %{
               "type" => "conversation.user.message",
               "content" => "hello from project a"
             })

    assert :ok =
             RuntimeSignal.send_signal(project_b, conversation_id, %{
               "type" => "conversation.user.message",
               "content" => "hello from project b"
             })

    assert {:ok, canonical_timeline_a} =
             Runtime.conversation_projection(project_a, conversation_id, :canonical_timeline)

    assert {:ok, canonical_timeline_b} =
             Runtime.conversation_projection(project_b, conversation_id, :canonical_timeline)

    assert [%{content: "hello from project a"}] =
             Enum.filter(canonical_timeline_a, &(&1.type == "conv.in.message.received"))

    assert [%{content: "hello from project b"}] =
             Enum.filter(canonical_timeline_b, &(&1.type == "conv.in.message.received"))
  end

  test "conversation cast persists canonical user message without projection sync side-effects" do
    root = TempProject.create!()
    on_exit(fn -> TempProject.cleanup(root) end)

    project_id = unique_id("journal-bridge-cast-project")
    conversation_id = unique_id("journal-bridge-cast-conversation")

    assert {:ok, ^project_id} = Runtime.start_project(root, project_id: project_id)

    assert {:ok, ^conversation_id} =
             Runtime.start_conversation(project_id, conversation_id: conversation_id)

    signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "cast hello"},
        source: "/test/conversation_journal_bridge"
      )

    assert :ok = Runtime.conversation_cast(project_id, conversation_id, signal)

    assert_eventually(fn ->
      timeline = JidoConversation.timeline(project_id, conversation_id, [])

      Enum.any?(timeline, fn entry ->
        entry.type == "conv.in.message.received" and entry.content == "cast hello"
      end)
    end)

    assert_eventually(fn ->
      case Runtime.conversation_projection(project_id, conversation_id, :canonical_timeline) do
        {:ok, timeline} ->
          Enum.any?(timeline, fn entry ->
            entry.type == "conv.in.message.received" and entry.content == "cast hello"
          end)

        _ ->
          false
      end
    end)
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0) do
    flunk("condition did not become true in time")
  end
end
