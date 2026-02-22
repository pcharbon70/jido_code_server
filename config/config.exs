import Config

config :jido_code_server,
  project_id_generator: {JidoCodeServer.ProjectId, :generate, []},
  default_data_dir: ".jido",
  tool_timeout_ms: 30_000,
  llm_timeout_ms: 120_000,
  tool_max_concurrency: 8
