defmodule Xitdb.DSL.DatalogCompiler do
  @moduledoc false

  import Xitdb.Selector, only: [is_map_modifier: 1, is_set_modifier: 1, is_typed_modifier: 1]
  alias Xitdb.DSL.PathCompiler
  alias Xitdb.Selector

  @aggregations [:count, :sum, :min, :max]
  @predicates [:starts_with, :contains]

  @doc """
  Compiles a Datalog `do ... end` block AST into a folded binary literal (when static)
  or minimal `<>` concatenation AST (when containing `^` runtime pins).
  """
  @spec compile(Macro.t(), keyword(), Macro.Env.t() | nil) :: Macro.t()
  def compile(block_ast, opts \\ [], caller \\ nil) do
    exprs =
      case block_ast do
        {:__block__, _, lines} -> lines
        single -> [single]
      end

    {find_ast, from_ast, where_ast} = extract_sections!(exprs, opts[:from], caller)
    {find_parts, find_vars} = compile_find!(find_ast, caller)
    initial_bindings = init_bindings(from_ast, find_vars, caller)
    where_clauses_ast = unwrap_where_clauses!(where_ast)

    {where_segments, _final_bindings} =
      Enum.reduce(where_clauses_ast, {[], initial_bindings}, fn
        {:<-, _, [{alias_var, _, ctx}, source_ast]}, {seg_acc, binds}
        when is_atom(alias_var) and is_atom(ctx) ->
          new_binds =
            Map.put(binds, alias_var, build_collection_binding(source_ast, alias_var, caller))

          {seg_acc, new_binds}

        clause_ast, {seg_acc, binds} ->
          clause_segs = compile_where_clause!(clause_ast, find_vars, binds, caller)

          line_segs =
            case seg_acc do
              [] -> clause_segs
              _ -> [{:static, "\n  "} | clause_segs]
            end

          {seg_acc ++ line_segs, binds}
      end)

    header = "find " <> Enum.join(find_parts, ", ") <> "\nwhere\n  "
    PathCompiler.fold_and_quote([{:static, header} | where_segments])
  end

  @doc false
  def format_literal(nil) do
    raise ArgumentError, "cannot match nil in Datalog where clause"
  end

  def format_literal(val) when is_binary(val), do: Selector.encode_quoted(val)
  def format_literal(val) when is_integer(val) or is_float(val), do: to_string(val)
  def format_literal(val) when is_boolean(val), do: Atom.to_string(val)

  def format_literal(val) when is_atom(val),
    do: Selector.encode_quoted(Atom.to_string(val))

  def format_literal(other) do
    raise ArgumentError, "unsupported Datalog literal in where clause: #{inspect(other)}"
  end

  @doc false
  def format_bracket_pin(idx) when is_integer(idx), do: "[#{idx}]"
  def format_bracket_pin([idx]) when is_integer(idx), do: "[[#{idx}]]"

  def format_bracket_pin(key) when is_binary(key),
    do: "[" <> Selector.encode_quoted(key) <> "]"

  def format_bracket_pin(key)
      when is_atom(key) and not is_nil(key) and not is_boolean(key),
      do: "[" <> Selector.encode_quoted(Atom.to_string(key)) <> "]"

  def format_bracket_pin(invalid) do
    raise ArgumentError,
          "invalid pinned bracket key in Datalog path: #{inspect(invalid)}"
  end

  defp init_bindings(nil, _find_vars, _caller), do: %{}

  defp init_bindings({alias_var, col_ast}, _find_vars, caller) when is_atom(alias_var) do
    %{alias_var => build_collection_binding(col_ast, alias_var, caller)}
  end

  defp init_bindings({col_name, _, ctx} = col_ast, find_vars, caller)
       when is_atom(col_name) and is_atom(ctx) do
    primary_var = List.first(find_vars) || :_e

    if primary_var == col_name do
      %{col_name => build_collection_binding(col_ast, col_name, caller)}
    else
      %{
        primary_var => build_collection_binding(col_ast, primary_var, caller),
        col_name => build_collection_binding(col_ast, :_e, caller)
      }
    end
  end

  defp init_bindings(col_ast, find_vars, caller) do
    primary_var = List.first(find_vars) || :e
    %{primary_var => build_collection_binding(col_ast, primary_var, caller)}
  end

  defp extract_sections!(exprs, default_from, caller) do
    exprs
    |> Enum.reduce({nil, default_from, nil}, fn
      {:find, _, args}, {_find, from, where} ->
        {args, from, where}

      {:from, _, [{op, _, [{alias_var, _, ctx}, col_ast]}]}, {find, _from, where}
      when op in [:in, :<-] and is_atom(alias_var) and is_atom(ctx) ->
        {find, {alias_var, col_ast}, where}

      {:from, _, [col_ast]}, {find, _from, where} ->
        {find, col_ast, where}

      {:where, _, [where_arg]}, {find, from, _where} ->
        {find, from, where_arg}

      other, _acc ->
        compile_error!(
          caller,
          "Unsupported clause in Xitdb.DSL.datalog/query block (expected `find`, `from`, or `where`): #{Macro.to_string(other)}"
        )
    end)
    |> case do
      {nil, _, _} ->
        compile_error!(caller, "Xitdb.DSL.query block is missing a `find` clause")

      {_, _, nil} ->
        compile_error!(caller, "Xitdb.DSL.query block is missing a `where` clause")

      sections ->
        sections
    end
  end

  defp compile_find!(find_args, caller) do
    items =
      case find_args do
        [{:{}, _, tuple_elems}] -> tuple_elems
        [{a, b}] -> [a, b]
        [list] when is_list(list) -> list
        multiple when is_list(multiple) -> multiple
      end

    Enum.map_reduce(items, [], fn
      {agg, _, [{var_name, _, ctx}]}, vars_acc
      when agg in @aggregations and is_atom(var_name) and is_atom(ctx) ->
        lvar = format_logic_var(var_name)
        {"#{agg}(#{lvar})", Enum.uniq(vars_acc ++ [normalize_var_atom(var_name)])}

      {var_name, _, ctx}, vars_acc when is_atom(var_name) and is_atom(ctx) ->
        lvar = format_logic_var(var_name)
        {lvar, Enum.uniq(vars_acc ++ [normalize_var_atom(var_name)])}

      atom, vars_acc when is_atom(atom) ->
        lvar = format_logic_var(atom)
        {lvar, Enum.uniq(vars_acc ++ [normalize_var_atom(atom)])}

      other, _vars_acc ->
        compile_error!(
          caller,
          "Invalid `find` element in Datalog query: #{Macro.to_string(other)}"
        )
    end)
  end

  defp unwrap_where_clauses!(do: {:__block__, _, lines}), do: lines
  defp unwrap_where_clauses!(do: single), do: [single]
  defp unwrap_where_clauses!(clauses) when is_list(clauses), do: clauses
  defp unwrap_where_clauses!({:__block__, _, lines}), do: lines
  defp unwrap_where_clauses!(single), do: [single]

  defp build_collection_binding(
         {{:., _, [Access, :get]}, _, _} = indexed_ast,
         _alias_var,
         caller
       ) do
    compile_path_segments(indexed_ast, [], %{}, caller)
  end

  defp build_collection_binding({mod_fn, _, [arg]}, alias_var, _caller)
       when is_map_modifier(mod_fn) do
    [
      PathCompiler.typed_modifier_segment(mod_fn, arg),
      {:static, "[#{format_logic_var(alias_var)}]"}
    ]
  end

  defp build_collection_binding({col_name, _, ctx}, alias_var, _caller)
       when is_atom(col_name) and is_atom(ctx) do
    [{:static, Selector.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
  end

  defp build_collection_binding(col_name, alias_var, _caller)
       when (is_atom(col_name) and not is_nil(col_name) and not is_boolean(col_name)) or
              is_binary(col_name) do
    [{:static, Selector.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
  end

  defp build_collection_binding(bad_ast, _alias_var, caller) do
    compile_error!(
      caller,
      "Invalid collection source in Datalog `from` / `<-` binding: #{Macro.to_string(bad_ast)}"
    )
  end

  defp compile_where_clause!({:not, _, [inner_clause]}, find_vars, binds, caller) do
    [{:static, "not "} | compile_where_clause!(inner_clause, find_vars, binds, caller)]
  end

  defp compile_where_clause!(
         {:reach, _, [{from_var, _, c1}, {to_var, _, c2}, edge_clause]},
         find_vars,
         binds,
         caller
       )
       when is_atom(from_var) and is_atom(c1) and is_atom(to_var) and is_atom(c2) do
    reach_vars =
      Enum.uniq(find_vars ++ [normalize_var_atom(from_var), normalize_var_atom(to_var)])

    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds, caller)

    [{:static, "reach(#{format_logic_var(from_var)}, #{format_logic_var(to_var)}, "}] ++
      edge_segs ++
      [{:static, ")"}]
  end

  defp compile_where_clause!(
         {:reach, _, [{from_var, _, c1}, {to_var, _, c2}, {depth_var, _, c3}, edge_clause]},
         find_vars,
         binds,
         caller
       )
       when is_atom(from_var) and is_atom(c1) and is_atom(to_var) and is_atom(c2) and
              is_atom(depth_var) and is_atom(c3) do
    reach_vars =
      Enum.uniq(
        find_vars ++
          [
            normalize_var_atom(from_var),
            normalize_var_atom(to_var),
            normalize_var_atom(depth_var)
          ]
      )

    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds, caller)

    [
      {:static,
       "reach(#{format_logic_var(from_var)}, #{format_logic_var(to_var)}, #{format_logic_var(depth_var)}, "}
    ] ++
      edge_segs ++
      [{:static, ")"}]
  end

  defp compile_where_clause!({pred, _, [arg1, arg2]}, _find_vars, _binds, caller)
       when pred in @predicates do
    [{:static, "#{pred}("}] ++
      compile_operand!(arg1, caller) ++
      [{:static, ", "}] ++
      compile_operand!(arg2, caller) ++
      [{:static, ")"}]
  end

  defp compile_where_clause!({op, _, [lhs, rhs]}, find_vars, binds, caller)
       when op in [:==, :=] do
    if datalog_path_expr?(lhs) do
      compile_path_segments(lhs, find_vars, binds, caller) ++
        [{:static, " = "}] ++
        compile_operand!(rhs, caller)
    else
      compile_operand!(lhs, caller) ++
        [{:static, " == "}] ++
        compile_operand!(rhs, caller)
    end
  end

  defp compile_where_clause!({op, _, [lhs, rhs]}, find_vars, binds, caller)
       when op in [:!=, :>, :>=, :<, :<=] do
    lhs_segs =
      if datalog_path_expr?(lhs) do
        compile_path_segments(lhs, find_vars, binds, caller)
      else
        compile_operand!(lhs, caller)
      end

    lhs_segs ++ [{:static, " #{op} "}] ++ compile_operand!(rhs, caller)
  end

  defp compile_where_clause!(
         {{:., _, [left, set_fn]}, _, [member_arg]},
         find_vars,
         binds,
         caller
       )
       when is_set_modifier(set_fn) do
    compile_path_segments(left, find_vars, binds, caller) ++
      compile_set_step!(set_fn, member_arg, caller)
  end

  defp compile_where_clause!({set_fn, _, [left, member_arg]}, find_vars, binds, caller)
       when is_set_modifier(set_fn) do
    compile_path_segments(left, find_vars, binds, caller) ++
      compile_set_step!(set_fn, member_arg, caller)
  end

  defp compile_where_clause!(other, find_vars, binds, caller) do
    if datalog_path_expr?(other) do
      compile_path_segments(other, find_vars, binds, caller)
    else
      compile_error!(caller, "Unsupported Datalog `where` clause: #{Macro.to_string(other)}")
    end
  end

  defp datalog_path_expr?({:at_moment, _, [_, _]}), do: true
  defp datalog_path_expr?({{:., _, _}, _, _}), do: true
  defp datalog_path_expr?({mod_fn, _, _}) when is_typed_modifier(mod_fn), do: true
  defp datalog_path_expr?(_), do: false

  defp compile_path_segments({:root, _, ctx}, _find_vars, _binds, _caller) when is_atom(ctx),
    do: []

  defp compile_path_segments({:_, _, ctx}, _find_vars, _binds, _caller) when is_atom(ctx),
    do: []

  defp compile_path_segments(
         {:at_moment, _, [moment_ast, inner_ast]},
         find_vars,
         binds,
         caller
       ) do
    [
      compile_moment_segment!(moment_ast, caller)
      | compile_path_segments(inner_ast, find_vars, binds, caller)
    ]
  end

  defp compile_path_segments({mod_fn, _, [arg]}, _find_vars, _binds, _caller)
       when is_typed_modifier(mod_fn) do
    [PathCompiler.typed_modifier_segment(mod_fn, arg)]
  end

  defp compile_path_segments({{:., _, [left, set_fn]}, _, [member_arg]}, find_vars, binds, caller)
       when is_set_modifier(set_fn) do
    compile_path_segments(left, find_vars, binds, caller) ++
      compile_set_step!(set_fn, member_arg, caller)
  end

  defp compile_path_segments({{:., _, [left, mod_fn]}, _, [arg]}, find_vars, binds, caller)
       when is_typed_modifier(mod_fn) do
    compile_path_segments(left, find_vars, binds, caller) ++
      [PathCompiler.typed_modifier_segment(mod_fn, arg)]
  end

  defp compile_path_segments({{:., _, [left, field]}, _, []}, find_vars, binds, caller)
       when is_atom(field) do
    compile_path_segments(left, find_vars, binds, caller) ++
      [{:static, Selector.format_step(:hash_map, field)}]
  end

  defp compile_path_segments(
         {{:., _, [Access, :get]}, _, [{root_name, _, ctx}, right]},
         find_vars,
         binds,
         caller
       )
       when is_atom(root_name) and is_atom(ctx) do
    base_segs =
      cond do
        root_name in [:root, :_] -> []
        Map.has_key?(binds, root_name) -> Map.fetch!(binds, root_name)
        true -> [{:static, Selector.format_step(:hash_map, root_name)}]
      end

    base_segs ++ [compile_bracket_step!(right, find_vars, caller)]
  end

  defp compile_path_segments(
         {{:., _, [Access, :get]}, _, [left, right]},
         find_vars,
         binds,
         caller
       ) do
    compile_path_segments(left, find_vars, binds, caller) ++
      [compile_bracket_step!(right, find_vars, caller)]
  end

  defp compile_path_segments({name, _, ctx}, find_vars, binds, _caller)
       when is_atom(name) and is_atom(ctx) do
    norm = normalize_var_atom(name)

    cond do
      Map.has_key?(binds, norm) -> Map.fetch!(binds, norm)
      norm in find_vars -> [{:static, "[#{format_logic_var(norm)}]"}]
      true -> [{:static, Selector.format_step(:hash_map, name)}]
    end
  end

  defp compile_path_segments(bad_ast, _find_vars, _binds, caller) do
    compile_error!(
      caller,
      "Invalid path expression in Datalog clause: #{Macro.to_string(bad_ast)}"
    )
  end

  defp compile_moment_segment!(m, _caller) when is_integer(m), do: {:static, "@#{m}"}
  defp compile_moment_segment!({:-, _, [m]}, _caller) when is_integer(m), do: {:static, "@-#{m}"}

  defp compile_moment_segment!({:^, _, [pinned_expr]}, _caller) do
    {:dynamic, quote(do: "@" <> Integer.to_string(unquote(pinned_expr)))}
  end

  defp compile_moment_segment!({var_name, _, ctx}, _caller)
       when is_atom(var_name) and is_atom(ctx) do
    {:static, "@" <> format_logic_var(var_name)}
  end

  defp compile_moment_segment!(other, caller) do
    compile_error!(caller, "Invalid moment specifier in at_moment/2: #{Macro.to_string(other)}")
  end

  defp compile_bracket_step!({:^, _, [pinned_expr]}, _find_vars, _caller) do
    {:dynamic, quote(do: Xitdb.DSL.DatalogCompiler.format_bracket_pin(unquote(pinned_expr)))}
  end

  defp compile_bracket_step!([{:^, _, [pinned_expr]}], _find_vars, _caller) do
    {:dynamic, quote(do: Xitdb.DSL.DatalogCompiler.format_bracket_pin([unquote(pinned_expr)]))}
  end

  defp compile_bracket_step!([{var_name, _, ctx}], _find_vars, _caller)
       when is_atom(var_name) and is_atom(ctx) do
    {:static, "[[#{format_logic_var(var_name)}]]"}
  end

  defp compile_bracket_step!([idx], _find_vars, _caller) when is_integer(idx) do
    {:static, "[[#{idx}]]"}
  end

  defp compile_bracket_step!([{:-, _, [idx]}], _find_vars, _caller) when is_integer(idx) do
    {:static, "[[-#{idx}]]"}
  end

  defp compile_bracket_step!({var_name, _, ctx}, _find_vars, _caller)
       when is_atom(var_name) and is_atom(ctx) do
    {:static, "[#{format_logic_var(var_name)}]"}
  end

  defp compile_bracket_step!(idx, _find_vars, _caller) when is_integer(idx) do
    {:static, "[#{idx}]"}
  end

  defp compile_bracket_step!({:-, _, [idx]}, _find_vars, _caller) when is_integer(idx) do
    {:static, "[-#{idx}]"}
  end

  defp compile_bracket_step!(str, _find_vars, _caller) when is_binary(str) do
    {:static, "[" <> Selector.encode_quoted(str) <> "]"}
  end

  defp compile_bracket_step!(atom, _find_vars, _caller)
       when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    {:static, "[" <> Selector.encode_quoted(Atom.to_string(atom)) <> "]"}
  end

  defp compile_bracket_step!(other, _find_vars, caller) do
    compile_error!(
      caller,
      "Invalid bracket expression in Datalog path: #{Macro.to_string(other)}"
    )
  end

  defp compile_set_step!(set_fn, member_arg, caller) do
    prefix =
      case set_fn do
        f when f in [:set_member, :hash_set] -> "%"
        f when f in [:counted_set_member, :counted_set] -> "#%"
        f when f in [:sorted_set_member, :sorted_set] -> "^"
      end

    [{:static, prefix} | compile_operand!(member_arg, caller)]
  end

  defp compile_operand!({:^, _, [pinned_expr]}, _caller) do
    [{:dynamic, quote(do: Xitdb.DSL.DatalogCompiler.format_literal(unquote(pinned_expr)))}]
  end

  defp compile_operand!({var_name, _, ctx}, _caller) when is_atom(var_name) and is_atom(ctx) do
    [{:static, format_logic_var(var_name)}]
  end

  defp compile_operand!({:-, _, [num]}, _caller) when is_integer(num) or is_float(num) do
    [{:static, "-" <> to_string(num)}]
  end

  defp compile_operand!(literal, _caller)
       when is_binary(literal) or is_number(literal) or is_boolean(literal) or
              (is_atom(literal) and not is_nil(literal)) do
    [{:static, format_literal(literal)}]
  end

  defp compile_operand!(other, caller) do
    compile_error!(
      caller,
      "Unsupported Datalog operand (pin dynamic expressions with `^`): #{Macro.to_string(other)}"
    )
  end

  defp format_logic_var(atom) when is_atom(atom) do
    str = Atom.to_string(atom)
    if String.starts_with?(str, "?"), do: str, else: "?" <> str
  end

  defp normalize_var_atom(atom) when is_atom(atom) do
    str = Atom.to_string(atom)

    if String.starts_with?(str, "?") do
      String.to_atom(String.trim_leading(str, "?"))
    else
      atom
    end
  end

  defp compile_error!(%Macro.Env{file: file, line: line}, description) do
    raise CompileError, file: file, line: line, description: description
  end

  defp compile_error!(nil, description) do
    raise CompileError, description: description
  end
end
