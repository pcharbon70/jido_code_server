defmodule Jido.Code.Server.AlertRouterTest do
  use ExUnit.Case, async: false

  alias Jido.Code.Server.Config
  alias Jido.Code.Server.Telemetry

  setup do
    original_router = Application.get_env(:jido_code_server, :alert_router)
    original_events = Application.get_env(:jido_code_server, :alert_signal_events)

    on_exit(fn ->
      restore_env(:alert_router, original_router)
      restore_env(:alert_signal_events, original_events)
    end)

    :ok
  end

  test "configured security/timeout escalation signals route through alert router" do
    Application.put_env(:jido_code_server, :alert_signal_events, [
      "security.sandbox_violation",
      "security.repeated_timeout_failures"
    ])

    Application.put_env(
      :jido_code_server,
      :alert_router,
      {__MODULE__.Sink, :dispatch, [self()]}
    )

    assert :ok =
             Telemetry.emit("security.sandbox_violation", %{
               project_id: "phase9-alert-routing",
               reason: :outside_root
             })

    assert_receive {:alert_routed, event_name, payload, metadata}
    assert event_name == "security.sandbox_violation"
    assert payload.project_id == "phase9-alert-routing"
    assert payload.reason == :outside_root
    assert metadata.alert_event == "security.sandbox_violation"
    assert metadata.alert_severity == :critical
    assert metadata.event_name == "security.sandbox_violation"
  end

  test "non-escalation events are not routed" do
    Application.put_env(:jido_code_server, :alert_signal_events, ["security.sandbox_violation"])
    Application.put_env(:jido_code_server, :alert_router, {__MODULE__.Sink, :dispatch, [self()]})

    assert :ok =
             Telemetry.emit("conversation.tool.completed", %{project_id: "phase9-alert-routing"})

    refute_receive {:alert_routed, _, _, _}, 50
  end

  test "invalid alert router config is ignored safely" do
    Application.put_env(:jido_code_server, :alert_signal_events, ["security.sandbox_violation"])
    Application.put_env(:jido_code_server, :alert_router, {:missing_module, :dispatch, []})

    assert Config.alert_router() == {:missing_module, :dispatch, []}

    assert :ok =
             Telemetry.emit("security.sandbox_violation", %{project_id: "phase9-alert-routing"})
  end

  defmodule Sink do
    @spec dispatch(String.t(), map(), map(), pid()) :: :ok
    def dispatch(event_name, payload, metadata, recipient_pid) do
      send(recipient_pid, {:alert_routed, event_name, payload, metadata})
      :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_code_server, key)
  defp restore_env(key, value), do: Application.put_env(:jido_code_server, key, value)
end
