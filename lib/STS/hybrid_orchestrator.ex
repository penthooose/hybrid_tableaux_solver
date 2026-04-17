defmodule STS.HybridOrchestrator do
  @moduledoc """
  Hybrid orchestrator for LLM-guided + symbolic tableaux reasoning.

  Design principle:
  - LLM guidance is heuristic only.
  - Final SAT/UNSAT verdict is always produced by `STS.TableauxSolver`.
  """

  alias STS.{Tableaux, TableauxSolver}

  @openrouter_endpoint "https://openrouter.ai/api/v1/chat/completions"
  @default_model "anthropic/claude-sonnet-4.6"

  @type guidance :: %{
          raw: String.t() | nil,
          parsed: map() | nil,
          source: :openrouter | :local_fallback,
          warning: String.t() | nil
        }

  @type result :: %{
          input: String.t(),
          route: :symbolic_only | :hybrid_llm_guided | :hybrid_fallback | :llm_only_unverified,
          candidate: %{candidate?: boolean(), metrics: map()} | nil,
          applied_tactics: map(),
          llm_usage: %{applied: [String.t()], ignored: [String.t()]},
          execution_plan_audit: [map()],
          symbolic_execution: map(),
          validation: %{
            performed: boolean(),
            status: :passed | :failed | :skipped,
            reason: String.t() | nil,
            baseline_status: atom() | nil,
            guided_status: atom() | nil,
            timing_ms: non_neg_integer()
          },
          llm: %{
            attempted: boolean(),
            used: boolean(),
            status: :ok | :skipped | :fallback,
            model: String.t() | nil,
            reason: String.t() | nil,
            guidance: guidance() | nil
          },
          symbolic: map(),
          explain_steps: [map()],
          timings_ms: %{
            llm: non_neg_integer(),
            symbolic: non_neg_integer(),
            total: non_neg_integer()
          }
        }

  @spec run(String.t() | TableauxSolver.solve_result(), keyword()) :: result()
  def run(formula_or_input, opts \\ []) do
    total_start = System.monotonic_time(:millisecond)

    formula_text = preview_formula(formula_or_input)

    trace = []

    trace =
      add_step(
        trace,
        :info,
        "Received input",
        "Starting hybrid orchestration for formula: #{formula_text}"
      )

    {candidate_info, trace} = evaluate_candidate(formula_or_input, opts, trace)

    llm_allowed? = Keyword.get(opts, :llm, true)
    force_llm? = Keyword.get(opts, :force_llm, false)

    llm_attempt? = should_invoke_llm?(llm_allowed?, force_llm?, candidate_info)
    symbolic_validate? = Keyword.get(opts, :symbolic_validate, true)

    {llm_block, trace, llm_time} =
      maybe_get_guidance(llm_attempt?, formula_text, candidate_info, opts, trace)

    {llm_block, tactics, llm_usage, execution_plan_audit} = derive_symbolic_tactics(llm_block)

    trace =
      if map_size(tactics) > 0 do
        add_step(
          trace,
          :info,
          "LLM tactics applied",
          "Applied machine-usable tactics: #{inspect(tactics)}"
        )
      else
        trace
      end

    trace =
      if llm_usage.ignored != [] do
        add_step(
          trace,
          :warn,
          "Some LLM tactics ignored",
          Enum.join(llm_usage.ignored, " | ")
        )
      else
        trace
      end

    trace =
      if execution_plan_audit != [] do
        applied_count = Enum.count(execution_plan_audit, &(&1.status == :applied))
        ignored_count = Enum.count(execution_plan_audit, &(&1.status == :ignored))

        add_step(
          trace,
          :info,
          "Execution plan replayed",
          "steps=#{length(execution_plan_audit)}, applied=#{applied_count}, ignored=#{ignored_count}"
        )
      else
        trace
      end

    symbolic_opts =
      opts
      |> Keyword.take([
        :domain,
        :debug,
        :branch_priority,
        :quantifier_order,
        :domain_order,
        :exists_domain_order,
        :forall_domain_order,
        :branch_queue,
        :strict_hybrid
      ])
      |> Keyword.put(:debug, Keyword.get(opts, :symbolic_debug, false))
      |> maybe_put_tactic_opts(tactics)

    strict_hybrid? = Keyword.get(opts, :strict_hybrid, true) and llm_block.status == :ok

    symbolic_opts =
      if strict_hybrid?,
        do: Keyword.put(symbolic_opts, :strict_hybrid, true),
        else: symbolic_opts

    llm_guided_keys = effective_llm_guided_keys(opts, tactics, strict_hybrid?)

    symbolic_opts =
      symbolic_opts
      |> Keyword.put(:llm_guided, llm_guided_keys != [] or strict_hybrid?)
      |> Keyword.put(:llm_guided_keys, llm_guided_keys)

    {guided_result, guided_time} =
      time_it(fn -> TableauxSolver.solve(formula_or_input, symbolic_opts) end)

    trace =
      add_step(
        trace,
        :info,
        "Guided symbolic solve finished",
        "Guided symbolic engine returned #{String.upcase(to_string(guided_result.status))}"
      )

    validation_opts =
      opts
      |> Keyword.take([:domain, :debug, :branch_priority, :quantifier_order, :domain_order])
      |> Keyword.put(:debug, Keyword.get(opts, :symbolic_debug, false))

    {symbolic_result, validation, trace} =
      if symbolic_validate? do
        {baseline_result, validation_time} =
          time_it(fn -> TableauxSolver.solve(formula_or_input, validation_opts) end)

        {symbolic_result, status, reason, trace} =
          if baseline_result.status == guided_result.status do
            {
              guided_result,
              :passed,
              "Guided result matches standalone symbolic validation",
              add_step(
                trace,
                :info,
                "Final symbolic validation passed",
                "Guided=#{guided_result.status}, baseline=#{baseline_result.status}"
              )
            }
          else
            {
              baseline_result,
              :failed,
              "Guided and baseline symbolic statuses diverged; baseline verdict used",
              add_step(
                trace,
                :warn,
                "Final symbolic validation mismatch",
                "Guided=#{guided_result.status}, baseline=#{baseline_result.status}; baseline verdict selected"
              )
            }
          end

        validation = %{
          performed: true,
          status: status,
          reason: reason,
          baseline_status: baseline_result.status,
          guided_status: guided_result.status,
          timing_ms: validation_time
        }

        {symbolic_result, validation, trace}
      else
        validation = %{
          performed: false,
          status: :skipped,
          reason: "Final symbolic validation disabled; returning guided symbolic verdict",
          baseline_status: nil,
          guided_status: guided_result.status,
          timing_ms: 0
        }

        trace =
          add_step(
            trace,
            :warn,
            "Final symbolic validation skipped",
            "symbolic_validate=false; reporting guided symbolic verdict without second-pass confirmation"
          )

        {guided_result, validation, trace}
      end

    symbolic_execution =
      build_symbolic_execution_summary(
        symbolic_opts,
        execution_plan_audit,
        guided_result,
        symbolic_result,
        validation
      )

    trace =
      add_step(
        trace,
        :info,
        "Guided symbolic actions",
        "opts=#{inspect(symbolic_execution.guided_solver_opts)}, plan_steps=#{symbolic_execution.execution_plan_steps.applied}/#{symbolic_execution.execution_plan_steps.total} applied, symbolic_steps=#{symbolic_execution.guided_symbolic_steps_count}"
      )

    route = choose_route(llm_block, symbolic_validate?)
    total_time = System.monotonic_time(:millisecond) - total_start

    %{
      input: formula_text,
      route: route,
      candidate: candidate_info,
      applied_tactics: tactics,
      llm_usage: llm_usage,
      execution_plan_audit: execution_plan_audit,
      symbolic_execution: symbolic_execution,
      validation: validation,
      llm: llm_block,
      symbolic: symbolic_result,
      explain_steps: finalize_steps(trace),
      timings_ms: %{llm: llm_time, symbolic: guided_time, total: total_time}
    }
  end

  defp evaluate_candidate(formula_or_input, opts, trace) do
    case TableauxSolver.hybrid_candidate?(formula_or_input, Keyword.take(opts, [:domain])) do
      {:ok, info} ->
        detail = "candidate?=#{info.candidate?}, metrics=#{inspect(info.metrics)}"
        {info, add_step(trace, :info, "Hybrid candidacy evaluated", detail)}

      {:error, reason} ->
        trace = add_step(trace, :warn, "Could not evaluate candidacy", reason)
        {nil, trace}
    end
  end

  defp maybe_get_guidance(false, _formula_text, _candidate_info, _opts, trace) do
    block = %{
      attempted: false,
      used: false,
      status: :skipped,
      model: nil,
      reason: "LLM guidance skipped (not requested or not needed by heuristic)",
      guidance: nil
    }

    {block, add_step(trace, :info, "LLM step skipped", block.reason), 0}
  end

  defp maybe_get_guidance(true, formula_text, candidate_info, opts, trace) do
    model = resolve_model(opts)

    trace =
      add_step(
        trace,
        :info,
        "LLM guidance requested",
        "Attempting OpenRouter model=#{model} for decomposition hints"
      )

    {llm_result, llm_time} =
      time_it(fn ->
        request_openrouter_guidance(formula_text, candidate_info, opts)
      end)

    case llm_result do
      {:ok, guidance} ->
        block = %{
          attempted: true,
          used: true,
          status: :ok,
          model: model,
          reason: nil,
          guidance: guidance
        }

        trace =
          add_step(
            trace,
            :info,
            "LLM guidance received",
            "Guidance source=#{guidance.source}; symbolic engine will still verify final result"
          )

        {block, trace, llm_time}

      {:error, reason} ->
        fallback = local_fallback_guidance(formula_text, candidate_info)

        block = %{
          attempted: true,
          used: false,
          status: :fallback,
          model: model,
          reason: reason,
          guidance: fallback
        }

        trace =
          add_step(
            trace,
            :warn,
            "LLM guidance unavailable",
            "Reason: #{reason}. Falling back to local heuristic guidance."
          )

        {block, trace, llm_time}
    end
  end

  defp should_invoke_llm?(false, _force_llm?, _candidate_info), do: false
  defp should_invoke_llm?(true, true, _candidate_info), do: true

  defp should_invoke_llm?(true, false, %{candidate?: true}), do: true

  defp should_invoke_llm?(true, false, %{metrics: metrics}) when is_map(metrics) do
    q = Map.get(metrics, :quantifier_count, 0)
    n = Map.get(metrics, :node_count, 0)
    a = Map.get(metrics, :atom_count, 0)

    q > 0 or n >= 20 or a >= 12
  end

  defp should_invoke_llm?(true, false, _), do: false

  defp request_openrouter_guidance(formula_text, candidate_info, opts) do
    api_key =
      Keyword.get(opts, :openrouter_api_key) ||
        System.get_env("OPENROUTER_API_KEY") ||
        read_key_from_env_files(opts, "OPENROUTER_API_KEY")

    cond do
      is_nil(api_key) or api_key == "" ->
        {:error, "OPENROUTER_API_KEY missing"}

      not Code.ensure_loaded?(Req) ->
        {:error, "Req dependency not available; add {:req, \"~> 0.5\"}"}

      true ->
        do_openrouter_request(api_key, formula_text, candidate_info, opts)
    end
  end

  defp read_key_from_env_file(path, key) when is_binary(path) and is_binary(key) do
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

  defp resolve_model(opts) do
    Keyword.get(opts, :model) ||
      System.get_env("OPENROUTER_MODEL") ||
      read_key_from_env_files(opts, "OPENROUTER_MODEL") || @default_model
  end

  defp read_key_from_env_files(opts, key) do
    env_files(opts)
    |> Enum.find_value(fn path -> read_key_from_env_file(path, key) end)
  end

  defp env_files(opts) do
    [
      Keyword.get(opts, :env_file),
      Path.join(File.cwd!(), ".env"),
      Path.expand("../../.env", __DIR__),
      Path.join(__DIR__, ".env")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp do_openrouter_request(api_key, formula_text, candidate_info, opts) do
    model = resolve_model(opts)
    temperature = Keyword.get(opts, :temperature, 0.2)
    timeout = Keyword.get(opts, :openrouter_timeout_ms, 40_000)

    payload = %{
      model: model,
      temperature: temperature,
      messages: [
        %{
          role: "system",
          content:
            "You are a theorem-proving assistant. Return ONLY strict JSON. Never claim final SAT/UNSAT certainty; provide heuristic decomposition hints only."
        },
        %{
          role: "user",
          content: build_prompt(formula_text, candidate_info)
        }
      ]
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"http-referer", Keyword.get(opts, :openrouter_referer, "https://local.simple-tableaux")},
      {"x-title", Keyword.get(opts, :openrouter_title, "Simple Hybrid Tableaux Solver")}
    ]

    case apply(Req, :post, [
           @openrouter_endpoint,
           [json: payload, headers: headers, receive_timeout: timeout]
         ]) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        content = extract_openrouter_content(body)

        if is_binary(content) and content != "" do
          guidance = %{
            raw: content,
            parsed: maybe_parse_json(content),
            source: :openrouter,
            warning: nil
          }

          {:ok, guidance}
        else
          {:error, "OpenRouter returned no usable content"}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, "OpenRouter HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "OpenRouter request failed: #{inspect(reason)}"}
    end
  end

  defp build_prompt(formula_text, candidate_info) do
    """
    Formula:
    #{formula_text}

    Complexity info:
    #{inspect(candidate_info)}

    Please provide JSON with keys:
    - decomposition_plan: [string]
    - branching_hints: [string]
    - quantifier_hints: [string]
    - external_oracle_hints: [string]
    - confidence: number between 0 and 1
    - solver_tactics: {
        "branch_priority": "default|close_fast|reverse",
        "quantifier_order": "default|reverse",
        "domain_order": [string],
        "reason": string
      }
    - execution_plan: {
        "steps": [
          {"action": "instantiate_exists", "order": [string]},
          {"action": "instantiate_forall", "order": [string], "quantifier_order": "default|reverse"},
          {"action": "choose_branch", "branch_priority": "default|close_fast|reverse", "preferred_literals": [string]},
          {"action": "propagate", "mode": "unit"}
        ],
        "exists_witness_order": [string],
        "universal_unroll_order": [string],
        "branch_literal_priority": [string]
      }

    Constraints:
    - Output a RAW JSON object only (no markdown, no code fences).
    - Do not claim a final SAT/UNSAT proof; provide heuristic guidance only.
    - Keep guidance model-agnostic and verification-friendly.
    - For execution_plan.steps, use only the allowed action names.
    """
    |> String.trim()
  end

  defp extract_openrouter_content(body) when is_map(body) do
    choices = Map.get(body, "choices") || Map.get(body, :choices) || []

    case choices do
      [first | _] ->
        message = Map.get(first, "message") || Map.get(first, :message) || %{}
        content = Map.get(message, "content") || Map.get(message, :content)

        case content do
          text when is_binary(text) -> text
          [%{"text" => text} | _] when is_binary(text) -> text
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_openrouter_content(_), do: nil

  defp maybe_parse_json(text) do
    cond do
      Code.ensure_loaded?(Jason) ->
        decode_json_safely(text)

      true ->
        nil
    end
  end

  defp decode_json_safely(text) when is_binary(text) do
    attempts = [
      text,
      strip_markdown_code_fence(text),
      first_json_object(text)
    ]

    attempts
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.find_value(fn candidate ->
      case apply(Jason, :decode, [candidate]) do
        {:ok, parsed} -> parsed
        {:error, _} -> nil
      end
    end)
  end

  defp decode_json_safely(_), do: nil

  defp strip_markdown_code_fence(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```[a-zA-Z0-9_-]*\s*/u, "")
    |> String.replace(~r/\s*```$/u, "")
  end

  defp first_json_object(text) when is_binary(text) do
    case Regex.run(~r/\{[\s\S]*\}/u, text) do
      [match | _] -> match
      _ -> nil
    end
  end

  defp local_fallback_guidance(formula_text, candidate_info) do
    quantified =
      case candidate_info do
        %{metrics: %{quantifier_count: q}} when is_integer(q) and q > 0 ->
          [
            "Ground quantifiers over the smallest domain first and cache instantiated literals.",
            "Normalize to NNF before branching to keep quantifier handling deterministic."
          ]

        _ ->
          []
      end

    branching = [
      "Prefer expanding conjunctions before disjunctions to reduce branch explosion.",
      "Prioritize branches containing literals likely to close quickly (p and ¬p patterns)."
    ]

    external = [
      "If branching remains large, export candidate branches to cvc5/Vampire as an oracle check.",
      "Treat oracle responses as verification signals, not as replacement for local traceability."
    ]

    %{
      raw: nil,
      parsed: %{
        "decomposition_plan" => [
          "Input formula: #{formula_text}",
          "Preprocess formula: eliminate implications, then NNF.",
          "Instantiate quantifiers over finite domains.",
          "Run tableaux with branch-priority heuristic."
        ],
        "branching_hints" => branching,
        "quantifier_hints" => quantified,
        "external_oracle_hints" => external,
        "solver_tactics" => %{
          "branch_priority" => "close_fast",
          "quantifier_order" => "default",
          "domain_order" => [],
          "reason" =>
            "Prefer quick branch closures first. Keep quantifier order stable unless model proposes explicit finite-domain ordering."
        },
        "execution_plan" => %{
          "steps" => [
            %{"action" => "choose_branch", "branch_priority" => "close_fast"},
            %{"action" => "propagate", "mode" => "unit"}
          ],
          "exists_witness_order" => [],
          "universal_unroll_order" => [],
          "branch_literal_priority" => []
        },
        "confidence" => 0.42
      },
      source: :local_fallback,
      warning: "LLM call unavailable; using deterministic local guidance"
    }
  end

  defp choose_route(%{attempted: false}, _symbolic_validate?), do: :symbolic_only
  defp choose_route(%{status: :ok}, false), do: :llm_only_unverified
  defp choose_route(%{status: :ok}, true), do: :hybrid_llm_guided
  defp choose_route(_llm, false), do: :llm_only_unverified
  defp choose_route(_llm, true), do: :hybrid_fallback

  defp derive_symbolic_tactics(%{guidance: %{parsed: parsed}} = llm_block) when is_map(parsed) do
    normalized = normalize_parsed_guidance(parsed)

    {structured, ignored_structured, execution_plan_audit} = parse_structured_tactics(normalized)

    inferred = infer_tactics_from_hints(normalized)
    # precedence: execution_plan.steps + structured > inferred
    tactics = Map.merge(inferred, structured)

    usage = %{
      applied: format_tactic_usage_applied(tactics),
      ignored: ignored_structured
    }

    llm_block = put_in(llm_block, [:guidance, :parsed], normalized)
    {llm_block, tactics, usage, execution_plan_audit}
  end

  defp derive_symbolic_tactics(%{attempted: false} = llm_block),
    do: {llm_block, %{}, %{applied: [], ignored: []}, []}

  defp derive_symbolic_tactics(llm_block),
    do: {llm_block, %{}, %{applied: [], ignored: ["No structured JSON guidance parsed"]}, []}

  defp normalize_parsed_guidance(parsed) when is_map(parsed) do
    %{
      "decomposition_plan" => ensure_string_list(Map.get(parsed, "decomposition_plan")),
      "branching_hints" => ensure_string_list(Map.get(parsed, "branching_hints")),
      "quantifier_hints" => ensure_string_list(Map.get(parsed, "quantifier_hints")),
      "external_oracle_hints" => ensure_string_list(Map.get(parsed, "external_oracle_hints")),
      "solver_tactics" => normalize_solver_tactics_map(Map.get(parsed, "solver_tactics")),
      "execution_plan" => normalize_execution_plan_map(Map.get(parsed, "execution_plan")),
      "confidence" => normalize_confidence(Map.get(parsed, "confidence"))
    }
  end

  defp normalize_parsed_guidance(_), do: %{}

  defp normalize_solver_tactics_map(map) when is_map(map), do: map
  defp normalize_solver_tactics_map(_), do: %{}

  defp normalize_execution_plan_map(map) when is_map(map) do
    Map.update(map, "steps", [], &normalize_steps/1)
  end

  defp normalize_execution_plan_map(_), do: %{}

  defp normalize_steps(steps) when is_list(steps), do: steps
  defp normalize_steps(_), do: []

  defp ensure_string_list(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp ensure_string_list(value) when is_binary(value), do: [String.trim(value)]
  defp ensure_string_list(_), do: []

  defp normalize_confidence(value) when is_float(value), do: value
  defp normalize_confidence(value) when is_integer(value), do: value / 1

  defp normalize_confidence(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {v, _} -> v
      :error -> nil
    end
  end

  defp normalize_confidence(_), do: nil

  defp parse_structured_tactics(parsed) when is_map(parsed) do
    solver_tactics = Map.get(parsed, "solver_tactics", %{})
    execution_plan = Map.get(parsed, "execution_plan", %{})

    ignored = []
    tactics = %{}
    step_audit = []

    {tactics, ignored} =
      case Map.get(solver_tactics, "branch_priority") do
        value when is_binary(value) ->
          case String.downcase(String.trim(value)) do
            "close_fast" -> {Map.put(tactics, :branch_priority, :close_fast), ignored}
            "reverse" -> {Map.put(tactics, :branch_priority, :reverse), ignored}
            "default" -> {Map.put(tactics, :branch_priority, :default), ignored}
            other -> {tactics, ignored ++ ["Invalid solver_tactics.branch_priority='#{other}'"]}
          end

        nil ->
          {tactics, ignored}

        _ ->
          {tactics, ignored ++ ["Invalid solver_tactics.branch_priority (expected string)"]}
      end

    {tactics, ignored} =
      case Map.get(solver_tactics, "quantifier_order") do
        value when is_binary(value) ->
          case String.downcase(String.trim(value)) do
            "default" ->
              {Map.put(tactics, :quantifier_order, :default), ignored}

            "reverse" ->
              {Map.put(tactics, :quantifier_order, :reverse), ignored}

            other ->
              {tactics, ignored ++ ["Invalid solver_tactics.quantifier_order='#{other}'"]}
          end

        nil ->
          {tactics, ignored}

        _ ->
          {tactics, ignored ++ ["Invalid solver_tactics.quantifier_order (expected string)"]}
      end

    {tactics, ignored} =
      case Map.get(solver_tactics, "domain_order") do
        values when is_list(values) ->
          normalized =
            values
            |> Enum.map(&to_string/1)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          if normalized == [] do
            {tactics, ignored}
          else
            {Map.put(tactics, :domain_order, normalized), ignored}
          end

        nil ->
          {tactics, ignored}

        _ ->
          {tactics, ignored ++ ["Invalid solver_tactics.domain_order (expected list of strings)"]}
      end

    {tactics, ignored} =
      if Map.has_key?(tactics, :domain_order) do
        domain_order = Map.get(tactics, :domain_order, [])

        {tactics
         |> Map.put_new(:exists_domain_order, domain_order)
         |> Map.put_new(:forall_domain_order, domain_order), ignored}
      else
        {tactics, ignored}
      end

    {tactics, ignored, step_audit} =
      parse_execution_plan_steps(
        Map.get(execution_plan, "steps", []),
        tactics,
        ignored,
        step_audit
      )

    {tactics, ignored} =
      case Map.get(execution_plan, "exists_witness_order") do
        values when is_list(values) ->
          normalized =
            values
            |> Enum.map(&to_string/1)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          cond do
            normalized == [] ->
              {tactics, ignored}

            Map.has_key?(tactics, :exists_domain_order) and
                Map.get(tactics, :exists_domain_order) == normalized ->
              {tactics, ignored}

            Map.has_key?(tactics, :exists_domain_order) ->
              {tactics,
               ignored ++
                 [
                   "execution_plan.exists_witness_order ignored because exists_domain_order already set"
                 ]}

            true ->
              {Map.put(tactics, :exists_domain_order, normalized), ignored}
          end

        nil ->
          {tactics, ignored}

        _ ->
          {tactics,
           ignored ++ ["Invalid execution_plan.exists_witness_order (expected list of strings)"]}
      end

    {tactics, ignored} =
      case Map.get(execution_plan, "universal_unroll_order") do
        values when is_list(values) ->
          normalized =
            values
            |> Enum.map(&to_string/1)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          cond do
            normalized == [] ->
              {tactics, ignored}

            Map.has_key?(tactics, :forall_domain_order) and
                Map.get(tactics, :forall_domain_order) == normalized ->
              {tactics, ignored}

            Map.has_key?(tactics, :forall_domain_order) ->
              {tactics,
               ignored ++
                 [
                   "execution_plan.universal_unroll_order ignored because forall_domain_order already set"
                 ]}

            true ->
              {Map.put(tactics, :forall_domain_order, normalized), ignored}
          end

        nil ->
          {tactics, ignored}

        _ ->
          {tactics,
           ignored ++ ["Invalid execution_plan.universal_unroll_order (expected list of strings)"]}
      end

    {tactics, ignored} =
      case Map.get(execution_plan, "branch_literal_priority") do
        values when is_list(values) ->
          normalized =
            values
            |> Enum.map(&to_string/1)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          if normalized == [] do
            {tactics, ignored}
          else
            tactics =
              tactics
              |> Map.put(:preferred_literals, normalized)
              |> append_branch_queue(normalized)

            {tactics, ignored}
          end

        nil ->
          {tactics, ignored}

        _ ->
          {tactics,
           ignored ++
             ["Invalid execution_plan.branch_literal_priority (expected list of strings)"]}
      end

    unknown_key_issues =
      solver_tactics
      |> Map.keys()
      |> Enum.reject(&(&1 in ["branch_priority", "quantifier_order", "domain_order", "reason"]))
      |> Enum.map(&"Unsupported solver_tactics key ignored: #{&1}")

    unknown_plan_key_issues =
      execution_plan
      |> Map.keys()
      |> Enum.reject(
        &(&1 in [
            "exists_witness_order",
            "universal_unroll_order",
            "branch_literal_priority",
            "steps"
          ])
      )
      |> Enum.map(&"Unsupported execution_plan key ignored: #{&1}")

    {tactics, ignored ++ unknown_key_issues ++ unknown_plan_key_issues, step_audit}
  end

  defp parse_structured_tactics(_), do: {%{}, ["guidance missing or not an object"], []}

  defp parse_execution_plan_steps(steps, tactics, ignored, step_audit) when is_list(steps) do
    Enum.with_index(steps, 1)
    |> Enum.reduce({tactics, ignored, step_audit}, fn {step, idx}, {acc_t, acc_i, acc_a} ->
      case parse_plan_step(step) do
        {:error, reason} ->
          audit = %{index: idx, action: :unknown, status: :ignored, detail: reason}
          {acc_t, acc_i ++ [reason], acc_a ++ [audit]}

        {:ok, action, params} ->
          case replay_plan_step(action, params, acc_t) do
            {:applied, new_tactics, detail} ->
              audit = %{index: idx, action: action, status: :applied, detail: detail}
              {new_tactics, acc_i, acc_a ++ [audit]}

            {:ignored, detail} ->
              audit = %{index: idx, action: action, status: :ignored, detail: detail}
              {acc_t, acc_i ++ ["execution_plan.steps[#{idx}] #{detail}"], acc_a ++ [audit]}
          end
      end
    end)
  end

  defp parse_execution_plan_steps(_not_list, tactics, ignored, step_audit),
    do: {tactics, ignored ++ ["execution_plan.steps must be a list"], step_audit}

  defp parse_plan_step(step) when is_binary(step) do
    action = step |> String.trim() |> String.downcase()

    case action do
      "instantiate_exists" -> {:ok, :instantiate_exists, %{}}
      "instantiate_forall" -> {:ok, :instantiate_forall, %{}}
      "choose_branch" -> {:ok, :choose_branch, %{}}
      "propagate" -> {:ok, :propagate, %{}}
      _ -> {:error, "Unknown execution plan action '#{step}'"}
    end
  end

  defp parse_plan_step(step) when is_map(step) do
    action_raw = Map.get(step, "action") || Map.get(step, :action)

    cond do
      not is_binary(action_raw) ->
        {:error, "execution_plan step object missing string action"}

      true ->
        action = action_raw |> String.trim() |> String.downcase()
        params = stringify_keys(step)

        case action do
          "instantiate_exists" -> {:ok, :instantiate_exists, params}
          "instantiate_forall" -> {:ok, :instantiate_forall, params}
          "choose_branch" -> {:ok, :choose_branch, params}
          "propagate" -> {:ok, :propagate, params}
          _ -> {:error, "Unknown execution plan action '#{action}'"}
        end
    end
  end

  defp parse_plan_step(_), do: {:error, "execution_plan step must be string or object"}

  defp replay_plan_step(:instantiate_exists, params, tactics) do
    order =
      params
      |> Map.get("order", Map.get(params, "exists_witness_order", []))
      |> normalize_string_list()

    cond do
      order == [] ->
        {:ignored, "instantiate_exists missing non-empty order"}

      true ->
        tactics =
          tactics
          |> Map.put(:exists_domain_order, order)
          |> append_branch_queue(order)

        {:applied, tactics,
         "instantiate_exists set exists_domain_order=#{inspect(order)} and queued witness candidates"}
    end
  end

  defp replay_plan_step(:instantiate_forall, params, tactics) do
    order =
      params
      |> Map.get("order", Map.get(params, "universal_unroll_order", []))
      |> normalize_string_list()

    q_order = parse_quantifier_order(Map.get(params, "quantifier_order"))

    tactics =
      if is_nil(q_order),
        do: tactics,
        else: Map.put(tactics, :quantifier_order, q_order)

    tactics =
      if order == [],
        do: tactics,
        else: Map.put(tactics, :forall_domain_order, order)

    if is_nil(q_order) and order == [] do
      {:ignored, "instantiate_forall had no usable params"}
    else
      {:applied, tactics,
       "instantiate_forall set #{if q_order, do: "quantifier_order=#{q_order}", else: ""} #{if order != [], do: "forall_domain_order=#{inspect(order)}", else: ""}"}
    end
  end

  defp replay_plan_step(:choose_branch, params, tactics) do
    priority = parse_branch_priority(Map.get(params, "branch_priority"))
    preferred = params |> Map.get("preferred_literals", []) |> normalize_string_list()

    tactics = if is_nil(priority), do: tactics, else: Map.put(tactics, :branch_priority, priority)

    tactics =
      if preferred == [] do
        tactics
      else
        tactics
        |> Map.put(:preferred_literals, preferred)
        |> append_branch_queue(preferred)
      end

    if is_nil(priority) and preferred == [] do
      {:ignored, "choose_branch had no usable params"}
    else
      {:applied, tactics,
       "choose_branch set #{if priority, do: "branch_priority=#{priority}", else: ""} #{if preferred != [], do: "preferred_literals=#{length(preferred)}", else: ""}"}
    end
  end

  defp replay_plan_step(:propagate, params, tactics) do
    mode =
      params
      |> Map.get("mode", "unit")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    case mode do
      "unit" ->
        tactics =
          if Map.has_key?(tactics, :branch_priority),
            do: tactics,
            else: Map.put(tactics, :branch_priority, :close_fast)

        {:applied, tactics,
         "propagate(unit) replayed (mapped to branch_priority close_fast when absent)"}

      _ ->
        {:ignored, "propagate mode '#{mode}' unsupported (allowed: unit)"}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_), do: []

  defp parse_branch_priority(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "default" -> :default
      "close_fast" -> :close_fast
      "reverse" -> :reverse
      _ -> nil
    end
  end

  defp parse_branch_priority(_), do: nil

  defp parse_quantifier_order(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "default" -> :default
      "reverse" -> :reverse
      _ -> nil
    end
  end

  defp parse_quantifier_order(_), do: nil

  defp infer_tactics_from_hints(parsed) do
    text_blob =
      parsed
      |> Map.get("branching_hints", [])
      |> List.wrap()
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(text_blob, "close quickly") -> %{branch_priority: :close_fast}
      String.contains?(text_blob, "branch explosion") -> %{branch_priority: :close_fast}
      true -> %{}
    end
  end

  defp maybe_put_tactic_opts(opts, tactics) do
    [
      :branch_priority,
      :quantifier_order,
      :domain_order,
      :exists_domain_order,
      :forall_domain_order,
      :preferred_literals,
      :branch_queue
    ]
    |> Enum.reduce(opts, fn key, acc ->
      value = Map.get(tactics, key)

      cond do
        Keyword.has_key?(acc, key) -> acc
        is_nil(value) -> acc
        true -> Keyword.put(acc, key, value)
      end
    end)
  end

  defp format_tactic_usage_applied(tactics) when map_size(tactics) == 0, do: []

  defp format_tactic_usage_applied(tactics) do
    tactics
    |> Enum.map(fn
      {:branch_priority, v} ->
        "Applied branch_priority=#{v} for OR-branch ordering"

      {:quantifier_order, v} ->
        "Applied quantifier_order=#{v} for quantifier instantiation order"

      {:domain_order, v} when is_list(v) ->
        "Applied domain_order with #{length(v)} preferred constants"

      {:preferred_literals, v} when is_list(v) ->
        "Applied preferred_literals with #{length(v)} branch literal hints"

      {:branch_queue, v} when is_list(v) ->
        "Applied branch_queue with #{length(v)} queued branch targets"

      {:exists_domain_order, v} when is_list(v) ->
        "Applied exists_domain_order with #{length(v)} preferred witness values"

      {:forall_domain_order, v} when is_list(v) ->
        "Applied forall_domain_order with #{length(v)} preferred unroll values"

      {k, v} ->
        "Applied #{k}=#{inspect(v)}"
    end)
  end

  defp build_symbolic_execution_summary(
         symbolic_opts,
         execution_plan_audit,
         guided_result,
         symbolic_result,
         validation
       ) do
    applied = Enum.count(execution_plan_audit, &(&1.status == :applied))
    ignored = Enum.count(execution_plan_audit, &(&1.status == :ignored))
    guided_steps = Map.get(guided_result, :symbolic_steps, [])

    guided_steps_preview =
      guided_steps
      |> Enum.take(20)
      |> Enum.map(&Map.get(&1, :message, ""))

    %{
      guided_solver_opts: compact_solver_opts(symbolic_opts),
      guided_status: Map.get(guided_result, :status),
      guided_reason: Map.get(guided_result, :reason),
      guided_true_atoms_count: guided_result |> Map.get(:true_atoms, []) |> length(),
      llm_guided: get_in(guided_result, [:symbolic_solver_opts, :llm_guided]) || false,
      llm_guided_keys: get_in(guided_result, [:symbolic_solver_opts, :llm_guided_keys]) || [],
      guided_symbolic_steps_count: length(guided_steps),
      guided_symbolic_steps_truncated?: Map.get(guided_result, :symbolic_steps_truncated?, false),
      guided_symbolic_steps_preview: guided_steps_preview,
      execution_plan_steps: %{
        total: length(execution_plan_audit),
        applied: applied,
        ignored: ignored
      },
      validation_performed: Map.get(validation, :performed, false),
      final_status: Map.get(symbolic_result, :status)
    }
  end

  defp compact_solver_opts(opts) when is_list(opts) do
    opts
    |> Keyword.take([
      :branch_priority,
      :quantifier_order,
      :domain_order,
      :exists_domain_order,
      :forall_domain_order,
      :preferred_literals,
      :branch_queue,
      :strict_hybrid,
      :llm_guided,
      :llm_guided_keys,
      :domain,
      :debug
    ])
  end

  defp compact_solver_opts(_), do: []

  defp effective_llm_guided_keys(user_opts, tactics, strict_hybrid?) when is_map(tactics) do
    guided =
      [
        :branch_priority,
        :quantifier_order,
        :domain_order,
        :exists_domain_order,
        :forall_domain_order,
        :preferred_literals,
        :branch_queue
      ]
      |> Enum.filter(fn key ->
        Map.has_key?(tactics, key) and not Keyword.has_key?(user_opts, key)
      end)

    if strict_hybrid?, do: Enum.uniq(guided ++ [:strict_hybrid]), else: guided
  end

  defp effective_llm_guided_keys(_user_opts, _tactics, _strict_hybrid?), do: []

  defp append_branch_queue(tactics, []), do: tactics

  defp append_branch_queue(tactics, values) when is_list(values) do
    existing = Map.get(tactics, :branch_queue, [])
    merged = (existing ++ values) |> Enum.map(&to_string/1) |> Enum.uniq()
    Map.put(tactics, :branch_queue, merged)
  end

  defp time_it(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    value = fun.()
    elapsed = System.monotonic_time(:millisecond) - start
    {value, elapsed}
  end

  defp add_step(trace, level, title, detail) do
    [
      %{
        level: level,
        title: title,
        detail: detail,
        timestamp: DateTime.utc_now()
      }
      | trace
    ]
  end

  defp finalize_steps(trace) do
    trace
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {step, idx} -> Map.put(step, :index, idx) end)
  end

  defp preview_formula(text) when is_binary(text), do: truncate_text(text, 700)

  defp preview_formula(ast) do
    ast
    |> Tableaux.to_human()
    |> truncate_text(700)
  rescue
    _ ->
      ast
      |> inspect()
      |> truncate_text(700)
  end

  defp truncate_text(text, max) when is_binary(text) and is_integer(max) and max > 0 do
    if String.length(text) > max do
      String.slice(text, 0, max) <> " ...[truncated]"
    else
      text
    end
  end
end
