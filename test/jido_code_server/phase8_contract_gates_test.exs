defmodule Jido.Code.Server.Phase8ContractGatesTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server, as: Runtime
  alias Jido.Code.Server.Conversation.JournalBridge
  alias Jido.Code.Server.TestSupport.RuntimeSignal
  alias Jido.Code.Server.TestSupport.TempProject
  alias JidoConversation

  @fixture_path "test/fixtures/cross_repo/user_strategy_tool_strategy_trace.json"

  setup do
    on_exit(fn ->
      Enum.each(Runtime.list_projects(), fn %{project_id: project_id} ->
        _ = Runtime.stop_project(project_id)
      end)
    end)

    :ok
  end

  test "shared conversation fixture maps to canonical timeline parity" do
    fixture = load_fixture!()
    project_id = unique_id("phase8-fixture-project")
    conversation_id = unique_id("phase8-fixture-conversation")
    correlation_id = unique_id("phase8-fixture-correlation")

    Enum.each(fixture["conversation_events"] || [], fn event ->
      signal =
        Jido.Signal.new!(event["type"], event["data"] || %{},
          source: "/tests/phase8_contract_fixture",
          extensions: %{"correlation_id" => correlation_id}
        )

      assert :ok = JournalBridge.ingest(project_id, conversation_id, signal)
    end)

    expected_types = fixture["expected"]["canonical_timeline_types"] || []
    expected_statuses = fixture["expected"]["canonical_tool_statuses"] || []

    assert_eventually(fn ->
      timeline = JidoConversation.timeline(project_id, conversation_id, coalesce_deltas: false)
      observed_statuses = Enum.map(tool_entries(timeline), &map_lookup(map_lookup(&1, :metadata), :status))

      Enum.map(timeline, &map_lookup(&1, :type)) == expected_types and
        Enum.frequencies(observed_statuses) == Enum.frequencies(expected_statuses)
    end)
  end

  test "deterministic orchestration ordering and restart parity are stable" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_id = unique_id("phase8-determinism")
    conversation_a = unique_id("phase8-determinism-a")
    conversation_b = unique_id("phase8-determinism-b")

    assert {:ok, ^project_id} =
             Runtime.start_project(root, project_id: project_id, llm_adapter: :deterministic)

    assert {:ok, ^conversation_a} =
             Runtime.start_conversation(project_id, conversation_id: conversation_a)

    assert :ok =
             RuntimeSignal.send_signal(project_id, conversation_a, %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "please list skills"}
             })

    signature_a = wait_for_lifecycle_signature(project_id, conversation_a)

    assert {:ok, ^conversation_b} =
             Runtime.start_conversation(project_id, conversation_id: conversation_b)

    assert :ok =
             RuntimeSignal.send_signal(project_id, conversation_b, %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "please list skills"}
             })

    signature_b = wait_for_lifecycle_signature(project_id, conversation_b)
    assert signature_b == signature_a

    # Recovery gate: canonical projections remain stable across stop/start boundary.
    assert :ok = Runtime.stop_conversation(project_id, conversation_a)

    assert {:ok, ^conversation_a} =
             Runtime.start_conversation(project_id, conversation_id: conversation_a)

    assert :ok =
             RuntimeSignal.send_signal(project_id, conversation_a, %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "after restart"}
             })

    assert_eventually(fn ->
      timeline = JidoConversation.timeline(project_id, conversation_a, [])
      contents = Enum.map(timeline, &map_lookup(&1, :content))

      "after restart" in contents and
        Enum.any?(timeline, &(map_lookup(&1, :type) == "conv.out.assistant.completed"))
    end)
  end

  test "async tool cancellation path drains pending work and conversation remains usable" do
    root = TempProject.create!(with_seed_files: true)
    on_exit(fn -> TempProject.cleanup(root) end)

    project_id = unique_id("phase8-cancel")
    conversation_id = unique_id("phase8-cancel-conversation")

    assert {:ok, ^project_id} =
             Runtime.start_project(root, project_id: project_id, llm_adapter: :deterministic)

    assert {:ok, ^conversation_id} =
             Runtime.start_conversation(project_id, conversation_id: conversation_id)

    assert :ok =
             RuntimeSignal.send_signal(project_id, conversation_id, %{
               "type" => "conversation.tool.requested",
               "data" => %{
                 "name" => "asset.list",
                 "args" => %{"type" => "skill"},
                 "meta" => %{"run_mode" => "async", "correlation_id" => unique_id("phase8-async")}
               }
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, conversation_id, %{
               "type" => "conversation.cancel",
               "data" => %{"reason" => "phase8_cancel"}
             })

    assert_eventually(fn ->
      with {:ok, timeline} <- Runtime.conversation_projection(project_id, conversation_id, :timeline),
           {:ok, pending} <-
             Runtime.conversation_projection(project_id, conversation_id, :pending_tool_calls) do
        types = Enum.map(timeline, &map_lookup(&1, :type))

        pending == [] and "conversation.tool.requested" in types and "conversation.cancel" in types
      else
        _ -> false
      end
    end)

    # Resilience gate: conversation should still accept a new user message afterward.
    assert :ok =
             RuntimeSignal.send_signal(project_id, conversation_id, %{
               "type" => "conversation.resume",
               "data" => %{}
             })

    assert :ok =
             RuntimeSignal.send_signal(project_id, conversation_id, %{
               "type" => "conversation.user.message",
               "data" => %{"content" => "still responsive"}
             })

    assert_eventually(fn ->
      case Runtime.conversation_projection(project_id, conversation_id, :timeline) do
        {:ok, timeline} ->
          types = Enum.map(timeline, &map_lookup(&1, :type))
          "conversation.resume" in types and "conversation.run.closed" in types

        _ ->
          false
      end
    end)
  end

  defp wait_for_lifecycle_signature(project_id, conversation_id) do
    expected_core = [
      "conversation.user.message",
      "conversation.llm.requested",
      "conversation.llm.completed",
      "conversation.run.opened",
      "conversation.run.closed"
    ]

    assert_eventually(fn ->
      case Runtime.conversation_projection(project_id, conversation_id, :timeline) do
        {:ok, timeline} ->
          types = Enum.map(timeline, &map_lookup(&1, :type))
          Enum.all?(expected_core, &(&1 in types))

        _ ->
          false
      end
    end)

    {:ok, timeline} = Runtime.conversation_projection(project_id, conversation_id, :timeline)
    observed_types = Enum.map(timeline, &map_lookup(&1, :type))

    observed_types
    |> Enum.filter(
      &(&1 in [
          "conversation.user.message",
          "conversation.run.opened",
          "conversation.llm.requested",
          "conversation.tool.requested",
          "conversation.tool.completed",
          "conversation.assistant.delta",
          "conversation.assistant.message",
          "conversation.llm.completed",
          "conversation.run.closed"
        ])
    )
  end

  defp load_fixture! do
    @fixture_path
    |> File.read!()
    |> Jason.decode!()
  end

  defp tool_entries(timeline) do
    Enum.filter(timeline, &(map_lookup(&1, :type) == "conv.out.tool.status"))
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp map_lookup(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_lookup(_map, _key), do: nil

  defp assert_eventually(fun, attempts \\ 80)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(30)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true in time")
end
