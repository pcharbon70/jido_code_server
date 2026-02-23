import Config

config :jido_code_server,
  project_id_generator: {Jido.Code.Server.ProjectId, :generate, []},
  default_data_dir: ".jido",
  tool_timeout_ms: 30_000,
  tool_timeout_alert_threshold: 3,
  alert_signal_events: ["security.sandbox_violation", "security.repeated_timeout_failures"],
  alert_router: nil,
  tool_max_output_bytes: 262_144,
  tool_max_artifact_bytes: 131_072,
  network_egress_policy: :deny,
  network_allowlist: [],
  outside_root_allowlist: [],
  tool_env_allowlist: [],
  llm_timeout_ms: 120_000,
  tool_max_concurrency: 8,
  tool_max_concurrency_per_conversation: 4,
  watcher_debounce_ms: 250
