# Simple Hybrid Tableaux Solver — Manual

This project demonstrates a **hybrid SAT-style reasoning workflow** in Elixir:

- a **symbolic tableaux core** (`STS.TableauxSolver`) gives the final SAT/UNSAT answer,
- an optional **OpenRouter LLM guidance layer** suggests decomposition/branching hints,
- all final results are still **truth-grounded by symbolic verification**.

---

## 1) Modules and roles

### `tableaux.ex`

Defines the first-order logic AST and utilities:

- terms: `{:var, x}`, `{:const, c}`
- formulas: `:top`, `:bot`, `:pred`, `:not`, `:and`, `:or`, `:implies`, `:iff`, `:forall`, `:exists`
- pretty printer and substitution.

### `tableaux_solver.ex`

Symbolic solver with:

- human-readable parser (`forall`, `exists`, `and`, `or`, `not`, `->`, `<->`)
- normalization (`implication-elimination`, NNF, quantifier expansion on finite domains)
- tableaux SAT/UNSAT search
- result formatter.

### `hybrid_orchestrator.ex`

Hybrid controller:

- evaluates if a formula is a hybrid candidate,
- optionally calls OpenRouter for heuristic guidance,
- falls back to local deterministic guidance if LLM is unavailable,
- always runs symbolic verification and returns explainable trace steps.

### `simple_hybrid_tableaux_solver.ex`

Small public API facade for easier usage in scripts/livebooks.

### `hybrid_tableaux_solver_main.ex`

Explainable CLI/main launcher:

- route decision,
- complexity metrics,
- LLM status,
- symbolic verification output,
- step-by-step trace,
- timing summary.

---

## 2) Environment setup

Set this variable in your runtime environment:

- `OPENROUTER_API_KEY`
- `OPENROUTER_MODEL` (optional; defaults to `anthropic/claude-sonnet-4.6`)

For local development, keep it in `.env` (never commit real keys to public repos).

The solver now reads these from system env **or** local `.env`.

---

## 3) Core philosophy (important)

The LLM is a **strategy advisor**, not the truth oracle.

1. Parse + normalize formula.
2. Optionally ask LLM for decomposition hints.
3. Run tableaux solver.
4. Return SAT/UNSAT from the symbolic engine.

This is the XAI-friendly path: suggestions are visible, but correctness remains verifiable.

---

## 4) CLI usage examples

Run from the `simple_tableaux_solver` folder.

Recommended in Mix mode:

- `mix sts.solve ...` (or alias `mix solve ...`)
- do **not** run files directly from `lib/` with `elixir lib/...`.

Optional escript mode:

- `mix escript.build`
- run generated executable from project root.

### Example A — quick contradiction

`mix solve "p and not p"`

### Example B — quantified formula

`mix solve "forall x in {a,b}: P(x) -> Q(x)"`

### Example C — force LLM guidance

`mix solve "(p or q) and (not p or r) and (not q or r)" --force-llm --llm`

### Example D — custom model

`mix solve "exists x in {a,b,c}: P(x) and not Q(x)" --model mistralai/mistral-small-3.1-24b-instruct`

### Example D2 — use `.env` model automatically

If `.env` contains `OPENROUTER_MODEL=anthropic/claude-sonnet-4.6`, then this uses that model automatically:

`mix solve "p" --force-llm`

### Example E — provide default domain

`mix solve "forall x: P(x) -> Q(x)" --domain a,b,c`

### Example F — symbolic trace noise on

`mix solve "(p or q) and not p" --symbolic-debug`

### Example G — demo mode

`mix solve --demo`

---

## 5) API usage examples (Elixir)

Load files:

`Code.require_file("tableaux.ex", __DIR__)`

`Code.require_file("tableaux_solver.ex", __DIR__)`

`Code.require_file("hybrid_orchestrator.ex", __DIR__)`

`Code.require_file("simple_hybrid_tableaux_solver.ex", __DIR__)`

### Example 1 — symbolic only

`STS.SimpleHybridTableauxSolver.solve_symbolic("p and not p")`

### Example 2 — full hybrid solve

`STS.SimpleHybridTableauxSolver.solve("forall x in {a,b}: P(x) -> Q(x)", llm: true)`

### Example 3 — ask candidate heuristic only

`STS.SimpleHybridTableauxSolver.hybrid_candidate?("(p or q) and (r or s)")`

### Example 4 — explicit key/model override

`STS.SimpleHybridTableauxSolver.solve("exists x in {a,b}: P(x)", openrouter_api_key: System.get_env("OPENROUTER_API_KEY"), model: "openai/gpt-4o-mini")`

### Example 5 — fallback path (disable llm)

`STS.SimpleHybridTableauxSolver.solve("forall x: P(x)", llm: false, domain: ["a", "b"])`

---

## 6) Livebook integration: UI vs API?

Short answer: **both are good**.

### Recommended near-term approach

Use the solver as an API from Livebook cells first (fastest, stable).

- You can show outputs/tables/trace in notebook cells.
- Great for teaching and reproducibility.

### Optional richer UI in Livebook

Yes, you can build UI controls with `Kino`:

- formula text input
- checkbox for LLM on/off
- model dropdown
- run button
- output panel for trace and verdict.

That gives a mini explainable SAT workbench inside Livebook.

---

## 7) Livebook examples

### Example L1 — minimal API cell

1. Require files.
2. Call `STS.SimpleHybridTableauxSolver.solve/2`.
3. Render result map.

### Example L2 — side-by-side symbolic vs hybrid

- left result: `solve_symbolic/2`
- right result: `solve/2`
- compare route, timings, and guidance.

### Example L3 — explainable report cell

- print `result.explain_steps`
- show `result.symbolic.human_formula`
- show sorted model assignment.

### Example L4 — classroom challenge set

Run batch formulas and collect:

- satisfiable? (boolean)
- route used
- node/atom/quantifier metrics
- total runtime.

### Example L5 — oracle extension stub

After symbolic result, add a cell that sends selected hard cases to external ATP/SMT oracle.

---

## 8) Explainable console output coverage

`hybrid_tableaux_solver_main.ex` reports:

- routing decision (symbolic/hybrid/fallback)
- complexity metrics
- LLM status (attempted/used/fallback + reason)
- guidance highlights (if available)
- symbolic SAT/UNSAT verdict + assignment
- indexed trace steps with details
- timing breakdown (LLM/symbolic/total).

---

## 9) Notes for GitHub + module import

Yes, your plan works:

1. Upload project to GitHub.
2. Import in Livebook.
3. Set `OPENROUTER_API_KEY` in Livebook runtime env/secrets.
4. Use module API (and optionally a Kino UI wrapper).

For a research/class setup, API-first + optional UI controls is usually the best compromise.

---

## 10) `solver_gui.ex` (Kino playground)

`solver_gui.ex` is now implemented as a **Livebook/Kino playground layer**.

- It is **not** the core solver.
- It wraps the API from `STS.SimpleHybridTableauxSolver`.
- It gracefully falls back to API mode when Kino is unavailable.

### Livebook usage

In a Livebook code cell:

`Mix.install([{:simple_tableaux_solver, github: "penthooose/Simple_hybrid_tableaux_solver"}])`

`STS.SolverGUI.start()`

This renders a small interface with:

- formula input,
- llm / force-llm toggles,
- symbolic debug toggle,
- model + temperature fields,
- default domain field,
- run button,
- formatted explainable output.

### Non-Livebook/API usage

`Code.require_file("solver_gui.ex", __DIR__)`

    STS.SolverGUI.solve("p and not p", llm: false)

`STS.SolverGUI.to_text_report(result)`

---

## 11) TPTP `.ax` integration (real-world benchmarks)

The project now includes `tptp_parser.ex` and supports parsing a practical subset of TPTP FOF files.

### What is supported

- `fof(Name, Role, Formula).`
- quantifiers: `! [X,...] : ...`, `? [X,...] : ...`
- connectives: `~`, `&`, `|`, `=>`, `<=`, `<=>`
- predicates and terms (constants, variables, function terms)

### Important limitation

TPTP FOF theorem proving is generally a **different and more expressive setting** than this simplified finite-domain tableaux demo.

So current behavior is a **bridge/approximation**, not a full ATP replacement:

- formulas are parsed,
- selected roles are conjoined,
- optional finite grounding domain is built from constants,
- then your existing tableaux engine is run.

For complete FOL ATP-level correctness on all TPTP problems, use a dedicated solver backend (e.g., Vampire, E, Leo-III, cvc5).

### CLI examples

Single file:

`mix solve --tptp-file .\\tptp_problems\\AGT001+0.ax --no-llm`

Single file with LLM:

`mix solve --tptp-file .\\tptp_problems\\AGT001+0.ax --llm`

Folder batch (first 3 files):

`mix solve --tptp-dir .\\tptp_problems --tptp-limit 3 --no-llm`

Use specific roles:

`mix solve --tptp-file .\\tptp_problems\\AGT001+0.ax --tptp-roles axiom,conjecture`

Control finite grounding size:

`mix solve --tptp-file .\\tptp_problems\\AGT001+0.ax --tptp-domain-limit 8`

---

## 12) When is the LLM invoked?

Current rule:

- `--no-llm` -> never
- `--force-llm` -> always
- auto mode (`--llm` or default allowed): invoke when formula is non-trivial, e.g.
  - parser heuristic marks candidate complex, **or**
  - quantifiers are present, **or**
  - node/atom complexity passes moderate thresholds.

This keeps small trivial formulas fast while still using LLM guidance for meaningful reasoning cases.

---

## 13) How LLM guidance is used by solver (machine-applied)

Guidance is not only printed for humans anymore.

- The orchestrator extracts a `solver_tactics` block from LLM JSON (or infers tactics from hints).
- It maps this to symbolic options (currently branch ordering strategy, e.g. `:close_fast`).
- The symbolic tableaux engine applies that tactic while exploring disjunction branches.

So LLM guidance now has an executable effect on search behavior while final correctness remains symbolic.
