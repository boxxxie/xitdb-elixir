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
    |> extract_segments()
    |> fold_and_quote()
  end

  @doc false
  @spec fold_and_quote([segment()]) :: Macro.t()
  def fold_and_quote(segments) when is_list(segments) do
    segments
    |> fold_static_segments()
    |> segments_to_quoted()
  end

  @doc false
  @spec typed_modifier_segment(atom(), Macro.t()) :: segment()
  def typed_modifier_segment(mod_fn, {:^, _, [inner]}) do
    typed_modifier_segment(mod_fn, inner)
  end

  def typed_modifier_segment(mod_fn, idx)
      when mod_fn in [:linked, :linked_list, :linked_array_list] and is_integer(idx) do
    {:static, Selector.format_step(:linked_array_list, idx)}
  end

  def typed_modifier_segment(mod_fn, {:-, _, [idx]})
      when mod_fn in [:linked, :linked_list, :linked_array_list] and is_integer(idx) do
    {:static, Selector.format_step(:linked_array_list, -idx)}
  end

  def typed_modifier_segment(mod_fn, idx)
      when mod_fn in [:array, :array_list] and is_integer(idx) do
    {:static, Selector.format_step(:array_list, idx)}
  end

  def typed_modifier_segment(mod_fn, {:-, _, [idx]})
      when mod_fn in [:array, :array_list] and is_integer(idx) do
    {:static, Selector.format_step(:array_list, -idx)}
  end

  def typed_modifier_segment(mod_fn, literal)
      when is_binary(literal) or
             (is_atom(literal) and not is_nil(literal) and not is_boolean(literal)) do
    {:static, Selector.format_typed_step(mod_fn, literal)}
  end

  def typed_modifier_segment(mod_fn, dynamic_ast) do
    {:dynamic, quote(do: Xitdb.Selector.format_typed_step(unquote(mod_fn), unquote(dynamic_ast)))}
  end

  defp extract_segments(str) when is_binary(str) do
    [{:static, str}]
  end

  defp extract_segments(atom)
       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    [{:static, Selector.format_step(:hash_map, atom)}]
  end

  defp extract_segments({:sigil_x, _, _} = sigil_ast) do
    [{:dynamic, sigil_ast}]
  end

  defp extract_segments(list) when is_list(list) do
    Enum.flat_map(list, &extract_list_step_segment/1)
  end

  defp extract_segments({:root, _, ctx}) when is_atom(ctx), do: []
  defp extract_segments({:_, _, ctx}) when is_atom(ctx), do: []

  defp extract_segments({:^, _, [pinned_expr]}) do
    [{:dynamic, quote(do: Xitdb.Selector.format_root_or_step(unquote(pinned_expr)))}]
  end

  defp extract_segments({:at_moment, _, [moment_ast, inner_ast]}) do
    [moment_segment(moment_ast) | extract_segments(inner_ast)]
  end

  defp extract_segments({mod_fn, _, [arg]}) when is_typed_modifier(mod_fn) do
    [typed_modifier_segment(mod_fn, arg)]
  end

  defp extract_segments({{:., _, [left, mod_fn]}, _, [arg]}) when is_typed_modifier(mod_fn) do
    extract_segments(left) ++ [typed_modifier_segment(mod_fn, arg)]
  end

  defp extract_segments({{:., _, [left, field]}, _, []}) when is_atom(field) do
    extract_segments(left) ++ [{:static, Selector.format_step(:hash_map, field)}]
  end

  defp extract_segments(
         {{:., _, [Access, :get]}, _, [{{:., _, [parent, mod_fn]}, _, [container_key]}, right]}
       )
       when is_map_modifier(mod_fn) do
    extract_segments(parent) ++
      [typed_modifier_segment(:hash_map, container_key), typed_modifier_segment(mod_fn, right)]
  end

  defp extract_segments({{:., _, [Access, :get]}, _, [{mod_fn, _, [container_key]}, right]})
       when is_map_modifier(mod_fn) do
    [typed_modifier_segment(:hash_map, container_key), typed_modifier_segment(mod_fn, right)]
  end

  defp extract_segments({{:., _, [Access, :get]}, _, [left, right]}) do
    extract_segments(left) ++ [extract_bracket_segment(right)]
  end

  defp extract_segments({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    [{:static, Selector.format_step(:hash_map, name)}]
  end

  defp extract_segments(other) do
    [{:dynamic, quote(do: Xitdb.Selector.format_root_or_step(unquote(other)))}]
  end

  defp extract_list_step_segment([idx_ast]) do
    [typed_modifier_segment(:linked, idx_ast)]
  end

  defp extract_list_step_segment({kind, val_ast}) when is_atom(kind) do
    [typed_modifier_segment(kind, val_ast)]
  end

  defp extract_list_step_segment(step_ast) do
    [extract_bracket_segment(step_ast)]
  end

  defp extract_bracket_segment([idx_ast]) do
    typed_modifier_segment(:linked, idx_ast)
  end

  defp extract_bracket_segment({mod_fn, _, [arg]}) when is_typed_modifier(mod_fn) do
    typed_modifier_segment(mod_fn, arg)
  end

  defp extract_bracket_segment({:^, _, [inner]}) do
    extract_bracket_segment(inner)
  end

  defp extract_bracket_segment(idx) when is_integer(idx) do
    {:static, Selector.format_step(:array_list, idx)}
  end

  defp extract_bracket_segment({:-, _, [idx]}) when is_integer(idx) do
    {:static, Selector.format_step(:array_list, -idx)}
  end

  defp extract_bracket_segment(key)
       when is_binary(key) or (is_atom(key) and not is_nil(key) and not is_boolean(key)) do
    {:static, Selector.format_step(:hash_map, key)}
  end

  defp extract_bracket_segment(dynamic_ast) do
    {:dynamic, quote(do: Xitdb.Selector.format_bracket_step(unquote(dynamic_ast)))}
  end

  defp moment_segment({:^, _, [inner]}), do: moment_segment(inner)
  defp moment_segment(m) when is_integer(m), do: {:static, "@#{m}"}
  defp moment_segment({:-, _, [m]}) when is_integer(m), do: {:static, "@-#{m}"}

  defp moment_segment(m_ast) do
    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(m_ast)))}
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
