defmodule Xitdb.DSL.DatalogCompiler do
  @moduledoc false

  import Xitdb.Selector, only: [is_set_modifier: 1, is_typed_modifier: 1]
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
    where_clauses_ast = unwrap_where_clauses!(where_ast)
    initial_bindings = init_bindings(from_ast, find_vars, where_clauses_ast, caller)
    initial_counters = %{wild: 0, cmp: 0}

    {where_segments, _final_bindings, _counters} =
      Enum.reduce(where_clauses_ast, {[], initial_bindings, initial_counters}, fn
        {:<-, _, [{alias_var, _, ctx}, source_ast]}, {seg_acc, binds, counters}
        when is_atom(alias_var) and is_atom(ctx) ->
          {source_ast2, counters} = replace_path_wildcards(source_ast, counters)
          norm_alias = normalize_var_atom(alias_var)

          new_binds =
            Map.put(
              binds,
              norm_alias,
              build_collection_binding(source_ast2, norm_alias, find_vars, binds, caller)
            )

          {seg_acc, new_binds, counters}

        clause_ast, {seg_acc, binds, counters} ->
          {expanded_clauses, counters} = expand_and_desugar_clause(clause_ast, counters)

          seg_acc =
            Enum.reduce(expanded_clauses, seg_acc, fn expanded_clause, inner_acc ->
              clause_segs = compile_where_clause!(expanded_clause, find_vars, binds, caller)

              line_segs =
                case inner_acc do
                  [] -> clause_segs
                  _ -> [{:static, "\n  "} | clause_segs]
                end

              inner_acc ++ line_segs
            end)

          {seg_acc, binds, counters}
      end)

    all_vars =
      MapSet.union(
        MapSet.new(find_vars, &format_logic_var/1),
        extract_static_vars(where_segments)
      )

    if MapSet.size(all_vars) > 16 do
      raise ArgumentError,
            "Datalog query uses #{MapSet.size(all_vars)} logic variables (maximum is 16)"
    end

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

  defp init_bindings(nil, _find_vars, _where_clauses, _caller), do: %{}

  defp init_bindings({alias_var, col_ast}, find_vars, _where_clauses, caller)
       when is_atom(alias_var) do
    norm_alias = normalize_var_atom(alias_var)
    %{norm_alias => build_collection_binding(col_ast, norm_alias, find_vars, %{}, caller)}
  end

  defp init_bindings({col_name, _, ctx} = col_ast, find_vars, where_clauses, caller)
       when is_atom(col_name) and is_atom(ctx) do
    norm_col = normalize_var_atom(col_name)
    primary_var = select_primary_var(find_vars, where_clauses, norm_col)

    if primary_var == norm_col do
      %{norm_col => build_collection_binding(col_ast, norm_col, find_vars, %{}, caller)}
    else
      %{
        primary_var => build_collection_binding(col_ast, primary_var, find_vars, %{}, caller),
        norm_col => build_collection_binding(col_ast, :_e, find_vars, %{}, caller)
      }
    end
  end

  defp init_bindings(col_ast, find_vars, where_clauses, caller) do
    primary_var = select_primary_var(find_vars, where_clauses, nil)
    %{primary_var => build_collection_binding(col_ast, primary_var, find_vars, %{}, caller)}
  end

  defp select_primary_var(find_vars, where_clauses, excluded_col) do
    rebound_vars =
      Enum.reduce(where_clauses, MapSet.new(), fn
        {:<-, _, [{alias_var, _, ctx}, _]}, acc when is_atom(alias_var) and is_atom(ctx) ->
          MapSet.put(acc, normalize_var_atom(alias_var))

        _, acc ->
          acc
      end)

    excluded =
      [:root, :_]
      |> then(fn list -> if excluded_col, do: [excluded_col | list], else: list end)
      |> MapSet.new()
      |> MapSet.union(rebound_vars)

    candidate_roots =
      where_clauses
      |> Enum.flat_map(&collect_member_root_vars(&1, find_vars, excluded))
      |> Enum.uniq()

    Enum.find(find_vars, fn var -> var in candidate_roots end) ||
      List.first(candidate_roots) ||
      List.first(find_vars) ||
      :_e
  end

  defp collect_member_root_vars(ast, find_vars, excluded) do
    {_ast, vars} =
      Macro.prewalk(ast, [], fn
        {{:., _, [left, _field]}, _, []} = node, acc ->
          case extract_root_var(left) do
            {:ok, var} ->
              if MapSet.member?(excluded, var), do: {node, acc}, else: {node, [var | acc]}

            :none ->
              {node, acc}
          end

        {{:., _, [left, mod_or_set]}, _, [_]} = node, acc
        when is_atom(mod_or_set) and mod_or_set != :get ->
          case extract_root_var(left) do
            {:ok, var} ->
              if MapSet.member?(excluded, var), do: {node, acc}, else: {node, [var | acc]}

            :none ->
              {node, acc}
          end

        {{:., _, [Access, :get]}, _, [left, _right]} = node, acc ->
          case extract_root_var(left) do
            {:ok, var} ->
              if var in find_vars and not MapSet.member?(excluded, var) do
                {node, [var | acc]}
              else
                {node, acc}
              end

            :none ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(vars)
  end

  defp extract_root_var({var, _, ctx}) when is_atom(var) and is_atom(ctx),
    do: {:ok, normalize_var_atom(var)}

  defp extract_root_var({:at_moment, _, [_, inner]}), do: extract_root_var(inner)
  defp extract_root_var({{:., _, [Access, :get]}, _, [left, _]}), do: extract_root_var(left)
  defp extract_root_var({{:., _, [left, _]}, _, _}), do: extract_root_var(left)
  defp extract_root_var(_), do: :none

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

  defp build_collection_binding({col_name, _, ctx}, alias_var, _find_vars, binds, _caller)
       when is_atom(col_name) and is_atom(ctx) do
    norm_col = normalize_var_atom(col_name)

    cond do
      norm_col in [:root, :_] ->
        [{:static, "[#{format_logic_var(alias_var)}]"}]

      Map.has_key?(binds, norm_col) ->
        Map.fetch!(binds, norm_col) ++ [{:static, "[#{format_logic_var(alias_var)}]"}]

      true ->
        [
          {:static,
           Selector.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}
        ]
    end
  end

  defp build_collection_binding(col_name, alias_var, _find_vars, _binds, _caller)
       when (is_atom(col_name) and not is_nil(col_name) and not is_boolean(col_name)) or
              is_binary(col_name) do
    [{:static, Selector.format_step(:hash_map, col_name) <> "[#{format_logic_var(alias_var)}]"}]
  end

  defp build_collection_binding(path_ast, alias_var, find_vars, binds, caller)
       when is_tuple(path_ast) do
    if binding_path_ast?(path_ast) do
      segs = compile_path_segments(path_ast, find_vars, binds, caller)

      if ends_with_alias_step?(path_ast, alias_var) do
        segs
      else
        segs ++ [{:static, "[#{format_logic_var(alias_var)}]"}]
      end
    else
      compile_error!(
        caller,
        "Invalid collection source in Datalog `from` / `<-` binding: #{Macro.to_string(path_ast)}"
      )
    end
  end

  defp build_collection_binding(bad_ast, _alias_var, _find_vars, _binds, caller) do
    compile_error!(
      caller,
      "Invalid collection source in Datalog `from` / `<-` binding: #{Macro.to_string(bad_ast)}"
    )
  end

  defp binding_path_ast?({{:., _, [Access, :get]}, _, _}), do: true
  defp binding_path_ast?({:at_moment, _, [_, _]}), do: true

  defp binding_path_ast?({{:., _, [_left, mod_fn]}, _, [_arg]}) when is_typed_modifier(mod_fn),
    do: true

  defp binding_path_ast?({{:., _, [_left, field]}, _, []}) when is_atom(field), do: true
  defp binding_path_ast?({mod_fn, _, [_arg]}) when is_typed_modifier(mod_fn), do: true
  defp binding_path_ast?(_), do: false

  defp ends_with_alias_step?(
         {{:., _, [Access, :get]}, _, [_left, {var_name, _, ctx}]},
         alias_var
       )
       when is_atom(var_name) and is_atom(ctx) do
    normalize_var_atom(var_name) == alias_var
  end

  defp ends_with_alias_step?(
         {{:., _, [Access, :get]}, _, [_left, [{var_name, _, ctx}]]},
         alias_var
       )
       when is_atom(var_name) and is_atom(ctx) do
    normalize_var_atom(var_name) == alias_var
  end

  defp ends_with_alias_step?({:at_moment, _, [_m, inner]}, alias_var) do
    ends_with_alias_step?(inner, alias_var)
  end

  defp ends_with_alias_step?(_ast, _alias_var), do: false

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
    from_norm = normalize_var_atom(from_var)
    to_norm = normalize_var_atom(to_var)

    if from_norm == to_norm do
      raise ArgumentError,
            "reach/3 requires distinct from and to logic variables, got: #{format_logic_var(from_var)}"
    end

    reach_vars = Enum.uniq(find_vars ++ [from_norm, to_norm])
    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds, caller)
    validate_reach_edge_vars!(edge_segs, from_norm, to_norm)

    [{:static, "reach(#{format_logic_var(from_norm)}, #{format_logic_var(to_norm)}, "}] ++
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
    from_norm = normalize_var_atom(from_var)
    to_norm = normalize_var_atom(to_var)
    depth_norm = normalize_var_atom(depth_var)

    if from_norm == to_norm do
      raise ArgumentError,
            "reach/4 requires distinct from and to logic variables, got: #{format_logic_var(from_var)}"
    end

    reach_vars = Enum.uniq(find_vars ++ [from_norm, to_norm, depth_norm])
    edge_segs = compile_where_clause!(edge_clause, reach_vars, binds, caller)
    validate_reach_edge_vars!(edge_segs, from_norm, to_norm)

    [
      {:static,
       "reach(#{format_logic_var(from_norm)}, #{format_logic_var(to_norm)}, #{format_logic_var(depth_norm)}, "}
    ] ++
      edge_segs ++
      [{:static, ")"}]
  end

  defp compile_where_clause!({:reach, _, args}, _find_vars, _binds, _caller) do
    raise ArgumentError,
          "reach/3,4 requires logic variables for from, to (and optional depth), got: #{Enum.map_join(args, ", ", &Macro.to_string/1)}"
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
  defp datalog_path_expr?({{:., _, [Access, :get]}, _, [_, _]}), do: true

  defp datalog_path_expr?({{:., _, [_left, mod_fn]}, _, [_]}) when is_typed_modifier(mod_fn),
    do: true

  defp datalog_path_expr?({{:., _, [_left, set_fn]}, _, [_]}) when is_set_modifier(set_fn),
    do: true

  defp datalog_path_expr?({{:., _, [left, field]}, _, []}) when is_atom(field),
    do: not match?({:__aliases__, _, _}, left)

  defp datalog_path_expr?({mod_fn, _, [_]}) when is_typed_modifier(mod_fn), do: true
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
    norm_root = normalize_var_atom(root_name)

    base_segs =
      cond do
        norm_root in [:root, :_] -> []
        Map.has_key?(binds, norm_root) -> Map.fetch!(binds, norm_root)
        norm_root in find_vars -> [{:static, "[#{format_logic_var(norm_root)}]"}]
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
      norm in [:root, :_] -> []
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

  defp validate_reach_edge_vars!(edge_segs, from_norm, to_norm) do
    edge_vars = extract_static_vars(edge_segs)
    from_str = format_logic_var(from_norm)
    to_str = format_logic_var(to_norm)

    missing =
      [from_str, to_str]
      |> Enum.reject(&MapSet.member?(edge_vars, &1))

    if missing != [] do
      raise ArgumentError,
            "reach edge clause must reference both #{from_str} and #{to_str}, missing: #{Enum.join(missing, ", ")}"
    end
  end

  defp expand_and_desugar_clause(clause_ast, counters) do
    {rewritten, counters} = replace_clause_wildcards(clause_ast, counters)
    expand_comparisons(rewritten, counters)
  end

  defp replace_clause_wildcards({:not, meta, [inner]}, counters) do
    {inner2, counters} = replace_clause_wildcards(inner, counters)
    {{:not, meta, [inner2]}, counters}
  end

  defp replace_clause_wildcards({:reach, meta, [from_ast, to_ast, edge]}, counters) do
    {edge2, counters} = replace_clause_wildcards(edge, counters)
    {{:reach, meta, [from_ast, to_ast, edge2]}, counters}
  end

  defp replace_clause_wildcards({:reach, meta, [from_ast, to_ast, depth_ast, edge]}, counters) do
    {edge2, counters} = replace_clause_wildcards(edge, counters)
    {{:reach, meta, [from_ast, to_ast, depth_ast, edge2]}, counters}
  end

  defp replace_clause_wildcards({op, meta, [lhs, rhs]}, counters)
       when op in [:==, :=, :!=, :>, :>=, :<, :<=] do
    {lhs2, counters} =
      if datalog_path_expr?(lhs),
        do: replace_path_wildcards(lhs, counters),
        else: replace_scalar_wildcards(lhs, counters)

    {rhs2, counters} =
      if datalog_path_expr?(rhs),
        do: replace_path_wildcards(rhs, counters),
        else: replace_scalar_wildcards(rhs, counters)

    {{op, meta, [lhs2, rhs2]}, counters}
  end

  defp replace_clause_wildcards({pred, meta, [arg1, arg2]}, counters) when pred in @predicates do
    {arg1_2, counters} = replace_scalar_wildcards(arg1, counters)
    {arg2_2, counters} = replace_scalar_wildcards(arg2, counters)
    {{pred, meta, [arg1_2, arg2_2]}, counters}
  end

  defp replace_clause_wildcards({{:., m1, [left, set_fn]}, m2, [member_arg]}, counters)
       when is_set_modifier(set_fn) do
    {left2, counters} = replace_path_wildcards(left, counters)
    {arg2, counters} = replace_scalar_wildcards(member_arg, counters)
    {{{:., m1, [left2, set_fn]}, m2, [arg2]}, counters}
  end

  defp replace_clause_wildcards({set_fn, meta, [left, member_arg]}, counters)
       when is_set_modifier(set_fn) do
    {left2, counters} = replace_path_wildcards(left, counters)
    {arg2, counters} = replace_scalar_wildcards(member_arg, counters)
    {{set_fn, meta, [left2, arg2]}, counters}
  end

  defp replace_clause_wildcards(other, counters) do
    if datalog_path_expr?(other) do
      replace_path_wildcards(other, counters)
    else
      {other, counters}
    end
  end

  defp replace_path_wildcards({:_, _, ctx} = node, counters) when is_atom(ctx),
    do: {node, counters}

  defp replace_path_wildcards({:at_moment, meta, [moment_ast, inner_ast]}, counters) do
    {moment2, counters} = replace_scalar_wildcards(moment_ast, counters)
    {inner2, counters} = replace_path_wildcards(inner_ast, counters)
    {{:at_moment, meta, [moment2, inner2]}, counters}
  end

  defp replace_path_wildcards({{:., m1, [Access, :get]}, m2, [left, right]}, counters) do
    {left2, counters} = replace_path_wildcards(left, counters)
    {right2, counters} = replace_bracket_wildcards(right, counters)
    {{{:., m1, [Access, :get]}, m2, [left2, right2]}, counters}
  end

  defp replace_path_wildcards({{:., m1, [left, set_fn]}, m2, [arg]}, counters)
       when is_set_modifier(set_fn) do
    {left2, counters} = replace_path_wildcards(left, counters)
    {arg2, counters} = replace_scalar_wildcards(arg, counters)
    {{{:., m1, [left2, set_fn]}, m2, [arg2]}, counters}
  end

  defp replace_path_wildcards({{:., m1, [left, mod_fn]}, m2, [arg]}, counters)
       when is_typed_modifier(mod_fn) do
    {left2, counters} = replace_path_wildcards(left, counters)
    {{{:., m1, [left2, mod_fn]}, m2, [arg]}, counters}
  end

  defp replace_path_wildcards({{:., m1, [left, field]}, m2, []}, counters) when is_atom(field) do
    {left2, counters} = replace_path_wildcards(left, counters)
    {{{:., m1, [left2, field]}, m2, []}, counters}
  end

  defp replace_path_wildcards(other, counters), do: {other, counters}

  defp replace_bracket_wildcards([inner], counters) do
    {inner2, counters} = replace_scalar_wildcards(inner, counters)
    {[inner2], counters}
  end

  defp replace_bracket_wildcards(other, counters),
    do: replace_scalar_wildcards(other, counters)

  defp replace_scalar_wildcards({:_, _, ctx}, %{wild: n} = counters) when is_atom(ctx) do
    {{:"?__wild_#{n}", [], nil}, %{counters | wild: n + 1}}
  end

  defp replace_scalar_wildcards(other, counters), do: {other, counters}

  defp expand_comparisons({:not, meta, [inner]}, counters) do
    {inner_clauses, counters} = expand_comparisons(inner, counters)
    {lead, [last]} = Enum.split(inner_clauses, -1)
    {lead ++ [{:not, meta, [last]}], counters}
  end

  defp expand_comparisons({:reach, meta, [from_ast, to_ast, edge]}, counters) do
    case expand_comparisons(edge, counters) do
      {[edge2], counters} ->
        {{:reach, meta, [from_ast, to_ast, edge2]}, counters} |> wrap_single()

      _ ->
        raise ArgumentError, "reach/3 edge clause cannot contain multi-clause comparisons"
    end
  end

  defp expand_comparisons({:reach, meta, [from_ast, to_ast, depth_ast, edge]}, counters) do
    case expand_comparisons(edge, counters) do
      {[edge2], counters} ->
        {{:reach, meta, [from_ast, to_ast, depth_ast, edge2]}, counters} |> wrap_single()

      _ ->
        raise ArgumentError, "reach/4 edge clause cannot contain multi-clause comparisons"
    end
  end

  defp expand_comparisons({op, _meta, [lhs, rhs]}, counters)
       when op in [:==, :=, :!=, :>, :>=, :<, :<=] do
    {op, lhs, rhs} = normalize_comparison_order(op, lhs, rhs)
    lhs_path? = datalog_path_expr?(lhs)
    rhs_path? = datalog_path_expr?(rhs)

    cond do
      op in [:==, :=] and lhs_path? and not rhs_path? ->
        {[{op, [], [lhs, rhs]}], counters}

      lhs_path? and rhs_path? ->
        {v1, counters} = next_cmp_var(counters)
        {v2, counters} = next_cmp_var(counters)
        scalar_op = if op == :=, do: :==, else: op
        {[{:=, [], [lhs, v1]}, {:=, [], [rhs, v2]}, {scalar_op, [], [v1, v2]}], counters}

      lhs_path? ->
        {v1, counters} = next_cmp_var(counters)
        {[{:=, [], [lhs, v1]}, {op, [], [v1, rhs]}], counters}

      true ->
        {[{op, [], [lhs, rhs]}], counters}
    end
  end

  defp expand_comparisons(other, counters), do: {[other], counters}

  defp wrap_single({clause, counters}), do: {[clause], counters}

  defp normalize_comparison_order(op, lhs, rhs) do
    lhs_path? = datalog_path_expr?(lhs)
    rhs_path? = datalog_path_expr?(rhs)

    cond do
      not lhs_path? and rhs_path? ->
        {flip_cmp_op(op), rhs, lhs}

      not lhs_path? and not rhs_path? and is_pin_or_literal?(lhs) and logic_var_ast?(rhs) ->
        {flip_cmp_op(op), rhs, lhs}

      true ->
        {op, lhs, rhs}
    end
  end

  defp flip_cmp_op(:<), do: :>
  defp flip_cmp_op(:<=), do: :>=
  defp flip_cmp_op(:>), do: :<
  defp flip_cmp_op(:>=), do: :<=
  defp flip_cmp_op(op), do: op

  defp is_pin_or_literal?({:^, _, [_]}), do: true
  defp is_pin_or_literal?({:-, _, [n]}) when is_integer(n) or is_float(n), do: true

  defp is_pin_or_literal?(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_atom(v),
    do: true

  defp is_pin_or_literal?(_), do: false

  defp logic_var_ast?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp logic_var_ast?(_), do: false

  defp next_cmp_var(%{cmp: n} = counters) do
    {{:"?__cmp_#{n}", [], nil}, %{counters | cmp: n + 1}}
  end

  defp extract_static_vars(segments) do
    segments
    |> Enum.reduce(MapSet.new(), fn
      {:static, bin}, acc when is_binary(bin) -> scan_vars_outside_quotes(bin, false, false, acc)
      _, acc -> acc
    end)
  end

  defp scan_vars_outside_quotes(<<>>, _in_q, _esc, acc), do: acc

  defp scan_vars_outside_quotes(<<?\\, _, rest::binary>>, true, false, acc),
    do: scan_vars_outside_quotes(rest, true, false, acc)

  defp scan_vars_outside_quotes(<<?", rest::binary>>, in_q, false, acc),
    do: scan_vars_outside_quotes(rest, not in_q, false, acc)

  defp scan_vars_outside_quotes(<<??, rest::binary>>, false, false, acc) do
    case consume_ident(rest, []) do
      {"", tail} -> scan_vars_outside_quotes(tail, false, false, acc)
      {ident, tail} -> scan_vars_outside_quotes(tail, false, false, MapSet.put(acc, "?" <> ident))
    end
  end

  defp scan_vars_outside_quotes(<<_, rest::binary>>, in_q, _esc, acc),
    do: scan_vars_outside_quotes(rest, in_q, false, acc)

  defp consume_ident(<<c, rest::binary>>, [])
       when c in ?A..?Z or c in ?a..?z or c == ?_ do
    consume_ident(rest, [c])
  end

  defp consume_ident(<<c, rest::binary>>, [_ | _] = acc)
       when c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c == ?_ do
    consume_ident(rest, [c | acc])
  end

  defp consume_ident(rest, acc), do: {IO.iodata_to_binary(:lists.reverse(acc)), rest}

  defp compile_error!(%Macro.Env{file: file, line: line}, description) do
    raise CompileError, file: file, line: line, description: description
  end

  defp compile_error!(nil, description) do
    raise CompileError, description: description
  end
end
