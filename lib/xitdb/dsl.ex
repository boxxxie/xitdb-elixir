defmodule Xitdb.DSL do
  @moduledoc """
  Compile-time macro DSL for `Xitdb` path selectors, transaction mutation blocks,
  structural Pull patterns, and Ecto/Datomic-style Datalog queries.

  ## Usage

      use Xitdb.DSL

      # 1. Path selector macro with runtime interpolation & collection tags
      sel = path(users[user_id].todos[[idx]])
      counted_sel = path(org.counted(:departments)[dept_id].headcount)

      # 2. Atomic transaction block (0 intermediate NIF reads, auto-vivifies paths)
      {:ok, db} =
        tx db, doc: "promote alice" do
          put users[id].role, "admin"
          append users[id].audit_log, "promoted"
          insert users[id].todos[[0]], "urgent task"
          slice users[id].todos, 0..9
          fork users[id], backups[id]
          rm users[id].temp_token
          update users[id].login_count, &((&1 || 0) + 1)
        end

      # 3. Declarative Datalog query macro with ^var pinning
      {:ok, res} =
        query db do
          find {name, salary}
          where [
            sorted("username->id")[name] == id,
            starts_with(name, ^prefix),
            users[id].salary == salary,
            salary >= ^min_salary,
            not(users[id].flags.set_member("suspended"))
          ]
        end
  """

  alias Xitdb.DSL.{DatalogCompiler, PathCompiler, TxRewriter}
  alias Xitdb.Pull

  defmacro __using__(_opts) do
    quote do
      import Xitdb.DSL
      import Xitdb.Sigils
    end
  end

  # ============================================================================
  # 1. Path & Pull Selector Macros (`path/1`, `pull_pattern/1`)
  # ============================================================================

  @doc """
  Compiles an Elixir path expression into a canonical `xitdb` selector binary.

  Static segments are folded into a single binary literal at compile time, while
  dynamic runtime expressions (`users[id]`, `todos[[idx]]`) are safely encoded at
  runtime.

  ## Supported Step Modifiers
  - `.field` or `[key]` — `:hash_map` (`.key`)
  - `counted(:key)` or `counted(var)` — `:counted_hash_map` (`#key`)
  - `sorted(:key)` or `sorted(var)` — `:sorted_map` (`$key`)
  - `[idx]` or `array(idx)` — `:array_list` (`[idx]`)
  - `[[idx]]` or `linked(idx)` — `:linked_array_list` (`[[idx]]`)
  - `set_member(m)` — `:hash_set` (`%m`)
  - `counted_set_member(m)` — `:counted_hash_set` (`#%m`)
  - `sorted_set_member(m)` — `:sorted_set` (`^m`)
  - `at_moment(moment, path)` — prefixes `@<moment>`
  """
  defmacro path(expr) do
    PathCompiler.compile(expr)
  end

  @doc """
  Compiles an Elixir path expression into a pre-tokenized `xitdb` path-step list,
  eliminating selector string formatting and NIF-side selector parsing at runtime.
  """
  defmacro path_steps(expr) do
    PathCompiler.compile_steps(expr)
  end

  @doc """
  Compiles a structural Pull pattern into a canonical `xitdb` Pull string at compile time
  when given a literal list, or at runtime if dynamic.
  """
  defmacro pull_pattern(pattern) when is_list(pattern) do
    case eval_static_pull_ast(pattern) do
      {:ok, static_pattern} ->
        Pull.compile!(static_pattern)

      :dynamic ->
        quote do
          Xitdb.Pull.compile!(unquote(pattern))
        end
    end
  end

  defmacro pull_pattern(pattern) do
    quote do
      Xitdb.Pull.compile!(unquote(pattern))
    end
  end

  defp eval_static_pull_ast(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn elem, {:ok, acc} ->
      case eval_static_pull_elem(elem) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        :dynamic -> {:halt, :dynamic}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, :lists.reverse(rev)}
      :dynamic -> :dynamic
    end
  end

  defp eval_static_pull_ast(_), do: :dynamic

  defp eval_static_pull_elem(v) when is_atom(v) or is_binary(v), do: {:ok, v}

  defp eval_static_pull_elem({k, v}) when is_atom(k) or is_binary(k) do
    with {:ok, ev} <- eval_static_pull_val(v), do: {:ok, {k, ev}}
  end

  defp eval_static_pull_elem(_), do: :dynamic

  defp eval_static_pull_val(list) when is_list(list), do: eval_static_pull_ast(list)

  defp eval_static_pull_val({:.., _, [first_ast, last_ast]}) do
    with {:ok, first} <- eval_static_int(first_ast),
         {:ok, last} <- eval_static_int(last_ast) do
      {:ok, first..last}
    end
  end

  defp eval_static_pull_val({:..//, _, [first_ast, last_ast, step_ast]}) do
    with {:ok, first} <- eval_static_int(first_ast),
         {:ok, last} <- eval_static_int(last_ast),
         {:ok, step} <- eval_static_int(step_ast) do
      {:ok, first..last//step}
    end
  end

  defp eval_static_pull_val({:{}, _, [:slice, off_ast, lim_ast]}) do
    with {:ok, off} <- eval_static_int(off_ast),
         {:ok, lim} <- eval_static_int(lim_ast) do
      {:ok, {:slice, off, lim}}
    end
  end

  defp eval_static_pull_val({a, b}) do
    with {:ok, ea} <- eval_static_pull_val(a),
         {:ok, eb} <- eval_static_pull_ast(b) do
      {:ok, {ea, eb}}
    end
  end

  defp eval_static_pull_val(_), do: :dynamic

  defp eval_static_int(i) when is_integer(i), do: {:ok, i}
  defp eval_static_int({:-, _, [i]}) when is_integer(i), do: {:ok, -i}
  defp eval_static_int(_), do: :dynamic

  # ============================================================================
  # 2. Transaction Mutation Block DSL (`tx/2`, `tx/3`, `tx!/2`, `tx!/3`)
  # ============================================================================

  @doc """
  Executes a declarative transaction block and commits all staged operations in a
  single atomic NIF call.

  Inside `tx`, the following operations are available:
  - `put path_expr, value` (or 1-arity `put set_path.set_member(member)` for set members)
  - `update path_expr, fun` (or 3-arity `update path_expr, default, fun`)
  - `rm path_expr`
  - `append path_expr, value`
  - `insert list_path[[idx]], value` (or `insert list_path, idx, value`)
  - `slice list_path, first..last` (or `slice list_path, offset, size`)
  - `fork from_path, to_path`
  - `index_on source_map, field_key, index_map`
  - `init_col path_expr, kind`
  - `reset_col path_expr, kind`
  - `meta key, value`
  - `instant epoch_ms`
  - `savepoint()`
  - `abort reason`
  """
  defmacro tx(db, opts) when is_list(opts) do
    compile_tx_kw(db, opts, &TxRewriter.compile_tx/4, __CALLER__)
  end

  defmacro tx(db, opts, do: block) do
    TxRewriter.compile_tx(db, opts, block, __CALLER__)
  end

  @doc """
  Same as `tx/2` and `tx/3`, but returns the updated `%Xitdb{}` handle directly
  or raises `Xitdb.Error` on failure.
  """
  defmacro tx!(db, opts) when is_list(opts) do
    compile_tx_kw(db, opts, &TxRewriter.compile_tx_bang/4, __CALLER__)
  end

  defmacro tx!(db, opts, do: block) do
    TxRewriter.compile_tx_bang(db, opts, block, __CALLER__)
  end

  defp compile_tx_kw(db, opts, compiler, caller) do
    if Keyword.keyword?(opts) and Keyword.has_key?(opts, :do) do
      {block, rest_opts} = Keyword.pop!(opts, :do)
      compiler.(db, rest_opts, block, caller)
    else
      raise ArgumentError, "expected a :do block in transaction options, got: #{inspect(opts)}"
    end
  end

  @doc """
  Wraps `tx/2` and `tx/3`, automatically injecting all `index_on` declarations
  configured on one or more schema modules exporting `__xitdb_indexes__/0`
  (and optional `__xitdb_collection__/0`).
  """
  defmacro tx_for(db, schemas, do: block) do
    TxRewriter.compile_tx_for(db, schemas, [], block, __CALLER__)
  end

  defmacro tx_for(db, schemas, opts, do: block) do
    TxRewriter.compile_tx_for(db, schemas, opts, block, __CALLER__)
  end

  @doc """
  Same as `tx_for/3` and `tx_for/4`, but returns the updated `%Xitdb{}` handle directly
  or raises `Xitdb.Error` on failure.
  """
  defmacro tx_for!(db, schemas, do: block) do
    TxRewriter.compile_tx_for_bang(db, schemas, [], block, __CALLER__)
  end

  defmacro tx_for!(db, schemas, opts, do: block) do
    TxRewriter.compile_tx_for_bang(db, schemas, opts, block, __CALLER__)
  end

  # ============================================================================
  # 3. Datalog Query Macro (`datalog/1`, `query/2`, `query/3`, `query!/2`, `query!/3`)
  # ============================================================================

  @doc """
  Compiles an Ecto/Datomic-style Datalog query block into a canonical `xitdb` Datalog string.

  ## Examples

      min_age = 21

      q =
        datalog do
          find {e, name, age}
          from users
          where [
            e.username == name,
            e.age == age,
            age >= ^min_age,
            not(e.banned == true)
          ]
        end
  """
  defmacro datalog(do: block) do
    DatalogCompiler.compile(block, [], __CALLER__)
  end

  @doc """
  Compiles and executes a Datalog query block against `target` (`%Xitdb{}` or `%Xitdb.Cursor{}`).
  """
  defmacro query(target, opts_or_query) do
    expand_query_2(:query, target, opts_or_query, __CALLER__)
  end

  defmacro query(target, opts, do: block) do
    {from_opt, runtime_opts} =
      if Keyword.keyword?(opts), do: Keyword.pop(opts, :from), else: {nil, opts}

    query_str_ast = DatalogCompiler.compile(block, [from: from_opt], __CALLER__)

    quote do
      Xitdb.query(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
    end
  end

  defmacro query(target, query_str, opts) do
    quote do
      Xitdb.query(unquote(target), unquote(query_str), unquote(opts))
    end
  end

  @doc """
  Same as `query/2` and `query/3`, but raises `Xitdb.Error` on failure.
  """
  defmacro query!(target, opts_or_query) do
    expand_query_2(:query!, target, opts_or_query, __CALLER__)
  end

  defmacro query!(target, opts, do: block) do
    {from_opt, runtime_opts} =
      if Keyword.keyword?(opts), do: Keyword.pop(opts, :from), else: {nil, opts}

    query_str_ast = DatalogCompiler.compile(block, [from: from_opt], __CALLER__)

    quote do
      Xitdb.query!(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
    end
  end

  defmacro query!(target, query_str, opts) do
    quote do
      Xitdb.query!(unquote(target), unquote(query_str), unquote(opts))
    end
  end

  defp expand_query_2(fun, target, opts_or_query, caller) do
    if is_list(opts_or_query) and Keyword.keyword?(opts_or_query) and
         Keyword.has_key?(opts_or_query, :do) do
      {block, opts} = Keyword.pop!(opts_or_query, :do)
      {from_opt, runtime_opts} = Keyword.pop(opts, :from)
      query_str_ast = DatalogCompiler.compile(block, [from: from_opt], caller)

      quote do
        Xitdb.unquote(fun)(unquote(target), unquote(query_str_ast), unquote(runtime_opts))
      end
    else
      quote do
        Xitdb.unquote(fun)(unquote(target), unquote(opts_or_query), [])
      end
    end
  end
end
