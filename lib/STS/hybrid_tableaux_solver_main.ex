defmodule STS.HybridTableauxSolverMain do
  @moduledoc """
  Console-first launcher for explainable hybrid SAT solving.

  Usage (CLI):
  	elixir hybrid_tableaux_solver_main.ex "forall x in {a,b}: P(x) -> Q(x)"

  Or run demo:
  	elixir hybrid_tableaux_solver_main.ex --demo
  """

  alias STS.{SimpleHybridTableauxSolver, Tableaux, TableauxSolver, TPTPParser}

  @spec run(String.t() | Tableaux.formula(), keyword()) :: map()
  def run(formula_or_input, opts \\ []) do
    input_preview =
      case formula_or_input do
        text when is_binary(text) -> text
        ast -> Tableaux.to_human(ast)
      end

    print_banner()

    IO.puts("Input formula:")
    IO.puts("  #{input_preview}")
    IO.puts("")

    result = SimpleHybridTableauxSolver.solve(formula_or_input, opts)
    print_report(result)
    result
  end

  @spec run_cli([String.t()]) :: :ok
  def run_cli(argv \\ System.argv()) do
    {opts, args, _invalid} =
      OptionParser.parse(argv,
        strict: [
          demo: :boolean,
          llm: :boolean,
          force_llm: :boolean,
          symbolic_debug: :boolean,
          model: :string,
          domain: :string,
          temperature: :float,
          tptp_file: :string,
          tptp_dir: :string,
          tptp_limit: :integer,
          tptp_roles: :string,
          tptp_auto_domain: :boolean,
          tptp_domain_limit: :integer
        ]
      )

    cond do
      Keyword.get(opts, :demo, false) ->
        run_demo(opts)

      is_binary(Keyword.get(opts, :tptp_file)) ->
        run_tptp_file(Keyword.get(opts, :tptp_file), normalize_cli_opts(opts))

      is_binary(Keyword.get(opts, :tptp_dir)) ->
        run_tptp_dir(Keyword.get(opts, :tptp_dir), normalize_cli_opts(opts))

      args == [] ->
        print_usage()

      true ->
        formula = Enum.join(args, " ")
        opts = normalize_cli_opts(opts)
        run(formula, opts)
    end

    :ok
  end

  defp run_tptp_file(path, opts) do
    case TPTPParser.parse_file(path) do
      {:ok, entries} ->
        roles = parse_tptp_roles(Keyword.get(opts, :tptp_roles))
        formula = TPTPParser.to_conjunction(entries, roles: roles)

        constants = TPTPParser.collect_constants(entries)
        tptp_domain_limit = Keyword.get(opts, :tptp_domain_limit, 6)
        tptp_auto_domain = Keyword.get(opts, :tptp_auto_domain, true)

        solver_opts =
          opts
          |> Keyword.delete(:tptp_file)
          |> Keyword.delete(:tptp_dir)
          |> Keyword.delete(:tptp_limit)
          |> Keyword.delete(:tptp_roles)
          |> Keyword.delete(:tptp_auto_domain)
          |> Keyword.delete(:tptp_domain_limit)

        solver_opts =
          if tptp_auto_domain and is_nil(Keyword.get(solver_opts, :domain)) and constants != [] do
            limited_domain = Enum.take(constants, tptp_domain_limit)
            Keyword.put(solver_opts, :domain, limited_domain)
          else
            solver_opts
          end

        IO.puts("Loaded TPTP file: #{path}")
        IO.puts("  formulas parsed: #{length(entries)}")
        IO.puts("  roles included: #{Enum.join(Enum.map(roles, &to_string/1), ", ")}")

        if Keyword.has_key?(solver_opts, :domain) do
          domain = Keyword.get(solver_opts, :domain, [])

          IO.puts(
            "  auto-domain size: #{length(domain)} (from #{length(constants)} constants; limit=#{tptp_domain_limit})"
          )
        end

        IO.puts("")
        run(formula, solver_opts)

      {:error, reason} ->
        IO.puts("Failed to parse TPTP file #{path}: #{reason}")
    end
  end

  defp run_tptp_dir(dir, opts) do
    limit = Keyword.get(opts, :tptp_limit, 3)

    files =
      dir
      |> Path.join("*.ax")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.take(limit)

    if files == [] do
      IO.puts("No .ax files found in #{dir}")
    else
      IO.puts("Running #{length(files)} TPTP file(s) from #{dir}")

      Enum.each(files, fn path ->
        IO.puts("\n" <> String.duplicate("=", 72))
        run_tptp_file(path, opts)
      end)
    end
  end

  defp parse_tptp_roles(nil), do: [:axiom]

  defp parse_tptp_roles(raw) when is_binary(raw) do
    raw
    |> String.split([",", ";"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.to_atom(String.downcase(&1)))
    |> case do
      [] -> [:axiom]
      roles -> roles
    end
  end

  defp normalize_cli_opts(opts) do
    case Keyword.get(opts, :domain) do
      nil ->
        opts

      raw when is_binary(raw) ->
        domain =
          raw
          |> String.split([",", ";"], trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        opts
        |> Keyword.delete(:domain)
        |> Keyword.put(:domain, domain)
    end
  end

  defp run_demo(opts) do
    examples = [
      "p and not p",
      "forall x in {a,b}: P(x) -> Q(x)",
      "exists x in {a,b,c}: P(x) and not Q(x)",
      "(p or q) and (not p or r) and (not q or r)"
    ]

    Enum.each(examples, fn formula ->
      IO.puts("\n" <> String.duplicate("=", 72))
      run(formula, opts)
    end)
  end

  defp print_report(result) do
    print_route(result)
    print_metrics(result)
    print_llm_status(result)
    print_applied_tactics(result)
    print_symbolic_result(result)
    print_trace(result)
    print_timings(result)
  end

  defp print_route(result) do
    IO.puts("Routing decision:")
    IO.puts("  #{route_label(result.route)}")
    IO.puts("")
  end

  defp route_label(:symbolic_only), do: "symbolic_only (tableaux only)"

  defp route_label(:hybrid_llm_guided),
    do: "hybrid_llm_guided (LLM guidance + symbolic verification)"

  defp route_label(:hybrid_fallback),
    do: "hybrid_fallback (LLM failed/skipped, local heuristic + symbolic verification)"

  defp route_label(other), do: to_string(other)

  defp print_metrics(%{candidate: %{candidate?: candidate?, metrics: metrics}}) do
    IO.puts("Complexity / hybrid candidacy:")
    IO.puts("  candidate?: #{candidate?}")
    IO.puts("  node_count: #{Map.get(metrics, :node_count, "-")}")
    IO.puts("  atom_count: #{Map.get(metrics, :atom_count, "-")}")
    IO.puts("  quantifier_count: #{Map.get(metrics, :quantifier_count, "-")}")
    IO.puts("")
  end

  defp print_metrics(_result) do
    IO.puts("Complexity / hybrid candidacy:")
    IO.puts("  unavailable")
    IO.puts("")
  end

  defp print_llm_status(%{llm: llm}) do
    IO.puts("LLM guidance:")
    IO.puts("  attempted: #{llm.attempted}")
    IO.puts("  used: #{llm.used}")
    IO.puts("  status: #{llm.status}")

    if llm.model, do: IO.puts("  model: #{llm.model}")
    if llm.reason, do: IO.puts("  reason: #{llm.reason}")

    print_guidance_highlights(llm.guidance)
    IO.puts("")
  end

  defp print_guidance_highlights(nil) do
    IO.puts("  guidance highlights: none")
  end

  defp print_guidance_highlights(%{parsed: parsed}) when is_map(parsed) do
    IO.puts("  guidance highlights:")

    parsed
    |> Map.take([
      "decomposition_plan",
      "branching_hints",
      "quantifier_hints",
      "external_oracle_hints",
      "confidence"
    ])
    |> Enum.each(fn
      {key, values} when is_list(values) ->
        Enum.each(values, fn item -> IO.puts("    - #{key}: #{item}") end)

      {key, value} ->
        IO.puts("    - #{key}: #{inspect(value)}")
    end)
  end

  defp print_guidance_highlights(%{raw: raw}) when is_binary(raw) do
    IO.puts("  guidance highlights:")
    IO.puts("    - raw: #{String.slice(raw, 0, 250)}")
  end

  defp print_guidance_highlights(_), do: IO.puts("  guidance highlights: none")

  defp print_applied_tactics(%{applied_tactics: tactics}) when is_map(tactics) do
    IO.puts("Applied symbolic tactics:")

    if map_size(tactics) == 0 do
      IO.puts("  none")
    else
      Enum.each(tactics, fn {k, v} ->
        IO.puts("  #{k}: #{inspect(v)}")
      end)
    end

    IO.puts("")
  end

  defp print_applied_tactics(_result) do
    IO.puts("Applied symbolic tactics:")
    IO.puts("  none")
    IO.puts("")
  end

  defp print_symbolic_result(%{symbolic: symbolic}) do
    IO.puts("Symbolic verification result:")
    IO.puts("  " <> String.replace(TableauxSolver.format_result(symbolic), "\n", "\n  "))

    if is_map(symbolic.model) and map_size(symbolic.model) > 0 do
      true_entries =
        symbolic.model
        |> Enum.filter(fn {_atom, truth} -> truth end)
        |> Enum.sort_by(&elem(&1, 0))

      false_count =
        symbolic.model
        |> Enum.count(fn {_atom, truth} -> not truth end)

      IO.puts(
        "  assignment summary: true=#{length(true_entries)}, false=#{false_count}, total=#{map_size(symbolic.model)}"
      )

      if true_entries != [] do
        max_show = 80
        shown = Enum.take(true_entries, max_show)

        IO.puts("  true assignments:")

        Enum.each(shown, fn {atom, truth} ->
          IO.puts("    - #{atom} => #{truth}")
        end)

        remaining = length(true_entries) - length(shown)

        if remaining > 0 do
          IO.puts("    ... #{remaining} more true assignments omitted")
        end
      end

      if false_count > 0 do
        IO.puts("  note: false assignments are hidden for readability")
      end
    end

    IO.puts("")
  end

  defp print_trace(%{explain_steps: steps}) when is_list(steps) do
    IO.puts("Explainable trace:")

    Enum.each(steps, fn step ->
      level = step.level |> to_string() |> String.upcase()
      IO.puts("  [#{step.index}] #{level} — #{step.title}")
      IO.puts("      #{step.detail}")
    end)

    IO.puts("")
  end

  defp print_trace(_), do: :ok

  defp print_timings(%{timings_ms: t}) do
    IO.puts("Timing (ms):")
    IO.puts("  llm: #{Map.get(t, :llm, "-")}")
    IO.puts("  symbolic: #{Map.get(t, :symbolic, "-")}")
    IO.puts("  total: #{Map.get(t, :total, "-")}")
    IO.puts("")
  end

  defp print_banner do
    IO.puts("Simple Hybrid Tableaux Solver")
    IO.puts(String.duplicate("-", 72))
  end

  defp print_usage do
    IO.puts("Usage:")
    IO.puts("  mix sts.solve \"<FORMULA>\" [options]")
    IO.puts("  mix solve \"<FORMULA>\" [options]")
    IO.puts("")
    IO.puts("Options:")
    IO.puts("  --demo                  Run built-in demo formulas")
    IO.puts("  --llm / --no-llm        Enable/disable OpenRouter guidance")
    IO.puts("  --force-llm             Force LLM guidance even for small formulas")
    IO.puts("  --symbolic-debug        Print internal tableaux expansion logs")

    IO.puts(
      "  --model <name>          OpenRouter model (default: OPENROUTER_MODEL or anthropic/claude-sonnet-4.6)"
    )

    IO.puts("  --domain a,b,c          Default quantifier domain if none specified")
    IO.puts("  --temperature <float>   LLM temperature")
    IO.puts("  --tptp-file <path>      Parse and run one TPTP .ax file")
    IO.puts("  --tptp-dir <dir>        Parse and run .ax files from directory")
    IO.puts("  --tptp-limit <n>        Number of files for --tptp-dir (default: 3)")
    IO.puts("  --tptp-roles a,b,c      Roles to include (default: axiom)")
    IO.puts("  --tptp-auto-domain      Auto-build finite domain from constants (default: true)")
    IO.puts("  --tptp-domain-limit <n> Max constants used for auto-domain (default: 6)")
    IO.puts("")
    IO.puts("Example:")
    IO.puts("  mix solve \"forall x in {a,b}: P(x) -> Q(x)\" --llm")

    IO.puts("  mix solve --tptp-file .\\tptp_problems\\AGT001+0.ax --force-llm")
  end
end
