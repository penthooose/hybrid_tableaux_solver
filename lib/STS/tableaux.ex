defmodule STS.Tableaux do
  @moduledoc """
  Minimal first-order logic AST helpers for a tableaux-style SAT demonstrator.

  This module intentionally avoids set operations and focuses on:
  - propositional connectives
  - predicates with terms
  - finite-domain quantifiers
  """

  @type logic_term :: {:var, String.t()} | {:const, String.t()} | {:fun, String.t(), [logic_term]}
  @type domain :: [logic_term] | nil

  @type formula ::
          :top
          | :bot
          | {:pred, String.t(), [logic_term]}
          | {:not, formula}
          | {:and, formula, formula}
          | {:or, formula, formula}
          | {:implies, formula, formula}
          | {:iff, formula, formula}
          | {:forall, String.t(), domain, formula}
          | {:exists, String.t(), domain, formula}

  # ----- Constructors -----

  def var(name), do: {:var, to_name(name)}
  def const(name), do: {:const, to_name(name)}

  def prop(name), do: {:pred, to_name(name), []}

  def pred(name, args \\ []) when is_list(args) do
    {:pred, to_name(name), Enum.map(args, &normalize_term/1)}
  end

  def to_cond(id), do: prop(id)

  def neg({:not, x}), do: x
  def neg(x), do: {:not, x}

  def conj(x, y), do: {:and, x, y}
  def disj(x, y), do: {:or, x, y}
  def impl(x, y), do: {:implies, x, y}
  def iff(x, y), do: {:iff, x, y}

  def bot(), do: :bot
  def top(), do: :top

  def for_all(var_name, domain, formula),
    do: {:forall, to_name(var_name), normalize_domain(domain), formula}

  def exists(var_name, domain, formula),
    do: {:exists, to_name(var_name), normalize_domain(domain), formula}

  def bracket(x), do: x

  # ----- Substitution -----

  def substitute(formula, var_name, replacement) do
    var_name = to_name(var_name)
    replacement = normalize_term(replacement)
    do_substitute_formula(formula, var_name, replacement)
  end

  defp do_substitute_formula(:top, _var, _replacement), do: :top
  defp do_substitute_formula(:bot, _var, _replacement), do: :bot

  defp do_substitute_formula({:pred, name, args}, var_name, replacement) do
    {:pred, name, Enum.map(args, &do_substitute_term(&1, var_name, replacement))}
  end

  defp do_substitute_formula({:not, f}, var_name, replacement),
    do: {:not, do_substitute_formula(f, var_name, replacement)}

  defp do_substitute_formula({:and, f1, f2}, var_name, replacement),
    do:
      {:and, do_substitute_formula(f1, var_name, replacement),
       do_substitute_formula(f2, var_name, replacement)}

  defp do_substitute_formula({:or, f1, f2}, var_name, replacement),
    do:
      {:or, do_substitute_formula(f1, var_name, replacement),
       do_substitute_formula(f2, var_name, replacement)}

  defp do_substitute_formula({:implies, f1, f2}, var_name, replacement),
    do:
      {:implies, do_substitute_formula(f1, var_name, replacement),
       do_substitute_formula(f2, var_name, replacement)}

  defp do_substitute_formula({:iff, f1, f2}, var_name, replacement),
    do:
      {:iff, do_substitute_formula(f1, var_name, replacement),
       do_substitute_formula(f2, var_name, replacement)}

  defp do_substitute_formula({:forall, bound_var, domain, body}, var_name, replacement) do
    if bound_var == var_name do
      {:forall, bound_var, domain, body}
    else
      {:forall, bound_var, domain, do_substitute_formula(body, var_name, replacement)}
    end
  end

  defp do_substitute_formula({:exists, bound_var, domain, body}, var_name, replacement) do
    if bound_var == var_name do
      {:exists, bound_var, domain, body}
    else
      {:exists, bound_var, domain, do_substitute_formula(body, var_name, replacement)}
    end
  end

  defp do_substitute_formula(other, _var_name, _replacement), do: other

  defp do_substitute_term({:var, name}, var_name, replacement) when name == var_name,
    do: replacement

  defp do_substitute_term({:fun, name, args}, var_name, replacement),
    do: {:fun, name, Enum.map(args, &do_substitute_term(&1, var_name, replacement))}

  defp do_substitute_term(term, _var_name, _replacement), do: term

  # ----- Pretty Printing -----

  def to_hd(formula), do: to_human(formula)

  def to_human(formula), do: to_human(formula, 0)

  defp to_human(:top, _prec), do: "⊤"
  defp to_human(:bot, _prec), do: "⊥"

  defp to_human({:pred, name, []}, _prec), do: name

  defp to_human({:pred, name, args}, _prec) do
    args_str = Enum.map_join(args, ", ", &term_to_human/1)
    "#{name}(#{args_str})"
  end

  defp to_human({:not, x}, parent_prec) do
    rendered = "¬#{to_human(x, 5)}"
    maybe_parenthesize(rendered, parent_prec, 5)
  end

  defp to_human({:and, x, y}, parent_prec) do
    rendered = "#{to_human(x, 4)} ∧ #{to_human(y, 4)}"
    maybe_parenthesize(rendered, parent_prec, 4)
  end

  defp to_human({:or, x, y}, parent_prec) do
    rendered = "#{to_human(x, 3)} ∨ #{to_human(y, 3)}"
    maybe_parenthesize(rendered, parent_prec, 3)
  end

  defp to_human({:implies, x, y}, parent_prec) do
    rendered = "#{to_human(x, 2)} → #{to_human(y, 2)}"
    maybe_parenthesize(rendered, parent_prec, 2)
  end

  defp to_human({:iff, x, y}, parent_prec) do
    rendered = "#{to_human(x, 1)} ↔ #{to_human(y, 1)}"
    maybe_parenthesize(rendered, parent_prec, 1)
  end

  defp to_human({:forall, var_name, domain, body}, parent_prec) do
    rendered = "∀#{var_name}#{domain_to_human(domain)}. #{to_human(body, 0)}"
    maybe_parenthesize(rendered, parent_prec, 0)
  end

  defp to_human({:exists, var_name, domain, body}, parent_prec) do
    rendered = "∃#{var_name}#{domain_to_human(domain)}. #{to_human(body, 0)}"
    maybe_parenthesize(rendered, parent_prec, 0)
  end

  defp to_human(other, _prec), do: inspect(other)

  defp domain_to_human(nil), do: ""
  defp domain_to_human([]), do: " in {}"

  defp domain_to_human(domain) when is_list(domain) do
    inside = Enum.map_join(domain, ", ", &term_to_human/1)
    " in {#{inside}}"
  end

  defp term_to_human({:var, name}), do: name
  defp term_to_human({:const, name}), do: name

  defp term_to_human({:fun, name, args}) do
    inside = Enum.map_join(args, ", ", &term_to_human/1)
    "#{name}(#{inside})"
  end

  defp term_to_human(other), do: inspect(other)

  defp maybe_parenthesize(text, parent_prec, my_prec) when my_prec < parent_prec,
    do: "(#{text})"

  defp maybe_parenthesize(text, _parent_prec, _my_prec), do: text

  # ----- Analysis helpers -----

  def count_nodes(:top), do: 1
  def count_nodes(:bot), do: 1
  def count_nodes({:pred, _name, _args}), do: 1
  def count_nodes({:not, x}), do: 1 + count_nodes(x)

  def count_nodes({op, x, y}) when op in [:and, :or, :implies, :iff],
    do: 1 + count_nodes(x) + count_nodes(y)

  def count_nodes({q, _v, _d, body}) when q in [:forall, :exists], do: 1 + count_nodes(body)
  def count_nodes(_), do: 1

  # ----- Internal normalization -----

  defp normalize_term({:var, _} = term), do: term
  defp normalize_term({:const, _} = term), do: term

  defp normalize_term({:fun, name, args}),
    do: {:fun, to_name(name), Enum.map(args, &normalize_term/1)}

  defp normalize_term(name) when is_atom(name) do
    const(Atom.to_string(name))
  end

  defp normalize_term(name) when is_binary(name) do
    if variable_like?(name), do: var(name), else: const(name)
  end

  defp normalize_term(name) when is_integer(name) or is_float(name) do
    const(to_string(name))
  end

  defp normalize_term(other), do: const(to_string(other))

  defp normalize_domain(nil), do: nil
  defp normalize_domain(domain) when is_list(domain), do: Enum.map(domain, &normalize_term/1)
  defp normalize_domain(_), do: nil

  defp variable_like?(<<first::utf8, _rest::binary>>), do: first in ?A..?Z
  defp variable_like?(""), do: false

  defp to_name(name) when is_binary(name), do: name
  defp to_name(name) when is_atom(name), do: Atom.to_string(name)
  defp to_name(name), do: to_string(name)

  # ----- Macros for convenience -----

  defmacro ~~~x do
    quote do
      neg(unquote(x))
    end
  end

  defmacro left &&& right do
    quote do
      conj(unquote(left), unquote(right))
    end
  end

  defmacro left ||| right do
    quote do
      disj(unquote(left), unquote(right))
    end
  end

  defmacro left ~> right do
    quote do
      impl(unquote(left), unquote(right))
    end
  end

  defmacro left <~> right do
    quote do
      iff(unquote(left), unquote(right))
    end
  end

  defmacro all(var, domain, do: body) do
    quote do
      for_all(unquote(var), unquote(domain), unquote(body))
    end
  end

  defmacro exist(var, domain, do: body) do
    quote do
      exists(unquote(var), unquote(domain), unquote(body))
    end
  end
end
