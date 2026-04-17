defmodule STS.SolverGUI do
  @moduledoc """
  Livebook/Kino playground for the hybrid tableaux solver.

  This is NOT a replacement for the API modules:
  - Use `STS.SimpleHybridTableauxSolver` for API calls.
  - Use this module for an interactive notebook UI.

  Works best inside Livebook. Outside Livebook, it gracefully returns usage hints.
  """

  alias STS.{SimpleHybridTableauxSolver, TPTPParser}

  @default_formula "forall x in {a,b}: P(x) -> Q(x)"
  @default_model "openai/gpt-4o-mini"
  @default_tptp_problem "AGT001+0"
  @spinner_frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

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
      layout = build_playground(opts)
      maybe_render_layout(layout, opts)
      {:ok, layout}
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
    ui_state = start_ui_state()

    kino_frame_render(
      output,
      kino_markdown("## Hybrid Tableaux Playground\nFill the form and click **Run Solver**.")
    )

    kino_control_listen(form, fn event ->
      data = Map.get(event, :data, %{})

      formula = Map.get(data, :formula, @default_formula)

      base_solver_opts =
        []
        |> put_if(:llm, Map.get(data, :llm, true))
        |> put_if(:force_llm, Map.get(data, :force_llm, false))
        |> put_if(:strict_hybrid, Map.get(data, :strict_hybrid, true))
        |> put_if(:symbolic_validate, Map.get(data, :symbolic_validate, true))
        |> put_if(:symbolic_debug, Map.get(data, :symbolic_debug, false))
        |> put_if(:model, normalize_string(Map.get(data, :model, @default_model)))
        |> put_if(:temperature, parse_float(Map.get(data, :temperature, "0.2")))
        |> put_if(:domain, parse_domain(Map.get(data, :default_domain, "")))

      case ui_begin_run(ui_state) do
        {:busy, current_run_id} ->
          kino_frame_render(
            output,
            kino_markdown(
              "## Hybrid Tableaux Playground\n⚠️ Solver is already running (run ##{current_run_id}). Please wait..."
            )
          )

        {:ok, run_id} ->
          Task.start(fn -> animate_spinner(output, ui_state, run_id) end)

          Task.start(fn ->
            md =
              try do
                case solve_from_form(data, formula, base_solver_opts) do
                  {:ok, result, input_label, solver_opts, input_meta} ->
                    render_result_markdown(result, input_label, solver_opts, input_meta)

                  {:error, message, solver_opts, input_meta} ->
                    render_error_markdown(message, solver_opts, input_meta)
                end
              rescue
                e ->
                  render_error_markdown(
                    "Unexpected error: #{Exception.message(e)}",
                    base_solver_opts,
                    %{source: :runtime}
                  )
              end

            ui_finish_run(ui_state, run_id)
            kino_frame_render(output, kino_markdown(md))
          end)
      end
    end)

    kino_layout_grid([form, output], columns: 1)
  end

  defp build_form(opts) do
    default_formula = Keyword.get(opts, :formula, @default_formula)
    default_model = Keyword.get(opts, :model, default_model())
    default_domain = Keyword.get(opts, :domain, "")
    default_tptp_problem = Keyword.get(opts, :tptp_problem, @default_tptp_problem)
    default_tptp_roles = Keyword.get(opts, :tptp_roles, "axiom")

    fields = [
      formula: kino_input_textarea("Formula", default: default_formula),
      use_tptp:
        kino_input_checkbox(
          "Use TPTP problem (instead of Formula)",
          default: Keyword.get(opts, :use_tptp, false)
        ),
      tptp_problem:
        kino_input_text(
          "TPTP file name or path (e.g. AGT001+0 or AGT001+0.ax)",
          default: default_tptp_problem
        ),
      tptp_roles:
        kino_input_text(
          "TPTP roles (comma-separated)",
          default: default_tptp_roles
        ),
      tptp_auto_domain:
        kino_input_checkbox(
          "Auto-domain from TPTP constants",
          default: Keyword.get(opts, :tptp_auto_domain, true)
        ),
      tptp_domain_limit:
        kino_input_text(
          "TPTP auto-domain limit",
          default: to_string(Keyword.get(opts, :tptp_domain_limit, 6))
        ),
      llm: kino_input_checkbox("Use LLM guidance", default: Keyword.get(opts, :llm, true)),
      force_llm:
        kino_input_checkbox(
          "Force LLM guidance",
          default: Keyword.get(opts, :force_llm, false)
        ),
      strict_hybrid:
        kino_input_checkbox(
          "Strict hybrid mode (enforce LLM ordering controls)",
          default: Keyword.get(opts, :strict_hybrid, true)
        ),
      symbolic_validate:
        kino_input_checkbox(
          "Run symbolic final validation (truth grounding)",
          default: Keyword.get(opts, :symbolic_validate, true)
        ),
      symbolic_debug:
        kino_input_checkbox(
          "Symbolic debug",
          default: Keyword.get(opts, :symbolic_debug, false)
        ),
      show_symbolic_steps:
        kino_input_checkbox(
          "Show symbolic step-by-step execution",
          default: Keyword.get(opts, :show_symbolic_steps, true)
        ),
      compact_symbolic_steps:
        kino_input_checkbox(
          "Compact symbolic step report",
          default: Keyword.get(opts, :compact_symbolic_steps, true)
        ),
      model: kino_input_text("OpenRouter model", default: default_model),
      temperature: kino_input_text("Temperature", default: "0.2"),
      default_domain:
        kino_input_text("Default domain (comma-separated)", default: to_string(default_domain))
    ]

    kino_control_form(fields, submit: "Run Solver")
  end

  defp render_result_markdown(result, formula, solver_opts, input_meta) do
    symbolic = Map.get(result, :symbolic, %{})
    llm = Map.get(result, :llm, %{})
    tactics = Map.get(result, :applied_tactics, %{})
    llm_usage = Map.get(result, :llm_usage, %{applied: [], ignored: []})
    execution_plan_audit = Map.get(result, :execution_plan_audit, [])
    symbolic_execution = Map.get(result, :symbolic_execution, %{})
    validation = Map.get(result, :validation, %{})
    metrics = get_in(result, [:candidate, :metrics]) || %{}
    steps = Map.get(result, :explain_steps, [])
    timings = Map.get(result, :timings_ms, %{})

    source_md =
      case input_meta do
        %{source: :tptp} = meta ->
          [
            "### Source",
            "- Mode: `TPTP`",
            "- File: `#{Map.get(meta, :file, "-")}`",
            "- Roles: `#{inspect(Map.get(meta, :roles, []))}`",
            "- Parsed formulas: `#{Map.get(meta, :parsed_count, "-")}`",
            "- Constants found: `#{Map.get(meta, :constants_count, "-")}`",
            "- Auto-domain applied: `#{Map.get(meta, :auto_domain_applied, false)}`",
            "- Effective domain size: `#{Map.get(meta, :effective_domain_size, "-")}`",
            ""
          ]
          |> Enum.join("\n")

        _ ->
          ""
      end

    steps_md =
      steps
      |> Enum.map(fn s ->
        "- **[#{s.index}] #{String.upcase(to_string(s.level))}** #{s.title} — #{s.detail}"
      end)
      |> Enum.join("\n")

    model_md = format_model_assignment_md(symbolic)
    llm_output_md = format_llm_output_md(llm)
    llm_usage_md = format_llm_usage_md(llm_usage, tactics)
    plan_audit_md = format_execution_plan_audit_md(execution_plan_audit)
    symbolic_exec_md = format_symbolic_execution_md(symbolic_execution)
    validation_md = format_validation_md(validation)
    show_symbolic_steps? = Map.get(input_meta, :show_symbolic_steps, true)

    compact_symbolic_steps? = Map.get(input_meta, :compact_symbolic_steps, true)

    symbolic_steps_md =
      if show_symbolic_steps? do
        format_symbolic_steps_md(symbolic, compact_symbolic_steps?)
      else
        "- hidden by UI toggle (enable \"Show symbolic step-by-step execution\" to display)"
      end

    """
    ## Hybrid Solver Result

    ### Input
    - Formula: `#{formula}`
    - Options: `#{inspect(solver_opts)}`

    #{source_md}

    ### Routing
    - Route: `#{Map.get(result, :route, "-")}`
    - LLM attempted: `#{Map.get(llm, :attempted, false)}`
    - LLM used: `#{Map.get(llm, :used, false)}`
    - LLM status: `#{Map.get(llm, :status, "-")}`
    - LLM reason: `#{Map.get(llm, :reason, "-")}`

    ### LLM output usage mapping
    #{llm_usage_md}

    ### Execution plan replay audit
    #{plan_audit_md}

    ### LLM output (preferred structured)
    #{llm_output_md}

    ### Symbolic Verdict
    - Status: `#{Map.get(symbolic, :status, "-")}`
    - Human formula: `#{Map.get(symbolic, :human_formula, "-")}`
    - Reason: `#{value_or_dash(Map.get(symbolic, :reason))}`

    ### Symbolic solver actions (guided run)
    #{symbolic_exec_md}

    ### Final symbolic validation
    #{validation_md}

    ### Complexity Metrics
    - Node count: `#{Map.get(metrics, :node_count, "-")}`
    - Atom count: `#{Map.get(metrics, :atom_count, "-")}`
    - Quantifier count: `#{Map.get(metrics, :quantifier_count, "-")}`

    ### Explainable Trace
    #{if steps_md == "", do: "- (no steps)", else: steps_md}

    ### Timings (ms)
    - llm: `#{Map.get(timings, :llm, "-")}`
    - symbolic: `#{Map.get(timings, :symbolic, "-")}`
    - total: `#{Map.get(timings, :total, "-")}`

    ### Model Assignment
    #{model_md}

    ### Symbolic step-by-step execution (guided)
    #{symbolic_steps_md}
    """
  end

  defp render_error_markdown(message, solver_opts, input_meta) do
    """
    ## Hybrid Solver Error

    - Message: `#{message}`
    - Options: `#{inspect(solver_opts)}`
    - Input meta: `#{inspect(input_meta)}`
    """
  end

  defp solve_from_form(data, formula_text, base_solver_opts) do
    use_tptp? = Map.get(data, :use_tptp, false)
    show_symbolic_steps? = Map.get(data, :show_symbolic_steps, true)
    compact_symbolic_steps? = Map.get(data, :compact_symbolic_steps, true)

    if use_tptp? do
      solve_tptp_from_form(data, base_solver_opts)
    else
      result = solve(formula_text, base_solver_opts)

      {:ok, result, formula_text, base_solver_opts,
       %{
         source: :formula,
         show_symbolic_steps: show_symbolic_steps?,
         compact_symbolic_steps: compact_symbolic_steps?
       }}
    end
  end

  defp solve_tptp_from_form(data, base_solver_opts) do
    raw_problem = normalize_string(Map.get(data, :tptp_problem, @default_tptp_problem)) || ""
    roles = parse_tptp_roles(Map.get(data, :tptp_roles, "axiom"))
    auto_domain? = Map.get(data, :tptp_auto_domain, true)
    domain_limit = parse_int(Map.get(data, :tptp_domain_limit, 6), 6)
    show_symbolic_steps? = Map.get(data, :show_symbolic_steps, true)
    compact_symbolic_steps? = Map.get(data, :compact_symbolic_steps, true)

    with {:ok, file_path} <- find_tptp_file(raw_problem),
         {:ok, entries} <- TPTPParser.parse_file(file_path) do
      formula = TPTPParser.to_conjunction(entries, roles: roles)
      constants = TPTPParser.collect_constants(entries)

      {solver_opts, auto_domain_applied?} =
        maybe_apply_tptp_auto_domain(base_solver_opts, constants, auto_domain?, domain_limit)

      result = SimpleHybridTableauxSolver.solve(formula, solver_opts)

      input_label =
        "[TPTP] #{Path.basename(file_path)} (roles=#{Enum.join(Enum.map(roles, &to_string/1), ",")})"

      input_meta = %{
        source: :tptp,
        file: file_path,
        parsed_count: length(entries),
        roles: roles,
        constants_count: length(constants),
        auto_domain_applied: auto_domain_applied?,
        effective_domain_size: effective_domain_size(solver_opts),
        show_symbolic_steps: show_symbolic_steps?,
        compact_symbolic_steps: compact_symbolic_steps?
      }

      {:ok, result, input_label, solver_opts, input_meta}
    else
      {:error, reason} ->
        {:error, "TPTP load failed for '#{raw_problem}': #{reason}", base_solver_opts,
         %{source: :tptp, requested: raw_problem, roles: roles}}
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

  defp parse_tptp_roles(_), do: [:axiom]

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp maybe_apply_tptp_auto_domain(solver_opts, constants, true, domain_limit) do
    if is_nil(Keyword.get(solver_opts, :domain)) and constants != [] do
      limited = Enum.take(constants, max(domain_limit, 0))
      {Keyword.put(solver_opts, :domain, limited), true}
    else
      {solver_opts, false}
    end
  end

  defp maybe_apply_tptp_auto_domain(solver_opts, _constants, _auto_domain, _domain_limit),
    do: {solver_opts, false}

  defp effective_domain_size(solver_opts) do
    case Keyword.get(solver_opts, :domain) do
      domain when is_list(domain) -> length(domain)
      _ -> 0
    end
  end

  defp find_tptp_file(raw_problem) when is_binary(raw_problem) do
    problem = String.trim(raw_problem)

    cond do
      problem == "" ->
        {:error, "empty TPTP problem name"}

      true ->
        names =
          [problem, normalize_tptp_name(problem)]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        absolute_candidate =
          names
          |> Enum.find(&File.exists?/1)

        if is_binary(absolute_candidate) do
          {:ok, absolute_candidate}
        else
          roots = tptp_search_roots()

          found =
            for root <- roots,
                name <- names,
                candidate = Path.join(root, name),
                File.exists?(candidate),
                do: candidate

          case found do
            [path | _] -> {:ok, path}
            [] -> {:error, "could not find '#{problem}' under #{inspect(roots)}"}
          end
        end
    end
  end

  defp normalize_tptp_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    if String.ends_with?(trimmed, ".ax"), do: trimmed, else: trimmed <> ".ax"
  end

  defp tptp_search_roots do
    roots = [
      app_tptp_root(),
      Path.expand("../../tptp_problems", __DIR__),
      Path.join(File.cwd!(), "tptp_problems"),
      Path.join(File.cwd!(), "simple_tableaux_solver/tptp_problems"),
      Path.join(
        File.cwd!(),
        "item_12_Integrating_external_solvers_into_Elixir_and_Livebook/simple_tableaux_solver/tptp_problems"
      )
    ]

    roots
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  defp app_tptp_root do
    try do
      Path.join(Application.app_dir(:simple_tableaux_solver), "tptp_problems")
    rescue
      _ -> nil
    end
  end

  # -------------------------
  # Generic helpers
  # -------------------------

  defp start_ui_state do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{running: false, run_id: 0, started_at_ms: nil}
      end)

    pid
  end

  defp ui_begin_run(ui_state) do
    now = System.monotonic_time(:millisecond)

    Agent.get_and_update(ui_state, fn state ->
      if state.running do
        {{:busy, state.run_id}, state}
      else
        new_id = state.run_id + 1
        {{:ok, new_id}, %{state | running: true, run_id: new_id, started_at_ms: now}}
      end
    end)
  end

  defp ui_finish_run(ui_state, run_id) do
    Agent.update(ui_state, fn state ->
      if state.run_id == run_id do
        %{state | running: false, started_at_ms: nil}
      else
        state
      end
    end)
  end

  defp ui_running?(ui_state, run_id) do
    Agent.get(ui_state, fn state ->
      state.running and state.run_id == run_id
    end)
  end

  defp ui_elapsed_ms(ui_state) do
    now = System.monotonic_time(:millisecond)

    Agent.get(ui_state, fn state ->
      case state.started_at_ms do
        ms when is_integer(ms) -> max(now - ms, 0)
        _ -> 0
      end
    end)
  end

  defp animate_spinner(output, ui_state, run_id) do
    do_animate_spinner(output, ui_state, run_id, 0)
  end

  defp do_animate_spinner(output, ui_state, run_id, frame_idx) do
    if ui_running?(ui_state, run_id) do
      frame = Enum.at(@spinner_frames, rem(frame_idx, length(@spinner_frames)))
      seconds = (ui_elapsed_ms(ui_state) / 1000) |> Float.round(1)

      md =
        "## Hybrid Tableaux Playground\n" <>
          "#{frame} **Running solver...** `#{seconds}s`\n\n" <>
          "Please wait — repeated clicks are ignored while this run is active."

      kino_frame_render(output, kino_markdown(md))
      Process.sleep(120)
      do_animate_spinner(output, ui_state, run_id, frame_idx + 1)
    else
      :ok
    end
  end

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

  defp format_model_assignment_md(symbolic) do
    if Map.get(symbolic, :status) == :skipped do
      "- skipped (symbolic validation disabled)"
    else
      case Map.get(symbolic, :model) do
        model when is_map(model) and map_size(model) > 0 ->
          true_entries =
            model
            |> Enum.filter(fn {_atom, truth} -> truth end)
            |> Enum.sort_by(&elem(&1, 0))

          false_count = Enum.count(model, fn {_atom, truth} -> not truth end)

          header =
            [
              "- summary: true=#{length(true_entries)}, false=#{false_count}, total=#{map_size(model)}"
            ]

          body =
            if true_entries == [] do
              [
                "- no positive atoms needed",
                "- note: only false assignments were necessary and are hidden for readability"
              ]
            else
              max_show = 120
              shown = Enum.take(true_entries, max_show)

              lines = Enum.map(shown, fn {k, v} -> "- `#{k}` => `#{v}`" end)
              omitted = length(true_entries) - length(shown)

              false_note =
                if false_count > 0,
                  do: ["- note: false assignments hidden for readability"],
                  else: []

              if omitted > 0 do
                lines ++ ["- ... #{omitted} more true assignments omitted"] ++ false_note
              else
                lines ++ false_note
              end
            end

          Enum.join(header ++ body, "\n")

        _ ->
          "- no model map available (typically UNSAT or parse/solve failure)"
      end
    end
  end

  defp format_llm_output_md(llm) do
    parsed = get_in(llm, [:guidance, :parsed])
    raw = get_in(llm, [:guidance, :raw])

    cond do
      is_map(parsed) and map_size(parsed) > 0 ->
        pretty =
          if Code.ensure_loaded?(Jason) do
            case Jason.encode(parsed, pretty: true) do
              {:ok, json} -> json
              _ -> inspect(parsed, pretty: true, limit: :infinity)
            end
          else
            inspect(parsed, pretty: true, limit: :infinity)
          end

        "```json\n#{sanitize_code_block(pretty)}\n```"

      is_binary(raw) and String.trim(raw) != "" ->
        "```json\n#{sanitize_code_block(raw)}\n```"

      true ->
        "- (no model output available)"
    end
  end

  defp format_llm_usage_md(llm_usage, tactics) do
    applied_lines =
      llm_usage
      |> Map.get(:applied, [])
      |> Enum.map(&"- #{&1}")

    ignored_lines =
      llm_usage
      |> Map.get(:ignored, [])
      |> Enum.map(&"- ignored: #{&1}")

    fallback_applied =
      if applied_lines == [] and is_map(tactics) and map_size(tactics) > 0 do
        tactics
        |> Enum.map(fn
          {:branch_priority, v} ->
            "- applied fallback mapping: branch_priority=#{inspect(v)}"

          {k, v} ->
            "- applied fallback mapping: #{k}=#{inspect(v)}"
        end)
      else
        []
      end

    lines = applied_lines ++ fallback_applied ++ ignored_lines

    if lines == [] do
      "- no machine-usable tactic extracted; symbolic solver used default strategy"
    else
      Enum.join(lines, "\n")
    end
  end

  defp format_execution_plan_audit_md(audit) when is_list(audit) and audit != [] do
    audit
    |> Enum.map(fn step ->
      "- [#{Map.get(step, :index, "?")}] `#{Map.get(step, :action, :unknown)}` → `#{Map.get(step, :status, :unknown)}`: #{Map.get(step, :detail, "-")}"
    end)
    |> Enum.join("\n")
  end

  defp format_execution_plan_audit_md(_), do: "- no execution plan steps were replayed"

  defp format_validation_md(validation) when is_map(validation) and map_size(validation) > 0 do
    [
      "- Performed: `#{Map.get(validation, :performed, false)}`",
      "- Status: `#{Map.get(validation, :status, :unknown)}`",
      "- Reason: `#{value_or_dash(Map.get(validation, :reason))}`",
      "- Guided status: `#{value_or_dash(Map.get(validation, :guided_status))}`",
      "- Baseline status: `#{value_or_dash(Map.get(validation, :baseline_status))}`",
      "- Validation time (ms): `#{Map.get(validation, :timing_ms, 0)}`"
    ]
    |> Enum.join("\n")
  end

  defp format_validation_md(_), do: "- unavailable"

  defp format_symbolic_execution_md(exec) when is_map(exec) and map_size(exec) > 0 do
    steps = Map.get(exec, :execution_plan_steps, %{})

    [
      "- Guided status: `#{value_or_dash(Map.get(exec, :guided_status))}`",
      "- Guided reason: `#{value_or_dash(Map.get(exec, :guided_reason))}`",
      "- Final status used: `#{value_or_dash(Map.get(exec, :final_status))}`",
      "- Guided true atoms count: `#{Map.get(exec, :guided_true_atoms_count, 0)}`",
      "- LLM guided execution?: `#{Map.get(exec, :llm_guided, false)}`",
      "- LLM guided keys: `#{inspect(Map.get(exec, :llm_guided_keys, []))}`",
      "- Strict hybrid: `#{get_in(exec, [:guided_solver_opts, :strict_hybrid]) || false}`",
      "- Guided symbolic step count: `#{Map.get(exec, :guided_symbolic_steps_count, 0)}`",
      "- Guided symbolic steps truncated?: `#{Map.get(exec, :guided_symbolic_steps_truncated?, false)}`",
      "- Plan steps applied/total: `#{Map.get(steps, :applied, 0)}/#{Map.get(steps, :total, 0)}`",
      "- Solver options used: `#{inspect(Map.get(exec, :guided_solver_opts, []))}`"
    ]
    |> Enum.join("\n")
  end

  defp format_symbolic_execution_md(_), do: "- unavailable"

  defp format_symbolic_steps_md(symbolic, compact?) when is_map(symbolic) do
    steps = Map.get(symbolic, :symbolic_steps, [])

    if steps == [] do
      "- no detailed symbolic steps collected (enable Symbolic debug to capture expanding/assignment actions)"
    else
      if compact? do
        compact_symbolic_steps_md(steps)
      else
        max_show = 500
        shown = Enum.take(steps, max_show)

        lines =
          shown
          |> Enum.map(fn step ->
            "- [#{Map.get(step, :index, "?")}] #{Map.get(step, :message, "-")}"
          end)

        omitted = length(steps) - length(shown)

        lines =
          if omitted > 0 do
            lines ++ ["- ... #{omitted} more steps omitted"]
          else
            lines
          end

        Enum.join(lines, "\n")
      end
    end
  end

  defp format_symbolic_steps_md(_, _), do: "- unavailable"

  defp compact_symbolic_steps_md(steps) when is_list(steps) do
    counts =
      steps
      |> Enum.frequencies_by(fn step -> Map.get(step, :kind, :unknown) end)
      |> Enum.sort_by(fn {kind, _count} -> to_string(kind) end)

    counts_lines =
      counts
      |> Enum.map(fn {kind, count} -> "- `#{kind}`: `#{count}`" end)

    head = Enum.take(steps, 40)
    tail = Enum.take(Enum.reverse(steps), 15) |> Enum.reverse()

    head_lines =
      head
      |> Enum.map(fn step ->
        "- [#{Map.get(step, :index, "?")}] #{Map.get(step, :message, "-")}"
      end)

    tail_lines =
      tail
      |> Enum.map(fn step ->
        "- [#{Map.get(step, :index, "?")}] #{Map.get(step, :message, "-")}"
      end)

    omitted = length(steps) - length(head) - length(tail)

    [
      "- total symbolic steps: `#{length(steps)}`",
      "- compact mode: showing first #{length(head)} and last #{length(tail)} steps",
      "",
      "**Step-kind summary**",
      Enum.join(counts_lines, "\n"),
      "",
      "**First steps**",
      Enum.join(head_lines, "\n"),
      if(omitted > 0, do: "\n- ... #{omitted} middle steps omitted\n", else: ""),
      if(tail != [], do: "**Last steps**\n" <> Enum.join(tail_lines, "\n"), else: "")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp value_or_dash(nil), do: "-"
  defp value_or_dash(""), do: "-"
  defp value_or_dash(v), do: to_string(v)

  defp sanitize_code_block(text) when is_binary(text) do
    String.replace(text, "```", "``\\`")
  end

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

  defp kino_control_listen(control, callback) do
    control_mod = Module.concat([Kino, Control])

    cond do
      function_exported?(control_mod, :listen, 2) ->
        apply(control_mod, :listen, [control, callback])

      function_exported?(control_mod, :stream, 1) and function_exported?(Kino, :listen, 2) ->
        stream = apply(control_mod, :stream, [control])
        apply(Kino, :listen, [stream, callback])

      true ->
        raise "Unsupported Kino version: no control event listening API found"
    end
  end

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

  defp maybe_render_layout(layout, opts) do
    auto_render? = Keyword.get(opts, :auto_render, true)

    if auto_render? and function_exported?(Kino, :render, 1) do
      try do
        apply(Kino, :render, [layout])
      rescue
        _ -> :ok
      end
    end

    :ok
  end
end
