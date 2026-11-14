if Code.ensure_loaded?(Ash.DataLayer) do
  defmodule Xitdb.Ash.Query do
    @moduledoc false

    defstruct [
      :resource,
      :domain,
      :filter,
      :sort,
      :distinct,
      :distinct_sort,
      :limit,
      :offset,
      :select,
      :tenant,
      context: %{},
      aggregates: [],
      calculations: []
    ]

    def new(resource, domain), do: %__MODULE__{resource: resource, domain: domain}

    def set_context(_resource, %__MODULE__{} = query, context),
      do: {:ok, %{query | context: context}}

    def set_tenant(_resource, %__MODULE__{} = query, tenant), do: {:ok, %{query | tenant: tenant}}
    def filter(%__MODULE__{} = query, filter, _resource), do: {:ok, %{query | filter: filter}}
    def sort(%__MODULE__{} = query, sort, _resource), do: {:ok, %{query | sort: sort}}

    def distinct(%__MODULE__{} = query, distinct, _resource),
      do: {:ok, %{query | distinct: distinct}}

    def distinct_sort(%__MODULE__{} = query, sort, _resource),
      do: {:ok, %{query | distinct_sort: sort}}

    def limit(%__MODULE__{} = query, limit, _resource), do: {:ok, %{query | limit: limit}}
    def offset(%__MODULE__{} = query, offset, _resource), do: {:ok, %{query | offset: offset}}
    def select(%__MODULE__{} = query, select, _resource), do: {:ok, %{query | select: select}}

    def add_aggregate(%__MODULE__{} = query, agg, _resource),
      do: {:ok, %{query | aggregates: [agg | query.aggregates]}}

    def add_aggregates(%__MODULE__{} = query, aggs, _resource),
      do: {:ok, %{query | aggregates: aggs ++ query.aggregates}}

    def add_calculation(%__MODULE__{} = query, calc, expr, _resource),
      do: {:ok, %{query | calculations: [{calc, expr} | query.calculations]}}

    def add_calculations(%__MODULE__{} = query, calcs, _resource),
      do: {:ok, %{query | calculations: calcs ++ query.calculations}}

    def execute(_db, %__MODULE__{context: %{__stub_empty__: true}}, _resource), do: {:ok, []}
    def execute(_db, _query, _resource), do: {:error, :not_implemented}

    def execute_aggregates(_db, %__MODULE__{context: %{__stub_empty__: true}}, _aggs, _resource),
      do: {:ok, %{}}

    def execute_aggregates(_db, _query, _aggregates, _resource), do: {:error, :not_implemented}
  end
end
