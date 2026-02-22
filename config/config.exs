import Config

config :jido_code_server,
  project_id_generator: {JidoCodeServer.ProjectId, :generate, []},
  default_data_dir: ".jido",
  tool_timeout_ms: 30_000,
  tool_timeout_alert_threshold: 3,
  tool_max_output_bytes: 262_144,
  tool_max_artifact_bytes: 131_072,
  llm_timeout_ms: 120_000,
  tool_max_concurrency: 8,
  watcher_debounce_ms: 250
