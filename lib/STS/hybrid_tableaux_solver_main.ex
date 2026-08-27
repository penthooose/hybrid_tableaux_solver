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
    print_report(result, opts)
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
          strict_hybrid: :boolean,
          symbolic_validate: :boolean,
          symbolic_debug: :boolean,
          show_symbolic_steps: :boolean,
          symbolic_steps_compact: :boolean,
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

        formula =
          if :conjecture in roles or :negated_conjecture in roles do
            # Explicit role set already contains the conjecture — keep it as-is.
            TPTPParser.to_conjunction(entries, roles: roles)
          else
            # Default: prove the conjecture by negating it (refutation).
            TPTPParser.add_conjecture(
              TPTPParser.to_conjunction(entries, roles: roles),
              entries
            )
          end

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
        result = run(formula, solver_opts)

        final_status = get_in(result, [:symbolic_execution, :final_status])

        has_conjecture =
          Enum.any?(entries, &(&1.role in [:conjecture, :negated_conjecture]))

        print_szs_status(final_status, has_conjecture)

      {:error, reason} ->
        IO.puts("Failed to parse TPTP file #{path}: #{reason}")
    end
  end

  # Emit a machine-readable SZS status line (the benchmark runner parses this):
  #   unsat on a (negated) conjecture -> Unsatisfiable (theorem proven)
  #   sat on a conjecture problem     -> GaveUp (could not refute — incomplete)
  #   sat on plain satisfiability     -> Satisfiable
  defp print_szs_status(final_status, has_conjecture) do
    status =
      cond do
        final_status == :unsat ->
          "Unsatisfiable"

        final_status == :sat and has_conjecture ->
          "GaveUp"

        final_status == :sat ->
          "Satisfiable"

        true ->
          "GaveUp"
      end

    IO.puts("")
    IO.puts("% SZS status #{status}")
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

  # Default premise roles (everything except the conjecture, which is handled
  # separately via refutation when no explicit role set is given).
  defp parse_tptp_roles(nil), do: [:axiom, :hypothesis, :assumption, :definition, :lemma]

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

  defp print_report(result, opts) do
    print_route(result)
    print_metrics(result)
    print_llm_status(result)
    print_applied_tactics(result)
    print_execution_plan_audit(result)
    print_llm_raw_output(result)
    print_symbolic_result(result)
    print_symbolic_execution(result)
    print_validation(result)
    print_trace(result)
    print_timings(result)
    print_model_assignment(result)
    print_symbolic_steps(result, opts)
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

  defp route_label(:llm_only_unverified),
    do: "llm_only_unverified (LLM-guided run without symbolic final verification)"

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

  defp print_applied_tactics(%{applied_tactics: tactics} = result) when is_map(tactics) do
    IO.puts("Applied symbolic tactics:")

    if map_size(tactics) == 0 do
      IO.puts("  none")
    else
      Enum.each(tactics, fn {k, v} ->
        IO.puts("  #{k}: #{inspect(v)}")

        case {k, v} do
          {:branch_priority, mode} ->
            IO.puts("    -> used for OR-branch ordering in tableaux search (mode=#{mode})")

          _ ->
            :ok
        end
      end)
    end

    print_tactic_usage_audit(result)

    IO.puts("")
  end

  defp print_applied_tactics(_result) do
    IO.puts("Applied symbolic tactics:")
    IO.puts("  none")
    print_tactic_usage_audit(%{})
    IO.puts("")
  end

  defp print_tactic_usage_audit(%{llm_usage: usage}) when is_map(usage) do
    applied = Map.get(usage, :applied, [])
    ignored = Map.get(usage, :ignored, [])

    IO.puts("LLM output usage mapping:")

    if applied == [] do
      IO.puts("  applied: none")
    else
      Enum.each(applied, fn line -> IO.puts("  applied: #{line}") end)
    end

    if ignored == [] do
      IO.puts("  ignored: none")
    else
      Enum.each(ignored, fn line -> IO.puts("  ignored: #{line}") end)
    end
  end

  defp print_tactic_usage_audit(_result) do
    IO.puts("LLM output usage mapping:")
    IO.puts("  applied: none")
    IO.puts("  ignored: none")
  end

  defp print_execution_plan_audit(%{execution_plan_audit: audit}) when is_list(audit) do
    IO.puts("Execution plan replay audit:")

    if audit == [] do
      IO.puts("  none")
    else
      Enum.each(audit, fn step ->
        IO.puts(
          "  [#{Map.get(step, :index, "?")}] #{Map.get(step, :action, :unknown)} -> #{Map.get(step, :status, :unknown)}"
        )

        IO.puts("      #{Map.get(step, :detail, "-")}")
      end)
    end

    IO.puts("")
  end

  defp print_execution_plan_audit(_result) do
    IO.puts("Execution plan replay audit:")
    IO.puts("  unavailable")
    IO.puts("")
  end

  defp print_llm_raw_output(%{llm: llm}) do
    IO.puts("LLM model output (verbatim):")

    case get_in(llm, [:guidance, :raw]) do
      raw when is_binary(raw) and raw != "" ->
        IO.puts("  --- begin raw ---")

        raw
        |> String.split("\n")
        |> Enum.each(fn line -> IO.puts("  " <> line) end)

        IO.puts("  --- end raw ---")

      _ ->
        IO.puts("  (no raw model output available)")
    end

    IO.puts("")
  end

  defp print_llm_raw_output(_result) do
    IO.puts("LLM model output (verbatim):")
    IO.puts("  (unavailable)")
    IO.puts("")
  end

  defp print_symbolic_result(%{symbolic: symbolic}) do
    IO.puts("Symbolic verification result:")

    case Map.get(symbolic, :status) do
      status when status in [:sat, :unsat] ->
        IO.puts("  " <> String.replace(TableauxSolver.format_result(symbolic), "\n", "\n  "))

      :skipped ->
        IO.puts("  status: SKIPPED")
        IO.puts("  reason: #{Map.get(symbolic, :reason, "-")}")

      _ ->
        IO.puts("  unavailable")
    end

    IO.puts("")
  end

  defp print_validation(%{validation: validation}) when is_map(validation) do
    IO.puts("Final symbolic validation:")
    IO.puts("  performed: #{Map.get(validation, :performed, false)}")
    IO.puts("  status: #{Map.get(validation, :status, :unknown)}")

    reason = Map.get(validation, :reason)
    if is_binary(reason) and String.trim(reason) != "", do: IO.puts("  reason: #{reason}")

    IO.puts("  guided_status: #{Map.get(validation, :guided_status, "-")}")
    IO.puts("  baseline_status: #{Map.get(validation, :baseline_status, "-")}")
    IO.puts("  validation_ms: #{Map.get(validation, :timing_ms, 0)}")
    IO.puts("")
  end

  defp print_validation(_result) do
    IO.puts("Final symbolic validation:")
    IO.puts("  unavailable")
    IO.puts("")
  end

  defp print_symbolic_execution(%{symbolic_execution: exec}) when is_map(exec) do
    IO.puts("Symbolic solver actions (guided run):")
    IO.puts("  guided_status: #{Map.get(exec, :guided_status, "-")}")

    reason = Map.get(exec, :guided_reason)
    if is_binary(reason) and String.trim(reason) != "", do: IO.puts("  guided_reason: #{reason}")

    IO.puts("  final_status: #{Map.get(exec, :final_status, "-")}")
    IO.puts("  true_atoms_count: #{Map.get(exec, :guided_true_atoms_count, 0)}")
    IO.puts("  llm_guided_execution: #{Map.get(exec, :llm_guided, false)}")
    IO.puts("  llm_guided_keys: #{inspect(Map.get(exec, :llm_guided_keys, []))}")
    IO.puts("  strict_hybrid: #{get_in(exec, [:guided_solver_opts, :strict_hybrid]) || false}")
    IO.puts("  guided_symbolic_steps_count: #{Map.get(exec, :guided_symbolic_steps_count, 0)}")

    IO.puts(
      "  guided_symbolic_steps_truncated: #{Map.get(exec, :guided_symbolic_steps_truncated?, false)}"
    )

    steps = Map.get(exec, :execution_plan_steps, %{})

    IO.puts(
      "  plan_steps: applied=#{Map.get(steps, :applied, 0)}, ignored=#{Map.get(steps, :ignored, 0)}, total=#{Map.get(steps, :total, 0)}"
    )

    IO.puts("  solver_opts_used: #{inspect(Map.get(exec, :guided_solver_opts, []))}")
    IO.puts("")
  end

  defp print_symbolic_execution(_result) do
    IO.puts("Symbolic solver actions (guided run):")
    IO.puts("  unavailable")
    IO.puts("")
  end

  defp print_model_assignment(%{symbolic: symbolic}) do
    IO.puts("Model assignment (at end):")

    if Map.get(symbolic, :status) == :skipped do
      IO.puts("  skipped (symbolic validation disabled)")
      IO.puts("")
      return_noop = :ok
      return_noop
    else
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
      else
        IO.puts("  (empty or unsat)")
      end

      IO.puts("")
    end
  end

  defp print_model_assignment(_result) do
    IO.puts("Model assignment (at end):")
    IO.puts("  (unavailable)")
    IO.puts("")
  end

  defp print_symbolic_steps(result, opts) when is_list(opts) do
    if Keyword.get(opts, :show_symbolic_steps, true) do
      do_print_symbolic_steps(result, opts)
    else
      IO.puts("Symbolic step-by-step execution (guided):")
      IO.puts("  hidden by CLI option --no-show-symbolic-steps")
      IO.puts("")
    end
  end

  defp do_print_symbolic_steps(%{symbolic: symbolic}, opts) when is_map(symbolic) do
    IO.puts("Symbolic step-by-step execution (guided):")

    steps = Map.get(symbolic, :symbolic_steps, [])

    if steps == [] do
      IO.puts("  no detailed symbolic steps collected (enable symbolic_debug or trace_steps)")
      IO.puts("")
    else
      if Keyword.get(opts, :symbolic_steps_compact, true) do
        counts =
          steps
          |> Enum.frequencies_by(fn step -> Map.get(step, :kind, :unknown) end)
          |> Enum.sort_by(fn {kind, _} -> to_string(kind) end)

        IO.puts("  total_steps: #{length(steps)}")
        IO.puts("  compact_mode: true")
        IO.puts("  step_kind_summary:")

        Enum.each(counts, fn {kind, count} ->
          IO.puts("    - #{kind}: #{count}")
        end)

        head = Enum.take(steps, 35)
        tail = Enum.take(Enum.reverse(steps), 12) |> Enum.reverse()

        IO.puts("  first_steps:")

        Enum.each(head, fn step ->
          IO.puts("    [#{Map.get(step, :index, "?")}] #{Map.get(step, :message, "-")}")
        end)

        omitted = length(steps) - length(head) - length(tail)

        if omitted > 0 do
          IO.puts("    ... #{omitted} middle steps omitted")
        end

        if tail != [] do
          IO.puts("  last_steps:")

          Enum.each(tail, fn step ->
            IO.puts("    [#{Map.get(step, :index, "?")}] #{Map.get(step, :message, "-")}")
          end)
        end
      else
        max_show = 250
        shown = Enum.take(steps, max_show)

        Enum.each(shown, fn step ->
          IO.puts("  [#{Map.get(step, :index, "?")}] #{Map.get(step, :message, "-")}")
        end)

        omitted = length(steps) - length(shown)

        if omitted > 0 do
          IO.puts("  ... #{omitted} more steps omitted")
        end
      end

      if Map.get(symbolic, :symbolic_steps_truncated?, false) do
        IO.puts("  note: symbolic trace collection hit configured trace limit")
      end

      IO.puts("")
    end
  end

  defp do_print_symbolic_steps(_result, _opts) do
    IO.puts("Symbolic step-by-step execution (guided):")
    IO.puts("  unavailable")
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
    IO.puts("  --strict-hybrid / --no-strict-hybrid")
    IO.puts("                          Enforce stronger LLM-driven ordering controls")
    IO.puts("  --symbolic-validate / --no-symbolic-validate")
    IO.puts("                          Enable/disable final symbolic truth-grounding step")
    IO.puts("  --symbolic-debug        Print internal tableaux expansion logs")
    IO.puts("  --show-symbolic-steps / --no-show-symbolic-steps")

    IO.puts(
      "                          Show/hide detailed symbolic step-by-step execution section"
    )

    IO.puts("  --symbolic-steps-compact / --no-symbolic-steps-compact")

    IO.puts(
      "                          Show compact symbolic step summary instead of full step dump"
    )

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
