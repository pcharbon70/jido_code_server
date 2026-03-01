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

  test "rejects unsupported strategy and mode combinations" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "hello"},
        source: "/conversation/c-1",
        extensions: %{"correlation_id" => "corr-exec-2"}
      )

    params = %{
      "execution_envelope" => %{
        "execution_kind" => "strategy_run",
        "conversation_id" => "c-1",
        "mode" => "planning",
        "mode_state" => %{"strategy" => "planning"},
        "strategy_type" => "engineering_design",
        "strategy_opts" => %{},
        "source_signal" => Jido.Code.Server.Conversation.Signal.to_map(source_signal),
        "llm_context" => %{
          "messages" => [%{"role" => "user", "content" => "hello"}]
        },
        "correlation_id" => "corr-exec-2",
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

    assert {:error, result} = RunExecutionInstruction.run(params, context)
    assert result["execution_kind"] == "strategy_run"
    assert is_binary(result["reason"])
    assert String.contains?(result["reason"], "unsupported_strategy_for_mode")
  end

  test "returns normalized failure payload with canonical signals when strategy runner errors" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "hello"},
        source: "/conversation/c-1",
        extensions: %{"correlation_id" => "corr-exec-3"}
      )

    params = %{
      "execution_envelope" => %{
        "execution_kind" => "strategy_run",
        "conversation_id" => "c-1",
        "mode" => "coding",
        "mode_state" => %{"strategy" => "code_generation"},
        "strategy_type" => "code_generation",
        "strategy_opts" => %{"adapter" => :missing_adapter},
        "source_signal" => Jido.Code.Server.Conversation.Signal.to_map(source_signal),
        "llm_context" => %{
          "messages" => [%{"role" => "user", "content" => "hello"}]
        },
        "correlation_id" => "corr-exec-3",
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

    assert {:error, result} = RunExecutionInstruction.run(params, context)
    assert result["execution_kind"] == "strategy_run"
    assert result["retryable"] == false
    assert is_list(result["signals"])

    assert Enum.any?(result["signals"], fn signal ->
             signal["type"] == "conversation.llm.requested"
           end)

    failed =
      Enum.find(result["signals"], fn signal ->
        signal["type"] == "conversation.llm.failed"
      end)

    assert failed
    assert is_binary(get_in(failed, ["data", "reason"]))
    assert String.contains?(get_in(failed, ["data", "reason"]), "invalid_llm_adapter")
    assert get_in(failed, ["extensions", "cause_id"]) == source_signal.id
    assert get_in(failed, ["meta", "correlation_id"]) == "corr-exec-3"
  end
end
