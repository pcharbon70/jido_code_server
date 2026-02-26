defmodule Jido.Code.Server.Benchmark.Phase9BenchScript do
  alias Jido.Code.Server.Benchmark.Phase9Harness
  require Logger

  @switches [
    projects: :integer,
    conversations: :integer,
    events: :integer,
    concurrency: :integer,
    timeout_ms: :integer,
    quiet: :boolean,
    verbose: :boolean
  ]

  def run do
    {parsed, _argv, _invalid} = OptionParser.parse(System.argv(), strict: @switches)
    configure_logging(parsed)
    ensure_runtime_started!()

    harness_opts = [
      project_count: Keyword.get(parsed, :projects, 3),
      conversations_per_project: Keyword.get(parsed, :conversations, 4),
      events_per_conversation: Keyword.get(parsed, :events, 3),
      max_concurrency: Keyword.get(parsed, :concurrency, 12),
      stream_timeout_ms: Keyword.get(parsed, :timeout_ms, 15_000)
    ]

    case Phase9Harness.run(harness_opts) do
      {:ok, report} ->
        print_report(report)

        if report.passed? do
          IO.puts("Phase 9 benchmark harness passed.")
        else
          IO.puts("Phase 9 benchmark harness reported failures.")
          System.halt(1)
        end

      {:error, reason} ->
        IO.puts("Failed to run Phase 9 benchmark harness: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp configure_logging(parsed) do
    quiet? =
      case {Keyword.get(parsed, :quiet), Keyword.get(parsed, :verbose, false)} do
        {true, false} -> true
        {false, _verbose?} -> false
        {nil, false} -> true
        {_quiet?, true} -> false
      end

    if quiet? do
      Logger.configure(level: :warning)
    end
  end

  defp ensure_runtime_started! do
    case Application.ensure_all_started(:jido_code_server) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start :jido_code_server: #{inspect(reason)}"
    end
  end

  defp print_report(report) do
    IO.puts("Phase 9 Benchmark Report")
    IO.puts("Elapsed (ms): #{report.elapsed_ms}")

    IO.puts(
      "Projects: requested=#{report.projects.requested} started=#{report.projects.started} failed=#{report.projects.failed}"
    )

    IO.puts(
      "Conversations: requested=#{report.conversations.requested} started=#{report.conversations.started} failed=#{report.conversations.failed}"
    )

    IO.puts(
      "Events: requested=#{report.events.requested} sent=#{report.events.sent} failed=#{report.events.failed}"
    )

    latency = report.events.latency_ms

    IO.puts(
      "Latency (ms): avg=#{latency.avg} p50=#{latency.p50} p95=#{latency.p95} min=#{latency.min} max=#{latency.max}"
    )

    IO.puts(
      "Projection checks: checked=#{report.projection_checks.checked} failed=#{report.projection_checks.failed}"
    )

    Enum.each(report.project_diagnostics, fn diag ->
      IO.puts(
        "Project diag: project_id=#{diag.project_id} health=#{diag.health_status} errors=#{diag.error_count}"
      )
    end)

    if report.failures != [] do
      IO.puts("Failures:")

      Enum.each(report.failures, fn failure ->
        IO.puts("  - #{inspect(failure)}")
      end)
    end
  end
end

Jido.Code.Server.Benchmark.Phase9BenchScript.run()
