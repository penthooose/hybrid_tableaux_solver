defmodule Mix.Tasks.Sts.Solve do
  @shortdoc "Run STS hybrid tableaux CLI from project root"
  @moduledoc """
  Root-level CLI task for the STS solver.

  Examples:

      mix sts.solve --demo
      mix sts.solve "p and not p"
      mix sts.solve --tptp-file .\\tptp_problems\\AGT001+0.ax --llm --tptp-domain-limit 4

  Alias:

      mix solve ...
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    STS.HybridTableauxSolverMain.run_cli(args)
  end
end
