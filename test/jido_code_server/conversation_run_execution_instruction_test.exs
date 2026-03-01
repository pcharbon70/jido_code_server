defmodule Jido.Code.Server.ConversationRunExecutionInstructionTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.Instructions.RunExecutionInstruction

  test "returns normalized execution payload for strategy_run envelope" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "hello"},
        source: "/conversation/c-1",
        extensions: %{"correlation_id" => "corr-exec-1"}
      )

    params = %{
      "execution_envelope" => %{
        "execution_kind" => "strategy_run",
        "conversation_id" => "c-1",
        "mode" => "coding",
        "mode_state" => %{"strategy" => "code_generation", "max_turn_steps" => 16},
        "strategy_type" => "code_generation",
        "strategy_opts" => %{},
        "source_signal" => Jido.Code.Server.Conversation.Signal.to_map(source_signal),
        "llm_context" => %{
          "messages" => [%{"role" => "user", "content" => "hello"}]
        },
        "correlation_id" => "corr-exec-1",
        "cause_id" => source_signal.id
      }
    }

    context = %{
      "conversation_id" => "c-1",
      "project_ctx" => %{
        project_id: "p-1",
        conversation_id: "c-1",
        llm_adapter: :deterministic
      }
    }

    assert {:ok, result} = RunExecutionInstruction.run(params, context)
    assert is_list(result["signals"])
    assert is_map(result["result_meta"])
    assert is_binary(result["execution_ref"])

    assert Enum.any?(result["signals"], fn signal ->
             signal["type"] == "conversation.llm.requested"
           end)
  end
end
