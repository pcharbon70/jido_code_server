defmodule Jido.Code.Server.Phase9BenchmarkHarnessTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Benchmark.Phase9Harness

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "phase9 harness runs a small synthetic workload and returns a passing report" do
    assert {:ok, report} =
             Phase9Harness.run(
               project_count: 2,
               conversations_per_project: 2,
               events_per_conversation: 2,
               max_concurrency: 4,
               stream_timeout_ms: 10_000
             )

    assert report.passed?
    assert report.failures == []

    assert report.projects.requested == 2
    assert report.projects.started == 2
    assert report.projects.failed == 0

    assert report.conversations.requested == 4
    assert report.conversations.started == 4
    assert report.conversations.failed == 0

    assert report.events.requested == 8
    assert report.events.sent == 8
    assert report.events.failed == 0

    assert report.projection_checks.checked == 4
    assert report.projection_checks.failed == 0
    assert report.elapsed_ms >= 0
  end

  test "phase9 harness rejects invalid options" do
    assert {:error, {:invalid_benchmark_opt, :project_count, :expected_positive_integer}} =
             Phase9Harness.run(project_count: 0)

    assert {:error,
            {:invalid_benchmark_opt, :conversations_per_project, :expected_positive_integer}} =
             Phase9Harness.run(conversations_per_project: -1)
  end
end
