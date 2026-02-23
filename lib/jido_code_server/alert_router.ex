defmodule Jido.Code.Server.AlertRouter do
  @moduledoc """
  Routes configured high-severity telemetry events to an external alert handler.
  """

  alias Jido.Code.Server.Config

  @type event_name :: String.t()
  @type payload :: map()
  @type metadata :: map()

  @critical_events MapSet.new([
                     "security.sandbox_violation",
                     "security.repeated_timeout_failures"
                   ])

  @spec maybe_dispatch(event_name(), payload(), metadata()) :: :ok
  def maybe_dispatch(name, payload, metadata)
      when is_binary(name) and is_map(payload) and is_map(metadata) do
    if signal_event?(name) do
      dispatch(name, payload, with_alert_metadata(name, metadata))
    else
      :ok
    end
  rescue
    _error ->
      :ok
  end

  defp signal_event?(name), do: name in Config.alert_signal_events()

  defp with_alert_metadata(name, metadata) do
    metadata
    |> Map.put_new(:alert_event, name)
    |> Map.put_new(:alert_severity, alert_severity(name))
  end

  defp alert_severity(name) do
    if MapSet.member?(@critical_events, name), do: :critical, else: :warning
  end

  defp dispatch(name, payload, metadata) do
    case Config.alert_router() do
      nil ->
        :ok

      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [name, payload, metadata])
        :ok

      {module, function, extra_args}
      when is_atom(module) and is_atom(function) and is_list(extra_args) ->
        apply(module, function, [name, payload, metadata | extra_args])
        :ok

      _ ->
        :ok
    end
  end
end
