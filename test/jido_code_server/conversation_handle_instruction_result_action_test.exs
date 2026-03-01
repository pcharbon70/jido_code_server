defmodule Jido.Code.Server.ConversationHandleInstructionResultActionTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.Actions.HandleInstructionResultAction
  alias Jido.Code.Server.Conversation.Domain.State
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal

  test "re-ingests reason signals when instruction returns error with normalized payload" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "hello"},
        source: "/conversation/c-action",
        extensions: %{"correlation_id" => "corr-action"}
      )

    requested =
      Jido.Signal.new!("conversation.llm.requested", %{"source_signal_id" => source_signal.id},
        source: "/conversation/c-action",
        extensions: %{"correlation_id" => "corr-action", "cause_id" => source_signal.id}
      )

    failed =
      Jido.Signal.new!("conversation.llm.failed", %{"reason" => "temporary_failure"},
        source: "/conversation/c-action",
        extensions: %{"correlation_id" => "corr-action", "cause_id" => source_signal.id}
      )

    params = %{
      "status" => "error",
      "reason" => %{
        "signals" => [ConversationSignal.to_map(requested), ConversationSignal.to_map(failed)]
      },
      "meta" => %{
        "effect_kind" => "execution",
        "execution_kind" => "strategy_run"
      }
    }

    context = %{
      "state" => %{
        project_id: "p-action",
        conversation_id: "c-action",
        project_ctx: %{},
        domain: State.new(project_id: "p-action", conversation_id: "c-action")
      }
    }

    assert {:ok, %{domain: domain}, _directives} =
             HandleInstructionResultAction.run(params, context)

    types = Enum.map(domain.timeline, & &1.type)
    assert "conversation.llm.requested" in types
    assert "conversation.llm.failed" in types
  end
end
