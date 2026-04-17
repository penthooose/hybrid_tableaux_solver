defmodule STS.SolverGUI do
  @moduledoc """
  Livebook/Kino playground for the hybrid tableaux solver.

  This is NOT a replacement for the API modules:
  - Use `STS.SimpleHybridTableauxSolver` for API calls.
  - Use this module for an interactive notebook UI.

  Works best inside Livebook. Outside Livebook, it gracefully returns usage hints.
  """

  alias STS.SimpleHybridTableauxSolver

  @default_formula "forall x in {a,b}: P(x) -> Q(x)"
  @default_model "openai/gpt-4o-mini"

  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Kino)

  @doc """
  API-first execution helper (works anywhere, no Kino needed).
  """
  @spec solve(String.t(), keyword()) :: map()
  def solve(formula, opts \\ []) when is_binary(formula) do
    SimpleHybridTableauxSolver.solve(formula, opts)
  end

  @doc """
  Starts an interactive Kino playground inside Livebook.

  Returns:
  - `{:ok, layout}` in Livebook with Kino available
  - `{:error, message}` otherwise
  """
  @spec start(keyword()) :: {:ok, any()} | {:error, String.t()}
  def start(opts \\ []) do
    if available?() do
      {:ok, build_playground(opts)}
    else
      {:error, no_kino_message()}
    end
  end

  @doc """
  Alias for `start/1`.
  """
  @spec start_playground(keyword()) :: {:ok, any()} | {:error, String.t()}
  def start_playground(opts \\ []), do: start(opts)

  @doc """
  Quick examples for API mode (good for scripts/tests).
  """
  @spec example_calls() :: [map()]
  def example_calls do
    [
      solve("p and not p", llm: false),
      solve("forall x in {a,b}: P(x) -> Q(x)", llm: false),
      solve("exists x in {a,b,c}: P(x) and not Q(x)", llm: false)
    ]
  end

  @doc """
  Human-readable result string for API/console contexts.
  """
  @spec to_text_report(map()) :: String.t()
  def to_text_report(result) when is_map(result) do
    symbolic = result[:symbolic] || %{}

    [
      "route: #{Map.get(result, :route, "-")}",
      "status: #{get_in(symbolic, [:status]) || "-"}",
      "formula: #{get_in(symbolic, [:human_formula]) || "-"}",
      "llm_status: #{get_in(result, [:llm, :status]) || "-"}",
      "timings_ms: #{inspect(Map.get(result, :timings_ms, %{}))}"
    ]
    |> Enum.join("\n")
  end

  # -------------------------
  # Internal Kino Playground
  # -------------------------

  defp build_playground(opts) do
    form = build_form(opts)
    output = kino_frame_new()

    kino_frame_render(
      output,
      kino_markdown("## Hybrid Tableaux Playground\nFill the form and click **Run Solver**.")
    )

    kino_control_listen(form, fn event ->
      data = Map.get(event, :data, %{})

      formula = Map.get(data, :formula, @default_formula)

      solver_opts =
        []
        |> put_if(:llm, Map.get(data, :llm, true))
        |> put_if(:force_llm, Map.get(data, :force_llm, false))
        |> put_if(:symbolic_debug, Map.get(data, :symbolic_debug, false))
        |> put_if(:model, normalize_string(Map.get(data, :model, @default_model)))
        |> put_if(:temperature, parse_float(Map.get(data, :temperature, "0.2")))
        |> put_if(:domain, parse_domain(Map.get(data, :default_domain, "")))

      result = solve(formula, solver_opts)
      md = render_result_markdown(result, formula, solver_opts)
      kino_frame_render(output, kino_markdown(md))
    end)

    kino_layout_grid([form, output], columns: 1)
  end

  defp build_form(opts) do
    default_formula = Keyword.get(opts, :formula, @default_formula)
    default_model = Keyword.get(opts, :model, default_model())
    default_domain = Keyword.get(opts, :domain, "")

    fields = [
      formula: kino_input_textarea("Formula", default: default_formula),
      llm: kino_input_checkbox("Use LLM guidance", default: Keyword.get(opts, :llm, true)),
      force_llm:
        kino_input_checkbox(
          "Force LLM guidance",
          default: Keyword.get(opts, :force_llm, false)
        ),
      symbolic_debug:
        kino_input_checkbox(
          "Symbolic debug",
          default: Keyword.get(opts, :symbolic_debug, false)
        ),
      model: kino_input_text("OpenRouter model", default: default_model),
      temperature: kino_input_text("Temperature", default: "0.2"),
      default_domain:
        kino_input_text("Default domain (comma-separated)", default: to_string(default_domain))
    ]

    kino_control_form(fields, submit: "Run Solver")
  end

  defp render_result_markdown(result, formula, solver_opts) do
    symbolic = Map.get(result, :symbolic, %{})
    llm = Map.get(result, :llm, %{})
    tactics = Map.get(result, :applied_tactics, %{})
    metrics = get_in(result, [:candidate, :metrics]) || %{}
    steps = Map.get(result, :explain_steps, [])
    timings = Map.get(result, :timings_ms, %{})

    steps_md =
      steps
      |> Enum.map(fn s ->
        "- **[#{s.index}] #{String.upcase(to_string(s.level))}** #{s.title} — #{s.detail}"
      end)
      |> Enum.join("\n")

    model_md =
      case Map.get(symbolic, :model) do
        model when is_map(model) and map_size(model) > 0 ->
          model
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {k, v} -> "- `#{k}` => `#{v}`" end)
          |> Enum.join("\n")

        _ ->
          "- (empty or unsat)"
      end

    """
    ## Hybrid Solver Result

    ### Input
    - Formula: `#{formula}`
    - Options: `#{inspect(solver_opts)}`

    ### Routing
    - Route: `#{Map.get(result, :route, "-")}`
    - LLM attempted: `#{Map.get(llm, :attempted, false)}`
    - LLM used: `#{Map.get(llm, :used, false)}`
    - LLM status: `#{Map.get(llm, :status, "-")}`
    - LLM reason: `#{Map.get(llm, :reason, "-")}`
    - Applied tactics: `#{inspect(tactics)}`

    ### Symbolic Verdict
    - Status: `#{Map.get(symbolic, :status, "-")}`
    - Human formula: `#{Map.get(symbolic, :human_formula, "-")}`

    ### Complexity Metrics
    - Node count: `#{Map.get(metrics, :node_count, "-")}`
    - Atom count: `#{Map.get(metrics, :atom_count, "-")}`
    - Quantifier count: `#{Map.get(metrics, :quantifier_count, "-")}`

    ### Model Assignment
    #{model_md}

    ### Explainable Trace
    #{if steps_md == "", do: "- (no steps)", else: steps_md}

    ### Timings (ms)
    - llm: `#{Map.get(timings, :llm, "-")}`
    - symbolic: `#{Map.get(timings, :symbolic, "-")}`
    - total: `#{Map.get(timings, :total, "-")}`
    """
  end

  # -------------------------
  # Generic helpers
  # -------------------------

  defp parse_domain(text) when is_binary(text) do
    text
    |> String.split([",", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      xs -> xs
    end
  end

  defp parse_domain(_), do: nil

  defp default_model do
    System.get_env("OPENROUTER_MODEL") ||
      read_env_file_var(Path.expand("../../.env", __DIR__), "OPENROUTER_MODEL") ||
      read_env_file_var(Path.join(__DIR__, ".env"), "OPENROUTER_MODEL") || @default_model
  end

  defp read_env_file_var(path, key) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         line when is_binary(line) <-
           Enum.find(String.split(content, ["\n", "\r\n"], trim: true), fn line ->
             String.starts_with?(String.trim(line), "#{key}=")
           end) do
      line
      |> String.trim()
      |> String.trim_leading("#{key}=")
      |> String.trim()
      |> String.trim_leading("\"")
      |> String.trim_trailing("\"")
      |> case do
        "" -> nil
        value -> value
      end
    else
      _ -> nil
    end
  end

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value / 1

  defp parse_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {v, _} -> v
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp normalize_string(nil), do: nil
  defp normalize_string(v) when is_binary(v), do: String.trim(v)
  defp normalize_string(v), do: to_string(v)

  defp put_if(opts, _k, nil), do: opts
  defp put_if(opts, _k, ""), do: opts
  defp put_if(opts, k, v), do: Keyword.put(opts, k, v)

  # -------------------------
  # Dynamic Kino wrappers
  # -------------------------

  defp kino_markdown(text), do: apply(Module.concat(Kino, Markdown), :new, [text])
  defp kino_frame_new(), do: apply(Module.concat(Kino, Frame), :new, [])

  defp kino_frame_render(frame, content),
    do: apply(Module.concat(Kino, Frame), :render, [frame, content])

  defp kino_layout_grid(items, opts),
    do: apply(Module.concat(Kino, Layout), :grid, [items, opts])

  defp kino_control_form(fields, opts),
    do: apply(Module.concat([Kino, Control]), :form, [fields, opts])

  defp kino_control_listen(control, callback),
    do: apply(Module.concat([Kino, Control]), :listen, [control, callback])

  defp kino_input_text(label, opts),
    do: apply(Module.concat([Kino, Input]), :text, [label, opts])

  defp kino_input_textarea(label, opts),
    do: apply(Module.concat([Kino, Input]), :textarea, [label, opts])

  defp kino_input_checkbox(label, opts),
    do: apply(Module.concat([Kino, Input]), :checkbox, [label, opts])

  defp no_kino_message do
    """
    Kino UI is unavailable in this runtime.

    To use GUI locally on Windows:
    1) Start Livebook locally.
    2) In a Livebook cell, run:
       Mix.install([{:simple_tableaux_solver, github: "penthooose/Simple_hybrid_tableaux_solver"}])
    3) Run `STS.SolverGUI.start()`.

    API mode remains available via:
    	STS.SolverGUI.solve("p and not p", llm: false)
    """
    |> String.trim()
  end
end
