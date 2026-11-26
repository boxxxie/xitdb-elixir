defmodule Credo.Check.Warning.NoBusinessLogicRescue do
  @moduledoc false

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed_paths: ["lib/xitdb/fallback.ex"]],
    explanations: [
      check:
        "Avoid `rescue`/`catch` outside boundary modules; fail fast or use `Xitdb.Fallback.run/2,3` or `Xitdb.Fallback.try_run/3,4`."
    ]

  @impl Credo.Check
  def run(%SourceFile{filename: filename} = source_file, params) do
    allowed = Params.get(params, :allowed_paths, __MODULE__)

    if Enum.any?(allowed, &String.starts_with?(filename, &1)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp traverse({:try, meta, [blocks]} = ast, issues, issue_meta) when is_list(blocks) do
    if non_reraise_handler?(blocks) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse({def_kind, meta, [_, blocks]} = ast, issues, issue_meta)
       when def_kind in [:def, :defp, :defmacro, :defmacrop] and is_list(blocks) do
    if non_reraise_handler?(blocks) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp non_reraise_handler?(blocks) do
    has_non_reraise?(blocks, :rescue) or has_non_reraise?(blocks, :catch)
  end

  defp has_non_reraise?(blocks, key) do
    case Keyword.fetch(blocks, key) do
      {:ok, clauses} -> not all_clauses_reraise?(clauses)
      :error -> false
    end
  end

  defp all_clauses_reraise?(clauses) when is_list(clauses) and clauses != [] do
    Enum.all?(clauses, fn
      {:->, _, [_lhs, body]} -> ends_with_reraise?(body)
      _ -> false
    end)
  end

  defp all_clauses_reraise?(_), do: false

  defp ends_with_reraise?({:__block__, _, exprs}) when is_list(exprs) and exprs != [] do
    ends_with_reraise?(List.last(exprs))
  end

  defp ends_with_reraise?({:reraise, _, _}), do: true
  defp ends_with_reraise?({{:., _, [:erlang, :raise]}, _, [_, _, _]}), do: true
  defp ends_with_reraise?(_), do: false

  defp issue_for(issue_meta, line_no) do
    format_issue(issue_meta,
      message: "Unexpected `rescue`/`catch` outside boundary modules.",
      line_no: line_no
    )
  end
end
