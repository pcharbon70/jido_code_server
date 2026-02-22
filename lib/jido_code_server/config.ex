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

  @spec llm_timeout_ms() :: pos_integer()
  def llm_timeout_ms do
    Application.get_env(@app, :llm_timeout_ms, 120_000)
  end

  @spec tool_max_concurrency() :: pos_integer()
  def tool_max_concurrency do
    Application.get_env(@app, :tool_max_concurrency, 8)
  end
end
