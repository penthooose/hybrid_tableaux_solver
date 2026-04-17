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
    roles = Keyword.get(opts, :roles, [:axiom])

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
    results = Enum.map(blocks, &parse_fof_block/1)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, Enum.map(results, fn {:ok, e} -> e end)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_fof_blocks(content) when is_binary(content) do
    cleaned = strip_comments(content)
    do_extract_blocks(cleaned, 0, [])
  end

  defp do_extract_blocks(text, pos, acc) do
    case next_fof_start(text, pos) do
      :nomatch ->
        {:ok, Enum.reverse(acc)}

      {:ok, start} ->
        case find_fof_end(text, start + 4, 1) do
          {:ok, stop} ->
            block = binary_part(text, start, stop - start + 1)
            do_extract_blocks(text, stop + 1, [block | acc])

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp next_fof_start(text, pos) do
    size = byte_size(text)

    if pos >= size do
      :nomatch
    else
      slice = binary_part(text, pos, size - pos)

      case :binary.match(slice, "fof(") do
        {idx, _len} -> {:ok, pos + idx}
        :nomatch -> :nomatch
      end
    end
  end

  defp find_fof_end(text, pos, depth) when depth >= 0 do
    size = byte_size(text)

    cond do
      pos >= size ->
        {:error, "Unterminated fof(...) block"}

      true ->
        ch = :binary.at(text, pos)

        cond do
          ch == ?( ->
            find_fof_end(text, pos + 1, depth + 1)

          ch == ?) and depth - 1 == 0 ->
            dot_pos = skip_ws(text, pos + 1)

            if dot_pos < size and :binary.at(text, dot_pos) == ?. do
              {:ok, dot_pos}
            else
              find_fof_end(text, pos + 1, depth - 1)
            end

          ch == ?) ->
            find_fof_end(text, pos + 1, depth - 1)

          true ->
            find_fof_end(text, pos + 1, depth)
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

  defp parse_fof_block(block) do
    inner =
      block
      |> String.trim()
      |> String.trim_leading("fof(")
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
        with {:ok, formula} <- parse_formula_string(formula_str) do
          {:ok,
           %{
             name: String.trim(name),
             role: parse_role(role),
             formula: formula,
             raw_formula: String.trim(formula_str)
           }}
        end

      _ ->
        {:error, "Malformed fof block: #{String.slice(String.trim(block), 0, 120)}..."}
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

  defp parse_var_list([{:ident, name} | rest], acc), do: {:ok, Enum.reverse([name | acc]), rest}
  defp parse_var_list(_tokens, _acc), do: {:error, "Invalid quantifier variable list"}

  defp parse_atom_formula([{:ident, "$true"} | rest]), do: {:ok, :top, rest}
  defp parse_atom_formula([{:ident, "$false"} | rest]), do: {:ok, :bot, rest}

  defp parse_atom_formula([{:ident, name}, :lparen | rest]) do
    with {:ok, args, rest2} <- parse_term_list(rest, []),
         {:ok, rest3} <- expect(rest2, :rparen) do
      {:ok, Tableaux.pred(name, Enum.map(args, &term_to_logic/1)), rest3}
    end
  end

  defp parse_atom_formula([{:ident, name} | rest]), do: {:ok, Tableaux.prop(name), rest}
  defp parse_atom_formula(_), do: {:error, "Expected atom/predicate"}

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

  defp parse_term([{:ident, name}, :lparen | rest]) do
    with {:ok, args, rest2} <- parse_term_list(rest, []),
         {:ok, rest3} <- expect(rest2, :rparen) do
      {:ok, {:fun, name, args}, rest3}
    end
  end

  defp parse_term([{:ident, name} | rest]) do
    if variable_name?(name), do: {:ok, {:var, name}, rest}, else: {:ok, {:const, name}, rest}
  end

  defp parse_term(_), do: {:error, "Expected term"}

  defp variable_name?(name) do
    String.match?(name, ~r/^[A-Z]/)
  end

  defp term_to_logic({:var, name}), do: Tableaux.var(name)
  defp term_to_logic({:const, name}), do: Tableaux.const(name)
  defp term_to_logic({:fun, name, args}), do: {:fun, name, Enum.map(args, &term_to_logic/1)}

  defp expect([token | rest], token), do: {:ok, rest}
  defp expect(_tokens, token), do: {:error, "Expected token #{inspect(token)}"}
end
