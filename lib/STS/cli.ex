defmodule STS.CLI do
  @moduledoc """
  Escript entrypoint for root-level CLI execution.

  Build once:

      mix escript.build

  Then run from project root:

      ./simple_tableaux_solver --demo
  """

  @spec main([String.t()]) :: :ok
  def main(argv) do
    STS.HybridTableauxSolverMain.run_cli(argv)
  end
end
