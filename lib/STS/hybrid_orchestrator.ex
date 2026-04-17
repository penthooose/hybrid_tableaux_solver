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
          route: :symbolic_only | :hybrid_llm_guided | :hybrid_fallback,
          candidate: %{candidate?: boolean(), metrics: map()} | nil,
          llm: %{
            attempted: boolean(),
            used: boolean(),
            status: :ok | :skipped | :fallback,
            model: String.t() | nil,
            reason: String.t() | nil,
            guidance: guidance() | nil
          },
          symbolic: TableauxSolver.solve_result(),
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

    {llm_block, trace, llm_time} =
      maybe_get_guidance(llm_attempt?, formula_text, candidate_info, opts, trace)

    symbolic_opts =
      opts
      |> Keyword.take([:domain, :debug])
      |> Keyword.put(:debug, Keyword.get(opts, :symbolic_debug, false))

    {symbolic_result, symbolic_time} =
      time_it(fn -> TableauxSolver.solve(formula_or_input, symbolic_opts) end)

    trace =
      add_step(
        trace,
        :info,
        "Symbolic verification finished",
        "Symbolic engine returned #{String.upcase(to_string(symbolic_result.status))}"
      )

    route = choose_route(llm_block)
    total_time = System.monotonic_time(:millisecond) - total_start

    %{
      input: formula_text,
      route: route,
      candidate: candidate_info,
      llm: llm_block,
      symbolic: symbolic_result,
      explain_steps: finalize_steps(trace),
      timings_ms: %{llm: llm_time, symbolic: symbolic_time, total: total_time}
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

    Constraints:
    - Output a RAW JSON object only (no markdown, no code fences).
    - Do not claim a final SAT/UNSAT proof; provide heuristic guidance only.
    - Keep guidance model-agnostic and verification-friendly.
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
        "confidence" => 0.42
      },
      source: :local_fallback,
      warning: "LLM call unavailable; using deterministic local guidance"
    }
  end

  defp choose_route(%{attempted: false}), do: :symbolic_only
  defp choose_route(%{status: :ok}), do: :hybrid_llm_guided
  defp choose_route(_), do: :hybrid_fallback

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
