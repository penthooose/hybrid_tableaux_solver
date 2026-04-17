defmodule SimpleTableauxSolver.MixProject do
  use Mix.Project

  def project do
    [
      app: :simple_tableaux_solver,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      escript: [main_module: STS.CLI]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:kino, "~> 0.13"}
    ]
  end

  defp aliases do
    [
      solve: ["sts.solve"]
    ]
  end
end
