defmodule JidoCodeServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :jido_code_server,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {JidoCodeServer.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jido_action, github: "agentjido/jido_action", branch: "main"},
      {:jido_ai, github: "agentjido/jido_ai", branch: "main"},
      {:jido_signal, "~> 1.0"},
      {:jido_workspace, git: "https://github.com/agentjido/jido_workspace.git", branch: "main"},
      {:jido_conversation, git: "https://github.com/pcharbon70/jido_conversation.git", branch: "main"},
      {:jido_workflow, git: "https://github.com/pcharbon70/jido_workflow.git", branch: "main"},
      {:jido_command, git: "https://github.com/pcharbon70/jido_command.git", branch: "main"},
      {:jido_skill, git: "https://github.com/pcharbon70/jido_skill.git", branch: "main"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      q: ["quality"],
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test",
        "dialyzer"
      ]
    ]
  end
end
