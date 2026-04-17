defmodule STS.SimpleHybridTableauxSolver do
  @moduledoc """
  Public API facade for the hybrid tableaux demonstrator.

  This module keeps the surface area small while delegating orchestration to
  `STS.HybridOrchestrator` and symbolic checks to `STS.TableauxSolver`.
  """

  alias STS.{HybridOrchestrator, TableauxSolver}

  @spec solve(String.t() | Tableaux.formula(), keyword()) :: HybridOrchestrator.result()
  def solve(formula_or_input, opts \\ []) do
    HybridOrchestrator.run(formula_or_input, opts)
  end

  @spec solve_symbolic(String.t() | Tableaux.formula(), keyword()) ::
          TableauxSolver.solve_result()
  def solve_symbolic(formula_or_input, opts \\ []) do
    TableauxSolver.solve(formula_or_input, opts)
  end

  @spec hybrid_candidate?(String.t() | Tableaux.formula(), keyword()) ::
          {:ok, %{candidate?: boolean(), metrics: map()}} | {:error, String.t()}
  def hybrid_candidate?(formula_or_input, opts \\ []) do
    TableauxSolver.hybrid_candidate?(formula_or_input, opts)
  end
end
