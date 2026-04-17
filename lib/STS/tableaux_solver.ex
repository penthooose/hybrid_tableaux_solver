defmodule STS.TableauxSolver do
  @moduledoc """
  Human-readable parser + quantifier-aware tableaux satisfiability solver.

  Supported syntax examples:

    - p
    - ¬p
    - p /\ q
    - p \/ q
    - p -> q
    - p <-> q
    - forall x in {a,b}: P(x) -> Q(x)
    - exists Y. R(Y) /\ S
  """

  alias STS.Tableaux

  @type assignment :: %{String.t() => boolean()}

  @type solve_result :: %{
          status: :sat | :unsat,
          satisfiable?: boolean(),
          input: String.t() | nil,
          formula: Tableaux.formula(),
          normalized: Tableaux.formula(),
          human_formula: String.t(),
          model: assignment | nil,
          true_atoms: [String.t()],
          reason: String.t() | nil,
          symbolic_steps: [map()],
          symbolic_steps_truncated?: boolean(),
          symbolic_solver_opts: map()
        }

  @spec parse(String.t()) :: {:ok, Tableaux.formula()} | {:error, String.t()}
  def parse(input) when is_binary(input) do
    with {:ok, tokens} <- tokenize(input),
         {:ok, ast, rest} <- parse_formula(tokens),
         :ok <- ensure_no_tokens_left(rest) do
      {:ok, bind_quantified_vars(ast)}
    end
  end

  @spec parse!(String.t()) :: Tableaux.formula()
  def parse!(input) do
    case parse(input) do
      {:ok, ast} -> ast
      {:error, reason} -> raise ArgumentError, "Formula parse error: #{reason}"
    end
  end

  @spec to_human(Tableaux.formula()) :: String.t()
  def to_human(formula), do: Tableaux.to_human(formula)

  @spec solve(String.t() | Tableaux.formula(), keyword()) :: solve_result
  def solve(formula_or_input, opts \\ []) do
    debug = Keyword.get(opts, :debug, false)
    default_domain = normalize_default_domain(Keyword.get(opts, :domain, []))
    branch_priority = Keyword.get(opts, :branch_priority, :default)
    quantifier_order = Keyword.get(opts, :quantifier_order, :default)
    domain_order = normalize_domain_order(Keyword.get(opts, :domain_order, []))
    exists_domain_order = normalize_domain_order(Keyword.get(opts, :exists_domain_order, []))
    forall_domain_order = normalize_domain_order(Keyword.get(opts, :forall_domain_order, []))
    preferred_literals = normalize_preferred_literals(Keyword.get(opts, :preferred_literals, []))
    branch_queue = normalize_branch_queue(Keyword.get(opts, :branch_queue, []))
    strict_hybrid = Keyword.get(opts, :strict_hybrid, false)

    with {:ok, original_formula, input} <- normalize_input(formula_or_input),
         normalized <-
           normalize_formula(
             original_formula,
             default_domain,
             quantifier_order,
             domain_order,
             exists_domain_order,
             forall_domain_order
           ) do
      trace_state = init_trace_state(opts, debug)

      trace_state =
        trace_add(
          trace_state,
          :solver_opts,
          "symbolic solver opts: strict_hybrid=#{strict_hybrid}, branch_priority=#{branch_priority}, quantifier_order=#{quantifier_order}, domain_order=#{inspect(domain_order)}, exists_domain_order=#{inspect(exists_domain_order)}, forall_domain_order=#{inspect(forall_domain_order)}, preferred_literals=#{length(preferred_literals)}, branch_queue=#{length(branch_queue)}"
        )

      trace_state =
        maybe_add_llm_guidance_step(trace_state, opts)

      {branch_result, trace_state} =
        tableaux(
          [normalized],
          %{},
          debug,
          branch_priority,
          preferred_literals,
          branch_queue,
          trace_state
        )

      branch_result
      |> to_result(input, original_formula, normalized)
      |> attach_symbolic_trace(
        trace_state,
        opts,
        branch_priority,
        quantifier_order,
        domain_order,
        preferred_literals,
        branch_queue,
        exists_domain_order,
        forall_domain_order,
        strict_hybrid
      )
    else
      {:error, reason} ->
        %{
          status: :unsat,
          satisfiable?: false,
          input: if(is_binary(formula_or_input), do: formula_or_input, else: nil),
          formula: :bot,
          normalized: :bot,
          human_formula: "⊥",
          model: nil,
          true_atoms: [],
          reason: reason,
          symbolic_steps: [],
          symbolic_steps_truncated?: false,
          symbolic_solver_opts: %{}
        }
    end
  end

  @doc """
  Pretty, single-string summary for CLI/Livebook output.
  """
  @spec format_result(solve_result) :: String.t()
  def format_result(result) do
    model_text =
      case result.status do
        :sat ->
          atoms =
            result.true_atoms
            |> Enum.sort()
            |> Enum.join(", ")

          if atoms == "", do: "(no positive atoms needed)", else: atoms

        :unsat ->
          "-"
      end

    [
      "status: #{String.upcase(to_string(result.status))}",
      "formula: #{result.human_formula}",
      "model: #{model_text}"
    ]
    |> Enum.join("\n")
  end

  @doc """
  Lightweight heuristic for deciding when to route to an LLM-guided hybrid path.
  """
  @spec hybrid_candidate?(String.t() | Tableaux.formula(), keyword()) ::
          {:ok, %{candidate?: boolean(), metrics: map()}} | {:error, String.t()}
  def hybrid_candidate?(formula_or_input, opts \\ []) do
    default_domain = normalize_default_domain(Keyword.get(opts, :domain, []))
    quantifier_order = Keyword.get(opts, :quantifier_order, :default)
    domain_order = normalize_domain_order(Keyword.get(opts, :domain_order, []))

    with {:ok, formula, _input} <- normalize_input(formula_or_input),
         normalized <-
           normalize_formula(formula, default_domain, quantifier_order, domain_order, [], []) do
      metrics = %{
        node_count: Tableaux.count_nodes(normalized),
        atom_count: normalized |> collect_atoms() |> MapSet.size(),
        quantifier_count: count_quantifiers(formula)
      }

      # Tunable trigger for the future LLM+symbolic branch
      candidate? =
        metrics.node_count > 120 or
          metrics.atom_count > 35 or
          metrics.quantifier_count > 3

      {:ok, %{candidate?: candidate?, metrics: metrics}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------- Normalization pipeline ----------

  defp normalize_formula(
         formula,
         default_domain,
         quantifier_order,
         domain_order,
         exists_domain_order,
         forall_domain_order
       ) do
    formula
    |> eliminate_implications()
    |> nnf()
    |> expand_quantifiers(
      default_domain,
      quantifier_order,
      domain_order,
      exists_domain_order,
      forall_domain_order
    )
  end

  defp eliminate_implications(:top), do: :top
  defp eliminate_implications(:bot), do: :bot
  defp eliminate_implications({:pred, _, _} = pred), do: pred

  defp eliminate_implications({:not, x}), do: {:not, eliminate_implications(x)}

  defp eliminate_implications({:and, x, y}),
    do: {:and, eliminate_implications(x), eliminate_implications(y)}

  defp eliminate_implications({:or, x, y}),
    do: {:or, eliminate_implications(x), eliminate_implications(y)}

  defp eliminate_implications({:implies, x, y}) do
    {:or, {:not, eliminate_implications(x)}, eliminate_implications(y)}
  end

  defp eliminate_implications({:iff, x, y}) do
    x = eliminate_implications(x)
    y = eliminate_implications(y)
    {:and, {:or, {:not, x}, y}, {:or, {:not, y}, x}}
  end

  defp eliminate_implications({:forall, var_name, domain, body}),
    do: {:forall, var_name, domain, eliminate_implications(body)}

  defp eliminate_implications({:exists, var_name, domain, body}),
    do: {:exists, var_name, domain, eliminate_implications(body)}

  defp eliminate_implications(other), do: other

  defp nnf(:top), do: :top
  defp nnf(:bot), do: :bot
  defp nnf({:pred, _, _} = pred), do: pred

  defp nnf({:not, :top}), do: :bot
  defp nnf({:not, :bot}), do: :top
  defp nnf({:not, {:pred, _, _} = pred}), do: {:not, pred}
  defp nnf({:not, {:not, x}}), do: nnf(x)
  defp nnf({:not, {:and, x, y}}), do: {:or, nnf({:not, x}), nnf({:not, y})}
  defp nnf({:not, {:or, x, y}}), do: {:and, nnf({:not, x}), nnf({:not, y})}

  defp nnf({:not, {:forall, var_name, domain, body}}),
    do: {:exists, var_name, domain, nnf({:not, body})}

  defp nnf({:not, {:exists, var_name, domain, body}}),
    do: {:forall, var_name, domain, nnf({:not, body})}

  defp nnf({:not, x}), do: {:not, nnf(x)}
  defp nnf({:and, x, y}), do: {:and, nnf(x), nnf(y)}
  defp nnf({:or, x, y}), do: {:or, nnf(x), nnf(y)}
  defp nnf({:forall, var_name, domain, body}), do: {:forall, var_name, domain, nnf(body)}
  defp nnf({:exists, var_name, domain, body}), do: {:exists, var_name, domain, nnf(body)}
  defp nnf(other), do: other

  defp expand_quantifiers(
         :top,
         _default_domain,
         _quantifier_order,
         _domain_order,
         _exists_domain_order,
         _forall_domain_order
       ),
       do: :top

  defp expand_quantifiers(
         :bot,
         _default_domain,
         _quantifier_order,
         _domain_order,
         _exists_domain_order,
         _forall_domain_order
       ),
       do: :bot

  defp expand_quantifiers(
         {:pred, _, _} = pred,
         _default_domain,
         _quantifier_order,
         _domain_order,
         _exists_domain_order,
         _forall_domain_order
       ),
       do: pred

  defp expand_quantifiers(
         {:not, x},
         default_domain,
         quantifier_order,
         domain_order,
         exists_domain_order,
         forall_domain_order
       ),
       do:
         {:not,
          expand_quantifiers(
            x,
            default_domain,
            quantifier_order,
            domain_order,
            exists_domain_order,
            forall_domain_order
          )}

  defp expand_quantifiers(
         {:and, x, y},
         default_domain,
         quantifier_order,
         domain_order,
         exists_domain_order,
         forall_domain_order
       ),
       do:
         {:and,
          expand_quantifiers(
            x,
            default_domain,
            quantifier_order,
            domain_order,
            exists_domain_order,
            forall_domain_order
          ),
          expand_quantifiers(
            y,
            default_domain,
            quantifier_order,
            domain_order,
            exists_domain_order,
            forall_domain_order
          )}

  defp expand_quantifiers(
         {:or, x, y},
         default_domain,
         quantifier_order,
         domain_order,
         exists_domain_order,
         forall_domain_order
       ),
       do:
         {:or,
          expand_quantifiers(
            x,
            default_domain,
            quantifier_order,
            domain_order,
            exists_domain_order,
            forall_domain_order
          ),
          expand_quantifiers(
            y,
            default_domain,
            quantifier_order,
            domain_order,
            exists_domain_order,
            forall_domain_order
          )}

  defp expand_quantifiers(
         {:forall, var_name, domain, body},
         default_domain,
         quantifier_order,
         domain_order,
         exists_domain_order,
         forall_domain_order
       ) do
    quantifier_domain_order =
      pick_quantifier_domain_order(
        :forall,
        domain_order,
        exists_domain_order,
        forall_domain_order
      )

    domain =
      domain
      |> resolve_domain(default_domain)
      |> order_domain_values(quantifier_order, quantifier_domain_order)

    case domain do
      [] ->
        :top

      values ->
        values
        |> Enum.map(fn value ->
          body
          |> Tableaux.substitute(var_name, value)
          |> expand_quantifiers(
            default_domain,
            quantifier_order,
            domain_order,
            exists_domain_order,
            forall_domain_order
          )
        end)
        |> reduce_all(:and)
    end
  end

  defp expand_quantifiers(
         {:exists, var_name, domain, body},
         default_domain,
         quantifier_order,
         domain_order,
         exists_domain_order,
         forall_domain_order
       ) do
    quantifier_domain_order =
      pick_quantifier_domain_order(
        :exists,
        domain_order,
        exists_domain_order,
        forall_domain_order
      )

    domain =
      domain
      |> resolve_domain(default_domain)
      |> order_domain_values(quantifier_order, quantifier_domain_order)

    case domain do
      [] ->
        :bot

      values ->
        values
        |> Enum.map(fn value ->
          body
          |> Tableaux.substitute(var_name, value)
          |> expand_quantifiers(
            default_domain,
            quantifier_order,
            domain_order,
            exists_domain_order,
            forall_domain_order
          )
        end)
        |> reduce_all(:or)
    end
  end

  defp expand_quantifiers(
         other,
         _default_domain,
         _quantifier_order,
         _domain_order,
         _exists_domain_order,
         _forall_domain_order
       ),
       do: other

  defp pick_quantifier_domain_order(
         :exists,
         domain_order,
         exists_domain_order,
         _forall_domain_order
       ) do
    if exists_domain_order == [], do: domain_order, else: exists_domain_order
  end

  defp pick_quantifier_domain_order(
         :forall,
         domain_order,
         _exists_domain_order,
         forall_domain_order
       ) do
    if forall_domain_order == [], do: domain_order, else: forall_domain_order
  end

  defp reduce_all([], :and), do: :top
  defp reduce_all([], :or), do: :bot
  defp reduce_all([single], _op), do: single

  defp reduce_all([head | tail], :and),
    do: Enum.reduce(tail, head, fn x, acc -> {:and, acc, x} end)

  defp reduce_all([head | tail], :or), do: Enum.reduce(tail, head, fn x, acc -> {:or, acc, x} end)

  # ---------- Tableaux engine ----------

  defp tableaux(
         [],
         assignment,
         _debug,
         _branch_priority,
         _preferred_literals,
         _branch_queue,
         trace_state
       ),
       do: {{:sat, assignment}, trace_state}

  defp tableaux(
         [formula | rest],
         assignment,
         debug,
         branch_priority,
         preferred_literals,
         branch_queue,
         trace_state
       ) do
    trace_state =
      trace_add(trace_state, :expand, "expanding: #{Tableaux.to_human(formula)}", %{
        formula: formula
      })

    if debug, do: IO.puts("expanding: #{Tableaux.to_human(formula)}")

    case formula do
      :top ->
        trace_state = trace_add(trace_state, :simplify, "expanded ⊤ (no-op)")

        tableaux(
          rest,
          assignment,
          debug,
          branch_priority,
          preferred_literals,
          branch_queue,
          trace_state
        )

      :bot ->
        {:unsat, trace_add(trace_state, :branch_closed, "encountered ⊥ (branch closed)")}

      {:and, x, y} ->
        trace_state =
          trace_add(
            trace_state,
            :decompose_and,
            "decompose conjunction: #{Tableaux.to_human(x)}  AND  #{Tableaux.to_human(y)}",
            %{left: Tableaux.to_human(x), right: Tableaux.to_human(y)}
          )

        tableaux(
          [x, y | rest],
          assignment,
          debug,
          branch_priority,
          preferred_literals,
          branch_queue,
          trace_state
        )

      {:or, x, y} ->
        {first_branch, second_branch} =
          order_or_branches(x, y, assignment, branch_priority, preferred_literals, branch_queue)

        guidance_tag =
          guidance_tag(trace_state, [:branch_priority, :preferred_literals, :branch_queue])

        trace_state =
          trace_add(
            trace_state,
            :choose_branch,
            "#{guidance_tag} choose branch order (mode=#{branch_priority}): first=#{Tableaux.to_human(first_branch)} | second=#{Tableaux.to_human(second_branch)}",
            %{
              first: Tableaux.to_human(first_branch),
              second: Tableaux.to_human(second_branch),
              mode: branch_priority
            }
          )

        {first_result, trace_state} =
          tableaux(
            [first_branch | rest],
            assignment,
            debug,
            branch_priority,
            preferred_literals,
            branch_queue,
            trace_state
          )

        case first_result do
          {:sat, _} = sat ->
            {sat, trace_state}

          :unsat ->
            trace_state =
              trace_add(trace_state, :backtrack, "first branch closed; trying alternate")

            tableaux(
              [second_branch | rest],
              assignment,
              debug,
              branch_priority,
              preferred_literals,
              branch_queue,
              trace_state
            )
        end

      _ ->
        case literal_info(formula) do
          {:ok, atom_name, truth_value} ->
            extend_assignment(
              atom_name,
              truth_value,
              rest,
              assignment,
              debug,
              branch_priority,
              preferred_literals,
              branch_queue,
              trace_state
            )

          :non_literal ->
            # Should be rare after normalization; try to continue conservatively.
            trace_state =
              trace_add(
                trace_state,
                :skip_non_literal,
                "non-literal encountered after normalization; skipping",
                %{formula: Tableaux.to_human(formula)}
              )

            tableaux(
              rest,
              assignment,
              debug,
              branch_priority,
              preferred_literals,
              branch_queue,
              trace_state
            )
        end
    end
  end

  defp extend_assignment(
         atom_name,
         truth_value,
         rest,
         assignment,
         _debug,
         branch_priority,
         preferred_literals,
         branch_queue,
         trace_state
       ) do
    case Map.get(assignment, atom_name) do
      nil ->
        trace_state =
          trace_add(
            trace_state,
            :assign,
            "assign literal: #{if(truth_value, do: "", else: "¬")}#{atom_name}",
            %{atom: atom_name, truth: truth_value}
          )

        tableaux(
          rest,
          Map.put(assignment, atom_name, truth_value),
          false,
          branch_priority,
          preferred_literals,
          branch_queue,
          trace_state
        )

      ^truth_value ->
        trace_state =
          trace_add(
            trace_state,
            :assign_consistent,
            "literal already consistent: #{if(truth_value, do: "", else: "¬")}#{atom_name}",
            %{atom: atom_name, truth: truth_value}
          )

        tableaux(
          rest,
          assignment,
          false,
          branch_priority,
          preferred_literals,
          branch_queue,
          trace_state
        )

      _opposite ->
        {:unsat,
         trace_add(
           trace_state,
           :contradiction,
           "contradiction on literal #{if(truth_value, do: "", else: "¬")}#{atom_name} (branch closed)",
           %{atom: atom_name, truth: truth_value}
         )}
    end
  end

  defp order_or_branches(x, y, _assignment, :default, preferred_literals, branch_queue) do
    {x, y}
    |> maybe_prefer_branch_queue(branch_queue)
    |> maybe_prefer_literals(preferred_literals)
  end

  defp order_or_branches(x, y, _assignment, :reverse, preferred_literals, branch_queue) do
    {y, x}
    |> maybe_prefer_branch_queue(branch_queue)
    |> maybe_prefer_literals(preferred_literals)
  end

  defp order_or_branches(x, y, assignment, :close_fast, preferred_literals, branch_queue) do
    sx = closure_potential(x, assignment)
    sy = closure_potential(y, assignment)

    pair = if sy > sx, do: {y, x}, else: {x, y}

    pair
    |> maybe_prefer_branch_queue(branch_queue)
    |> maybe_prefer_literals(preferred_literals)
  end

  defp order_or_branches(x, y, _assignment, _other, preferred_literals, branch_queue) do
    {x, y}
    |> maybe_prefer_branch_queue(branch_queue)
    |> maybe_prefer_literals(preferred_literals)
  end

  defp maybe_prefer_branch_queue({first, second}, branch_queue) when is_list(branch_queue) do
    if branch_queue == [] do
      {first, second}
    else
      s_first = branch_queue_score(first, branch_queue)
      s_second = branch_queue_score(second, branch_queue)

      if s_second > s_first, do: {second, first}, else: {first, second}
    end
  end

  defp maybe_prefer_branch_queue(pair, _), do: pair

  defp branch_queue_score(formula, branch_queue) do
    text =
      try do
        formula
        |> Tableaux.to_human()
        |> String.downcase()
      rescue
        _ -> formula |> inspect() |> String.downcase()
      end

    branch_queue
    |> Enum.with_index()
    |> Enum.reduce(0, fn {token, idx}, acc ->
      token_text = token |> to_string() |> String.downcase()

      if token_text != "" and String.contains?(text, token_text) do
        max(acc, 10_000 - idx)
      else
        acc
      end
    end)
  end

  defp maybe_prefer_literals({first, second}, preferred_literals)
       when is_list(preferred_literals) do
    if preferred_literals == [] do
      {first, second}
    else
      s_first = literal_preference_score(first, preferred_literals)
      s_second = literal_preference_score(second, preferred_literals)

      if s_second > s_first, do: {second, first}, else: {first, second}
    end
  end

  defp maybe_prefer_literals(pair, _), do: pair

  defp literal_preference_score(formula, preferred_literals) do
    text =
      try do
        formula
        |> Tableaux.to_human()
        |> String.downcase()
      rescue
        _ -> formula |> inspect() |> String.downcase()
      end

    preferred_literals
    |> Enum.count(fn lit -> String.contains?(text, lit) end)
  end

  defp closure_potential(formula, assignment) do
    case literal_info(formula) do
      {:ok, atom_name, truth_value} ->
        case Map.get(assignment, atom_name) do
          nil -> 0
          ^truth_value -> 1
          _ -> 3
        end

      :non_literal ->
        case formula do
          {:and, a, b} -> closure_potential(a, assignment) + closure_potential(b, assignment)
          {:or, a, b} -> max(closure_potential(a, assignment), closure_potential(b, assignment))
          _ -> 0
        end
    end
  end

  defp literal_info({:pred, _, _} = atom), do: {:ok, atom_key(atom), true}
  defp literal_info({:not, {:pred, _, _} = atom}), do: {:ok, atom_key(atom), false}
  defp literal_info(_), do: :non_literal

  defp atom_key({:pred, _, _} = atom), do: Tableaux.to_human(atom)

  # ---------- Result assembly ----------

  defp to_result({:sat, model}, input, formula, normalized) do
    true_atoms =
      model
      |> Enum.filter(fn {_k, v} -> v end)
      |> Enum.map(&elem(&1, 0))

    reason =
      if true_atoms == [] do
        "Found an open tableau branch (satisfied without requiring positive literals)."
      else
        "Found an open tableau branch with a consistent assignment of literals."
      end

    %{
      status: :sat,
      satisfiable?: true,
      input: input,
      formula: formula,
      normalized: normalized,
      human_formula: Tableaux.to_human(formula),
      model: model,
      true_atoms: true_atoms,
      reason: reason,
      symbolic_steps: [],
      symbolic_steps_truncated?: false,
      symbolic_solver_opts: %{}
    }
  end

  defp to_result(:unsat, input, formula, normalized) do
    %{
      status: :unsat,
      satisfiable?: false,
      input: input,
      formula: formula,
      normalized: normalized,
      human_formula: Tableaux.to_human(formula),
      model: nil,
      true_atoms: [],
      reason: "No open tableau branch found",
      symbolic_steps: [],
      symbolic_steps_truncated?: false,
      symbolic_solver_opts: %{}
    }
  end

  defp init_trace_state(opts, debug) do
    enabled = Keyword.get(opts, :trace_steps, debug)
    limit = max(Keyword.get(opts, :trace_limit, 1_500), 20)
    llm_guided = Keyword.get(opts, :llm_guided, false)

    llm_guided_keys =
      opts
      |> Keyword.get(:llm_guided_keys, [])
      |> Enum.map(&normalize_guided_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      enabled: enabled,
      limit: limit,
      count: 0,
      steps_rev: [],
      truncated?: false,
      llm_guided: llm_guided,
      llm_guided_keys: llm_guided_keys
    }
  end

  defp maybe_add_llm_guidance_step(trace_state, opts) do
    if Keyword.get(opts, :llm_guided, false) do
      keys = Keyword.get(opts, :llm_guided_keys, [])
      strict_hybrid = Keyword.get(opts, :strict_hybrid, false)

      trace_add(
        trace_state,
        :llm_guidance,
        "[LLM-guided] symbolic execution uses LLM-provided tactics for: #{inspect(keys)} (strict_hybrid=#{strict_hybrid})"
      )
    else
      trace_add(
        trace_state,
        :llm_guidance,
        "[symbolic-default] no LLM tactic influenced this run"
      )
    end
  end

  defp guidance_tag(trace_state, keys) do
    if llm_guided_for_any?(trace_state, keys), do: "[LLM-guided]", else: "[symbolic-default]"
  end

  defp llm_guided_for_any?(%{llm_guided: true, llm_guided_keys: guided_keys}, keys)
       when is_list(guided_keys) and is_list(keys) do
    Enum.any?(keys, fn key -> normalize_guided_key(key) in guided_keys end)
  end

  defp llm_guided_for_any?(_, _), do: false

  defp normalize_guided_key(key) when is_atom(key), do: key

  defp normalize_guided_key(key) when is_binary(key) do
    case key do
      "branch_priority" -> :branch_priority
      "quantifier_order" -> :quantifier_order
      "domain_order" -> :domain_order
      "preferred_literals" -> :preferred_literals
      "exists_domain_order" -> :exists_domain_order
      "forall_domain_order" -> :forall_domain_order
      "branch_queue" -> :branch_queue
      "strict_hybrid" -> :strict_hybrid
      _ -> nil
    end
  end

  defp normalize_guided_key(_), do: nil

  defp trace_add(trace_state, kind, message, meta \\ %{})

  defp trace_add(%{enabled: false} = trace_state, _kind, _message, _meta), do: trace_state

  defp trace_add(trace_state, kind, message, meta) do
    if trace_state.count >= trace_state.limit do
      if trace_state.truncated?,
        do: trace_state,
        else: %{trace_state | truncated?: true}
    else
      step = %{kind: kind, message: message, meta: meta}

      %{trace_state | count: trace_state.count + 1, steps_rev: [step | trace_state.steps_rev]}
    end
  end

  defp finalize_symbolic_steps(%{enabled: false}), do: []

  defp finalize_symbolic_steps(trace_state) do
    steps =
      trace_state.steps_rev
      |> Enum.reverse()
      |> Enum.with_index(1)
      |> Enum.map(fn {step, idx} -> Map.put(step, :index, idx) end)

    if trace_state.truncated? do
      steps ++
        [
          %{
            index: length(steps) + 1,
            kind: :trace_limit,
            message: "trace truncated at #{trace_state.limit} steps",
            meta: %{}
          }
        ]
    else
      steps
    end
  end

  defp attach_symbolic_trace(
         result,
         trace_state,
         opts,
         branch_priority,
         quantifier_order,
         domain_order,
         preferred_literals,
         branch_queue,
         exists_domain_order,
         forall_domain_order,
         strict_hybrid
       ) do
    result
    |> Map.put(:symbolic_steps, finalize_symbolic_steps(trace_state))
    |> Map.put(:symbolic_steps_truncated?, trace_state.truncated?)
    |> Map.put(:symbolic_solver_opts, %{
      branch_priority: branch_priority,
      quantifier_order: quantifier_order,
      domain_order: domain_order,
      exists_domain_order: exists_domain_order,
      forall_domain_order: forall_domain_order,
      preferred_literals: preferred_literals,
      branch_queue: branch_queue,
      strict_hybrid: strict_hybrid,
      llm_guided: Keyword.get(opts, :llm_guided, false),
      llm_guided_keys: Keyword.get(opts, :llm_guided_keys, []),
      debug: Keyword.get(opts, :debug, false)
    })
  end

  # ---------- Parser ----------

  # tokens: :not | :and | :or | :implies | :iff | :forall | :exists | :in
  #         :lparen | :rparen | :lbrace | :rbrace | :comma | :dot | :colon
  #         :true | :false | {:ident, String.t()} | {:number, String.t()}

  defp tokenize(input) when is_binary(input), do: do_tokenize(String.trim(input), [])

  defp do_tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(input, acc) do
    cond do
      whitespace_prefix?(input) ->
        do_tokenize(String.trim_leading(input), acc)

      String.starts_with?(input, "<->") ->
        do_tokenize(String.slice(input, 3..-1//1), [:iff | acc])

      String.starts_with?(input, "->") ->
        do_tokenize(String.slice(input, 2..-1//1), [:implies | acc])

      String.starts_with?(input, "/\\") or String.starts_with?(input, "∧") ->
        do_tokenize(String.slice(input, 1..-1//1), [:and | acc])

      String.starts_with?(input, "\\/") or String.starts_with?(input, "∨") ->
        do_tokenize(String.slice(input, 1..-1//1), [:or | acc])

      String.starts_with?(input, "¬") or String.starts_with?(input, "!") or
          String.starts_with?(input, "~") ->
        do_tokenize(String.slice(input, 1..-1//1), [:not | acc])

      String.starts_with?(input, "∀") ->
        do_tokenize(String.slice(input, 1..-1//1), [:forall | acc])

      String.starts_with?(input, "∃") ->
        do_tokenize(String.slice(input, 1..-1//1), [:exists | acc])

      String.starts_with?(input, "(") ->
        do_tokenize(String.slice(input, 1..-1//1), [:lparen | acc])

      String.starts_with?(input, ")") ->
        do_tokenize(String.slice(input, 1..-1//1), [:rparen | acc])

      String.starts_with?(input, "{") ->
        do_tokenize(String.slice(input, 1..-1//1), [:lbrace | acc])

      String.starts_with?(input, "}") ->
        do_tokenize(String.slice(input, 1..-1//1), [:rbrace | acc])

      String.starts_with?(input, ",") ->
        do_tokenize(String.slice(input, 1..-1//1), [:comma | acc])

      String.starts_with?(input, ":") ->
        do_tokenize(String.slice(input, 1..-1//1), [:colon | acc])

      String.starts_with?(input, ".") ->
        do_tokenize(String.slice(input, 1..-1//1), [:dot | acc])

      true ->
        case scan_identifier_or_number(input) do
          {:ok, token, rest} ->
            do_tokenize(rest, [token | acc])

          :error ->
            {:error, "Unexpected token near: #{inspect(String.slice(input, 0, 20))}"}
        end
    end
  end

  defp whitespace_prefix?(input), do: Regex.match?(~r/^\s+/, input)

  defp scan_identifier_or_number(input) do
    cond do
      Regex.match?(~r/^[A-Za-z_?][A-Za-z0-9_?]*/, input) ->
        [match] = Regex.run(~r/^[A-Za-z_?][A-Za-z0-9_?]*/, input)
        rest = String.slice(input, String.length(match)..-1//1) || ""
        {:ok, keyword_or_ident(match), rest}

      Regex.match?(~r/^[0-9]+(?:\.[0-9]+)?/, input) ->
        [match] = Regex.run(~r/^[0-9]+(?:\.[0-9]+)?/, input)
        rest = String.slice(input, String.length(match)..-1//1) || ""
        {:ok, {:number, match}, rest}

      true ->
        :error
    end
  end

  defp keyword_or_ident(text) do
    case String.downcase(text) do
      "forall" -> :forall
      "exists" -> :exists
      "in" -> :in
      "and" -> :and
      "or" -> :or
      "not" -> :not
      "true" -> true
      "false" -> false
      _ -> {:ident, text}
    end
  end

  defp ensure_no_tokens_left([]), do: :ok

  defp ensure_no_tokens_left(rest),
    do: {:error, "Could not parse trailing tokens: #{inspect(rest)}"}

  defp parse_formula(tokens), do: parse_iff(tokens)

  defp parse_iff(tokens) do
    with {:ok, left, rest} <- parse_implies(tokens) do
      parse_iff_tail(left, rest)
    end
  end

  defp parse_iff_tail(left, [:iff | rest]) do
    with {:ok, right, rest2} <- parse_implies(rest) do
      parse_iff_tail({:iff, left, right}, rest2)
    end
  end

  defp parse_iff_tail(left, rest), do: {:ok, left, rest}

  defp parse_implies(tokens) do
    with {:ok, left, rest} <- parse_or(tokens) do
      case rest do
        [:implies | rest2] ->
          with {:ok, right, rest3} <- parse_implies(rest2) do
            {:ok, {:implies, left, right}, rest3}
          end

        _ ->
          {:ok, left, rest}
      end
    end
  end

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      parse_or_tail(left, rest)
    end
  end

  defp parse_or_tail(left, [:or | rest]) do
    with {:ok, right, rest2} <- parse_and(rest) do
      parse_or_tail({:or, left, right}, rest2)
    end
  end

  defp parse_or_tail(left, rest), do: {:ok, left, rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_unary(tokens) do
      parse_and_tail(left, rest)
    end
  end

  defp parse_and_tail(left, [:and | rest]) do
    with {:ok, right, rest2} <- parse_unary(rest) do
      parse_and_tail({:and, left, right}, rest2)
    end
  end

  defp parse_and_tail(left, rest), do: {:ok, left, rest}

  defp parse_unary([:not | rest]) do
    with {:ok, expr, rest2} <- parse_unary(rest) do
      {:ok, {:not, expr}, rest2}
    end
  end

  defp parse_unary([:forall | rest]), do: parse_quantifier(:forall, rest)
  defp parse_unary([:exists | rest]), do: parse_quantifier(:exists, rest)

  defp parse_unary([:lparen | rest]) do
    with {:ok, expr, rest2} <- parse_formula(rest),
         {:ok, rest3} <- expect(rest2, :rparen) do
      {:ok, expr, rest3}
    end
  end

  defp parse_unary(tokens), do: parse_atom(tokens)

  defp parse_quantifier(kind, [{:ident, var_name} | rest]) do
    {domain, rest2} = parse_optional_domain(rest)
    rest3 = consume_optional_separator(rest2)

    with {:ok, body, rest4} <- parse_formula(rest3) do
      q =
        if kind == :forall,
          do: Tableaux.for_all(var_name, domain, body),
          else: Tableaux.exists(var_name, domain, body)

      {:ok, q, rest4}
    end
  end

  defp parse_quantifier(_kind, _tokens), do: {:error, "Expected variable name after quantifier"}

  defp parse_optional_domain([:in, :lbrace | rest]) do
    case parse_domain_terms(rest, []) do
      {:ok, domain, rest2} -> {domain, rest2}
      {:error, _} -> {nil, rest}
    end
  end

  defp parse_optional_domain(rest), do: {nil, rest}

  defp parse_domain_terms([:rbrace | rest], acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_domain_terms(tokens, acc) do
    with {:ok, term, rest} <- parse_term(tokens) do
      case rest do
        [:comma | rest2] -> parse_domain_terms(rest2, [term | acc])
        [:rbrace | rest2] -> {:ok, Enum.reverse([term | acc]), rest2}
        _ -> {:error, "Expected ',' or '}' in domain"}
      end
    end
  end

  defp consume_optional_separator([:colon | rest]), do: rest
  defp consume_optional_separator([:dot | rest]), do: rest
  defp consume_optional_separator(rest), do: rest

  defp parse_atom([true | rest]), do: {:ok, :top, rest}
  defp parse_atom([false | rest]), do: {:ok, :bot, rest}

  defp parse_atom([{:ident, name}, :lparen | rest]) do
    with {:ok, args, rest2} <- parse_arg_list(rest, []),
         {:ok, rest3} <- expect(rest2, :rparen) do
      {:ok, Tableaux.pred(name, args), rest3}
    end
  end

  defp parse_atom([{:ident, name} | rest]), do: {:ok, Tableaux.prop(name), rest}
  defp parse_atom([{:number, number} | rest]), do: {:ok, Tableaux.prop(number), rest}
  defp parse_atom(_), do: {:error, "Expected atom, predicate, or parenthesized formula"}

  defp parse_arg_list([:rparen | _] = tokens, acc), do: {:ok, Enum.reverse(acc), tokens}

  defp parse_arg_list(tokens, acc) do
    with {:ok, term, rest} <- parse_term(tokens) do
      case rest do
        [:comma | rest2] -> parse_arg_list(rest2, [term | acc])
        [:rparen | _] -> {:ok, Enum.reverse([term | acc]), rest}
        _ -> {:error, "Expected ',' or ')' in argument list"}
      end
    end
  end

  defp parse_term([{:ident, text} | rest]), do: {:ok, parse_symbol_term(text), rest}
  defp parse_term([{:number, text} | rest]), do: {:ok, Tableaux.const(text), rest}
  defp parse_term(_), do: {:error, "Expected term"}

  defp parse_symbol_term(text) do
    if variable_like?(text), do: Tableaux.var(text), else: Tableaux.const(text)
  end

  defp variable_like?(""), do: false

  defp variable_like?(text) do
    String.starts_with?(text, "?") or Regex.match?(~r/^[A-Z]/, text)
  end

  defp expect([token | rest], token), do: {:ok, rest}
  defp expect(_tokens, token), do: {:error, "Expected token #{inspect(token)}"}

  # ---------- Utility ----------

  defp normalize_input(input) when is_binary(input) do
    case parse(input) do
      {:ok, formula} -> {:ok, formula, input}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_input(formula), do: {:ok, formula, nil}

  defp normalize_default_domain(domain) when is_list(domain) do
    Enum.map(domain, fn
      {:var, _} = t -> t
      {:const, _} = t -> t
      atom when is_atom(atom) -> Tableaux.const(Atom.to_string(atom))
      text when is_binary(text) -> Tableaux.const(text)
      other -> Tableaux.const(to_string(other))
    end)
  end

  defp normalize_default_domain(_), do: []

  defp normalize_domain_order(order) when is_list(order) do
    order
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_domain_order(_), do: []

  defp normalize_preferred_literals(literals) when is_list(literals) do
    literals
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_preferred_literals(_), do: []

  defp normalize_branch_queue(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_branch_queue(_), do: []

  defp resolve_domain(nil, default_domain), do: default_domain
  defp resolve_domain([], default_domain), do: default_domain
  defp resolve_domain(domain, _default_domain), do: domain

  defp order_domain_values(values, :reverse, _domain_order), do: Enum.reverse(values)

  defp order_domain_values(values, _quantifier_order, domain_order) when is_list(domain_order) do
    if domain_order == [] do
      values
    else
      rank =
        domain_order
        |> Enum.with_index()
        |> Map.new()

      values
      |> Enum.with_index()
      |> Enum.sort_by(fn {term, idx} ->
        {Map.get(rank, String.downcase(term_name(term)), 1_000_000), idx}
      end)
      |> Enum.map(&elem(&1, 0))
    end
  end

  defp order_domain_values(values, _quantifier_order, _domain_order), do: values

  defp term_name({:const, name}) when is_binary(name), do: name
  defp term_name({:var, name}) when is_binary(name), do: name
  defp term_name({:fun, name, _args}) when is_binary(name), do: name
  defp term_name(other), do: to_string(other)

  defp collect_atoms(:top), do: MapSet.new()
  defp collect_atoms(:bot), do: MapSet.new()

  defp collect_atoms({:pred, _, _} = pred), do: MapSet.new([Tableaux.to_human(pred)])
  defp collect_atoms({:not, x}), do: collect_atoms(x)

  defp collect_atoms({op, x, y}) when op in [:and, :or, :implies, :iff] do
    MapSet.union(collect_atoms(x), collect_atoms(y))
  end

  defp collect_atoms({q, _v, _d, body}) when q in [:forall, :exists], do: collect_atoms(body)
  defp collect_atoms(_), do: MapSet.new()

  defp count_quantifiers(:top), do: 0
  defp count_quantifiers(:bot), do: 0
  defp count_quantifiers({:pred, _, _}), do: 0
  defp count_quantifiers({:not, x}), do: count_quantifiers(x)

  defp count_quantifiers({op, x, y}) when op in [:and, :or, :implies, :iff],
    do: count_quantifiers(x) + count_quantifiers(y)

  defp count_quantifiers({q, _v, _d, body}) when q in [:forall, :exists],
    do: 1 + count_quantifiers(body)

  defp count_quantifiers(_), do: 0

  # Convert constants matching bound quantified variable names into variables.
  # This keeps user syntax simple (e.g., "forall x: P(x)") while preserving
  # proper substitution behavior during quantifier expansion.
  defp bind_quantified_vars(formula, bound_vars \\ MapSet.new())

  defp bind_quantified_vars(:top, _bound_vars), do: :top
  defp bind_quantified_vars(:bot, _bound_vars), do: :bot

  defp bind_quantified_vars({:pred, name, args}, bound_vars) do
    bound_names = MapSet.new(bound_vars)

    args =
      Enum.map(args, fn
        {:const, term_name} when is_binary(term_name) ->
          if MapSet.member?(bound_names, term_name),
            do: {:var, term_name},
            else: {:const, term_name}

        other ->
          other
      end)

    {:pred, name, args}
  end

  defp bind_quantified_vars({:not, x}, bound_vars),
    do: {:not, bind_quantified_vars(x, bound_vars)}

  defp bind_quantified_vars({op, x, y}, bound_vars) when op in [:and, :or, :implies, :iff],
    do: {op, bind_quantified_vars(x, bound_vars), bind_quantified_vars(y, bound_vars)}

  defp bind_quantified_vars({q, var_name, domain, body}, bound_vars)
       when q in [:forall, :exists] do
    local_bound = MapSet.put(bound_vars, var_name)
    {q, var_name, domain, bind_quantified_vars(body, local_bound)}
  end

  defp bind_quantified_vars(other, _bound_vars), do: other
end
