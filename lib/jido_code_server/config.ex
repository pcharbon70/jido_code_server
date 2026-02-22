defmodule JidoCodeServer.Config do
  @moduledoc """
  Accessors for runtime configuration defaults used by scaffolding modules.
  """

  @app :jido_code_server

  @spec project_id_generator() :: {module(), atom(), list()}
  def project_id_generator do
    Application.get_env(@app, :project_id_generator, {JidoCodeServer.ProjectId, :generate, []})
  end

  @spec default_data_dir() :: String.t()
  def default_data_dir do
    Application.get_env(@app, :default_data_dir, ".jido")
  end

  @spec tool_timeout_ms() :: pos_integer()
  def tool_timeout_ms do
    Application.get_env(@app, :tool_timeout_ms, 30_000)
  end

  @spec tool_timeout_alert_threshold() :: pos_integer()
  def tool_timeout_alert_threshold do
    Application.get_env(@app, :tool_timeout_alert_threshold, 3)
  end

  @spec tool_max_output_bytes() :: pos_integer()
  def tool_max_output_bytes do
    Application.get_env(@app, :tool_max_output_bytes, 262_144)
  end

  @spec tool_max_artifact_bytes() :: pos_integer()
  def tool_max_artifact_bytes do
    Application.get_env(@app, :tool_max_artifact_bytes, 131_072)
  end

  @spec network_egress_policy() :: :allow | :deny
  def network_egress_policy do
    Application.get_env(@app, :network_egress_policy, :deny)
  end

  @spec network_allowlist() :: [String.t()]
  def network_allowlist do
    Application.get_env(@app, :network_allowlist, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  @spec llm_timeout_ms() :: pos_integer()
  def llm_timeout_ms do
    Application.get_env(@app, :llm_timeout_ms, 120_000)
  end

  @spec tool_max_concurrency() :: pos_integer()
  def tool_max_concurrency do
    Application.get_env(@app, :tool_max_concurrency, 8)
  end

  @spec strict_asset_loading() :: boolean()
  def strict_asset_loading do
    Application.get_env(@app, :strict_asset_loading, false)
  end

  @spec watcher_debounce_ms() :: pos_integer()
  def watcher_debounce_ms do
    Application.get_env(@app, :watcher_debounce_ms, 250)
  end
end
