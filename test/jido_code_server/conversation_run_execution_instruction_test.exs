defmodule Jido.Code.Server.ConversationRunExecutionInstructionTest.NativePayloadRunner do
  @behaviour Jido.Code.Server.Project.StrategyRunner

  @impl true
  def start(_project_ctx, _envelope, _opts) do
    {:ok,
     %{
       "delta_chunks" => ["Design ", "notes"],
       "tool_calls" => [%{"name" => "asset.list", "args" => %{"type" => "skill"}}],
       "finish_reason" => "tool_calls",
       "provider" => :jido_ai,
       "model" => "claude-3-7-sonnet"
     }}
  end

  @impl true
  def capabilities do
    %{
      streaming?: true,
      tool_calling?: true,
      cancellable?: true,
      supported_strategies: [:code_generation, :planning, :engineering_design, :reasoning]
    }
  end
end

defmodule Jido.Code.Server.ConversationRunExecutionInstructionTest.CancelledPayloadRunner do
  @behaviour Jido.Code.Server.Project.StrategyRunner

  @impl true
  def start(_project_ctx, _envelope, _opts) do
    {:ok,
     %{
       "cancelled" => true,
       "reason" => "conversation_cancelled",
       "finish_reason" => "cancelled",
       "provider" => "jido_ai",
       "model" => "claude-3-7-sonnet"
     }}
  end

  @impl true
  def capabilities do
    %{
      streaming?: false,
      tool_calling?: false,
      cancellable?: true,
      supported_strategies: [:code_generation, :planning, :engineering_design, :reasoning]
    }
  end
end

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
    assert is_map(result["execution"])
    assert result["lifecycle_status"] == "completed"
    assert result["execution"]["execution_kind"] == "strategy_run"
    assert result["execution"]["run_id"] == "corr-exec-1"
    assert result["execution"]["step_id"] =~ ":strategy:"

    assert Enum.any?(result["signals"], fn signal ->
             signal["type"] == "conversation.llm.requested"
           end)

    requested =
      Enum.find(result["signals"], fn signal ->
        signal["type"] == "conversation.llm.requested"
      end)

    assert requested
    assert get_in(requested, ["data", "execution", "execution_kind"]) == "strategy_run"
    assert get_in(requested, ["data", "execution", "lifecycle_status"]) == "requested"
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

  test "resolves mode default strategy when strategy_type is omitted" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "plan this"},
        source: "/conversation/c-1",
        extensions: %{"correlation_id" => "corr-exec-4"}
      )

    params = %{
      "execution_envelope" => %{
        "execution_kind" => "strategy_run",
        "conversation_id" => "c-1",
        "mode" => "planning",
        "mode_state" => %{},
        "strategy_opts" => %{
          "runner" => Jido.Code.Server.ConversationRunExecutionInstructionTest.NativePayloadRunner
        },
        "source_signal" => Jido.Code.Server.Conversation.Signal.to_map(source_signal),
        "llm_context" => %{
          "messages" => [%{"role" => "user", "content" => "plan this"}]
        },
        "correlation_id" => "corr-exec-4",
        "cause_id" => source_signal.id
      }
    }

    context = %{
      "conversation_id" => "c-1",
      "project_ctx" => %{
        project_id: "p-1",
        conversation_id: "c-1"
      }
    }

    assert {:ok, result} = RunExecutionInstruction.run(params, context)
    assert result["result_meta"]["strategy_type"] == "planning"
    assert result["result_meta"]["mode"] == "planning"
  end

  test "applies strategy override precedence from request then project defaults" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "plan this"},
        source: "/conversation/c-1",
        extensions: %{"correlation_id" => "corr-exec-5"}
      )

    base_envelope = %{
      "execution_kind" => "strategy_run",
      "conversation_id" => "c-1",
      "mode" => "planning",
      "mode_state" => %{"strategy" => "reasoning"},
      "strategy_opts" => %{
        "runner" => Jido.Code.Server.ConversationRunExecutionInstructionTest.NativePayloadRunner
      },
      "source_signal" => Jido.Code.Server.Conversation.Signal.to_map(source_signal),
      "llm_context" => %{
        "messages" => [%{"role" => "user", "content" => "plan this"}]
      },
      "correlation_id" => "corr-exec-5",
      "cause_id" => source_signal.id
    }

    context = %{
      "conversation_id" => "c-1",
      "project_ctx" => %{
        project_id: "p-1",
        conversation_id: "c-1",
        strategy_defaults: %{planning: "planning"}
      }
    }

    assert {:ok, project_default_result} =
             RunExecutionInstruction.run(%{"execution_envelope" => base_envelope}, context)

    assert project_default_result["result_meta"]["strategy_type"] == "planning"

    request_override_envelope = Map.put(base_envelope, "strategy_type", "reasoning")

    assert {:ok, request_override_result} =
             RunExecutionInstruction.run(
               %{"execution_envelope" => request_override_envelope},
               context
             )

    assert request_override_result["result_meta"]["strategy_type"] == "reasoning"
  end

  test "normalizes streaming-style strategy payloads through execution instruction path" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "design"},
        source: "/conversation/c-1",
        extensions: %{"correlation_id" => "corr-exec-6"}
      )

    params = %{
      "execution_envelope" => %{
        "execution_kind" => "strategy_run",
        "conversation_id" => "c-1",
        "mode" => "coding",
        "mode_state" => %{"strategy" => "code_generation"},
        "strategy_type" => "code_generation",
        "strategy_opts" => %{
          "runner" => Jido.Code.Server.ConversationRunExecutionInstructionTest.NativePayloadRunner
        },
        "source_signal" => Jido.Code.Server.Conversation.Signal.to_map(source_signal),
        "llm_context" => %{
          "messages" => [%{"role" => "user", "content" => "design"}]
        },
        "correlation_id" => "corr-exec-6",
        "cause_id" => source_signal.id
      }
    }

    context = %{
      "conversation_id" => "c-1",
      "project_ctx" => %{
        project_id: "p-1",
        conversation_id: "c-1"
      }
    }

    assert {:ok, result} = RunExecutionInstruction.run(params, context)
    types = Enum.map(result["signals"], & &1["type"])

    assert "conversation.llm.requested" in types
    assert "conversation.assistant.delta" in types
    assert "conversation.tool.requested" in types
    assert "conversation.llm.completed" in types

    tool_requested =
      Enum.find(result["signals"], fn signal ->
        signal["type"] == "conversation.tool.requested"
      end)

    assert get_in(tool_requested, ["data", "tool_call", :name]) == "asset.list"
    assert get_in(tool_requested, ["data", "execution", "execution_kind"]) == "tool_run"
    assert get_in(tool_requested, ["data", "execution", "lifecycle_status"]) == "requested"

    completed =
      Enum.find(result["signals"], fn signal ->
        signal["type"] == "conversation.llm.completed"
      end)

    assert get_in(completed, ["data", "execution", "execution_kind"]) == "strategy_run"
    assert get_in(completed, ["data", "execution", "lifecycle_status"]) == "completed"
  end

  test "maps cancelled strategy payloads to canonical failed terminal signal with cancelled status" do
    source_signal =
      Jido.Signal.new!("conversation.user.message", %{"content" => "design"},
        source: "/conversation/c-1",
        extensions: %{"correlation_id" => "corr-exec-7"}
      )

    params = %{
      "execution_envelope" => %{
        "execution_kind" => "strategy_run",
        "conversation_id" => "c-1",
        "mode" => "engineering",
        "mode_state" => %{"strategy" => "engineering_design"},
        "strategy_type" => "engineering_design",
        "strategy_opts" => %{
          "runner" =>
            Jido.Code.Server.ConversationRunExecutionInstructionTest.CancelledPayloadRunner
        },
        "source_signal" => Jido.Code.Server.Conversation.Signal.to_map(source_signal),
        "llm_context" => %{
          "messages" => [%{"role" => "user", "content" => "design"}]
        },
        "correlation_id" => "corr-exec-7",
        "cause_id" => source_signal.id
      }
    }

    context = %{
      "conversation_id" => "c-1",
      "project_ctx" => %{
        project_id: "p-1",
        conversation_id: "c-1"
      }
    }

    assert {:ok, result} = RunExecutionInstruction.run(params, context)
    assert result["result_meta"]["terminal_status"] == "cancelled"
    assert result["result_meta"]["lifecycle_status"] == "canceled"
    assert result["execution"]["lifecycle_status"] == "canceled"

    failed =
      Enum.find(result["signals"], fn signal ->
        signal["type"] == "conversation.llm.failed"
      end)

    assert failed
    assert get_in(failed, ["data", "reason"]) == "conversation_cancelled"
    assert get_in(failed, ["data", "execution", "lifecycle_status"]) == "failed"
  end
end
