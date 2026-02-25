defmodule Jido.Code.Server.Benchmark.Phase9Harness do
  @moduledoc """
  Synthetic load/failure harness for Phase 9 operational readiness checks.

  This harness runs an in-process workload over multiple projects and
  conversations, then returns a structured report suitable for CI artifacts
  and runbook execution.
  """

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Conversation.Signal, as: ConversationSignal
  alias Jido.Code.Server.Project.Layout

  @default_project_count 3
  @default_conversations_per_project 4
  @default_events_per_conversation 3
  @default_max_concurrency 12
  @default_stream_timeout_ms 15_000
  @benchmark_prefix "jido_code_server_phase9_bench"
  @event_prefix "phase9-bench:"

  @type run_report :: map()

  @spec run(keyword()) :: {:ok, run_report()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    with {:ok, config} <- normalize_config(opts),
         {:ok, roots} <- create_project_roots(config.project_count) do
      {project_ids, report} = run_with_roots(config, roots)
      cleanup_projects(project_ids)
      cleanup_roots(roots)
      report
    else
      {:error, {:project_root_bootstrap_failed, _reason, roots}} = error ->
        cleanup_roots(roots)
        {:error, error}

      {:error, _reason} = error ->
        error
    end
  end

  defp run_with_roots(config, roots) do
    started_at = System.monotonic_time(:millisecond)
    project_result = start_projects(roots)

    conversation_result =
      start_conversations(project_result.started, config.conversations_per_project)

    workload = build_workload(conversation_result.started, config.events_per_conversation)
    dispatch_result = dispatch_workload(workload, config)
    projection_failures = validate_projections(conversation_result.started, workload)
    diagnostics = collect_project_diagnostics(project_result.started)

    failures =
      project_result.failures
      |> Kernel.++(conversation_result.failures)
      |> Kernel.++(dispatch_result.failures)
      |> Kernel.++(projection_failures)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    report = %{
      started_at: DateTime.utc_now(),
      elapsed_ms: elapsed_ms,
      config: %{
        project_count: config.project_count,
        conversations_per_project: config.conversations_per_project,
        events_per_conversation: config.events_per_conversation,
        max_concurrency: config.max_concurrency,
        stream_timeout_ms: config.stream_timeout_ms
      },
      projects: %{
        requested: config.project_count,
        started: length(project_result.started),
        failed: length(project_result.failures)
      },
      conversations: %{
        requested: config.project_count * config.conversations_per_project,
        started: length(conversation_result.started),
        failed: length(conversation_result.failures)
      },
      events: %{
        requested: length(workload),
        sent: dispatch_result.sent,
        failed: length(dispatch_result.failures),
        latency_ms: latency_summary(dispatch_result.latencies)
      },
      projection_checks: %{
        checked: length(conversation_result.started),
        failed: length(projection_failures)
      },
      project_diagnostics: diagnostics,
      failures: failures,
      passed?: failures == []
    }

    {project_result.started, {:ok, report}}
  end

  defp normalize_config(opts) do
    with {:ok, project_count} <-
           positive_integer_opt(opts, :project_count, @default_project_count),
         {:ok, conversations_per_project} <-
           positive_integer_opt(
             opts,
             :conversations_per_project,
             @default_conversations_per_project
           ),
         {:ok, events_per_conversation} <-
           positive_integer_opt(opts, :events_per_conversation, @default_events_per_conversation),
         {:ok, max_concurrency} <-
           positive_integer_opt(opts, :max_concurrency, @default_max_concurrency),
         {:ok, stream_timeout_ms} <-
           positive_integer_opt(opts, :stream_timeout_ms, @default_stream_timeout_ms) do
      {:ok,
       %{
         project_count: project_count,
         conversations_per_project: conversations_per_project,
         events_per_conversation: events_per_conversation,
         max_concurrency: max_concurrency,
         stream_timeout_ms: stream_timeout_ms
       }}
    end
  end

  defp positive_integer_opt(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, {:invalid_benchmark_opt, key, :expected_positive_integer}}
    end
  end

  defp create_project_roots(project_count) do
    Enum.reduce_while(1..project_count, {:ok, []}, fn index, {:ok, roots} ->
      case create_project_root(index) do
        {:ok, root} ->
          {:cont, {:ok, [root | roots]}}

        {:error, reason} ->
          {:halt, {:error, {:project_root_bootstrap_failed, reason, Enum.reverse(roots)}}}
      end
    end)
    |> case do
      {:ok, roots} -> {:ok, Enum.reverse(roots)}
      {:error, _reason} = error -> error
    end
  end

  defp create_project_root(index) do
    root =
      Path.join(
        System.tmp_dir!(),
        "#{@benchmark_prefix}_#{index}_#{System.unique_integer([:positive])}"
      )

    with {:ok, layout} <- Layout.ensure_layout(root, ".jido"),
         :ok <- seed_layout(layout) do
      {:ok, root}
    end
  end

  defp seed_layout(layout) do
    with :ok <- File.write(Path.join(layout.skills, "example_skill.md"), "# Example Skill\n"),
         :ok <-
           File.write(Path.join(layout.commands, "example_command.md"), "# Example Command\n"),
         :ok <-
           File.write(Path.join(layout.workflows, "example_workflow.md"), "# Example Workflow\n"),
         :ok <- File.write(Path.join(layout.skill_graph, "index.md"), "# Example Graph\n") do
      :ok
    else
      {:error, reason} ->
        {:error, {:seed_layout_failed, reason}}
    end
  end

  defp start_projects(roots) do
    Enum.with_index(roots, 1)
    |> Enum.reduce(%{started: [], failures: []}, fn {root, index}, acc ->
      project_id = benchmark_project_id(index)

      case Runtime.start_project(root,
             project_id: project_id,
             conversation_orchestration: true,
             llm_adapter: :deterministic
           ) do
        {:ok, ^project_id} ->
          %{acc | started: [project_id | acc.started]}

        {:error, reason} ->
          failure = %{
            step: :start_project,
            project_id: project_id,
            root_path: root,
            reason: reason
          }

          %{acc | failures: [failure | acc.failures]}
      end
    end)
    |> reverse_started_and_failures()
  end

  defp start_conversations(project_ids, conversations_per_project) do
    jobs =
      for project_id <- project_ids,
          index <- 1..conversations_per_project do
        {project_id, index}
      end

    Enum.reduce(jobs, %{started: [], failures: []}, fn {project_id, index}, acc ->
      start_conversation_for_benchmark(acc, project_id, index)
    end)
    |> reverse_started_and_failures()
  end

  defp start_conversation_for_benchmark(acc, project_id, index) do
    conversation_id = "#{project_id}-c#{index}"

    case Runtime.start_conversation(project_id, conversation_id: conversation_id) do
      {:ok, ^conversation_id} ->
        %{acc | started: [{project_id, conversation_id} | acc.started]}

      {:error, reason} ->
        failure = %{
          step: :start_conversation,
          project_id: project_id,
          conversation_id: conversation_id,
          reason: reason
        }

        %{acc | failures: [failure | acc.failures]}
    end
  end

  defp build_workload(conversations, events_per_conversation) do
    for {project_id, conversation_id} <- conversations,
        event_index <- 1..events_per_conversation do
      %{
        project_id: project_id,
        conversation_id: conversation_id,
        content: "#{@event_prefix}#{project_id}:#{conversation_id}:#{event_index}"
      }
    end
  end

  defp dispatch_workload([], _config), do: %{sent: 0, failures: [], latencies: []}

  defp dispatch_workload(workload, config) do
    workload
    |> Task.async_stream(
      &send_workload_event/1,
      max_concurrency: min(config.max_concurrency, length(workload)),
      timeout: config.stream_timeout_ms,
      ordered: false
    )
    |> Enum.reduce(%{sent: 0, failures: [], latencies: []}, fn
      {:ok, %{ok?: true, latency_ms: latency}}, acc ->
        %{acc | sent: acc.sent + 1, latencies: [latency | acc.latencies]}

      {:ok, %{ok?: false, latency_ms: latency, failure: failure}}, acc ->
        %{acc | failures: [failure | acc.failures], latencies: [latency | acc.latencies]}

      {:exit, reason}, acc ->
        failure = %{step: :send_event, reason: {:task_exit, reason}}
        %{acc | failures: [failure | acc.failures]}
    end)
    |> reverse_failures_and_latencies()
  end

  defp send_workload_event(event) do
    started_at = System.monotonic_time(:millisecond)

    result =
      send_signal(event.project_id, event.conversation_id, %{
        "type" => "conversation.user.message",
        "content" => event.content
      })

    duration_ms = System.monotonic_time(:millisecond) - started_at

    case result do
      :ok ->
        %{ok?: true, latency_ms: duration_ms}

      {:error, reason} ->
        %{
          ok?: false,
          latency_ms: duration_ms,
          failure: %{
            step: :send_event,
            project_id: event.project_id,
            conversation_id: event.conversation_id,
            content: event.content,
            reason: reason
          }
        }
    end
  end

  defp validate_projections(conversations, workload) do
    expected = expected_messages_by_conversation(workload)

    Enum.reduce(conversations, [], fn {project_id, conversation_id}, acc ->
      expected_messages = Map.get(expected, {project_id, conversation_id}, [])

      case projection_failure(project_id, conversation_id, expected_messages) do
        nil -> acc
        failure -> [failure | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp projection_failure(project_id, conversation_id, expected_messages) do
    case Runtime.conversation_projection(project_id, conversation_id, :timeline) do
      {:ok, timeline} when is_list(timeline) ->
        actual = actual_benchmark_messages(timeline)
        missing = expected_messages -- actual

        case missing do
          [] ->
            nil

          _ ->
            %{
              step: :projection_check,
              project_id: project_id,
              conversation_id: conversation_id,
              reason: :missing_messages,
              expected_count: length(expected_messages),
              actual_count: length(actual),
              missing_count: length(missing)
            }
        end

      {:error, reason} ->
        %{
          step: :projection_check,
          project_id: project_id,
          conversation_id: conversation_id,
          reason: reason
        }
    end
  end

  defp actual_benchmark_messages(timeline) do
    timeline
    |> Enum.filter(&(map_lookup(&1, :type) == "conversation.user.message"))
    |> Enum.map(&map_lookup(&1, :content))
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, @event_prefix)))
  end

  defp send_signal(project_id, conversation_id, raw_signal) do
    with {:ok, signal} <- ConversationSignal.normalize(raw_signal),
         {:ok, _snapshot} <-
           Runtime.conversation_call(project_id, conversation_id, signal, 30_000) do
      :ok
    end
  end

  defp expected_messages_by_conversation(workload) do
    Enum.reduce(workload, %{}, fn event, acc ->
      key = {event.project_id, event.conversation_id}
      Map.update(acc, key, [event.content], &[event.content | &1])
    end)
    |> Enum.into(%{}, fn {key, messages} -> {key, Enum.reverse(messages)} end)
  end

  defp collect_project_diagnostics(project_ids) do
    Enum.map(project_ids, fn project_id ->
      case Runtime.diagnostics(project_id) do
        %{health: %{status: status, error_count: error_count}} ->
          %{project_id: project_id, health_status: status, error_count: error_count}

        _ ->
          %{project_id: project_id, health_status: :unknown, error_count: nil}
      end
    end)
  end

  defp latency_summary([]) do
    %{count: 0, min: 0, max: 0, avg: 0.0, p50: 0, p95: 0}
  end

  defp latency_summary(values) when is_list(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    sum = Enum.sum(sorted)

    %{
      count: count,
      min: hd(sorted),
      max: List.last(sorted),
      avg: Float.round(sum / count, 2),
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95)
    }
  end

  defp percentile(sorted_values, percentile)
       when is_list(sorted_values) and sorted_values != [] do
    count = length(sorted_values)
    rank = Float.ceil(percentile / 100 * count) |> trunc()
    index = max(rank - 1, 0)
    Enum.at(sorted_values, index, List.last(sorted_values))
  end

  defp cleanup_projects(project_ids) do
    Enum.each(project_ids, fn project_id ->
      _ = Runtime.stop_project(project_id)
    end)
  end

  defp cleanup_roots(roots) do
    Enum.each(roots, fn root ->
      _ = File.rm_rf(root)
    end)
  end

  defp reverse_started_and_failures(result) do
    %{
      started: Enum.reverse(result.started),
      failures: Enum.reverse(result.failures)
    }
  end

  defp reverse_failures_and_latencies(result) do
    %{
      sent: result.sent,
      failures: Enum.reverse(result.failures),
      latencies: Enum.reverse(result.latencies)
    }
  end

  defp benchmark_project_id(index) do
    "phase9-bench-p#{index}-#{System.unique_integer([:positive])}"
  end

  defp map_lookup(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_lookup(_map, _key), do: nil
end
