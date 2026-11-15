defmodule Xitdb.DSL.PathCompiler do
  @moduledoc false

  import Xitdb.Selector, only: [is_map_modifier: 1, is_typed_modifier: 1]
  alias Xitdb.Selector

  @type segment :: {:static, String.t()} | {:dynamic, Macro.t()}

  @doc """
  Compiles a path DSL AST expression into a folded binary literal (when static)
  or minimal `<>` binary concatenation AST (when dynamic).
  """
  @spec compile(Macro.t()) :: Macro.t()
  def compile(ast) do
    ast
    |> extract_segments(:selector)
    |> fold_and_quote()
  end

  @doc """
  Compiles an Elixir path expression AST into a runtime expression evaluating to
  a pre-tokenized `xitdb` path-step list (`[]` of step binaries, integers, `[idx]`, or `{kind, key}` tuples).
  """
  @spec compile_steps(Macro.t()) :: Macro.t()
  def compile_steps(ast) do
    ast
    |> extract_segments(:steps)
    |> segments_to_quoted_steps()
  end

  @doc false
  @spec fold_and_quote([segment()]) :: Macro.t()
  def fold_and_quote(segments) when is_list(segments) do
    segments
    |> fold_static_segments()
    |> segments_to_quoted()
  end

  @doc false
  @spec typed_modifier_segment(atom(), Macro.t(), :selector | :steps) :: term()
  def typed_modifier_segment(mod_fn, ast, mode \\ :selector)

  def typed_modifier_segment(mod_fn, {:^, _, [inner]}, mode) do
    typed_modifier_segment(mod_fn, inner, mode)
  end

  def typed_modifier_segment(:at_moment, arg, mode) do
    moment_segment(arg, mode)
  end

  def typed_modifier_segment(mod_fn, idx, mode)
      when mod_fn in [:linked, :linked_list, :linked_array_list] and is_integer(idx) do
    if mode == :steps,
      do: {:static_step, [idx]},
      else: {:static, Selector.format_step(:linked_array_list, idx)}
  end

  def typed_modifier_segment(mod_fn, {:-, _, [idx]}, mode)
      when mod_fn in [:linked, :linked_list, :linked_array_list] and is_integer(idx) do
    if mode == :steps,
      do: {:static_step, [-idx]},
      else: {:static, Selector.format_step(:linked_array_list, -idx)}
  end

  def typed_modifier_segment(mod_fn, idx, mode)
      when mod_fn in [:array, :array_list] and is_integer(idx) do
    if mode == :steps,
      do: {:static_step, idx},
      else: {:static, Selector.format_step(:array_list, idx)}
  end

  def typed_modifier_segment(mod_fn, {:-, _, [idx]}, mode)
      when mod_fn in [:array, :array_list] and is_integer(idx) do
    if mode == :steps,
      do: {:static_step, -idx},
      else: {:static, Selector.format_step(:array_list, -idx)}
  end

  def typed_modifier_segment(mod_fn, literal, :selector)
      when is_binary(literal) or
             (is_atom(literal) and not is_nil(literal) and not is_boolean(literal)) do
    {:static, Selector.format_typed_step(mod_fn, literal)}
  end

  def typed_modifier_segment(mod_fn, literal, :steps)
      when is_binary(literal) or
             (is_atom(literal) and not is_nil(literal) and not is_boolean(literal)) do
    {:static_step, static_typed_step(mod_fn, to_step_string(literal))}
  end

  def typed_modifier_segment(mod_fn, dynamic_ast, :selector) do
    {:dynamic, quote(do: Xitdb.Selector.format_typed_step(unquote(mod_fn), unquote(dynamic_ast)))}
  end

  def typed_modifier_segment(mod_fn, dynamic_ast, :steps) when mod_fn in [:hash_map, :map] do
    {:dynamic_step, quote(do: Xitdb.Selector.validate_step_key(unquote(dynamic_ast)))}
  end

  def typed_modifier_segment(mod_fn, dynamic_ast, :steps) do
    {:dynamic_step,
     quote(do: Xitdb.Selector.normalize_typed_step(unquote(mod_fn), unquote(dynamic_ast)))}
  end

  defp to_step_string(s) when is_binary(s), do: s
  defp to_step_string(a) when is_atom(a), do: Atom.to_string(a)

  defp static_typed_step(kind, val) when kind in [:hash_map, :map], do: val

  defp static_typed_step(kind, val) when kind in [:counted, :counted_map, :counted_hash_map],
    do: {:counted_hash_map, val}

  defp static_typed_step(kind, val) when kind in [:sorted, :sorted_map],
    do: {:sorted_map, val}

  defp static_typed_step(kind, val) when kind in [:set, :hash_set, :set_member],
    do: {:hash_set, val}

  defp static_typed_step(kind, val)
       when kind in [:counted_set, :counted_hash_set, :counted_set_member],
       do: {:counted_hash_set, val}

  defp static_typed_step(kind, val) when kind in [:sorted_set, :sorted_set_member],
    do: {:sorted_set, val}

  defp extract_segments(str, :selector) when is_binary(str) do
    [{:static, str}]
  end

  defp extract_segments(str, :steps) when is_binary(str) do
    Enum.map(Selector.normalize_root_or_steps(str), &{:static_step, &1})
  end

  defp extract_segments(atom, mode)
       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    if mode == :steps do
      [{:static_step, Atom.to_string(atom)}]
    else
      [{:static, Selector.format_step(:hash_map, atom)}]
    end
  end

  defp extract_segments({:sigil_x, _, _} = sigil_ast, :selector) do
    [{:dynamic, sigil_ast}]
  end

  defp extract_segments({:sigil_x, _, _} = sigil_ast, :steps) do
    [{:dynamic_steps, quote(do: Xitdb.Selector.normalize_root_or_steps(unquote(sigil_ast)))}]
  end

  defp extract_segments(list, mode) when is_list(list) do
    Enum.flat_map(list, &extract_list_step_segment(&1, mode))
  end

  defp extract_segments({:root, _, ctx}, _mode) when is_atom(ctx), do: []
  defp extract_segments({:_, _, ctx}, _mode) when is_atom(ctx), do: []

  defp extract_segments({:^, _, [pinned_expr]}, :selector) do
    [{:dynamic, quote(do: Xitdb.Selector.format_root_or_step(unquote(pinned_expr)))}]
  end

  defp extract_segments({:^, _, [pinned_expr]}, :steps) do
    [{:dynamic_steps, quote(do: Xitdb.Selector.normalize_root_or_steps(unquote(pinned_expr)))}]
  end

  defp extract_segments({:at_moment, _, [moment_ast, inner_ast]}, mode) do
    [moment_segment(moment_ast, mode) | extract_segments(inner_ast, mode)]
  end

  defp extract_segments({:path, _, [inner_ast]}, mode), do: extract_segments(inner_ast, mode)

  defp extract_segments({:path_steps, _, [inner_ast]}, mode),
    do: extract_segments(inner_ast, mode)

  defp extract_segments({mod_fn, _, [arg]}, mode) when is_typed_modifier(mod_fn) do
    [typed_modifier_segment(mod_fn, arg, mode)]
  end

  defp extract_segments({{:., _, [left, mod_fn]}, _, [arg]}, mode)
       when is_typed_modifier(mod_fn) do
    extract_segments(left, mode) ++ [typed_modifier_segment(mod_fn, arg, mode)]
  end

  defp extract_segments({{:., _, [left, field]}, _, []}, mode) when is_atom(field) do
    step_seg =
      if mode == :steps,
        do: {:static_step, Atom.to_string(field)},
        else: {:static, Selector.format_step(:hash_map, field)}

    extract_segments(left, mode) ++ [step_seg]
  end

  defp extract_segments(
         {{:., _, [Access, :get]}, _, [{{:., _, [parent, mod_fn]}, _, [container_key]}, right]},
         mode
       )
       when is_map_modifier(mod_fn) do
    extract_segments(parent, mode) ++
      [
        typed_modifier_segment(:hash_map, container_key, mode),
        typed_modifier_segment(mod_fn, right, mode)
      ]
  end

  defp extract_segments({{:., _, [Access, :get]}, _, [{mod_fn, _, [container_key]}, right]}, mode)
       when is_map_modifier(mod_fn) do
    [
      typed_modifier_segment(:hash_map, container_key, mode),
      typed_modifier_segment(mod_fn, right, mode)
    ]
  end

  defp extract_segments({{:., _, [Access, :get]}, _, [left, right]}, mode) do
    extract_segments(left, mode) ++ [extract_bracket_segment(right, mode)]
  end

  defp extract_segments({name, _, ctx}, mode) when is_atom(name) and is_atom(ctx) do
    if mode == :steps do
      [{:static_step, Atom.to_string(name)}]
    else
      [{:static, Selector.format_step(:hash_map, name)}]
    end
  end

  defp extract_segments(other, :selector) do
    [{:dynamic, quote(do: Xitdb.Selector.format_root_or_step(unquote(other)))}]
  end

  defp extract_segments(other, :steps) do
    [{:dynamic_steps, quote(do: Xitdb.Selector.normalize_root_or_steps(unquote(other)))}]
  end

  defp extract_list_step_segment([idx_ast], mode) do
    [typed_modifier_segment(:linked, idx_ast, mode)]
  end

  defp extract_list_step_segment({kind, val_ast}, mode) when is_atom(kind) do
    [typed_modifier_segment(kind, val_ast, mode)]
  end

  defp extract_list_step_segment(step_ast, mode) do
    [extract_bracket_segment(step_ast, mode)]
  end

  defp extract_bracket_segment([idx_ast], mode) do
    typed_modifier_segment(:linked, idx_ast, mode)
  end

  defp extract_bracket_segment({mod_fn, _, [arg]}, mode) when is_typed_modifier(mod_fn) do
    typed_modifier_segment(mod_fn, arg, mode)
  end

  defp extract_bracket_segment({:^, _, [inner]}, mode) do
    extract_bracket_segment(inner, mode)
  end

  defp extract_bracket_segment(idx, mode) when is_integer(idx) do
    if mode == :steps,
      do: {:static_step, idx},
      else: {:static, Selector.format_step(:array_list, idx)}
  end

  defp extract_bracket_segment({:-, _, [idx]}, mode) when is_integer(idx) do
    if mode == :steps,
      do: {:static_step, -idx},
      else: {:static, Selector.format_step(:array_list, -idx)}
  end

  defp extract_bracket_segment(key, mode)
       when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)) do
    if mode == :steps,
      do: {:static_step, to_step_string(key)},
      else: {:static, Selector.format_step(:hash_map, key)}
  end

  defp extract_bracket_segment(dynamic_ast, :selector) do
    {:dynamic, quote(do: Xitdb.Selector.format_bracket_step(unquote(dynamic_ast)))}
  end

  defp extract_bracket_segment(dynamic_ast, :steps) do
    {:dynamic_step, quote(do: Xitdb.Selector.normalize_bracket_step(unquote(dynamic_ast)))}
  end

  defp moment_segment({:^, _, [inner]}, mode), do: moment_segment(inner, mode)

  defp moment_segment(m, mode) when is_integer(m) do
    if mode == :steps, do: {:static_step, {:at_moment, m}}, else: {:static, "@#{m}"}
  end

  defp moment_segment({:-, _, [m]}, mode) when is_integer(m) do
    if mode == :steps, do: {:static_step, {:at_moment, -m}}, else: {:static, "@-#{m}"}
  end

  defp moment_segment(m_ast, :selector) do
    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(m_ast)))}
  end

  defp moment_segment(m_ast, :steps) do
    {:dynamic_step, quote(do: Xitdb.Selector.normalize_typed_step(:at_moment, unquote(m_ast)))}
  end

  defp segments_to_quoted_steps([]), do: []

  defp segments_to_quoted_steps(segments) do
    chunks =
      segments
      |> Enum.chunk_by(fn
        {:dynamic_steps, _} -> :dynamic_list
        _ -> :single
      end)
      |> Enum.map(fn
        [{:dynamic_steps, expr}] ->
          expr

        single_items ->
          Enum.map(single_items, fn
            {:static_step, step} -> Macro.escape(step)
            {:dynamic_step, expr} -> expr
          end)
      end)

    case chunks do
      [single_chunk] ->
        single_chunk

      [first | rest] ->
        Enum.reduce(rest, first, fn chunk, acc ->
          quote do
            unquote(acc) ++ unquote(chunk)
          end
        end)
    end
  end

  defp fold_static_segments(segments) do
    segments
    |> Enum.reduce([], fn
      {:static, s2}, [{:static, s1} | rest] -> [{:static, s1 <> s2} | rest]
      seg, acc -> [seg | acc]
    end)
    |> :lists.reverse()
  end

  defp segments_to_quoted([]), do: ""
  defp segments_to_quoted([{:static, s}]), do: s
  defp segments_to_quoted([{:dynamic, expr}]), do: expr

  defp segments_to_quoted(segments) do
    exprs =
      Enum.map(segments, fn
        {:static, s} -> s
        {:dynamic, expr} -> expr
      end)

    Enum.reduce(tl(exprs), hd(exprs), fn seg, acc ->
      quote do
        unquote(acc) <> unquote(seg)
      end
    end)
  end
end
