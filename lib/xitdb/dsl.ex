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
  Compiles a structural Pull pattern into a canonical `xitdb` Pull string at compile time
  when given a literal list, or at runtime if dynamic.
  """
  defmacro pull_pattern(pattern) when is_list(pattern) do
    if Macro.quoted_literal?(pattern) do
      Pull.compile!(pattern)
    else
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
  defmacro tx(db, do: block) do
    TxRewriter.compile_tx(db, [], block, __CALLER__)
  end

  defmacro tx(db, opts, do: block) do
    TxRewriter.compile_tx(db, opts, block, __CALLER__)
  end

  @doc """
  Same as `tx/2` and `tx/3`, but returns the updated `%Xitdb{}` handle directly
  or raises `Xitdb.Error` on failure.
  """
  defmacro tx!(db, do: block) do
    TxRewriter.compile_tx_bang(db, [], block, __CALLER__)
  end

  defmacro tx!(db, opts, do: block) do
    TxRewriter.compile_tx_bang(db, opts, block, __CALLER__)
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
  defmacro query(target, do: block) do
    query_str_ast = DatalogCompiler.compile(block, [], __CALLER__)

    quote do
      Xitdb.query(unquote(target), unquote(query_str_ast), [])
    end
  end

  defmacro query(target, query_str) do
    quote do
      Xitdb.query(unquote(target), unquote(query_str), [])
    end
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
  defmacro query!(target, do: block) do
    query_str_ast = DatalogCompiler.compile(block, [], __CALLER__)

    quote do
      Xitdb.query!(unquote(target), unquote(query_str_ast), [])
    end
  end

  defmacro query!(target, query_str) do
    quote do
      Xitdb.query!(unquote(target), unquote(query_str), [])
    end
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
end
