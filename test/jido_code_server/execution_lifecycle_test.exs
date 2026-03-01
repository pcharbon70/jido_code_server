defmodule Jido.Code.Server.ExecutionLifecycleTest do
  use ExUnit.Case, async: true

  alias Jido.Code.Server.Conversation.ExecutionLifecycle

  test "classifies timeout failures as retryable with timeout category" do
    failure = ExecutionLifecycle.failure_profile(:timeout)

    assert failure["lifecycle_status"] == "failed"
    assert failure["terminal_status"] == "failed"
    assert failure["retryable"] == true
    assert failure["timeout_category"] == "execution_timeout"
  end

  test "classifies cancelled failures as non-retryable canceled lifecycle" do
    failure = ExecutionLifecycle.failure_profile("conversation_cancelled")

    assert failure["lifecycle_status"] == "canceled"
    assert failure["terminal_status"] == "cancelled"
    assert failure["retryable"] == false
  end

  test "honors explicit retryable override from structured payload" do
    failure =
      ExecutionLifecycle.failure_profile(%{"reason" => "temporary_failure", "retryable" => false})

    assert failure["lifecycle_status"] == "failed"
    assert failure["retryable"] == false
  end
end
