defmodule Llmgateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :llmgateway,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        llmgateway: [
          strip_beams: true
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Llmgateway.Application, []}
    ]
  end


  defp deps do
    [
      {:req, "~> 0.5"},
      {:llm_db, "~> 2026.0"},
      {:yaml_elixir, "~> 2.11"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:mox, "~> 1.2", only: :test}
    ]
  end
end