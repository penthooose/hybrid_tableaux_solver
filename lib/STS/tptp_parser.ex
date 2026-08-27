defmodule STS.TPTPParser do
  @moduledoc """
  Lightweight parser for a practical subset of TPTP FOF files.

  Supported currently:
  - `fof(Name,Role,Formula).`
  - Quantifiers: `! [X,...] : F`, `? [X,...] : F`
  - Connectives: `~`, `&`, `|`, `=>`, `<=`, `<=>`
  - Predicates and terms with constants/variables/function terms

  Notes:
  - This is not a full TPTP implementation.
  - It is intended to bridge TPTP examples into the hybrid tableaux demo.
  """

  alias STS.Tableaux

  @known_roles ~w(axiom hypothesis assumption definition lemma conjecture negated_conjecture type plain)a

  # Standard non-conjecture roles that form the premises of a theorem.
  @premise_roles ~w(axiom hypothesis assumption definition lemma)a

  @type role :: atom()
  @type entry :: %{
          name: String.t(),
          role: role(),
          formula: Tableaux.formula(),
          raw_formula: String.t()
        }

  @spec parse_file(String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse_file(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, blocks} <- extract_fof_blocks(content),
         {:ok, entries} <- parse_blocks(blocks) do
      {:ok, entries}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec to_conjunction([entry()], keyword()) :: Tableaux.formula()
  def to_conjunction(entries, opts \\ []) when is_list(entries) do
    roles = Keyword.get(opts, :roles, @premise_roles)

    formulas =
      entries
      |> Enum.filter(fn e -> e.role in roles end)
      |> Enum.map(& &1.formula)

    case formulas do
      [] ->
        :top

      [head | tail] ->
        Enum.reduce(tail, head, fn f, acc -> Tableaux.conj(acc, f) end)
    end
  end

  @doc """
  Conjoins the (negated) conjecture onto a premise formula for theorem proving.

  `formula` is the premise conjunction (see `to_conjunction/2`); a `conjecture`
  entry is negated (classical refutation) and conjoined, while an already-
  `negated_conjecture` entry is conjoined as-is. Returns `formula` unchanged
  when the problem has no conjecture.
  """
  @spec add_conjecture(Tableaux.formula(), [entry()]) :: Tableaux.formula()
  def add_conjecture(formula, entries) when is_list(entries) do
    case Enum.find(entries, &(&1.role in [:conjecture, :negated_conjecture])) do
      nil ->
        formula

      %{role: :conjecture, formula: conjecture} ->
        Tableaux.conj(formula, Tableaux.neg(conjecture))

      %{role: :negated_conjecture, formula: conjecture} ->
        Tableaux.conj(formula, conjecture)
    end
  end

  @spec collect_constants([entry()] | Tableaux.formula()) :: [String.t()]
  def collect_constants(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn e -> collect_constants(e.formula) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def collect_constants(:top), do: []
  def collect_constants(:bot), do: []

  def collect_constants({:pred, _name, args}) do
    args
    |> Enum.flat_map(&term_constants/1)
    |> Enum.uniq()
  end

  def collect_constants({:not, f}), do: collect_constants(f)

  def collect_constants({op, f1, f2}) when op in [:and, :or, :implies, :iff] do
    (collect_constants(f1) ++ collect_constants(f2))
    |> Enum.uniq()
  end

  def collect_constants({q, _v, domain, body}) when q in [:forall, :exists] do
    domain_consts =
      case domain do
        list when is_list(list) -> Enum.flat_map(list, &term_constants/1)
        _ -> []
      end

    (domain_consts ++ collect_constants(body))
    |> Enum.uniq()
  end

  def collect_constants(_), do: []

  defp term_constants({:const, c}), do: [c]
  defp term_constants({:var, _}), do: []
  defp term_constants({:fun, _n, args}), do: Enum.flat_map(args, &term_constants/1)
  defp term_constants(_), do: []

  # ----------------
  # Block extraction
  # ----------------

  defp parse_blocks(blocks) do
    results = Enum.map(blocks, &parse_block/1)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.flat_map(results, fn {:ok, e} -> e end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_block({block, kind}) do
    case parse_block_of_kind(block, kind) do
      :skip -> {:ok, []}
      {:ok, entry} -> {:ok, [entry]}
      {:error, reason} -> {:error, reason}
    end
  end

  # Supported TPTP block kinds (formula roles).
  @block_kinds ~w(fof cnf tff thf)a

  defp extract_fof_blocks(content) when is_binary(content) do
    cleaned = strip_comments(content)
    do_extract_blocks(cleaned, 0, [])
  end

  defp do_extract_blocks(text, pos, acc) do
    case next_block_start(text, pos) do
      :nomatch ->
        {:ok, Enum.reverse(acc)}

      {:ok, start, kind} ->
        case find_block_end(text, start + byte_size(Atom.to_string(kind)) + 1, 1) do
          {:ok, stop} ->
            block = binary_part(text, start, stop - start + 1)
            do_extract_blocks(text, stop + 1, [{block, kind} | acc])

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Finds the next `fof(`/`cnf(`/`tff(`/`thf(` block start, returning
  # `{:ok, index, kind}` or `:nomatch`.
  defp next_block_start(text, pos) do
    size = byte_size(text)

    if pos >= size do
      :nomatch
    else
      slice = binary_part(text, pos, size - pos)

      candidates =
        Enum.flat_map(@block_kinds, fn kind ->
          prefix = Atom.to_string(kind) <> "("

          case :binary.match(slice, prefix) do
            {idx, _len} -> [{idx, kind}]
            :nomatch -> []
          end
        end)

      case Enum.sort_by(candidates, &elem(&1, 0)) do
        [{idx, kind} | _] -> {:ok, pos + idx, kind}
        [] -> :nomatch
      end
    end
  end

  defp find_block_end(text, pos, depth) when depth >= 0 do
    size = byte_size(text)

    cond do
      pos >= size ->
        {:error, "Unterminated TPTP block"}

      true ->
        ch = :binary.at(text, pos)

        cond do
          ch == ?( ->
            find_block_end(text, pos + 1, depth + 1)

          ch == ?) and depth - 1 == 0 ->
            dot_pos = skip_ws(text, pos + 1)

            if dot_pos < size and :binary.at(text, dot_pos) == ?. do
              {:ok, dot_pos}
            else
              find_block_end(text, pos + 1, depth - 1)
            end

          ch == ?) ->
            find_block_end(text, pos + 1, depth - 1)

          true ->
            find_block_end(text, pos + 1, depth)
        end
    end
  end

  defp skip_ws(text, pos) do
    size = byte_size(text)

    cond do
      pos >= size ->
        pos

      :binary.at(text, pos) in [?\n, ?\r, ?\t, ?\s] ->
        skip_ws(text, pos + 1)

      true ->
        pos
    end
  end

  defp strip_comments(content) do
    content
    |> String.split(["\r\n", "\n"], trim: false)
    |> Enum.map(fn line ->
      case String.split(line, "%", parts: 2) do
        [before, _comment] -> before
        [only] -> only
      end
    end)
    |> Enum.join("\n")
  end

  # ----------------
  # Block parsing
  # ----------------

  defp parse_block_of_kind(block, kind) do
    inner =
      block
      |> String.trim()
      |> String.trim_leading(Atom.to_string(kind) <> "(")
      |> String.trim_trailing(".")

    inner =
      if String.ends_with?(inner, ")") do
        String.slice(inner, 0, byte_size(inner) - 1)
      else
        inner
      end

    parts = split_top_level_commas(inner)

    case parts do
      [name, role, formula_str] ->
        role_atom = parse_role(role)

        if role_atom == :type do
          # thf(...) type declarations carry no formula to prove — skip them.
          :skip
        else
          with {:ok, formula} <- parse_formula_string(formula_str) do
            {:ok,
             %{
               name: String.trim(name),
               role: role_atom,
               formula: formula,
               raw_formula: String.trim(formula_str)
             }}
          end
        end

      _ ->
        {:error,
         "Malformed #{Atom.to_string(kind)} block: #{String.slice(String.trim(block), 0, 120)}..."}
    end
  end

  defp split_top_level_commas(text) do
    {parts, current, _pdepth, _bdepth, _in_quote} =
      text
      |> String.graphemes()
      |> Enum.reduce({[], "", 0, 0, false}, fn ch, {parts, cur, pd, bd, inq} ->
        cond do
          ch == "'" ->
            {parts, cur <> ch, pd, bd, not inq}

          inq ->
            {parts, cur <> ch, pd, bd, inq}

          ch == "(" ->
            {parts, cur <> ch, pd + 1, bd, inq}

          ch == ")" ->
            {parts, cur <> ch, pd - 1, bd, inq}

          ch == "[" ->
            {parts, cur <> ch, pd, bd + 1, inq}

          ch == "]" ->
            {parts, cur <> ch, pd, bd - 1, inq}

          ch == "," and pd == 0 and bd == 0 ->
            {[String.trim(cur) | parts], "", pd, bd, inq}

          true ->
            {parts, cur <> ch, pd, bd, inq}
        end
      end)

    Enum.reverse([String.trim(current) | parts])
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_role(role_text) do
    role =
      role_text
      |> String.trim()
      |> String.downcase()
      |> String.to_atom()

    if role in @known_roles, do: role, else: :unknown
  end

  # ----------------
  # Formula parser
  # ----------------

  defp parse_formula_string(text) when is_binary(text) do
    with {:ok, tokens} <- tokenize(text),
         {:ok, formula, rest} <- parse_formula(tokens),
         :ok <- ensure_empty(rest) do
      {:ok, formula}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # tokens
  # :lparen :rparen :lbrack :rbrack :comma :colon
  # :forall :exists :not :and :or :implies :implied_by :iff :eq :neq
  # {:ident, String.t()}

  defp tokenize(text), do: do_tokenize(String.trim(text), [])

  defp do_tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(text, acc) do
    cond do
      String.starts_with?(text, "<=>") ->
        do_tokenize(String.slice(text, 3..-1//1), [:iff | acc])

      String.starts_with?(text, "=>") ->
        do_tokenize(String.slice(text, 2..-1//1), [:implies | acc])

      String.starts_with?(text, "<=") ->
        do_tokenize(String.slice(text, 2..-1//1), [:implied_by | acc])

      String.starts_with?(text, "!=") ->
        do_tokenize(String.slice(text, 2..-1//1), [:neq | acc])

      String.starts_with?(text, "~") ->
        do_tokenize(String.slice(text, 1..-1//1), [:not | acc])

      String.starts_with?(text, "!") ->
        do_tokenize(String.slice(text, 1..-1//1), [:forall | acc])

      String.starts_with?(text, "?") ->
        do_tokenize(String.slice(text, 1..-1//1), [:exists | acc])

      String.starts_with?(text, "&") ->
        do_tokenize(String.slice(text, 1..-1//1), [:and | acc])

      String.starts_with?(text, "|") ->
        do_tokenize(String.slice(text, 1..-1//1), [:or | acc])

      String.starts_with?(text, "=") ->
        do_tokenize(String.slice(text, 1..-1//1), [:eq | acc])

      String.starts_with?(text, "@") ->
        do_tokenize(String.slice(text, 1..-1//1), [:at | acc])

      String.starts_with?(text, ">") ->
        do_tokenize(String.slice(text, 1..-1//1), [:gt | acc])

      String.starts_with?(text, "(") ->
        do_tokenize(String.slice(text, 1..-1//1), [:lparen | acc])

      String.starts_with?(text, ")") ->
        do_tokenize(String.slice(text, 1..-1//1), [:rparen | acc])

      String.starts_with?(text, "[") ->
        do_tokenize(String.slice(text, 1..-1//1), [:lbrack | acc])

      String.starts_with?(text, "]") ->
        do_tokenize(String.slice(text, 1..-1//1), [:rbrack | acc])

      String.starts_with?(text, ",") ->
        do_tokenize(String.slice(text, 1..-1//1), [:comma | acc])

      String.starts_with?(text, ":") ->
        do_tokenize(String.slice(text, 1..-1//1), [:colon | acc])

      Regex.match?(~r/^\s+/, text) ->
        do_tokenize(String.trim_leading(text), acc)

      String.starts_with?(text, "'") ->
        parse_quoted_ident(text, acc)

      true ->
        parse_ident(text, acc)
    end
  end

  defp parse_quoted_ident(text, acc) do
    rest = String.slice(text, 1..-1//1)

    case String.split(rest, "'", parts: 2) do
      [name, tail] -> do_tokenize(tail, [{:ident, name} | acc])
      _ -> {:error, "Unterminated quoted identifier in #{inspect(text)}"}
    end
  end

  defp parse_ident(text, acc) do
    case Regex.run(~r/^[A-Za-z0-9_\$]+/, text) do
      [name] ->
        tail = String.slice(text, String.length(name)..-1//1) || ""
        do_tokenize(tail, [{:ident, name} | acc])

      _ ->
        {:error, "Unexpected token near: #{inspect(String.slice(text, 0, 30))}"}
    end
  end

  defp ensure_empty([]), do: :ok
  defp ensure_empty(rest), do: {:error, "Unparsed tokens remain: #{inspect(rest)}"}

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

        [:implied_by | rest2] ->
          with {:ok, right, rest3} <- parse_implies(rest2) do
            {:ok, {:implies, right, left}, rest3}
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
    with {:ok, f, rest2} <- parse_unary(rest) do
      {:ok, {:not, f}, rest2}
    end
  end

  defp parse_unary([:forall | rest]), do: parse_quantifier(:forall, rest)
  defp parse_unary([:exists | rest]), do: parse_quantifier(:exists, rest)

  defp parse_unary([:lparen | rest]) do
    with {:ok, f, rest2} <- parse_formula(rest),
         {:ok, rest3} <- expect(rest2, :rparen) do
      {:ok, f, rest3}
    end
  end

  defp parse_unary(tokens), do: parse_atom_formula(tokens)

  defp parse_quantifier(kind, [:lbrack | rest]) do
    with {:ok, vars, rest2} <- parse_var_list(rest, []),
         {:ok, rest3} <- expect(rest2, :rbrack),
         {:ok, rest4} <- expect(rest3, :colon),
         {:ok, body, rest5} <- parse_formula(rest4) do
      formula =
        Enum.reduce(Enum.reverse(vars), body, fn var_name, acc ->
          if kind == :forall,
            do: Tableaux.for_all(var_name, nil, acc),
            else: Tableaux.exists(var_name, nil, acc)
        end)

      {:ok, formula, rest5}
    end
  end

  defp parse_quantifier(_kind, _tokens), do: {:error, "Expected [var,...] after quantifier"}

  defp parse_var_list([{:ident, name}, :comma | rest], acc),
    do: parse_var_list(rest, [name | acc])

  # Typed THF variable list entry: `[X: $i, ...]` — skip the type annotation.
  defp parse_var_list([{:ident, name}, :colon | rest], acc) do
    with {:ok, rest2} <- skip_type(rest, 0) do
      case rest2 do
        [:comma | rest3] -> parse_var_list(rest3, [name | acc])
        [:rbrack | _] = r -> {:ok, Enum.reverse([name | acc]), r}
        _ -> {:error, "Invalid quantifier variable list"}
      end
    end
  end

  defp parse_var_list([{:ident, name} | rest], acc), do: {:ok, Enum.reverse([name | acc]), rest}
  defp parse_var_list(_tokens, _acc), do: {:error, "Invalid quantifier variable list"}

  # Consume a THF type annotation (e.g. `$i`, `$o`, `$tType`, `$i > $i`) up to
  # the next top-level comma or closing bracket.
  defp skip_type([:comma | _] = rest, 0), do: {:ok, rest}
  defp skip_type([:rbrack | _] = rest, 0), do: {:ok, rest}
  defp skip_type([:lparen | rest], depth), do: skip_type(rest, depth + 1)
  defp skip_type([:rparen | rest], depth) when depth > 0, do: skip_type(rest, depth - 1)
  defp skip_type([_ | rest], depth), do: skip_type(rest, depth)
  defp skip_type([], _depth), do: {:error, "Unterminated type annotation"}

  defp parse_atom_formula([{:ident, "$true"} | rest]), do: {:ok, :top, rest}
  defp parse_atom_formula([{:ident, "$false"} | rest]), do: {:ok, :bot, rest}

  # Predicate / equality atom. `t1 = t2` is represented as an opaque predicate
  # atom `{:pred, "=", [t1, t2]}`; `t1 != t2` as `{:pred, "!=", [t1, t2]}`.
  defp parse_atom_formula(tokens) do
    with {:ok, term, rest} <- parse_term(tokens) do
      case rest do
        [:eq | rest2] ->
          with {:ok, right, rest3} <- parse_term(rest2) do
            {:ok, {:pred, "=", [term, right]}, rest3}
          end

        [:neq | rest2] ->
          with {:ok, right, rest3} <- parse_term(rest2) do
            {:ok, {:pred, "!=", [term, right]}, rest3}
          end

        _ ->
          with {:ok, pred} <- pred_from_term(term) do
            {:ok, pred, rest}
          end
      end
    end
  end

  defp pred_from_term({:fun, name, args}), do: {:ok, {:pred, name, args}}
  defp pred_from_term({:const, name}), do: {:ok, {:pred, name, []}}
  defp pred_from_term({:var, name}), do: {:ok, {:pred, name, []}}
  defp pred_from_term(_), do: {:error, "Expected atom/predicate"}

  defp parse_term_list([:rparen | _] = rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_term_list(tokens, acc) do
    with {:ok, term, rest} <- parse_term(tokens) do
      case rest do
        [:comma | rest2] -> parse_term_list(rest2, [term | acc])
        [:rparen | _] -> {:ok, Enum.reverse([term | acc]), rest}
        _ -> {:error, "Expected ',' or ')' in term list"}
      end
    end
  end

  defp parse_term(tokens), do: parse_term_app(parse_base_term(tokens))

  defp parse_base_term([{:ident, name}, :lparen | rest]) do
    with {:ok, args, rest2} <- parse_term_list(rest, []),
         {:ok, rest3} <- expect(rest2, :rparen) do
      {:ok, {:fun, name, args}, rest3}
    end
  end

  defp parse_base_term([{:ident, name} | rest]) do
    if variable_name?(name), do: {:ok, {:var, name}, rest}, else: {:ok, {:const, name}, rest}
  end

  defp parse_base_term([:lparen | rest]) do
    with {:ok, t, rest2} <- parse_term(rest),
         {:ok, rest3} <- expect(rest2, :rparen) do
      {:ok, t, rest3}
    end
  end

  defp parse_base_term(_), do: {:error, "Expected term"}

  # THF application chain: `f @ a @ b` becomes `{:fun, f, [a, b]}`.
  defp parse_term_app({:error, reason}), do: {:error, reason}

  defp parse_term_app({:ok, term, rest}) do
    case rest do
      [:at | rest2] ->
        with {:ok, arg, rest3} <- parse_term(rest2) do
          parse_term_app({:ok, apply_term(term, arg), rest3})
        end

      _ ->
        {:ok, term, rest}
    end
  end

  defp apply_term({:const, name}, arg), do: {:fun, name, [arg]}
  defp apply_term({:var, name}, arg), do: {:fun, name, [arg]}
  defp apply_term({:fun, name, args}, arg), do: {:fun, name, args ++ [arg]}
  defp apply_term(other, arg), do: {:fun, "app", [other, arg]}

  defp variable_name?(name) do
    String.match?(name, ~r/^[A-Z]/)
  end

  defp expect([token | rest], token), do: {:ok, rest}
  defp expect(_tokens, token), do: {:error, "Expected token #{inspect(token)}"}
end
